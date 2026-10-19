import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 52 — the window stays usable while another process holds the archive.
///
/// This is the slice's own verification criterion, expressed as a test: *"A
/// mutation issued while another process holds the lock must leave the window
/// responsive and surface `archiveBusy` as a message, not a freeze."*
///
/// The competing holder is a second `ArchiveLock` on the same lockfile. That is a
/// faithful stand-in for another process rather than a cheat — `flock(2)`
/// ownership belongs to the open file description, so two descriptors contend
/// identically whether they live in one process or two (the same technique
/// `CrossProcessWriteSafetyTests` uses in the engine).
@MainActor
@Suite struct MainActorResponsivenessTests {

    /// The heart of it: with a competitor holding the lock, a mutation is in
    /// flight *and* the main actor is still free to run.
    ///
    /// **This is the assertion that fails outright without 52's engine change.**
    /// Moving the write off the main actor is not enough on its own: under slice
    /// 47's lock ordering the waiting writer held `Archive`'s state lock for the
    /// whole five-second wait, so the very next main-actor *read* — a detail-pane
    /// render, or 51's one-second external-change poll — parked behind it. The
    /// freeze moved; it did not go away.
    @Test func aBlockedMutationLeavesTheMainActorFree() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let existing = try #require(model.persons.first?.uid)

        try await AppTestSupport.withCompetitor(holdingTheLockAt: root) {
            model.createPerson(given: "Rose", surname: "Hanner")
            #expect(model.hasMutationsInFlight)

            // **Let the write actually reach the flock before timing anything.**
            // `mutate` hands off to a `Task`, which needs the main actor to start
            // — so timing reads immediately after the call measures a write that
            // has not begun, and would pass no matter how the engine locks. Found
            // exactly that way: this test passed against the pre-52 lock order
            // until it waited. It now asks the engine rather than sleeping a guess.
            try await Self.untilBlocked(try #require(model.archive))

            let started = ContinuousClock.now
            for _ in 0..<50 {
                #expect(model.fullPerson(existing) != nil)
                #expect(model.persons.count == 1)
            }
            let cost = ContinuousClock.now - started
            #expect(cost < .milliseconds(250), "50 main-actor reads took \(cost)")
        }

        await model.settle()
        #expect(model.persons.count == 2, "the write lands once the competitor releases")
    }

    /// The indicator is delayed, so an ordinary edit never flashes it.
    @Test func anOrdinaryEditNeverShowsTheWaitingIndicator() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        #expect(!model.isWaitingOnAnotherProcess)
    }

    /// …and it does appear once a wait outlives the delay, then clears.
    @Test func aLongWaitShowsTheIndicatorAndThenClearsIt() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        // Long enough that the write cannot give up while the deadlines below run.
        let archive = try #require(model.archive)
        archive.lockTimeout = 30

        try await AppTestSupport.withCompetitor(holdingTheLockAt: root) {
            model.createPerson(given: "Marcus", surname: "Hanner")
            #expect(!model.isWaitingOnAnotherProcess, "not before the delay")

            // **The clock starts once the write is blocked, not when it is issued**
            // (CI, slice 77). Before it reaches the flock the write needs the main
            // actor to start its `Task` and then the write queue; on a loaded
            // runner that hop alone ate a deadline counted from the call, and the
            // test failed with the indicator never armed because nothing was
            // waiting yet. Polled to deadlines rather than sampled once, because
            // the suites run in parallel — a *timing* flake, not a behaviour
            // change, is the kind most likely to be re-diagnosed as a real bug.
            try await Self.untilBlocked(archive)
            let deadline = ContinuousClock.now + .seconds(10)
            while !model.isWaitingOnAnotherProcess && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(model.isWaitingOnAnotherProcess)
        }

        await model.settle()
        #expect(!model.isWaitingOnAnotherProcess, "it must clear when the write lands")
    }

    /// A *local* write that outlives the delay must stay silent.
    ///
    /// The bar used to fire on elapsed time alone, so a long write with no
    /// competitor — a big ingest, an index rebuild — announced "another process
    /// is writing" when nothing else was running (52's `/code-review`). A rebuild
    /// is the honest stand-in: real work, no contention.
    ///
    /// **The volume is seeded on disk, not written through the model** (CI, after
    /// slice 64). This used to issue 400 `createPerson` calls to make the write
    /// queue busy for long enough, and each of those commits ran `refresh()` on
    /// the main actor — 400 people-list reloads back to back, which held the one
    /// actor every other suite's `settle()` and commit hop also needs. On a slow
    /// runner that was 17 s of main-actor time, and seventeen unrelated undo and
    /// repair tests expired their 10 s deadline at once. A thousand person
    /// records dropped straight into `conclusions/persons/` cost the main actor
    /// nothing, and one `rebuildIndex()` over them is a single write that takes
    /// well over the delay — ~0.9 ms a record — with a single commit at the end.
    @Test func aSlowLocalWriteDoesNotClaimAnotherProcess() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        // Off the main actor for the same reason as the rest of this test.
        let personCount = 1000
        try await Task.detached {
            let personsDirectory = root.appendingPathComponent(
                "conclusions/persons", isDirectory: true)
            try FileManager.default.createDirectory(
                at: personsDirectory, withIntermediateDirectories: true)
            for index in 0..<personCount {
                let person = Person(
                    uid: IdentifierMinter.person(),
                    names: [
                        PersonName(
                            type: .birth, given: "Person", surname: "\(index)",
                            full: "Person \(index)")
                    ],
                    provenance: .assertedNow())
                try GeneaLogicJSON.encoder.encode(person).write(
                    to: personsDirectory.appendingPathComponent("\(person.uid.raw).json"))
            }
        }.value

        let started = ContinuousClock.now
        model.rebuildIndex()
        // Watch across the whole write, not just at the end — the bar is only
        // wrong while it is up.
        var everClaimed = false
        while model.hasMutationsInFlight {
            if model.isWaitingOnAnotherProcess { everClaimed = true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await model.writesSettled()
        let elapsed = ContinuousClock.now - started

        // **Guards against the test proving nothing.** If the work finishes before
        // the indicator is even armed, the assertion below passes no matter how
        // the indicator behaves — which is exactly what the first version of this
        // test did, and it survived deliberate sabotage because of it.
        #expect(
            elapsed > ArchiveModel.waitIndicatorDelay,
            "local work finished in \(elapsed), before the indicator could arm")
        #expect(!everClaimed, "no competitor was running, so nothing should claim one")
        #expect(model.persons.count == personCount)
    }

    /// A wait that outlasts the lock timeout fails as a *message*, with the
    /// window still alive — `archiveBusy`, not a beachball. The timeout is
    /// shortened so the test doesn't sit out the production five seconds.
    @Test func anExhaustedWaitSurfacesArchiveBusyAsAnError() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        let archive = try #require(model.archive)
        archive.lockTimeout = 0.2

        try await AppTestSupport.withCompetitor(holdingTheLockAt: root) {
            model.createPerson(given: "Marcus", surname: "Hanner")
            await model.settle()

            #expect(model.persons.isEmpty)
            let message = try #require(model.actionError)
            #expect(message.localizedCaseInsensitiveContains("another"), "got: \(message)")
        }
    }

    /// Waits until the engine reports a write parked on the competitor's lock.
    /// Reads `isWaitingForAnotherProcess`, which takes none of the archive's
    /// locks, so it answers while the write is blocked.
    private static func untilBlocked(_ archive: Archive) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !archive.isWaitingForAnotherProcess && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(archive.isWaitingForAnotherProcess, "the write never reached the lock")
    }
}

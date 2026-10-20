import Foundation
import GeneaLogicModel
import Synchronization
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Shared scaffolding for the app-level tests.
///
/// **The app had no test target until slice 52.** It was added for the undo
/// coverage that slice needed: moving every engine call off the main actor
/// rewrote all seventeen `registerUndo` blocks, and the failure mode for getting
/// that wrong is silent (⌘Z stops ping-ponging and nothing throws). The suite is
/// deliberately narrow — it exercises `ArchiveModel` against a real temporary
/// archive, not the SwiftUI views.
enum AppTestSupport {

    /// A fresh empty archive in a temp directory, plus a model already opened on
    /// it with an `UndoManager` attached (the window supplies one in production —
    /// without it, mutations still happen but record no undo).
    /// - Parameter undo: `false` detaches the undo manager entirely, for tests
    ///   that are not about undo. Worth having rather than ignoring: with
    ///   explicit grouping (see below), a mutation issued outside `act` has no
    ///   open group, and `NSUndoManager` *raises* when the deferred registration
    ///   lands. An unrelated test would then fail for a reason that has nothing
    ///   to do with what it is checking.
    @MainActor
    static func makeModel(undo: Bool = true) throws -> (model: ArchiveModel, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-app-tests-\(UUID().uuidString)")
        _ = try Archive.create(at: root)

        // `load()` refuses to open an archive it holds no sandbox access to, and
        // in a test there is neither a picker URL nor a saved bookmark to derive
        // one from. The archive is under the test host's own container, so it
        // needs no scope — just the store's acknowledgement that it is reachable.
        ArchiveAccessStore.shared.adoptAlreadyReachable(root)

        let model = ArchiveModel(url: root)
        model.undoManager = undo ? UndoManager() : nil
        // Grouped explicitly by `act`, rather than by run-loop event.
        //
        // **This is the one place the tests deliberately differ from the app**, so
        // it is worth being precise about why. In the app, grouping is
        // `groupsByEvent`'s — and must stay so, because that manager belongs to
        // the window and AppKit's text-field undo shares it (see
        // `ArchiveModel.undoManager`). Here the manager is ours alone with no text
        // field attached, so switching it off is safe, and it buys determinism the
        // event observer can't: it does not reliably fire between two `await`s in
        // a test, which silently merged consecutive actions into one group.
        //
        // The cost is that a test cannot express "two actions in the same
        // run-loop turn". That case is a known limitation of the app's grouping
        // (slice 52), not something the harness should pretend to cover.
        model.undoManager?.groupsByEvent = false
        model.load()
        return (model, root)
    }

    /// Removes a temp archive created by `makeModel`. Nothing was written to the
    /// app's defaults (see `adoptAlreadyReachable`), so only the live entry and
    /// the directory need clearing.
    @MainActor
    static func remove(_ root: URL) {
        ArchiveAccessStore.shared.release(root)
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `body` while "another process" holds the archive lock, and does not
    /// return until that holder has actually let go. Shared since slice 67, whose
    /// busy-archive case needs the same competitor.
    ///
    /// The holder sits on a background thread rather than wrapping `body` in
    /// `ArchiveLock.withLock`, because `withLock` takes a synchronous closure and
    /// every one of these tests needs to `await` inside the held window.
    ///
    /// **Slice 53:** the holder now *opens its own* `ArchiveLock` instead of capturing
    /// one. `ArchiveLock` is not `Sendable` and 53 changes nothing in the package, so
    /// only the lockfile URL — a value — crosses onto the background thread. It contends
    /// exactly as before: `flock(2)` ownership belongs to the open file description, and
    /// this is a second description either way.
    @MainActor
    static func withCompetitor(
        holdingTheLockAt root: URL, _ body: () async throws -> Void
    ) async throws {
        let lockURL = ArchiveLayout.lockURL(in: root)
        let held = DispatchSemaphore(value: 0)
        let mayRelease = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        let tookIt = Mutex(false)

        DispatchQueue.global().async {
            if let lock = try? ArchiveLock(at: lockURL, archiveRoot: root) {
                try? lock.withLock {
                    tookIt.withLock { $0 = true }
                    held.signal()
                    mayRelease.wait()
                }
            }
            // Unconditional, so a lockfile that cannot be opened *fails* the suite via
            // `tookIt` rather than hanging it. On the success path this is a second
            // signal nothing waits on, which is harmless.
            held.signal()
            released.signal()
        }
        await Self.wait(for: held)
        try #require(tookIt.withLock { $0 }, "the competitor never took the lock")

        do {
            try await body()
        } catch {
            mayRelease.signal()
            await Self.wait(for: released)
            throw error
        }
        mayRelease.signal()
        await Self.wait(for: released)
    }

    /// Polls `condition` until it holds or `timeout` of *running* time is spent,
    /// and returns whether it held.
    ///
    /// **Only the time this loop was actually running counts** (#33). A gap
    /// between two polls longer than `longestCountedGap` means the main actor,
    /// or the whole test process, wasn't scheduling us. That isn't the thing
    /// being waited on being slow: whatever it is ends on the main actor too,
    /// so it was stalled for the same stretch. On a loaded CI runner the
    /// suite once went ~7 seconds with nothing completing, not even tests
    /// that only needed the main actor. Every wall-clock deadline running at
    /// the time expired together, and about 25 unrelated tests failed at once.
    ///
    /// A real hang still fails: each poll counts up to the cap, so the budget
    /// runs out however slowly the loop turns.
    @MainActor
    static func poll(
        every interval: Duration = .milliseconds(2),
        for timeout: Duration = .seconds(10),
        until condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        var spent = Duration.zero
        var last = clock.now
        while !condition() && spent < timeout {
            try? await Task.sleep(for: interval)
            let now = clock.now
            spent += min(now - last, longestCountedGap)
            last = now
        }
        return condition()
    }

    /// The longest gap between polls that `poll` counts in full. Polls are
    /// milliseconds apart, so anything past this is the process not running.
    static let longestCountedGap: Duration = .milliseconds(100)

    /// `DispatchSemaphore.wait()` is unavailable from an async context — it blocks a
    /// cooperative-pool thread, which Swift 6 makes an error rather than a warning. The
    /// block moves to a global queue; the async side suspends instead of occupying one.
    private static func wait(for semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }
}

extension ArchiveModel {
    /// Performs one user action and waits for its write — and its undo
    /// registration — to land.
    ///
    /// Every mutation is asynchronous since slice 52, so a test that called
    /// `deleteArtifact` and asserted immediately would be racing the write queue.
    /// `settle` also turns the run loop, which is what closes the event group the
    /// registrations went into, so the next `undo()` reverses this action alone.
    @MainActor
    func act(_ body: () -> Void) async {
        undoManager?.beginUndoGrouping()
        body()
        // Settle *inside* the group: since slice 52 the undo registration happens
        // in `commit`, a hop after the call, so closing the group first would
        // leave it homeless and `NSUndoManager` would raise "must begin a group
        // before registering undo".
        await settle()
        undoManager?.endUndoGrouping()
    }

    /// Undoes one group and waits for the engine call it issues.
    @MainActor
    func undoAndSettle() async {
        undoManager?.undo()
        await settle()
    }

    /// Redoes one group and waits for the engine call it issues.
    @MainActor
    func redoAndSettle() async {
        undoManager?.redo()
        await settle()
    }

    /// Waits for the cheap file sweep to finish (slice 57).
    ///
    /// It runs off the main actor, so `fileDamage` is not yet published when
    /// `load()` or a refresh returns. Awaits the real task rather than polling for
    /// its effect — polling could not tell "the sweep found nothing" from "the
    /// sweep hasn't run yet", which is the distinction half these tests are about.
    @MainActor
    func fileSweepSettled() async {
        await fileSweepTask?.value
    }

    /// Waits for the out-of-band staleness check to finish (slice 60).
    ///
    /// Same shape and same reason as `fileSweepSettled()`: it runs off the main
    /// actor, so nothing it rebuilds is published when the poll returns. Awaiting
    /// the task distinguishes "the check found nothing" from "the check hasn't
    /// run", which is precisely what these tests are asserting.
    @MainActor
    func reconcileSettled() async {
        await reconcileTask?.value
    }

    /// Waits until no mutation is in flight.
    ///
    /// Polls rather than awaiting a signal because `mutate` deliberately exposes
    /// no completion handle — the app never needs one, and adding it to the
    /// production type purely for tests would be the tail wagging the dog.
    ///
    /// **Giving up is a failure, and saying so is the whole point** (CI, slice
    /// 61). This used to expire *silently* on a two-second deadline, on the
    /// reasoning that a write against an uncontended temporary archive is
    /// sub-millisecond so anything approaching it is a bug. Both halves were
    /// wrong in the same direction. The archive is uncontended but the *machine*
    /// is not — suites run in parallel, and slice 61's added a second one that
    /// clones archives and builds indexes — so two seconds is reachable on a
    /// loaded CI runner. And expiring silently does not report that bug: it hands
    /// the test a half-applied model, which then fails on whatever it asserts
    /// next. That is exactly how this surfaced — as `model.persons` not being
    /// empty after an undo, and as an index-out-of-range crash two lines after a
    /// count check, in slice 52's undo suite, which had nothing to do with it.
    ///
    /// So the deadline is now generous *and* loud. A timeout that reports itself
    /// cannot read as a hang, which was the original argument for keeping it
    /// short, so the trade that argument was making no longer applies.
    ///
    /// **And it counts running time, not wall time** (#33): see
    /// `AppTestSupport.poll`.
    @MainActor
    func settle(timeout: Duration = .seconds(10)) async {
        let settled = await AppTestSupport.poll(for: timeout) { !hasMutationsInFlight }
        if !settled {
            Issue.record(
                """
                A mutation did not finish within \(timeout), so this test is about to \
                assert against a half-applied model. Treat any failure below as a \
                consequence of this, not as its cause.
                """)
        }
        // One more turn so the `commit` that just ran has published its state.
        await Task.yield()
    }
}

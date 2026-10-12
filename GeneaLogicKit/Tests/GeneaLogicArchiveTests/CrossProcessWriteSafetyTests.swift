import Foundation
import GeneaLogicModel
import Synchronization
import Testing

@testable import GeneaLogicArchive

/// Slice 47 — two GeneaLogic processes on one machine writing one archive.
///
/// `@testable` (unlike the rest of this suite) because the three mechanisms
/// under test are all deliberately `internal`: `ArchiveLock`, `IndexDirtyMarker`
/// and `ArchiveLayout`. Reaching them directly is the point — a test that could
/// only see the public API would have to infer the lockfile's path from a string
/// literal, which is exactly the hardcoding the slice forbids.
///
/// The *honest* concurrency tests cannot run in-process; they spawn real `genea`
/// invocations and live in the CLI package
/// (`GeneaLogicCLITests/ConcurrentWriterTests.swift`). What is provable here is
/// the mechanism: the timeout is set, the lock excludes, the sentinel is left
/// exactly when it should be, and the recovery path converges on the sidecars.
@Suite struct CrossProcessWriteSafetyTests {

    // MARK: - Busy timeout

    /// The failure this slice's simplest half removes: before it, a competing
    /// write got `SQLITE_BUSY` **immediately** and the mutation threw, because
    /// the connection set no busy timeout at all.
    ///
    /// Asserted on both connection constructors, since "every connection" is the
    /// claim — `SQLiteDatabase.init` is the only place a `sqlite3*` is opened,
    /// and `ArchiveIndex.open` is the only thing that calls it.
    @Test func everyIndexConnectionSetsABusyTimeout() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)
        let dbURL = ArchiveLayout.indexDatabaseURL(in: root)

        let raw = try SQLiteDatabase(at: dbURL)
        #expect(try raw.busyTimeout() == SQLiteDatabase.busyTimeoutMilliseconds)

        let index = try ArchiveIndex.open(at: dbURL)
        #expect(try index.busyTimeout() == SQLiteDatabase.busyTimeoutMilliseconds)
    }

    // MARK: - Where the lock lives

    /// Fork (c): the lockfile lives under `.index/`, which is already excluded
    /// from `manifest.files` and from `verifyIntegrity()`'s unreferenced-file
    /// sweep — so adding it changes neither. At the package root it would show
    /// up in both.
    ///
    /// Since slice 48 it is one level deeper — `.index/<machine-key>/lock` — so
    /// the exclusion has to hold at depth, which is what the integrity check
    /// below is really pinning now.
    @Test func theLockfileLivesInsideTheIndexDirectoryAndIsInvisibleToIntegrity() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "1920 Census"))

        let lockURL = ArchiveLayout.lockURL(in: root)
        #expect(FileManager.default.fileExists(atPath: lockURL.path))
        let machineDirectory = lockURL.deletingLastPathComponent()
        #expect(machineDirectory.lastPathComponent == MachineKey.current)
        #expect(machineDirectory.deletingLastPathComponent().lastPathComponent == ".index")

        let report = try archive.verifyIntegrity()
        #expect(report.isClean, "integrity issues: \(report.issues)")

        let manifestData = try Data(contentsOf: ArchiveLayout.manifestURL(in: root))
        let manifest = try GeneaLogicJSONCoding.decoder.decode(Manifest.self, from: manifestData)
        #expect(!manifest.files.contains { $0.path.hasPrefix(".index/") })
    }

    /// The implementation gotcha fork (c) names by hand: `rebuildIndex()` drops
    /// and regenerates the index, and must not take the lockfile with it — the
    /// owning `Archive` still holds a descriptor on it, so a delete-and-recreate
    /// would leave two processes locking two different inodes and both
    /// proceeding.
    @Test func rebuildingTheIndexLeavesTheLockfileAlone() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Before rebuild"))

        let lockURL = ArchiveLayout.lockURL(in: root)
        let inodeBefore =
            try FileManager.default.attributesOfItem(atPath: lockURL.path)[
                .systemFileNumber] as? Int

        try archive.rebuildIndex()

        let inodeAfter =
            try FileManager.default.attributesOfItem(atPath: lockURL.path)[
                .systemFileNumber] as? Int
        #expect(inodeBefore != nil)
        #expect(inodeBefore == inodeAfter)

        // And the archive is still usable afterwards — i.e. the lock it still
        // holds is the lock a competitor would contend for.
        try archive.addArtifact(.sample(title: "After rebuild"))
        #expect(archive.artifacts(matching: ArtifactQuery(text: "After rebuild")).count == 1)
    }

    // MARK: - Mutual exclusion

    /// Fork (d): a mutation blocked by another holder waits, then fails loudly
    /// with a typed error naming the holder — never hangs, never corrupts.
    ///
    /// The competing holder is a second `ArchiveLock` on the same path. That is
    /// a faithful stand-in for another process rather than a cheat: `flock(2)`
    /// ownership belongs to the *open file description*, so two descriptors
    /// contend identically whether they live in one process or two.
    @Test func aMutationBlockedByAnotherHolderThrowsArchiveBusy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        archive.lockTimeout = 0.15

        let competitor = try ArchiveLock(at: ArchiveLayout.lockURL(in: root), archiveRoot: root)
        var thrown: ArchiveError?
        try competitor.withLock {
            do {
                try archive.addArtifact(.sample(title: "Should not land"))
            } catch let error as ArchiveError {
                thrown = error
            }
        }

        guard case .archiveBusy(let busyRoot, let holderPID) = thrown else {
            Issue.record("expected .archiveBusy, got \(String(describing: thrown))")
            return
        }
        #expect(busyRoot.standardizedFileURL == root.standardizedFileURL)
        #expect(holderPID == ProcessInfo.processInfo.processIdentifier)
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Should not land")).isEmpty)

        // Released — the same mutation now goes through, so the lock is a turn
        // signal and not a permanent block.
        try archive.addArtifact(.sample(title: "Should not land"))
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Should not land")).count == 1)
    }

    /// Fork (e): readers take no archive lock, deliberately. A lookup issued
    /// while a competitor holds the lock must return (stale is acceptable;
    /// blocking the app's browse path behind an agent's writes is not).
    @Test func readsDoNotWaitOnTheArchiveLock() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let existing = try archive.addArtifact(.sample(title: "Already here"))
        archive.lockTimeout = 30  // Long enough that a reader taking it would hang the test.

        let competitor = try ArchiveLock(at: ArchiveLayout.lockURL(in: root), archiveRoot: root)
        try competitor.withLock {
            #expect(archive.artifact(withID: existing.uid)?.title == "Already here")
            #expect(archive.artifacts(matching: ArtifactQuery(text: "Already here")).count == 1)
        }
    }

    /// Slice 52: fork (e)'s promise has to survive **our own** blocked writer,
    /// not just the competitor.
    ///
    /// The test above holds the archive lock and reads — with nothing of ours
    /// waiting on it. But a reader and a waiting writer meet at `Archive.lock`,
    /// and under slice 47's `lock` → `fileLock` ordering the writer held `lock`
    /// for the whole 5s flock wait. Measured before the fix: 1.82s for one
    /// `artifacts()` call. That is the real shape of the app's freeze — the write
    /// is on a background thread, and the *main actor's next read* is what stops.
    ///
    /// So: a competitor holds the lock, one of our own writers is parked waiting
    /// for it, and a read must still come back promptly.
    @Test func aReadIsNotBlockedByOurOwnWriterWaitingOnTheArchiveLock() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let existing = try archive.addArtifact(.sample(title: "Already here"))
        archive.lockTimeout = 30  // The writer must still be waiting when we read.

        let competitor = try ArchiveLock(at: ArchiveLayout.lockURL(in: root), archiveRoot: root)
        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)

        try competitor.withLock {
            DispatchQueue.global().async {
                writerStarted.signal()
                // Blocks until the competitor below releases.
                _ = try? archive.addArtifact(.sample(title: "Blocked write"))
                writerFinished.signal()
            }
            writerStarted.wait()
            // Let the writer actually reach the flock poll before we time a read.
            Thread.sleep(forTimeInterval: 0.2)

            let started = ContinuousClock.now
            #expect(archive.artifact(withID: existing.uid)?.title == "Already here")
            let cost = ContinuousClock.now - started
            #expect(cost < .milliseconds(250), "read took \(cost) behind a waiting writer")
        }

        writerFinished.wait()
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Blocked write")).count == 1)
    }

    /// The invariant that makes the re-ordering safe: `writerLock` still admits
    /// exactly one in-process writer at a time, so the non-re-entrant `flock`
    /// never gets two holders sharing this process's descriptor. If it did, the
    /// first to finish would `LOCK_UN` the descriptor out from under the second,
    /// and a competing process could interleave with a mutation in progress.
    @Test func concurrentWritersInOneProcessStillSerialize() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let tracker = ConcurrencyTracker()
        let group = DispatchGroup()

        for index in 0..<8 {
            DispatchQueue.global().async(group: group) {
                try? archive.withState { manifest, _ in
                    tracker.enter()
                    // Wide enough that genuine overlap would be caught.
                    Thread.sleep(forTimeInterval: 0.01)
                    tracker.leave()
                    manifest.name = "writer \(index)"
                }
            }
        }
        group.wait()

        #expect(!tracker.sawOverlap, "two writers were inside withState at once")
    }

    // MARK: - Divergence detection (the `.index/dirty` sentinel)

    @Test func aCleanMutationLeavesNoSentinel() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "1920 Census"))
        try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        #expect(!IndexDirtyMarker.isSet(in: root))
    }

    /// Fork (f), end to end: an index write that **fails after the sidecar is
    /// already on disk** is the divergence nothing used to detect — the index
    /// file is present, opens fine, and is schema-current, so none of the
    /// existing rebuild triggers fire.
    ///
    /// The failure is injected for real rather than mocked: a second connection
    /// drops the `place` table out from under the archive's own connection, so
    /// `upsert`'s final `replacePlaces` throws — *after* `record.json` has been
    /// written. The sidecars are authoritative, so the correct recovery is for
    /// the next `open()` to rebuild onto them, which is what is asserted.
    @Test func anInterruptedMutationLeavesTheSentinelAndTheNextOpenRebuildsFromIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let saboteur = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        try saboteur.exec("DROP TABLE place;")

        let birthplace = Location(asRecorded: "Riga, Latvia")
        #expect(throws: ArchiveError.self) {
            try archive.addArtifact(.sample(title: "Survivor", locations: [birthplace]))
        }
        #expect(IndexDirtyMarker.isSet(in: root))

        // The sidecar landed even though the index write did not finish — that
        // is the divergence, and it is why the sentinel has to exist. Note the
        // divergence is *partial*: `upsert` is not one transaction, so the
        // artifact row is there and only the place projection is missing. A
        // half-applied index is exactly as wrong as an unapplied one, and just
        // as invisible to the existing rebuild triggers.
        #expect(try artifactRecordTitles(in: root) == ["Survivor"])
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Survivor")).count == 1)
        #expect(try indexPlaceStrings(in: root).isEmpty)

        let reopened = try Archive.open(at: root)
        #expect(!IndexDirtyMarker.isSet(in: root))
        #expect(reopened.artifacts(matching: ArtifactQuery(text: "Survivor")).count == 1)
        #expect(try indexPlaceStrings(in: root).contains(birthplace.asRecorded))
    }

    /// The sentinel is what `open()` reads, so a leftover one must force a
    /// rebuild even when the index looks perfectly healthy — otherwise the whole
    /// mechanism is decorative. Here the "interrupted" mutation is simulated the
    /// way a crashed process leaves things: a sidecar on disk that the index has
    /// never seen, plus the marker.
    @Test func aLeftoverSentinelForcesARebuildOfAnOtherwiseHealthyIndex() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Indexed normally"))

        let orphan = Artifact(
            uid: ArtifactID("ART-01890000-0000-7000-8000-0000000000ff"),
            title: "Written behind the index's back",
            mediaType: .document,
            provenance: .assertedNow()
        )
        let orphanDirectory = ArchiveLayout.artifactDirectory(in: root, slug: "orphan")
        try FileManager.default.createDirectory(
            at: orphanDirectory, withIntermediateDirectories: true)
        try Data(GeneaLogicJSONCoding.encoder.encode(orphan)).write(
            to: orphanDirectory.appendingPathComponent(ArchiveLayout.recordFileName))

        // Without the marker, `open()` takes the "use as-is" branch and never
        // sees it — that is §10.4's still-open gap, asserted here so the two
        // cases stay visibly distinct.
        let unaware = try Archive.open(at: root)
        #expect(unaware.artifact(withID: orphan.uid) == nil)

        try IndexDirtyMarker.set(in: root)
        let reopened = try Archive.open(at: root)
        #expect(reopened.artifact(withID: orphan.uid)?.title == orphan.title)
        #expect(!IndexDirtyMarker.isSet(in: root))
    }

    /// **Review regression (47).** The sentinel was cleared unconditionally on
    /// success, so a *later* successful mutation erased the one an *earlier*
    /// failed mutation had left — and the divergence was then never rebuilt,
    /// which is precisely the hole fork (f) exists to close. The original unit
    /// test missed it by reopening with no intervening success.
    @Test func aLaterSuccessDoesNotEraseAnEarlierFailuresSentinel() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let saboteur = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        try saboteur.exec("DROP TABLE place;")
        #expect(throws: ArchiveError.self) {
            try archive.addArtifact(.sample(title: "Diverged"))
        }
        #expect(IndexDirtyMarker.isSet(in: root))

        // Repair the index behind the archive's back so the next mutation
        // succeeds — standing in for the ordinary case where the failure was
        // transient and the session simply carries on working.
        try saboteur.exec(
            "CREATE TABLE IF NOT EXISTS place (value TEXT NOT NULL, record_uid TEXT NOT NULL);")
        try archive.addArtifact(.sample(title: "Succeeded afterwards"))

        #expect(
            IndexDirtyMarker.isSet(in: root),
            "a successful mutation must not clear a divergence it did not resolve")

        let reopened = try Archive.open(at: root)
        #expect(!IndexDirtyMarker.isSet(in: root))
        #expect(reopened.artifacts(matching: ArtifactQuery(text: "Diverged")).count == 1)
        #expect(
            reopened.artifacts(matching: ArtifactQuery(text: "Succeeded afterwards")).count == 1)
    }

    /// **Review regression (47).** Recovering from a dirty sentinel used to
    /// `removeItem` the database first. That is fine for a corrupt file and
    /// actively harmful for a healthy one: another process holding a live
    /// connection keeps the unlinked inode, stops seeing new records, and its
    /// next mutation fails with "attempt to write a readonly database" *after*
    /// writing the sidecar — staying broken until relaunch. The dirty path must
    /// rebuild in place, leaving the inode alone.
    @Test func recoveringFromASentinelDoesNotBreakAnotherLiveHandle() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Before"))

        let dbURL = ArchiveLayout.indexDatabaseURL(in: root)
        let inodeBefore =
            try FileManager.default.attributesOfItem(atPath: dbURL.path)[
                .systemFileNumber] as? Int

        // A second handle, standing in for the app: open, and stays open.
        let live = try Archive.open(at: root)

        // Now force the recovery path on a perfectly healthy database.
        try IndexDirtyMarker.set(in: root)
        let recovered = try Archive.open(at: root)
        #expect(recovered.artifacts().count == 1)

        let inodeAfter =
            try FileManager.default.attributesOfItem(atPath: dbURL.path)[
                .systemFileNumber] as? Int
        #expect(inodeBefore == inodeAfter, "recovery replaced the database file")

        // The pre-existing handle must still be able to read AND write.
        #expect(live.artifacts().count == 1)
        try live.addArtifact(.sample(title: "After recovery"))
        #expect(live.artifacts().count == 2)
        #expect(try Archive.open(at: root).artifacts().count == 2)
    }

    // MARK: - Create is a mutation too

    /// `create`'s `alreadyExists` guard moved *inside* the archive lock (review
    /// finding, 47 — it used to run before the lockfile existed, so two
    /// concurrent creates both passed it and the second silently overwrote the
    /// first's `archiveUID`). This pins that the guard still works after the
    /// move; it is **not** the regression test for the race, which is inherently
    /// multi-process and lives in
    /// `GeneaLogicCLITests/ConcurrentWriterTests.concurrentCreatesProduceExactlyOneArchive`.
    @Test func aSecondCreateAtTheSamePathIsRejectedRatherThanOverwriting() throws {
        let root = TestSupport.makeTempDirectory().appendingPathComponent("New.genea")
        let first = try Archive.create(at: root, name: "First")
        let originalUID = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: ArchiveLayout.manifestURL(in: root))
        ).archiveUID

        #expect(throws: ArchiveError.self) {
            _ = try Archive.create(at: root, name: "Second")
        }

        let after = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        #expect(after.archiveUID == originalUID)
        #expect(after.name == "First")
        #expect(try first.verifyIntegrity().isClean)
    }

    // MARK: - The stale in-memory manifest (fork g)

    /// Fork (g): our in-memory `Manifest` is loaded once at `open()`. If another
    /// process renames the archive meanwhile, the next mutation's
    /// `commitManifest` would write our stale `name` straight back over theirs —
    /// a silent lost update in the one manifest field that isn't recomputed.
    ///
    /// The other process is simulated by rewriting `manifest.json` directly,
    /// which is precisely what it would do.
    @Test func aMutationPicksUpAnotherProcessesManifestRename() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root, name: "Original")
        try archive.addArtifact(.sample(title: "1920 Census"))

        let manifestURL = ArchiveLayout.manifestURL(in: root)
        var external = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: manifestURL))
        external.name = "Renamed by the other process"
        try Data(GeneaLogicJSONCoding.encoder.encode(external)).write(to: manifestURL)

        // A mutation on the handle that still remembers "Original".
        try archive.addArtifact(.sample(title: "1930 Census"))

        let after = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: manifestURL))
        #expect(after.name == "Renamed by the other process")
        // The same refresh reaches `verifyIntegrity()`, which is the reader
        // §10.5 names as the stale manifest's consumer.
        #expect(try archive.verifyIntegrity().isClean)
        // …and the mutation itself still landed, so this is a merge of the two
        // writers' changes rather than one of them winning wholesale.
        #expect(archive.artifacts(matching: ArtifactQuery(text: "1930 Census")).count == 1)
    }

    // MARK: - Helpers

    /// The `place` projection, read through a connection of our own so the
    /// assertion is about what is on disk rather than what some handle caches.
    private func indexPlaceStrings(in root: URL) throws -> [String] {
        try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root)).allPlaceStrings()
    }

    /// Titles read straight out of `artifacts/*/record.json` — the authoritative
    /// side, deliberately bypassing the index.
    private func artifactRecordTitles(in root: URL) throws -> [String] {
        let artifactsRoot = ArchiveLayout.artifactsDirectory(in: root)
        let directories = try FileManager.default.contentsOfDirectory(
            at: artifactsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return
            try directories
            .map { $0.appendingPathComponent(ArchiveLayout.recordFileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map {
                try GeneaLogicJSONCoding.decoder.decode(
                    Artifact.self, from: try Data(contentsOf: $0)
                ).title
            }
            .sorted()
    }
}

/// Counts how many threads are inside a region at once, and remembers whether
/// that ever exceeded one.
///
/// `Mutex` rather than a hand-rolled `NSLock` box: the state it guards is
/// unreachable except through `withLock`, so the conformance is *checked*
/// `Sendable` rather than `@unchecked` — the compiler enforces what a comment
/// would otherwise have to promise.
private final class ConcurrencyTracker: Sendable {
    private struct State {
        var inFlight = 0
        var sawOverlap = false
    }
    private let state = Mutex(State())

    func enter() {
        state.withLock {
            $0.inFlight += 1
            if $0.inFlight > 1 { $0.sawOverlap = true }
        }
    }

    func leave() {
        state.withLock { $0.inFlight -= 1 }
    }

    var sawOverlap: Bool {
        state.withLock { $0.sawOverlap }
    }
}

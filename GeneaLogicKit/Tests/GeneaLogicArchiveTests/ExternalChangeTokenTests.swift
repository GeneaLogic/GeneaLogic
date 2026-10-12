import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// Slice 51 — `Archive.externalChangeToken()`, the primitive that lets a
/// long-lived handle (the Mac app's open window) notice that another process
/// wrote to the archive.
///
/// Two `Archive` handles on one root are a faithful stand-in for two processes
/// here, because the property under test is *per-connection*: each handle owns
/// its own `sqlite3*`, and `PRAGMA data_version` is defined as "changed by
/// commits on other connections". Whether those connections live in one process
/// or two makes no difference to it.
@Suite struct ExternalChangeTokenTests {

    /// The half that makes the token usable at all: it must **not** move when we
    /// write. A token that ticked on our own commits would make every mutation
    /// look like someone else's and refresh the UI in a loop.
    @Test func ourOwnMutationsDoNotMoveTheToken() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let initial = archive.externalChangeToken()
        #expect(initial != nil)

        try archive.addArtifact(.sample(title: "Ours"))
        try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        #expect(archive.externalChangeToken() == initial)
    }

    /// The other half: another writer's commit must move it.
    @Test func anotherWritersCommitMovesTheToken() throws {
        let root = TestSupport.makeTempDirectory()
        let ours = try Archive.create(at: root)
        let theirs = try Archive.open(at: root)

        let before = ours.externalChangeToken()
        try theirs.addArtifact(.sample(title: "Theirs"))
        let after = ours.externalChangeToken()

        #expect(before != nil)
        #expect(after != before)
    }

    /// A conclusion-only write moves the token like any other commit.
    ///
    /// **This test used to prove more than it does now.** When slice 51 chose the
    /// `data_version` poll, a person add wrote no `manifest.json` at all, so the
    /// cheap alternative — watching the manifest's mtime — missed it *entirely*.
    /// Slice 49 put conclusion records in the manifest and closed that hole, so
    /// this case no longer decides between the two.
    ///
    /// What still does, and is why 51 is not revisited: the manifest's mtime moves
    /// when **we** write it, so an mtime poller re-fires on the app's own edits,
    /// while `data_version` bumps only on *other* connections' commits — that is
    /// what "exact" meant in 51's fork (a). And a commit that changes no tracked
    /// file still bumps it while leaving the manifest alone (an external
    /// `reindex`; see `ManifestCoverageTests`).
    @Test func aConclusionOnlyWriteMovesTheTokenToo() throws {
        let root = TestSupport.makeTempDirectory()
        let ours = try Archive.create(at: root)
        let theirs = try Archive.open(at: root)

        let before = ours.externalChangeToken()
        try theirs.addPerson(.sample(given: "Grace", surname: "Hopper"))

        #expect(ours.externalChangeToken() != before)
    }

    /// An external `reindex` moves the token and rewrites **no** manifest — the
    /// case that still separates `data_version` from a manifest-mtime watch now
    /// that slice 49 has closed the conclusion-write hole.
    ///
    /// 51 verified this by hand and recorded it in its spec; it is pinned here
    /// because it is now the argument, not a supporting observation.
    @Test func anExternalReindexMovesTheTokenWithoutTouchingTheManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let ours = try Archive.create(at: root)
        try ours.addArtifact(.sample(title: "Indexed"))
        let theirs = try Archive.open(at: root)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifestBefore =
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate]
            as? Date

        let before = ours.externalChangeToken()
        try theirs.rebuildIndex()

        #expect(ours.externalChangeToken() != before)
        #expect(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate]
                as? Date == manifestBefore)
    }

    /// The token is a *change* signal, not a version number: successive reads
    /// with nothing happening in between must compare equal, or a poller would
    /// refresh forever.
    @Test func repeatedReadsAreStableWhenNothingHappens() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Settled"))

        let readings = (0..<5).map { _ in archive.externalChangeToken() }
        // Non-nil first: mapping `nil` to a placeholder would let five failed
        // reads satisfy "stable", which is the opposite of what this pins
        // (review finding, 51).
        #expect(readings.allSatisfy { $0 != nil })
        #expect(Set(readings.compactMap { $0 }).count == 1)
    }

    /// Reads are what the poller does, and they must not take the archive lock —
    /// otherwise a 1s poll would contend with every write an agent makes, which
    /// is exactly the contention slice 47's fork (e) refused to introduce.
    /// The read must happen **while the lock is genuinely held** (review finding,
    /// 51 — the first version of this test let a mutation complete first, so it
    /// would have passed even if the accessor took the cross-process lock).
    /// Holding an `ArchiveLock` directly is what makes it real: a second
    /// descriptor on the same lockfile contends exactly as another process does.
    @Test func readingTheTokenDoesNotWaitOnTheArchiveLock() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Seeded"))
        // Long enough that a token read which took the lock would visibly hang
        // rather than quietly time out and look like a pass.
        archive.lockTimeout = 30

        let competitor = try ArchiveLock(at: ArchiveLayout.lockURL(in: root), archiveRoot: root)
        try competitor.withLock {
            #expect(archive.externalChangeToken() != nil)
        }
    }
}

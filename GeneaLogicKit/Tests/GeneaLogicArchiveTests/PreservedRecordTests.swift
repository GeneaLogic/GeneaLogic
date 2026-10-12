import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 58 (a)–(d) — a rebuild must not destroy what it couldn't read.
///
/// Since 55 a record whose sidecar won't decode is skipped, so no row goes back
/// into the index. That row was a *byte-identical copy of the file*, written by
/// the same deterministic encoder — and once the file is corrupt it is the only
/// surviving one. `Rebuild Index` deleted it, and so did `Archive.open` on a
/// dirty index, before the user was told anything was wrong.
@Suite struct PreservedRecordTests {

    /// The bytes GeneaLogic wrote for `record`, then `broken` in its place —
    /// returning what the preserved copy has to match.
    private func corrupt(_ record: URL, with junk: String = "{ not JSON") throws -> Data {
        let original = try Data(contentsOf: record)
        try Data(junk.utf8).write(to: record)
        return original
    }

    // MARK: - The copy survives, byte for byte

    /// The claim 59 is built on: what comes back is the file, not a summary of
    /// it. Anything less and a "restore" would be a regeneration.
    @Test func aRebuildKeepsTheRecordItCouldNotRead() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"

        let original = try corrupt(root.appendingPathComponent(path))
        #expect(try archive.rebuildIndex() == [path])

        let preserved = try #require(try archive.preservedRecord(atPath: path))
        #expect(preserved.json == original)
        #expect(preserved.uid == person.uid.raw)
        #expect(preserved.path == path)
    }

    /// An artifact's identity resolves through the `artifact` table's `slug`
    /// column, so its unreadable `record.json` needs no parsing either (fork a).
    @Test func anUnreadableArtifactRecordIsPreservedToo() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"

        let original = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()

        let preserved = try #require(try archive.preservedRecord(atPath: path))
        #expect(preserved.json == original)
        #expect(preserved.uid == artifact.uid.raw)
    }

    /// The other rebuild trigger, and the worse one: `Archive.open` rebuilds on a
    /// dirty index without anyone asking, so this ran *before* the user could be
    /// told there was damage.
    @Test func anOpenThatRebuildsOnADirtyIndexKeepsTheCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"

        let original = try corrupt(root.appendingPathComponent(path))
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        #expect(try reopened.standingFindings().unreadableRecords == [path])
        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
    }

    /// Rebuilds are not one-shot: the second one has no live row left to stage,
    /// so the copy has to be carried from the previous rebuild's own record of it.
    @Test func theCopySurvivesRepeatedRebuilds() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"

        let original = try corrupt(root.appendingPathComponent(path))
        for _ in 0..<3 {
            try archive.rebuildIndex()
            #expect(try archive.preservedRecord(atPath: path)?.json == original)
        }
    }

    // MARK: - And is reachable from nothing else (fork b)

    /// If a preserved record surfaced in a browse list, 55 and 56's whole story
    /// would invert: the user would see a phantom that looks healthy, for a file
    /// the archive cannot read.
    @Test func aPreservedRecordIsInNoQueryAndIsStillReportedAsUnreadable() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let broken = try archive.addPerson(.sample(given: "Ada", surname: "Broken"))
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Intact"))
        let path = "conclusions/persons/\(broken.uid.raw).json"

        _ = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()

        #expect(archive.persons().count == 1)
        #expect(archive.person(withID: broken.uid) == nil)
        #expect(try archive.standingFindings().unreadableRecords == [path])
        #expect(
            try archive.verifyIntegrity().issues.contains(
                .unreadableRecord(path: path, reason: .undecodable)))
        // Present, but only where it says what it is.
        #expect(try archive.preservedRecordPaths() == [path])
    }

    // MARK: - Lifetime (fork c)

    @Test func repairingTheSidecarDropsTheCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"
        let record = root.appendingPathComponent(path)

        let original = try corrupt(record)
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [path])

        try original.write(to: record)
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths().isEmpty)
        #expect(archive.persons().count == 1)
    }

    @Test func discardingIsExplicitAndDoesNotResurrectTheRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"

        _ = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()

        try archive.discardPreservedRecord(atPath: path)
        #expect(try archive.preservedRecordPaths().isEmpty)
        // Discarding the copy says nothing about the file, which is still there
        // and still unreadable.
        #expect(try archive.standingFindings().unreadableRecords == [path])
        // And a later rebuild does not bring it back — there is no live row to
        // stage from, which is the whole reason the copy mattered.
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths().isEmpty)
    }

    /// **A sidecar that is *gone* is skipped by the walk without ever being
    /// reported unreadable** (review finding, 58), so pruning against that list
    /// threw the copy away for the case that most needs it — a file deleted in
    /// Finder or dropped by a sync. The rule is "is this uid live again?".
    @Test func aVanishedSidecarKeepsItsCopyToo() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"
        let record = root.appendingPathComponent(path)

        let original = try Data(contentsOf: record)
        try FileManager.default.removeItem(at: record)
        try archive.rebuildIndex()

        #expect(archive.persons().isEmpty)
        // Nothing calls it unreadable — there is no file to fail to read.
        #expect(try archive.standingFindings().unreadableRecords.isEmpty)
        #expect(try archive.preservedRecord(atPath: path)?.json == original)
    }

    /// The other side of keying on the uid: a folder renamed out of band leaves
    /// the record live under a *new* path, so the copy staged against the old one
    /// must go. A path-keyed rule kept it — a "restorable" duplicate of a record
    /// that is perfectly healthy.
    @Test func aRenamedArtifactFolderLeavesNoPhantomCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)

        try FileManager.default.moveItem(
            at: root.appendingPathComponent("artifacts/\(slug)"),
            to: root.appendingPathComponent("artifacts/renamed-by-hand"))
        try archive.rebuildIndex()

        #expect(archive.artifacts().count == 1)
        #expect(try archive.preservedRecordPaths().isEmpty)
    }

    /// A record that has *never* decoded — a corrupt file dropped in from
    /// elsewhere — was never in the index, so there is nothing to keep. 59's
    /// button has to ask, not assume.
    @Test func aRecordThatNeverDecodedHasNoPreservedCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let path = "conclusions/persons/PER-never-decoded.json"
        try Data("{ garbage".utf8).write(to: root.appendingPathComponent(path))

        try archive.rebuildIndex()
        #expect(try archive.standingFindings().unreadableRecords == [path])
        #expect(try archive.preservedRecord(atPath: path) == nil)
    }

    /// Preservation is per-record, like the skip it follows.
    @Test func onlyTheUnreadableRecordsAreKept() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let broken = try archive.addPerson(.sample(given: "Ada", surname: "Broken"))
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Intact"))
        let artifact = try archive.addArtifact(.sample(title: "Deed"))
        _ = artifact

        _ = try corrupt(
            root.appendingPathComponent("conclusions/persons/\(broken.uid.raw).json"))
        try archive.rebuildIndex()

        #expect(
            try archive.preservedRecordPaths()
                == ["conclusions/persons/\(broken.uid.raw).json"])
    }
}

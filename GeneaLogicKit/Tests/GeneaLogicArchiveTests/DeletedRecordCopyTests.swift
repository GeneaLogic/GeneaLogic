import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 58c — a deleted record keeps no preserved copy.
///
/// A deletion that arrives from another machine takes the record's file away
/// without this machine's index being told, so the next rebuild kept its last
/// bytes in `orphaned_record` exactly as it keeps a sidecar lost in Finder — and
/// nothing ever pruned it, since its uid is never live again. On disk the two
/// look alike; the manifest tells them apart. These pin both halves: a deletion
/// leaves no copy, in either landing order, and a loss keeps its copy *and* its
/// manifest entry, which an unrelated write used to drop.
@Suite struct DeletedRecordCopyTests {

    /// The two machines: `mine`, open for the whole test, and `other`, a copy of
    /// it holding the same records under the same slugs and uids.
    private struct Pair {
        let mine: URL
        let other: URL
        let archive: Archive
    }

    private func makePair(_ populate: (Archive) throws -> Void) throws -> Pair {
        let mine = TestSupport.makeTempDirectory()
        try populate(try Archive.create(at: mine))
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: mine, to: other)
        return Pair(mine: mine, other: other, archive: try Archive.open(at: mine))
    }


    private func manifestPaths(_ root: URL) throws -> Set<String> {
        let manifest = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        return Set(manifest.files.map(\.path))
    }

    /// Rewrites `manifest.json` without `path` — what a commit that deleted it
    /// leaves, delivered or not.
    private func dropFromManifest(_ path: String, in root: URL) throws {
        let url = ArchiveLayout.manifestURL(in: root)
        var manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: Data(contentsOf: url))
        manifest.files.removeAll { $0.path == path }
        try GeneaLogicJSON.encoder.encode(manifest).write(to: url)
    }

    // MARK: - A delivered deletion leaves no copy

    /// A person removed on the other machine — unlinked, never trashed — in both
    /// landing orders. **File first** is the one that needs the prune to run over
    /// the whole table: a rebuild between the two halves stages the copy while
    /// the manifest still names the path, which is also the state a build before
    /// this slice left behind for good.
    @Test(arguments: [true, false])
    func aDeliveredPersonDeletionLeavesNoCopy(fileFirst: Bool) throws {
        var person: Person!
        let pair = try makePair { person = try $0.addPerson(.sample(given: "Ada", surname: "L")) }
        let path = "conclusions/persons/\(person.uid.raw).json"
        _ = try Archive.open(at: pair.other).removePerson(person.uid)

        if fileFirst {
            try TestSupport.deliverRemoval([path], to: pair.mine)
            try pair.archive.rebuildIndex()
            #expect(try pair.archive.preservedRecordPaths() == [path])
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
            try pair.archive.reconcileIfStale()
        } else {
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
            try pair.archive.reconcileIfStale()
            try TestSupport.deliverRemoval([path], to: pair.mine)
            try pair.archive.rebuildIndex()
        }

        #expect(try pair.archive.preservedRecordPaths().isEmpty)
        #expect(pair.archive.person(withID: person.uid) == nil)
    }

    /// The same for an artifact, whose folder goes to `.trash/` — and the name it
    /// held is free again: 58b reserved it for the copy, so a new artifact with the
    /// same title was given `-2` for good.
    @Test(arguments: [true, false])
    func aDeliveredArtifactDeletionLeavesNoCopyAndFreesTheName(fileFirst: Bool) throws {
        var artifact: Artifact!
        let pair = try makePair { artifact = try $0.addArtifact(.sample(title: "Letter")) }
        let slug = try #require(pair.archive.artifacts().first?.slug)
        let folder = "artifacts/\(slug)"
        _ = try Archive.open(at: pair.other).removeArtifact(artifact.uid)
        let trash = ".trash/\(artifact.uid.raw)"

        if fileFirst {
            try TestSupport.deliverRemoval([folder], to: pair.mine)
            try TestSupport.deliver([trash], from: pair.other, to: pair.mine)
            try pair.archive.rebuildIndex()
            #expect(try pair.archive.preservedRecordPaths() == ["\(folder)/record.json"])
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
            try pair.archive.reconcileIfStale()
        } else {
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
            try pair.archive.reconcileIfStale()
            try TestSupport.deliverRemoval([folder], to: pair.mine)
            try TestSupport.deliver([trash], from: pair.other, to: pair.mine)
            try pair.archive.rebuildIndex()
        }

        #expect(try pair.archive.preservedRecordPaths().isEmpty)
        let added = try pair.archive.addArtifact(.sample(title: "Letter"))
        #expect(pair.archive.artifacts().first { $0.uid == added.uid }?.slug == slug)
    }

    // MARK: - A loss keeps its copy

    /// A sidecar lost out of band keeps its copy through the rebuild that stages
    /// it, an unrelated write after that, and the rebuild after the write — and
    /// stays reported and repairable throughout. The write is the half that was
    /// already wrong before this slice: with a settled witness it read the lost
    /// record as deleted and dropped its manifest entry, so the `missingFile`
    /// finding vanished; under 58c's rule the copy would have followed it.
    @Test func aLostSidecarKeepsItsCopyThroughAnUnrelatedWrite() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [path])

        _ = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))

        #expect(try manifestPaths(root).contains(path))
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths() == [path])
        #expect(try archive.verifyIntegrity().issues.contains(.missingFile(path: path)))

        try archive.repairRecord(atPath: path)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
        #expect(archive.person(withID: person.uid) != nil)
    }

    /// A lost artifact sidecar keeps its payload's coverage too, as 55 does for an
    /// unreadable one (`/code-review`): the masters' entries are derived from a
    /// `record.json` that is not there, so without the carry the next write
    /// dropped them and rot in the masters went unreported until a repair.
    @Test func aLostArtifactSidecarKeepsItsPayloadCoveredThroughAWrite() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Census"))
        let attached = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "recto"),
            to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"
        let master = "artifacts/\(slug)/\(attached.entry.path)"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        _ = try archive.addArtifact(.sample(title: "Will"))
        try archive.rebuildIndex()

        #expect(try manifestPaths(root).isSuperset(of: [path, master]))
        #expect(try archive.preservedRecordPaths() == [path])
        try Data("rotted".utf8).write(to: root.appendingPathComponent(master))
        #expect(try archive.verifyIntegrity().issues.contains { $0.path == master })
    }

    /// A removal cut between its unlink and its manifest commit still ends in the
    /// deletion (`/code-review`). The dirty-marker rebuild stages a copy from the
    /// row the removal never dropped, and the manifest still names the path — so
    /// the carry would have kept the entry as an `interruptedWrite` that only
    /// `rebaseline()` clears. Under the sentinel the next write lets it go, as it
    /// did before this slice, and the rebuild after it prunes the copy. The
    /// journal is what says the removal was ours (slice 69, fork c).
    @Test func anInterruptedRemovalStillEndsInADeletion() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try IndexDirtyMarker.set(in: root)
        IndexDirtyMarker.journalRemoval(of: path, in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        let reopened = try Archive.open(at: root)
        #expect(reopened.interruptedWriteSuspected)

        _ = try reopened.addPerson(.sample(given: "Grace", surname: "Hopper"))

        #expect(try !manifestPaths(root).contains(path))
        try reopened.rebuildIndex()
        #expect(try reopened.preservedRecordPaths().isEmpty)
        #expect(try !reopened.verifyIntegrity().issues.contains { $0.path == path })
    }

    /// A lost record's copy, its entry already dropped from the manifest — the
    /// state a probe then has to answer for.
    private func lostArtifactUnnamed() throws -> (Archive, URL, folder: URL, path: String) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Census"))
        let slug = try #require(archive.artifacts().first?.slug)
        let folder = root.appendingPathComponent("artifacts/\(slug)")
        let path = "artifacts/\(slug)/record.json"
        try FileManager.default.removeItem(at: folder.appendingPathComponent("record.json"))
        try archive.rebuildIndex()
        try dropFromManifest(path, in: root)
        return (archive, root, folder, path)
    }

    /// A folder replaced by a plain file is an answer, not an error: `lstat`
    /// under it is `ENOTDIR`, and nothing can be there (second `/code-review`).
    /// Read as "cannot say", the copy was kept for good — invisible, and holding
    /// the slug, the leak this slice removes.
    @Test func aFolderReplacedByAFileStillPrunesTheCopy() throws {
        let (archive, _, folder, _) = try lostArtifactUnnamed()
        try FileManager.default.removeItem(at: folder)
        try Data("not a folder".utf8).write(to: folder)

        try archive.rebuildIndex()

        #expect(try archive.preservedRecordPaths().isEmpty)
    }

    /// A probe that really cannot answer keeps the copy, and does not fail the
    /// rebuild (`/code-review`): the prune runs inside its transaction, where a
    /// throw failed the open over a cleanup the walk itself tolerates. Not as
    /// root, which `EACCES` does not stop.
    @Test(.enabled(if: getuid() != 0))
    func aProbeThatCannotAnswerKeepsTheCopy() throws {
        let (archive, _, folder, path) = try lostArtifactUnnamed()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }

        try archive.rebuildIndex()

        #expect(try archive.preservedRecordPaths() == [path])
    }

    // MARK: - A crash does not cost an earlier loss its copy

    /// A loss that predates a crash survives the crash's recovery (second
    /// `/code-review`). The first fix stopped carrying *every* lost record while
    /// any interrupted write was unresolved, so one died write elsewhere cost a
    /// weeks-old loss its entry at the next edit and its copy at the next
    /// rebuild; and the recovery read that entry as the died write's residue.
    @Test(arguments: [true, false])
    func anEarlierLossSurvivesACrashsRecovery(divergedElsewhere: Bool) throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bystander = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))

        // The crash: a write to the bystander died with its manifest behind it,
        // or died before it diverged anything.
        if divergedElsewhere {
            let other = root.appendingPathComponent(
                "conclusions/persons/\(bystander.uid.raw).json")
            try (Data(contentsOf: other) + Data("\n".utf8)).write(to: other)
        }
        try IndexDirtyMarker.set(in: root)
        let reopened = try Archive.open(at: root)
        #expect(reopened.interruptedWriteSuspected == divergedElsewhere)

        _ = try reopened.addPerson(.sample(given: "Alan", surname: "Turing"))
        try reopened.rebuildIndex()

        #expect(try manifestPaths(root).contains(path))
        #expect(try reopened.preservedRecordPaths() == [path])
        let issues = try reopened.verifyIntegrity().issues
        #expect(issues.contains(.missingFile(path: path)))
        #expect(!issues.contains(.interruptedWrite(path: path)))
    }

    /// An unreadable file keeps its copy whatever the manifest says: a file that
    /// is *there* is damage, not a deletion.
    @Test func anUnreadableFileTheManifestDropsKeepsItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        try dropFromManifest(path, in: root)

        try archive.rebuildIndex()

        #expect(try archive.preservedRecordPaths() == [path])
    }

    // MARK: - Accept Current Contents

    /// *Accept Current Contents* keeps a lost record's entry, as it keeps an
    /// unreadable one's (second `/code-review`, reversing fork (c)): it is
    /// archive-wide, so blessing one unrelated hand edit cost every lost record
    /// its last copy at the next rebuild. Accepting a loss is discarding the copy
    /// — which drops the entry, and with it the finding.
    @Test func rebaselineKeepsALostRecordsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let edited = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        let handEdit = root.appendingPathComponent("conclusions/persons/\(edited.uid.raw).json")
        try (Data(contentsOf: handEdit) + Data("\n".utf8)).write(to: handEdit)

        try archive.rebaseline()
        try archive.rebuildIndex()

        #expect(try manifestPaths(root).contains(path))
        #expect(try archive.preservedRecordPaths() == [path])
        #expect(try archive.verifyIntegrity().issues == [.missingFile(path: path)])

        try archive.discardPreservedRecord(atPath: path)
        #expect(try !manifestPaths(root).contains(path))
        #expect(try archive.verifyIntegrity().isClean)
    }

    // MARK: - A write inside the delivery window

    /// A local write between a delivered deletion's two halves carries the
    /// record's entry — the copy is there and the manifest still names it — and
    /// that manifest can reach the deleting machine. It converges, whichever
    /// manifest the provider keeps: theirs is adopted here and the copy pruned;
    /// ours is dropped there by 50b's rule (the deleting machine recorded the
    /// removal) and the merge comes back. Pins `/code-review`'s concern that the
    /// carried entry would come back for good.
    @Test(arguments: [true, false])
    func aWriteInTheDeliveryWindowConverges(theirsWins: Bool) throws {
        var person: Person!
        let pair = try makePair { person = try $0.addPerson(.sample(given: "Ada", surname: "L")) }
        let path = "conclusions/persons/\(person.uid.raw).json"
        let otherArchive = try Archive.open(at: pair.other)
        _ = try otherArchive.removePerson(person.uid)
        try TestSupport.deliverRemoval([path], to: pair.mine)
        try pair.archive.rebuildIndex()
        _ = try pair.archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        #expect(try manifestPaths(pair.mine).contains(path))

        if theirsWins {
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
        } else {
            let grace = try #require(
                try manifestPaths(pair.mine).first { $0.hasPrefix("conclusions/persons/") && $0 != path })
            try TestSupport.deliver(["manifest.json", grace], from: pair.mine, to: pair.other)
            try otherArchive.reconcileIfStale()
            #expect(try !manifestPaths(pair.other).contains(path))
            try TestSupport.deliver(["manifest.json"], from: pair.other, to: pair.mine)
        }
        try pair.archive.reconcileIfStale()

        #expect(try !manifestPaths(pair.mine).contains(path))
        #expect(try pair.archive.preservedRecordPaths().isEmpty)
        #expect(try pair.archive.verifyIntegrity().isClean, "\((try? pair.archive.verifyIntegrity())?.issues)")
    }
}

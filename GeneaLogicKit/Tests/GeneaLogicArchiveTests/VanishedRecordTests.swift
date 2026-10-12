import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 58d — a vanished record can be restored.
///
/// A record whose file went (Finder, a sync) keeps its last bytes in the index
/// once a rebuild has run, and since 58c its manifest entry too — so 59's repair
/// could already put it back. Nothing said so: `StandingFindings` reported only
/// unreadable records. These pin `vanished` — which copies it names and which it
/// must not — the name a plan now carries, and the two ways out (restore, and
/// deleting it — undoably, by restoring it and deleting it the ordinary way).
@Suite struct VanishedRecordTests {

    private func personPath(_ person: Person) -> String {
        "conclusions/persons/\(person.uid.raw).json"
    }

    /// An archive with a person whose file was deleted out of band, after the
    /// rebuild that turned its live row into a preserved copy.
    private func vanishedPerson() throws -> (Archive, URL, Person, path: String) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = personPath(person)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        return (archive, root, person, path)
    }

    // MARK: - What `vanished` names

    @Test func aVanishedPersonIsNamedAndPlannedWithItsName() throws {
        let (archive, _, _, path) = try vanishedPerson()

        let findings = try archive.standingFindings()
        #expect(findings.vanished == [path])
        #expect(findings.unreadable.isEmpty)
        #expect(!findings.isEmpty)
        #expect(try archive.verifyIntegrity().issues.contains(.missingFile(path: path)))

        let plan = try #require(try archive.repairPlans(forRecordsAt: findings.vanished)[path])
        #expect(plan.recordLabel == "Ada Lovelace")
        #expect(plan.isDeletable)
        #expect(plan.isByteExact)
        #expect(!plan.replacesFileOnDisk)
        #expect(!plan.requiresExplicitAcceptance)
    }

    /// The whole folder gone, not just the sidecar — what deleting an artifact in
    /// Finder does. The record still comes back; the masters have no second copy.
    @Test func aVanishedArtifactFolderIsNamedByItsTitle() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"
        try FileManager.default.removeItem(at: root.appendingPathComponent("artifacts/\(slug)"))
        try archive.rebuildIndex()

        #expect(try archive.standingFindings().vanished == [path])
        #expect(try archive.repairPlan(forRecordAt: path)?.recordLabel == "Deed of Sale")

        try archive.repairRecord(atPath: path)
        #expect(archive.artifacts().map(\.slug) == [slug])
        #expect(try archive.standingFindings().vanished.isEmpty)
    }

    /// The kinds with no name of their own still vanish, and still plan — the
    /// label is the only thing they lack.
    @Test func aVanishedRelationshipHasAPlanButNoLabel() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let ada = try archive.addPerson(.sample(given: "Ada"))
        let byron = try archive.addPerson(.sample(given: "Byron"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: byron.uid, person2Uid: ada.uid))
        let path = "conclusions/relationships/\(relationship.uid.raw).json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        #expect(try archive.standingFindings().vanished == [path])
        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(plan.recordLabel == nil)
    }

    /// An unreadable record has a copy too, and is not vanished — its file is
    /// there. It gets the copy's name all the same, which 56's row never could.
    @Test func anUnreadableRecordIsNotVanishedButIsNamedFromItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        let path = personPath(person)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        let findings = try archive.standingFindings()
        #expect(findings.unreadableRecords == [path])
        #expect(findings.vanished.isEmpty)
        #expect(try archive.repairPlan(forRecordAt: path)?.recordLabel == "Grace Hopper")
    }

    /// A deletion delivered from another machine is not a loss: 58c prunes its
    /// copy, so there is nothing to name.
    @Test func aDeliveredDeletionIsNotVanished() throws {
        let mine = TestSupport.makeTempDirectory()
        let person = try Archive.create(at: mine).addPerson(.sample(given: "Ada"))
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: mine, to: other)
        let archive = try Archive.open(at: mine)
        _ = try Archive.open(at: other).removePerson(person.uid)

        try TestSupport.deliverRemoval([personPath(person)], to: mine)
        try archive.rebuildIndex()
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        try archive.reconcileIfStale()

        #expect(try archive.standingFindings().vanished.isEmpty)
    }

    /// A file a delivery in flight is bringing is *arriving*, not lost — even with
    /// a copy staged, as a provider that deletes before it writes leaves one. The
    /// same classification `verifyIntegrity()` makes.
    @Test func aFileADeliveryIsBringingIsNotVanished() throws {
        let mine = TestSupport.makeTempDirectory()
        let person = try Archive.create(at: mine).addPerson(.sample(given: "Ada"))
        let path = personPath(person)
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        try FileManager.default.copyItem(at: mine, to: other)
        let archive = try Archive.open(at: mine)
        _ = try Archive.open(at: other).updatePerson(person.uid) { $0.names[0].given = "Augusta" }

        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        try TestSupport.deliverRemoval([path], to: mine)
        try archive.rebuildIndex()

        #expect(try archive.verifyIntegrity().issues.contains(.awaitingDelivery(path: path)))
        #expect(try archive.standingFindings().vanished.isEmpty)
    }

    // MARK: - The two ways out

    @Test func restoringClearsTheFinding() throws {
        let (archive, root, person, path) = try vanishedPerson()

        try archive.repairRecord(atPath: path)

        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(archive.person(withID: person.uid) != nil)
        #expect(try archive.standingFindings().isEmpty)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// Delete goes through the ordinary deletion, so it comes back with the
    /// ordinary restore — the undo a host registers is the one it already has.
    @Test func deletingAMissingPersonIsUndoable() throws {
        let (archive, root, person, path) = try vanishedPerson()

        let deleted = try archive.deleteVanishedRecord(atPath: path)

        #expect(try archive.standingFindings().isEmpty)
        #expect(try archive.preservedRecordPaths().isEmpty)
        #expect(try archive.verifyIntegrity().isClean)
        #expect(archive.person(withID: person.uid) == nil)

        guard case .person(let removed) = deleted else {
            Issue.record("expected a person, got \(deleted)")
            return
        }
        try archive.restorePerson(removed)
        #expect(archive.person(withID: person.uid)?.displayName == "Ada Lovelace")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// An artifact goes to the Trash **with whatever is left in its folder** —
    /// the master the record lists and a file it doesn't. Nothing is stranded,
    /// which is why the first version's "files left" refusal is gone, and the
    /// trash entry brings it all back.
    @Test func deletingAMissingArtifactTrashesItsFolder() throws {
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
        try Data("verso".utf8).write(to: root.appendingPathComponent("artifacts/\(slug)/unlisted.jpg"))
        #expect(try archive.repairPlan(forRecordAt: path)?.isDeletable == true)

        let deleted = try archive.deleteVanishedRecord(atPath: path)

        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("artifacts/\(slug)").path))
        #expect(archive.trashedArtifacts().map(\.uid) == [artifact.uid])
        #expect(try archive.standingFindings().isEmpty)
        #expect(try archive.verifyIntegrity().isClean)

        guard case .artifact(let uid, let deletion) = deleted else {
            Issue.record("expected an artifact, got \(deleted)")
            return
        }
        #expect(uid == artifact.uid)
        try archive.restoreArtifact(deletion)
        #expect(archive.artifacts().map(\.uid) == [artifact.uid])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(master).path))
    }

    /// The kinds with no list delete and come back the same way.
    @Test func deletingAMissingRelationshipIsUndoable() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let ada = try archive.addPerson(.sample(given: "Ada"))
        let byron = try archive.addPerson(.sample(given: "Byron"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: byron.uid, person2Uid: ada.uid))
        let path = "conclusions/relationships/\(relationship.uid.raw).json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        guard case .relationship(let removed) = try archive.deleteVanishedRecord(atPath: path)
        else {
            Issue.record("expected a relationship")
            return
        }
        #expect(archive.relationship(withID: relationship.uid) == nil)
        #expect(try archive.verifyIntegrity().isClean)

        try archive.restoreRelationship(removed)
        #expect(archive.relationship(withID: relationship.uid) != nil)
    }

    /// The check runs under the write lock (`/code-review`): a file that comes
    /// back after a host's plan said "deletable" is refused, not deleted around.
    @Test func aFileThatCameBackIsNotDeleted() throws {
        let (archive, root, _, path) = try vanishedPerson()
        #expect(try archive.repairPlan(forRecordAt: path)?.isDeletable == true)

        try Data("{ not json".utf8).write(to: root.appendingPathComponent(path))

        #expect(throws: ArchiveError.recordNotMissing(path: path)) {
            try archive.deleteVanishedRecord(atPath: path)
        }
        #expect(try archive.preservedRecordPaths() == [path])
    }

    enum Blocker: CaseIterable { case file, danglingSymlink }
    enum WayOut: CaseIterable { case restore, delete }

    /// A folder replaced by something that isn't one: the record is gone
    /// (`isGone` reads ENOTDIR as gone), so it is listed and both ways out are
    /// offered — but nothing can be written there (slice 71). Each refuses
    /// naming what is in the way, before anything moves — a dangling symlink too
    /// (`/code-review`), which `fileExists` follows to nothing — and works once
    /// it is moved aside.
    @Test(arguments: Blocker.allCases, WayOut.allCases)
    func aFolderTakenByAFileIsNamedByBothWaysOut(blocker: Blocker, wayOut: WayOut) throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Census"))
        let slug = try #require(archive.artifacts().first?.slug)
        let folder = "artifacts/\(slug)"
        let folderURL = root.appendingPathComponent(folder)
        let path = "\(folder)/record.json"
        try archive.rebuildIndex()
        try FileManager.default.removeItem(at: folderURL)
        switch blocker {
        case .file:
            try Data("not a folder".utf8).write(to: folderURL)
        case .danglingSymlink:
            try FileManager.default.createSymbolicLink(
                atPath: folderURL.path, withDestinationPath: "nowhere")
        }
        try archive.rebuildIndex()

        #expect(try archive.standingFindings().vanished == [path])
        #expect(try archive.repairPlan(forRecordAt: path)?.isDeletable == true)
        let before = try TestSupport.snapshotOutsideIndex(root)

        let blocked = ArchiveError.recordPathBlocked(path: path, by: folder)
        #expect(throws: blocked) { try archive.repairRecord(atPath: path) }
        #expect(throws: blocked) { try archive.deleteVanishedRecord(atPath: path) }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
        #expect(try archive.preservedRecordPaths() == [path])

        try FileManager.default.moveItem(
            at: folderURL, to: root.appendingPathComponent("moved-aside"))
        switch wayOut {
        case .restore:
            try archive.repairRecord(atPath: path)
            #expect(archive.artifacts().map(\.uid) == [artifact.uid])
        case .delete:
            guard case .artifact(_, let deletion) = try archive.deleteVanishedRecord(atPath: path)
            else {
                Issue.record("expected an artifact")
                return
            }
            #expect(archive.trashedArtifacts().map(\.uid) == [artifact.uid])
            try archive.restoreArtifact(deletion)
            #expect(archive.artifacts().map(\.uid) == [artifact.uid])
        }
        #expect(try archive.standingFindings().vanished.isEmpty)
    }

    @Test func deletingWithNoCopyThrows() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let path = "conclusions/persons/PER-none.json"
        #expect(throws: ArchiveError.noPreservedCopy(path: path)) {
            try archive.deleteVanishedRecord(atPath: path)
        }
    }

    /// A removal cut between its unlink and its manifest commit is a deletion
    /// still finishing, not a loss: the recovery rebuild discards the copy of
    /// what the journal says was unlinked (58c; slice 69, fork c), so there is no
    /// "Missing record" row offering back a record the user deleted.
    @Test func aCutRemovalIsNotVanished() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada"))
        try IndexDirtyMarker.set(in: root)
        IndexDirtyMarker.journalRemoval(of: personPath(person), in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(personPath(person)))

        let reopened = try Archive.open(at: root)

        #expect(reopened.interruptedWriteSuspected)
        #expect(try reopened.standingFindings().vanished.isEmpty)
    }

    /// Delete is for a record that is gone; an unreadable one keeps its file.
    @Test func anUnreadableRecordIsNotDeletable() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Grace"))
        let path = personPath(person)
        try Data("{ not json".utf8).write(to: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        #expect(try archive.repairPlans(forRecordsAt: [path])[path]?.isDeletable == false)
        #expect(throws: ArchiveError.recordNotMissing(path: path)) {
            try archive.deleteVanishedRecord(atPath: path)
        }
    }
}

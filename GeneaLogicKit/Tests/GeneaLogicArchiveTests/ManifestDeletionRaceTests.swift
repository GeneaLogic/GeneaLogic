import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 50b — a deletion of yours is not a delivery.
///
/// The wedge slice 50 measured, one case over. Delete a record here while the
/// other machine writes anything at all, and the manifest the provider keeps
/// still names the record you deleted: that entry is in neither the settled
/// entries nor on disk, so 60c reads it as a delivery of a version that will
/// never arrive. Worse than 50's shape in one respect — every later mutation
/// carries the phantom entry forward, so the manifest permanently describes a
/// file that cannot exist and the deletion is undone in the bookkeeping.
///
/// These pin the drop rule, each of the three facts it turns on as its own
/// negative case (each one alone would be a silent withdrawal of a real
/// finding), and the direction a genuine delete-against-edit resolves in.
@Suite struct ManifestDeletionRaceTests {

    // MARK: - The rig

    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }


    private func manifest(at root: URL) throws -> Manifest {
        try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
    }

    private func addName(_ surname: String, to person: PersonID, in archive: Archive) throws {
        try archive.updatePerson(person) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: surname))
        }
    }

    private func path(of person: PersonID) -> String {
        "conclusions/persons/\(person.raw).json"
    }

    /// **The measured case.** Both machines hold two people; mine deletes one and
    /// other edits the other, so the manifest other then delivers still names the
    /// record mine removed — and the record other really changed arrives with it.
    private func stageTheDeletion() throws -> (
        mine: URL, other: URL, mineDeleted: PersonID, otherEdited: PersonID
    ) {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid
        let bob = try otherArchive.addPerson(.sample(given: "Ada", surname: "Bob")).uid

        let mine = try clone(other)
        let mineArchive = try Archive.open(at: mine)
        _ = try mineArchive.removePerson(alice)

        try addName("OTHER-EDIT", to: bob, in: otherArchive)

        try TestSupport.deliver(["manifest.json", path(of: bob)], from: other, to: mine)
        return (mine, other, alice, bob)
    }

    // MARK: - The defect

    /// The whole slice in one test: the deleted record's entry is dropped, the
    /// archive settles, and the record the other machine really sent is adopted.
    /// Before it, `verifyIntegrity()` reported `awaitingDelivery` on the deleted
    /// record for ever, with advice forbidding the one operation that would
    /// clear it.
    @Test func aDeletedRecordIsNotAwaitedForEver() throws {
        let staged = try stageTheDeletion()
        let archive = try Archive.open(at: staged.mine)

        #expect(try archive.verifyIntegrity().isClean, "the archive is wedged")
        #expect(!archive.deliveryIsInFlight, "nothing is arriving; the witness must settle")

        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(!files.contains(path(of: staged.mineDeleted)), "the deletion was undone")
        #expect(files.contains(path(of: staged.otherEdited)))

        let arrived = try #require(try archive.person(withID: staged.otherEdited))
        #expect(arrived.names.contains { $0.surname == "OTHER-EDIT" })
    }

    /// **The entry stays gone.** `awaitedPaths` carries a manifest entry with no
    /// file forward on every mutation — correctly, for a delivery — so a phantom
    /// one is not merely reported once: it is re-added for ever. This is the half
    /// of the defect that makes the deletion permanently un-makeable.
    @Test func aLaterMutationDoesNotResurrectThePhantomEntry() throws {
        let staged = try stageTheDeletion()
        let archive = try Archive.open(at: staged.mine)
        _ = try archive.addPerson(.sample(given: "Ada", surname: "Later"))

        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(!files.contains(path(of: staged.mineDeleted)))
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// **A delete loses to an edit** (fork c). If the other machine *edited* the
    /// record instead of merely holding it, its manifest names a version we never
    /// superseded, so nothing licenses dropping the entry: we keep theirs, wait,
    /// and the record comes back when it lands. The safe direction — and the
    /// deleted sidecar is in `.trash/` on either reading, so nothing is lost.
    @Test func aDeleteLosesToAnEditOfTheSameRecord() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid

        let mine = try clone(other)
        _ = try Archive.open(at: mine).removePerson(alice)
        try addName("THEIR-EDIT", to: alice, in: otherArchive)

        // The manifest reaches us before the record it describes, which is the
        // ordinary shape of a delivery.
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        let midFlight = try Archive.open(at: mine)
        #expect(midFlight.deliveryIsInFlight, "their edit is genuinely on its way")
        #expect(try manifest(at: mine).files.map(\.path).contains(path(of: alice)))

        try TestSupport.deliver([path(of: alice)], from: other, to: mine)
        let landed = try Archive.open(at: mine)
        #expect(try landed.verifyIntegrity().isClean)
        let restored = try #require(try landed.person(withID: alice))
        #expect(restored.names.contains { $0.surname == "THEIR-EDIT" })
    }

    /// Convergence, per 50 fork (d): the second reconcile of the same pair of
    /// manifests computes the same set and writes nothing.
    @Test func mergingADeletionASecondTimeChangesNothing() throws {
        let staged = try stageTheDeletion()
        _ = try Archive.open(at: staged.mine)

        let manifestURL = ArchiveLayout.manifestURL(in: staged.mine)
        let after = try Data(contentsOf: manifestURL)
        let stamp = try #require(ManifestWitness.stamp(of: manifestURL))

        _ = try Archive.open(at: staged.mine)
        #expect(try Data(contentsOf: manifestURL) == after)
        #expect(ManifestWitness.stamp(of: manifestURL) == stamp, "the file was rewritten")
    }

    // MARK: - The three facts, each as its own negative case

    /// **(i) Our settled entries must not name the path.** A record we had
    /// *edited* whose file is then deleted out of band satisfies the other two
    /// facts, and dropping its entry would quietly withdraw a real finding —
    /// taking away the one document that says the file is expected. It is
    /// `settled` that separates the two, and this is the test that says so.
    @Test func anOutOfBandDeletionOfAnEditedRecordIsStillReported() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid
        let bob = try otherArchive.addPerson(.sample(given: "Ada", surname: "Bob")).uid

        let mine = try clone(other)
        try addName("MY-EDIT", to: alice, in: try Archive.open(at: mine))
        try addName("OTHER-EDIT", to: bob, in: otherArchive)

        // Not a deletion the engine made: the file simply goes.
        try FileManager.default.removeItem(at: mine.appendingPathComponent(path(of: alice)))
        try TestSupport.deliver(["manifest.json", path(of: bob)], from: other, to: mine)

        let archive = try Archive.open(at: mine)
        #expect(
            try manifest(at: mine).files.map(\.path).contains(path(of: alice)),
            "the entry was silently withdrawn")
        #expect(try archive.verifyIntegrity().issues.contains { $0.path == path(of: alice) })
    }

    /// **(ii) The arriving entry must be one we superseded.** A record the other
    /// machine created, whose manifest arrived before the record did, is absent
    /// from our disk and from our settled entries for an entirely different
    /// reason — and it is genuinely on its way.
    @Test func aRecordOfTheirsThatHasNotLandedIsStillAwaited() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice"))

        let mine = try clone(other)
        // A local deletion of something else, so there *is* evidence on file —
        // the merge must not spend it on a path it says nothing about.
        let mineOnly = try Archive.open(at: mine)
            .addPerson(.sample(given: "Ada", surname: "Mine")).uid
        _ = try Archive.open(at: mine).removePerson(mineOnly)

        let theirs = try otherArchive.addPerson(.sample(given: "Ada", surname: "New")).uid
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)

        let archive = try Archive.open(at: mine)
        #expect(try manifest(at: mine).files.map(\.path).contains(path(of: theirs)))
        #expect(archive.deliveryIsInFlight)
        #expect(
            try archive.verifyIntegrity().issues.contains(.awaitingDelivery(path: path(of: theirs))))
    }

    /// **`settled` is not a record of what we deleted, and must not be read as
    /// one** (`/code-review`). It only moves when a mutation starts current or a
    /// delivery settles, so while one is stuck in flight it lags arbitrarily: a
    /// record created *and then edited* in that window is in `superseded` and has
    /// never been in `settled`. If its file is then lost out of band and an older
    /// manifest naming the superseded version arrives, an absence-based reading of
    /// fact (i) drops the entry and the loss goes unreported.
    @Test func aRecordLostWhileADeliveryIsStuckIsStillReported() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice"))
        let mine = try clone(other)
        _ = try Archive.open(at: mine)

        // A delivery that will not complete: their manifest names a record that
        // never arrives, so nothing on this machine settles again.
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Bob"))
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        let mineArchive = try Archive.open(at: mine)
        #expect(mineArchive.deliveryIsInFlight)

        // Local work in that window: created, then edited. Only the edit reaches
        // `superseded`, and `settled` has not moved since before either.
        let mineOnly = try mineArchive.addPerson(.sample(given: "Ada", surname: "Mine")).uid
        let theirOlderManifest = try Data(
            contentsOf: ArchiveLayout.manifestURL(in: mine))
        try addName("MY-EDIT", to: mineOnly, in: mineArchive)

        // The file is lost — nothing deleted it through the engine — and their
        // older manifest, which knows the record at the version we superseded,
        // arrives.
        try FileManager.default.removeItem(at: mine.appendingPathComponent(path(of: mineOnly)))
        try theirOlderManifest.write(to: ArchiveLayout.manifestURL(in: mine))

        let reopened = try Archive.open(at: mine)
        #expect(
            try manifest(at: mine).files.map(\.path).contains(path(of: mineOnly)),
            "the entry was silently withdrawn")
        #expect(try reopened.verifyIntegrity().issues.contains { $0.path == path(of: mineOnly) })
    }

    /// **A record that comes back is no longer one we removed.** The note is
    /// dropped when the path is authored again — otherwise a later loss of the
    /// *new* file would read as the old deletion and have its entry withdrawn.
    @Test func restoringARecordForgetsThatWeDeletedIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Alice"))
        let removed = try archive.removePerson(person.uid)

        let indexURL = ArchiveLayout.indexDatabaseURL(in: root)
        #expect(try ArchiveIndex.open(at: indexURL).deletedPaths().contains(path(of: person.uid)))

        try archive.restorePerson(removed)
        #expect(try ArchiveIndex.open(at: indexURL).deletedPaths().isEmpty)
    }

    // MARK: - An artifact is not decided one path at a time

    /// **The whole artifact goes, record and payload alike.** The rule is per
    /// path, so nothing about artifacts needs a special case when the deletion
    /// stands: both entries are dropped and the archive settles.
    @Test func deletingAnArtifactDropsItsRecordAndItsPayload() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let artifact = try otherArchive.addArtifact(.sample()).uid
        _ = try otherArchive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "bytes"),
            to: artifact, role: .preservationMaster)

        let mine = try clone(other)
        _ = try Archive.open(at: mine).removeArtifact(artifact)
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Elsewhere"))

        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        let archive = try Archive.open(at: mine)

        let files = try manifest(at: mine).files.map(\.path)
        #expect(!files.contains { $0.hasPrefix("artifacts/") }, "the artifact is still named")
        #expect(try archive.verifyIntegrity().issues.allSatisfy { !$0.path.hasPrefix("artifacts/") })
    }

    /// **But a payload whose record came back must come back with it**
    /// (hand-test). Delete an artifact here while the other machine edits it: *a
    /// delete loses to an edit* restores the record, and deciding the payload
    /// separately drops its entry as our deletion — leaving a record that lists a
    /// preservation master which is on no disk, in no manifest, and reported by
    /// nothing, its only copy in `.trash/`. Before this slice the same race
    /// wedged the archive and reported the file outstanding, which is noisy and
    /// honest; going quiet is the worse failure.
    @Test func aPayloadWhoseRecordSurvivedIsNotDropped() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let artifact = try otherArchive.addArtifact(.sample()).uid
        let file = try otherArchive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "bytes"),
            to: artifact, role: .preservationMaster)
        let payload = try #require(
            try manifest(at: other).files.map(\.path).first { $0.hasSuffix("scan.jpg") })

        let mine = try clone(other)
        _ = try Archive.open(at: mine).removeArtifact(artifact)
        _ = try otherArchive.updateMetadata(of: artifact) { $0.title = "EDITED ON OTHER" }

        // Their manifest and the record they edited arrive; the payload they
        // never touched does not, because they did not change it.
        let record = try #require(
            try manifest(at: other).files.map(\.path).first { $0.hasSuffix("record.json") })
        try TestSupport.deliver(["manifest.json", record], from: other, to: mine)

        let archive = try Archive.open(at: mine)
        let restored = try #require(try archive.artifact(withID: artifact))
        #expect(restored.title == "EDITED ON OTHER", "their edit should win")
        #expect(
            restored.files.contains { $0.uid == file.entry.uid },
            "the record still lists the file")

        #expect(
            try manifest(at: mine).files.map(\.path).contains(payload),
            "the record came back and its payload went unreported")
        #expect(try archive.verifyIntegrity().issues.contains { $0.path == payload })
    }

    // MARK: - What the evidence may and may not be armed by (`/code-review`)

    private func deletedPaths(in root: URL) throws -> Set<String> {
        try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root)).deletedPaths()
    }

    /// **Detaching a file from a *living* artifact must not let the coupling put
    /// its entry back.** The record was never deleted, so "its record survived"
    /// is trivially true — and un-dropping there restores an entry for a file
    /// that is in `.trash/`, listed by no record, and will never arrive: 50b's
    /// own wedge, one case over.
    @Test func detachingAFileFromALivingArtifactStillSettles() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let artifact = try otherArchive.addArtifact(.sample()).uid
        let file = try otherArchive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "bytes"),
            to: artifact, role: .preservationMaster)
        let payload = try #require(
            try manifest(at: other).files.map(\.path).first { $0.hasSuffix("scan.jpg") })

        let mine = try clone(other)
        _ = try Archive.open(at: mine).detachFile(file.entry.uid, in: artifact)
        let elsewhere = try otherArchive.addPerson(.sample(given: "Ada", surname: "Elsewhere")).uid

        try TestSupport.deliver(["manifest.json", path(of: elsewhere)], from: other, to: mine)
        let archive = try Archive.open(at: mine)

        #expect(
            !(try manifest(at: mine).files.map(\.path).contains(payload)),
            "the detached file's entry came back and will never arrive")
        #expect(!archive.deliveryIsInFlight, "the archive is wedged")
        #expect(try archive.verifyIntegrity().issues.allSatisfy { $0.path != payload })
    }

    /// **A path that merely *fell out* of the manifest is not a deletion.**
    ///
    /// **Honest about its status: this pins a rule, it does not reproduce a
    /// defect.** `/code-review` raised the gap — the note was taken from the
    /// manifest diff, which is a weaker claim than *we deleted this* — and no
    /// route was found where an entry leaves without a deliberate removal
    /// (`rebaseline` over a lost record keeps the entry; a lost payload keeps
    /// its entry too, since payload entries come from the index's file rows and
    /// not from disk). The gate went in anyway, because `deleted` is what
    /// licenses dropping an entry and what the artifact coupling now keys on, so
    /// it has to mean what it is named. This test passes with the gate removed.
    @Test func aLostRecordIsNotRecordedAsADeletion() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let lost = try archive.addPerson(.sample(given: "Ada", surname: "Alice")).uid
        try addName("EDITED", to: lost, in: archive)

        // Nobody deleted this — the file went, and a rebaseline accepted the disk.
        try FileManager.default.removeItem(at: root.appendingPathComponent(path(of: lost)))
        try archive.rebaseline()
        #expect(try !deletedPaths(in: root).contains(path(of: lost)), "armed by a loss")

        // And the mechanism is live in this archive, so the absence above is a
        // discrimination rather than nothing happening at all.
        let removed = try archive.addPerson(.sample(given: "Ada", surname: "Second")).uid
        _ = try archive.removePerson(removed)
        #expect(try deletedPaths(in: root).contains(path(of: removed)))
    }

    /// **A note is only meaningful while the path is absent.** When a delete
    /// loses to an edit the record comes back through the *merge*, not through a
    /// local write, so the local forget never fires — and the note would outlive
    /// the deletion for ever, arming the drop rule if that file were later lost.
    @Test func aRecordThatComesBackFromTheOtherMachineClearsItsNote() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid

        let mine = try clone(other)
        _ = try Archive.open(at: mine).removePerson(alice)
        try addName("THEIR-EDIT", to: alice, in: otherArchive)
        #expect(try deletedPaths(in: mine).contains(path(of: alice)))

        try TestSupport.deliver(["manifest.json", path(of: alice)], from: other, to: mine)
        _ = try Archive.open(at: mine)

        #expect(try !deletedPaths(in: mine).contains(path(of: alice)), "the note outlived it")
    }

    // MARK: - The rule itself

    /// A scratch directory holding one file per path, so the disk check has real
    /// bytes to answer from.
    private func stage(_ files: [String: String]) throws -> URL {
        let root = TestSupport.makeTempDirectory()
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    private func entry(_ path: String, _ contents: String) -> ManifestEntry {
        ManifestEntry(
            path: path, sha256: Checksum.sha256Hex(of: Data(contents.utf8)),
            byteLength: Int64(contents.utf8.count))
    }

    private static let deleted = "conclusions/persons/PER-1.json"
    private static let other = "conclusions/persons/PER-2.json"

    /// All three facts together: we superseded that version, our settled entries
    /// do not name the path, and nothing is there.
    @Test func anEntryWeSupersededByDeletingIsDropped() throws {
        let root = try stage([Self.other: "kept"])
        let gone = entry(Self.deleted, "as-deleted")
        let kept = entry(Self.other, "kept")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [gone, kept], settled: [Self.other: kept],
                superseded: [Self.deleted: [gone]], deleted: [Self.deleted], root: root))
        #expect(merged == [kept])
    }

    /// **(iii) Nothing may be there.** We deleted it and something put a file
    /// back — a restore from `.trash/`, a copy by hand. The entry stands and the
    /// ordinary checks speak for what is on disk.
    @Test func aDeletedPathWithAFileBackInPlaceIsLeftAlone() throws {
        let root = try stage([Self.deleted: "restored", Self.other: "kept"])
        let gone = entry(Self.deleted, "as-deleted")
        let kept = entry(Self.other, "kept")

        #expect(
            ManifestMerge.merge(
                delivered: [gone, kept], settled: [Self.other: kept],
                superseded: [Self.deleted: [gone]], deleted: [Self.deleted], root: root) == nil)
    }

    /// **A directory where a record belongs is not an absence.** It is something
    /// to report, and dropping the entry would take away the one document that
    /// says the file is expected — so only `stat(2)` failing outright reads as
    /// *deleted*.
    @Test func somethingThatIsNotAFileIsNotAnAbsence() throws {
        let root = try stage([Self.other: "kept"])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.deleted), withIntermediateDirectories: true)
        let gone = entry(Self.deleted, "as-deleted")
        let kept = entry(Self.other, "kept")

        #expect(
            ManifestMerge.merge(
                delivered: [gone, kept], settled: [Self.other: kept],
                superseded: [Self.deleted: [gone]], deleted: [Self.deleted], root: root) == nil)
    }

    /// **(i) restated as the positive fact it now is.** The same three-way
    /// picture with no deletion recorded — a file simply lost — leaves the entry
    /// alone, whatever `settled` happens to say. This is the unit-level form of
    /// `aRecordLostWhileADeliveryIsStuckIsStillReported`.
    @Test func anEntryWeSupersededButNeverDeletedIsNotDropped() throws {
        let root = try stage([Self.other: "kept"])
        let lost = entry(Self.deleted, "as-lost")
        let kept = entry(Self.other, "kept")

        #expect(
            ManifestMerge.merge(
                delivered: [lost, kept], settled: [Self.other: kept],
                superseded: [Self.deleted: [lost]], deleted: [], root: root) == nil)
    }

    /// **A dangling symlink is not an absence either.** `stat` follows it and
    /// fails `ENOENT`, so an absence test written on `stat` reads it as deleted —
    /// while something is plainly there to report. `lstat` sees the link.
    @Test func aDanglingSymlinkIsNotAnAbsence() throws {
        let root = try stage([Self.other: "kept"])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.deleted).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(Self.deleted),
            withDestinationURL: root.appendingPathComponent("nowhere.json"))
        let gone = entry(Self.deleted, "as-deleted")
        let kept = entry(Self.other, "kept")

        #expect(
            ManifestMerge.merge(
                delivered: [gone, kept], settled: [Self.other: kept],
                superseded: [Self.deleted: [gone]], deleted: [Self.deleted], root: root) == nil)
    }

    /// The coupling at unit level: the record survives, so the payload beside it
    /// is put back even though all three facts hold for it.
    @Test func aDroppedPayloadIsPutBackWhenItsRecordIsKept() throws {
        let root = try stage([Self.other: "kept"])
        let record = entry("artifacts/a-1/record.json", "theirs-edited")
        let payload = entry("artifacts/a-1/scan.jpg", "as-deleted")
        let elsewhere = entry(Self.other, "kept")

        #expect(
            ManifestMerge.merge(
                delivered: [record, payload, elsewhere], settled: [Self.other: elsewhere],
                superseded: ["artifacts/a-1/scan.jpg": [payload]],
                deleted: ["artifacts/a-1/record.json", "artifacts/a-1/scan.jpg"],
                root: root) == nil,
            "the payload's record survived, so nothing should change")
    }

    /// And the other direction: when the record is dropped too, the whole
    /// artifact goes. The coupling must not resurrect a deletion that stands.
    @Test func aPayloadGoesWhenItsRecordGoes() throws {
        let root = try stage([Self.other: "kept"])
        let record = entry("artifacts/a-1/record.json", "as-deleted")
        let payload = entry("artifacts/a-1/scan.jpg", "as-deleted")
        let elsewhere = entry(Self.other, "kept")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [record, payload, elsewhere], settled: [Self.other: elsewhere],
                superseded: [
                    "artifacts/a-1/record.json": [record], "artifacts/a-1/scan.jpg": [payload],
                ],
                deleted: ["artifacts/a-1/record.json", "artifacts/a-1/scan.jpg"], root: root))
        #expect(merged == [elsewhere])
    }

    /// The drop mints nothing and touches nothing else: the surviving entries are
    /// the ones that arrived, in the order the engine writes.
    @Test func droppingOneEntryLeavesTheRestExactlyAsDelivered() throws {
        let root = try stage(["b.json": "b", "c.json": "c"])
        let gone = entry("a.json", "as-deleted")
        let b = entry("b.json", "b")
        let c = entry("c.json", "c")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [c, gone, b], settled: ["b.json": b, "c.json": c],
                superseded: ["a.json": [gone]], deleted: ["a.json"], root: root))
        #expect(merged == [b, c])
    }
}

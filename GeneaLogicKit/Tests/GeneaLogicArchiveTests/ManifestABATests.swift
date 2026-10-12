import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// Slice 50e — a revert is not a stale manifest.
///
/// 50's merge keeps **our** entry when the arriving manifest names a version our own
/// writes replaced, reading that as *the sender never heard of our write*. A version
/// can recur — an undo writes the exact snapshot back — and when the sender's
/// manifest lands before its record, the merge decided against the very version
/// about to arrive, and nothing revisited it: the index served our edit for ever and
/// `verify` called the reverted record corrupt. The decision is now provisional,
/// noted, and reversed when the version it ruled against lands.
@Suite struct ManifestABATests {

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

    private func contests(in archive: Archive) -> [String: ContestedEntry] {
        archive.withIndex { (try? $0.contestedEntries()) ?? [:] }
    }

    private func personPath(_ id: PersonID) -> String { "conclusions/persons/\(id.raw).json" }

    /// **The measured case.** Mine edits a person; other takes the edit and undoes it,
    /// so its record is byte-for-byte the version mine replaced; other's manifest is
    /// delivered to mine, and its record is not — yet.
    private func stageARevertInFlight() throws -> (
        mine: URL, other: URL, person: Person, otherArchive: Archive
    ) {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let original = try otherArchive.addPerson(.sample(given: "Ada", surname: "Baseline"))

        let mine = try clone(other)
        _ = try Archive.open(at: mine).updatePerson(original.uid) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: "MY-EDIT"))
        }
        try TestSupport.deliver([personPath(original.uid), "manifest.json"], from: mine, to: other)
        try otherArchive.reconcileIfStale()
        try otherArchive.restorePerson(original)

        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        return (mine, other, original, otherArchive)
    }

    // MARK: - The defect

    /// The whole slice: the record lands after its manifest, and the revert is
    /// adopted — on the next open, with nothing else asked of anyone.
    @Test func aRevertIsAdoptedWhenItsRecordLands() throws {
        let staged = try stageARevertInFlight()
        let path = personPath(staged.person.uid)
        _ = try Archive.open(at: staged.mine)
        try TestSupport.deliver([path], from: staged.other, to: staged.mine)

        let archive = try Archive.open(at: staged.mine)
        #expect(archive.person(withID: staged.person.uid)?.names.count == 1)
        #expect(try archive.verifyIntegrity().isClean, "\((try? archive.verifyIntegrity())?.issues)")
        // Their entry, verbatim: nothing was minted from disk (49's rule).
        let theirs = try manifest(at: staged.other).files.first { $0.path == path }
        #expect(try manifest(at: staged.mine).files.first { $0.path == path } == theirs)
        #expect(contests(in: archive).isEmpty)
        // And the record is editable — the drift guard has nothing to refuse.
        _ = try archive.updatePerson(staged.person.uid) { $0.names[0].given = "Adah" }
    }

    /// **A window left open sees it too** (fork d): the app's poll, not just open.
    @Test func aLiveHandleAdoptsTheRevertOnItsNextPoll() throws {
        let staged = try stageARevertInFlight()
        let archive = try Archive.open(at: staged.mine)
        #expect(archive.person(withID: staged.person.uid)?.names.count == 2, "not landed yet")
        #expect(contests(in: archive).count == 1)
        #expect(try archive.reconcileIfStale() == false, "nothing has landed")

        try TestSupport.deliver([personPath(staged.person.uid)], from: staged.other, to: staged.mine)
        #expect(try archive.reconcileIfStale())
        #expect(archive.person(withID: staged.person.uid)?.names.count == 1)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// Record first was always right: the merge sees their bytes on disk and keeps
    /// theirs, so there is nothing to contest.
    @Test func recordFirstNeedsNoContest() throws {
        let staged = try stageARevertInFlight()
        try TestSupport.deliver([personPath(staged.person.uid)], from: staged.other, to: staged.mine)

        let archive = try Archive.open(at: staged.mine)
        #expect(archive.person(withID: staged.person.uid)?.names.count == 1)
        #expect(try archive.verifyIntegrity().isClean)
        #expect(contests(in: archive).isEmpty)
    }

    // MARK: - What must not change

    /// **50's own case is untouched.** Other never edited the record, so its
    /// record never lands: the contest stands, nothing is adopted, and our edit
    /// stays — through any number of polls and reopens.
    @Test func fiftysCaseKeepsOursAndAdoptsNothing() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid
        let bob = try otherArchive.addPerson(.sample(given: "Ada", surname: "Bob")).uid
        let aliceBefore = try Data(contentsOf: other.appendingPathComponent(personPath(alice)))
        let mine = try clone(other)
        _ = try Archive.open(at: mine).updatePerson(alice) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: "MY-EDIT"))
        }
        _ = try otherArchive.updatePerson(bob) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: "OTHER-EDIT"))
        }
        try TestSupport.deliver(["manifest.json", personPath(bob)], from: other, to: mine)

        let archive = try Archive.open(at: mine)
        #expect(contests(in: archive).keys.contains(personPath(alice)))
        #expect(try archive.reconcileIfStale() == false)
        let reopened = try Archive.open(at: mine)
        #expect(reopened.person(withID: alice)?.names.count == 2, "our edit survived")
        #expect(try reopened.verifyIntegrity().isClean)

        // Other catches up — its manifest, from elsewhere, names our version — and
        // the note goes.
        try TestSupport.deliver(["manifest.json", personPath(alice)], from: mine, to: other)
        try otherArchive.reconcileIfStale()
        _ = try otherArchive.updatePerson(bob) { $0.names[0].given = "Ada B." }
        try TestSupport.deliver(["manifest.json", personPath(bob)], from: other, to: mine)
        let caughtUp = try Archive.open(at: mine)
        #expect(caughtUp.person(withID: alice)?.names.count == 2)
        #expect(try caughtUp.verifyIntegrity().isClean)
        #expect(contests(in: caughtUp).isEmpty)

        // So the old bytes put back by hand, much later, are reported — 49's route
        // for a bare edit — never adopted (`/code-review`).
        try aliceBefore.write(to: mine.appendingPathComponent(personPath(alice)))
        #expect(try caughtUp.reconcileIfStale() == false)
        #expect(try !Archive.open(at: mine).verifyIntegrity().isClean)
    }

    /// **A payload never triggers a reversal on its own** (`/code-review`): its
    /// landing is answerable by size alone, and a same-length file of ours would
    /// read as theirs. Only a record, hashed, does — and carries its payload with it.
    @Test func aSameLengthPayloadDoesNotReverseTheMerge() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Scan"))
        let attached = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "ours!"),
            to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/\(attached.entry.path)"
        let ours = try #require(try manifest(at: root).files.first { $0.path == path })
        // A merge that kept ours over a same-length version of theirs.
        try archive.withIndex {
            try $0.noteContested([
                ContestedEntry(
                    theirs: ManifestEntry(
                        path: path, sha256: String(repeating: "a", count: 64),
                        byteLength: ours.byteLength),
                    ours: ours)
            ])
        }

        #expect(try archive.reconcileIfStale() == false)
        #expect(try manifest(at: root).files.first { $0.path == path } == ours)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// **A failed adoption backs off** (`/code-review`): its gate is not the
    /// witness, so 60's back-off never covered it, and every poll took the archive
    /// lock and failed again.
    @Test func aFailingAdoptionBacksOff() throws {
        guard getuid() != 0 else { return }  // root ignores the permission this uses
        let staged = try stageARevertInFlight()
        let archive = try Archive.open(at: staged.mine)
        try TestSupport.deliver([personPath(staged.person.uid)], from: staged.other, to: staged.mine)

        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: staged.mine.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.mine.path) }
        #expect(throws: (any Error).self) { try archive.reconcileIfStale() }
        #expect(try archive.reconcileIfStale() == false, "retried at once")
    }

    /// **The hand-test's case: the revert travels with another delivery.** Until
    /// everything lands the witness cannot settle, so every open re-merges the
    /// manifest this machine wrote — which names our version, and once read as the
    /// sender catching up, and the note went before the record could land.
    @Test func aRevertTravellingWithAnotherDeliveryIsStillAdopted() throws {
        let staged = try stageARevertInFlight()
        let newcomer = try staged.otherArchive.addPerson(.sample(given: "Newcomer"))
        try TestSupport.deliver(["manifest.json"], from: staged.other, to: staged.mine)

        for _ in 0..<3 { _ = try Archive.open(at: staged.mine) }
        try TestSupport.deliver(
            [personPath(staged.person.uid), personPath(newcomer.uid)], from: staged.other,
            to: staged.mine)

        let archive = try Archive.open(at: staged.mine)
        #expect(archive.person(withID: staged.person.uid)?.names.count == 1)
        #expect(archive.person(withID: newcomer.uid) != nil)
        #expect(try archive.verifyIntegrity().isClean, "\((try? archive.verifyIntegrity())?.issues)")
    }

    /// **A local write ends the contest** (fork c). Their version landing *after*
    /// our next edit is the provider keeping one side of a real conflict: reported,
    /// never adopted over the edit.
    @Test func aLocalWriteEndsTheContestSoALaterLandingIsReported() throws {
        let staged = try stageARevertInFlight()
        let archive = try Archive.open(at: staged.mine)
        _ = try archive.updatePerson(staged.person.uid) {
            $0.names.append(PersonName(type: .birth, given: "Ada", surname: "SECOND-EDIT"))
        }
        #expect(contests(in: archive).isEmpty)

        try TestSupport.deliver([personPath(staged.person.uid)], from: staged.other, to: staged.mine)
        let reopened = try Archive.open(at: staged.mine)
        #expect(try !reopened.verifyIntegrity().isClean, "the conflict went unreported")
        #expect(
            try manifest(at: staged.mine).files.first { $0.path == personPath(staged.person.uid) }
                != manifest(at: staged.other).files.first {
                    $0.path == personPath(staged.person.uid)
                })
    }

    /// **Nothing is laundered.** Rot in another record is still reported after an
    /// adoption, and a second reconcile writes nothing (fork d's convergence, 50's).
    @Test func adoptionLaundersNothingAndConverges() throws {
        let staged = try stageARevertInFlight()
        _ = try Archive.open(at: staged.mine)
        let bystander = try Archive.open(at: staged.mine).addPerson(.sample(given: "Bystander"))
        let rotted = staged.mine.appendingPathComponent(personPath(bystander.uid))
        try (Data(contentsOf: rotted) + Data(" ".utf8)).write(to: rotted)
        try TestSupport.deliver([personPath(staged.person.uid)], from: staged.other, to: staged.mine)

        let archive = try Archive.open(at: staged.mine)
        #expect(
            try archive.verifyIntegrity().issues.contains {
                if case .checksumMismatch(personPath(bystander.uid), _, _) = $0 { return true }
                return false
            })

        let manifestURL = ArchiveLayout.manifestURL(in: staged.mine)
        let bytes = try Data(contentsOf: manifestURL)
        #expect(try archive.reconcileIfStale() == false)
        _ = try Archive.open(at: staged.mine)
        #expect(try Data(contentsOf: manifestURL) == bytes)
    }

    // MARK: - The drop half (fork b)

    /// A record we deleted, restored from the trash on the other machine: byte for
    /// byte the version our deletion replaced. Its manifest lands first and 50b's
    /// rule drops the entry; when the folder lands, the drop is reversed and the
    /// artifact is visible again.
    @Test func aRestoreIsAdoptedWhenItsFolderLands() throws {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let artifact = try otherArchive.addArtifact(.sample(title: "Letter"))
        let slug = try #require(otherArchive.artifacts().first?.slug)
        let folder = "artifacts/\(slug)"
        let trashed = ".trash/\(artifact.uid.raw)"

        let mine = try clone(other)
        _ = try Archive.open(at: mine).removeArtifact(artifact.uid)

        // Other takes the deletion — the folder goes, the trash entry arrives —
        // and restores it.
        try FileManager.default.removeItem(at: other.appendingPathComponent(folder))
        try TestSupport.deliver([trashed, "manifest.json"], from: mine, to: other)
        try otherArchive.reconcileIfStale()
        // A deletion, not a loss: the delivered manifest has let the path go, so
        // the rebuild keeps no copy of it (slice 58c).
        #expect(try otherArchive.preservedRecordPaths().isEmpty)
        _ = try otherArchive.restoreFromTrash(artifact.uid)

        // Its manifest lands first; then the folder, and the trash entry's removal.
        try TestSupport.deliver(["manifest.json"], from: other, to: mine)
        let before = try Archive.open(at: mine)
        #expect(before.artifact(withID: artifact.uid) == nil)
        #expect(contests(in: before).keys.contains("\(folder)/record.json"))

        try TestSupport.deliver([folder], from: other, to: mine)
        try FileManager.default.removeItem(at: mine.appendingPathComponent(trashed))
        let after = try Archive.open(at: mine)
        #expect(after.artifact(withID: artifact.uid)?.title == "Letter")
        #expect(try after.verifyIntegrity().isClean, "\((try? after.verifyIntegrity())?.issues)")
        #expect(contests(in: after).isEmpty)
    }
}

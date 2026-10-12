import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 50 — the manifest survives two machines.
///
/// Two machines edit **different** records; both sidecars sync intact; the
/// archive wedges anyway, because both rewrote `manifest.json` and the provider
/// had to pick one. The surviving manifest names the pre-edit hash for a record
/// only the other machine edited, 60c reads that moved entry as a delivery, and
/// nothing will ever arrive to satisfy it — so the witness never settles, the
/// index is never reconciled, and every further edit to that record is refused
/// with advice that forbids the one operation that would clear it.
///
/// These pin the merge that resolves it, the rule it decides by, and the two
/// properties that let it run without a human: it **mints nothing**, and it
/// **writes nothing when it changes nothing**.
@Suite struct ManifestRaceTests {

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

    /// **The measured case.** Mine and other each edit a different person, both
    /// settle, and then the provider delivers *other's* manifest — which knows
    /// nothing of mine's edit — along with the record other really did change.
    private func stageTheRace() throws -> (
        mine: URL, other: URL, mineEdited: PersonID, otherEdited: PersonID,
        mineBeforeDelivery: [ManifestEntry]
    ) {
        let other = TestSupport.makeTempDirectory()
        let otherArchive = try Archive.create(at: other)
        let alice = try otherArchive.addPerson(.sample(given: "Ada", surname: "Alice")).uid
        let bob = try otherArchive.addPerson(.sample(given: "Ada", surname: "Bob")).uid

        let mine = try clone(other)
        let mineArchive = try Archive.open(at: mine)
        try addName("MY-EDIT", to: alice, in: mineArchive)

        try addName("OTHER-EDIT", to: bob, in: otherArchive)

        let mineBeforeDelivery = try manifest(at: mine).files
        try TestSupport.deliver(
            ["manifest.json", "conclusions/persons/\(bob.raw).json"], from: other, to: mine)
        return (mine, other, alice, bob, mineBeforeDelivery)
    }

    // MARK: - The defect

    /// The whole slice in one test: after the race, an open reconciles instead of
    /// wedging. Before it, `verifyIntegrity()` reported `awaitingDelivery` on
    /// mine's own record for ever and the archive never settled.
    @Test func aManifestRaceResolvesInsteadOfWedgingTheArchive() throws {
        let staged = try stageTheRace()
        let archive = try Archive.open(at: staged.mine)

        #expect(try archive.verifyIntegrity().isClean, "the archive is wedged")
        #expect(!archive.deliveryIsInFlight, "nothing is arriving; the witness must settle")

        let files = try manifest(at: staged.mine).files.map(\.path)
        #expect(files.contains("conclusions/persons/\(staged.mineEdited.raw).json"))
        #expect(files.contains("conclusions/persons/\(staged.otherEdited.raw).json"))
    }

    /// The consequence the user actually meets: the record that lost the race was
    /// **frozen against every further edit**, because the drift guard read it as
    /// a version still on its way in.
    @Test func theRecordThatLostTheRaceIsEditableAgain() throws {
        let staged = try stageTheRace()
        let archive = try Archive.open(at: staged.mine)
        try addName("AFTER-MERGE", to: staged.mineEdited, in: archive)

        let person = try #require(try archive.person(withID: staged.mineEdited))
        #expect(person.names.contains { $0.surname == "MY-EDIT" }, "our edit survived")
        #expect(person.names.contains { $0.surname == "AFTER-MERGE" })
    }

    /// **Both machines' edits are kept**, which is the point of merging rather
    /// than picking: the delivered record is adopted and ours is not reverted.
    @Test func bothMachinesEditsSurviveTheMerge() throws {
        let staged = try stageTheRace()
        let archive = try Archive.open(at: staged.mine)

        let mineEdited = try #require(try archive.person(withID: staged.mineEdited))
        let otherEdited = try #require(try archive.person(withID: staged.otherEdited))
        #expect(mineEdited.names.contains { $0.surname == "MY-EDIT" })
        #expect(otherEdited.names.contains { $0.surname == "OTHER-EDIT" })
    }

    // MARK: - Convergence (fork d)

    /// **A second reconcile writes nothing.** `merge` returning `nil` rather than
    /// an equal array is what stops two machines ping-ponging a rewrite each way,
    /// and what keeps a poll off the sync channel on an archive being read.
    @Test func mergingASecondTimeChangesNothing() throws {
        let staged = try stageTheRace()
        _ = try Archive.open(at: staged.mine)

        let manifestURL = ArchiveLayout.manifestURL(in: staged.mine)
        let after = try Data(contentsOf: manifestURL)
        let stamp = try #require(ManifestWitness.stamp(of: manifestURL))

        _ = try Archive.open(at: staged.mine)
        #expect(try Data(contentsOf: manifestURL) == after)
        #expect(ManifestWitness.stamp(of: manifestURL) == stamp, "the file was rewritten")
    }

    /// An archive nobody has raced is untouched by the merge — it is inert
    /// whenever the manifest and the settled entries agree, which is every open
    /// of every archive on one machine.
    @Test func anUncontestedArchiveIsNeverRewritten() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addPerson(.sample())

        let manifestURL = ArchiveLayout.manifestURL(in: root)
        let stamp = try #require(ManifestWitness.stamp(of: manifestURL))
        _ = try Archive.open(at: root)
        #expect(ManifestWitness.stamp(of: manifestURL) == stamp)
    }

    // MARK: - The laundering rule (slice 49 fork a)

    /// **The merge mints nothing.** Every entry it emits was authored at write
    /// time by one machine or the other — which is exactly what lets it run
    /// automatically where `rebaseline()` may not.
    @Test func everyMergedEntryCameFromAManifestAndNotFromDisk() throws {
        let staged = try stageTheRace()
        let delivered = try manifest(at: staged.other).files

        _ = try Archive.open(at: staged.mine)

        let authored = Set(delivered.map(\.sha256))
            .union(staged.mineBeforeDelivery.map(\.sha256))
        for entry in try manifest(at: staged.mine).files {
            #expect(authored.contains(entry.sha256), "\(entry.path) was re-hashed from disk")
        }
    }

    /// Rot that neither manifest ever described is still reported as damage after
    /// a merge — the regression that would say the merge had laundered it.
    @Test func damageIsStillDamageAfterAMerge() throws {
        let staged = try stageTheRace()
        let spec = "\(ArchiveLayout.schemaDirectoryName)/\(ArchiveLayout.schemaSpecFileName)"
        let url = staged.mine.appendingPathComponent(spec)
        try (Data(contentsOf: url) + Data("rot".utf8)).write(to: url)

        let archive = try Archive.open(at: staged.mine)
        let issues = try archive.verifyIntegrity().issues
        #expect(!issues.contains(.awaitingDelivery(path: spec)))
        #expect(
            issues.contains {
                switch $0 {
                case .checksumMismatch(let path, _, _): path == spec
                case .sizeMismatch(let path, _, _): path == spec
                default: false
                }
            })
    }

    // MARK: - The evidence, and its lifecycle

    private func superseded(in root: URL) throws -> [String: [ManifestEntry]] {
        try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root)).supersededFiles()
    }

    /// A local write notes the entry it replaced. Without that note the merge has
    /// nothing to tell a race from a delivery, and both read as a delivery.
    @Test func aLocalWriteNotesWhatItReplaced() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "First")).uid
        let path = "conclusions/persons/\(person.raw).json"
        let asCreated = try #require(try manifest(at: root).files.first { $0.path == path })

        try addName("SECOND", to: person, in: archive)
        #expect(try superseded(in: root)[path]?.contains(asCreated) == true)
    }

    /// **Every version a path has moved on from, not just the first.** A machine
    /// that edits one record several times must recognise a manifest naming *any*
    /// of them as behind it — keeping only the first covers offline editing and
    /// breaks the moment the two machines have exchanged anything (see
    /// `anIntermediateVersionIsRecognisedAsBehindUsToo`).
    @Test func everyVersionAPathHasMovedOnFromIsKept() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "First")).uid
        let path = "conclusions/persons/\(person.raw).json"
        let asCreated = try #require(try manifest(at: root).files.first { $0.path == path })

        try addName("SECOND", to: person, in: archive)
        let afterSecond = try #require(try manifest(at: root).files.first { $0.path == path })
        try addName("THIRD", to: person, in: archive)

        let held = try #require(try superseded(in: root)[path])
        #expect(held.contains(asCreated))
        #expect(held.contains(afterSecond))
    }

    /// **The second round, which keeping only the first predecessor got wrong**
    /// (`/code-review`). Once the other machine has adopted our E1 and written
    /// again, its manifest legitimately names E1 for our path — and if we have
    /// moved on to E2 in the meantime, that E1 has to be recognised as behind us
    /// exactly as E0 was. With only the first predecessor held, the merge took
    /// theirs, the manifest named a version the disk did not hold, and the
    /// archive wedged precisely as it did before the slice.
    @Test func anIntermediateVersionIsRecognisedAsBehindUsToo() throws {
        let staged = try stageTheRace()
        let path = "conclusions/persons/\(staged.mineEdited.raw).json"
        let mineArchive = try Archive.open(at: staged.mine)

        // Round one settles: the other machine takes our version of the record.
        try TestSupport.deliver(["manifest.json", path], from: staged.mine, to: staged.other)
        let otherArchive = try Archive.open(at: staged.other)

        // We move on again, while it writes something of its own — so its next
        // manifest names our *intermediate* version, not the one we started at.
        try addName("MY-SECOND-EDIT", to: staged.mineEdited, in: mineArchive)
        try addName("THEIRS-AGAIN", to: staged.otherEdited, in: otherArchive)
        try TestSupport.deliver(
            ["manifest.json", "conclusions/persons/\(staged.otherEdited.raw).json"],
            from: staged.other, to: staged.mine)

        let reopened = try Archive.open(at: staged.mine)
        #expect(try reopened.verifyIntegrity().isClean, "the archive wedged on the second round")
        #expect(!reopened.deliveryIsInFlight)
        try addName("STILL-EDITABLE", to: staged.mineEdited, in: reopened)
    }

    /// **Dropped when the sender catches up**, which its manifest naming our own
    /// entry is proof of. Otherwise the evidence only grows, and keeps claiming a
    /// local edit is unheard-of long after the other machine has taken it.
    @Test func evidenceIsDroppedOnceTheOtherMachineHasOurVersion() throws {
        let staged = try stageTheRace()
        let path = "conclusions/persons/\(staged.mineEdited.raw).json"
        _ = try Archive.open(at: staged.mine)
        #expect(try superseded(in: staged.mine)[path]?.isEmpty == false, "still unheard-of")

        // The other machine catches up — our record and the manifest naming it
        // reach it — and then writes again, so its next manifest carries our
        // entry for the raced path alongside a change of its own.
        try TestSupport.deliver(["manifest.json", path], from: staged.mine, to: staged.other)
        let otherArchive = try Archive.open(at: staged.other)
        try addName("AGAIN", to: staged.otherEdited, in: otherArchive)
        try TestSupport.deliver(
            ["manifest.json", "conclusions/persons/\(staged.otherEdited.raw).json"],
            from: staged.other, to: staged.mine)

        _ = try Archive.open(at: staged.mine)
        #expect(try superseded(in: staged.mine)[path] == nil)
    }

    // MARK: - The rule, case by case

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

    private static let authored = "conclusions/persons/PER-1.json"
    private static let payload = "artifacts/a-1/scan.jpg"

    /// **The race.** Their entry is exactly what our local write replaced, so
    /// their manifest cannot have heard about that write — and ours is ahead.
    @Test func anEntryWeAlreadySupersededMeansTheirManifestIsBehind() throws {
        let root = try stage([Self.authored: "ours-longer"])
        let ours = entry(Self.authored, "ours-longer")
        let base = entry(Self.authored, "base")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [base], settled: [Self.authored: ours],
                superseded: [Self.authored: [base]], deleted: [], root: root))
        #expect(merged == [ours])
    }

    /// **The delivery, which looks identical from the two manifests alone.** The
    /// disk holds the old version because the new one has not landed — and their
    /// entry is *not* what we superseded, so nothing licenses preferring ours.
    @Test func anEntryWeNeverSupersededIsARealDelivery() throws {
        let root = try stage([Self.authored: "ours"])
        let ours = entry(Self.authored, "ours")
        let theirs = entry(Self.authored, "theirs-new")

        #expect(
            ManifestMerge.merge(
                delivered: [theirs], settled: [Self.authored: ours],
                superseded: [Self.authored: [entry(Self.authored, "some-older-thing")]],
                deleted: [], root: root) == nil)
    }

    /// No evidence at all — a pre-50 index, one rebuilt since, or a machine that
    /// has changed nothing. The arriving manifest stands, exactly as before this
    /// slice.
    @Test func noSupersededEvidenceMeansNoMerge() throws {
        let root = try stage([Self.authored: "ours"])
        #expect(
            ManifestMerge.merge(
                delivered: [entry(Self.authored, "theirs")],
                settled: [Self.authored: entry(Self.authored, "ours")],
                superseded: [:], deleted: [], root: root) == nil)
    }

    /// The evidence is there, but the archive no longer holds the version it is
    /// evidence for: the merge must not assert a state that is not on disk.
    @Test func anAbsentFileIsNotOursToClaim() throws {
        let root = try stage([:])
        let ours = entry(Self.authored, "ours")
        let base = entry(Self.authored, "base")

        #expect(
            ManifestMerge.merge(
                delivered: [base], settled: [Self.authored: ours],
                superseded: [Self.authored: [base]], deleted: [], root: root) == nil)
    }

    /// Same for a file that has changed under us since we settled — that is
    /// damage or a bare hand edit, and neither is ours to speak for.
    @Test func aFileThatNoLongerMatchesOurEntryIsNotOursToClaim() throws {
        let root = try stage([Self.authored: "something-else-entirely"])
        let ours = entry(Self.authored, "ours")
        let base = entry(Self.authored, "base")

        #expect(
            ManifestMerge.merge(
                delivered: [base], settled: [Self.authored: ours],
                superseded: [Self.authored: [base]], deleted: [], root: root) == nil)
    }

    /// Same length, different bytes: the one case that costs a hash, and only for
    /// an engine-authored file — which is small, and local because we wrote it.
    @Test func aSameLengthDiskCheckIsSettledByHashingAnAuthoredFile() throws {
        let root = try stage([Self.authored: "xxxx"])
        let ours = entry(Self.authored, "aaaa")
        let base = entry(Self.authored, "bbbb")

        #expect(
            ManifestMerge.merge(
                delivered: [base], settled: [Self.authored: ours],
                superseded: [Self.authored: [base]], deleted: [], root: root) == nil,
            "same length is not the same bytes")
    }

    /// **A payload file is answered by `st_size` alone** — hashing a cloud
    /// placeholder materializes it (slice 57), so the merge declines to read one
    /// and leans on the superseded evidence it already has.
    @Test func aPayloadFileIsAnsweredBySizeAlone() throws {
        let root = try stage([Self.payload: "zzzz"])
        let ours = entry(Self.payload, "aaaa")
        let base = entry(Self.payload, "bb")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [base], settled: [Self.payload: ours],
                superseded: [Self.payload: [base]], deleted: [], root: root))
        #expect(merged == [ours])
    }

    /// **A path their manifest does not name is left alone** (slice 49 fork f).
    /// Restoring it cannot be told from a manifest legitimately rolled back by
    /// hand, and an absent entry means *unverified*, never *tampered* — the next
    /// mutation mints it.
    @Test func aPathTheirManifestDoesNotNameIsLeftAlone() throws {
        let root = try stage([Self.authored: "ours"])
        let ours = entry(Self.authored, "ours")

        #expect(
            ManifestMerge.merge(
                delivered: [], settled: [Self.authored: ours],
                superseded: [Self.authored: [entry(Self.authored, "base")]], deleted: [],
                root: root) == nil)
    }

    /// The merged list is sorted by path — the order `recomputeManifestFiles`
    /// already emits, so a merged manifest and an engine-written one agree and
    /// the order-sensitive witness digest does not move for ordering alone.
    @Test func theMergedListIsInTheSameOrderTheEngineWrites() throws {
        let root = try stage(["a.json": "a-ours", "b.json": "b"])
        let ours = entry("a.json", "a-ours")
        let base = entry("a.json", "a")
        let b = entry("b.json", "b")

        let merged = try #require(
            ManifestMerge.merge(
                delivered: [b, base], settled: ["a.json": ours, "b.json": b],
                superseded: ["a.json": [base]], deleted: [], root: root))
        #expect(merged.map(\.path) == ["a.json", "b.json"])
    }
}

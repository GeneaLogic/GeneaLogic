import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 60b — a first open must not certify what it hasn't seen.
///
/// Slice 60 recorded a witness unconditionally when there was none, so that a
/// fault in a pre-60 archive still reported as the damage it is. But *no
/// previous state to differ from* is not *this state is complete*, and on a
/// first open with no `.index/` part-way through a delivery the two come apart:
/// the witness certified files nobody had seen, `manifest.json` never moved
/// again, nothing re-fired, and `verifyIntegrity()` called the archive healthy
/// while a delivered record stayed invisible to every query.
///
/// The state is reachable from any copy, restore or `rsync` that drops
/// `.index/`. These pin the fix and, just as importantly, the two things it must
/// not break on the way past: the manifest entries of files that have not
/// arrived, and the original exception's purpose.
@Suite struct FreshIndexWitnessTests {

    /// A second archive holding the same records, standing in for the other
    /// machine. Copied rather than rebuilt so the slugs and uids match.
    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }


    /// The receiving machine's copy: the same archive, arrived **without an
    /// index**, with the other machine's manifest delivered ahead of the record
    /// it describes.
    private func makeFreshIndexMidDelivery() throws -> (
        receiver: URL, source: URL, sourceArchive: Archive, person: PersonID, path: String
    ) {
        let source = TestSupport.makeTempDirectory()
        let sourceArchive = try Archive.create(at: source)
        _ = try sourceArchive.addArtifact(.sample(title: "Shared"))

        let receiver = try clone(source)
        try FileManager.default.removeItem(at: ArchiveLayout.indexDirectory(in: receiver))

        let person = try sourceArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try TestSupport.deliver(["manifest.json"], from: source, to: receiver)

        return (receiver, source, sourceArchive, person.uid, path)
    }

    // MARK: - The defect

    /// **The scenario, exactly as it was reproduced.** It fails before this
    /// slice: the first open blesses a half-delivered state, and because
    /// `manifest.json` never changes again, no later open ever looks.
    @Test func aFirstOpenMidDeliveryDoesNotCertifyWhatItHasNotSeen() throws {
        let (receiver, source, _, person, path) = try makeFreshIndexMidDelivery()

        // First open builds the index from what is there — which is not
        // everything the manifest names.
        do {
            let first = try Archive.open(at: receiver)
            #expect(first.person(withID: person) == nil)
        }

        try TestSupport.deliver([path], from: source, to: receiver)

        // No explicit `rebuildIndex()`: the archive has to notice on its own.
        let second = try Archive.open(at: receiver)
        #expect(
            second.person(withID: person) != nil,
            "the delivered record is still invisible — the first open certified it unseen")
        #expect(try second.verifyIntegrity().isClean)
    }

    /// The same, through a live handle rather than a reopen — `reconcileIfStale()`
    /// is the other door into the state.
    @Test func aLiveHandleOnAFreshIndexAlsoConverges() throws {
        let (receiver, source, _, person, path) = try makeFreshIndexMidDelivery()

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        #expect(archive.person(withID: person) == nil)

        try TestSupport.deliver([path], from: source, to: receiver)
        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.person(withID: person) != nil)
        #expect(try archive.reconcileIfStale() == false)
    }

    // MARK: - The regression the naive fix causes

    /// **60's manifest-scrubbing data loss, re-run through the unknown door.**
    /// `awaitedPaths` is the one consumer where a false *not*-arriving destroys
    /// rather than misleads: the manifest is the only document that says an
    /// un-arrived file is expected, so a three-state split that mapped only
    /// `.disagrees` to "in flight" would let one unrelated mutation delete the
    /// entry and lose the record for good when it lands.
    @Test func anUnrelatedEditOnAFreshIndexKeepsTheUnArrivedEntry() throws {
        let (receiver, source, _, person, path) = try makeFreshIndexMidDelivery()

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        _ = try archive.addArtifact(.sample(title: "Something else entirely"))

        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: receiver)))
        #expect(
            manifest.files.contains { $0.path == path },
            "the local edit deleted the un-arrived record's manifest entry")

        // And the archive still converges when the record finally lands.
        try TestSupport.deliver([path], from: source, to: receiver)
        _ = try archive.reconcileIfStale()
        #expect(archive.person(withID: person) != nil)
    }

    // MARK: - What the removed exception was protecting

    /// **Damage on an archive with no witness still reports as damage.** This is
    /// the assertion that stops the defect being "solved" by making unknown mean
    /// *arriving*: with no history there is no evidence anything is on its way,
    /// and saying so would tell the user to wait for a file that will never come.
    @Test func damageOnAnArchiveWithNoWitnessIsStillDamage() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Shared"))

        // The archive's own copy of the spec — in the manifest, and not a record,
        // so the finding is about integrity alone. Lengthened rather than
        // rewritten in place, so the delivery-completeness check fails too and
        // the state really is `.unknown` rather than a settled `.matches`.
        let spec = "\(ArchiveLayout.schemaDirectoryName)/\(ArchiveLayout.schemaSpecFileName)"
        let specURL = root.appendingPathComponent(spec)
        try (Data(contentsOf: specURL) + Data("rot".utf8)).write(to: specURL)
        try FileManager.default.removeItem(at: ArchiveLayout.indexDirectory(in: root))

        let fresh = try Archive.open(at: root)
        #expect(fresh.deliveryIsInFlight == false)

        let report = try fresh.verifyIntegrity()
        #expect(!report.issues.contains(.awaitingDelivery(path: spec)))
        #expect(
            report.issues.contains {
                switch $0 {
                case .sizeMismatch(let p, _, _), .checksumMismatch(let p, _, _): p == spec
                default: false
                }
            })
    }

    /// **Fork (c): under unknown the drift guard tells the truth instead of
    /// picking a side.** Accepting the current contents would discard an incoming
    /// version; waiting would promise an arrival this state cannot evidence.
    @Test func theDriftGuardSaysItCannotTellWithoutHistory() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"

        // A hand edit that leaves valid JSON and a different length, so the
        // fresh index cannot settle a witness over it.
        let recordURL = root.appendingPathComponent(path)
        let edited = try String(contentsOf: recordURL, encoding: .utf8)
            .replacingOccurrences(of: "\"Before\"", with: "\"Before, edited by hand\"")
        try edited.write(to: recordURL, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: ArchiveLayout.indexDirectory(in: root))

        let fresh = try Archive.open(at: root)
        #expect(throws: ArchiveError.recordDriftedWithNoHistory(path: path)) {
            _ = try fresh.updateMetadata(of: artifact.uid) { $0.title = "Local" }
        }
    }

    // MARK: - Deleting while unsettled

    /// **A deletion is not a file that has not arrived, and mistaking one for the
    /// other poisons the manifest permanently** (`/code-review`).
    ///
    /// `awaitedPaths` reads "the index no longer names this path" as *still in
    /// flight*, which is only sound for a path nobody asked to delete. Carry a
    /// deleted record's entry forward once and it names a file that will never
    /// exist: completeness is false for ever, the witness can never settle, every
    /// later mutation carries it again, and `verifyIntegrity()` reports a missing
    /// file on every open — with `deliveryIsInFlight` false, so no surface
    /// explains it. 60b is what routes every index-less archive through here.
    @Test func aDeletionWhileUnsettledDoesNotHauntTheManifest() throws {
        let (receiver, source, _, person, path) = try makeFreshIndexMidDelivery()

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        let doomed = try #require(archive.artifacts().first?.uid)
        let doomedRecord = "artifacts/\(try #require(archive.artifacts().first?.slug))/record.json"
        _ = try archive.removeArtifact(doomed)

        try TestSupport.deliver([path], from: source, to: receiver)
        _ = try archive.reconcileIfStale()

        // The delivery settles, and nothing is left claiming the deleted record.
        #expect(archive.person(withID: person) != nil)
        #expect(try !archive.verifyIntegrity().issues.contains(.missingFile(path: doomedRecord)))
        #expect(try Archive.open(at: receiver).verifyIntegrity().isClean)
    }

    /// The same for a conclusion, which leaves by `removeAuthoredFile` rather
    /// than by the rename into `.trash/` that an artifact folder takes — the two
    /// removal shapes the chokepoint has to cover between them.
    @Test func aDeletedConclusionWhileUnsettledLeavesNoEntryBehind() throws {
        let (receiver, source, _, person, path) = try makeFreshIndexMidDelivery()

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        let local = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        let localPath = "conclusions/persons/\(local.uid.raw).json"
        _ = try archive.removePerson(local.uid)

        try TestSupport.deliver([path], from: source, to: receiver)
        _ = try archive.reconcileIfStale()

        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: receiver)))
        #expect(!manifest.files.contains { $0.path == localPath })
        #expect(archive.person(withID: person) != nil)
        #expect(try Archive.open(at: receiver).verifyIntegrity().isClean)
    }

    /// And the delivery's own un-arrived entry is still protected — the deletion
    /// filter must not become a second route to 60's manifest scrubbing.
    @Test func filteringDeletionsStillLeavesAnUnArrivedEntryAlone() throws {
        let (receiver, _, _, _, path) = try makeFreshIndexMidDelivery()

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        let local = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        _ = try archive.removePerson(local.uid)

        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: receiver)))
        #expect(manifest.files.contains { $0.path == path })
    }

    // MARK: - `.unknown` means no witness, and nothing wider

    /// **An unreadable `manifest.json` is not an archive with no history**
    /// (`/code-review`). A settled witness is history; only the comparison is
    /// unavailable. Saying otherwise would have the drift guard tell the user
    /// "this copy of the archive has no history yet" about an archive that has
    /// been settling deliveries all along — the class of false claim this slice
    /// exists to remove.
    @Test func anUnreadableManifestIsNotAnArchiveWithoutHistory() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"

        // Drift on the record, so the guard has something to refuse.
        let recordURL = root.appendingPathComponent(path)
        let edited = try String(contentsOf: recordURL, encoding: .utf8)
            .replacingOccurrences(of: "\"Before\"", with: "\"Before, edited by hand\"")
        try edited.write(to: recordURL, atomically: true, encoding: .utf8)

        // And a manifest that no longer decodes — what a non-atomic outside
        // writer leaves behind mid-write.
        try Data("{ not a manifest".utf8).write(to: ArchiveLayout.manifestURL(in: root))

        #expect(throws: ArchiveError.recordAwaitingDelivery(path: path)) {
            _ = try archive.updateMetadata(of: artifact.uid) { $0.title = "Local" }
        }
        #expect(archive.deliveryIsInFlight)
    }

    // MARK: - What it costs, and where it stops

    /// **Fork (e)'s cost is bounded.** Not recording a witness makes a damaged
    /// archive re-walk on every open — but only one whose files are the *wrong
    /// size*. An intact archive that merely lost its index settles on its first
    /// open and never walks again, which is the pre-60 upgrade path and by far
    /// the common case.
    @Test func anIntactArchiveWithNoIndexSettlesOnItsFirstOpen() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Shared"))
        try FileManager.default.removeItem(at: ArchiveLayout.indexDirectory(in: root))

        let first = try Archive.open(at: root)
        #expect(first.deliveryIsInFlight == false)
        #expect(try first.verifyIntegrity().isClean)

        // A row that exists only in the index: any rebuild walks the sidecars and
        // clears it, so its survival is a positive answer to "did a rebuild
        // happen?" — which a correctness-only assertion cannot give.
        let planted = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        let phantom = Person(
            uid: PersonID(UUIDv7.generate()),
            names: [],
            provenance: Provenance(
                createdBy: .human,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                reviewStatus: .asserted))
        try planted.upsert(phantom)

        for _ in 0..<3 { _ = try Archive.open(at: root) }
        let after = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        #expect(try after.person(phantom.uid) != nil, "a settled archive rebuilt anyway")
    }
}

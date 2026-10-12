import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 60c — a delivery in flight must not speak for damage it did not cause.
///
/// The in-flight flag is archive-wide: slice 60 documents that it says a
/// delivery is in flight, never which files it covers. So while one was in
/// flight **every** mismatch was relabelled `.awaitingDelivery`, including damage
/// that had nothing to do with it — `genea verify` told the user to wait for a
/// file that will never arrive, the standing damage banner went quiet for the
/// duration, and a dismissal they had already made was reset when it came back.
///
/// These pin the per-entry question that replaces it, and the two directions it
/// must not overshoot: a file the delivery really is bringing still reports as
/// arriving, and an index with no per-entry history falls back to slice 60's
/// coarse answer rather than to a fresh accusation of damage.
@Suite struct DeliveryScopeTests {

    /// A second archive holding the same records, standing in for the other
    /// machine. Copied rather than rebuilt so the slugs and uids match — and
    /// **with its `.index/`**, unlike 60b's, because the state under test here is
    /// an archive that has settled before.
    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }


    /// The archive's own copy of the schema spec: tracked by the manifest, and
    /// **not a record**, so damaging it is a finding about integrity alone and
    /// perturbs no index walk. Standing in for the rotted JPEG the slice was
    /// measured on.
    private static let bystander =
        "\(ArchiveLayout.schemaDirectoryName)/\(ArchiveLayout.schemaSpecFileName)"

    /// Rots `bystander` in place — lengthened rather than rewritten, so the
    /// cheap `st_size` sweep sees it too.
    private func rotBystander(in root: URL) throws {
        let url = root.appendingPathComponent(Self.bystander)
        try (Data(contentsOf: url) + Data("rot".utf8)).write(to: url)
    }

    /// A receiver that **has settled before** — index and witness intact — now
    /// part-way through a delivery: the other machine's manifest has landed and
    /// the record it names has not.
    private func makeSettledReceiverMidDelivery() throws -> (
        receiver: URL, source: URL, sourceArchive: Archive, person: PersonID, delivered: String
    ) {
        let source = TestSupport.makeTempDirectory()
        let sourceArchive = try Archive.create(at: source)
        _ = try sourceArchive.addArtifact(.sample(title: "Shared"))

        let receiver = try clone(source)

        let person = try sourceArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let delivered = "conclusions/persons/\(person.uid.raw).json"
        try TestSupport.deliver(["manifest.json"], from: source, to: receiver)

        return (receiver, source, sourceArchive, person.uid, delivered)
    }

    // MARK: - The defect

    /// **The rotted-JPEG case, exactly as it was measured.** Damage that predates
    /// the delivery keeps reporting as damage while that delivery is in flight,
    /// and the file that really is arriving still reports as arriving.
    ///
    /// Before this slice both lines read `awaiting-delivery`, so the report told
    /// the user to wait for a file that would never arrive.
    @Test func damageThatPredatesADeliveryStillReportsAsDamage() throws {
        let (receiver, _, _, _, delivered) = try makeSettledReceiverMidDelivery()
        try rotBystander(in: receiver)

        let archive = try Archive.open(at: receiver)
        #expect(archive.deliveryIsInFlight, "the delivery is what makes this the hard case")

        let report = try archive.verifyIntegrity()
        #expect(
            !report.issues.contains(.awaitingDelivery(path: Self.bystander)),
            "a file that rotted before the delivery was relabelled as still arriving")
        #expect(
            report.issues.contains {
                switch $0 {
                case .checksumMismatch(let path, _, _): path == Self.bystander
                default: false
                }
            })
        #expect(report.issues.contains(.awaitingDelivery(path: delivered)))
    }

    /// The same split in the cheap sweep — which is the one that reaches the
    /// standing damage banner, and so the one that decides whether the window
    /// goes quiet for the length of a download.
    @Test func theSweepSplitsDamageFromTheDeliveryToo() throws {
        let (receiver, _, _, _, delivered) = try makeSettledReceiverMidDelivery()
        try rotBystander(in: receiver)

        let archive = try Archive.open(at: receiver)
        let report = archive.sweepFileSizes()

        #expect(
            report.issues.contains {
                switch $0 {
                case .sizeMismatch(let path, _, _): path == Self.bystander
                default: false
                }
            },
            "the banner stays silent for the whole delivery")
        #expect(report.issues.contains(.awaitingDelivery(path: delivered)))
    }

    /// **A file that vanished is not a file that has not arrived**, on the same
    /// terms: the delivery does not name it, so nothing is bringing it back.
    @Test func aDeletedFileIsNotRelabelledByAnUnrelatedDelivery() throws {
        let (receiver, _, _, _, delivered) = try makeSettledReceiverMidDelivery()
        try FileManager.default.removeItem(
            at: receiver.appendingPathComponent(Self.bystander))

        let archive = try Archive.open(at: receiver)
        let report = try archive.verifyIntegrity()

        #expect(report.issues.contains(.missingFile(path: Self.bystander)))
        #expect(report.issues.contains(.awaitingDelivery(path: delivered)))
    }

    /// **The hand-test's finding, and the worst of the three.** An archive that
    /// is damaged when a delivery lands could never settle its witness again:
    /// the completeness gate asked whether *every* manifest entry was at its
    /// recorded size, and a rotted file is the wrong size for ever. So the
    /// delivery completed, the record was adopted and visible — and
    /// `deliveryIsInFlight` stayed **true** with nothing arriving: 61's bar up
    /// permanently, every open re-walking the archive, and no surface able to
    /// explain it.
    ///
    /// Damage is not what a delivery is bringing, so it cannot be what says the
    /// delivery is unfinished.
    @Test func aDamagedArchiveStillSettlesOnceTheDeliveryLands() throws {
        let (receiver, source, _, person, delivered) = try makeSettledReceiverMidDelivery()
        try rotBystander(in: receiver)

        let archive = try Archive.open(at: receiver)
        archive.reconcileBackoffBounds = (.zero, .zero)
        #expect(archive.deliveryIsInFlight)

        try TestSupport.deliver([delivered], from: source, to: receiver)
        _ = try archive.reconcileIfStale()

        #expect(archive.person(withID: person) != nil)
        #expect(
            !archive.deliveryIsInFlight,
            "the delivery finished, but the damage keeps the archive in flight for ever")
        // And the damage is still damage, on an archive that now has a settled
        // witness rather than a permanently unsettled one.
        #expect(
            try archive.verifyIntegrity().issues.contains {
                switch $0 {
                case .checksumMismatch(let path, _, _): path == Self.bystander
                default: false
                }
            })
    }

    /// **What the gate is actually for still holds.** A record the manifest names
    /// and the disk has not received keeps the witness unsettled — that entry
    /// *moved*, so it is the delivery's, and settling over it would leave the
    /// index permanently stale with nothing left to re-fire.
    @Test func anUnArrivedRecordStillHoldsTheWitnessBack() throws {
        let (receiver, _, _, _, _) = try makeSettledReceiverMidDelivery()
        try rotBystander(in: receiver)

        let archive = try Archive.open(at: receiver)
        #expect(archive.deliveryIsInFlight, "the un-arrived record was skipped along with the rot")
    }

    // MARK: - The drift guard

    /// **The same wrong advice, one layer over.** A record that drifted locally
    /// while some unrelated delivery is in flight gets *accept the current
    /// contents*, not *wait* — the delivery is not bringing this path, so waiting
    /// would be waiting for nothing.
    @Test func theDriftGuardDoesNotTellYouToWaitForAFileNobodyIsSending() throws {
        let (receiver, _, _, _, _) = try makeSettledReceiverMidDelivery()

        let archive = try Archive.open(at: receiver)
        let artifact = try #require(archive.artifacts().first)
        let path = "artifacts/\(artifact.slug)/record.json"

        // A hand edit of the local record — valid JSON, and nothing to do with
        // the delivery in flight.
        let recordURL = receiver.appendingPathComponent(path)
        let edited = try String(contentsOf: recordURL, encoding: .utf8)
            .replacingOccurrences(of: "\"Shared\"", with: "\"Shared, edited by hand\"")
        try edited.write(to: recordURL, atomically: true, encoding: .utf8)

        #expect(archive.deliveryIsInFlight)
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: path)) {
            _ = try archive.updateMetadata(of: artifact.uid) { $0.title = "Local" }
        }
    }

    /// And the record the delivery **is** bringing still says *wait*, which is
    /// the claim 60 added the message for. Blessing the local bytes there would
    /// discard the other machine's edit.
    @Test func theDriftGuardStillSaysWaitForTheRecordActuallyArriving() throws {
        let source = TestSupport.makeTempDirectory()
        let sourceArchive = try Archive.create(at: source)
        let artifact = try sourceArchive.addArtifact(.sample(title: "Shared"))
        let slug = try #require(sourceArchive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"

        let receiver = try clone(source)

        // The other machine edits the record, and only its manifest has landed.
        _ = try sourceArchive.updateMetadata(of: artifact.uid) { $0.title = "Edited elsewhere" }
        try TestSupport.deliver(["manifest.json"], from: source, to: receiver)

        let archive = try Archive.open(at: receiver)
        #expect(throws: ArchiveError.recordAwaitingDelivery(path: path)) {
            _ = try archive.updateMetadata(of: artifact.uid) { $0.title = "Local" }
        }
    }

    // MARK: - An index with no per-entry history

    /// **A pre-60c index falls back to slice 60's answer, not to a new
    /// accusation.** Its witness is real and its settled rows do not exist, so it
    /// cannot tell which files the delivery covers — and inventing damage from
    /// evidence it does not hold is the failure mode this whole thread of slices
    /// exists to remove. It lasts one window: the next settling backfills.
    @Test func anIndexWithNoSettledEntriesKeepsTheArchiveWideAnswer() throws {
        let (receiver, _, _, _, delivered) = try makeSettledReceiverMidDelivery()
        try rotBystander(in: receiver)
        try stripSettledEntries(from: receiver)

        let archive = try Archive.open(at: receiver)
        let report = try archive.verifyIntegrity()

        #expect(report.issues.contains(.awaitingDelivery(path: Self.bystander)))
        #expect(report.issues.contains(.awaitingDelivery(path: delivered)))
    }

    /// And it is one window: an index that is current backfills its entries on
    /// the next open, so the *following* delivery gets the per-entry answer with
    /// nobody having rebuilt anything.
    @Test func aSettledIndexBackfillsItsEntriesOnTheNextOpen() throws {
        let source = TestSupport.makeTempDirectory()
        let sourceArchive = try Archive.create(at: source)
        _ = try sourceArchive.addArtifact(.sample(title: "Shared"))
        let receiver = try clone(source)

        // Upgrade day: a settled index from before the slice, opened once.
        try stripSettledEntries(from: receiver)
        _ = try Archive.open(at: receiver)

        // Now the delivery, with damage that predates it.
        let person = try sourceArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        try TestSupport.deliver(["manifest.json"], from: source, to: receiver)
        try rotBystander(in: receiver)

        let report = try Archive.open(at: receiver).verifyIntegrity()
        #expect(!report.issues.contains(.awaitingDelivery(path: Self.bystander)))
        #expect(
            report.issues.contains(
                .awaitingDelivery(path: "conclusions/persons/\(person.uid.raw).json")))
    }

    /// **The third route to "cannot tell": a manifest that does not decode.** It
    /// is `.disagrees` (60b — a settled witness is history, and `AtomicIO` never
    /// leaves a manifest in that state, so somebody else wrote it), but the
    /// entries it is bringing cannot be read, and every consumer is holding the
    /// *settled* manifest instead. Comparing that against the settled rows would
    /// find every path unchanged and call the whole delivery damage.
    @Test func anUnreadableManifestKeepsTheArchiveWideAnswerToo() throws {
        let (receiver, _, _, _, _) = try makeSettledReceiverMidDelivery()
        let archive = try Archive.open(at: receiver)
        try rotBystander(in: receiver)
        try Data("{ not a manifest".utf8).write(to: ArchiveLayout.manifestURL(in: receiver))

        #expect(archive.deliveryIsInFlight)
        #expect(try archive.verifyIntegrity().issues.contains(.awaitingDelivery(path: Self.bystander)))
    }

    // MARK: - Inputs the rows must not choke on

    /// **A duplicated path in `manifest.json` must not stop the archive
    /// opening** (`/code-review`). It is not this engine's output, but nothing
    /// rejects one on load and every other reader of `manifest.files` already
    /// tolerates it by keeping the first — so a primary key that threw here would
    /// make 60c the one thing that turns a readable archive into an unopenable
    /// one.
    @Test func aManifestWithADuplicatePathStillOpensAndSettles() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)

        let manifestURL = ArchiveLayout.manifestURL(in: root)
        var manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        let duplicated = try #require(manifest.files.first)
        manifest.files.append(duplicated)
        _ = try AtomicIO.writeJSON(manifest, to: manifestURL)

        let archive = try Archive.open(at: root)
        _ = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        #expect(try Archive.open(at: root).verifyIntegrity().isClean)
    }

    /// An index exactly as slice 60b left one: a witness, and no rows to say what
    /// it covered.
    private func stripSettledEntries(from root: URL) throws {
        let db = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        try db.exec("DELETE FROM settled_file;")
        try db.exec("DELETE FROM meta WHERE key = 'settledFiles';")
    }
}

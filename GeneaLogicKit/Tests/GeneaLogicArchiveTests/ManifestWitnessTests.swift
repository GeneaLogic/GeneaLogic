import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 60 — the index knows whether it is current.
///
/// The index had four rebuild triggers (missing, unopenable, schema-stale, and
/// 47's `.index/dirty` sentinel) and every one answers *is this database
/// usable?* None answered *does it reflect the files on disk?* The witness — a
/// digest of `manifest.files`, recorded in the index's own `meta` — is the fifth
/// trigger, and it is what lets a change made somewhere else be adopted instead
/// of silently ignored.
@Suite struct ManifestWitnessTests {

    // MARK: - Detecting a rebuild

    /// Inserts a person row that exists **only** in the index, keyed by a uid no
    /// file on disk carries. Any rebuild walks the sidecars and clears the record
    /// tables, so the phantom's survival is a direct, positive answer to "did a
    /// rebuild happen?" — which a correctness-only assertion cannot give, since
    /// an implementation that rebuilt on every open would pass all of those.
    ///
    /// Opened as a second connection on the same file, because `Archive` keeps
    /// its own private.
    private func plantPhantom(in root: URL) throws -> PersonID {
        let index = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        let person = Person(
            uid: PersonID(UUIDv7.generate()),
            names: [],
            provenance: Provenance(
                createdBy: .human,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                reviewStatus: .asserted))
        try index.upsert(person)
        return person.uid
    }

    private func phantomSurvives(_ uid: PersonID, in root: URL) throws -> Bool {
        let index = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        return try index.person(uid) != nil
    }


    /// A second archive holding the same records, standing in for the other
    /// machine. Copied rather than rebuilt so the slugs and uids match.
    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    // MARK: - The case this exists for: a change that arrives with its manifest

    @Test func aDeliveredChangeIsAdoptedOnOpenWithNoExplicitRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)

        // The other machine edits, and its engine writes both files.
        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }

        try TestSupport.deliver(
            ["artifacts/\(slug)/record.json", "manifest.json"], from: other, to: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifact(withID: artifact.uid)?.title == "After")
    }

    @Test func aDeliveredChangeIsAdoptedByALiveHandle() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }

        // The handle stays open across the delivery — the app's case.
        #expect(archive.artifact(withID: artifact.uid)?.title == "Before")
        try TestSupport.deliver(
            ["artifacts/\(slug)/record.json", "manifest.json"], from: other, to: root)

        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.artifact(withID: artifact.uid)?.title == "After")
        // Idempotent: having adopted it, there is nothing left to do.
        #expect(try archive.reconcileIfStale() == false)
    }

    @Test func aDeliveredConclusionArrivesToo() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        let person = try otherArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        try TestSupport.deliver(
            ["conclusions/persons/\(person.uid.raw).json", "manifest.json"],
            from: other, to: root)

        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.person(withID: person.uid) != nil)
    }

    @Test func aDeliveredDeletionArrivesToo() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        try otherArchive.removePerson(person.uid)

        try FileManager.default.removeItem(
            at: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))
        try TestSupport.deliver(["manifest.json"], from: other, to: root)

        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.person(withID: person.uid) == nil)
    }

    // MARK: - The boundary: a bare hand edit is deliberately *not* adopted

    /// **The limit of this mechanism, asserted rather than left to be discovered.**
    /// A `record.json` edited in place with no matching manifest write does not
    /// move the witness, so nothing here adopts it — and that is the correct
    /// posture, not a gap this slice failed to close. A file whose bytes disagree
    /// with the checksum the manifest recorded is *suspect*: it is equally
    /// consistent with bit rot, and slice 49 deliberately reports it rather than
    /// believing it, while 58 refuses to overwrite it. Rebuilding the query
    /// surface from it automatically would launder exactly what those two exist to
    /// catch. The resolution stays the one a human asks for: `rebaseline()`.
    @Test func aHandEditWithNoManifestIsReportedRatherThanAdopted() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)
        let recordURL = root.appendingPathComponent("artifacts/\(slug)/record.json")

        var record = try GeneaLogicJSONCoding.decoder.decode(
            Artifact.self, from: Data(contentsOf: recordURL))
        record.title = "Edited By Hand"
        try Data(GeneaLogicJSONCoding.encoder.encode(record)).write(to: recordURL)

        #expect(try archive.reconcileIfStale() == false)
        #expect(archive.artifact(withID: artifact.uid)?.title == "Before")

        // It is not invisible — it is reported, which is 49's contract.
        let report = try archive.verifyIntegrity()
        #expect(
            report.issues.contains {
                if case .checksumMismatch(let path, _, _) = $0 {
                    return path == "artifacts/\(slug)/record.json"
                }
                return false
            })
    }

    // MARK: - It must not rebuild when nothing changed

    @Test func anUnchangedArchiveNeverRebuilds() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Steady"))

        let phantom = try plantPhantom(in: root)
        for _ in 0..<5 {
            #expect(try archive.reconcileIfStale() == false)
        }
        #expect(try phantomSurvives(phantom, in: root))

        // And across a reopen, which is the other half of the same claim.
        _ = try Archive.open(at: root)
        #expect(try phantomSurvives(phantom, in: root))
    }

    @Test func ourOwnWritesMoveTheWitnessWithoutRebuilding() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Ours"))

        let phantom = try plantPhantom(in: root)

        _ = try archive.updateMetadata(of: artifact.uid) { $0.title = "Ours, edited" }
        _ = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        #expect(try archive.reconcileIfStale() == false)
        #expect(try phantomSurvives(phantom, in: root))
        #expect(try Archive.open(at: root).artifacts().first?.title == "Ours, edited")
        #expect(try phantomSurvives(phantom, in: root))
    }

    // MARK: - Fork (e): sync does not deliver everything at once

    /// A manifest that arrived ahead of the record it describes. Rebuilding from
    /// it is fine — it is the best available answer — but **recording its witness
    /// would be permanent staleness**: the manifest does not change again when the
    /// sidecar finally lands, so nothing would ever re-trigger.
    @Test func anIncompleteDeliveryIsRebuiltButNotBlessed() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }

        // The back-off is the subject of its own suite; here it would only make
        // the test assert the clock.
        archive.reconcileBackoffBounds = (.zero, .zero)

        // The manifest lands first, describing a record.json still in flight.
        try TestSupport.deliver(["manifest.json"], from: other, to: root)

        #expect(try archive.reconcileIfStale() == true)
        // The witness is *not* advanced to the delivered manifest — and equally
        // not cleared, which is what keeps "arriving" distinguishable from
        // "damaged" (see `Archive.recordWitness`). It still describes the
        // manifest we last accounted for in full.
        let index = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        let onDisk = try #require(ManifestWitness.read(from: ArchiveLayout.manifestURL(in: root)))
        let recorded = try #require(try index.manifestWitness())
        #expect(!recorded.describesSameFiles(as: onDisk))

        // Because nothing was blessed, the next check looks again — and once the
        // record lands, the archive converges.
        #expect(try archive.reconcileIfStale() == true)
        try TestSupport.deliver(["artifacts/\(slug)/record.json"], from: other, to: root)
        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.artifact(withID: artifact.uid)?.title == "After")

        let settled = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: root))
        #expect(try settled.manifestWitness() != nil)
        #expect(try archive.reconcileIfStale() == false)
    }

    // MARK: - It must not disturb what 47 and 49 established

    /// The sentinel and the witness answer different questions — *our write died
    /// mid-flight* versus *the files are not the ones we indexed* — and a
    /// witness-driven rebuild resolves only the second. Clearing the first would
    /// erase the classification that makes a mismatch read as suspect rather than
    /// corrupt (49, fork e); only `rebaseline()` resolves that.
    @Test func adoptingADeliveredChangeDoesNotResolveAnInterruptedWrite() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let person = try archive.addPerson(.sample())
        let slug = try #require(archive.artifacts().first?.slug)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }
        try TestSupport.deliver(
            ["artifacts/\(slug)/record.json", "manifest.json"], from: other, to: root)

        // Reopened with a sentinel already in place: a write died here earlier,
        // having got as far as one sidecar.
        let record = root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json")
        try (Data(contentsOf: record) + Data("\n".utf8)).write(to: record)
        try IndexDirtyMarker.set(in: root)
        let reopened = try Archive.open(at: root)
        #expect(reopened.interruptedWriteSuspected)
        #expect(reopened.artifact(withID: artifact.uid)?.title == "After")
        #expect(reopened.interruptedWriteSuspected)
    }

    // MARK: - Fork (a): the manifest is a sufficient witness

    /// **The completeness claim, pinned table by table.** Every table in the index
    /// derives from a file `manifest.files` covers, which is only true because
    /// slice 49 folded sidecar and conclusion checksums in — before that, a
    /// `person add` changed the index and left the manifest alone, and a witness
    /// built on it would have been blind to the whole conclusion layer. If that
    /// ever stops holding, this fails before any staleness does.
    @Test func everyIndexedRecordKindMovesTheWitness() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        func digest() throws -> String {
            let manifest = try GeneaLogicJSONCoding.decoder.decode(
                Manifest.self,
                from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
            return ManifestWitness.digest(of: manifest)
        }

        var seen: Set<String> = [try digest()]

        // artifact + place + search_text
        let artifact = try archive.addArtifact(.sample(title: "Census"))
        #expect(seen.insert(try digest()).inserted, "artifact record.json")

        // file
        let source = try TestSupport.makeSourceFile()
        _ = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        #expect(seen.insert(try digest()).inserted, "payload file")

        // person
        let ada = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        #expect(seen.insert(try digest()).inserted, "conclusions/persons")

        let grace = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        #expect(seen.insert(try digest()).inserted, "conclusions/persons (second)")

        // link — needs a mention to point at, so the artifact is re-made with one
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Ada Lovelace", role: .subject,
            informationQuality: .primary)
        _ = try archive.updateMetadata(of: artifact.uid) { $0.personsMentioned = [mention] }
        #expect(seen.insert(try digest()).inserted, "artifact record.json (mention added)")

        _ = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: ada.uid)
        #expect(seen.insert(try digest()).inserted, "conclusions/links")

        // relationship
        _ = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: ada.uid, person2Uid: grace.uid))
        #expect(seen.insert(try digest()).inserted, "conclusions/relationships")

        // dismissal
        _ = try archive.dismiss(.samePerson, between: ada.uid, and: grace.uid)
        #expect(seen.insert(try digest()).inserted, "conclusions/dismissals")
    }

    // MARK: - The stored form

    @Test func aWitnessRoundTripsThroughItsStoredForm() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Round trip"))

        let witness = try #require(
            ManifestWitness.read(from: ArchiveLayout.manifestURL(in: root)))

        let restored = try #require(ManifestWitness(storedValue: witness.storedValue))
        #expect(restored == witness)
        #expect(restored.stamp != nil)
        #expect(ManifestWitness(storedValue: "") == nil)
    }

    /// The stamp is a gate, never the answer: a manifest rewritten with identical
    /// contents moves it, and must not cost a rebuild.
    @Test func anIdenticalRewriteOfTheManifestDoesNotRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Steady"))

        let phantom = try plantPhantom(in: root)
        let manifestURL = ArchiveLayout.manifestURL(in: root)
        let bytes = try Data(contentsOf: manifestURL)
        try bytes.write(to: manifestURL)

        #expect(try archive.reconcileIfStale() == false)
        #expect(try phantomSurvives(phantom, in: root))
    }
}

/// Slice 60, `/code-review` findings — the three ways the witness could be
/// blessed while the index was not actually current. Each of these is a *silent*
/// permanent staleness: the record never appears, a reopen does not help, and
/// `verifyIntegrity()` says nothing is wrong.
@Suite struct WitnessBlessingTests {


    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// **A record that is *new* on the other machine, delivered manifest-first.**
    /// The fork (e) test above covers an *update*, whose entry survives the
    /// recompute by carry-forward; a brand-new record has no entry to carry, so
    /// the recompute drops it — and the completeness check then sees a manifest
    /// that no longer mentions the missing file and blesses it.
    @Test func aNewRecordDeliveredManifestFirstIsNotLostForever() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        let person = try otherArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let recordPath = "conclusions/persons/\(person.uid.raw).json"

        archive.reconcileBackoffBounds = (.zero, .zero)

        // The manifest lands first; the record is still in flight.
        try TestSupport.deliver(["manifest.json"], from: other, to: root)
        _ = try archive.reconcileIfStale()

        // The delivered manifest must survive the poll: it is the only record
        // that the person's file is expected.
        let afterPoll = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        #expect(
            afterPoll.files.contains { $0.path == recordPath },
            "the poll rewrote the delivered manifest and dropped the in-flight record")

        // Then the record arrives, and the archive must converge.
        try TestSupport.deliver([recordPath], from: other, to: root)
        _ = try archive.reconcileIfStale()
        #expect(archive.person(withID: person.uid) != nil)

        // And a reopen must not be needed to get there, nor undo it.
        #expect(try Archive.open(at: root).person(withID: person.uid) != nil)
    }

    /// **An unrelated local edit must not bless a stale index.** Every mutation
    /// records a witness; if it does so without establishing that the index
    /// matched the manifest *before* the mutation, one `addPerson` after a
    /// delivery certifies the stale index as current, and nothing ever rebuilds.
    @Test func anUnrelatedLocalEditDoesNotBlessAStaleIndex() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }
        try TestSupport.deliver(
            ["artifacts/\(slug)/record.json", "manifest.json"], from: other, to: root)

        // A local edit lands before anything noticed the delivery.
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))

        #expect(try archive.reconcileIfStale() == true)
        #expect(archive.artifact(withID: artifact.uid)?.title == "After")
    }

    /// **The delivered manifest must not be rewritten by a staleness poll.** The
    /// reconcile runs through the mutation chokepoint, whose closing
    /// `commitManifest` recomputes `files` from the freshly rebuilt index — so
    /// every entry whose file has not arrived is deleted from the one document
    /// that says it is expected.
    @Test func aStalenessPollDoesNotRewriteTheDeliveredManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.addArtifact(.sample(title: "Arriving"))
        _ = try otherArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))

        let delivered = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: other)))
        try TestSupport.deliver(["manifest.json"], from: other, to: root)

        _ = try archive.reconcileIfStale()

        let onDisk = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        #expect(onDisk.files.map(\.path) == delivered.files.map(\.path))
    }
}

/// Slice 60, fork (e)'s back-off — specced, and missing until `/code-review`.
///
/// An unsettled reconcile leaves no witness, which makes the archive read as
/// stale unconditionally. Without a back-off, the app's one-second poll takes the
/// archive lock and walks every sidecar *every tick* for as long as one large
/// file is in flight — a slow download turned into a rebuild storm that also
/// blocks the other process's writes.
@Suite struct ReconcileBackoffTests {

    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// An archive whose manifest describes a person record that has not arrived,
    /// so every reconcile is unsettled.
    private func makeArchiveAwaitingADelivery() throws -> Archive {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let other = try clone(root)
        _ = try Archive.open(at: other).addPerson(.sample(given: "Ada", surname: "Lovelace"))

        let manifest = ArchiveLayout.manifestURL(in: other)
        try? FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: root))
        try FileManager.default.copyItem(at: manifest, to: ArchiveLayout.manifestURL(in: root))
        return archive
    }

    @Test func anUnsettledDeliveryIsNotRewalkedOnEveryTick() throws {
        let archive = try makeArchiveAwaitingADelivery()
        archive.reconcileBackoffBounds = (.seconds(30), .seconds(30))

        #expect(try archive.reconcileIfStale() == true)
        // The manifest has not changed, and the missing file has not arrived —
        // there is nothing new to learn, so the walk must not happen again.
        for _ in 0..<5 {
            #expect(try archive.reconcileIfStale() == false)
        }
    }

    /// Waiting must not become never: with the window elapsed, the next check
    /// looks again, which is what lets the archive converge once the file lands.
    @Test func theBackoffExpiresAndTheCheckResumes() throws {
        let archive = try makeArchiveAwaitingADelivery()
        archive.reconcileBackoffBounds = (.zero, .zero)

        #expect(try archive.reconcileIfStale() == true)
        #expect(try archive.reconcileIfStale() == true)
    }

    /// A manifest that changes means the delivery moved on, and is worth looking
    /// at immediately however long the previous back-off had grown.
    @Test func aChangedManifestResetsTheBackoff() throws {
        let archive = try makeArchiveAwaitingADelivery()
        archive.reconcileBackoffBounds = (.seconds(30), .seconds(30))

        #expect(try archive.reconcileIfStale() == true)
        #expect(try archive.reconcileIfStale() == false)

        // A newer manifest arrives — still incomplete, but different.
        let root = archive.rootURL
        let other = try clone(root)
        _ = try Archive.open(at: other).addPerson(.sample(given: "Grace", surname: "Hopper"))
        try? FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: root))
        try FileManager.default.copyItem(
            at: ArchiveLayout.manifestURL(in: other), to: ArchiveLayout.manifestURL(in: root))

        #expect(try archive.reconcileIfStale() == true)
    }
}

/// Slice 60, hand-test — a delivery in flight is not damage.
///
/// A manifest that arrives ahead of the records it names makes every ordinary
/// check right to notice and wrong to accuse: nothing is corrupt, a file has not
/// landed yet. The engine knows which it is — the manifest on disk is not the one
/// the index last settled, and only a change from elsewhere can do that, since
/// corruption leaves `manifest.json` alone — and these pin that it says so,
/// including the part that matters most: `rebaseline` must not be offered.
@Suite struct AwaitingDeliveryTests {

    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// An archive holding A's records under B's manifest: one record edited on
    /// the other machine, its manifest delivered, its bytes still in flight.
    private func makeMidDelivery() throws -> (
        archive: Archive, uid: ArtifactID, path: String, otherMachine: URL
    ) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Before"))
        let slug = try #require(archive.artifacts().first?.slug)

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        _ = try otherArchive.updateMetadata(of: artifact.uid) { $0.title = "After" }

        try FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: root))
        try FileManager.default.copyItem(
            at: ArchiveLayout.manifestURL(in: other), to: ArchiveLayout.manifestURL(in: root))
        archive.reconcileBackoffBounds = (.zero, .zero)
        _ = try archive.reconcileIfStale()
        return (archive, artifact.uid, "artifacts/\(slug)/record.json", other)
    }

    @Test func verifyCallsItArrivalRatherThanCorruption() throws {
        let (archive, _, path, _) = try makeMidDelivery()
        let report = try archive.verifyIntegrity()

        #expect(report.issues.contains(.awaitingDelivery(path: path)))
        // And says it *once*, not also as the two kinds it replaces.
        #expect(
            !report.issues.contains {
                switch $0 {
                case .checksumMismatch(let p, _, _), .sizeMismatch(let p, _, _): p == path
                default: false
                }
            })
    }

    /// **The one that matters most.** `rebaseline()` mid-delivery records the
    /// stale local bytes as the truth, and the incoming record then lands as a
    /// reported corruption instead of an adoption — the other machine's change is
    /// discarded. So the affordance hosts gate on must not offer it.
    @Test func aRebaselineIsNotOfferedForAnArrivingChange() throws {
        let (archive, _, path, _) = try makeMidDelivery()
        let report = try archive.verifyIntegrity()

        #expect(report.rebaselinableIssues.isEmpty)
        #expect(!IntegrityReport.Issue.awaitingDelivery(path: path).isResolvableByRebaseline)
    }

    /// The cheap sweep drives the app's banner — the one surface 57 built never
    /// to cry wolf. A file still downloading must not put "1 file is missing"
    /// on screen for the whole transfer.
    @Test func theCheapSweepDoesNotCallAnArrivingFileMissing() throws {
        let (archive, _, path, _) = try makeMidDelivery()
        let sweep = archive.sweepFileSizes()

        #expect(sweep.issues.contains(.awaitingDelivery(path: path)))
        #expect(
            !sweep.issues.contains {
                switch $0 {
                case .missingFile(let p), .sizeMismatch(let p, _, _): p == path
                default: false
                }
            })
    }

    /// Editing the record that is mid-flight is still refused — overwriting it
    /// would discard the incoming version — but with the advice inverted.
    @Test func theDriftGuardAdvisesWaitingNotAccepting() throws {
        let (archive, uid, path, _) = try makeMidDelivery()

        #expect(throws: ArchiveError.recordAwaitingDelivery(path: path)) {
            _ = try archive.updateMetadata(of: uid) { $0.title = "Local" }
        }
    }

    /// And it all clears itself: nothing here is a state the user has to resolve.
    @Test func itClearsWhenTheDeliveryLands() throws {
        let (archive, uid, path, other) = try makeMidDelivery()
        let root = archive.rootURL
        #expect(try !archive.verifyIntegrity().isClean)

        // The record arrives from the machine whose manifest we already adopted.
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        try FileManager.default.copyItem(
            at: other.appendingPathComponent(path), to: root.appendingPathComponent(path))

        #expect(try archive.reconcileIfStale() == true)
        #expect(try archive.verifyIntegrity().isClean)
        #expect(archive.artifact(withID: uid)?.title == "After")

        // And the edit that was refused mid-delivery now goes through.
        _ = try archive.updateMetadata(of: uid) { $0.title = "Local, afterwards" }
        #expect(archive.artifact(withID: uid)?.title == "Local, afterwards")
    }
}

/// Slice 60, second `/code-review` — the ordinary mutation path mid-delivery.
@Suite struct MutationDuringDeliveryTests {

    private func clone(_ root: URL) throws -> URL {
        let copy = TestSupport.makeTempDirectory().appendingPathComponent("clone.genea")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// **An unrelated local edit must not delete an in-flight record's entry.**
    /// The adopt path stopped recomputing the manifest, but every *other*
    /// mutation still does — and `recomputeManifestFiles` derives the authored
    /// set from the index, so a record that has not arrived contributes no path
    /// and its entry is dropped from the only document that expects it. The
    /// rewritten manifest then looks complete, the next reconcile settles it, and
    /// the record is lost when it finally lands.
    @Test func anUnrelatedEditDoesNotDropAnInFlightRecordsEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        archive.reconcileBackoffBounds = (.zero, .zero)
        _ = try archive.addArtifact(.sample(title: "Local"))

        let other = try clone(root)
        let otherArchive = try Archive.open(at: other)
        let person = try otherArchive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"

        // The manifest arrives; the person's record is still in flight.
        try FileManager.default.removeItem(at: ArchiveLayout.manifestURL(in: root))
        try FileManager.default.copyItem(
            at: ArchiveLayout.manifestURL(in: other), to: ArchiveLayout.manifestURL(in: root))

        // An ordinary, unrelated local edit.
        _ = try archive.addArtifact(.sample(title: "Something else entirely"))

        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        #expect(
            manifest.files.contains { $0.path == path },
            "the local edit deleted the in-flight record's manifest entry")

        // And the archive still converges when the record lands.
        try FileManager.default.copyItem(
            at: other.appendingPathComponent(path), to: root.appendingPathComponent(path))
        _ = try archive.reconcileIfStale()
        #expect(archive.person(withID: person.uid) != nil)
    }
}

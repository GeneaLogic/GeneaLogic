import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 58 fork (f) — an edit must not silently overwrite a drifted sidecar.
///
/// The mutation path reads from the index and blind-writes the file without ever
/// reading it, so a record hand-edited on disk — or written by an agent driving
/// the CLI while the app is open — looks entirely healthy right up to the moment
/// an edit discards it. Every case here uses a **same-size** edit, which 57's
/// sweep is structurally blind to and this check is not.
@Suite struct RecordDriftGuardTests {

    /// Rewrites `record` with `original` → `replacement` substituted, and
    /// asserts the length didn't change.
    @discardableResult
    private func handEdit(
        _ record: URL, replacing original: String, with replacement: String
    ) throws -> Data {
        let before = try Data(contentsOf: record)
        let text = try #require(String(data: before, encoding: .utf8))
        let edited = Data(text.replacingOccurrences(of: original, with: replacement).utf8)
        #expect(edited.count == before.count, "the point of these tests is a same-size edit")
        #expect(edited != before)
        try edited.write(to: record)
        return edited
    }

    // MARK: - The refusal

    @Test func anEditRefusesToOverwriteAHandEditedConclusion() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")

        let edited = try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        #expect(
            throws: ArchiveError.recordDriftedOnDisk(
                path: "conclusions/persons/\(person.uid.raw).json")
        ) {
            _ = try archive.updatePerson(person.uid) {
                $0.identifierURI = "https://example.org/ada"
            }
        }
        // The refusal is only worth anything if the other version is still there.
        #expect(try Data(contentsOf: record) == edited)
    }

    @Test func anEditRefusesToOverwriteAHandEditedArtifactRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)
        let record = root.appendingPathComponent("artifacts/\(slug)/record.json")

        try handEdit(record, replacing: "Deed of Sale", with: "Deed of Salt")

        #expect(throws: ArchiveError.self) {
            try archive.updateMetadata(of: artifact.uid) { $0.notes = "from the Inspector" }
        }
    }

    /// The scenario the check exists for: the write is *complete* either way, so
    /// nothing looks broken afterwards — the on-disk version is simply gone.
    @Test func theRefusalIsWhatKeepsTheOtherVersion() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        #expect(throws: (any Error).self) {
            _ = try archive.updatePerson(person.uid) {
                $0.identifierURI = "https://example.org/clobber"
            }
        }
        let onDisk = try GeneaLogicJSONCoding.decoder.decode(
            Person.self, from: Data(contentsOf: record))
        #expect(onDisk.names.first?.surname == "Lovelaci")
        #expect(onDisk.identifierURI == nil)
    }

    // MARK: - A refused mutation leaves nothing behind (hand-test, 58)

    /// **Found by hand-testing.** The file operations move bytes around the
    /// artifact's folder *first* and write the record afterwards, so the
    /// chokepoint refusal came too late: the attach was correctly refused and the
    /// copied file stayed in the folder anyway, claimed by nothing — visible only
    /// later, as an unreferenced file in Verify. A refusal must leave the archive
    /// exactly as it found it.
    @Test func aRefusedAttachLeavesNoFileBehind() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)
        let folder = root.appendingPathComponent("artifacts/\(slug)")
        try handEdit(
            folder.appendingPathComponent("record.json"),
            replacing: "Deed of Sale", with: "Deed of Salt")

        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "bytes")
        #expect(throws: ArchiveError.self) {
            _ = try archive.attachFile(
                copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        }

        #expect(
            try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["record.json"])
        #expect(
            try archive.verifyIntegrity().issues.allSatisfy {
                if case .unreferencedFile = $0 { return false }
                return true
            })
    }

    /// The same rule running the other way: a refused detach must not have
    /// already moved the file into `.trash/`.
    @Test func aRefusedDetachLeavesTheFileWhereItIs() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payload = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        try handEdit(
            root.appendingPathComponent("artifacts/\(slug)/record.json"),
            replacing: "Deed of Sale", with: "Deed of Salt")

        #expect(throws: ArchiveError.self) {
            _ = try archive.detachFile(attached.entry.uid, in: artifact.uid)
        }
        #expect(FileManager.default.fileExists(atPath: payload.path))
        #expect(archive.trashedFiles().isEmpty)
    }

    /// And a refused replace must not have already overwritten the content.
    @Test func aRefusedReplaceLeavesTheExistingContent() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payload = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        try handEdit(
            root.appendingPathComponent("artifacts/\(slug)/record.json"),
            replacing: "Deed of Sale", with: "Deed of Salt")

        let replacement = try TestSupport.makeSourceFile(
            named: "scan.tif", contents: "replacement!!")
        #expect(throws: ArchiveError.self) {
            _ = try archive.replaceFile(
                attached.entry.uid, in: artifact.uid, copyingFrom: replacement)
        }
        #expect(try String(contentsOf: payload, encoding: .utf8) == "original bytes")
    }

    // MARK: - The guard must survive its own error path (review findings, 58)

    /// **The one that mattered most.** The refusal throws from inside
    /// `withState`, whose catch used to arm the interrupted-write flag — the
    /// first thing the guard checks. So the guard switched itself off, and the
    /// error text's "then try again" walked the user straight into the loss.
    @Test func retryingAfterARefusalIsStillRefused() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        let edited = try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        for attempt in 0..<3 {
            #expect(throws: ArchiveError.self, "attempt \(attempt) got through") {
                _ = try archive.updatePerson(person.uid) {
                    $0.identifierURI = "https://example.org/retry"
                }
            }
            #expect(try Data(contentsOf: record) == edited)
        }
    }

    /// A refusal writes nothing, so it must not leave the archive *looking* like
    /// a mutation died: that both downgrades a real `.checksumMismatch` to
    /// `.interruptedWrite` and costs the next open a needless full rebuild.
    @Test func aRefusalDoesNotLeaveTheArchiveLookingInterrupted() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        try handEdit(root.appendingPathComponent(path), replacing: "Lovelace", with: "Lovelaci")

        #expect(throws: ArchiveError.self) {
            _ = try archive.updatePerson(person.uid) { $0.identifierURI = "https://example.org/x" }
        }

        #expect(!IndexDirtyMarker.isSet(in: root))
        #expect(try !archive.standingFindings().interruptedWriteSuspected)
        // The hand-edit reports as what it is, not as a write that died.
        let issues = try archive.verifyIntegrity().issues.filter { $0.path == path }
        #expect(
            issues.contains {
                if case .checksumMismatch = $0 { return true }
                return false
            })
        #expect(
            !issues.contains {
                if case .interruptedWrite = $0 { return true }
                return false
            })
    }

    /// A validation-only failure writes nothing either, and used to arm the same
    /// flag *and* leave the sentinel — so one failed edit disarmed the guard for
    /// the rest of the session, and the sentinel re-armed it in the next process.
    @Test func anUnrelatedFailedMutationDoesNotDisarmTheGuard() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        let edited = try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        // Something that fails before writing anything.
        #expect(throws: ArchiveError.self) {
            _ = try archive.updatePerson(PersonID("PER-does-not-exist")) { _ in }
        }
        #expect(throws: ArchiveError.self) {
            _ = try archive.updatePerson(person.uid) { $0.identifierURI = "https://example.org/y" }
        }
        #expect(try Data(contentsOf: record) == edited)

        // And in the next process, which reads the sentinel rather than the flag.
        #expect(!IndexDirtyMarker.isSet(in: root))
        let reopened = try Archive.open(at: root)
        #expect(throws: ArchiveError.self) {
            _ = try reopened.updatePerson(person.uid) { $0.identifierURI = "https://example.org/z" }
        }
        #expect(try Data(contentsOf: record) == edited)
    }

    // MARK: - The way through

    /// `rebaseline()` is the existing, human-gated "yes, that edit was mine" —
    /// the error text points at it, so it had better work.
    @Test func rebaselineAcceptsTheEditAndTheNextWriteGoesThrough() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        try archive.rebaseline()
        let updated = try archive.updatePerson(person.uid) {
            $0.identifierURI = "https://example.org/mine"
        }

        #expect(updated.identifierURI == "https://example.org/mine")
        // The blessed edit is what got built on, not the version the index had.
        #expect(updated.names.first?.surname == "Lovelaci")
        #expect(try archive.verifyIntegrity().isClean)
    }

    // MARK: - What is deliberately not drift

    /// After a write dies between its sidecar and its manifest, an
    /// engine-authored file is *expected* to mismatch (57's classification).
    /// Firing here would freeze editing the record the crash was writing — and
    /// only the bytes that write journaled are exempt (slice 68; see below).
    @Test func anUnresolvedInterruptedWriteDoesNotBlockEditing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        let edited = try handEdit(
            root.appendingPathComponent(path), replacing: "Lovelace", with: "Lovelaci")
        try IndexDirtyMarker.set(in: root)
        IndexDirtyMarker.journalWrite(
            of: path, sha256: Checksum.sha256Hex(of: edited), in: root)

        let reopened = try Archive.open(at: root)
        #expect(try reopened.standingFindings().interruptedWriteSuspected)
        _ = try reopened.updatePerson(person.uid) {
            $0.identifierURI = "https://example.org/unblocked"
        }
    }

    /// A merge writes several records in one mutation, and a file operation
    /// rewrites the record it just changed. A path this mutation already wrote
    /// mismatches its baseline because *we* changed it.
    @Test func aMutationThatWritesTheSameRecordTwiceDoesNotTripOnItself() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let survivor = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let duplicate = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        try archive.updatePerson(duplicate.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1815")]
        }

        try archive.mergePersons(duplicate.uid, into: survivor.uid)
        #expect(archive.persons().count == 1)

        // And a file attachment, which rewrites the record it has just changed.
        let artifact = try archive.addArtifact(.sample(title: "Deed"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "bytes")
        _ = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        try archive.updateMetadata(of: artifact.uid) { $0.notes = "still editable" }
    }

    /// Absent is a repair, not a clobber: there is no other version to keep.
    @Test func aMissingSidecarIsRewrittenRatherThanRefused() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try FileManager.default.removeItem(at: record)

        _ = try archive.updatePerson(person.uid) {
            $0.identifierURI = "https://example.org/restored"
        }
        #expect(FileManager.default.fileExists(atPath: record.path))
    }

    /// **The check is scoped to engine-authored files, and that is load-bearing.**
    /// A payload file's checksum is authored into the `record.json` that claims
    /// it, not minted by this path — so rot in a preservation master must keep
    /// being reported by `verifyIntegrity()` and must not freeze every edit of
    /// the artifact that owns it.
    @Test func rotInAPayloadFileDoesNotBlockEditingItsArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed"))
        let source = try TestSupport.makeSourceFile(named: "master.tif", contents: "master bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payloadPath = "artifacts/\(slug)/\(attached.entry.path)"

        try Data("ROTTED bytes".utf8).write(to: root.appendingPathComponent(payloadPath))
        try archive.updateMetadata(of: artifact.uid) { $0.notes = "still editable" }

        #expect(
            try archive.verifyIntegrity().issues.contains {
                if case .checksumMismatch(let path, _, _) = $0 { return path == payloadPath }
                return false
            })
    }

    /// An archive written before slice 49 has no authored entries to compare
    /// against, and inventing a baseline is exactly what `rebaseline()` gates.
    @Test func aRecordWithNoManifestEntryIsWrittenWithoutComplaint() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try handEdit(record, replacing: "Lovelace", with: "Lovelaci")

        // Strip the entry the way a pre-49 archive simply wouldn't have one.
        let manifestURL = ArchiveLayout.manifestURL(in: root)
        var manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.files.removeAll { $0.path.hasPrefix("conclusions/") }
        try AtomicIO.writeJSON(manifest, to: manifestURL)

        _ = try archive.updatePerson(person.uid) {
            $0.identifierURI = "https://example.org/no-baseline"
        }
    }

    // MARK: - Removals (slice 68, fork a)

    /// A same-size edit of any conclusion record: bumps the first digit of its
    /// provenance timestamp, which every kind carries. The bytes still decode.
    @discardableResult
    private func drift(_ record: URL) throws -> Data {
        var bytes = try Data(contentsOf: record)
        let key = Data("\"createdAt\"".utf8)
        let start = try #require(bytes.range(of: key)).upperBound
        let digit = try #require(bytes[start...].firstIndex { (0x30...0x39).contains($0) })
        bytes[digit] = 0x30 + (bytes[digit] - 0x30 + 1) % 10
        try bytes.write(to: record)
        return bytes
    }

    /// Every file under `conclusions/`, by archive-relative path.
    private func conclusions(in root: URL) throws -> [String: Data] {
        let base = root.appendingPathComponent("conclusions")
        var files: [String: Data] = [:]
        let walker = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "json" {
            files[ArchiveLayout.relativePath(of: url, in: root)] = try Data(contentsOf: url)
        }
        return files
    }

    private func expectNotInterrupted(_ archive: Archive, at root: URL) throws {
        #expect(!IndexDirtyMarker.isSet(in: root))
        #expect(try !archive.standingFindings().interruptedWriteSuspected)
    }

    /// Two persons, a relationship, a link and a dismissal between them.
    private struct Family {
        let root: URL
        let archive: Archive
        let artifact: Artifact
        let ann: Person
        let bob: Person
        let relationship: Relationship
        let link: EvidenceLink
        let dismissal: Dismissal

        func url(_ path: String) -> URL { root.appendingPathComponent(path) }
        var annPath: String { "conclusions/persons/\(ann.uid.raw).json" }
        var bobPath: String { "conclusions/persons/\(bob.uid.raw).json" }
        var relationshipPath: String { "conclusions/relationships/\(relationship.uid.raw).json" }
        var linkPath: String { "conclusions/links/\(link.uid.raw).json" }
        var dismissalPath: String { "conclusions/dismissals/\(dismissal.uid.raw).json" }
    }

    private func family(function: String = #function) throws -> Family {
        let root = TestSupport.makeTempDirectory(function: function)
        let archive = try Archive.create(at: root)
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject,
            informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let ann = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let bob = try archive.addPerson(.sample(given: "Bob", surname: "Roe"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: ann.uid, person2Uid: bob.uid))
        let link = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"), to: bob.uid
        ).link
        let dismissal = try archive.dismiss(.samePerson, between: ann.uid, and: bob.uid)
        return Family(
            root: root, archive: archive, artifact: artifact, ann: ann, bob: bob,
            relationship: relationship, link: link, dismissal: dismissal)
    }

    /// Slice 68: a delete destroyed whatever was on disk, and its undo wrote back the
    /// index's copy. Each removal is refused, and the other version stays.
    @Test func aDeleteRefusesAHandEditedConclusion() throws {
        let f = try family()
        let removals: [(String, () throws -> Void)] = [
            (f.annPath, { _ = try f.archive.removePerson(f.ann.uid) }),
            (f.relationshipPath, { _ = try f.archive.removeRelationship(f.relationship.uid) }),
            (f.linkPath, { _ = try f.archive.unlink(f.link.uid) }),
            (f.dismissalPath, { _ = try f.archive.removeDismissal(f.dismissal.uid) }),
            (
                f.dismissalPath,
                { _ = try f.archive.undismiss(.samePerson, between: f.ann.uid, and: f.bob.uid) }
            ),
        ]
        for (path, remove) in removals {
            let edited = try drift(f.url(path))
            #expect(throws: ArchiveError.recordDriftedOnDisk(path: path)) { try remove() }
            #expect(try Data(contentsOf: f.url(path)) == edited)
            try expectNotInterrupted(f.archive, at: f.root)
        }
        #expect(f.archive.persons().count == 2)
        #expect(f.archive.evidenceLink(withID: f.link.uid) != nil)
    }

    /// A removal of a record nobody touched still goes through.
    @Test func aDeleteOfAnUnchangedRecordStillWorks() throws {
        let f = try family()
        try f.archive.unlink(f.link.uid)
        try f.archive.removeRelationship(f.relationship.uid)
        #expect(!FileManager.default.fileExists(atPath: f.url(f.linkPath).path))
        #expect(!FileManager.default.fileExists(atPath: f.url(f.relationshipPath).path))
    }

    // MARK: - Cascades are all or nothing (slice 68, fork b)

    /// The merge writes what stays and *then* unlinks what it displaced, so a
    /// refusal at the unlink used to arrive with the writes already standing —
    /// and having authored something, armed the interrupted-write flag. Whichever
    /// record drifted, a refused merge changes no file.
    @Test(arguments: ["absorbed", "survivor", "relationship", "link", "dismissal"])
    func aMergeRefusedByAnyOfItsRecordsChangesNothing(_ drifted: String) throws {
        let f = try family(function: "merge-\(drifted)")
        // The merge absorbs Bob into Ann: his link is repointed, the couple
        // relationship and the dismissal between them are dropped.
        let path =
            switch drifted {
            case "absorbed": f.bobPath
            case "survivor": f.annPath
            case "relationship": f.relationshipPath
            case "link": f.linkPath
            default: f.dismissalPath
            }
        try drift(f.url(path))
        let before = try conclusions(in: f.root)

        #expect(throws: ArchiveError.recordDriftedOnDisk(path: path)) {
            try f.archive.mergePersons(f.bob.uid, into: f.ann.uid)
        }
        #expect(try conclusions(in: f.root) == before)
        try expectNotInterrupted(f.archive, at: f.root)
    }

    /// The revert writes back every record the merge touched; one drifted since
    /// refuses the lot, before any of it is written.
    @Test func aRevertRefusedByADriftedRecordChangesNothing() throws {
        let f = try family()
        let decision = try f.archive.mergePersons(f.bob.uid, into: f.ann.uid)
        try drift(f.url(f.annPath))
        let before = try conclusions(in: f.root)

        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            try f.archive.revertMerge(decision)
        }
        #expect(try conclusions(in: f.root) == before)
        try expectNotInterrupted(f.archive, at: f.root)
    }

    /// A second verdict on a pair supersedes the first *after* it is written; a
    /// drifted first verdict refuses before the new one lands.
    @Test func aSupersedeRefusedByADriftedLinkChangesNothing() throws {
        let f = try family()
        try drift(f.url(f.linkPath))
        let before = try conclusions(in: f.root)
        let mention = MentionRef(artifact: f.artifact.uid, localRef: "p1")

        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.linkPath)) {
            _ = try f.archive.link(mention, to: f.bob.uid)
        }
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.linkPath)) {
            _ = try f.archive.confirm(mention, as: f.bob.uid)
        }
        #expect(try conclusions(in: f.root) == before)
        try expectNotInterrupted(f.archive, at: f.root)
    }

    // MARK: - The exemption is the crash's own bytes (slice 68, fork c)

    /// Leaves `ann` as a crash's residue, the way a write killed after its rename
    /// leaves it: her sidecar holds new bytes, the sentinel is up, and its journal
    /// names those bytes. Opening settles it. Returns the bytes.
    @discardableResult
    private func crashedOn(_ f: Family) throws -> Data {
        try IndexDirtyMarker.set(in: f.root)
        let written = try drift(f.url(f.annPath))
        IndexDirtyMarker.journalWrite(
            of: f.annPath, sha256: Checksum.sha256Hex(of: written), in: f.root)
        return written
    }

    /// The first cut exempted every mismatch the recovering open found, so a
    /// hand edit already on disk — to any record — rode along with the crash.
    /// Only bytes the journal names are ours.
    @Test func aHandEditOnDiskAtTheCrashIsNotExempt() throws {
        let f = try family()
        let edited = try drift(f.url(f.bobPath))
        try crashedOn(f)
        let archive = try Archive.open(at: f.root)
        #expect(InterruptedWriteMarker.exemptions(in: f.root).keys.sorted() == [f.annPath])
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.bobPath)) {
            _ = try archive.removePerson(f.bob.uid)
        }
        #expect(try Data(contentsOf: f.url(f.bobPath)) == edited)
    }

    /// Nor is a hand edit of the very path the crash was writing, if the write
    /// never landed: the journal names the bytes, not just the path.
    @Test func aJournaledPathWhoseWriteNeverLandedIsNotExempt() throws {
        let f = try family()
        try IndexDirtyMarker.set(in: f.root)
        IndexDirtyMarker.journalWrite(of: f.annPath, sha256: String(repeating: "0", count: 64), in: f.root)
        try drift(f.url(f.annPath))
        let archive = try Archive.open(at: f.root)
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try archive.removePerson(f.ann.uid)
        }
    }

    /// A second crash before anyone accepts the first journals only its own
    /// writes; the first crash's record must stay exempt (found by hand-testing
    /// 68 against repeated `kill -9`s).
    @Test func aSecondCrashKeepsTheFirstCrashsExemption() throws {
        let f = try family()
        try crashedOn(f)
        _ = try Archive.open(at: f.root)

        try IndexDirtyMarker.set(in: f.root)
        let written = try drift(f.url(f.relationshipPath))
        IndexDirtyMarker.journalWrite(
            of: f.relationshipPath, sha256: Checksum.sha256Hex(of: written), in: f.root)
        let archive = try Archive.open(at: f.root)

        #expect(
            InterruptedWriteMarker.exemptions(in: f.root).keys.sorted()
                == [f.annPath, f.relationshipPath].sorted())
        _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
        _ = try archive.removeRelationship(f.relationship.uid)
    }

    /// Once a write of ours supersedes the crash's bytes, they stop being exempt —
    /// so a sync or a restore that puts those exact bytes back is guarded.
    @Test func aRewrittenPathIsNoLongerExempt() throws {
        let f = try family()
        let crashed = try crashedOn(f)
        let archive = try Archive.open(at: f.root)
        _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
        #expect(InterruptedWriteMarker.exemptions(in: f.root).isEmpty)

        try crashed.write(to: f.url(f.annPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try archive.removePerson(f.ann.uid)
        }
        // And in the next process, which reads the marker.
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try Archive.open(at: f.root).removePerson(f.ann.uid)
        }
    }

    /// Slice 68: the guard used to be off archive-wide until *Accept Current
    /// Contents*. Now the crash's record stays editable, and nothing else is.
    @Test func aRecoveredCrashExemptsOnlyItsOwnBytes() throws {
        let f = try family()
        try crashedOn(f)
        let archive = try Archive.open(at: f.root)
        #expect(try archive.standingFindings().interruptedWriteSuspected)

        // A record drifted after the crash — a delivery, an agent — is guarded.
        let edited = try drift(f.url(f.bobPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.bobPath)) {
            _ = try archive.updatePerson(f.bob.uid) { $0.identifierURI = "https://example.org/b" }
        }
        #expect(try Data(contentsOf: f.url(f.bobPath)) == edited)

        // The crash's own record is not.
        _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
        // And once ours, it is guarded like any other.
        try drift(f.url(f.annPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a2" }
        }
    }

    /// Exempt while its bytes are still the ones the crash left — not after.
    @Test func theCrashsRecordIsGuardedOnceItsBytesMoveAgain() throws {
        let f = try family()
        try crashedOn(f)
        let archive = try Archive.open(at: f.root)
        try drift(f.url(f.annPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try archive.removePerson(f.ann.uid)
        }
    }

    /// The residue is written into the marker, so the next launch exempts the
    /// same bytes rather than everything.
    @Test func theExemptionSurvivesAReopen() throws {
        let f = try family()
        try crashedOn(f)
        _ = try Archive.open(at: f.root)
        #expect(!IndexDirtyMarker.isSet(in: f.root))
        let recorded = InterruptedWriteMarker.exemptions(in: f.root)
        #expect(Set(recorded.keys) == [f.annPath])

        let reopened = try Archive.open(at: f.root)
        #expect(try reopened.standingFindings().interruptedWriteSuspected)
        try drift(f.url(f.relationshipPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.relationshipPath)) {
            _ = try reopened.removeRelationship(f.relationship.uid)
        }
        _ = try reopened.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
    }

    /// A marker written before 68 is empty, and its crash journaled nothing, so
    /// it exempts nothing: re-deriving the residue would sweep in everything that
    /// drifted between that crash and this open. The way through is the one the
    /// banner already offers.
    @Test func anEmptyMarkerExemptsNothing() throws {
        let f = try family()
        try drift(f.url(f.annPath))
        try Data().write(to: ArchiveLayout.interruptedWriteMarkerURL(in: f.root))

        let archive = try Archive.open(at: f.root)
        #expect(try archive.standingFindings().interruptedWriteSuspected)
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.annPath)) {
            _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
        }
        try archive.rebaseline()
        _ = try archive.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
    }

    /// A mutation of ours that dies part-way in this session exempts exactly the
    /// bytes it wrote — and nothing else.
    @Test func aFailedWriteOfOursExemptsWhatItWroteAndNothingElse() throws {
        let f = try family()
        // Make the merge fail after its first write: the persons folder becomes
        // a file just as the repointed link lands.
        let persons = f.root.appendingPathComponent("conclusions/persons")
        let aside = f.root.appendingPathComponent("persons-aside")
        WriteCheckpoint.install(root: f.root) { event, url in
            guard event == "renamed", url.path.contains("/conclusions/links/"),
                !FileManager.default.fileExists(atPath: aside.path)
            else { return }
            try? FileManager.default.moveItem(at: persons, to: aside)
            try? Data().write(to: persons)
        }
        #expect(throws: (any Error).self) {
            try f.archive.mergePersons(f.bob.uid, into: f.ann.uid)
        }
        WriteCheckpoint.remove(root: f.root)
        try FileManager.default.removeItem(at: persons)
        try FileManager.default.moveItem(at: aside, to: persons)

        #expect(try f.archive.standingFindings().interruptedWriteSuspected)
        let written = try Checksum.sha256Hex(ofFileAt: f.url(f.linkPath))
        #expect(f.archive.interruptedWriteExemptions == [f.linkPath: written])

        try drift(f.url(f.relationshipPath))
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: f.relationshipPath)) {
            _ = try f.archive.removeRelationship(f.relationship.uid)
        }
    }

    /// `rebaseline()` resolves the write, and takes the exemption with it.
    @Test func rebaselineClearsTheExemption() throws {
        let f = try family()
        try crashedOn(f)
        let archive = try Archive.open(at: f.root)
        try archive.rebaseline()
        #expect(!InterruptedWriteMarker.isSet(in: f.root))
        let reopened = try Archive.open(at: f.root)
        #expect(try !reopened.standingFindings().interruptedWriteSuspected)
        _ = try reopened.updatePerson(f.ann.uid) { $0.identifierURI = "https://example.org/a" }
    }
}

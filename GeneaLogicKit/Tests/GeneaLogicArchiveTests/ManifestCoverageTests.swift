import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// Slice 49 — `manifest.files` covers everything the engine authors, so damage to
/// a `record.json` or a `conclusions/**` record is reportable rather than
/// invisible.
///
/// `@testable` for `IndexDirtyMarker` (fork e's classification needs the sentinel
/// set by hand) and `ArchiveLayout`, on the same reasoning as
/// `CrossProcessWriteSafetyTests`: inferring those paths from string literals is
/// the hardcoding the design forbids.
@Suite struct ManifestCoverageTests {

    // MARK: - Helpers

    private func manifest(in root: URL) throws -> Manifest {
        try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
    }

    private func entry(_ path: String, in root: URL) throws -> ManifestEntry? {
        try manifest(in: root).files.first { $0.path == path }
    }

    /// Rewrites a file's bytes behind the engine's back — bit rot, a hand edit, a
    /// sync client's delivery: the archive cannot tell them apart, which is why
    /// they all report the same way.
    private func corrupt(_ relativePath: String, in root: URL, to contents: String = "{}") throws {
        try Data(contents.utf8).write(to: root.appendingPathComponent(relativePath))
    }

    private func checksumMismatches(_ report: IntegrityReport) -> [String] {
        report.issues.compactMap {
            if case .checksumMismatch(let path, _, _) = $0 { return path }
            return nil
        }
    }

    private func interruptedWrites(_ report: IntegrityReport) -> [String] {
        report.issues.compactMap {
            if case .interruptedWrite(let path) = $0 { return path }
            return nil
        }
    }

    // MARK: - Coverage

    /// The gap the slice exists to close: an artifact's `record.json` and a
    /// conclusion record are the archive's least reproducible data and were the
    /// only things `verifyIntegrity()` could not see.
    @Test func rottedSidecarAndRottedConclusionAreBothReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Rotting"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let slug = try #require(archive.artifacts().first?.slug)

        #expect(try archive.verifyIntegrity().isClean)

        let recordPath = "artifacts/\(slug)/record.json"
        let personPath = "conclusions/persons/\(person.uid.raw).json"
        try corrupt(recordPath, in: root)
        try corrupt(personPath, in: root)

        let mismatches = checksumMismatches(try archive.verifyIntegrity())
        #expect(mismatches.contains(recordPath))
        #expect(mismatches.contains(personPath))
        #expect(artifact.uid.raw.hasPrefix("ART-"))
    }

    /// **The laundering regression.** Carrying an entry forward verbatim is the
    /// whole design: a recompute that re-hashed present entries would rewrite the
    /// rot's own hash into the manifest on the next unrelated mutation, and the
    /// damage would verify clean forever after.
    @Test func anUnrelatedMutationDoesNotRehashARottedRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Victim"))
        let bystander = try archive.addArtifact(.sample(title: "Bystander"))
        let slug = try #require(archive.artifacts().first { $0.title == "Victim" }?.slug)
        let victimPath = "artifacts/\(slug)/record.json"

        let recorded = try #require(try entry(victimPath, in: root))
        try corrupt(victimPath, in: root)

        // Mutate something else — an artifact edit, a conclusion write — each of
        // which recomputes the whole file list.
        try archive.updateMetadata(of: bystander.uid) { $0.notes = "touched" }
        try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))

        #expect(try entry(victimPath, in: root) == recorded, "the entry must be carried forward")
        #expect(checksumMismatches(try archive.verifyIntegrity()).contains(victimPath))
    }

    /// Fork (d): the blessed §5.1 out-of-band flow. A hand edit reports as damage
    /// — correct, and the point — until a human says the disk is right.
    @Test func rebaselineAcceptsAHandEditAndVerifiesClean() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let personPath = "conclusions/persons/\(person.uid.raw).json"

        var edited = try #require(archive.person(withID: person.uid))
        edited.identifierURI = "urn:hand-edited"
        try Data(GeneaLogicJSON.encoder.encode(edited)).write(
            to: root.appendingPathComponent(personPath))

        #expect(checksumMismatches(try archive.verifyIntegrity()).contains(personPath))

        try archive.rebaseline()

        #expect(try archive.verifyIntegrity().isClean)
        // The index was rebuilt onto the edit too, so the archive agrees with
        // itself rather than merely being quiet about the disagreement.
        #expect(archive.person(withID: person.uid)?.identifierURI == "urn:hand-edited")
    }

    /// Rebaseline blesses only what the manifest is the sole authority for. A
    /// payload file's checksum has a second home in the `record.json` that claims
    /// it, so rot in a preservation master stays reported — accepting *that*
    /// would mean rewriting a record, which is a different operation.
    @Test func rebaselineDoesNotBlessARottedPayloadFile() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Scanned"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payloadPath = "artifacts/\(slug)/\(attached.entry.path)"

        try corrupt(payloadPath, in: root, to: "rot")
        try archive.rebaseline()

        #expect(checksumMismatches(try archive.verifyIntegrity()).contains(payloadPath))
    }

    // MARK: - The crash window (fork e)

    /// A mutation that died between its sidecar write and its manifest write
    /// leaves a stale hash that is byte-identical to rot. The `.index/dirty`
    /// sentinel is the only thing that can tell them apart, so a mismatch on an
    /// engine-authored file is reported as *suspect*, not *corrupt*.
    @Test func aMismatchAfterAnInterruptedWriteIsClassifiedAsSuch() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let slug: String
        do {
            try archive.addArtifact(.sample(title: "Interrupted"))
            slug = try #require(archive.artifacts().first?.slug)
        }
        let recordPath = "artifacts/\(slug)/record.json"
        let personPath = "conclusions/persons/\(person.uid.raw).json"

        // Bytes that differ from the manifest's record but still decode — which
        // is exactly what a killed mutation leaves: the *newer* version of the
        // file, with the manifest still describing the older one. (Garbage would
        // also fail the rebuild the dirty sentinel triggers, testing something
        // else entirely.)
        for path in [recordPath, personPath] {
            let url = root.appendingPathComponent(path)
            try (String(data: try Data(contentsOf: url), encoding: .utf8)! + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try IndexDirtyMarker.set(in: root)

        // The classification is fixed at `open()`, because the open that resolves
        // the sentinel is also the one that clears it.
        let reopened = try Archive.open(at: root)
        let report = try reopened.verifyIntegrity()
        #expect(interruptedWrites(report).sorted() == [recordPath, personPath].sorted())
        #expect(checksumMismatches(report).isEmpty)

        // …and it is a classification, not a repair: `rebaseline` is still the
        // resolution.
        try reopened.rebaseline()
        #expect(try reopened.verifyIntegrity().isClean)
    }

    /// A write that dies **in this session** is the same divergence arriving from
    /// the other direction, and used to need a reopen before the report would say
    /// so (review finding, 49). The failure is injected the way
    /// `CrossProcessWriteSafetyTests` does it: a second connection drops a table
    /// out from under ours, so the index write throws *after* the sidecar landed.
    @Test func aWriteThatDiesInThisSessionIsClassifiedWithoutReopening() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Survivor"))
        let slug = try #require(archive.artifacts().first?.slug)
        let recordPath = "artifacts/\(slug)/record.json"

        let saboteur = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        try saboteur.exec("DROP TABLE place;")
        #expect(throws: ArchiveError.self) {
            try archive.updateMetadata(of: try #require(archive.artifacts().first?.uid)) {
                $0.notes = "the write that dies"
            }
        }

        // The sidecar landed with the new notes; the manifest still describes the
        // old bytes. Same handle, no reopen.
        #expect(interruptedWrites(try archive.verifyIntegrity()).contains(recordPath))
        #expect(checksumMismatches(try archive.verifyIntegrity()).isEmpty)
    }

    /// The flag is cleared by the one operation that resolves it, so a *later*
    /// problem in the same session is reported as what it is (review finding, 49).
    @Test func rebaselineStopsClassifyingLaterMismatchesAsInterrupted() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let personPath = "conclusions/persons/\(person.uid.raw).json"
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        try reopened.rebaseline()
        #expect(try reopened.verifyIntegrity().isClean)

        try corrupt(personPath, in: root, to: "{\"corrupt\": true}")
        let report = try reopened.verifyIntegrity()
        #expect(checksumMismatches(report).contains(personPath))
        #expect(interruptedWrites(report).isEmpty)
    }

    /// Fork (d) scoping, and what a host may offer a button for: `rebaseline()`
    /// blesses only files the manifest alone attests. The schema-spec copy is not
    /// one of them — nothing edits it after `create`, so a difference there is
    /// damage, and an earlier draft that emptied `files` wholesale silently
    /// re-minted it (review finding, 49).
    @Test func rebaselineDoesNotBlessAMangledSchemaSpec() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let specPath = "schema/\(ArchiveLayout.schemaSpecFileName)"

        try corrupt(specPath, in: root, to: "# not the spec")
        #expect(checksumMismatches(try archive.verifyIntegrity()).contains(specPath))

        try archive.rebaseline()

        #expect(checksumMismatches(try archive.verifyIntegrity()).contains(specPath))
        #expect(
            try archive.verifyIntegrity().rebaselinableIssues.isEmpty,
            "and a host must not be told the button would help")
    }

    /// The predicate hosts gate their rebaseline affordance on. Rot in a
    /// preservation master is a `.checksumMismatch` that `rebaseline()` provably
    /// will not resolve, so offering it there is a scary confirmation followed by
    /// an unchanged report (review finding, 49).
    @Test func onlyEngineAuthoredMismatchesAreOfferedToRebaseline() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Scanned"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)

        try corrupt("artifacts/\(slug)/\(attached.entry.path)", in: root, to: "rot")
        #expect(try !archive.verifyIntegrity().isClean)
        #expect(try archive.verifyIntegrity().rebaselinableIssues.isEmpty)

        // …and the record beside it, which it can, flips the same predicate. (Two
        // findings, one path: the shortened file mismatches on size *and* hash.)
        try corrupt("artifacts/\(slug)/record.json", in: root, to: "{}")
        #expect(
            Set(try archive.verifyIntegrity().rebaselinableIssues.map(\.path)) == [
                "artifacts/\(slug)/record.json"
            ])
    }

    /// The same damage on an archive with no interrupted write is corruption, and
    /// must keep saying so — the sentinel widens no excuse for payload files
    /// either.
    @Test func aPayloadMismatchIsNeverClassifiedAsAnInterruptedWrite() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Scanned"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payloadPath = "artifacts/\(slug)/\(attached.entry.path)"

        try corrupt(payloadPath, in: root, to: "rot")
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)
        let report = try reopened.verifyIntegrity()
        #expect(checksumMismatches(report).contains(payloadPath))
        #expect(interruptedWrites(report).isEmpty)
    }

    // MARK: - Where the bugs will be: deletion, trash, re-slugging

    /// Carrying entries forward means they no longer fall out of a recompute, so
    /// every path that removes or moves a record has to leave the manifest right.
    /// The set is enumerated from the index each time, which is what makes these
    /// four cases work without per-path bookkeeping — pinned so a future
    /// "optimization" that caches the list can't quietly break them.
    @Test func removingAnArtifactTakesItsEntriesWithIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Doomed"))
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "bytes")
        try archive.attachFile(copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)

        #expect(try entry("artifacts/\(slug)/record.json", in: root) != nil)

        try archive.removeArtifact(artifact.uid)

        let files = try manifest(in: root).files
        #expect(!files.contains { $0.path.hasPrefix("artifacts/\(slug)/") })
        #expect(!files.contains { $0.path.hasPrefix(".trash/") })
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// Restoring re-homes the folder — under a *fresh* slug when the original is
    /// taken — so the entry has to be minted at the new path. Nothing carries
    /// forward here: the trashed record was never in the manifest.
    @Test func restoringAReSluggedArtifactMintsItsEntryAtTheNewPath() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Twin"))
        let originalSlug = try #require(archive.artifacts().first?.slug)
        try archive.removeArtifact(artifact.uid)

        // Take the original slug, so the restore has to pick a different one.
        try archive.addArtifact(.sample(title: "Twin"))
        try archive.restoreFromTrash(artifact.uid)

        let restoredSlug = try #require(
            archive.artifacts().first { $0.uid == artifact.uid }?.slug)
        #expect(restoredSlug != originalSlug)

        let restoredEntry = try #require(
            try entry("artifacts/\(restoredSlug)/record.json", in: root))
        let onDisk = try Data(
            contentsOf: root.appendingPathComponent("artifacts/\(restoredSlug)/record.json"))
        #expect(restoredEntry.byteLength == Int64(onDisk.count))

        // No entry survives for a path nothing lives at any more — the original
        // slug is still listed here only because the *other* artifact took it.
        let files = try manifest(in: root).files
        #expect(files.filter { $0.path.hasSuffix("/record.json") }.count == 2)
        for entry in files {
            #expect(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(entry.path).path),
                "stale entry for \(entry.path)")
        }
        #expect(try archive.verifyIntegrity().isClean)
    }

    // MARK: - Compatibility (fork f)

    /// An archive written before this slice has no authored entries. That means
    /// *unverified*, never *tampered*: it verifies clean, and the entries appear
    /// on the next write, minted from whatever is on disk then.
    @Test func aManifestWithNoAuthoredEntriesVerifiesCleanAndFillsIn() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Legacy"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let slug = try #require(archive.artifacts().first?.slug)

        // Roll the manifest back to the pre-49 shape: payload + schema spec only.
        var legacy = try manifest(in: root)
        legacy.files = legacy.files.filter {
            !ArchiveLayout.isEngineAuthored(relativePath: $0.path)
        }
        try Data(GeneaLogicJSON.encoder.encode(legacy)).write(
            to: ArchiveLayout.manifestURL(in: root))

        let reopened = try Archive.open(at: root)
        let legacyReport = try reopened.verifyIntegrity()
        #expect(legacyReport.isClean, "unverified is not tampered")
        // …but the report must be able to say how little it checked, or a clean
        // legacy archive is indistinguishable from a clean covered one.
        #expect(legacyReport.trackedFileCount == 1, "only the schema spec was tracked")

        try reopened.updateMetadata(of: artifact.uid) { $0.notes = "touched" }

        #expect(try entry("artifacts/\(slug)/record.json", in: root) != nil)
        #expect(try entry("conclusions/persons/\(person.uid.raw).json", in: root) != nil)
        let filled = try reopened.verifyIntegrity()
        #expect(filled.isClean)
        #expect(filled.trackedFileCount == 3, "record.json + the person + the schema spec")
    }

    // MARK: - Fork (c): updatedAt moves with `files`, and only with it

    /// The cost fork (c) accepted knowingly is one manifest write per conclusion
    /// edit. The other half of the rule is that a mutation touching no tracked
    /// file still writes nothing — otherwise every index rebuild would churn the
    /// manifest and `updatedAt` would stop meaning anything.
    @Test func aMutationThatChangesNoTrackedFileDoesNotRewriteTheManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "Settled"))

        let manifestURL = ArchiveLayout.manifestURL(in: root)
        let before = try #require(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate]
                as? Date)

        try archive.rebuildIndex()
        try archive.emptyTrash()

        let after = try #require(
            try FileManager.default.attributesOfItem(atPath: manifestURL.path)[.modificationDate]
                as? Date)
        #expect(before == after)
        #expect(try manifest(in: root).updatedAt.isEmpty == false)
    }
}

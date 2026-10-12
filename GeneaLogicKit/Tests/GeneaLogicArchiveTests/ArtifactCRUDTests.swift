import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Artifact CRUD (`addArtifact`/`updateMetadata`/`removeArtifact`) and the
/// regression test for Bug 1 (the exclusive-access trap).
@Suite struct ArtifactCRUDTests {

    @Test func addArtifactWritesSidecarAndUpdatesIndexAndManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let artifact = try archive.addArtifact(.sample(title: "1920 US Census – Smith Family"))

        #expect(artifact.uid.raw.hasPrefix("ART-"))
        #expect(archive.artifact(withID: artifact.uid)?.title == artifact.title)

        // The sidecar landed on disk at a slug derived from the title.
        let recordURL = root.appendingPathComponent(
            "artifacts/1920-us-census-smith-family/record.json")
        #expect(FileManager.default.fileExists(atPath: recordURL.path))

        // The manifest now lists the schema spec only — addArtifact alone (no
        // attached files) doesn't add any `ManifestEntry` for the artifact, since
        // `recomputeManifestFiles` walks `artifact.files` (empty here).
        let manifest = try currentManifest(root: root)
        #expect(manifest.files.contains { $0.path.hasSuffix("genealogic-archive-1.0.md") })
    }

    @Test func updateMetadataMutatesAndPreservesIdentity() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Original title"))

        try archive.updateMetadata(of: artifact.uid) { record in
            record.title = "Updated title"
            record.tags = ["census", "1920"]
            // Attempting to change identity must be overwritten by the engine.
            record.uid = ArtifactID("ART-attempted-hijack")
        }

        let updated = try #require(archive.artifact(withID: artifact.uid))
        #expect(updated.title == "Updated title")
        #expect(updated.tags == ["census", "1920"])
        #expect(updated.uid == artifact.uid)
    }

    @Test func updateMetadataThrowsForUnknownArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = ArtifactID("ART-does-not-exist")

        #expect(throws: ArchiveError.artifactNotFound(bogus)) {
            try archive.updateMetadata(of: bogus) { _ in }
        }
    }

    @Test func removeArtifactDeletesFolderAndIndexEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "To be removed"))
        let slug = try #require(archive.artifacts().first?.slug)
        let directory = root.appendingPathComponent("artifacts/\(slug)")
        #expect(FileManager.default.fileExists(atPath: directory.path))

        try archive.removeArtifact(artifact.uid)

        #expect(archive.artifact(withID: artifact.uid) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func removeArtifactThrowsForUnknownArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = ArtifactID("ART-does-not-exist")

        #expect(throws: ArchiveError.artifactNotFound(bogus)) {
            try archive.removeArtifact(bogus)
        }
    }

    @Test func removeArtifactIsReversibleRestoringFilesIndexAndManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deletable dossier"))

        let doc = try TestSupport.makeSourceFile(named: "doc.txt", contents: "evidence bytes")
        let attached = try archive.attachFile(copyingFrom: doc, to: artifact.uid, role: .accessCopy)
        // A transcript file too, so we also confirm the index's search_text is
        // reprojected on restore (slice 8 column).
        let transcript = try TestSupport.makeSourceFile(
            named: "t.txt", contents: "Magdalena testimony")
        _ = try archive.attachFile(copyingFrom: transcript, to: artifact.uid, role: .transcript)
        let slug = try #require(archive.artifacts().first?.slug)
        let directory = root.appendingPathComponent("artifacts/\(slug)")
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Magdalena")).count == 1)

        // Delete: record, folder, index entry, and transcript search all gone.
        let deletion = try archive.removeArtifact(artifact.uid)
        #expect(archive.artifact(withID: artifact.uid) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Magdalena")).isEmpty)

        // Undo: the artifact, its files (bytes + uid + sha256), the index, the
        // manifest, and transcript-file search all come back faithfully.
        try archive.restoreArtifact(deletion)
        let restored = try #require(archive.artifact(withID: artifact.uid))
        #expect(restored.title == "Deletable dossier")
        #expect(restored.files.count == 2)
        #expect(
            restored.files.contains {
                $0.uid == attached.entry.uid && $0.sha256 == attached.entry.sha256
            })
        let restoredSlug = try #require(archive.artifacts().first?.slug)
        let restoredDoc = root.appendingPathComponent(
            "artifacts/\(restoredSlug)/\(attached.entry.path)")
        #expect(try Data(contentsOf: restoredDoc) == Data("evidence bytes".utf8))
        #expect(archive.artifacts(matching: ArtifactQuery(text: "Magdalena")).count == 1)

        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: manifestData)
        #expect(
            manifest.files.contains {
                $0.path == "artifacts/\(restoredSlug)/\(attached.entry.path)"
            }
        )

        // Redo: deleting again is clean.
        _ = try archive.removeArtifact(artifact.uid)
        #expect(archive.artifact(withID: artifact.uid) == nil)
    }

    // MARK: - Trash (persisted, cross-session recovery)

    @Test func removeArtifactMovesBytesToTrashAndListsThere() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Trashable"))
        let doc = try TestSupport.makeSourceFile(named: "doc.txt", contents: "bytes")
        _ = try archive.attachFile(copyingFrom: doc, to: artifact.uid, role: .accessCopy)

        try archive.removeArtifact(artifact.uid)

        // Gone from lookups, but recoverable: bytes parked under .trash/<uid>/payload.
        #expect(archive.artifact(withID: artifact.uid) == nil)
        let payloadRecord = root.appendingPathComponent(
            ".trash/\(artifact.uid.raw)/payload/record.json")
        #expect(FileManager.default.fileExists(atPath: payloadRecord.path))

        let trashed = archive.trashedArtifacts()
        #expect(trashed.count == 1)
        #expect(trashed.first?.uid == artifact.uid)
        #expect(trashed.first?.title == "Trashable")
        #expect(!(trashed.first?.deletedAt.isEmpty ?? true))
    }

    @Test func restoreFromTrashByUidBringsItBackAndClearsEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Recoverable"))
        let doc = try TestSupport.makeSourceFile(named: "doc.txt", contents: "evidence bytes")
        let attached = try archive.attachFile(copyingFrom: doc, to: artifact.uid, role: .accessCopy)

        try archive.removeArtifact(artifact.uid)
        let restored = try archive.restoreFromTrash(artifact.uid)

        #expect(restored.uid == artifact.uid)
        #expect(restored.title == "Recoverable")
        #expect(restored.files.contains { $0.uid == attached.entry.uid })
        #expect(archive.artifact(withID: artifact.uid) != nil)
        // The trash entry is consumed.
        #expect(archive.trashedArtifacts().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".trash/\(artifact.uid.raw)").path))
        // The restored file's bytes are back in the artifact folder.
        let slug = try #require(archive.artifacts().first?.slug)
        let bytes = try Data(
            contentsOf: root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)"))
        #expect(bytes == Data("evidence bytes".utf8))
    }

    @Test func restoreFromTrashThrowsForUnknownUid() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = ArtifactID("ART-not-trashed")

        #expect(throws: ArchiveError.trashEntryNotFound(bogus)) {
            _ = try archive.restoreFromTrash(bogus)
        }
    }

    @Test func emptyTrashIsIrreversible() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addArtifact(.sample(title: "One"))
        let b = try archive.addArtifact(.sample(title: "Two"))
        try archive.removeArtifact(a.uid)
        try archive.removeArtifact(b.uid)
        #expect(archive.trashedArtifacts().count == 2)

        try archive.emptyTrash()

        #expect(archive.trashedArtifacts().isEmpty)
        #expect(throws: ArchiveError.trashEntryNotFound(a.uid)) {
            _ = try archive.restoreFromTrash(a.uid)
        }
    }

    @Test func deleteFromTrashRemovesOnlyThatEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addArtifact(.sample(title: "Keep"))
        let b = try archive.addArtifact(.sample(title: "Purge"))
        try archive.removeArtifact(a.uid)
        try archive.removeArtifact(b.uid)

        try archive.deleteFromTrash(b.uid)

        let remaining = archive.trashedArtifacts()
        #expect(remaining.count == 1)
        #expect(remaining.first?.uid == a.uid)
        // The kept one still restores.
        #expect(throws: Never.self) { _ = try archive.restoreFromTrash(a.uid) }
    }

    @Test func rebuildIndexDoesNotResurrectTrashedArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Stays deleted"))
        try archive.removeArtifact(artifact.uid)

        // The §5.1 out-of-band rebuild must not walk .trash/ back into the index.
        try archive.rebuildIndex()

        #expect(archive.artifact(withID: artifact.uid) == nil)
        #expect(archive.trashedArtifacts().count == 1)
    }

    @Test func verifyIntegrityIgnoresTrashedBytes() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Has a file"))
        let doc = try TestSupport.makeSourceFile(named: "doc.txt", contents: "payload bytes")
        _ = try archive.attachFile(copyingFrom: doc, to: artifact.uid, role: .accessCopy)

        try archive.removeArtifact(artifact.uid)

        // The trashed file under .trash/ must not surface as an unreferenced/stray
        // file (the sweep is scoped to artifacts/, and .trash/ is a sibling).
        #expect(try archive.verifyIntegrity().isClean)
    }

    // MARK: - Regression: Bug 1 (exclusive-access trap)

    /// Before the fix, every mutation method ran `self.rewriteManifest()` from
    /// inside `withState { manifest, index in … }`, which both held an `inout`
    /// access to `self.manifest` — a Swift exclusive-access violation that
    /// **traps at runtime** (not a thrown error; the process aborts). This test
    /// simply has to *complete* — if the trap regresses, the test process itself
    /// crashes rather than reporting a failure, but a green run here is the
    /// signal that every mutation path that funnels through `commitManifest`
    /// is exclusivity-safe.
    @Test func mutationsCompleteWithoutExclusivityTrap() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let artifact = try archive.addArtifact(.sample(title: "Exclusivity check"))
        try archive.updateMetadata(of: artifact.uid) { $0.notes = "touched" }

        let sourceURL = try TestSupport.makeSourceFile(named: "doc.txt", contents: "evidence")
        let attached = try archive.attachFile(
            copyingFrom: sourceURL, to: artifact.uid, role: .accessCopy)
        try archive.replaceFile(attached.entry.uid, in: artifact.uid, copyingFrom: sourceURL)
        try archive.detachFile(attached.entry.uid, in: artifact.uid)

        try archive.removeArtifact(artifact.uid)

        // Reaching here at all is the assertion; this just confirms the archive
        // is still usable afterwards.
        #expect(archive.artifacts().isEmpty)
    }

    // MARK: - Helpers

    private func currentManifest(root: URL) throws -> Manifest {
        let data = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        return try GeneaLogicJSON.decoder.decode(Manifest.self, from: data)
    }
}

import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The §4.2.1 file-naming invariant (package-assigned, collision-free `path`;
/// `originalName` preserved; case/Unicode-fold collision detection; reserved-name
/// disambiguation) plus `attachFile`/`replaceFile`/`detachFile` correctness.
@Suite struct FileNamingAndAttachmentTests {

    @Test func attachFileAssignsPathAndPreservesOriginalName() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Photo album"))

        let source = try TestSupport.makeSourceFile(named: "Family Photo.jpg", contents: "bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        #expect(attached.entry.originalName == "Family Photo.jpg")
        #expect(attached.entry.path == "family-photo.jpg" || attached.entry.path.contains("Photo"))
        // path is package-assigned: it must exist on disk at the artifact folder.
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        let updated = try #require(archive.artifact(withID: artifact.uid))
        #expect(updated.files.count == 1)
        #expect(updated.files[0].sha256 == attached.entry.sha256)
    }

    @Test func setFileRoleChangesRoleAndReturnsPriorForUndo() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed"))

        let source = try TestSupport.makeSourceFile(named: "deed.pdf", contents: "bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let fileID = attached.entry.uid

        // Change the role: content/uid/path untouched, prior role returned (for undo).
        let prior = try archive.setFileRole(fileID, in: artifact.uid, to: .accessCopy)
        #expect(prior == .preservationMaster)

        let after = try #require(archive.artifact(withID: artifact.uid))
        #expect(after.files.count == 1)
        #expect(after.files[0].uid == fileID)
        #expect(after.files[0].path == attached.entry.path)
        #expect(after.files[0].sha256 == attached.entry.sha256)
        #expect(after.files[0].role == .accessCopy)

        // Undo by setting the returned prior role back.
        let redo = try archive.setFileRole(fileID, in: artifact.uid, to: prior)
        #expect(redo == .accessCopy)
        let restored = try #require(archive.artifact(withID: artifact.uid))
        #expect(restored.files[0].role == .preservationMaster)

        // A no-op change returns the current role and doesn't throw.
        let noop = try archive.setFileRole(fileID, in: artifact.uid, to: .preservationMaster)
        #expect(noop == .preservationMaster)

        // Unknown file / artifact ids throw.
        #expect(throws: ArchiveError.self) {
            try archive.setFileRole(FileID("FIL-missing"), in: artifact.uid, to: .derivative)
        }
        #expect(throws: ArchiveError.self) {
            try archive.setFileRole(fileID, in: ArtifactID("ART-missing"), to: .derivative)
        }
    }

    @Test func fileURLResolvesToTheOnDiskBytes() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Letter"))

        let source = try TestSupport.makeSourceFile(named: "letter.txt", contents: "Dear cousin")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        let url = try #require(archive.fileURL(of: attached.entry.uid, in: artifact.uid))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try String(contentsOf: url, encoding: .utf8) == "Dear cousin")
        let slug = try #require(archive.artifacts().first?.slug)
        #expect(
            url.path == root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)").path
        )

        // Unknown file / artifact ids resolve to nil.
        #expect(archive.fileURL(of: FileID("FIL-missing"), in: artifact.uid) == nil)
        #expect(archive.fileURL(of: attached.entry.uid, in: ArtifactID("ART-missing")) == nil)
    }

    @Test func sameBasenameDisambiguatesWithNumericSuffix() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Census pages"))

        let first = try TestSupport.makeSourceFile(named: "scan.tif", contents: "page one")
        let second = try TestSupport.makeSourceFile(named: "scan.tif", contents: "page two")

        let firstAttached = try archive.attachFile(
            copyingFrom: first, to: artifact.uid, role: .accessCopy)
        let secondAttached = try archive.attachFile(
            copyingFrom: second, to: artifact.uid, role: .accessCopy)

        #expect(firstAttached.entry.path == "scan.tif")
        #expect(secondAttached.entry.path == "scan-2.tif")
        #expect(firstAttached.entry.originalName == "scan.tif")
        #expect(secondAttached.entry.originalName == "scan.tif")
        #expect(firstAttached.entry.uid != secondAttached.entry.uid)
    }

    @Test func caseVariantBasenamesCollideUnderCaseFold() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Mixed-case attachments"))

        let lower = try TestSupport.makeSourceFile(named: "Document.pdf", contents: "v1")
        let upper = try TestSupport.makeSourceFile(named: "DOCUMENT.PDF", contents: "v2")

        let firstAttached = try archive.attachFile(
            copyingFrom: lower, to: artifact.uid, role: .accessCopy)
        let secondAttached = try archive.attachFile(
            copyingFrom: upper, to: artifact.uid, role: .accessCopy)

        #expect(firstAttached.entry.path != secondAttached.entry.path)
        #expect(
            TestSupport.normalizedForComparison(firstAttached.entry.path)
                != TestSupport.normalizedForComparison(secondAttached.entry.path),
            "disambiguation must produce names that don't collide even case-folded"
        )
    }

    @Test func nfcAndNfdVariantsCollide() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Unicode names"))

        // "é" as a single precomposed scalar (NFC) vs. "e" + combining acute
        // (NFD). Swift string *literals* are normalized at compile time, so
        // both forms must be assembled at runtime from explicit scalars to
        // actually differ byte-for-byte (a literal "\u{0065}\u{0301}" would be
        // folded to "\u{00E9}" before this code ever runs).
        let nfc = String(String.UnicodeScalarView([Unicode.Scalar(0x00E9)!])) + "le.txt"  // "éle.txt" (NFC)
        let nfd =
            String(String.UnicodeScalarView([Unicode.Scalar(0x0065)!, Unicode.Scalar(0x0301)!]))
            + "le.txt"  // "éle.txt" (NFD: e + combining acute)
        // `String.==` is canonical-equivalence-aware (NFC/NFD compare equal!),
        // so the meaningful "these are different on-disk byte sequences" check
        // has to happen below the `String` abstraction, via UTF-8 byte count —
        // exactly the level at which two filesystem entries would actually
        // collide or not.
        #expect(
            Array(nfc.utf8).count != Array(nfd.utf8).count,
            "the two source names must actually differ byte-for-byte (NFC vs. NFD)")
        #expect(
            nfc.precomposedStringWithCanonicalMapping == nfd.precomposedStringWithCanonicalMapping,
            "the two forms must be canonically equivalent for this test to be meaningful")

        let first = try TestSupport.makeSourceFile(named: nfc, contents: "v1")
        let second = try TestSupport.makeSourceFile(named: nfd, contents: "v2")

        let firstAttached = try archive.attachFile(
            copyingFrom: first, to: artifact.uid, role: .accessCopy)
        let secondAttached = try archive.attachFile(
            copyingFrom: second, to: artifact.uid, role: .accessCopy)

        #expect(firstAttached.entry.path != secondAttached.entry.path)
        #expect(
            Array(firstAttached.entry.path.utf8) != Array(secondAttached.entry.path.utf8),
            "the stored paths must differ at the byte level — String.== is canonical-equivalence-aware and could mask an on-disk collision"
        )
        #expect(
            TestSupport.normalizedForComparison(firstAttached.entry.path)
                != TestSupport.normalizedForComparison(secondAttached.entry.path),
            "disambiguation must produce names that don't collide even case/NFC-folded"
        )
    }

    @Test func nameSanitizingToRecordJSONIsDisambiguatedAway() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Reserved-name collision"))

        // "RECORD.JSON" sanitizes/normalizes to the reserved `record.json`.
        let source = try TestSupport.makeSourceFile(named: "RECORD.JSON", contents: "not a record")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .derivative)

        #expect(TestSupport.normalizedForComparison(attached.entry.path) != "record.json")
        #expect(TestSupport.normalizedForComparison(attached.entry.path) != "manifest.json")
        // It must have been disambiguated to something like "record-2.json".
        #expect(attached.entry.path != "RECORD.JSON")
    }

    /// The `uid` is the stable reference; the path moves to a fresh name derived
    /// from the replacement (slice 65, fork d), and the old bytes are gone — a
    /// replace never overwrites in place, so a crash cannot leave new bytes under
    /// the old hash.
    @Test func replaceFilePreservesUidAndMovesToAFreshPath() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Replaceable"))

        let original = try TestSupport.makeSourceFile(named: "page.txt", contents: "version one")
        let attached = try archive.attachFile(
            copyingFrom: original, to: artifact.uid, role: .accessCopy)
        let originalSHA = attached.entry.sha256
        let originalPath = attached.entry.path

        let replacement = try TestSupport.makeSourceFile(
            named: "page-v2.txt", contents: "version two — much longer content than before")
        try archive.replaceFile(attached.entry.uid, in: artifact.uid, copyingFrom: replacement)

        let updated = try #require(archive.artifact(withID: artifact.uid))
        let entry = try #require(updated.files.first { $0.uid == attached.entry.uid })

        #expect(entry.uid == attached.entry.uid)
        #expect(entry.path == "page-v2.txt")
        #expect(entry.sha256 != originalSHA)
        #expect(entry.originalName == "page-v2.txt")

        // The manifest describes the new path with the new checksum, and the old
        // path is gone from both the manifest and the disk.
        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: manifestData)
        let slug = try #require(archive.artifacts().first?.slug)
        let manifestEntry = try #require(
            manifest.files.first { $0.path == "artifacts/\(slug)/\(entry.path)" })
        #expect(manifestEntry.sha256 == entry.sha256)
        #expect(manifestEntry.byteLength == entry.byteLength)
        #expect(!manifest.files.contains { $0.path == "artifacts/\(slug)/\(originalPath)" })
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("artifacts/\(slug)/\(originalPath)").path))
        #expect(try archive.verifyIntegrity().isClean)
    }

    @Test func replaceFileThrowsForUnknownFile() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "No files yet"))
        let bogus = FileID("FIL-does-not-exist")
        let source = try TestSupport.makeSourceFile()

        #expect(throws: ArchiveError.fileNotFound(bogus, on: artifact.uid)) {
            try archive.replaceFile(bogus, in: artifact.uid, copyingFrom: source)
        }
    }

    @Test func detachFileRemovesEntryAndOnDiskContentAndManifestEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Detachable"))
        let source = try TestSupport.makeSourceFile(named: "temp.txt", contents: "ephemeral")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .derivative)
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")
        #expect(FileManager.default.fileExists(atPath: onDisk.path))

        try archive.detachFile(attached.entry.uid, in: artifact.uid)

        #expect(!FileManager.default.fileExists(atPath: onDisk.path))
        let updated = try #require(archive.artifact(withID: artifact.uid))
        #expect(updated.files.isEmpty)

        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: manifestData)
        #expect(!manifest.files.contains { $0.path.contains(attached.entry.path) })
    }

    // MARK: - Reversible file ops (revert / app-layer undo)

    @Test func revertOfDetachRestoresTheExactFileAndRedoRemovesItAgain() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Reversible detach"))
        let source = try TestSupport.makeSourceFile(named: "scan.txt", contents: "original bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")

        let change = try archive.detachFile(attached.entry.uid, in: artifact.uid)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try #require(archive.artifact(withID: artifact.uid)).files.isEmpty)

        // Undo: the exact entry (uid, path, sha256) and its bytes come back.
        let redo = try archive.revert(change)
        let restored = try #require(archive.artifact(withID: artifact.uid))
        let entry = try #require(restored.files.first)
        #expect(entry.uid == attached.entry.uid)
        #expect(entry.path == attached.entry.path, "the free original path is reused")
        #expect(entry.sha256 == attached.entry.sha256)
        #expect(try Data(contentsOf: onDisk) == Data("original bytes".utf8))

        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: manifestData)
        #expect(manifest.files.contains { $0.path == "artifacts/\(slug)/\(entry.path)" })

        // Redo (revert the revert): the file is removed again.
        _ = try archive.revert(redo)
        #expect(try #require(archive.artifact(withID: artifact.uid)).files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))
    }

    @Test func revertOfReplaceRestoresPriorContentAndRoundTrips() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Reversible replace"))
        let v1 = try TestSupport.makeSourceFile(named: "page.txt", contents: "version one")
        let attached = try archive.attachFile(copyingFrom: v1, to: artifact.uid, role: .accessCopy)
        let slug = try #require(archive.artifacts().first?.slug)
        func onDisk(_ path: String) -> URL {
            root.appendingPathComponent("artifacts/\(slug)/\(path)")
        }

        let v2 = try TestSupport.makeSourceFile(
            named: "page-v2.txt", contents: "version two is longer")
        let change = try archive.replaceFile(attached.entry.uid, in: artifact.uid, copyingFrom: v2)
        #expect(try Data(contentsOf: onDisk("page-v2.txt")) == Data("version two is longer".utf8))

        // Undo: the prior entry comes back verbatim — its path too, since it is
        // free again (slice 65 moved the replacement to a fresh one).
        let redo = try archive.revert(change)
        let restored = try #require(
            archive.artifact(withID: artifact.uid)?.files.first { $0.uid == attached.entry.uid })
        #expect(restored.sha256 == attached.entry.sha256)
        #expect(restored.originalName == "page.txt")
        #expect(restored.path == attached.entry.path)
        #expect(try Data(contentsOf: onDisk(restored.path)) == Data("version one".utf8))
        #expect(!FileManager.default.fileExists(atPath: onDisk("page-v2.txt").path))

        // Redo: the replacement content comes back.
        _ = try archive.revert(redo)
        let again = try #require(
            archive.artifact(withID: artifact.uid)?.files.first { $0.uid == attached.entry.uid })
        #expect(again.originalName == "page-v2.txt")
        #expect(try Data(contentsOf: onDisk(again.path)) == Data("version two is longer".utf8))
        #expect(try archive.verifyIntegrity().isClean)
    }

    @Test func revertOfAttachRemovesTheFileAndRedoReaddsIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Reversible attach"))
        let source = try TestSupport.makeSourceFile(named: "added.txt", contents: "freshly added")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .derivative)
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")

        // The caller models an attach as a `.added` change to undo it.
        let change = FileChange(artifactID: artifact.uid, operation: .added(attached.entry))
        let redo = try archive.revert(change)
        #expect(try #require(archive.artifact(withID: artifact.uid)).files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))

        // Redo re-adds the same file, bytes intact.
        _ = try archive.revert(redo)
        let entry = try #require(archive.artifact(withID: artifact.uid)?.files.first)
        #expect(entry.uid == attached.entry.uid)
        #expect(
            try Data(contentsOf: root.appendingPathComponent("artifacts/\(slug)/\(entry.path)"))
                == Data("freshly added".utf8))
    }

    // MARK: - Detached-file trash (persisted, cross-session recovery)

    @Test func detachFileMovesBytesToTrashAndListsThere() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Has a deletable file"))
        let source = try TestSupport.makeSourceFile(named: "cert.pdf", contents: "certificate")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")

        try archive.detachFile(attached.entry.uid, in: artifact.uid)

        // Gone from the artifact + disk, but parked under .trash/<file-uid>/payload.
        #expect(!FileManager.default.fileExists(atPath: onDisk.path))
        #expect(try #require(archive.artifact(withID: artifact.uid)).files.isEmpty)
        let payload = root.appendingPathComponent(".trash/\(attached.entry.uid.raw)/payload")
        #expect(try Data(contentsOf: payload) == Data("certificate".utf8))

        let trashed = archive.trashedFiles()
        #expect(trashed.count == 1)
        #expect(trashed.first?.uid == attached.entry.uid)
        #expect(trashed.first?.originalName == "cert.pdf")
        #expect(trashed.first?.artifactTitle == "Has a deletable file")
        #expect(!(trashed.first?.deletedAt.isEmpty ?? true))
    }

    @Test func restoreFileReattachesItAndClearsEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Recoverable file"))
        let source = try TestSupport.makeSourceFile(named: "scan.txt", contents: "scan bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)

        try archive.detachFile(attached.entry.uid, in: artifact.uid)
        let restored = try archive.restoreFile(attached.entry.uid)

        #expect(restored.uid == attached.entry.uid)
        #expect(restored.path == attached.entry.path, "the free original path is reused")
        #expect(restored.sha256 == attached.entry.sha256)
        let live = try #require(archive.artifact(withID: artifact.uid))
        #expect(live.files.contains { $0.uid == attached.entry.uid })
        // The trash entry is consumed and the bytes are back in the artifact folder.
        #expect(archive.trashedFiles().isEmpty)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".trash/\(attached.entry.uid.raw)").path))
        let slug = try #require(archive.artifacts().first?.slug)
        let bytes = try Data(
            contentsOf: root.appendingPathComponent("artifacts/\(slug)/\(restored.path)"))
        #expect(bytes == Data("scan bytes".utf8))
    }

    @Test func restoreFileThrowsForUnknownUid() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = FileID("FIL-not-trashed")

        #expect(throws: ArchiveError.fileTrashEntryNotFound(bogus)) {
            _ = try archive.restoreFile(bogus)
        }
    }

    @Test func restoreFileThrowsWhenOwningArtifactIsGone() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Doomed owner"))
        let source = try TestSupport.makeSourceFile(named: "f.txt", contents: "bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)

        try archive.detachFile(attached.entry.uid, in: artifact.uid)
        // The artifact the file belonged to is deleted; the file can't be re-homed.
        try archive.removeArtifact(artifact.uid)

        #expect(throws: ArchiveError.artifactNotFound(artifact.uid)) {
            _ = try archive.restoreFile(attached.entry.uid)
        }
        // The file's trash entry survives the failed restore (still recoverable if the
        // artifact comes back).
        #expect(archive.trashedFiles().count == 1)
    }

    @Test func detachFileWithMissingBytesMakesRecordOnlyEntryThatRestoresTheEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Out-of-band edited"))
        let source = try TestSupport.makeSourceFile(named: "g.txt", contents: "bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .derivative)
        let slug = try #require(archive.artifacts().first?.slug)
        let onDisk = root.appendingPathComponent("artifacts/\(slug)/\(attached.entry.path)")

        // Simulate an out-of-band deletion of the bytes before the user detaches.
        try FileManager.default.removeItem(at: onDisk)
        try archive.detachFile(attached.entry.uid, in: artifact.uid)

        // A record-only trash entry: listed, but no payload bytes.
        #expect(archive.trashedFiles().count == 1)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".trash/\(attached.entry.uid.raw)/payload").path
            )
        )

        // Restore re-adds the entry (without content); integrity then flags the gap.
        let restored = try archive.restoreFile(attached.entry.uid)
        #expect(restored.uid == attached.entry.uid)
        #expect(try #require(archive.artifact(withID: artifact.uid)).files.count == 1)
        #expect(archive.trashedFiles().isEmpty)
    }

    @Test func deleteFileFromTrashRemovesOnlyThatEntry() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Two files"))
        let keepSrc = try TestSupport.makeSourceFile(named: "keep.txt", contents: "keep")
        let purgeSrc = try TestSupport.makeSourceFile(named: "purge.txt", contents: "purge")
        let keep = try archive.attachFile(copyingFrom: keepSrc, to: artifact.uid, role: .derivative)
        let purge = try archive.attachFile(
            copyingFrom: purgeSrc, to: artifact.uid, role: .derivative)

        try archive.detachFile(keep.entry.uid, in: artifact.uid)
        try archive.detachFile(purge.entry.uid, in: artifact.uid)
        try archive.deleteFileFromTrash(purge.entry.uid)

        let remaining = archive.trashedFiles()
        #expect(remaining.count == 1)
        #expect(remaining.first?.uid == keep.entry.uid)
        #expect(throws: Never.self) { _ = try archive.restoreFile(keep.entry.uid) }
        #expect(throws: ArchiveError.fileTrashEntryNotFound(purge.entry.uid)) {
            _ = try archive.restoreFile(purge.entry.uid)
        }
    }

    @Test func emptyTrashClearsBothTrashedArtifactsAndFiles() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addArtifact(.sample(title: "Whole artifact"))
        let b = try archive.addArtifact(.sample(title: "Has a detached file"))
        let src = try TestSupport.makeSourceFile(named: "h.txt", contents: "bytes")
        let file = try archive.attachFile(copyingFrom: src, to: b.uid, role: .derivative)

        try archive.detachFile(file.entry.uid, in: b.uid)
        try archive.removeArtifact(a.uid)
        #expect(archive.trashedArtifacts().count == 1)
        #expect(archive.trashedFiles().count == 1)

        try archive.emptyTrash()

        #expect(archive.trashedArtifacts().isEmpty)
        #expect(archive.trashedFiles().isEmpty)
    }

    @Test func verifyIntegrityIgnoresTrashedFileBytes() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Detach keeps it clean"))
        let src = try TestSupport.makeSourceFile(named: "i.txt", contents: "payload")
        let attached = try archive.attachFile(copyingFrom: src, to: artifact.uid, role: .accessCopy)

        try archive.detachFile(attached.entry.uid, in: artifact.uid)

        // The trashed file under .trash/ must not surface as an unreferenced/stray file
        // (the sweep is scoped to artifacts/, and .trash/ is a sibling).
        #expect(try archive.verifyIntegrity().isClean)
    }

    @Test func attachFileSurfacesByteIdenticalDuplicatesWithoutSkippingTheCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Duplicate content"))

        let original = try TestSupport.makeSourceFile(named: "a.txt", contents: "identical bytes")
        let duplicate = try TestSupport.makeSourceFile(named: "b.txt", contents: "identical bytes")

        let firstAttached = try archive.attachFile(
            copyingFrom: original, to: artifact.uid, role: .accessCopy)
        #expect(firstAttached.duplicatesOf.isEmpty)

        let secondAttached = try archive.attachFile(
            copyingFrom: duplicate, to: artifact.uid, role: .accessCopy)
        #expect(secondAttached.duplicatesOf.map(\.uid) == [firstAttached.entry.uid])

        // Both are still stored — attachFile never silently skips the copy.
        let updated = try #require(archive.artifact(withID: artifact.uid))
        #expect(updated.files.count == 2)
    }
}

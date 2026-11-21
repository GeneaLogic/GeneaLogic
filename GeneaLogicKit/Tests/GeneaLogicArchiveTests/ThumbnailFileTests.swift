import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The browse summary's choice of the file a list draws (slice 84b).
@Suite struct ThumbnailFileTests {

    private func attach(
        _ name: String, _ role: FileRole, to id: ArtifactID, in archive: Archive,
        contents: String = "bytes"
    ) throws -> FileEntry {
        let source = try TestSupport.makeSourceFile(named: name, contents: contents)
        return try archive.attachFile(copyingFrom: source, to: id, role: role).entry
    }

    private func thumbnail(_ id: ArtifactID, in archive: Archive) -> ArtifactSummary.ThumbnailFile?
    {
        archive.artifacts().first { $0.uid == id }?.thumbnailFile
    }

    @Test func anAccessCopyComesBeforeAPreservationMaster() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        _ = try attach("master.tiff", .preservationMaster, to: artifact.uid, in: archive)
        let access = try attach("access.jpg", .accessCopy, to: artifact.uid, in: archive)

        #expect(thumbnail(artifact.uid, in: archive)?.uid == access.uid)
    }

    @Test func aPreservationMasterComesBeforeADerivative() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        _ = try attach("crop.png", .derivative, to: artifact.uid, in: archive)
        let master = try attach("scan.PDF", .preservationMaster, to: artifact.uid, in: archive)

        #expect(thumbnail(artifact.uid, in: archive)?.uid == master.uid)
    }

    @Test func anUndrawableAccessCopyFallsThroughToADrawableMaster() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        _ = try attach("reading.mp3", .accessCopy, to: artifact.uid, in: archive)
        let master = try attach("scan.tif", .preservationMaster, to: artifact.uid, in: archive)

        #expect(thumbnail(artifact.uid, in: archive)?.uid == master.uid)
    }

    @Test func noDrawableFileMeansNoThumbnail() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let bare = try archive.addArtifact(.sample(title: "No files"))
        let artifact = try archive.addArtifact(.sample())
        _ = try attach("letter.txt", .accessCopy, to: artifact.uid, in: archive)
        // A transcript is never drawn, whatever its type.
        _ = try attach("transcript.pdf", .transcript, to: artifact.uid, in: archive)

        #expect(thumbnail(bare.uid, in: archive) == nil)
        #expect(thumbnail(artifact.uid, in: archive) == nil)
    }

    @Test func thePathIsRelativeToTheArchiveRoot() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        let entry = try attach("scan.png", .accessCopy, to: artifact.uid, in: archive)

        let file = try #require(thumbnail(artifact.uid, in: archive))
        #expect(file.sha256 == entry.sha256)
        #expect(
            archive.rootURL.appendingPathComponent(file.path).standardizedFileURL
                == archive.fileURL(of: entry.uid, in: artifact.uid)?.standardizedFileURL)
    }

    @Test func aReplaceMovesTheThumbnailToTheNewBytes() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        let entry = try attach("scan.png", .accessCopy, to: artifact.uid, in: archive)
        let before = try #require(thumbnail(artifact.uid, in: archive))

        let newer = try TestSupport.makeSourceFile(named: "rescan.jpg", contents: "other bytes")
        try archive.replaceFile(entry.uid, in: artifact.uid, copyingFrom: newer)
        let after = try #require(thumbnail(artifact.uid, in: archive))

        // Same file, new bytes: the cache key moves with them.
        #expect(after.uid == before.uid)
        #expect(after.sha256 != before.sha256)
        #expect(after.path != before.path)
        #expect(
            FileManager.default.fileExists(
                atPath: archive.rootURL.appendingPathComponent(after.path).path))
    }

    @Test func aReplaceWithAnUndrawableFileFallsBackToTheNextRole() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        let access = try attach("access.jpg", .accessCopy, to: artifact.uid, in: archive)
        let master = try attach("master.tiff", .preservationMaster, to: artifact.uid, in: archive)

        let text = try TestSupport.makeSourceFile(named: "access.txt", contents: "now text")
        try archive.replaceFile(access.uid, in: artifact.uid, copyingFrom: text)

        #expect(thumbnail(artifact.uid, in: archive)?.uid == master.uid)
    }

    @Test func aDetachMovesTheThumbnailOn() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let artifact = try archive.addArtifact(.sample())
        let access = try attach("access.jpg", .accessCopy, to: artifact.uid, in: archive)
        let master = try attach("master.tiff", .preservationMaster, to: artifact.uid, in: archive)

        try archive.detachFile(access.uid, in: artifact.uid)
        #expect(thumbnail(artifact.uid, in: archive)?.uid == master.uid)
    }
}

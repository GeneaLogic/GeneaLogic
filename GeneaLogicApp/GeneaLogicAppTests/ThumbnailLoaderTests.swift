import CoreGraphics
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import GeneaLogicApp

/// Slice 84b — what the sidebar's thumbnail loader draws and what it refuses. The decodes
/// run on the loader's own queue, so these also catch it being isolated to the main actor
/// (the app's default) by mistake.
@MainActor
@Suite struct ThumbnailLoaderTests {
    private let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbnailLoaderTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A file record for `url` as written, under a checksum no other test shares (the
    /// loader's cache is process-wide).
    private func record(_ url: URL, lengthOffset: Int64 = 0) throws -> ArtifactSummary.ThumbnailFile
    {
        let length = try #require(
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
        return ArtifactSummary.ThumbnailFile(
            uid: FileID("FIL-\(UUID().uuidString)"), path: url.lastPathComponent,
            byteLength: length + lengthOffset, sha256: UUID().uuidString)
    }

    private func png(width: Int, height: Int) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.black)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    private func pdf(width: CGFloat, height: CGFloat, password: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        var info: [CFString: Any] = [:]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password
        }
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.fill(box.insetBy(dx: 10, dy: 10))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private func load(_ file: ArtifactSummary.ThumbnailFile, _ url: URL) async -> CGImage? {
        await ThumbnailLoader.shared.image(for: file, at: url, pixels: 64)
    }

    @Test func anImageIsDrawnWholeAndScaledToFit() async throws {
        let url = try png(width: 400, height: 200)
        let image = try #require(await load(try record(url), url))
        #expect(image.width == 64)
        #expect(image.height == 32)
    }

    @Test func aPDFsFirstPageIsDrawnWhole() async throws {
        let url = try pdf(width: 792, height: 612)
        let image = try #require(await load(try record(url), url))
        #expect(image.width == 64)
        #expect(abs(image.height - 49) <= 1)
    }

    /// Still arriving, or damaged: either way not the recorded bytes. Asked again once the
    /// length is right, so the refusal isn't remembered.
    @Test func aFileOfTheWrongLengthIsNotDrawnUntilItIsWhole() async throws {
        let url = try png(width: 40, height: 40)
        let whole = try record(url)
        var arriving = whole
        arriving.byteLength += 1
        #expect(await load(arriving, url) == nil)
        #expect(await load(whole, url) != nil)
    }

    /// A cache hit still looks at the file: one deleted after it was drawn keeps its
    /// symbol at once, without waiting for the size sweep.
    @Test func aFileDeletedAfterItWasDrawnIsNotDrawnAgain() async throws {
        let url = try png(width: 40, height: 40)
        let file = try record(url)
        #expect(await load(file, url) != nil)
        try FileManager.default.removeItem(at: url)
        #expect(await load(file, url) == nil)
    }

    /// Overwritten in place at the same length — damage only Verify Integrity's hashes
    /// see — it is drawn from what is there now, not shown as it was (84b's hand-test).
    @Test func aFileOverwrittenInPlaceIsDrawnFromItsNewBytes() async throws {
        let url = try png(width: 40, height: 40)
        let file = try record(url)
        #expect(await load(file, url) != nil)

        let length = Int(file.byteLength)
        try Data(count: length).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        #expect(await load(file, url) == nil)
    }

    /// Two archives holding the same file share a checksum, not a thumbnail: each copy is
    /// judged on its own bytes (84b's hand-test).
    @Test func twoCopiesOfOneFileAreJudgedSeparately() async throws {
        let good = try png(width: 40, height: 40)
        let file = try record(good)
        let zeroed = directory.appendingPathComponent("zeroed.png")
        try Data(count: Int(file.byteLength)).write(to: zeroed)

        #expect(await load(file, good) != nil)
        #expect(await load(file, zeroed) == nil)
    }

    @Test func aMissingFileIsNotDrawn() async throws {
        let url = directory.appendingPathComponent("gone.png")
        let file = ArtifactSummary.ThumbnailFile(
            uid: FileID("FIL-gone"), path: "gone.png", byteLength: 10, sha256: UUID().uuidString)
        #expect(await load(file, url) == nil)
    }

    @Test func aWholeFileThatWontDecodeIsNotDrawn() async throws {
        let url = directory.appendingPathComponent("noise.png")
        try Data("not an image".utf8).write(to: url)
        #expect(await load(try record(url), url) == nil)
    }

    /// A locked PDF draws nothing on its white page; it keeps its symbol instead.
    @Test func aLockedPDFIsNotDrawn() async throws {
        let url = try pdf(width: 612, height: 792, password: "secret")
        #expect(await load(try record(url), url) == nil)
    }

    @Test func aCancelledRequestGetsNothing() async throws {
        let url = try png(width: 40, height: 40)
        let file = try record(url)
        let task = Task { await ThumbnailLoader.shared.image(for: file, at: url, pixels: 64) }
        task.cancel()
        #expect(await task.value == nil)
    }

    /// Two rows asking for one file at once share a decode and both get the picture.
    @Test func concurrentRequestsForOneFileBothGetIt() async throws {
        let url = try png(width: 300, height: 300)
        let file = try record(url)
        async let first = ThumbnailLoader.shared.image(for: file, at: url, pixels: 64)
        async let second = ThumbnailLoader.shared.image(for: file, at: url, pixels: 64)
        let (a, b) = await (first, second)
        #expect(a != nil)
        #expect(a === b)
    }
}

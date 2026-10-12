import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicExtract

#if canImport(ImageIO)
import ImageIO

/// Real-fixture tests for `ImageIOMetadataExtractor`. Fixtures are synthesized
/// at runtime in a temp directory — no binary assets are committed.
@Suite struct ImageIOMetadataExtractorTests {

    @Test func extractsExifDateTimeOriginal() throws {
        let url = try makeJPEG(
            withProperties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "1920:01:01 00:00:00"
                ]
            ])
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = ImageIOMetadataExtractor()
        let metadata = try extractor.extract(from: url)

        let key = EmbeddedMetadataKey(namespace: "exif", name: "DateTimeOriginal")
        #expect(metadata[key] == .string("1920:01:01 00:00:00"))
    }

    @Test func entriesAreSortedByNamespaceAndName() throws {
        let url = try makeJPEG(
            withProperties: [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "1920:01:01 00:00:00",
                    kCGImagePropertyExifFNumber: 2.8,
                ]
            ])
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = ImageIOMetadataExtractor()
        let metadata = try extractor.extract(from: url)

        #expect(!metadata.entries.isEmpty)
        let keys = metadata.entries.map(\.key)
        #expect(keys == keys.sorted())
    }

    @Test func nonImageInputReturnsEmptyMetadata() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let extractor = ImageIOMetadataExtractor()
        let metadata = try extractor.extract(from: url)

        #expect(metadata.isEmpty)
    }

    /// Synthesizes a 1×1 JPEG at a temp URL with the given ImageIO properties
    /// (e.g. an EXIF sub-dictionary) embedded.
    private func makeJPEG(withProperties properties: [CFString: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jpg")

        let width = 1
        let height = 1
        var pixel: [UInt8] = [0, 0, 0, 255]

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: &pixel,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let image = context.makeImage()
        else {
            throw TestSetupError.imageCreationFailed
        }

        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, "public.jpeg" as CFString, 1, nil)
        else {
            throw TestSetupError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw TestSetupError.finalizeFailed
        }

        return url
    }

    private enum TestSetupError: Error {
        case imageCreationFailed
        case destinationCreationFailed
        case finalizeFailed
    }
}
#endif

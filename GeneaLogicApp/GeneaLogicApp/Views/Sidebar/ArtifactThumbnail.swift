import CoreGraphics
import Foundation
import GeneaLogicArchive
import ImageIO
import SwiftUI

/// An artifact row's leading image: a thumbnail of its first image or PDF (slice 84b),
/// the media type's symbol until one arrives, and for good when there is none to draw.
///
/// **The whole page, scaled to fit** a square, not cropped (agreed 2026-11-19): a scan's
/// shape is part of telling one from another. Every artifact row gets the same square
/// slot, so titles line up whether or not a row has a thumbnail.
struct ArtifactThumbnail: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.displayScale) private var displayScale
    let summary: ArtifactSummary
    @State private var image: CGImage?

    static let side: CGFloat = 32

    /// What a load depends on: the file's bytes, and the pixels this display needs.
    private struct LoadKey: Hashable {
        var file: ArtifactSummary.ThumbnailFile?
        var pixels: Int
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay { Rectangle().strokeBorder(.separator, lineWidth: 0.5) }
            } else {
                SidebarSymbol(name: summary.mediaType.systemImage)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .task(id: LoadKey(file: summary.thumbnailFile, pixels: pixels)) {
            guard let file = summary.thumbnailFile, let root = model.archive?.rootURL else {
                image = nil
                return
            }
            // A replace keeps the old picture up until the new one is drawn, rather than
            // flashing the symbol between them.
            image = await ArtifactThumbnails.image(for: file, in: root, pixels: pixels)
        }
    }

    private var pixels: Int { Int((Self.side * displayScale).rounded()) }
}

/// Draws and caches artifact thumbnails, in-process as the preview pane does: ImageIO for
/// images (it downsamples a large scan without decoding all of it, and uses an embedded
/// thumbnail when there is one), Core Graphics for a PDF's first page. **Not Quick
/// Look**, whose generators fail or stall in the sandbox (`FilePreviewContent`).
///
/// **Never a file that isn't on this Mac.** Reading a dataless file downloads it (57b),
/// so scrolling a synced archive's sidebar would download every scan. Such a file, or a
/// missing one, keeps its symbol and is asked again next time, since it may have arrived
/// by then. A file that is here but doesn't decode is remembered, so it isn't retried on
/// every scroll.
///
/// **Memory only** (84b, fork 2), keyed by the file's checksum so a replace draws anew.
@MainActor
enum ArtifactThumbnails {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 64 << 20
        return cache
    }()

    /// Checksums of files that are on this Mac and didn't decode.
    private static var undrawable: Set<String> = []

    static func image(
        for file: ArtifactSummary.ThumbnailFile, in root: URL, pixels: Int
    ) async -> CGImage? {
        let key = "\(file.sha256)@\(pixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        guard !undrawable.contains(file.sha256) else { return nil }

        switch await render(root.appendingPathComponent(file.path), pixels: pixels) {
        case .drawn(let image):
            cache.setObject(Box(image), forKey: key, cost: image.bytesPerRow * image.height)
            return image
        case .undrawable:
            undrawable.insert(file.sha256)
            return nil
        case .notOnThisMac:
            return nil
        }
    }

    enum Rendered: Sendable {
        case drawn(CGImage)
        case undrawable
        case notOnThisMac
    }

    @concurrent
    nonisolated static func render(_ url: URL, pixels: Int) async -> Rendered {
        guard FileManager.default.fileExists(atPath: url.path),
            !Archive.fileIsDataless(at: url)
        else { return .notOnThisMac }
        let image =
            url.pathExtension.lowercased() == "pdf"
            ? renderPDF(url, pixels: pixels) : renderImage(url, pixels: pixels)
        return image.map(Rendered.drawn) ?? .undrawable
    }

    private nonisolated static func renderImage(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            // Decode here, off the main thread, not lazily when the row first draws.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The first page on white, its rotation applied, its longer side `pixels` long.
    private nonisolated static func renderPDF(_ url: URL, pixels: Int) -> CGImage? {
        guard let page = CGPDFDocument(url as CFURL)?.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let turned = page.rotationAngle % 180 != 0
        let pageSize = turned ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scale = CGFloat(pixels) / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white)
        context.fill(rect)
        // Scale first, then let the page's own transform rotate and centre it: the
        // drawing transform never scales up, so it is given the page at its target size.
        context.scaleBy(x: scale, y: scale)
        let scaledRect = CGRect(
            x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        context.concatenate(
            page.getDrawingTransform(
                .cropBox, rect: scaledRect, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

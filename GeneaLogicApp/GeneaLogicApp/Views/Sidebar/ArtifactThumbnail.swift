import CoreGraphics
import Foundation
import GeneaLogicArchive
import ImageIO
import Synchronization
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

    /// What a load depends on. `generation` is there so a row still on screen asks again
    /// after a change lands — a delivery bringing its file, say — since nothing else about
    /// the row need change when a file it couldn't draw arrives.
    private struct LoadKey: Hashable {
        var file: ArtifactSummary.ThumbnailFile?
        var pixels: Int
        var damaged: Bool
        var generation: Int
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
        .task(id: loadKey) {
            // A file the size sweep found missing or the wrong length keeps its symbol.
            guard let file = summary.thumbnailFile, !loadKey.damaged,
                let archive = model.archive
            else {
                image = nil
                return
            }
            // A replace keeps the old picture up until the new one is drawn, rather than
            // flashing the symbol between them; so does a superseded load.
            let drawn = await ThumbnailLoader.shared.image(
                for: file, at: archive.url(of: file), pixels: pixels)
            if !Task.isCancelled { image = drawn }
        }
    }

    private var pixels: Int { Int((Self.side * displayScale).rounded()) }

    private var loadKey: LoadKey {
        let file = summary.thumbnailFile
        return LoadKey(
            file: file, pixels: pixels,
            damaged: file.map { model.fileDamage?.paths.contains($0.path) == true } ?? false,
            generation: model.mutationVersion)
    }
}

/// Draws and caches artifact thumbnails, in-process as the preview pane does: ImageIO for
/// images (it downsamples a large scan without decoding all of it, and uses an embedded
/// thumbnail when there is one that fits), Core Graphics for a PDF's first page. **Not
/// Quick Look**, whose generators fail or stall in the sandbox (`FilePreviewContent`).
///
/// **On its own queue, two at a time, not the cooperative pool.** A decode blocks on file
/// reads, and a fast scroll asks for hundreds; parked there they would starve the app's
/// other async work, for the reason `ArchiveModel.writeQueue` is a queue. **Only what a
/// row still wants is drawn:** requests for one file at one size share a decode, a row
/// that scrolls away withdraws its request, and a queued decode nobody wants is skipped.
///
/// **Never a file that isn't on this Mac,** or isn't the one recorded. Reading a dataless
/// file downloads it (57b), so scrolling a synced archive would download every scan, and a
/// file of the wrong length is still arriving or damaged. Either keeps its symbol and is
/// asked again next time, since it may be whole by then. A whole file that won't decode is
/// remembered with its size and date, so it isn't re-read on every scroll but is once it
/// is rewritten.
///
/// **Memory only** (84b, fork 2), keyed by the file's checksum so a replace draws anew.
///
/// **`nonisolated`, explicitly:** the app's default isolation is the main actor, and the
/// decodes run on `queue`'s threads.
nonisolated final class ThumbnailLoader: Sendable {
    static let shared = ThumbnailLoader()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private struct State {
        /// The requests waiting on each decode, by cache key. An entry with no waiters
        /// left is a decode queued for nobody.
        var waiting: [String: [UUID: CheckedContinuation<CGImage?, Never>]] = [:]
        /// Whole files that didn't decode, by checksum, size and modification date.
        var undrawable: Set<String> = []
    }

    /// NSCache is thread-safe; it is not annotated `Sendable`.
    private nonisolated(unsafe) let cache: NSCache<NSString, Box>
    private let state = Mutex(State())
    private let queue: OperationQueue

    private init() {
        cache = NSCache()
        cache.totalCostLimit = 64 << 20
        queue = OperationQueue()
        queue.name = "com.genealogic.app.thumbnails"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .utility
    }

    /// The thumbnail of `file`, at `url`, `pixels` on its longer side; `nil` when there
    /// is nothing to draw yet or ever, or the caller was cancelled.
    func image(
        for file: ArtifactSummary.ThumbnailFile, at url: URL, pixels: Int
    ) async -> CGImage? {
        let key = "\(file.sha256)@\(pixels)"
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let first: Bool? = state.withLock { state in
                    guard !Task.isCancelled else { return nil }
                    let first = state.waiting[key] == nil
                    state.waiting[key, default: [:]][id] = continuation
                    return first
                }
                switch first {
                case nil: continuation.resume(returning: nil)
                case true?:
                    queue.addOperation { self.run(key, file: file, url: url, pixels: pixels) }
                case false?: break
                }
            }
        } onCancel: {
            state.withLock { $0.waiting[key]?.removeValue(forKey: id) }?
                .resume(returning: nil)
        }
    }

    private func run(_ key: String, file: ArtifactSummary.ThumbnailFile, url: URL, pixels: Int) {
        let wanted = state.withLock { state in
            guard state.waiting[key]?.isEmpty == false else {
                state.waiting[key] = nil
                return false
            }
            return true
        }
        guard wanted else { return }
        let image = draw(file, at: url, pixels: pixels)
        if let image {
            cache.setObject(
                Box(image), forKey: key as NSString, cost: image.bytesPerRow * image.height)
        }
        let waiters = state.withLock { $0.waiting.removeValue(forKey: key) } ?? [:]
        for waiter in waiters.values { waiter.resume(returning: image) }
    }

    private func draw(_ file: ArtifactSummary.ThumbnailFile, at url: URL, pixels: Int) -> CGImage? {
        var st = stat()
        let found = url.withUnsafeFileSystemRepresentation { path in
            path.map { stat($0, &st) == 0 } ?? false
        }
        guard found, !Archive.isDataless(st), Int64(st.st_size) == file.byteLength else {
            return nil
        }
        let memo =
            "\(file.sha256) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        guard !state.withLock({ $0.undrawable.contains(memo) }) else { return nil }
        let image =
            url.pathExtension.lowercased() == "pdf"
            ? Self.renderPDF(url, pixels: pixels) : Self.renderImage(url, pixels: pixels)
        if image == nil { state.withLock { _ = $0.undrawable.insert(memo) } }
        return image
    }

    /// An embedded thumbnail when its shape matches the image's, else one drawn from the
    /// image. An embedded one can be stale after a crop, or letterboxed to 160×120, and
    /// either would break "the whole page" — but it is what makes a large scan cheap.
    private static func renderImage(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        func thumbnail(always: Bool) -> CGImage? {
            let options: [CFString: Any] = [
                always
                    ? kCGImageSourceCreateThumbnailFromImageAlways
                    : kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                // Decode here, off the main thread, not lazily when the row first draws.
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let quick = thumbnail(always: false) else { return nil }
        guard let aspect = imageAspect(source),
            abs(Double(quick.width) / Double(quick.height) - aspect) / aspect > 0.03
        else { return quick }
        return thumbnail(always: true) ?? quick
    }

    /// Width over height of the full image as displayed, its orientation applied.
    private static func imageAspect(_ source: CGImageSource) -> Double? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Double,
            let height = properties[kCGImagePropertyPixelHeight] as? Double,
            width > 0, height > 0
        else { return nil }
        // EXIF orientations 5–8 turn the image a quarter.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? height / width : width / height
    }

    /// The first page on white, its rotation applied, its longer side `pixels` long. A
    /// locked PDF has no page to draw, so it keeps its symbol rather than showing white.
    private static func renderPDF(_ url: URL, pixels: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL),
            !document.isEncrypted || document.isUnlocked,
            let page = document.page(at: 1)
        else { return nil }
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
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Scale first, then let the page's own transform rotate and centre it: the
        // drawing transform never scales up, so it is given the page at its target size.
        context.scaleBy(x: scale, y: scale)
        let target = CGRect(
            x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        context.concatenate(
            page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

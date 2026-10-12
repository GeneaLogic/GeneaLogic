import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Renders a file preview entirely with **in-process** views: an `Image` for images, a
/// `PDFView` for PDFs, and a read-only text view (via `NSAttributedString`) for
/// word-processing documents. Anything else shows a placeholder pointing at the file's
/// ⋯ menu.
///
/// **Why no Quick Look:** `QLPreviewView` renders HTML-backed previews (e.g. `.docx`)
/// through an out-of-process path that stalls ~30 s in this sandboxed app, and
/// `QLThumbnailGenerator` fails outright (`QLThumbnailErrorDomain`) for the same files —
/// the sandbox blocks Quick Look's out-of-process generators for Office documents, even
/// though `qlmanage` renders them in ~0.1 s outside the sandbox (measured for the slow `.docx` preview fix). AppKit's
/// `NSAttributedString(url:)` reads those documents **in-process** (the app can read the
/// package file directly), so we show their actual text instead.
struct FilePreviewContent: View {
    let url: URL

    var body: some View {
        switch Self.kind(of: url) {
        case .image:
            ImagePreview(url: url)
        case .pdf:
            PDFPreview(url: url)
        case .richText:
            RichTextDocumentPreview(url: url)
        case .other:
            UnsupportedPreview()
        }
    }

    private enum Kind { case image, pdf, richText, other }

    /// Word-processing document extensions `NSAttributedString` can read in-process.
    /// (`html`/`htm` are deliberately excluded — AppKit's HTML import can block on
    /// remote resource loads, which would hang in this no-network sandbox.)
    private static let richTextExtensions: Set<String> = [
        "doc", "docx", "rtf", "rtfd", "odt", "txt", "text",
    ]

    private static func kind(of url: URL) -> Kind {
        if richTextExtensions.contains(url.pathExtension.lowercased()) { return .richText }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        return .other
    }
}

/// In-process image preview (no Quick Look XPC). Loads off the main actor so a large
/// scan doesn't hitch the UI, then shows it in a zoomable/pannable view.
private struct ImagePreview: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                ZoomableImageView(image: image)
            } else if failed {
                ContentUnavailableView(
                    "Couldn't Load Image", systemImage: "photo",
                    description: Text("The image couldn't be read from the archive."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let loaded = await Task.detached { NSImage(contentsOf: url) }.value
            if let loaded {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}

/// A zoomable, pannable image view backed by `NSScrollView.allowsMagnification` — the
/// same native magnification PDFKit's `PDFView` uses, so images now zoom on par with PDFs
/// (slice 30): pinch or trackpad-magnify to zoom, scroll to pan. `magnification == 1`
/// means fit-to-window: the `NSImageView` autoresizes to fill the clip view and scales
/// its image proportionally (matching the previous `scaledToFit` look), so a window
/// resize refits automatically while preserving the user's zoom factor. Zoom-out is
/// clamped at fit (min 1×); zoom-in goes to 16×.
private struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 16
        scrollView.drawsBackground = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        imageView.frame = scrollView.contentView.bounds
        // Track the clip view on window resize, so magnification 1 stays fit-to-window.
        imageView.autoresizingMask = [.width, .height]
        scrollView.documentView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        if imageView.image !== image {
            imageView.image = image
            // A new image refits: drop any zoom the previous image was showing at.
            scrollView.magnification = 1
        }
    }
}

/// In-process PDF preview via PDFKit (no Quick Look XPC).
private struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
    }
}

/// In-process preview for word-processing documents (Word, RTF, ODT, plain text): reads
/// the file into an `NSAttributedString` and shows its **text content** (formatting
/// preserved; embedded images / exact page layout are not) in a read-only, selectable
/// text view. This sidesteps Quick Look, which can't render these in the sandbox (see
/// `FilePreviewContent`). The full-fidelity document opens via the file's ⋯ menu.
private struct RichTextDocumentPreview: View {
    let url: URL
    @State private var document: NSAttributedString?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                RichTextView(attributedText: document)
            } else if failed {
                UnsupportedPreview()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            failed = false
            // Documents here are small (transcripts/translations); reading is fast.
            // AppKit auto-detects the document type from the file's content.
            document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil)
            failed = document == nil
        }
    }
}

/// A read-only, selectable `NSTextView` (in a scroll view) showing an attributed string.
/// Drawn on a light "page" background so document text — which is typically black — stays
/// readable regardless of the app's light/dark appearance.
private struct RichTextView: NSViewRepresentable {
    let attributedText: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = true
            textView.backgroundColor = .white
            textView.textContainerInset = NSSize(width: 20, height: 20)
            textView.textStorage?.setAttributedString(attributedText)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only re-set when the document actually changes, so routine SwiftUI updates
        // don't reset the user's scroll position or selection.
        if textView.attributedString() != attributedText {
            textView.textStorage?.setAttributedString(attributedText)
        }
    }
}

/// Placeholder for file types with no in-process preview (spreadsheets, media, …):
/// directs the user to the file's ⋯ menu to open it in its default app. Never attempts
/// Quick Look (which would hang or fail in the sandbox).
private struct UnsupportedPreview: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Inline Preview", systemImage: "doc")
        } description: {
            Text(
                "This file type can't be previewed here — use the file's ⋯ menu to open it in its default app."
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

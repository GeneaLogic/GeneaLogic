//
//  ZoomableCanvas.swift
//  GeneaLogicApp
//
//  A pannable, zoomable host for a fixed-size SwiftUI drawing (the family tree).
//

import AppKit
import SwiftUI

/// Hosts fixed-size SwiftUI content inside a magnifying `NSScrollView` — pinch or
/// trackpad-magnify to zoom, scroll to pan.
///
/// This is a **variation** on `ZoomableImageView` (the slice-30 file preview), not a
/// copy, and the difference is the whole point: there the document view autoresizes
/// to fill the clip view so `magnification == 1` means fit-to-window. Here the
/// content has an intrinsic size — the tree is as wide as it is — so the document
/// view takes that exact frame and does **not** autoresize; the scroll view then
/// scrolls it, which is what a tree bigger than the window needs.
///
/// **The trap this deliberately avoids:** wrapping the content in a SwiftUI
/// `ScrollView` *and* putting it in an `NSScrollView` gives two scrollers fighting
/// over the same gesture. The `NSScrollView` owns both scrolling and zoom; the
/// hosted content is a plain, unscrolled view.
///
/// **The other trap:** `NSHostingView` starts a *fresh* SwiftUI environment — it does
/// not inherit the one this representable sits in (the same hazard as a `.sheet`
/// attached outside an `.environment(model)` injection). Anything the content reads
/// from the environment must therefore be injected into `content` by the caller.
struct ZoomableCanvas<Content: View>: NSViewRepresentable {
    /// The intrinsic size of the drawing, in points.
    let contentSize: CGSize
    let minMagnification: CGFloat
    let maxMagnification: CGFloat
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = CenteringScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = minMagnification
        scrollView.maxMagnification = maxMagnification
        scrollView.drawsBackground = false

        let hosting = NSHostingView(rootView: content)
        hosting.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.documentView = hosting
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = scrollView.documentView as? NSHostingView<Content> else { return }
        hosting.rootView = content
        if hosting.frame.size != contentSize {
            hosting.frame = CGRect(origin: .zero, size: contentSize)
        }
    }
}

/// An `NSScrollView` that centres its document view while it is smaller than the
/// visible area, so a small tree sits in the middle of the pane instead of pinned to
/// the top-left corner.
private final class CenteringScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let document = documentView else { return }
        let visible = contentView.bounds.size
        let size = document.frame.size
        var origin = document.frame.origin
        // Reset to the origin once the drawing outgrows the viewport: keeping a
        // previously-centred offset would leave the document's coordinate space
        // permanently shifted after a zoom-in or a window resize.
        origin.x = size.width < visible.width ? (visible.width - size.width) / 2 : 0
        origin.y = size.height < visible.height ? (visible.height - size.height) / 2 : 0
        if document.frame.origin != origin {
            document.setFrameOrigin(origin)
        }
    }
}

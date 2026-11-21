import SwiftUI

/// Saves a column's width once it settles, not on every frame (slice 80, the inspector;
/// generalised in 85 for the sidebar).
///
/// SwiftUI has no binding for a column's current width, and a column it rebuilds (on
/// every hide and show, a tab switch, a reopened window) opens at its `ideal` width. So
/// the width is measured here, saved, and handed back by the caller as the column's
/// `ideal`.
///
/// The live width stays in this modifier's own state, so a drag re-renders only this,
/// not the view that owns the column, and the column's `ideal` is not rewritten
/// mid-drag. It is saved after half a second without change, when the column hides, or
/// when the view goes away. Widths read while the column hides are ignored (`isShown`
/// is already false), and so are widths outside `range`.
///
/// **Not only drags are saved.** A width SwiftUI imposes and then holds, such as the
/// column narrowed by a narrower window, is saved too, because nothing here can tell
/// the two apart.
struct RememberedColumnWidth: ViewModifier {
    @Binding var saved: Double
    let isShown: Bool
    let range: ClosedRange<Double>
    @State private var live: Double?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Double.self) {
                $0.size.width
            } action: { width in
                guard isShown, range.contains(width) else { return }
                live = width
            }
            .task(id: live) {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { save() }
            }
            .onChange(of: isShown) { _, shown in if !shown { save() } }
            .onDisappear { save() }
    }

    private func save() {
        if let live, live != saved { saved = live }
    }
}

extension Double {
    /// The value, pinned into `range`: a remembered width replayed as a column's `ideal`.
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

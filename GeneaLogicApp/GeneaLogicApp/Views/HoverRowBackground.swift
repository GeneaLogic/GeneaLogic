import SwiftUI

extension View {
    /// The shared "list-like row" chrome: 6/8 padding and a rounded fill that
    /// highlights on hover (and, optionally, when selected — selection wins). Unifies
    /// what were three copy-pasted hand-rolled rows — the detail view's `AssertionRow`
    /// and `FileRow` and the welcome screen's `RecentArchiveRow` (F8; the row styling
    /// slice 33 deferred). The full-rectangle `contentShape` makes the whole padded
    /// row the hover/hit region.
    func hoverRowBackground(isHovering: Bool, isSelected: Bool = false) -> some View {
        self
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                hoverRowFill(isHovering: isHovering, isSelected: isSelected),
                in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
            )
    }
}

/// Selected wins over hover; hover is the subtle "this row is interactive" cue.
/// A free function, not a `View` method — it derives purely from its arguments.
private func hoverRowFill(isHovering: Bool, isSelected: Bool) -> Color {
    if isSelected { return Color.accentColor.opacity(0.18) }
    if isHovering { return Color.primary.opacity(0.06) }
    return .clear
}

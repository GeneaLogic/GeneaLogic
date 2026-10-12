import SwiftUI

/// The trailing "remove" (trash) control shared by the inline assertion/mention rows.
/// Removal is undoable (⌘Z), so it acts immediately without a confirm. The button
/// reveals when the row is hovered *or* its own control is keyboard-focused (Full
/// Keyboard Access), so a keyboard user can see and reach it — the dim (0.55) glyph and
/// its focus ring are otherwise invisible until the mouse hovers (UI audit F6). Callers
/// pass their row's `isHovering`; the focus state is owned here.
struct RowRemoveButton: View {
    let isHovering: Bool
    var accessibilityLabel: String = "Remove"
    var help: String = "Remove (⌘Z to undo)"
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "trash")
                .frame(width: Layout.iconButtonHitSize, height: Layout.iconButtonHitSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focused($focused)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
        .opacity(isHovering || focused ? 1 : 0.55)
    }
}

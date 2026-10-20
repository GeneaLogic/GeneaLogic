import SwiftUI

/// One assertion row — an icon, a title, an optional subtitle, and a remove button.
/// Removal is undoable (⌘Z), so it acts immediately without a confirm.
///
/// Shared by the artifact detail pane (Events & Places, Persons Mentioned) and the
/// People-tab detail pane (Names, Facts). When `onEdit` is set, the icon/title/
/// subtitle become a button that opens the row's editor (the People rows tap to
/// edit); when it's `nil` the text is plain and selectable (the artifact rows, which
/// only add and remove). Either way the trailing trash is its own button.
struct AssertionRow: View {
    let title: String
    let subtitle: String?
    let icon: String
    /// When set, the row's content is a button that opens an editor. When `nil` the
    /// content is plain, selectable text (the row is add/remove only).
    var onEdit: (() -> Void)? = nil
    /// The focus state the edit button binds to, so focus can come back to this row after
    /// its editor replaces it (slice 79b). Only meaningful with `onEdit`.
    var editFocus: RowFocus? = nil
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if let onEdit {
                // A tappable row opens the editor. Text selection is dropped here: it
                // would swallow the click the way it does in the Files list (slice 15).
                Button(action: onEdit) {
                    rowLabel
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .rowFocus(editFocus)
                .accessibilityHint("Edit")
            } else {
                rowLabel
                    .textSelection(.enabled)
            }
            RowRemoveButton(isHovering: isHovering, action: onDelete)
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    private var rowLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// A selectable chip in the document pane's file strip: a small icon, the file's
/// name, and its role badge. Highlighted while it's the file being previewed.
struct FileChip: View {
    let entry: FileEntry
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                Text(entry.originalName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Layout.fileNameChipMaxWidth)
                RoleBadge(role: entry.role)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                    .stroke(isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.originalName)
    }
}

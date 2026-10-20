import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The artifact's attached files, with an "Attach File…" action that adds another
/// file to *this* artifact (attach-to-existing). Attached files get a default role
/// (slice 32) that's corrected afterward via each row's ⋯ ▸ Role menu. Creating a
/// new artifact instead is the toolbar `+` (Add Media); the two are distinct verbs
/// multiplexed over one importer via `ArchiveModel.ImportMode`.
struct FilesSection: View {
    let files: [FileEntry]
    @Binding var selectedFileID: FileID?
    let onAttachOrScan: () -> Void
    let onPopOut: (FileID) -> Void
    let onOpenExternally: (FileID) -> Void
    let onSaveCopy: (FileID) -> Void
    let onScanMetadata: (FileID) -> Void
    let onSetRole: (FileID, FileRole) -> Void
    let onReplace: (FileID) -> Void
    let onDelete: (FileID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Files")
                    .font(.headline)
                Spacer()
                // A plain Button (not a SwiftUI Menu) so the shared Continuity path can
                // pop **one** connected AppKit menu — Attach File… above the flat scan
                // items — exactly like the toolbar `+`, instead of a SwiftUI menu that
                // then pops a second, disconnected AppKit menu (a slice 32 follow-up).
                Button {
                    onAttachOrScan()
                } label: {
                    AddAffordanceLabel(
                        title: "Attach File…", systemImage: "paperclip", opensMenu: true)
                }
                .buttonStyle(.plain)
            }

            if files.isEmpty {
                Text("No files attached. Use Attach File… to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if selectedFileID == nil {
                    Label("Select a file to preview it.", systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(files, id: \.uid) { entry in
                        FileRow(
                            entry: entry,
                            isSelected: entry.uid == selectedFileID,
                            onSelect: { selectedFileID = entry.uid },
                            onPopOut: { onPopOut(entry.uid) },
                            onOpenExternally: { onOpenExternally(entry.uid) },
                            onSaveCopy: { onSaveCopy(entry.uid) },
                            onScanMetadata: { onScanMetadata(entry.uid) },
                            onSetRole: { onSetRole(entry.uid, $0) },
                            onReplace: { onReplace(entry.uid) },
                            onDelete: { onDelete(entry.uid) })
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// One attached-file row: original name + role badge, with the package-assigned
/// path and size/format beneath, and a per-file actions menu. Clicking the row
/// selects it as the previewed document (highlighted while selected). The menu
/// covers export (Open in Default App, Save a Copy…, separate window) and editing
/// (Replace…/Delete). Delete is destructive but **undoable** (the engine stages the
/// bytes), so it confirms once rather than blocking.
private struct FileRow: View {
    let entry: FileEntry
    let isSelected: Bool
    let onSelect: () -> Void
    let onPopOut: () -> Void
    let onOpenExternally: () -> Void
    let onSaveCopy: () -> Void
    let onScanMetadata: () -> Void
    let onSetRole: (FileRole) -> Void
    let onReplace: () -> Void
    let onDelete: () -> Void

    @State private var confirmingDelete = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // The whole left region is one plain Button, so clicking anywhere on the
            // row's text/icon selects it for preview (not just the empty margins).
            // `textSelection` is intentionally omitted — it would swallow the click.
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Image(systemName: "doc")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(entry.originalName)
                                .fontWeight(.medium)
                            RoleBadge(role: entry.role)
                        }
                        Text(subtitle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to preview")

            Menu {
                Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                    onOpenExternally()
                }
                Button("Save a Copy…", systemImage: "square.and.arrow.down") { onSaveCopy() }
                Button("Open in Separate Window", systemImage: "macwindow.on.rectangle") {
                    onPopOut()
                }
                Divider()
                // Change the file's archival role after the fact (slice 32). A
                // Picker renders the four roles with a checkmark on the current one.
                Picker("Role", selection: roleBinding) {
                    ForEach(FileRole.allCases, id: \.self) { role in
                        Text(role.displayName).tag(role)
                    }
                }
                Button("Scan for Metadata", systemImage: "doc.text.magnifyingglass") {
                    onScanMetadata()
                }
                Divider()
                Button("Replace…", systemImage: "arrow.triangle.2.circlepath") { onReplace() }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    confirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(width: Layout.iconButtonHitSize, height: Layout.iconButtonHitSize)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Names the image-only ⋯ control for VoiceOver. No `.help` tooltip: the
            // ellipsis is a conventional "more actions" affordance (unlike the
            // trash/pop-out glyphs, which get one), and an identical help string
            // would just make VoiceOver announce "File actions" twice.
            .accessibilityLabel("File actions")
        }
        .hoverRowBackground(isHovering: isHovering, isSelected: isSelected)
        .onHover { isHovering = $0 }
        .confirmationDialog(
            "Delete “\(entry.originalName)”?", isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete File", role: .destructive) { onDelete() }
        } message: {
            Text(
                "This moves the file to the Trash. Undo with ⌘Z, or restore it later from "
                    + "File ▸ Show Trash.")
        }
    }

    /// Bridges the file's current role to the Role picker: reads `entry.role`
    /// (always fresh — the row rebuilds from the reloaded record after a change)
    /// and routes a new selection through the undoable `onSetRole`.
    private var roleBinding: Binding<FileRole> {
        Binding(get: { entry.role }, set: { onSetRole($0) })
    }

    private var subtitle: String {
        let size = ByteCountFormatter.string(fromByteCount: entry.byteLength, countStyle: .file)
        return "\(entry.path) · \(entry.format) · \(size)"
    }
}

/// A small capsule showing a file's role.
struct RoleBadge: View {
    let role: FileRole

    var body: some View {
        Text(role.displayName)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

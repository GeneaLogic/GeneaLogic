import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The Trash area's detail (slice 86): the cross-session safety net for deleted items,
/// selected by the sidebar's Trash row or File ▸ Show Trash. Moving an artifact to the
/// Trash stages its whole folder, and moving a file stages that file, into the package's
/// `.trash/` (so both survive quit); this lists what's there — split into **Artifacts**
/// and **Files** — and lets the user **Restore** an item, delete it permanently, or
/// **Empty Trash…** to reclaim the space.
///
/// In-session ⌘Z still undoes a move directly — the Trash is the recovery path *after*
/// that history is gone (e.g. across a relaunch). Restoring here is itself undoable (⌘Z
/// moves it back), so the Trash and the undo stack are two doors to one store; emptying
/// and permanently deleting are irreversible, so those two still ask.
///
/// **It was a sheet until slice 86**, and was easy to forget for it. The listings now live
/// in the model (`trashedArtifacts`, `trashedFiles`), which reloads them as writes land
/// while this area shows, so this view keeps no copy of its own to go stale.
struct TrashView: View {
    @Environment(ArchiveModel.self) private var model

    @State private var confirmingEmpty = false
    @State private var pendingArtifactDelete: TrashedArtifact?
    @State private var pendingFileDelete: TrashedFile?

    private var isEmpty: Bool { model.trashedArtifacts.isEmpty && model.trashedFiles.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .confirmationDialog(
                pendingArtifactDelete.map { "Permanently delete “\(Self.title(of: $0))”?" } ?? "",
                isPresented: Binding(
                    get: { pendingArtifactDelete != nil },
                    set: { if !$0 { pendingArtifactDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingArtifactDelete
            ) { item in
                Button("Delete Permanently", role: .destructive) {
                    model.deleteFromTrash(item.uid)
                }
            } message: { _ in
                Text("This removes it from the archive for good. It can't be undone.")
            }
            .confirmationDialog(
                pendingFileDelete.map { "Permanently delete “\(Self.name(of: $0))”?" } ?? "",
                isPresented: Binding(
                    get: { pendingFileDelete != nil },
                    set: { if !$0 { pendingFileDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingFileDelete
            ) { item in
                Button("Delete Permanently", role: .destructive) {
                    model.deleteFileFromTrash(item.uid)
                }
            } message: { _ in
                Text("This removes the file from the archive for good. It can't be undone.")
            }
            .confirmationDialog(
                "Empty the Trash?", isPresented: $confirmingEmpty, titleVisibility: .visible
            ) {
                Button("Empty Trash", role: .destructive) {
                    model.emptyTrash()
                }
            } message: {
                Text("This permanently deletes everything in the trash. It can't be undone.")
            }
            .reportsModal(
                confirmingEmpty || pendingArtifactDelete != nil || pendingFileDelete != nil)
    }

    /// The strip above the list, as Finder's Trash has: what it holds, and Empty.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Trash")
                .font(.headline)
            Text(summary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer(minLength: 8)
            Button("Empty Trash…") { confirmingEmpty = true }
                .disabled(isEmpty)
                .help("Permanently delete everything in the trash")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var summary: String {
        switch model.trashedArtifacts.count + model.trashedFiles.count {
        case 0: "Empty"
        case 1: "1 item"
        case let count: "\(count) items"
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("Trash Is Empty", systemImage: "trash")
            } description: {
                Text(
                    "Artifacts and files you move to the Trash are kept here — even after you "
                        + "quit — so you can put them back. Emptying the trash reclaims their "
                        + "space for good.")
            }
        } else {
            List {
                if !model.trashedArtifacts.isEmpty {
                    Section("Artifacts") {
                        ForEach(model.trashedArtifacts, id: \.uid) { item in
                            TrashRow(
                                icon: "doc",
                                title: Self.title(of: item),
                                subtitle: "Deleted \(displayDate(item.deletedAt))",
                                restoreHelp: "Put this artifact back in the archive.",
                                deleteHelp: "Remove this artifact for good. This can't be undone.",
                                onRestore: { model.restoreFromTrash(item.uid) },
                                onDelete: { pendingArtifactDelete = item })
                        }
                    }
                }
                if !model.trashedFiles.isEmpty {
                    Section("Files") {
                        ForEach(model.trashedFiles, id: \.uid) { item in
                            TrashRow(
                                icon: "doc.text",
                                title: Self.name(of: item),
                                subtitle:
                                    "From “\(item.artifactTitle)” · Deleted \(displayDate(item.deletedAt))",
                                restoreHelp: "Re-attach this file to “\(item.artifactTitle)”.",
                                deleteHelp: "Remove this file for good. This can't be undone.",
                                onRestore: { model.restoreFile(item) },
                                onDelete: { pendingFileDelete = item })
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private static func title(of item: TrashedArtifact) -> String {
        item.title.isEmpty ? "Untitled Artifact" : item.title
    }

    private static func name(of item: TrashedFile) -> String {
        item.originalName.isEmpty ? "Untitled File" : item.originalName
    }
}

/// One trashed item's row, for both kinds: leading icon, title + subtitle, and the
/// Restore / Delete Permanently… buttons, which its context menu repeats.
private struct TrashRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let restoreHelp: String
    let deleteHelp: String
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Restore", action: onRestore)
                .help(restoreHelp)
            Button("Delete Permanently…", role: .destructive, action: onDelete)
                .help(deleteHelp)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Restore", action: onRestore)
            Button("Delete Permanently…", role: .destructive, action: onDelete)
        }
    }
}

/// Formats the ISO 8601 `deletedAt` for display, falling back to the raw string.
private func displayDate(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .shortened)
}

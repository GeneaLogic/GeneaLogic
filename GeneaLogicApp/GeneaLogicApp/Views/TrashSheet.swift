import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The trash panel (File ▸ Show Trash…): the cross-session safety net for deleted
/// items. Deleting an artifact stages its whole folder, and deleting a file stages
/// that file, into the package's `.trash/` (so both survive quit); this sheet lists
/// what's there — split into **Artifacts** and **Files** — and lets the user
/// **Restore** an item or **Empty Trash** to reclaim the space.
///
/// In-session ⌘Z still undoes a delete directly — the trash is the recovery path
/// *after* that history is gone (e.g. across a relaunch). Restoring here is itself
/// undoable (⌘Z re-deletes), so the sheet and the undo stack are two doors to one
/// store; emptying / permanently deleting is irreversible.
struct TrashSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The listings, reloaded on appear and after each action (the engine calls aren't
    /// observable, so the sheet re-fetches rather than binding).
    @State private var artifacts: [TrashedArtifact] = []
    @State private var files: [TrashedFile] = []
    @State private var confirmingEmpty = false
    @State private var pendingArtifactDelete: TrashedArtifact?
    @State private var pendingFileDelete: TrashedFile?

    private var isEmpty: Bool { artifacts.isEmpty && files.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Trash")
                .font(.headline)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .padding(Layout.sheetPadding)
        // Resizable so the trashed-items lists can grow to show more rows. `.fitted` opts
        // back into resizable sheets (fixed-size by default on macOS 15+) (UI audit F5).
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.ContentSheet.minWidth, idealWidth: Layout.ContentSheet.idealWidth,
            maxWidth: .infinity,
            minHeight: Layout.ContentSheet.minHeight, idealHeight: Layout.ContentSheet.idealHeight,
            maxHeight: .infinity
        )
        .onAppear(perform: reload)
        .confirmationDialog(
            pendingArtifactDelete.map { "Permanently delete “\($0.title)”?" } ?? "",
            isPresented: Binding(
                get: { pendingArtifactDelete != nil },
                set: { if !$0 { pendingArtifactDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingArtifactDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) {
                reloadAfterWrite { model.deleteFromTrash(item.uid) }
            }
        } message: { _ in
            Text("This removes it from the archive for good. It can't be undone.")
        }
        .confirmationDialog(
            pendingFileDelete.map { "Permanently delete “\($0.originalName)”?" } ?? "",
            isPresented: Binding(
                get: { pendingFileDelete != nil },
                set: { if !$0 { pendingFileDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingFileDelete
        ) { item in
            Button("Delete Permanently", role: .destructive) {
                reloadAfterWrite { model.deleteFileFromTrash(item.uid) }
            }
        } message: { _ in
            Text("This removes the file from the archive for good. It can't be undone.")
        }
        .confirmationDialog(
            "Empty the Trash?", isPresented: $confirmingEmpty, titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) {
                reloadAfterWrite { model.emptyTrash() }
            }
        } message: {
            Text("This permanently deletes everything in the trash. It can't be undone.")
        }
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("Trash Is Empty", systemImage: "trash")
            } description: {
                Text(
                    "Deleted artifacts and files are kept here — even after you quit — so you "
                        + "can put them back. Emptying the trash reclaims their space for good.")
            }
        } else {
            List {
                if !artifacts.isEmpty {
                    Section("Artifacts") {
                        ForEach(artifacts, id: \.uid) { item in
                            ArtifactTrashRow(
                                item: item,
                                onRestore: { restoreArtifact(item) },
                                onDelete: { pendingArtifactDelete = item })
                        }
                    }
                }
                if !files.isEmpty {
                    Section("Files") {
                        ForEach(files, id: \.uid) { item in
                            FileTrashRow(
                                item: item,
                                onRestore: { restoreFile(item) },
                                onDelete: { pendingFileDelete = item })
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            Button("Empty Trash") { confirmingEmpty = true }
                .disabled(isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func reload() {
        artifacts = model.trashedArtifacts()
        files = model.trashedFiles()
    }

    private func restoreArtifact(_ item: TrashedArtifact) {
        reloadAfterWrite { model.restoreFromTrash(item.uid) }
    }

    private func restoreFile(_ item: TrashedFile) {
        reloadAfterWrite { model.restoreFile(item) }
    }

    /// Runs a trash mutation and reloads the sheet's own lists **once it has
    /// landed**.
    ///
    /// This sheet is one of the few places that keeps a private copy of engine
    /// state (`artifacts`/`files` above), so nothing republishes it — and since
    /// slice 52 the write is asynchronous, so reloading in the same turn read the
    /// archive back exactly as it was. Every action here did that: rows stayed
    /// after Restore, and after Empty Trash the sheet still listed entries whose
    /// bytes were gone, offering a Restore that could only throw
    /// `trashEntryNotFound`.
    private func reloadAfterWrite(_ body: @escaping () -> Void) {
        Task {
            body()
            await model.writesSettled()
            reload()
        }
    }
}

/// One trashed-artifact row: title + deleted-when, with Restore and a destructive
/// Delete Permanently.
private struct ArtifactTrashRow: View {
    let item: TrashedArtifact
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TrashRowLayout(
            icon: "doc",
            title: item.title.isEmpty ? "Untitled Artifact" : item.title,
            subtitle: "Deleted \(displayDate(item.deletedAt))",
            restoreHelp: nil,
            deleteHelp: "Remove this artifact for good. This can't be undone.",
            onRestore: onRestore,
            onDelete: onDelete)
    }
}

/// One trashed-file row: filename + which artifact it was detached from + when, with
/// Restore (re-attaches to that artifact) and a destructive Delete Permanently.
private struct FileTrashRow: View {
    let item: TrashedFile
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        TrashRowLayout(
            icon: "doc.text",
            title: item.originalName.isEmpty ? "Untitled File" : item.originalName,
            subtitle: "From “\(item.artifactTitle)” · Deleted \(displayDate(item.deletedAt))",
            restoreHelp: "Re-attach this file to “\(item.artifactTitle)”.",
            deleteHelp: "Remove this file for good. This can't be undone.",
            onRestore: onRestore,
            onDelete: onDelete)
    }
}

/// Shared row chrome for both trash kinds: leading icon, title + subtitle, and the
/// Restore / Delete Permanently buttons.
private struct TrashRowLayout: View {
    let icon: String
    let title: String
    let subtitle: String
    let restoreHelp: String?
    let deleteHelp: String
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Restore", action: onRestore)
                .help(restoreHelp ?? "")
            Button("Delete Permanently", role: .destructive, action: onDelete)
                .help(deleteHelp)
        }
        .padding(.vertical, 2)
    }
}

/// Formats the ISO 8601 `deletedAt` for display, falling back to the raw string.
private func displayDate(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
    return date.formatted(date: .abbreviated, time: .shortened)
}

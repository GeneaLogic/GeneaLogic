import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The detail pane's primary content: the artifact's title, the selected file's
/// preview, and — for a multi-file artifact — a strip to switch between files. A
/// metadata-only artifact (no files) shows an attach affordance instead.
struct ArtifactDocumentPane: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    let title: String
    let files: [FileEntry]
    @Binding var selectedFileID: FileID?

    var body: some View {
        VStack(spacing: 0) {
            DocumentHeader(artifactID: artifactID, title: title, selectedFile: selectedFile)
            Divider()
            if files.isEmpty {
                ContentUnavailableView {
                    Label("No Files Yet", systemImage: "tray")
                } description: {
                    Text(
                        "This artifact has no attached files. Attach a document, photo, or "
                            + "scan to see it here.")
                } actions: {
                    Button("Attach File…") { model.beginAttachOrScan(to: artifactID) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // A single file needs no selector.
                    if files.count > 1 {
                        FileSelectorStrip(files: files, selectedFileID: $selectedFileID)
                        Divider()
                    }
                    DocumentPreview(artifactID: artifactID, fileID: selectedFile?.uid)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The currently previewed file entry, or `nil` when nothing is selected or the
    /// selection names a file that has gone.
    private var selectedFile: FileEntry? {
        guard let selectedFileID else { return nil }
        return files.first { $0.uid == selectedFileID }
    }
}

/// The artifact's title above the document, with a pop-out button for the file on show.
private struct DocumentHeader: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let artifactID: ArtifactID
    let title: String
    let selectedFile: FileEntry?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let selectedFile {
                Button {
                    ArtifactFileActions(
                        model: model, artifactID: artifactID, openWindow: openWindow
                    )
                    .popOut(selectedFile)
                } label: {
                    Image(systemName: "macwindow.on.rectangle")
                        .frame(width: Layout.iconButtonHitSize, height: Layout.iconButtonHitSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open in separate window")
                .help("Open this file in a separate window")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Horizontal strip of the artifact's files; selecting one previews it.
private struct FileSelectorStrip: View {
    let files: [FileEntry]
    @Binding var selectedFileID: FileID?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files, id: \.uid) { entry in
                    FileChip(
                        entry: entry, isSelected: entry.uid == selectedFileID,
                        selectedFileID: $selectedFileID)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

/// The selected file's preview, or why there isn't one.
private struct DocumentPreview: View {
    @Environment(ArchiveModel.self) private var model
    let artifactID: ArtifactID
    /// The file to preview: `nil` when nothing is selected.
    let fileID: FileID?

    var body: some View {
        if let fileID {
            if let url = model.fileURL(of: fileID, in: artifactID) {
                // `.id` resets the preview's own state (scroll, loaded image) when a
                // different file is selected.
                FilePreviewContent(url: url)
                    .id(fileID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "File Unavailable", systemImage: "exclamationmark.triangle",
                    description: Text("The file's bytes couldn't be found in the archive."))
            }
        } else {
            ContentUnavailableView(
                "Select a File", systemImage: "doc",
                description: Text("Choose a file from the strip above to preview it."))
        }
    }
}

/// A selectable chip in the document pane's file strip: a small icon, the file's
/// name, and its role badge. Highlighted while it's the file being previewed.
///
/// Takes `isSelected` to read and the selection binding only to write, so selecting a
/// file redraws the two chips whose highlight changes and no others.
private struct FileChip: View {
    let entry: FileEntry
    let isSelected: Bool
    @Binding var selectedFileID: FileID?

    var body: some View {
        Button {
            selectedFileID = entry.uid
        } label: {
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

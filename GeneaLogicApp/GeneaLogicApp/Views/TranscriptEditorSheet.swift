import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// A dedicated, full-height editor for an artifact's inline `transcript`.
///
/// Transcripts are long-form text, so they get their own roomy sheet rather than
/// a row in the compact descriptive-fields grid (which deliberately omits them).
/// Save commits the whole field in one `updateMetadata` write; an empty transcript
/// is stored as `nil` (the field's "no transcript" state), not an empty string.
///
/// This edits the *inline* `Artifact.transcript` only. Long transcripts kept as a
/// `role: .transcript` file are shown in the Files list and are searchable, but
/// editing file content in-app is a later concern (it needs the file-write
/// durability work).
struct TranscriptEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifactID: ArtifactID
    /// Called with the saved value (trimmed to `nil` when empty) so the detail
    /// view can update its read-only display without waiting for a reload — the
    /// browse summary doesn't carry the transcript, so `refresh()` alone wouldn't
    /// surface the change.
    let onSaved: (String?) -> Void

    @State private var text: String

    init(artifactID: ArtifactID, initialText: String?, onSaved: @escaping (String?) -> Void) {
        self.artifactID = artifactID
        self.onSaved = onSaved
        _text = State(initialValue: initialText ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Transcript")
                .font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                        .stroke(.secondary.opacity(0.3))
                )

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // The editor is multi-line, so plain Return inserts a newline (the
                // focused TextEditor consumes it). The commit gesture is therefore
                // ⌘Return — Xcode's commit sheet precedent — with the button kept
                // visually prominent rather than relying on `.defaultAction` (which
                // would claim plain Return, the newline key) (UI audit F6).
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(Layout.sheetPadding)
        // Resizable so a long transcript gets room; the TextEditor fills the sheet and
        // grows with it. `.fitted` opts back into resizable sheets (fixed-size by default
        // on macOS 15+); the min/ideal/max frame sets the floor, opening size, and the
        // unbounded ceiling for the drag (UI audit F5).
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.ContentSheet.minWidth, idealWidth: Layout.ContentSheet.idealWidth,
            maxWidth: .infinity,
            minHeight: Layout.ContentSheet.minHeight, idealHeight: Layout.ContentSheet.idealHeight,
            maxHeight: .infinity)
    }

    private func save() {
        let value = text.trimmedNonEmpty
        model.updateMetadata(of: artifactID, actionName: "Edit Transcript") {
            $0.transcript = value
        }
        onSaved(value)
        dismiss()
    }
}

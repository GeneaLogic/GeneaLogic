import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Detail view for the selected artifact: the document on the left, its metadata in a
/// trailing inspector. This type is the **coordinator** — it loads the record, owns the
/// sheets and the file selection, and routes menu commands. Every section is its own
/// `View` taking only the values it reads, and acts on the model itself (slice 79).
struct ArtifactDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let artifact: ArtifactSummary

    /// The sheet that is up, or `nil`. One request for every sheet the detail can show,
    /// so a section opens one through a single binding and a menu command through the
    /// same state.
    @State private var sheet: ArtifactSheet?
    /// The requests presented and not yet dismissed, kept past `sheet` moving on so each
    /// one's `onDismiss` runs when its own dismissal finishes. A list rather than the
    /// latest one: a request that replaces another without passing through `nil` must not
    /// take over, or run early, the hook of the one it replaced.
    @State private var presentedSheets: [ArtifactSheet] = []

    /// The full record for read-only display, loaded from the index (the browse
    /// summary lacks notes/language/original format and the events/locations the
    /// Events & Places section shows). Reloaded with `files` — see `filesLoadKey`.
    @State private var detail: Artifact?

    /// The selected artifact's attached files, loaded from the full record (the
    /// browse summary carries only a `fileCount`). Reloaded whenever the artifact
    /// or its file count changes — see `filesLoadKey`.
    @State private var files: [FileEntry] = []

    /// The selected artifact's inline transcript, loaded from the full record (the
    /// browse summary doesn't carry it). Loaded with `files`, and updated in place
    /// when the transcript editor saves (its edit doesn't change `filesLoadKey`).
    @State private var transcript: String?

    /// The file row selected for the inline preview pane (read-only mode only);
    /// `nil` shows no pane. Cleared when the artifact changes or the file goes away.
    @State private var selectedFileID: FileID?

    /// The file the Artifact ▸ Selected File ▸ Delete File… menu command is awaiting
    /// confirmation for (the per-row ⋯ ▸ Delete has its own confirm).
    @State private var confirmingFileDelete: FileEntry?

    /// The evidence links whose evidence side is this artifact — which person-mentions
    /// are resolved to a concluded person. Loaded with the record and reloaded off
    /// `mutationVersion` (see `filesLoadKey`), so a resolve/unlink refreshes the chips.
    @State private var links: [EvidenceLink] = []

    /// The relationships this record supports that `conclusions/` doesn't yet assert
    /// (slice 45l). Loaded with the record and reloaded off `mutationVersion`, like `links`:
    /// resolving one more mention is exactly what makes an edge promotable, so the list has
    /// to move the moment a chip appears above it.
    @State private var relationshipSuggestions: [RelationshipReviewItem] = []

    /// Opens popped-out preview windows (the Selected File menu's "separate window").
    @Environment(\.openWindow) private var openWindow

    /// Whether the metadata inspector is shown. Per-window and restored across relaunch
    /// (it rides the same `@SceneStorage` machinery as the artifact selection); defaults
    /// to visible so a fresh window shows the metadata beside the document.
    @SceneStorage("inspectorShown") private var inspectorShown: Bool = true

    /// The inspector's width, as the user last left it (slice 80). SwiftUI rebuilds the
    /// column on every hide and show, and on every tab switch (this view is recreated),
    /// and a rebuilt column opens at its `ideal` width. So the width is recorded here
    /// and handed back as `ideal`. Per-window and restored across relaunch, like
    /// `inspectorShown`.
    @SceneStorage("inspectorWidth") private var inspectorWidth: Double = Self.inspectorWidths.ideal

    /// The inspector column's range. `ideal` is only the first-launch width; after that
    /// the column opens at `inspectorWidth`.
    private static let inspectorWidths = (min: 280.0, ideal: 340.0, max: 480.0)

    var body: some View {
        ArtifactDocumentPane(
            artifactID: artifact.uid, title: artifact.title, files: files,
            selectedFileID: $selectedFileID
        )
        // Metadata lives in a trailing inspector beside the document, toggled from
        // the toolbar. Edit mode happens *inside* the inspector, so the document
        // stays visible while you transcribe evidence off it.
        .inspector(isPresented: $inspectorShown) {
            ArtifactInspector(
                artifactID: artifact.uid, slug: artifact.slug,
                primaryDate: artifact.primaryDate, detail: detail, transcript: transcript,
                files: files, links: links, relationshipSuggestions: relationshipSuggestions,
                selectedFileID: $selectedFileID, sheet: $sheet
            )
            // Only widths inside the column's range are kept, so a width read
            // while the column animates in or out can't be saved.
            .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                let range = Self.inspectorWidths
                if width >= range.min && width <= range.max { inspectorWidth = width }
            }
            // **Keep this, even though it is half of #9's trigger** (slice 80). It is
            // the only API that sets the column's resize range: a content frame in its
            // place (tried) left the column a few points of play and ignored the ideal
            // width. #9 is worked around in `ArtifactInspector` instead.
            .inspectorColumnWidth(
                min: Self.inspectorWidths.min, ideal: inspectorWidth,
                max: Self.inspectorWidths.max)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    inspectorShown.toggle()
                } label: {
                    // The circled "i" (à la Preview's inspector toggle) reads as
                    // "info about this artifact" and avoids mirroring the leading
                    // sidebar toggle the way a trailing-panel glyph would.
                    Label("Inspector", systemImage: "info.circle")
                }
                .help(inspectorShown ? "Hide the inspector" : "Show the inspector")
            }
        }
        // Reloads the full record (fields/events/persons/transcript) and the file
        // list on selection change, after an attach (the summary's `fileCount`
        // bumps), or on any committed mutation (`mutationVersion`) — the last so an
        // undo/redo reloads the inspector and document, not just user edits.
        .task(id: filesLoadKey) {
            let full = model.fullArtifact(artifact.uid)
            detail = full
            files = full?.files ?? []
            transcript = full?.transcript
            links = model.artifactLinks(for: artifact.uid)
            relationshipSuggestions = model.suggestedRelationships(forArtifact: artifact.uid)
            // Keep the document selection valid: drop a file that's gone, then
            // default to the artifact's primary file so a document shows at once.
            if let selectedFileID, !files.contains(where: { $0.uid == selectedFileID }) {
                self.selectedFileID = nil
            }
            if selectedFileID == nil {
                selectedFileID = Self.primaryFile(in: files)?.uid
            }
            // Keep the menu-bar's file mirror in step with the loaded selection.
            model.selectedFile = selectedFileID
        }
        // Presented at the top level (not inside the inspector) so the menu commands —
        // Artifact ▸ Edit Transcript… among them — work even with the inspector hidden.
        .sheet(
            item: $sheet,
            onDismiss: {
                // Every request but the one now up has gone.
                let gone = presentedSheets.filter { $0.id != sheet?.id }
                presentedSheets.removeAll { $0.id != sheet?.id }
                for request in gone { request.onDismiss?() }
            }
        ) { request in
            ArtifactSheetContent(
                request: request, artifactID: artifact.uid,
                mentions: detail?.personsMentioned ?? [],
                statedRelationships: detail?.mentionRelationships ?? [],
                transcript: $transcript
            )
            .environment(model)
        }
        .confirmationDialog(
            confirmingFileDelete.map { "Delete “\($0.originalName)”?" } ?? "",
            isPresented: Binding(
                get: { confirmingFileDelete != nil },
                set: { if !$0 { confirmingFileDelete = nil } }),
            titleVisibility: .visible, presenting: confirmingFileDelete
        ) { entry in
            Button("Delete File", role: .destructive) {
                model.detachFile(entry.uid, from: artifact.uid)
            }
        } message: { _ in
            // Same wording as the per-row ⋯ ▸ Delete confirm (`FileRow`).
            Text(
                "This moves the file to the Trash. Undo with ⌘Z, or restore it later from "
                    + "File ▸ Show Trash.")
        }
        // Mirror the inspector's (view-owned) visibility down so the View menu can
        // label its toggle, and act on the menu's toggle/command intents (F6).
        .onAppear { model.inspectorVisible = inspectorShown }
        .onChange(of: inspectorShown) { _, shown in model.inspectorVisible = shown }
        .onChange(of: selectedFileID) { _, id in model.selectedFile = id }
        .onChange(of: sheet?.id) { if let sheet { presentedSheets.append(sheet) } }
        .onChange(of: model.pendingInspectorToggle) { _, requested in
            if requested {
                inspectorShown.toggle()
                model.inspectorVisible = inspectorShown
                model.pendingInspectorToggle = false
            }
        }
        .onChange(of: model.pendingArtifactCommand) { _, command in
            guard let command else { return }
            performArtifactCommand(command)
            model.pendingArtifactCommand = nil
        }
        .onChange(of: model.pendingFileCommand) { _, command in
            guard let command else { return }
            performFileCommand(command)
            model.pendingFileCommand = nil
        }
        // No `.navigationTitle` here: the window is titled by its *archive*
        // (set on `ArchiveContainerView`, alongside the `.genea` proxy icon). The
        // artifact's name is the heading above the document, in `DocumentHeader`.
    }

    /// Runs an artifact-scoped menu command by opening the same sheet the in-pane
    /// add affordances open.
    ///
    /// **Refused while a sheet is up.** The menu bar stays live over a sheet, and
    /// replacing the request would dismiss the open editor and drop what was typed in
    /// it. (Before 79 each sheet had its own state, and SwiftUI would not stack a second
    /// one; this keeps that outcome on purpose rather than by accident.)
    private func performArtifactCommand(_ command: ArchiveModel.ArtifactCommand) {
        guard sheet == nil else { return }
        switch command {
        case .addEvent: sheet = ArtifactSheet(.assertion(.blankEvent))
        case .addPlace: sheet = ArtifactSheet(.assertion(.blankPlace))
        case .addPerson: sheet = ArtifactSheet(.mention(.add))
        case .editTranscript: sheet = ArtifactSheet(.transcript)
        }
    }

    /// Runs a per-file menu command against the selected file, reusing the same
    /// actions the per-row ⋯ menu uses. No-op if the selection has gone away.
    private func performFileCommand(_ command: ArchiveModel.FileCommand) {
        guard let selectedFileID, let entry = files.first(where: { $0.uid == selectedFileID })
        else { return }
        let actions = ArtifactFileActions(
            model: model, artifactID: artifact.uid, openWindow: openWindow)
        switch command {
        case .openSeparateWindow: actions.popOut(entry)
        case .openInDefaultApp: actions.openExternally(entry)
        case .saveCopy: actions.saveCopy(entry)
        case .replace: model.beginReplace(fileID: entry.uid, artifactID: artifact.uid)
        case .delete: confirmingFileDelete = entry
        }
    }

    /// The artifact's primary file for the default preview: the first preservation
    /// master (the archival original), else the first file of any role.
    private static func primaryFile(in files: [FileEntry]) -> FileEntry? {
        files.first { $0.role == .preservationMaster } ?? files.first
    }

    /// Identity for the full-record `.task`: changes when a different artifact is
    /// selected, when the file count changes (attach), *or* on any committed
    /// mutation (`model.mutationVersion`) — the last so an undo/redo originating in
    /// the model reloads the fields, transcript, and files, not just user edits.
    private var filesLoadKey: String {
        "\(artifact.uid.raw)#\(artifact.fileCount)#\(model.mutationVersion)"
    }
}

// MARK: - Sheets

/// A request for one of the artifact detail's sheets, driving its single
/// `.sheet(item:)`. The fresh `id` makes every request a new presentation, even when
/// it asks for the same kind of sheet as the last one.
struct ArtifactSheet: Identifiable {
    enum Kind {
        /// Add an event or place, or promote an embedded-metadata suggestion.
        case assertion(AssertionEditorSheet.Prefill)
        /// Add a person mention, or edit one's name/role/quality/age/language/script.
        case mention(PersonMentionEditorSheet.Mode)
        /// Add or edit a `RecordedFact` on one mention. The mention is addressed by its
        /// record-local `localRef`; its name rides along for the editor's heading.
        /// `report` tells the row where an edit's fact ended up, for its focus return (79b).
        case mentionFact(
            mentionRef: String, mentionName: String, mode: RecordedFactEditorSheet.Mode,
            report: EditReport<RecordedFact>? = nil)
        /// Resolve a mention to a person. `replacing` is the dangling link this
        /// resolution replaces (slice 44g), or `nil` for a first-time resolve — carried
        /// through so the sheet can unlink the stale citation and create the new one as
        /// one grouped, undoable step.
        case resolve(mention: PersonMention, replacing: EvidenceLinkID?)
        /// The full-height transcript editor.
        case transcript
    }

    let id = UUID()
    let kind: Kind
    /// Called once the sheet has finished closing, so a row can take focus back without
    /// the dismissal overriding it (79b).
    var onDismiss: (() -> Void)?

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// Edit `mention` in the mention editor. The one owner of how a mention is addressed
    /// for editing, shared by the row's name and its Add Relationship… button.
    static func editMention(_ mention: PersonMention) -> ArtifactSheet {
        ArtifactSheet(.mention(.edit(ref: mention.localRef, existing: mention)))
    }
}

/// The sheet a request asks for. The mention editor's mentions and stated relationships
/// are the coordinator's loaded record, handed down again on every reload, so they stay
/// live while it is open (an undo underneath it updates them). The transcript editor
/// writes its saved text back through `transcript`, since its edit doesn't change
/// `filesLoadKey`.
private struct ArtifactSheetContent: View {
    let request: ArtifactSheet
    let artifactID: ArtifactID
    let mentions: [PersonMention]
    let statedRelationships: [MentionRelationship]
    @Binding var transcript: String?

    var body: some View {
        switch request.kind {
        case .assertion(let prefill):
            AssertionEditorSheet(artifactID: artifactID, prefill: prefill)
        case .mention(let mode):
            PersonMentionEditorSheet(
                artifactID: artifactID, mode: mode, mentions: mentions,
                statedRelationships: statedRelationships)
        case .mentionFact(let ref, let name, let mode, let report):
            RecordedFactEditorSheet(
                artifactID: artifactID, mentionRef: ref, mentionName: name, mode: mode,
                report: report)
        case .resolve(let mention, let replacing):
            ResolveMentionSheet(artifactID: artifactID, mention: mention, replacing: replacing)
        case .transcript:
            TranscriptEditorSheet(artifactID: artifactID, initialText: transcript) { saved in
                transcript = saved
            }
        }
    }
}

/// Placeholder shown when no artifact is selected.
struct ArtifactDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Select an Artifact", systemImage: "doc.text.magnifyingglass",
            description: Text("Choose an artifact from the list to see its details."))
    }
}

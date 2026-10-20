import AppKit
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Detail view for the selected artifact: read-only by default, switching into an
/// explicit edit mode (Edit → Done/Cancel) that buffers changes locally and
/// commits them in one `updateMetadata` write.
struct ArtifactDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let artifact: ArtifactSummary

    /// Drives the add/apply assertion sheet (manual Add Event/Place, or promoting an
    /// embedded-metadata suggestion), or `nil` when no sheet is up.
    @State private var pendingAssertion: PendingAssertion?

    /// Drives the person-mention editor (add a new mention, or edit an existing one's
    /// name/role/quality/age/name-language/script), or `nil` when no sheet is up.
    @State private var pendingMention: PendingMention?

    /// Drives the mention-scoped recorded-fact editor (add/edit a `RecordedFact` on one
    /// of the artifact's person mentions), or `nil` when no sheet is up.
    @State private var pendingMentionFact: PendingMentionFact?

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

    /// Whether the full-height transcript editor sheet is up.
    @State private var isEditingTranscript = false

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

    /// The mention whose resolve sheet is up (pick or create a person to link), or
    /// `nil`. An `Identifiable` wrapper so it can drive `.sheet(item:)`.
    @State private var resolvingMention: ResolveRequest?

    /// The relationships this record supports that `conclusions/` doesn't yet assert
    /// (slice 45l). Loaded with the record and reloaded off `mutationVersion`, like `links`:
    /// resolving one more mention is exactly what makes an edge promotable, so the list has
    /// to move the moment a chip appears above it.
    @State private var relationshipSuggestions: [RelationshipReviewItem] = []

    /// Opens popped-out preview windows (the pane's "separate window" action).
    @Environment(\.openWindow) private var openWindow

    /// Whether the metadata inspector is shown. Per-window and restored across relaunch
    /// (it rides the same `@SceneStorage` machinery as the artifact selection); defaults
    /// to visible so a fresh window shows the metadata beside the document.
    @SceneStorage("inspectorShown") private var inspectorShown: Bool = true

    var body: some View {
        documentPane
            // Metadata lives in a trailing inspector beside the document, toggled from
            // the toolbar. Edit mode happens *inside* the inspector, so the document
            // stays visible while you transcribe evidence off it.
            .inspector(isPresented: $inspectorShown) {
                inspectorContent
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
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
            .sheet(item: $pendingAssertion) { pending in
                AssertionEditorSheet(artifactID: artifact.uid, prefill: pending.prefill)
                    .environment(model)
            }
            .sheet(item: $pendingMention) { pending in
                PersonMentionEditorSheet(
                    artifactID: artifact.uid, mode: pending.mode,
                    mentions: detail?.personsMentioned ?? [],
                    statedRelationships: detail?.mentionRelationships ?? []
                )
                .environment(model)
            }
            .sheet(item: $pendingMentionFact) { pending in
                RecordedFactEditorSheet(
                    artifactID: artifact.uid, mentionRef: pending.mentionRef,
                    mentionName: pending.mentionName, mode: pending.mode
                )
                .environment(model)
            }
            .sheet(item: $resolvingMention) { request in
                ResolveMentionSheet(
                    artifactID: artifact.uid, mention: request.mention,
                    replacing: request.replacing
                )
                .environment(model)
            }
            // Presented at the top level (not inside `inspectorContent`) so the
            // Artifact ▸ Edit Transcript… menu command works even with the inspector
            // hidden — the in-pane button and the menu both set `isEditingTranscript`.
            .sheet(isPresented: $isEditingTranscript) {
                TranscriptEditorSheet(
                    artifactID: artifact.uid, initialText: transcript
                ) { saved in
                    transcript = saved
                }
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
        // artifact's name is the heading above the document, in `documentHeader`.
    }

    /// Runs an artifact-scoped menu command by driving this view's own sheet state
    /// (the same state the in-pane add affordances set).
    private func performArtifactCommand(_ command: ArchiveModel.ArtifactCommand) {
        switch command {
        case .addEvent: pendingAssertion = PendingAssertion(prefill: .blankEvent)
        case .addPlace: pendingAssertion = PendingAssertion(prefill: .blankPlace)
        case .addPerson: pendingMention = PendingMention(mode: .add)
        case .editTranscript: isEditingTranscript = true
        }
    }

    /// Runs a per-file menu command against the selected file, reusing the same
    /// handlers the per-row ⋯ menu uses. No-op if the selection has gone away.
    private func performFileCommand(_ command: ArchiveModel.FileCommand) {
        guard let entry = selectedFileEntry else { return }
        switch command {
        case .openSeparateWindow: popOut(entry)
        case .openInDefaultApp: openExternally(entry)
        case .saveCopy: saveCopy(entry)
        case .replace: model.beginReplace(fileID: entry.uid, artifactID: artifact.uid)
        case .delete: confirmingFileDelete = entry
        }
    }

    // MARK: - Document pane (primary content)

    /// The detail pane's primary content: the artifact's title, the selected file's
    /// preview, and — for a multi-file artifact — a strip to switch between files. A
    /// metadata-only artifact (no files) shows an attach affordance instead.
    private var documentPane: some View {
        VStack(spacing: 0) {
            documentHeader
            Divider()
            documentBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var documentHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(artifact.title)
                .font(.title2)
                .fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            if let entry = selectedFileEntry {
                Button {
                    popOut(entry)
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

    @ViewBuilder
    private var documentBody: some View {
        if files.isEmpty {
            ContentUnavailableView {
                Label("No Files Yet", systemImage: "tray")
            } description: {
                Text(
                    "This artifact has no attached files. Attach a document, photo, or "
                        + "scan to see it here.")
            } actions: {
                Button("Attach File…") { model.beginAttachOrScan(to: artifact.uid) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                if files.count > 1 {
                    fileSelectorStrip
                    Divider()
                }
                documentPreview
            }
        }
    }

    /// Horizontal strip of the artifact's files; selecting one previews it. Shown only
    /// for a multi-file artifact (a single file needs no selector).
    private var fileSelectorStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(files, id: \.uid) { entry in
                    FileChip(entry: entry, isSelected: entry.uid == selectedFileID) {
                        selectedFileID = entry.uid
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var documentPreview: some View {
        if let entry = selectedFileEntry {
            if let url = model.fileURL(of: entry.uid, in: artifact.uid) {
                // `.id` resets the preview's own state (scroll, loaded image) when a
                // different file is selected.
                FilePreviewContent(url: url)
                    .id(entry.uid)
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

    /// The artifact's primary file for the default preview: the first preservation
    /// master (the archival original), else the first file of any role.
    private static func primaryFile(in files: [FileEntry]) -> FileEntry? {
        files.first { $0.role == .preservationMaster } ?? files.first
    }

    // MARK: - Inspector (metadata)

    /// The metadata inspector: the descriptive fields, evidence sections (events,
    /// places, persons), transcript, files management, embedded-metadata suggestions,
    /// and identifiers — everything that used to fill the detail pane, now in a
    /// toggleable trailing inspector beside the document. Edit mode swaps the read-only
    /// fields for the editor form here, leaving the document visible.
    private var inspectorContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                inspectorHeader

                // Descriptive fields are always editable (no Edit/Done mode) and commit
                // on blur. They need the full record, so they wait for `detail` to load.
                if let detail {
                    EditableArtifactFields(artifact: detail, primaryDate: artifact.primaryDate)
                }

                EventsPlacesSection(
                    events: detail?.events ?? [],
                    locations: detail?.locations ?? [],
                    onAddEvent: { pendingAssertion = PendingAssertion(prefill: .blankEvent) },
                    onAddPlace: { pendingAssertion = PendingAssertion(prefill: .blankPlace) },
                    onDeleteEvent: deleteEvent,
                    onDeletePlace: deletePlace
                )

                PersonsMentionedSection(
                    persons: detail?.personsMentioned ?? [],
                    statedRelationships: detail?.mentionRelationships ?? [],
                    links: links,
                    personLookup: { id in model.persons.first { $0.uid == id } },
                    onAdd: { pendingMention = PendingMention(mode: .add) },
                    onEdit: { mention in
                        pendingMention = PendingMention(
                            mode: .edit(ref: mention.localRef, existing: mention))
                    },
                    onDelete: deletePerson,
                    onResolve: { resolvingMention = ResolveRequest(mention: $0, replacing: $1) },
                    onUnlink: { model.unlinkMention($0) },
                    onNavigate: { model.navigateToPerson($0) },
                    onAddFact: { ref in
                        pendingMentionFact = PendingMentionFact(
                            mentionRef: ref, mentionName: mentionName(ref: ref), mode: .add)
                    },
                    onEditFact: { ref, index, fact in
                        pendingMentionFact = PendingMentionFact(
                            mentionRef: ref, mentionName: mentionName(ref: ref),
                            mode: .edit(index: index, existing: fact))
                    },
                    onDeleteFact: deleteMentionFact,
                    artifactID: artifact.uid,
                    relationshipSuggestions: relationshipSuggestions,
                    // Both verbs bump `mutationVersion`, which is in `filesLoadKey`, so the
                    // list re-derives from the engine rather than being patched here. One
                    // owner of what is still owed — the same reason the inspector filters
                    // the lane's answer instead of computing its own.
                    onRecordRelationship: { model.confirmSuggestedRelationship($0) },
                    onDismissRelationship: { model.dismissSuggestedRelationship($0) }
                )

                TranscriptSection(transcript: transcript) {
                    isEditingTranscript = true
                }

                FilesSection(
                    files: files,
                    selectedFileID: $selectedFileID,
                    onAttachOrScan: { model.beginAttachOrScan(to: artifact.uid) },
                    onPopOut: { fileID in if let e = entry(fileID) { popOut(e) } },
                    onOpenExternally: { fileID in if let e = entry(fileID) { openExternally(e) }
                    },
                    onSaveCopy: { fileID in if let e = entry(fileID) { saveCopy(e) } },
                    onScanMetadata: { fileID in
                        if let e = entry(fileID) {
                            model.scanFileForMetadata(
                                e.uid, in: artifact.uid, originalName: e.originalName)
                        }
                    },
                    onSetRole: { fileID, role in
                        model.setFileRole(fileID, in: artifact.uid, to: role)
                    },
                    onReplace: { fileID in
                        model.beginReplace(fileID: fileID, artifactID: artifact.uid)
                    },
                    onDelete: { fileID in model.detachFile(fileID, from: artifact.uid) }
                )

                if let embedded = model.capturedMetadata[artifact.uid], !embedded.isEmpty {
                    EmbeddedMetadataSection(metadata: embedded) { entry in
                        pendingAssertion = PendingAssertion(prefill: .suggestion(entry))
                    }
                }

                // UID/slug are internal addressing — useful for support, but not
                // the first thing a researcher wants, so they sit de-emphasized
                // at the very bottom.
                IdentifiersSection(uid: artifact.uid.raw, slug: artifact.slug)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inspectorHeader: some View {
        Text("Details")
            .font(.headline)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Removes the event at `index` (undoable, like every `updateMetadata` write).
    /// The index addresses the loaded `detail.events`, which matches stored order;
    /// the bounds check guards against a stale index after a concurrent reload.
    private func deleteEvent(_ index: Int) {
        model.updateMetadata(of: artifact.uid, actionName: "Remove Event") {
            guard $0.events.indices.contains(index) else { return }
            $0.events.remove(at: index)
        }
    }

    /// Removes the place at `index` (undoable). See `deleteEvent` on indexing.
    private func deletePlace(_ index: Int) {
        model.updateMetadata(of: artifact.uid, actionName: "Remove Place") {
            guard $0.locations.indices.contains(index) else { return }
            $0.locations.remove(at: index)
        }
    }

    /// Removes the person mention at `index` (undoable). See `deleteEvent` on indexing.
    /// Any `EvidenceLink` pointing at the removed `localRef` is left dangling — that's
    /// `verifyIntegrity()`'s job (§2.3), and conclusions are a Phase 3 concern.
    private func deletePerson(_ index: Int) {
        model.updateMetadata(of: artifact.uid, actionName: "Remove Person Mentioned") {
            guard $0.personsMentioned.indices.contains(index) else { return }
            $0.personsMentioned.remove(at: index)
        }
    }

    /// The name-as-recorded of the mention with `localRef` `ref`, for the fact editor's
    /// heading; empty when the mention isn't found (a stale ref) or has no name.
    private func mentionName(ref: String) -> String {
        detail?.personsMentioned.first { $0.localRef == ref }?.nameAsRecorded ?? ""
    }

    /// Removes the recorded fact at `index` from the mention with `ref` (undoable). The
    /// mention is found by its stable `localRef`; both bounds are checked inside the
    /// closure against the loaded record. See `deleteEvent` on indexing.
    private func deleteMentionFact(ref: String, index: Int) {
        model.updateMetadata(of: artifact.uid, actionName: "Remove Recorded Fact") { record in
            guard
                let position = record.personsMentioned.firstIndex(where: { $0.localRef == ref })
            else { return }
            guard record.personsMentioned[position].facts.indices.contains(index) else { return }
            record.personsMentioned[position].facts.remove(at: index)
        }
    }

    /// The currently previewed file entry (the inline pane's subject), or `nil`.
    private var selectedFileEntry: FileEntry? {
        guard let selectedFileID else { return nil }
        return files.first { $0.uid == selectedFileID }
    }

    private func entry(_ fileID: FileID) -> FileEntry? {
        files.first { $0.uid == fileID }
    }

    /// Opens `entry` in a separate preview window, over a session-temp copy.
    private func popOut(_ entry: FileEntry) {
        guard
            let copy = model.temporaryCopy(
                of: entry.uid, in: artifact.uid, originalName: entry.originalName)
        else { return }
        openWindow(value: FilePreviewRequest(url: copy, title: entry.originalName))
    }

    /// Opens a session-temp copy of `entry` in the user's default app for that type.
    private func openExternally(_ entry: FileEntry) {
        guard
            let copy = model.temporaryCopy(
                of: entry.uid, in: artifact.uid, originalName: entry.originalName)
        else { return }
        NSWorkspace.shared.open(copy)
    }

    /// Exports a copy of `entry` to a user-chosen location via the save panel.
    private func saveCopy(_ entry: FileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.originalName
        panel.canCreateDirectories = true
        panel.title = "Save a Copy"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.exportFile(entry.uid, in: artifact.uid, to: destination)
    }

    /// Identity for the full-record `.task`: changes when a different artifact is
    /// selected, when the file count changes (attach), *or* on any committed
    /// mutation (`model.mutationVersion`) — the last so an undo/redo originating in
    /// the model reloads the fields, transcript, and files, not just user edits.
    private var filesLoadKey: String {
        "\(artifact.uid.raw)#\(artifact.fileCount)#\(model.mutationVersion)"
    }
}

/// Identifiable wrapper so an add/apply request can drive `.sheet(item:)`.
private struct PendingAssertion: Identifiable {
    let id = UUID()
    let prefill: AssertionEditorSheet.Prefill
}

/// Identifiable wrapper so a mention add/edit request can drive `.sheet(item:)`.
private struct PendingMention: Identifiable {
    let id = UUID()
    let mode: PersonMentionEditorSheet.Mode
}

/// Identifiable wrapper so a mention-fact add/edit request can drive `.sheet(item:)`.
/// The mention is addressed by its record-local `localRef`; its name rides along so the
/// editor can name the person in its heading.
private struct PendingMentionFact: Identifiable {
    let id = UUID()
    let mentionRef: String
    let mentionName: String
    let mode: RecordedFactEditorSheet.Mode
}

/// Identifiable wrapper so a resolve-mention request can drive `.sheet(item:)`.
private struct ResolveRequest: Identifiable {
    let id = UUID()
    let mention: PersonMention
    /// The dangling link this resolution **replaces** (slice 44g), or `nil` for a
    /// first-time resolve. Carried through so the sheet can unlink the stale citation
    /// and create the new one as one grouped, undoable step.
    var replacing: EvidenceLinkID?
}

/// Placeholder shown when no artifact is selected.
struct ArtifactDetailPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            "Select an Artifact", systemImage: "doc.text.magnifyingglass",
            description: Text("Choose an artifact from the list to see its details."))
    }
}

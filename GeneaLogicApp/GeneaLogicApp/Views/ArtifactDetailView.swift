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

// MARK: - Editable fields

/// The artifact's descriptive metadata, **always editable** — no Edit/Done mode (the
/// idiomatic Mac inspector, à la Finder Get Info). Text fields commit on blur or Return;
/// the two pickers commit immediately on change; every commit is its own undoable
/// `updateMetadata` write, and a commit only fires when the value actually changed.
///
/// Local `@State` buffers in-progress text. The loaded `artifact` is the source of truth:
/// an external change to it (undo/redo, an applied suggestion) re-seeds the buffers via
/// `onChange(of: artifact)`, so the inspector never shows a stale value. The derived
/// Primary Date is shown read-only — it's the earliest event date, recorded via the
/// Events & Places section, never typed here.
private struct EditableArtifactFields: View {
    @Environment(ArchiveModel.self) private var model
    let artifact: Artifact
    /// The derived Primary Date (earliest event date), supplied by the browse summary —
    /// it isn't stored on the full `Artifact`. Shown read-only when present.
    let primaryDate: String?

    private enum Field: Hashable { case title, tags, language, originalFormat, notes }

    @State private var title: String
    @State private var tagsText: String
    @State private var language: String
    @State private var originalFormat: String
    @State private var notes: String
    @State private var mediaType: MediaType
    /// Optional since 46b: `nil` = **Unstated**, exactly as `sourceDerivation` below.
    /// A required tier meant every import had to assert a genre, and the one it asserted
    /// was `compiled` — the lowest, and a claim about evidence nobody had made.
    @State private var sourceTier: SourceAuthorityTier?
    /// The GPS source-derivation axis (original / derivative / authored), orthogonal to
    /// the genre-shaped Source Tier. Optional: `nil` = **Unstated**, never "original"
    /// (§4.2 — absence must not assert the record is a first-hand original).
    @State private var sourceDerivation: SourceDerivation?
    @FocusState private var focus: Field?

    init(artifact: Artifact, primaryDate: String?) {
        self.artifact = artifact
        self.primaryDate = primaryDate
        _title = State(initialValue: artifact.title)
        _tagsText = State(initialValue: artifact.tags.joined(separator: ", "))
        _language = State(initialValue: artifact.language ?? "")
        _originalFormat = State(initialValue: artifact.originalFormat ?? "")
        _notes = State(initialValue: artifact.notes ?? "")
        _mediaType = State(initialValue: artifact.mediaType)
        _sourceTier = State(initialValue: artifact.sourceAuthorityTier)
        _sourceDerivation = State(initialValue: artifact.sourceDerivation)
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            EditRow("Title") {
                TextField("Title", text: $title)
                    .labelsHidden()
                    .focused($focus, equals: .title)
            }
            EditRow("Media Type") {
                Picker("Media Type", selection: $mediaType) {
                    ForEach(mediaTypeOptions, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            EditRow("Source Tier") {
                Picker("Source Tier", selection: $sourceTier) {
                    // `nil` = Unstated, tagged as an optional so the known cases and
                    // "unstated" share one selection — the Source Derivation pattern
                    // below, which this row joined in 46b.
                    Text("Unstated").tag(SourceAuthorityTier?.none)
                    ForEach(sourceTierOptions, id: \.self) {
                        Text($0.rawValue).tag(SourceAuthorityTier?.some($0))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            EditRow("Source Derivation") {
                Picker("Source Derivation", selection: $sourceDerivation) {
                    // `nil` = Unstated (the honest default). Tagged as an optional so the
                    // known cases and "unstated" share one selection.
                    Text("Unstated").tag(SourceDerivation?.none)
                    ForEach(sourceDerivationOptions, id: \.self) {
                        Text($0.rawValue).tag(SourceDerivation?.some($0))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            // Primary Date is *derived* (earliest event date) — read-only, shown only
            // when present; dates are recorded as events, never typed here. The value is
            // glossed to human-readable EDTF; the canonical form rides the caption when
            // it differs, so the stored precision stays discoverable.
            if let primaryDate, !primaryDate.isEmpty {
                let human = EDTFDate.parse(primaryDate)?.humanDescription ?? primaryDate
                GridRow {
                    Text("Primary Date")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(human)
                            .textSelection(.enabled)
                        Text(
                            human == primaryDate
                                ? "earliest event date" : "earliest event date · \(primaryDate)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            EditRow("Tags") {
                TextField("Tags", text: $tagsText, prompt: Text("comma, separated"))
                    .labelsHidden()
                    .focused($focus, equals: .tags)
            }
            EditRow("Language") {
                TextField("Language", text: $language, prompt: Text("BCP 47, e.g. en"))
                    .labelsHidden()
                    .focused($focus, equals: .language)
            }
            EditRow("Original Format") {
                TextField(
                    "Original Format", text: $originalFormat, prompt: Text("e.g. digital scan")
                )
                .labelsHidden()
                .focused($focus, equals: .originalFormat)
            }
            EditRow("Notes") {
                TextField("Notes", text: $notes, prompt: Text("free-form"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(3...8)
                    .focused($focus, equals: .notes)
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: Layout.fieldColumnMaxWidth, alignment: .leading)
        // Commit a text field when focus leaves it (moves to another field or away).
        .onChange(of: focus) { previous, _ in commitText(previous) }
        // Return commits the focused single-line field.
        .onSubmit { commitText(focus) }
        // Pickers commit immediately; the guard skips the no-op echo from re-seeding.
        .onChange(of: mediaType) { _, value in
            guard value != artifact.mediaType else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Change Media Type") {
                $0.mediaType = value
            }
        }
        .onChange(of: sourceTier) { _, value in
            guard value != artifact.sourceAuthorityTier else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Change Source Tier") {
                $0.sourceAuthorityTier = value
            }
        }
        .onChange(of: sourceDerivation) { _, value in
            guard value != artifact.sourceDerivation else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Change Source Derivation") {
                $0.sourceDerivation = value
            }
        }
        // Re-seed when the loaded record changes underneath us (undo/redo, applied
        // suggestion). `Artifact` is Equatable, so this fires only on real changes.
        //
        // **And let go of the field if its text is what changed** (52, found by
        // hand-test). A focused `TextField` has a live field editor, and AppKit
        // registers *its own* undo step against the window's manager when that
        // text is replaced programmatically. That used to be harmless: the engine
        // write was synchronous, so the re-seed happened inside `undo()` and
        // `NSUndoManager` filed the field's step as a redo. Now the write is
        // awaited, the re-seed lands a turn later with `isUndoing` already false,
        // and the field's step goes on the *undo* stack as a nameless entry —
        // where it swallows the next ⌘Z. Symptom: undo an artifact rename twice
        // and the second press does nothing (Edit ▸ Undo loses its action name).
        //
        // Releasing focus ends the field editor, so there is nothing to register.
        // Only when the focused field's own value moved, so committing an edit and
        // tabbing on doesn't yank focus back out from under the user — and *after*
        // the re-seed, so the `commitText` that focus loss triggers compares equal
        // and writes nothing.
        .onChange(of: artifact) { _, _ in releaseFocusIfOverwritten() }
        // A **rejected** write needs the same treatment and cannot use the trigger
        // above: nothing was written, so the record is unchanged and `artifact`
        // compares equal. Without this the field goes on displaying text the
        // archive refused — which looks saved (52, hand-test).
        .onChange(of: model.writeFailures) { _, _ in releaseFocusIfOverwritten() }
    }

    /// Writes the field that just lost focus, if its value actually changed.
    private func commitText(_ field: Field?) {
        guard let field else { return }
        switch field {
        case .title:
            let trimmed = title.trimmed
            // Title is required: an empty entry reverts to the stored value, never saves.
            guard !trimmed.isEmpty else {
                title = artifact.title
                return
            }
            guard trimmed != artifact.title else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Edit Title") { $0.title = trimmed }
        case .tags:
            let parsed = Self.parseTags(tagsText)
            guard parsed != artifact.tags else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Edit Tags") { $0.tags = parsed }
        case .language:
            let value = language.trimmedNonEmpty
            guard value != artifact.language else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Edit Language") {
                $0.language = value
            }
        case .originalFormat:
            let value = originalFormat.trimmedNonEmpty
            guard value != artifact.originalFormat else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Edit Original Format") {
                $0.originalFormat = value
            }
        case .notes:
            let value = notes.trimmedNonEmpty
            guard value != artifact.notes else { return }
            model.updateMetadata(of: artifact.uid, actionName: "Edit Notes") { $0.notes = value }
        }
    }

    /// Re-seeds every field from the stored record and, if that overwrote the one
    /// the user is in, lets go of it. See the `onChange(of: artifact)` note above
    /// for why releasing focus matters and why it is conditional.
    private func releaseFocusIfOverwritten() {
        let focusedFieldWasOverwritten = focusedFieldWouldChange
        reseed()
        if focusedFieldWasOverwritten { focus = nil }
    }

    /// Whether the field the user is currently in is about to be overwritten by
    /// `reseed()` — i.e. the record changed under them rather than because of
    /// them. See the `onChange(of: artifact)` note above.
    private var focusedFieldWouldChange: Bool {
        switch focus {
        case .title: title != artifact.title
        case .tags: tagsText != artifact.tags.joined(separator: ", ")
        case .language: language != (artifact.language ?? "")
        case .originalFormat: originalFormat != (artifact.originalFormat ?? "")
        case .notes: notes != (artifact.notes ?? "")
        case nil: false
        }
    }

    private func reseed() {
        title = artifact.title
        tagsText = artifact.tags.joined(separator: ", ")
        language = artifact.language ?? ""
        originalFormat = artifact.originalFormat ?? ""
        notes = artifact.notes ?? ""
        mediaType = artifact.mediaType
        sourceTier = artifact.sourceAuthorityTier
        sourceDerivation = artifact.sourceDerivation
    }

    /// Splits the comma-separated tag field into trimmed, non-empty tags.
    private static func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Known media types, plus the current value if it's an unrecognized (`.unknown`)
    /// vocabulary term so editing never silently drops it. (These fields commit on
    /// change, so anchoring on the live value is fine — there's no revert-before-save.)
    private var mediaTypeOptions: [MediaType] {
        MediaType.pickerOptions(including: mediaType)
    }

    /// Anchored on `.compiled` when unstated, for the same reason `sourceDerivation`
    /// anchors on `.original`: the anchor only decides whether an extra `.unknown` option
    /// is kept, and with nothing stored there is none to keep. The selection stays `nil`.
    private var sourceTierOptions: [SourceAuthorityTier] {
        SourceAuthorityTier.pickerOptions(including: sourceTier ?? .compiled)
    }

    /// Known derivations, plus the current value if it's an unrecognized (`.unknown`)
    /// term so editing never silently drops it. Anchored on `.original` when unstated —
    /// a harmless anchor, since `.original` is already a known case (this only decides
    /// which extra option to keep, not the selection, which stays `nil`/Unstated).
    private var sourceDerivationOptions: [SourceDerivation] {
        SourceDerivation.pickerOptions(including: sourceDerivation ?? .original)
    }
}

/// The artifact's internal identifiers (UID + package slug), shown small and
/// de-emphasized at the bottom of the detail. Not edited; copyable for support.
private struct IdentifiersSection: View {
    let uid: String
    let slug: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                IdentifierRow(label: "UID", value: uid)
                IdentifierRow(label: "Slug", value: slug)
            }
        }
        .padding(.top, 8)
    }

    private struct IdentifierRow: View {
        let label: String
        let value: String

        var body: some View {
            GridRow {
                Text(label)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
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

// MARK: - Editable fields helper

/// A label + editable-content row, the grid's left-aligned label column matching the
/// other inspector sections.
private struct EditRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        GridRow {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content
        }
    }
}

// MARK: - Transcript

/// The artifact's inline transcript, shown read-only with an "Edit Transcript"
/// action that opens the full-height editor sheet. A `role: .transcript` *file*
/// (long transcripts) is shown separately in the Files list, not here.
private struct TranscriptSection: View {
    let transcript: String?
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button {
                    onEdit()
                } label: {
                    AddAffordanceLabel(
                        title: hasText ? "Edit Transcript…" : "Add Transcript…",
                        systemImage: "text.quote")
                }
                .buttonStyle(.plain)
            }

            if let transcript, hasText {
                Text(transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: Layout.readableTextMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No transcript. Use Add Transcript… to type one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var hasText: Bool {
        !(transcript?.trimmed.isEmpty ?? true)
    }
}

// MARK: - Section add affordances

// MARK: - Events & Places

/// The artifact's recorded events and places, with an **Add…** menu that opens the
/// blank assertion editor (manual event/place entry — the path for files that carry
/// no usable embedded metadata) and a per-row remove. Promoting an embedded
/// suggestion lands here too; both write `events`/`locations` via `updateMetadata`,
/// so a removal is undoable like any other edit.
///
/// Rich editing of an existing event is deferred to the Phase 3 conclusions UI;
/// here the verbs are add and remove.
private struct EventsPlacesSection: View {
    let events: [Event]
    let locations: [Location]
    let onAddEvent: () -> Void
    let onAddPlace: () -> Void
    let onDeleteEvent: (Int) -> Void
    let onDeletePlace: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Events & Places")
                    .font(.headline)
                Spacer()
                Menu {
                    Button("Add Event…", systemImage: "calendar") { onAddEvent() }
                    Button("Add Place…", systemImage: "mappin.and.ellipse") { onAddPlace() }
                } label: {
                    AddAffordanceLabel(title: "Add…", systemImage: "plus", opensMenu: true)
                }
                // `.menuStyle(.button)` + `.buttonStyle(.plain)` renders the *full*
                // custom label faithfully (so `AddAffordanceLabel`'s own chevron shows,
                // matching the Files button) and imposes no foreground of its own — the
                // label's `.primary` color wins. `.borderless`/`.borderlessButton` each
                // mute the label (which read as disabled) and `.borderlessButton` also
                // drops the custom chevron, which is what made the affordances mismatch (F8).
                // `.plain` already suppresses the native menu indicator; hiding it is
                // explicit belt-and-suspenders so our own chevron is the only one.
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }

            if events.isEmpty && locations.isEmpty {
                Text("No events or places recorded. Use Add… to record one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(events.enumerated()), id: \.offset) { index, event in
                        AssertionRow(
                            title: event.type.isEmpty ? "Event" : event.type,
                            subtitle: eventSubtitle(event),
                            icon: "calendar"
                        ) { onDeleteEvent(index) }
                    }
                    ForEach(Array(locations.enumerated()), id: \.offset) { index, location in
                        AssertionRow(
                            title: location.asRecorded,
                            subtitle: location.normalized,
                            icon: "mappin.and.ellipse"
                        ) { onDeletePlace(index) }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    /// "about 1920 · Cook County, Illinois", either part omitted when absent. The date
    /// is glossed to human-readable EDTF, falling back to the raw string when it isn't
    /// parseable as a date (free text is kept verbatim).
    private func eventSubtitle(_ event: Event) -> String? {
        let dateText = event.date?.trimmedNonEmpty.map {
            EDTFDate.parse($0)?.humanDescription ?? $0
        }
        let parts = [dateText, event.location?.trimmedNonEmpty].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Persons Mentioned

/// The persons this artifact *names* — evidence-layer `PersonMention`s, each a "name
/// as it appears in this document" plus a role, not a tree identity. An **Add Person…**
/// button opens the blank assertion editor; a per-row remove writes through
/// `updateMetadata`, so it's undoable like any other edit.
///
/// Each row also carries its **resolution state** (slice 42): an unresolved mention
/// shows a **Resolve…** affordance (opens the resolve sheet), a resolved one shows a
/// chip for the concluded `Person` it's linked to — tap to jump to the People tab —
/// with an **Unlink** control. Resolving a mention is a conclusion-layer act
/// (`EvidenceLink`), kept distinct from the evidence-layer add/remove: removing the
/// mention deletes the evidence, unlinking removes only the conclusion.
private struct PersonsMentionedSection: View {
    let persons: [PersonMention]
    /// The record's stated relationships (slice 45k). Held at the section rather than
    /// the row because an edge belongs to the *record*, not to either end of it; each
    /// row filters out the ones that touch it.
    let statedRelationships: [MentionRelationship]
    let links: [EvidenceLink]
    let personLookup: (PersonID) -> PersonSummary?
    let onAdd: () -> Void
    let onEdit: (PersonMention) -> Void
    let onDelete: (Int) -> Void
    /// Opens the resolve sheet for a mention; the second argument is the stale link
    /// being replaced (a re-resolve) or `nil` (a first resolve).
    let onResolve: (PersonMention, EvidenceLinkID?) -> Void
    let onUnlink: (EvidenceLinkID) -> Void
    let onNavigate: (PersonID) -> Void
    /// Mention-scoped recorded-fact callbacks, keyed by the mention's stable `localRef`
    /// (not an array index): add a fact, edit the fact at an index, remove it.
    let onAddFact: (String) -> Void
    let onEditFact: (String, Int, RecordedFact) -> Void
    let onDeleteFact: (String, Int) -> Void
    /// Relationships this record supports that `conclusions/` doesn't assert (slice 45l),
    /// and the record they are being read on — a suggestion is archive-wide, so each row
    /// needs to know which of its citations is the one on screen.
    let artifactID: ArtifactID
    let relationshipSuggestions: [RelationshipReviewItem]
    let onRecordRelationship: (RelationshipReviewItem) -> Void
    let onDismissRelationship: (RelationshipReviewItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Persons Mentioned")
                    .font(.headline)
                Spacer()
                // A direct-action button (opens the assertion sheet) — no chevron,
                // unlike the menu-popping Events/Files affordances (F8).
                Button {
                    onAdd()
                } label: {
                    AddAffordanceLabel(title: "Add Person…", systemImage: "person.badge.plus")
                }
                .buttonStyle(.plain)
            }

            if persons.isEmpty {
                Text("No persons recorded. Use Add Person… to record someone this artifact names.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(persons.enumerated()), id: \.offset) { index, person in
                        let link = links.first { $0.personMentionRef == person.localRef }
                        let resolved = link.flatMap { personLookup($0.personUid) }
                        // One predicate, used for both the rendering and the payload:
                        // if they could disagree, a "Re-resolve…" that passed `nil`
                        // would *add* a second link to the same mention rather than
                        // replacing the stale one (the engine's `link` has no
                        // one-per-localRef guard), leaving two wrong citations.
                        let staleLink = resolved == nil ? link : nil
                        PersonMentionRow(
                            mention: person,
                            statedRelationships: statedRelationships,
                            allMentions: persons,
                            link: link,
                            resolvedPerson: resolved,
                            isDangling: staleLink != nil,
                            onEdit: { onEdit(person) },
                            onResolve: { onResolve(person, staleLink?.uid) },
                            onUnlink: { if let link { onUnlink(link.uid) } },
                            onNavigate: { if let link { onNavigate(link.personUid) } },
                            onDelete: { onDelete(index) },
                            onAddFact: { onAddFact(person.localRef) },
                            onEditFact: { factIndex, fact in
                                onEditFact(person.localRef, factIndex, fact)
                            },
                            onDeleteFact: { factIndex in onDeleteFact(person.localRef, factIndex) }
                        )
                    }
                }
            }
            suggestedRelationships
        }
        .padding(.top, 8)
    }

    /// The conclusions this record's own statements support but `conclusions/` doesn't hold
    /// yet — slice 45l's in-place half, beside the Review lane.
    ///
    /// **Here because this is where the judgement is actually made** (45e fork (d)'s
    /// precedent): the cataloguer is standing on the record that states the relationship,
    /// with the names and roles above them, and sending them to a separate queue to agree
    /// with a document they are already reading is the friction the derivation exists to
    /// remove. The lane is for the same work found later, from the other end.
    ///
    /// It is the same engine answer as the lane's, filtered — never a second derivation, so
    /// the two surfaces cannot disagree about what is still owed. Absent entirely when there
    /// is nothing to offer, which is the common case once a record has been worked through.
    @ViewBuilder
    private var suggestedRelationships: some View {
        if !relationshipSuggestions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested Relationships")
                    .font(.subheadline.weight(.semibold))
                ForEach(relationshipSuggestions) { item in
                    SuggestedRelationshipRow(
                        item: item,
                        // **This record's** basis, not the archive-wide `isStated` — a row
                        // here speaks for the document it sits on, and a suggestion another
                        // record states outright may only be *implied* by this one.
                        basis: item.basis(on: artifactID),
                        onRecord: { onRecordRelationship(item) },
                        onDismiss: { onDismissRelationship(item) })
                }
            }
            .padding(.top, 10)
        }
    }
}

/// One suggested relationship as the inspector shows it: the claim, where it came from, and
/// the two verbs.
///
/// **`sparkles`, like every other promotable-evidence row in the app** — a suggested fact
/// and a suggested relationship are the same kind of offer (here is something your record
/// says that your conclusions don't), and giving them two different marks would imply a
/// distinction that isn't there.
private struct SuggestedRelationshipRow: View {
    let item: RelationshipReviewItem
    /// How **this** record supports the claim. `nil` only if the record dropped out of the
    /// evidence between the sweep and the render, in which case the row says nothing about
    /// a basis rather than guessing one.
    let basis: RelationshipBasis?
    let onRecord: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.claim)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                // Which reading produced it, because it is the only evidence there is to
                // weigh — this row has no score and inventing one would be a lie.
                if let basis {
                    Text(
                        basis == .stated
                            ? "This record states it"
                            : "Implied by the roles on this record"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Record", action: onRecord)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("Add this relationship to your conclusions (⌘Z to undo)")
                    Button("Not This", action: onDismiss)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Stop offering this relationship, here and in Review")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// One person-mention row: the recorded name + role, plus its resolution state — a
/// **Resolve…** button when unresolved, or a tappable chip (→ concluded person) with an
/// **Unlink** control when resolved. The trailing trash removes the *mention* (evidence),
/// which is distinct from Unlink (removes only the conclusion link). Mirrors
/// `AssertionRow`'s hover/focus-reveal trash chrome.
private struct PersonMentionRow: View {
    let mention: PersonMention
    /// The whole record's edges and mentions, so the row can name the other end of
    /// each relationship this mention takes part in.
    let statedRelationships: [MentionRelationship]
    let allMentions: [PersonMention]
    let link: EvidenceLink?
    let resolvedPerson: PersonSummary?
    /// The link points at a person that no longer exists (§2.3, no cascade). Decided
    /// by the section, which uses the same answer to route the repair — see there.
    let isDangling: Bool
    /// Opens the mention editor (name/role/quality/age/language/script).
    let onEdit: () -> Void
    let onResolve: () -> Void
    let onUnlink: () -> Void
    let onNavigate: () -> Void
    let onDelete: () -> Void
    /// Recorded-fact callbacks for this mention (fact index-addressed within the mention).
    let onAddFact: () -> Void
    let onEditFact: (Int, RecordedFact) -> Void
    let onDeleteFact: (Int) -> Void

    @State private var isHovering = false
    /// Whether the link's **stored** match reasoning is expanded (slice 45e).
    @State private var isShowingReasoning = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "person")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                // The name + role/quality/age subtitle tap to edit the mention (the same
                // tap-to-edit affordance the People-tab name/fact rows use). The
                // resolution control and recorded facts below have their own actions and
                // stay outside this button.
                Button(action: onEdit) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(mention.nameAsRecorded)
                            .fontWeight(.medium)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Edit")
                statedRelationshipsLine
                resolutionControl
                recordedFacts
            }
            Spacer(minLength: 0)
            RowRemoveButton(
                isHovering: isHovering,
                accessibilityLabel: "Remove Mention",
                help: "Remove this mention (⌘Z to undo)",
                action: onDelete)
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }

    /// What the record states about how **this** person relates to the others it names
    /// (slice 45k) — "Parent: Marcus Feldberg", read from this mention's vantage point.
    ///
    /// A caption rather than a row list: the edges are edited in the mention sheet (the
    /// same tap-to-edit this row already offers), and a second set of controls here
    /// would give one statement two owners. Absent when the record states nothing about
    /// this person, which is the common case.
    @ViewBuilder
    private var statedRelationshipsLine: some View {
        let mine = statedRelationships.filter { $0.involves(mention.localRef) }
        if !mine.isEmpty {
            Text(mine.map(phrase(for:)).joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// One edge as this row reads it — phrased by `MentionRelationship+Display`, the single
    /// owner, so this row and the mention editor cannot describe one statement two ways.
    private func phrase(for edge: MentionRelationship) -> String {
        edge.phrase(from: mention.localRef) { ref in
            allMentions.first { $0.localRef == ref }?.nameAsRecorded
        }
    }

    /// This mention's recorded facts (what the document states about this person),
    /// each tap-to-edit + remove, with an always-present **Add Fact…** affordance.
    /// Indented under the mention's name so it reads as belonging to it.
    @ViewBuilder
    private var recordedFacts: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(mention.facts.enumerated()), id: \.offset) { index, fact in
                AssertionRow(
                    title: fact.type.displayName,
                    subtitle: Self.factSubtitle(fact),
                    icon: "doc.text",
                    onEdit: { onEditFact(index, fact) }
                ) { onDeleteFact(index) }
            }
            HStack(spacing: 12) {
                Button(action: onAddFact) {
                    Label("Add Fact…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Record what this document states about this person")

                // Slice 45k's editing lives in the mention sheet, and until this button
                // existed the only way to reach it was to know that clicking the name
                // opened it. The affordance names the feature; the sheet is still its one
                // owner (an edge belongs to the record, not to either end, so editing it
                // from two places would give one statement two owners). Hidden when the
                // record names nobody else — there is then no one to relate this person to.
                if canRelate {
                    Button(action: onEdit) {
                        Label("Add Relationship…", systemImage: "person.2")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("State how this document relates this person to another it names")
                }
            }
        }
        .padding(.top, 2)
    }

    /// Whether there is anyone on this record to relate this mention *to*.
    private var canRelate: Bool { allMentions.count > 1 }

    /// "“tailor” · 1892 · Łomża · secondary" — value (quoted), date (EDTF-glossed) and
    /// place omitted when absent; the information quality is shown only when the fact
    /// **overrides** the mention's (i.e. it states its own), since an inherited quality
    /// is already implied by the row.
    private static func factSubtitle(_ fact: RecordedFact) -> String? {
        var parts: [String] = []
        if let value = fact.value?.trimmedNonEmpty {
            parts.append("“\(value)”")
        }
        if let date = fact.date?.trimmedNonEmpty {
            parts.append(EDTFDate.parse(date)?.humanDescription ?? date)
        }
        if let place = fact.place?.trimmedNonEmpty {
            parts.append(place)
        }
        if let quality = fact.informationQuality {
            parts.append(quality.displayName.lowercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var resolutionControl: some View {
        if isDangling {
            HStack(spacing: 8) {
                // Not a button: there is nothing to navigate to, and rendering it as one
                // is the bug — it looked live and then selected nothing.
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.small)
                    Text("Missing person")
                }
                .font(.caption)
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.12), in: Capsule())
                .help("This mention is linked to a person that was deleted")

                Button("Re-resolve…", action: onResolve)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("Point this citation at a person that still exists")

                Button("Unlink", action: onUnlink)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Drop the stale link, leaving the mention unresolved (⌘Z to undo)")
            }
        } else if let link {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button(action: onNavigate) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right")
                                .imageScale(.small)
                            Text(chipText)
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 9)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Show this person in the People tab")

                    Button(isShowingReasoning ? "Hide Reasoning" : "Why?") {
                        isShowingReasoning.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("The match reasoning stored on this link")

                    Button("Unlink", action: onUnlink)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Remove the link to this person (⌘Z to undo)")
                }
                if isShowingReasoning {
                    storedReasoning(link)
                }
            }
        } else {
            Button(action: onResolve) {
                Label("Resolve…", systemImage: "link")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Link this mention to a concluded person")
        }
    }

    /// The **stored** match reasoning for a resolved mention — the breakdown as it was
    /// written, not as the matcher would score the pair today (slice 45e).
    ///
    /// This is what makes the triage pane's promise checkable. Confirming a suggestion
    /// stores the matcher's real dimension scores rather than rounding them up to 100
    /// (45c), and without a surface like this the app asserted that and then never showed
    /// it again — `genea match explain` was the only way to read a stored verdict.
    ///
    /// **Deliberately not re-scored.** A breakdown is a verdict at a time: the archive has
    /// changed since — a spouse relationship added, a name corrected — and re-deriving
    /// these numbers on every render would quietly answer a different question than the one
    /// the reviewer was asked. `matchScore(of:against:)` is the "what would it say now?"
    /// path, and comparing the two is an audit, not a display.
    ///
    /// A hand-made `link()` carries the honest minimum (`name: exact/100`, everything else
    /// unassessed), and that reads correctly here: `not assessed` on four rows is precisely
    /// the claim that no matcher ran.
    @ViewBuilder
    private func storedReasoning(_ link: EvidenceLink) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.verdictLine(link))
                .font(.caption2)
                .foregroundStyle(.secondary)
                // Wraps rather than truncating: the tail is where `matcher-proposed` lives,
                // which is the whole distinction this line exists to draw.
                .fixedSize(horizontal: false, vertical: true)
            MatchBreakdownView(breakdown: link.match)
            SourceWeightsRow(
                sourceAuthority: link.sourceAuthorityWeight,
                informationQuality: link.informationQualityWeight)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
        .padding(.top, 2)
    }

    /// "Confidence 91 · human-confirmed · by the matcher · 30 July 2026" — who decided, how
    /// sure the matcher was, and when. The CLI's `verdictLine` in the app's register.
    ///
    /// `provenance.createdBy` is the interesting half: it separates a link a **matcher
    /// proposed and a human accepted** from one a human made unaided, which is exactly the
    /// distinction the mixed record 45c writes exists to preserve.
    private static func verdictLine(_ link: EvidenceLink) -> String {
        var parts = ["Confidence \(link.aggregateConfidence)"]
        parts.append(link.reviewStatus.rawValue.replacingOccurrences(of: "-", with: " "))
        parts.append(
            link.provenance.createdBy == .machine ? "matcher-proposed" : "recorded by hand")
        if let reviewer = link.reviewedBy?.trimmedNonEmpty {
            parts.append("by \(reviewer)")
        }
        // The machine timestamp is ISO 8601 (never EDTF — that is for event dates), so the
        // date part alone is the readable half.
        if let at = link.reviewedAt?.trimmedNonEmpty {
            parts.append(String(at.prefix(10)))
        }
        return parts.joined(separator: " · ")
    }

    /// The chip text: the concluded person's display name, plus its primary date
    /// (EDTF-glossed) when present. Only reached for a link that resolves — a dangling
    /// one renders the missing-person state instead — so a nameless person here exists
    /// and reads "Unnamed person", matching the relationship rows.
    private var chipText: String {
        let name = resolvedPerson?.displayName ?? "Unnamed person"
        if let date = resolvedPerson?.primaryDate, let edtf = EDTFDate.parse(date) {
            return "\(name) · \(edtf.humanDescription)"
        }
        return name
    }

    /// "Subject · primary · age 45 · ru/Cyrl" — role always shown; quality omitted when
    /// undetermined (the default, so it's noise); age and the name's language/script only
    /// when present.
    private var subtitle: String? {
        var parts = [mention.role.displayName]
        if mention.informationQuality != .undetermined {
            parts.append(mention.informationQuality.displayName.lowercased())
        }
        if let age = mention.attributes?["ageAsRecorded"], !age.trimmed.isEmpty {
            parts.append("age \(age)")
        }
        if let tag = languageScriptTag(language: mention.nameLanguage, script: mention.nameScript) {
            parts.append(tag)
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Files

/// The artifact's attached files, with an "Attach File…" action that adds another
/// file to *this* artifact (attach-to-existing). Attached files get a default role
/// (slice 32) that's corrected afterward via each row's ⋯ ▸ Role menu. Creating a
/// new artifact instead is the toolbar `+` (Add Media); the two are distinct verbs
/// multiplexed over one importer via `ArchiveModel.ImportMode`.
private struct FilesSection: View {
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

// MARK: - Document file selector

/// A selectable chip in the document pane's file strip: a small icon, the file's
/// name, and its role badge. Highlighted while it's the file being previewed.
private struct FileChip: View {
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

/// A small capsule showing a file's role.
private struct RoleBadge: View {
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

// MARK: - Embedded metadata (suggestions)

/// Read-only "Embedded metadata (suggestions)" section, shown when EXIF/IPTC/GPS
/// data has been captured for this artifact's file this session — either at ingest
/// or on demand via a file row's **Scan for Metadata** (the cache is session-only).
///
/// Nothing here is written to `events`, `locations`, or any other genealogical
/// field automatically (ARCHITECTURE.md §6.4 — the "scan-date trap"). Each row
/// offers an explicit **Apply…** action that opens a human-confirmed sheet where
/// the user picks the target field and corrects the value before it's written.
private struct EmbeddedMetadataSection: View {
    let metadata: EmbeddedMetadata
    let onApply: (EmbeddedMetadataKeyValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Embedded Metadata (Suggestions)")
                .font(.headline)

            Text(
                "Read from the file's embedded metadata. Not applied to any date, place, or other field — review, then Apply only what you've verified."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(metadata.entries, id: \.key) { entry in
                    EmbeddedMetadataRow(entry: entry) { onApply(entry) }
                }
            }
        }
        .padding(.top, 8)
    }
}

/// A single `namespace:name` → value row, with an Apply action to promote it.
private struct EmbeddedMetadataRow: View {
    let entry: EmbeddedMetadataKeyValue
    let onApply: () -> Void

    var body: some View {
        GridRow {
            Text(entry.key.description)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(entry.value.displayString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Button("Apply…") { onApply() }
                .font(.caption)
                .buttonStyle(.link)
        }
    }
}

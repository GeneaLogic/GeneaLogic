import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

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
struct EditableArtifactFields: View {
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

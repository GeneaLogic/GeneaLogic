import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Adds one human-asserted `Event` or `Location` to an artifact.
///
/// Two ways in, both ending in the *same* write (`events.append` / `locations.append`
/// through `ArchiveModel.updateMetadata`, under the artifact's existing human/`asserted`
/// provenance):
///
/// - **From a suggestion** (`.suggestion`): the counterweight to the scan-date trap
///   (ARCHITECTURE.md §6.4). A captured embedded value is a *suggestion*, never
///   auto-applied — the human picks the target field (event or place) and
///   **corrects the value** (a 2026 scan date prefilled from EXIF stays 2026 until
///   the user changes it to the document's real date) before anything is written.
/// - **Blank** (`.blankEvent` / `.blankPlace`): manual entry for the common case where
///   the file carries no usable embedded metadata at all. Same write, just nothing
///   prefilled — this is how a date or place that isn't in the file's metadata gets
///   recorded.
///
/// Person *mentions* have their own editor (`PersonMentionEditorSheet`): a mention
/// carries more than a date/place (role, quality, name language/script, its own recorded
/// facts) and is independently editable, so it doesn't fit this sheet's add-only,
/// event-or-place shape.
struct AssertionEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifactID: ArtifactID
    let prefill: Prefill

    /// How the sheet was opened, and what (if anything) to prefill.
    enum Prefill {
        /// Promote a captured embedded-metadata value; the user picks event vs place.
        case suggestion(EmbeddedMetadataKeyValue)
        /// Add a fresh event from scratch.
        case blankEvent
        /// Add a fresh place from scratch.
        case blankPlace
    }

    /// Where the value will be written — event or place (EXIF/IPTC never suggests a
    /// person, and person mentions have their own editor).
    private enum Target: String, CaseIterable, Identifiable {
        case event = "Event"
        case place = "Place"
        var id: String { rawValue }
    }

    @State private var target: Target
    /// Event type — a free string in the model. From a suggestion it defaults to a
    /// *technical* type (the act of digitizing), never a life event, so an unedited
    /// apply can't masquerade as a birth/death; a manual add starts blank so the
    /// user states intent.
    @State private var eventType: String
    @State private var dateText: String
    /// The Event target's *optional* place.
    @State private var eventPlace: String
    /// The Place target's field.
    @State private var placeText: String

    init(artifactID: ArtifactID, prefill: Prefill) {
        self.artifactID = artifactID
        self.prefill = prefill
        switch prefill {
        case .suggestion(let entry):
            let raw = entry.value.displayString
            _target = State(initialValue: .event)
            _eventType = State(initialValue: "digitized")
            _dateText = State(initialValue: SuggestionNormalize.isoDate(from: raw) ?? raw)
            _eventPlace = State(initialValue: "")
            _placeText = State(initialValue: raw)
        case .blankEvent:
            _target = State(initialValue: .event)
            _eventType = State(initialValue: "")
            _dateText = State(initialValue: "")
            _eventPlace = State(initialValue: "")
            _placeText = State(initialValue: "")
        case .blankPlace:
            _target = State(initialValue: .place)
            _eventType = State(initialValue: "")
            _dateText = State(initialValue: "")
            _eventPlace = State(initialValue: "")
            _placeText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            // The suggestion path shows the captured value and lets the user route it
            // to an event or a place; a blank add already knows its target from the
            // button that opened it.
            if case .suggestion(let entry) = prefill {
                source(entry)
                Picker("Apply as", selection: $target) {
                    // Person is intentionally absent: an embedded-metadata value is a
                    // date or place, never a person, so a suggestion only routes here.
                    Text(Target.event.rawValue).tag(Target.event)
                    Text(Target.place.rawValue).tag(Target.place)
                }
                .pickerStyle(.segmented)
            }
            fields
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        // Resizable in width (the date/place fields benefit from room); height fits the
        // form. `.fitted` opts back into the pre-Sequoia resizable-sheet behavior — on
        // macOS 15+ sheets are fixed-size unless this is set — and the min/max frame
        // gives the drag a range (UI audit F5).
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.FormSheet.minWidth, idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch prefill {
        case .suggestion: return "Apply Suggestion"
        case .blankEvent: return "Add Event"
        case .blankPlace: return "Add Place"
        }
    }

    private var subtitle: String {
        switch prefill {
        case .suggestion:
            return
                "This captured value is a suggestion, not a verified fact — a file's embedded date is often when it was scanned, not when the document was made. Review and correct it before saving."
        case .blankEvent:
            return
                "Record an event this artifact documents — its type, date, and place. An artifact's Primary Date is the earliest of its event dates."
        case .blankPlace:
            return "Record a place this artifact references."
        }
    }

    private func source(_ entry: EmbeddedMetadataKeyValue) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("Captured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .gridColumnAlignment(.trailing)
                Text("\(entry.key.description)  =  \(entry.value.displayString)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch target {
        case .event:
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("Event Type") {
                    TextField(
                        "Event Type", text: $eventType,
                        prompt: Text("e.g. birth, marriage, created")
                    )
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 2) {
                    LabeledField("Date") {
                        TextField(
                            "Date", text: $dateText,
                            prompt: Text("e.g. 1920, 1920-05-12, about 1920, 1900/1905")
                        )
                        .labelsHidden()
                    }
                    EDTFDateGloss(dateText: dateText)
                }
                LabeledField("Place") {
                    TextField("Place", text: $eventPlace, prompt: Text("optional")).labelsHidden()
                }
            }
        case .place:
            VStack(alignment: .leading, spacing: 10) {
                LabeledField("Place") {
                    TextField("Place", text: $placeText, prompt: Text("place name as recorded"))
                        .labelsHidden()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add to Artifact") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
    }

    private var canApply: Bool {
        switch target {
        case .event: return !eventType.trimmed.isEmpty && !dateText.trimmed.isEmpty
        case .place: return !placeText.trimmed.isEmpty
        }
    }

    /// The record to append is built **here, on the main actor**, and the write closure
    /// only appends it. `updateMetadata`'s `edit` closure is `@escaping @Sendable` and
    /// runs off-main inside `mutate`'s work block (52), so reading `@State` from inside it
    /// is a real cross-actor read of fields the user can still be typing into — the same
    /// shape as `PersonMentionEditorSheet`'s snapshot, and fixed the same way (53 fork (b)).
    private func apply() {
        switch target {
        case .event:
            // Normalize common shorthand ("abt 1920" → "1920~") to canonical EDTF on the
            // way in, so the stored value parses/sorts/glosses like any other date.
            let date = dateText.trimmedNonEmpty.map(EDTFDate.normalizingShorthand)
            let event = Event(
                type: eventType.trimmed,
                date: date,
                location: eventPlace.trimmedNonEmpty)
            model.updateMetadata(of: artifactID, actionName: "Add Event") {
                $0.events.append(event)
            }
        case .place:
            let location = Location(asRecorded: placeText.trimmed)
            model.updateMetadata(of: artifactID, actionName: "Add Place") {
                $0.locations.append(location)
            }
        }
        dismiss()
    }
}

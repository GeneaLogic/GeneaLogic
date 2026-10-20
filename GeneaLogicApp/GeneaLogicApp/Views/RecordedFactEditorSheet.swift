import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Adds or edits one `RecordedFact` on an artifact's `PersonMention` — what a single
/// document records about a single person it names ("this register says he was born in
/// 1892 at Łomża"). This is the *evidence*-layer twin of `FactEditorSheet` (which edits a
/// concluded `Person`/`Relationship` fact): a `RecordedFact` is scoped to a mention, so a
/// multi-person record (a census household, a marriage register naming the couple *and*
/// both sets of parents) can finally say *whose* recorded birth is whose (§10.6).
///
/// The mention is addressed by its **`localRef`** (stable within the artifact, unlike an
/// array index), the fact by its value, starting at its index (79b). Every commit writes through
/// `ArchiveModel.updateMetadata`, so it's **undoable** (⌘Z) like any other evidence edit.
///
/// Type is restricted to ``FactType/recordedCases`` (person + couple facts, minus the
/// parent-child qualifiers, which describe a concluded *edge*, not an observation about
/// one named person). Date normalizes shorthand → canonical EDTF like every other date
/// field. The optional **Information Quality** is the per-*fact* GPS quality (§4.6): its
/// "Inherit from mention" default (a `nil` value) means "as good as the mention overall",
/// so a death certificate that's primary for the death and secondary for the birth it
/// mentions can say so per fact — see `RecordedFact.informationQuality`.
struct RecordedFactEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifactID: ArtifactID
    /// The mention this fact belongs to, addressed by its record-local `localRef`.
    let mentionRef: String
    /// The mention's name-as-recorded, shown in the heading so the user knows which
    /// person they're recording a fact about (they clicked "Add Fact" under one of
    /// several mentions).
    let mentionName: String
    let mode: Mode
    /// Called with the fact an edit wrote, so its row can take focus back (79b).
    let onSaved: ((RecordedFact) -> Void)?

    /// Add a new fact, or edit the one at `index` within the mention's `facts`.
    enum Mode {
        case add
        case edit(index: Int, existing: RecordedFact)
    }

    @State private var factType: FactType
    @State private var dateText: String
    @State private var placeText: String
    @State private var valueText: String
    /// The per-fact information-quality override; `nil` means **inherit the mention's**
    /// (the honest default — see `RecordedFact.informationQuality`), never "undetermined".
    @State private var quality: InformationQuality?

    init(
        artifactID: ArtifactID, mentionRef: String, mentionName: String, mode: Mode,
        onSaved: ((RecordedFact) -> Void)? = nil
    ) {
        self.artifactID = artifactID
        self.mentionRef = mentionRef
        self.mentionName = mentionName
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .add:
            _factType = State(initialValue: .birth)
            _dateText = State(initialValue: "")
            _placeText = State(initialValue: "")
            _valueText = State(initialValue: "")
            _quality = State(initialValue: nil)
        case .edit(_, let existing):
            _factType = State(initialValue: existing.type)
            _dateText = State(initialValue: existing.date ?? "")
            _placeText = State(initialValue: existing.place ?? "")
            _valueText = State(initialValue: existing.value ?? "")
            _quality = State(initialValue: existing.informationQuality)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            FactFormFields(
                factType: $factType, dateText: $dateText, placeText: $placeText,
                valueText: $valueText, typeOptions: typeOptions)
            qualityField
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        // Width-resizable, height fits the fields — matching the other form sheets (F5).
        .presentationSizing(.fitted)
        // Reserve height for the tallest layout up front: switching to a value-bearing or
        // custom type reveals the Value/Custom-Type rows, and `.fitted` won't regrow after
        // open, so without a floor those rows push the header/footer off the sheet (44i).
        .frame(
            minWidth: Layout.FormSheet.minWidth, idealWidth: Layout.FormSheet.idealWidth,
            maxWidth: Layout.FormSheet.maxWidth, minHeight: Layout.FormSheet.tallMinHeight)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(
                "What this document records about \(personPhrase) — evidence, not yet a concluded fact about them."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// "Add Recorded Fact — Marcus Hanner", so the heading names the mention the fact is
    /// being recorded under (the drop of a name-less mention degrades to no suffix).
    private var title: String {
        let verb = isEditing ? "Edit" : "Add"
        let name = mentionName.trimmed
        return name.isEmpty ? "\(verb) Recorded Fact" : "\(verb) Recorded Fact — \(name)"
    }

    /// The person named in the subtitle, or a neutral fallback when the mention has no
    /// recorded name.
    private var personPhrase: String {
        let name = mentionName.trimmed
        return name.isEmpty ? "this person" : name
    }

    private var qualityField: some View {
        LabeledField("Information Quality") {
            Picker("Information Quality", selection: $quality) {
                // `nil` = inherit the mention's overall quality (the default). Tagged as
                // an optional so the closed cases and "inherit" share one selection.
                Text("Inherit from mention").tag(InformationQuality?.none)
                ForEach(InformationQuality.allCases, id: \.self) { value in
                    Text(value.displayName).tag(InformationQuality?.some(value))
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(factType.rawValue.trimmed.isEmpty)
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    /// Recorded-fact types (person + couple, no parent-child qualifiers), plus the
    /// record's own type when editing so an off-list `.unknown(...)` authored elsewhere
    /// stays selectable (anchored on the *original* type, not the live selection).
    private var typeOptions: [FactType] {
        let anchor: FactType
        if case .edit(_, let existing) = mode { anchor = existing.type } else { anchor = .birth }
        return FactType.pickerOptions(from: FactType.recordedCases, including: anchor)
    }

    private func save() {
        let fact = RecordedFact(
            type: factType,
            date: dateText.trimmedNonEmpty.map(EDTFDate.normalizingShorthand),
            place: placeText.trimmedNonEmpty,
            value: valueText.trimmedNonEmpty,
            informationQuality: quality)
        let actionName = isEditing ? "Edit Recorded Fact" : "Add Recorded Fact"
        model.updateMetadata(of: artifactID, actionName: actionName) { record in
            // Address the mention by its stable `localRef`; the fact by value, starting
            // at its index. Both are found *inside* the closure, in the record the engine
            // loaded, since a captured index can go stale before the write commits (79b).
            guard
                let position = record.personsMentioned.firstIndex(where: {
                    $0.localRef == mentionRef
                })
            else { return }
            switch mode {
            case .add:
                record.personsMentioned[position].facts.append(fact)
            case .edit(let index, let existing):
                guard
                    let target = record.personsMentioned[position].facts.position(
                        of: existing, near: index)
                else { return }
                record.personsMentioned[position].facts[target] = fact
            }
        }
        if isEditing { onSaved?(fact) }
        dismiss()
    }
}

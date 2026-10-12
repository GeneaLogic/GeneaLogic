import GeneaLogicModel
import SwiftUI

/// The Type / Date / Place / Value fields shared by every fact editor. Today that's
/// `FactEditorSheet` (person facts *and* a couple `Relationship`'s marriage/divorce,
/// slice 43b) and `RecordedFactEditorSheet` (mention-scoped evidence facts); the form is
/// one component so the fields, prompts, and EDTF gloss never drift.
///
/// `typeOptions` is passed in already resolved (`FactType.pickerOptions(...)`), so the
/// caller decides the vocabulary — all `knownCases` for a person, just `coupleCases`
/// for a couple — while keeping any off-list `.unknown(...)` value already stored.
///
/// **Custom types (slice 44i):** `FactType` is an *open* vocabulary, so the picker
/// carries an **"Other…"** option that reveals a free-text field — a document can record
/// a fact type this build has never heard of (a "Manumission", a "Confirmation"), and it
/// is stored verbatim. Typed text folds to a known case case-insensitively
/// (`parsingLeniently`) so "birth" doesn't mint a twin beside `.birth`.
///
/// **Value (slice 44i):** a value-bearing fact (an occupation, a physical description)
/// carries its information in `value`, not a date or place; the Value field is always
/// shown (optional) since any fact type *may* carry one.
struct FactFormFields: View {
    @Binding var factType: FactType
    @Binding var dateText: String
    @Binding var placeText: String
    @Binding var valueText: String
    let typeOptions: [FactType]

    /// The picker's selection: a known/anchored `FactType`, or `nil` for the **"Other…"**
    /// free-text mode. Seeded from `factType` in `onAppear` (a stored off-list type that
    /// isn't among `typeOptions` starts in custom mode with its text prefilled).
    @State private var pickerSelection: FactType?
    @State private var customType: String = ""
    @State private var seeded = false

    /// Show the Value field for a value-bearing type — or whenever it already holds text,
    /// so a value is never hidden out from under the user (see the note at the field).
    private var showsValue: Bool {
        factType.isValueBearing || !valueText.trimmed.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledField("Type") {
                Picker("Type", selection: $pickerSelection) {
                    ForEach(typeOptions, id: \.self) {
                        Text($0.displayName).tag(FactType?.some($0))
                    }
                    Divider()
                    Text("Other…").tag(FactType?.none)
                }
                .labelsHidden()
                .fixedSize()
            }
            if pickerSelection == nil {
                LabeledField("Custom Type") {
                    TextField(
                        "Custom Type", text: $customType,
                        prompt: Text("as recorded, e.g. Manumission")
                    )
                    .labelsHidden()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                LabeledField("Date") {
                    TextField(
                        "Date", text: $dateText,
                        prompt: Text("e.g. 1892, about 1892, 1900/1905")
                    )
                    .labelsHidden()
                }
                EDTFDateGloss(dateText: dateText)
            }
            LabeledField("Place") {
                TextField("Place", text: $placeText, prompt: Text("optional"))
                    .labelsHidden()
            }
            // Value is shown only for types that conventionally carry one (occupation,
            // physical description, a custom type) — for a Birth/Marriage it's noise. But
            // never *hidden while it holds text*, so a value typed before switching type,
            // or one authored elsewhere, is always visible/editable rather than silently
            // stranded.
            if showsValue {
                LabeledField("Value") {
                    TextField(
                        "Value", text: $valueText,
                        prompt: Text("optional, e.g. tailor, brown hair")
                    )
                    .labelsHidden()
                }
            }
        }
        .onAppear {
            guard !seeded else { return }
            seeded = true
            // A stored type present in the options (a known case, or the off-list anchor
            // the caller kept) selects it; anything else starts in "Other…" mode with its
            // raw value prefilled so it's editable rather than silently reset.
            if typeOptions.contains(factType) {
                pickerSelection = factType
            } else {
                pickerSelection = nil
                customType = factType.rawValue
            }
        }
        .onChange(of: pickerSelection) { _, selection in
            factType = selection ?? FactType.parsingLeniently(customType)
        }
        .onChange(of: customType) { _, text in
            if pickerSelection == nil { factType = FactType.parsingLeniently(text) }
        }
    }
}

/// Builds a `PersonFact` from raw editor fields, normalizing date shorthand
/// ("abt 1892" → "1892~") to canonical EDTF so the stored value parses/sorts/glosses
/// like any other date, and folding empty strings to `nil`. Shared by both fact
/// editors; the editors don't touch evidence links, so the caller supplies
/// `supportedByLinks` (an edited fact's existing support carried through).
enum FactForm {
    static func build(
        type: FactType, date: String, place: String, value: String,
        supportedByLinks: [EvidenceLinkID]
    ) -> PersonFact {
        PersonFact(
            type: type,
            date: date.trimmedNonEmpty.map(EDTFDate.normalizingShorthand),
            place: place.trimmedNonEmpty,
            value: value.trimmedNonEmpty,
            supportedByLinks: supportedByLinks)
    }
}

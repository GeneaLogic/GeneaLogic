import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The "Other person…" partner picker for a couple fact (slice 43c). A couple fact
/// (marriage/divorce/annulment) rides a couple `Relationship` (§4.5), so recording one
/// needs a spouse. The `FactEditorSheet`'s "With" menu lists the subject's *existing*
/// couple partners; this sheet is how the user reaches **anyone else** — pick any
/// existing person as the spouse, or mint a brand-new one inline (given + surname).
///
/// It only *chooses* — it never writes. It hands back a `PartnerPick` the fact sheet
/// resolves into the right undoable path: reuse an existing couple relationship, create
/// one with an already-known person on save, or create the person + relationship + fact
/// together (one grouped ⌘Z).
///
/// The searchable list, sizing and footer are `PersonPickerSheet`'s; this sheet owns the
/// inline new-person form (its accessory).
struct CouplePartnerPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The person whose marriage this is — excluded from the list (you can't marry
    /// yourself) and the fixed end of the couple relationship the fact sheet builds.
    let subjectID: PersonID
    let onSelect: (PartnerPick) -> Void

    @State private var newGiven = ""
    @State private var newSurname = ""

    var body: some View {
        PersonPickerSheet(
            title: "Choose a Partner",
            prompt: "Pick who this marriage is with — an existing person, or a new one.",
            actionLabel: "Select",
            excluding: subjectID,
            emptyMessage: "No other people yet. Create a new spouse above.",
            accessory: { newPersonField },
            footerLeading: { EmptyView() }
        ) { personID in
            onSelect(.existing(personID))
            dismiss()
        }
    }

    /// The inline "create a brand-new spouse" mini-form. Either name field being
    /// non-empty is enough to mint a person (the same rule as the New Person sheet); the
    /// fact sheet then creates the person + couple relationship + fact in one grouped,
    /// undoable step.
    private var newPersonField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New person")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Given name", text: $newGiven)
                    .textFieldStyle(.roundedBorder)
                TextField("Surname", text: $newSurname)
                    .textFieldStyle(.roundedBorder)
                Button("Create & Use") {
                    onSelect(
                        .new(
                            given: newGiven.trimmedNonEmpty,
                            surname: newSurname.trimmedNonEmpty))
                    dismiss()
                }
                .disabled(!canCreateNew)
            }
        }
    }

    /// A new spouse needs at least one name part (given or surname), mirroring the New
    /// Person sheet's Create gate.
    private var canCreateNew: Bool {
        newGiven.trimmedNonEmpty != nil || newSurname.trimmedNonEmpty != nil
    }
}

/// What the partner picker hands back to `FactEditorSheet` (slice 43c): either an
/// existing person (the fact sheet reuses their couple relationship if one exists, else
/// creates it on save) or a brand-new spouse to mint inline.
enum PartnerPick {
    case existing(PersonID)
    case new(given: String?, surname: String?)
}

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Asserts a relationship between the subject person and another concluded person
/// (slice 43). The UI is **perspective-based** — the user picks whether the other
/// person is a **Parent**, **Child**, or **Partner** *of the subject* — so nobody has
/// to think in the model's `person1`/`person2` endpoints; the sheet maps the choice to
/// the §4.5 storage convention (parent-child: `person1` = parent, `person2` = child;
/// couple: symmetric). Writes a conclusion via `createRelationship`, undoable (⌘Z).
///
/// The searchable list, sizing and footer are `PersonPickerSheet`'s; this sheet owns the
/// perspective/nature pickers (its accessory) and the §4.5 mapping.
struct RelationshipEditorSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// The person whose detail pane opened this sheet — the relationship is asserted
    /// relative to them.
    let subjectID: PersonID
    let subjectName: String

    /// The other person's role relative to the subject.
    private enum RelationKind: String, CaseIterable, Identifiable {
        case parent, child, partner
        var id: String { rawValue }
        var label: String {
            switch self {
            case .parent: "Parent"
            case .child: "Child"
            case .partner: "Partner"
            }
        }
        /// The phrase completing "… is the subject's ___" for the picker caption.
        var relationPhrase: String {
            switch self {
            case .parent: "a parent of"
            case .child: "a child of"
            case .partner: "a partner of"
            }
        }
    }

    @State private var kind: RelationKind = .parent
    /// The nature of a parent-child link (slice 44f). `nil` is **Unspecified**, the
    /// default — not "biological": a nature the researcher hasn't established must
    /// not be asserted on their behalf. Irrelevant to a couple, so the control is
    /// hidden there.
    @State private var qualifier: FactType?

    var body: some View {
        PersonPickerSheet(
            title: "Add Relationship",
            prompt: "Record a family relationship for \(subjectName).",
            actionLabel: "Add",
            excluding: subjectID,
            emptyMessage: "No other people yet. Create another person first, "
                + "then relate them here.",
            accessory: {
                kindPicker
                if kind != .partner { naturePicker }
            },
            footerLeading: { EmptyView() },
            onSelect: relate
        )
    }

    private var kindPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("The other person is", selection: $kind) {
                ForEach(RelationKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("The person you pick below is \(kind.relationPhrase) \(subjectName).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Optional: an unqualified parent-child link reads as *unspecified*, which is the
    /// honest default for a link whose nature hasn't been researched.
    private var naturePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Nature", selection: $qualifier) {
                Text("Unspecified").tag(FactType?.none)
                ForEach(FactType.parentChildCases, id: \.self) { type in
                    Text(type.displayName).tag(FactType?.some(type))
                }
            }
            .fixedSize()
            Text("Leave as Unspecified until the nature of the link is established.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Maps the perspective choice to the stored `(type, person1, person2)` (§4.5) and
    /// asserts it.
    private func relate(to otherID: PersonID) {
        switch kind {
        case .partner:
            model.createRelationship(type: .couple, person1: subjectID, person2: otherID)
        case .parent:
            // The other person is the parent → they're person1, the subject is person2.
            model.createRelationship(
                type: .parentChild, person1: otherID, person2: subjectID, qualifier: qualifier)
        case .child:
            // The other person is the child → the subject is person1, they're person2.
            model.createRelationship(
                type: .parentChild, person1: subjectID, person2: otherID, qualifier: qualifier)
        }
        dismiss()
    }
}

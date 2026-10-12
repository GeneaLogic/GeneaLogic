//
//  ReplacePersonSheet.swift
//  GeneaLogicApp
//

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Repoints a relationship endpoint that dangles onto a deleted person (slice 44g).
/// A §2.3 removal doesn't cascade, so deleting a person leaves every relationship that
/// named them pointing at nothing; until now the only repair was deleting the
/// relationship outright, which throws away the half that is still true ("this person
/// has *a* parent") along with the half that isn't.
///
/// Existing people only — deliberately. The unnamed-new-person case is New Person on the
/// People tab, and quietly minting one here would make it easy to answer "who was this?"
/// with a second empty record rather than the person you meant. (That's the one thing
/// distinguishing it from `CouplePartnerPickerSheet`, which *does* offer inline create.)
///
/// It only *chooses*; the caller performs the undoable `replaceRelationshipEndpoint`.
struct ReplacePersonSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// The person whose detail view this is — excluded from the list, since they are
    /// already the *other* end of this relationship.
    let subjectID: PersonID
    /// How the missing person relates to the subject ("parent", "child", "partner"),
    /// for the prompt.
    let roleDescription: String
    let onSelect: (PersonID) -> Void

    var body: some View {
        PersonPickerSheet(
            title: "Replace Person",
            prompt: "This relationship names a person that was deleted. "
                + "Pick who the \(roleDescription) should be instead.",
            actionLabel: "Select",
            excluding: subjectID,
            emptyMessage: "No other people yet. Create another person first, "
                + "then use them here.",
            accessory: { EmptyView() },
            footerLeading: { EmptyView() }
        ) { personID in
            onSelect(personID)
            dismiss()
        }
    }
}

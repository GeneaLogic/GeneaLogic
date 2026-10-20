import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

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
struct PersonsMentionedSection: View {
    @Environment(ArchiveModel.self) private var model
    /// The record being read. A suggestion is archive-wide, so each suggestion row
    /// needs to know which of its citations is the one on screen.
    let artifactID: ArtifactID
    let persons: [PersonMention]
    /// The record's stated relationships (slice 45k). Held at the section rather than
    /// the row because an edge belongs to the *record*, not to either end of it; each
    /// row filters out the ones that touch it.
    let statedRelationships: [MentionRelationship]
    let links: [EvidenceLink]
    /// Relationships this record supports that `conclusions/` doesn't assert (slice 45l).
    let relationshipSuggestions: [RelationshipReviewItem]
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Persons Mentioned")
                    .font(.headline)
                Spacer()
                // A direct-action button (opens the assertion sheet) — no chevron,
                // unlike the menu-popping Events/Files affordances (F8).
                Button {
                    sheet = ArtifactSheet(.mention(.add))
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
                // `model.persons` is read here, by the section, so each row takes only
                // the one person it shows. Indexed once per body run rather than scanned
                // per mention.
                let personsByID = Dictionary(
                    model.persons.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
                VStack(alignment: .leading, spacing: 2) {
                    // Keyed by `localRef`, the mention's own identity, which an edit keeps
                    // (79b). The occurrence only matters if a record repeats a ref.
                    ForEach(persons.keyedRows(by: \.localRef)) { row in
                        let person = row.element
                        let link = links.first { $0.personMentionRef == person.localRef }
                        PersonMentionRow(
                            artifactID: artifactID,
                            index: row.index,
                            mention: person,
                            statedRelationships: statedRelationships,
                            allMentions: persons,
                            link: link,
                            resolvedPerson: link.flatMap { personsByID[$0.personUid] },
                            sheet: $sheet)
                    }
                }
                // A `localRef` is only unique within its record: the second mention is
                // `p2` on every artifact. Without this, selecting another artifact keeps
                // these row views, and a row's state (an expanded Why?) shows on that
                // artifact's mention in the same place (79b's hand-test).
                .id(artifactID)
            }
            SuggestedRelationships(artifactID: artifactID, items: relationshipSuggestions)
        }
        .padding(.top, 8)
    }
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
private struct SuggestedRelationships: View {
    let artifactID: ArtifactID
    let items: [RelationshipReviewItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested Relationships")
                    .font(.subheadline.weight(.semibold))
                ForEach(items) { item in
                    SuggestedRelationshipRow(
                        item: item,
                        // **This record's** basis, not the archive-wide `isStated` — a row
                        // here speaks for the document it sits on, and a suggestion another
                        // record states outright may only be *implied* by this one.
                        basis: item.basis(on: artifactID))
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
    @Environment(ArchiveModel.self) private var model
    let item: RelationshipReviewItem
    /// How **this** record supports the claim. `nil` only if the record dropped out of the
    /// evidence between the sweep and the render, in which case the row says nothing about
    /// a basis rather than guessing one.
    let basis: RelationshipBasis?

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
                // Both verbs bump `mutationVersion`, which reloads the coordinator's list,
                // so it re-derives from the engine rather than being patched here. One
                // owner of what is still owed — the same reason the inspector filters
                // the lane's answer instead of computing its own.
                HStack(spacing: 12) {
                    Button("Record") { model.confirmSuggestedRelationship(item) }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("Add this relationship to your conclusions (⌘Z to undo)")
                    Button("Not This") { model.dismissSuggestedRelationship(item) }
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

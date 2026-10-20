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

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Resolves a `PersonMention` (an artifact's "name as recorded") to a concluded
/// `Person`, creating an `EvidenceLink` — the evidence→conclusion bridge (slice 42).
/// Three paths: take a **matcher suggestion** (slice 45e, the accessory above the search
/// field), **link an existing** person picked by hand (the shared searchable list), or
/// **create a new** person seeded from the mention's recorded name and link in one step.
/// All are undoable (⌘Z) and write conclusions, never evidence (§2.3) — the mention itself
/// is untouched.
///
/// The suggestion path writes through `confirm` and the hand-picked path through `link()`,
/// which is not an inconsistency but the record staying honest about **which** happened:
/// `link()` stores a breakdown's honest minimum, and that is a claim that no matcher ran.
struct ResolveMentionSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let artifactID: ArtifactID
    let mention: PersonMention

    /// The dangling link this resolution replaces, or `nil` for a first-time resolve.
    /// When set, the picked/created person **takes over** the citation: the stale link
    /// is removed and the new one created in one grouped, undoable step (slice 44g).
    var replacing: EvidenceLinkID?

    /// The matcher's ranked candidates for this mention, loaded here rather than inside the
    /// accessory: the accessory renders nothing until they arrive, and a view that renders
    /// nothing never gets an `onAppear` to load them with. This sheet always renders.
    @State private var suggestions: [SuggestedLink] = []
    @State private var hasLoadedSuggestions = false

    var body: some View {
        PersonPickerSheet(
            title: replacing == nil ? "Resolve Mention" : "Re-resolve Mention",
            prompt: prompt,
            actionLabel: "Link",
            // Every person is a candidate: a document can name anyone.
            excluding: nil,
            emptyMessage: "No people yet. Create one from this mention below.",
            accessory: {
                MentionSuggestionsAccessory(candidates: suggestions) { suggestion in
                    // `confirm`, not `resolveMention`'s `link()` — the matcher produced
                    // this breakdown and the record has to store it (see the type note).
                    model.confirmSuggestion(suggestion)
                    dismiss()
                }
            },
            footerLeading: { createFromMentionButton }
        ) { personID in
            model.resolveMention(
                mention.localRef, in: artifactID, to: personID, replacing: replacing)
            dismiss()
        }
        .onAppear {
            guard !hasLoadedSuggestions else { return }
            hasLoadedSuggestions = true
            // Only on a first-time resolve. A **re-**resolve is the 44g repair path: the
            // mention's link points at a deleted person, and the question is which survivor
            // should inherit that citation — a judgement about the archive's damage, not
            // one the matcher's ranking speaks to.
            guard replacing == nil else { return }
            suggestions = model.suggestions(forMention: mention.localRef, in: artifactID)
        }
    }

    private var prompt: String {
        replacing == nil
            ? "Link “\(mention.nameAsRecorded)” (\(mention.role.displayName.lowercased())) "
                + "to a person in this archive."
            : "“\(mention.nameAsRecorded)” is linked to a person that was deleted. "
                + "Pick who this citation should point at instead."
    }

    /// The other resolution path: mint a person from the recorded name and link in one
    /// grouped, undoable step (`createPersonAndLink`).
    private var createFromMentionButton: some View {
        Button {
            model.createPersonAndLink(from: mention, in: artifactID, replacing: replacing)
            dismiss()
        } label: {
            Label(
                "Create new person from “\(mention.nameAsRecorded)” and link",
                systemImage: "person.fill.badge.plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }
}

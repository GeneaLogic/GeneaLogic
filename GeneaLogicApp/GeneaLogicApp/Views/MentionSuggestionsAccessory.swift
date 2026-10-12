import GeneaLogicArchive
// Named to read `ScoredMatch`'s members under `MemberImportVisibility` — see `ReviewItem`.
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// Ranked matcher suggestions inside the resolve-mention sheet — the **in-place** half of
/// slice 45e, beside the Review section's queue.
///
/// This is §6.3's inspector-primary direction and the spot a cataloguer is actually
/// standing in: a record has just been entered, its names need resolving, and the answer
/// is usually already in the archive. Making them walk to a separate queue for a question
/// the sheet in front of them can answer is the friction the matcher exists to remove.
///
/// **A suggestion row resolves through `confirm`, not `link()`.** They write different
/// records on purpose: `link()`'s honest minimum (`name: exact/100`, every other dimension
/// `nil`) is a claim that *nothing was computed*, which is true of a person picked out of
/// the search list below and false of one the matcher scored. Storing the real breakdown is
/// what keeps a confirmed suggestion distinguishable from a hand-made link (45c) — so the
/// two paths in this sheet deliberately do not share a write.
/// **Presentation only — the host owns the load.** It first held its own `@State` and
/// loaded in `.onAppear`, which never ran: the body was a `Group` that rendered nothing
/// until candidates arrived, an empty `Group` collapses to `EmptyView`, and a view that is
/// never in the hierarchy never appears. So the accessory sat permanently empty while the
/// matcher had a 91 to offer, with no error anywhere. Loading in the host — which always
/// renders — removes the cycle rather than papering over it with a zero-height spacer.
struct MentionSuggestionsAccessory: View {
    @Environment(ArchiveModel.self) private var model

    /// The ranked candidates for this mention, loaded by the host.
    let candidates: [SuggestedLink]
    /// Confirms a suggestion (and dismisses the host sheet).
    let onLink: (SuggestedLink) -> Void

    var body: some View {
        // Absent entirely when nothing scored above the floor, rather than showing an
        // empty box: the sheet is then exactly what it was before this slice. A mention
        // nothing matched is a *queue* concern, where the somebody-new path lives.
        if !candidates.isEmpty {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested")
                .font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(candidates, id: \.personID) { candidate in
                    SuggestionRow(
                        candidate: candidate,
                        person: model.persons.first { $0.uid == candidate.personID },
                        onLink: { onLink(candidate) })
                }
            }
        }
    }
}

/// One suggestion: the name, what agreed, and its confidence.
///
/// **The one-line reasoning, not the five-row breakdown.** An expander lived here briefly
/// and earned its removal: it made a cramped row carry two competing controls (its icon
/// button rendered as a filled accent box that read as the row's primary action, beside the
/// actual one), to show an accounting the Review section already draws properly. The
/// agreement line is still reasoning rather than an opaque score — "Name within · Spouse
/// name exact · Parents exact" is checkable against the document — and the full five rows
/// are one section away, on the surface built for reading them.
private struct SuggestionRow: View {
    let candidate: SuggestedLink
    let person: PersonSummary?
    let onLink: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(person?.displayName ?? candidate.personID.raw)
                    .font(.callout.weight(.medium))
                let agreement = candidate.match.breakdown.agreementLine
                if !agreement.isEmpty {
                    Text(agreement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text("\(candidate.match.aggregateConfidence)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Link", action: onLink)
                .controlSize(.small)
        }
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
    }
}

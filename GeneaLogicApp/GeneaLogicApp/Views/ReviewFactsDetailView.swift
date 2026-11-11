// `PersonSummary` is re-exported by `GeneaLogicArchive`; under `MemberImportVisibility`
// that makes the type nameable but not its members readable, so reading `uid` needs the
// defining module named here (the same note as `ReviewItem`).
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The Review section's second detail pane: one person, and everything their linked
/// sources record that hasn't been promoted into a fact yet (slice 45i).
///
/// Deliberately the **same rows, same actions** as `PersonDetailView`'s own Suggested Facts
/// section — this is a faster way to reach the work, not a different judgement about it.
/// Nothing is auto-applied here either (§2.3): Record affirms a fact as-recorded in one
/// click, Edit…/Apply… opens the editor prefilled, and either way the saved fact cites the
/// evidence link it came from.
///
/// The pane holds no state of its own. When a fact is recorded the sweep drops that
/// suggestion, and when the person's last suggestion goes the row leaves the sidebar and
/// the selection moves to the next row (`ReviewCommandHost`) — the same way a resolved
/// mention's does.
struct ReviewFactsDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let item: FactReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                suggestionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // A row's Edit… or Apply… opens its editor in `ReviewCommandHost`, with Review's
        // other sheets (slice 83b).
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.displayName)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(item.subtitle)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                // The person's own page is one click away, for the same reason the names
                // lane links its document: a judgement about what to record is made against
                // what is already recorded there.
                //
                // Styled as the Sources rows' jump is — accent colour + `arrow.up.right` —
                // rather than `.buttonStyle(.link)`, which inherits the surrounding
                // `.secondary` and renders a navigation affordance as grey caption text.
                Button {
                    model.navigateToPerson(item.person.uid)
                } label: {
                    HStack(spacing: 4) {
                        Text("Open in People")
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this person on the People tab")
            }
            .font(.callout)
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested Facts")
                .font(.headline)
            Text(
                "Evidence from linked sources. Review and confirm before recording — "
                    + "a source's records aren't automatically about this person."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(item.suggestions) { suggestion in
                    FactSuggestionRow(
                        suggestion: suggestion, person: item.person.uid,
                        keyCaption: keyCaption(for: suggestion))
                }
            }
        }
    }

    /// ⌘↩ acts on the top suggestion, and opens its editor if it can only be applied.
    private func keyCaption(for suggestion: FactSuggestion) -> String? {
        guard suggestion.id == item.suggestions.first?.id else { return nil }
        return ArchiveCommand.reviewKeyCaption(
            for: item.target.lane,
            acceptTitle: suggestion.isDirectlyRecordable ? nil : "Apply…")
    }
}

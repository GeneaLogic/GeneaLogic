import GeneaLogicModel
import SwiftUI

/// One Suggested-Facts row: a piece of promotable evidence from a linked source (a
/// recorded fact or a recorded age). A directly-recordable suggestion offers a one-click
/// **Record** (affirm as-recorded — slice 44i) beside **Edit…** (open the editor to
/// correct first); a couple fact or an age offers only **Apply…**, since those need the
/// sheet (a spouse, or deriving a year). Either way it's a human-confirmed promotion,
/// never an auto-applied fact (§2.3) — the conclusion-layer analog of the artifact
/// inspector's embedded-metadata suggestion rows.
///
/// Shared by the two surfaces that show suggestions (slice 45i): a person's own detail
/// pane, and the Review section's cross-person lane. One row means one thing in both:
/// its verbs are the row's commands (slice 83b), and the pane that drew it opens the
/// editor.
struct FactSuggestionRow: View {
    let suggestion: FactSuggestion
    /// The person the suggestion would be recorded on.
    let person: PersonID
    /// The keys that act on this row, on Review's top suggestion (slice 83).
    var keyCaption: String?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(suggestion.evidenceLine)
                    .fontWeight(.medium)
                if let title = suggestion.artifactTitle {
                    Text("from \(title)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let keyCaption {
                    ReviewKeyCaption(keyCaption)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                // Record when the fact can be affirmed as-recorded; then Edit… is the
                // correct-first path, and Apply… when the sheet is the only way (a couple
                // fact, an age).
                RowCommandButton(.recordSuggestedFact, on: subject, showsSymbol: true)
                RowCommandButton(
                    .editSuggestedFact, on: subject,
                    emphasis: suggestion.isDirectlyRecordable ? .secondary : .primary,
                    showsSymbol: true)
            }
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
        .rowCommandMenu(subject)
    }

    private var subject: CommandSubject {
        .factSuggestion(
            FactSuggestionTarget(
                person: person, id: suggestion.id,
                isDirectlyRecordable: suggestion.isDirectlyRecordable))
    }
}

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
/// pane, and the Review section's cross-person lane. One row means one thing in both.
struct FactSuggestionRow: View {
    let suggestion: FactSuggestion
    /// Record the un-edited fact in one click (only shown when `isDirectlyRecordable`).
    let onRecord: () -> Void
    /// Open the editor prefilled from the evidence to correct it before recording.
    let onApply: () -> Void

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
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) {
                if suggestion.isDirectlyRecordable {
                    Button(action: onRecord) {
                        Label("Record", systemImage: "checkmark.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("Record this fact as-recorded (⌘Z to undo)")
                }
                // "Edit…" when a one-click Record is also offered (it's the correct-first
                // path); "Apply…" when the sheet is the only way (couple fact / age).
                Button(action: onApply) {
                    Label(
                        suggestion.isDirectlyRecordable ? "Edit…" : "Apply…",
                        systemImage: suggestion.isDirectlyRecordable
                            ? "square.and.pencil" : "arrow.down.doc"
                    )
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    suggestion.isDirectlyRecordable ? Color.secondary : Color.accentColor
                )
                .help("Correct this evidence before recording it")
            }
        }
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }
}

import SwiftUI

/// The caption on the row Review's keys act on (slice 83, fork 3): "⌘↩ Confirm · ⌘⌫
/// Reject". This, not a prominent button, says where the keys land. The text is
/// `ArchiveCommand.reviewKeyCaption`; this is the one way it is drawn.
struct ReviewKeyCaption: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    /// The keys `lane` has, under their pane titles.
    init(for lane: ReviewLane, acceptTitle: String? = nil) {
        self.init(ArchiveCommand.reviewKeyCaption(for: lane, acceptTitle: acceptTitle))
    }

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The artifact's inline transcript, shown read-only with an "Edit Transcript"
/// action that opens the full-height editor sheet. A `role: .transcript` *file*
/// (long transcripts) is shown separately in the Files list, not here.
struct TranscriptSection: View {
    let transcript: String?
    @Binding var sheet: ArtifactSheet?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Transcript")
                    .font(.headline)
                Spacer()
                Button {
                    sheet = ArtifactSheet(.transcript)
                } label: {
                    AddAffordanceLabel(
                        title: hasText ? "Edit Transcript…" : "Add Transcript…",
                        systemImage: "text.quote")
                }
                .buttonStyle(.plain)
            }

            if let transcript, hasText {
                Text(transcript)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: Layout.readableTextMaxWidth, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No transcript. Use Add Transcript… to type one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
    }

    private var hasText: Bool {
        !(transcript?.trimmed.isEmpty ?? true)
    }
}

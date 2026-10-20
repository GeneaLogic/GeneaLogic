import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The artifact's internal identifiers (UID + package slug), shown small and
/// de-emphasized at the bottom of the detail. Not edited; copyable for support.
struct IdentifiersSection: View {
    let uid: String
    let slug: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Identifiers")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                IdentifierRow(label: "UID", value: uid)
                IdentifierRow(label: "Slug", value: slug)
            }
        }
        .padding(.top, 8)
    }

    private struct IdentifierRow: View {
        let label: String
        let value: String

        var body: some View {
            GridRow {
                Text(label)
                    .gridColumnAlignment(.trailing)
                Text(value)
                    .textSelection(.enabled)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
    }
}

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// A full-row selectable person, shared by the sheets that pick a concluded person from
/// a list: the resolve-mention sheet (slice 42) and the relationship editor (slice 43).
/// Shows the display name over its browse subtitle (primary date · fact count) with a
/// trailing accent action label; the whole row is one `.plain` button so it's clickable
/// edge to edge, with the standard hover chrome.
struct PersonPickRow: View {
    let person: PersonSummary
    /// The trailing call-to-action, e.g. "Link" (resolve) or "Add" (relationship).
    let actionLabel: String
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(person.displayName ?? "Unnamed person")
                        .fontWeight(.medium)
                    Text(person.browseSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(actionLabel)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverRowBackground(isHovering: isHovering)
        .onHover { isHovering = $0 }
    }
}

/// The rounded, magnifying-glass "Search people" field shared by the person-picker
/// sheets. A thin wrapper over a plain `TextField` so both sheets present it identically.
struct PersonSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search people", text: $text, prompt: Text("Search people"))
                .textFieldStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .overlay(
            RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                .stroke(.separator, lineWidth: 0.5)
        )
    }
}

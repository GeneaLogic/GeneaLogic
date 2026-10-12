import SwiftUI

/// Toolbar menu that filters the browse list by tag (the structured
/// `ArtifactQuery.tags` facet, kept separate from free-text search exactly for
/// this — ARCHITECTURE.md §5.1).
///
/// Each tag in the open archive is a toggle showing how many artifacts carry it;
/// selected tags AND-combine with each other and with the search field (the
/// engine applies both in one `ArtifactQuery`). The label gains a count and a
/// filled icon while a filter is active, and a **Clear Filters** item resets the
/// tag selection (leaving the text search untouched). With no tags anywhere in
/// the archive the menu is disabled.
struct TagFilterMenu: View {
    @Environment(ArchiveModel.self) private var model

    var body: some View {
        let facets = model.tagFacets
        let activeCount = model.selectedTags.count
        Menu {
            ForEach(facets) { facet in
                Toggle(isOn: binding(for: facet.key)) {
                    Text("\(facet.display)  (\(facet.count))")
                }
            }
            if activeCount > 0 {
                Divider()
                Button("Clear Filters") { model.clearTagFilter() }
            }
        } label: {
            Label(labelTitle(activeCount: activeCount), systemImage: icon(activeCount: activeCount))
        }
        // Show the active-filter count next to the icon (a toolbar menu otherwise
        // collapses its label to icon-only). With no filter active it reads
        // "Filter"; one or more selected tags read "Filter (N)".
        .labelStyle(.titleAndIcon)
        .menuIndicator(.hidden)
        .disabled(facets.isEmpty)
        .help("Filter artifacts by tag")
    }

    /// A two-way binding over one tag's membership in the selection, so a `Toggle`
    /// can drive `toggleTag` (which also re-runs the filter).
    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedTags.contains(key) },
            set: { _ in model.toggleTag(key) })
    }

    private func labelTitle(activeCount: Int) -> String {
        activeCount > 0 ? "Filter (\(activeCount))" : "Filter"
    }

    private func icon(activeCount: Int) -> String {
        activeCount > 0
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle"
    }
}

import SwiftUI

/// The Artifacts header's Filter menu (slice 84): the uncatalogued filter, then the
/// archive's tags.
///
/// Each tag is a toggle showing how many artifacts carry it; selected tags AND-combine
/// with each other and with the search field (the engine applies both in one
/// `ArtifactQuery`, ARCHITECTURE.md §5.1). **Uncatalogued Only** narrows the list to the
/// artifacts with no source tier, for a cataloguing pass; it is offered only while
/// there are some. The icon fills while any filter is on, and Clear Filters resets them
/// all, leaving the search alone.
struct ArtifactFilterMenu: View {
    @Environment(ArchiveModel.self) private var model
    @Binding var uncataloguedOnly: Bool
    /// The uncatalogued artifacts among the search's results.
    let uncataloguedCount: Int

    var body: some View {
        let facets = model.tagFacets
        let isActive = !model.selectedTags.isEmpty || uncataloguedOnly
        Menu {
            if uncataloguedCount > 0 || uncataloguedOnly {
                Toggle(isOn: $uncataloguedOnly) {
                    Text("Uncatalogued Only  (\(uncataloguedCount))")
                }
                .help("Artifacts whose source has not been characterised yet.")
            }
            if !facets.isEmpty {
                Section("Tags") {
                    ForEach(facets) { facet in
                        Toggle(isOn: binding(for: facet.key)) {
                            Text("\(facet.display)  (\(facet.count))")
                        }
                    }
                }
            }
            if isActive {
                Divider()
                Button("Clear Filters") {
                    uncataloguedOnly = false
                    model.clearTagFilter()
                }
            }
        } label: {
            Image(
                systemName: isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(facets.isEmpty && uncataloguedCount == 0 && !uncataloguedOnly)
        .help("Filter artifacts")
        .accessibilityLabel("Filter")
    }

    /// A two-way binding over one tag's membership in the selection, so a `Toggle` can
    /// drive `toggleTag` (which also re-runs the filter).
    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedTags.contains(key) },
            set: { _ in model.toggleTag(key) })
    }
}

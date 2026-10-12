import SwiftUI

/// The sidebar's list-scoping control cluster: **Filter** (by tag) and **Sort**,
/// pinned just under the `.searchable` field at the top of the browse list. This
/// co-locates the controls that narrow/order the **same** list (UI audit F14) —
/// previously the tag filter lived in the *trailing* toolbar, across the window
/// from the search field it AND-combines with. The trailing toolbar is left for
/// object/view actions (the `+`).
///
/// Hosted via `.safeAreaInset(edge: .top)`, so it stays pinned and doesn't scroll
/// with the list. The caller hides it when the archive has no artifacts.
struct ListControlsBar: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TagFilterMenu()
                Spacer()
                SortMenu()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
        }
        .background(.bar)
    }
}

/// Sidebar menu that orders the browse list (UI audit F7). An inline `Picker`
/// chooses the sort field (title / date added / primary date) and a second inline
/// `Picker` the direction, with labels phrased per field ("A to Z", "Newest
/// First", …). Sorting is client-side over the loaded summaries — no engine query.
struct SortMenu: View {
    @Environment(ArchiveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            SortPickers(key: $model.sortKey, ascending: $model.sortAscending)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .labelStyle(.titleAndIcon)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort artifacts")
    }
}

/// The two inline sort pickers — field then direction — shared by the sidebar
/// `SortMenu` and the View ▸ Sort By menu, so the sort UI has a single definition
/// (its labels have been retuned across several slices). Direction labels are
/// phrased for the currently chosen key.
struct SortPickers: View {
    @Binding var key: ArchiveModel.ArtifactSortKey
    @Binding var ascending: Bool

    var body: some View {
        Picker("Sort By", selection: $key) {
            ForEach(ArchiveModel.ArtifactSortKey.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.inline)
        Divider()
        Picker("Order", selection: $ascending) {
            Text(key.ascendingLabel).tag(true)
            Text(key.descendingLabel).tag(false)
        }
        .pickerStyle(.inline)
    }
}

import SwiftUI

/// The Artifacts header's Sort menu (UI audit F7; in the header since slice 84). An
/// inline `Picker` chooses the sort field (title / date added / primary date) and a
/// second inline `Picker` the direction, with labels phrased per field ("A to Z",
/// "Newest First", …). Sorting is client-side over the loaded summaries — no engine query.
struct SortMenu: View {
    @Environment(ArchiveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Menu {
            SortPickers(key: $model.sortKey, ascending: $model.sortAscending)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort artifacts")
        .accessibilityLabel("Sort")
    }
}

/// The two inline sort pickers — field then direction — shared by the header's
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

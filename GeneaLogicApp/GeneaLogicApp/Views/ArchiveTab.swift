import Foundation

/// The four top-level sections of an open archive: the evidence layer
/// (**Artifacts**), the concluded identities (**People**), the derived **Tree**, and
/// the matcher's triage queue (**Review**, slice 45e).
/// Switched by a segmented `Picker` in the toolbar's `.principal` slot (see
/// `OpenArchiveView`) — *not* a window-level `TabView`, which would displace the
/// `NavigationSplitView`'s title/toggle/search. The active section is persisted per
/// window via `@SceneStorage` and mirrored into the model (`activeTab`) so the menu
/// bar can scope its artifact commands to the Artifacts section.
///
/// **Review is a section, not a sheet** (45e fork (a)): triage is a place you come back
/// to and work through, and the two sheet precedents (`TrashSheet`,
/// `IntegrityReportSheet`) are both one-shot *reports*. A modal queue would also block
/// reading the artifact while deciding, which is the act itself.
enum ArchiveTab: String, CaseIterable, Identifiable {
    case artifacts
    case people
    case tree
    case review

    var id: String { rawValue }

    var label: String {
        switch self {
        case .artifacts: "Artifacts"
        case .people: "People"
        case .tree: "Tree"
        case .review: "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .artifacts: "doc.on.doc"
        case .people: "person.2"
        case .tree: "point.3.connected.trianglepath.dotted"
        case .review: "tray.full"
        }
    }
}

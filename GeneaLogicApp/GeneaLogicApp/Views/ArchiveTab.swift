import Foundation

/// What an open archive's window is showing: the evidence layer (**Artifacts**), the
/// concluded identities (**People**) as a list or as a **Tree**, or the matcher's triage
/// queue (**Review**, slice 45e).
///
/// Since slice 84 the area is set by selecting in the sidebar (`SidebarSelection`), and
/// Tree is People's second view (`section`), switched by a List | Tree control in the
/// toolbar; ⌘1–⌘4 still name all four. Persisted with the archive's window state (`WindowState`) and
/// mirrored into the model (`activeTab`) so the menu bar can scope its commands by area.
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

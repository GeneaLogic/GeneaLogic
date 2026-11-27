import Foundation

/// What an open archive's window is showing: the evidence layer (**Artifacts**), the
/// concluded identities (**People**) as a list or as a **Tree**, the matcher's triage
/// queue (**Review**, slice 45e), or the archive's **Trash** (slice 86).
///
/// Since slice 84 the area is set by selecting in the sidebar (`SidebarSelection`), and
/// Tree is People's second view (`section`), switched by a List | Tree control in the
/// toolbar; ⌘1–⌘4 still name all four. Persisted with the archive's window state
/// (`WindowState`) and mirrored into the model (`activeTab`) so the menu bar can scope its commands by area.
///
/// **Review is a section, not a sheet** (45e fork (a)): triage is a place you come back
/// to and work through, and a sheet is a one-shot *report* (`IntegrityReportSheet`). A
/// modal queue would also block reading the artifact while deciding, which is the act
/// itself. The trash was a sheet too until slice 86, and was easy to forget for it.
///
/// **Trash has no ⌘-number** (86, fork 1): Finder's and Notes' have none. File ▸ Show
/// Trash goes there, and `numbered` is the View menu's list.
enum ArchiveTab: String, CaseIterable, Identifiable {
    case artifacts
    case people
    case tree
    case review
    case trash

    /// The areas View ▸ ⌘1–⌘4 name, in that order.
    static let numbered: [ArchiveTab] = [.artifacts, .people, .tree, .review]

    /// The area a stored raw value names, or Artifacts for one this build doesn't know:
    /// a window state written by a later build, with an area this one lacks, restores
    /// what it can rather than failing (slice 85's lenient decoding, 86's Trash).
    init(stored raw: String) {
        self = ArchiveTab(rawValue: raw) ?? .artifacts
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .artifacts: "Artifacts"
        case .people: "People"
        case .tree: "Tree"
        case .review: "Review"
        case .trash: "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .artifacts: "doc.on.doc"
        case .people: "person.2"
        case .tree: "point.3.connected.trianglepath.dotted"
        case .review: "tray.full"
        case .trash: "trash"
        }
    }
}

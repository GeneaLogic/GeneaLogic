import Foundation

/// How an archive's window was left: what reopening it restores (slice 85, G10).
///
/// **On this Mac, not in the archive.** Per-user UI state inside the package would sync
/// between machines and sit beside the authored files. It is stored in
/// `ArchiveBookmarks`, keyed by the archive's file identity, so a moved or renamed
/// archive keeps it and a Finder copy starts fresh.
///
/// Every field decodes leniently: a field this build doesn't know is ignored, and one
/// it expects but doesn't find takes its default. A record from another build still
/// restores what it can, instead of failing whole.
struct WindowState: Codable, Equatable, Sendable {
    /// Names this record's window frame in AppKit's frame autosave. Minted with the
    /// record and kept across a re-key, so a moved archive keeps its frame too.
    var id = UUID()
    /// The area (`ArchiveTab`'s raw value).
    var tab = ArchiveTab.artifacts.rawValue
    /// The three selections, as raw ids. Empty means none.
    var selectedArtifactID = ""
    var selectedPersonID = ""
    var selectedReviewItemID = ""
    /// Whether People was last shown as a tree (slice 84).
    var peopleShowsTree = false
    var sidebarHidden = false
    var sidebarWidth = Double(Layout.ArchiveWindow.sidebarIdealWidth)
    var reviewExpanded = true
    var artifactsExpanded = true
    var peopleExpanded = true
    var treeAncestorDepth = 3
    var treeDescendantDepth = 3
    var inspectorShown = true
    var inspectorWidth = Layout.ArchiveWindow.inspectorIdealWidth

    /// The frame autosave name for this record's window.
    var frameAutosaveName: String { "GeneaLogic Archive \(id.uuidString)" }

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowState()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        id = value(.id, d.id)
        tab = value(.tab, d.tab)
        selectedArtifactID = value(.selectedArtifactID, d.selectedArtifactID)
        selectedPersonID = value(.selectedPersonID, d.selectedPersonID)
        selectedReviewItemID = value(.selectedReviewItemID, d.selectedReviewItemID)
        peopleShowsTree = value(.peopleShowsTree, d.peopleShowsTree)
        sidebarHidden = value(.sidebarHidden, d.sidebarHidden)
        sidebarWidth = value(.sidebarWidth, d.sidebarWidth)
        reviewExpanded = value(.reviewExpanded, d.reviewExpanded)
        artifactsExpanded = value(.artifactsExpanded, d.artifactsExpanded)
        peopleExpanded = value(.peopleExpanded, d.peopleExpanded)
        treeAncestorDepth = value(.treeAncestorDepth, d.treeAncestorDepth)
        treeDescendantDepth = value(.treeDescendantDepth, d.treeDescendantDepth)
        inspectorShown = value(.inspectorShown, d.inspectorShown)
        inspectorWidth = value(.inspectorWidth, d.inspectorWidth)
    }
}

/// One archive window's `WindowState`, observed by the views that show it and written
/// back to `ArchiveBookmarks` on every change, so a crash loses nothing (slice 85).
///
/// It replaces `@SceneStorage`, which only a relaunch restored: relaunch and reopen
/// now read the same record. Two windows never show one archive (slice 31), so two
/// windows never write one record.
///
/// **Loaded once the window owns its archive** (`load()`, from the container's `.task`
/// after `claimWindow` and the model's `load()`), not in `init`: SwiftUI re-runs a
/// view's `init` on every parent render, and reading the archive's identity needs the
/// access the model's `load()` ensures. Until then it holds the defaults and writes
/// nothing, so a duplicate window that dismisses itself never touches the record.
@MainActor
@Observable
final class ArchiveWindowState {
    var values = WindowState() {
        didSet { if isLoaded, values != oldValue { bookmarks.setWindowState(values, for: url) } }
    }

    /// Whether `load()` has run. The frame autosave waits for it, so it never attaches
    /// under a name that is about to change.
    private(set) var isLoaded = false

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let bookmarks: ArchiveBookmarks

    init(url: URL, bookmarks: ArchiveBookmarks = .shared) {
        self.url = url
        self.bookmarks = bookmarks
    }

    /// Reads the archive's record, or starts one. A new record is written at once, so
    /// its frame autosave name survives a close before anything else changes.
    func load() {
        guard !isLoaded else { return }
        if let stored = bookmarks.windowState(for: url) {
            values = stored
        } else {
            bookmarks.setWindowState(values, for: url)
        }
        isLoaded = true
    }
}

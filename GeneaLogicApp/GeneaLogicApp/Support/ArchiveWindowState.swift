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
    /// The window's frame, as AppKit describes it (`NSWindow.frameDescriptor`: the frame
    /// and the screen it was on), or `nil` for a window never moved or resized. Kept here
    /// rather than in AppKit's frame autosave, which SwiftUI's windows don't honour: they
    /// keep a frame autosave name of SwiftUI's own (found in 85's hand-test).
    var frame: String?

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WindowState()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
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
        frame = value(.frame, d.frame)
    }
}

/// One archive window's `WindowState`, observed by the views that show it and written
/// back to `ArchiveBookmarks` on every change, so a crash loses nothing (slice 85).
///
/// It replaces `@SceneStorage`, which only a relaunch restored: relaunch and reopen
/// now read the same record. Two windows never show one archive (slice 31), so two
/// windows never write one record.
///
/// **One observed property per field**, as `@SceneStorage` kept one key per field, so a
/// view re-renders only for the fields it reads: a selection step doesn't invalidate
/// the tree or the inspector.
///
/// **Loaded once the window has opened its archive** (`load()`, from the container's
/// `.task`, after `claimWindow` and a successful `ArchiveModel.load()`), not in `init`:
/// SwiftUI re-runs a view's `init` on every parent render, and reading the archive's
/// identity needs the access the model's `load()` ensures. Until then it holds the
/// defaults and writes nothing, so neither a duplicate window that dismisses itself nor
/// one whose archive couldn't be opened touches any record.
///
/// **The identity is read once, at load**, and every write goes to it. The window's URL
/// is fixed when it opens, so an archive renamed or moved while open would otherwise
/// have its later writes land under a different key.
@MainActor
@Observable
final class ArchiveWindowState {
    var tab: String = WindowState().tab {
        didSet { if tab != oldValue { persist() } }
    }
    var selectedArtifactID: String = WindowState().selectedArtifactID {
        didSet { if selectedArtifactID != oldValue { persist() } }
    }
    var selectedPersonID: String = WindowState().selectedPersonID {
        didSet { if selectedPersonID != oldValue { persist() } }
    }
    var selectedReviewItemID: String = WindowState().selectedReviewItemID {
        didSet { if selectedReviewItemID != oldValue { persist() } }
    }
    var peopleShowsTree: Bool = WindowState().peopleShowsTree {
        didSet { if peopleShowsTree != oldValue { persist() } }
    }
    var sidebarHidden: Bool = WindowState().sidebarHidden {
        didSet { if sidebarHidden != oldValue { persist() } }
    }
    var sidebarWidth: Double = WindowState().sidebarWidth {
        didSet { if sidebarWidth != oldValue { persist() } }
    }
    var reviewExpanded: Bool = WindowState().reviewExpanded {
        didSet { if reviewExpanded != oldValue { persist() } }
    }
    var artifactsExpanded: Bool = WindowState().artifactsExpanded {
        didSet { if artifactsExpanded != oldValue { persist() } }
    }
    var peopleExpanded: Bool = WindowState().peopleExpanded {
        didSet { if peopleExpanded != oldValue { persist() } }
    }
    var treeAncestorDepth: Int = WindowState().treeAncestorDepth {
        didSet { if treeAncestorDepth != oldValue { persist() } }
    }
    var treeDescendantDepth: Int = WindowState().treeDescendantDepth {
        didSet { if treeDescendantDepth != oldValue { persist() } }
    }
    var inspectorShown: Bool = WindowState().inspectorShown {
        didSet { if inspectorShown != oldValue { persist() } }
    }
    var inspectorWidth: Double = WindowState().inspectorWidth {
        didSet { if inspectorWidth != oldValue { persist() } }
    }
    /// Written by `WindowFrameKeeper` and read by it when the window opens; no view's
    /// body reads it, so a move re-renders nothing.
    @ObservationIgnored var frame: String? = nil {
        didSet { if frame != oldValue { persist() } }
    }

    /// Whether `load()` has run. The frame keeper waits for it, so it applies the record's
    /// frame and never saves into the defaults.
    private(set) var isLoaded = false

    @ObservationIgnored private var identity: String?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let bookmarks: ArchiveBookmarks

    init(url: URL, bookmarks: ArchiveBookmarks = .shared) {
        self.url = url
        self.bookmarks = bookmarks
    }

    /// Reads the archive's record, or starts one, and writes it back at once: a new
    /// record exists from the first open, and an existing one counts as just opened (the
    /// store keeps the most recently opened).
    func load() {
        guard !isLoaded else { return }
        let identity = ArchiveBookmarks.identity(of: url)
        self.identity = identity
        if let stored = bookmarks.windowState(forIdentity: identity) {
            apply(stored)
        }
        isLoaded = true
        persist()
    }

    /// The fields as one record.
    var snapshot: WindowState {
        var state = WindowState()
        state.tab = tab
        state.selectedArtifactID = selectedArtifactID
        state.selectedPersonID = selectedPersonID
        state.selectedReviewItemID = selectedReviewItemID
        state.peopleShowsTree = peopleShowsTree
        state.sidebarHidden = sidebarHidden
        state.sidebarWidth = sidebarWidth
        state.reviewExpanded = reviewExpanded
        state.artifactsExpanded = artifactsExpanded
        state.peopleExpanded = peopleExpanded
        state.treeAncestorDepth = treeAncestorDepth
        state.treeDescendantDepth = treeDescendantDepth
        state.inspectorShown = inspectorShown
        state.inspectorWidth = inspectorWidth
        state.frame = frame
        return state
    }

    private func apply(_ state: WindowState) {
        tab = state.tab
        selectedArtifactID = state.selectedArtifactID
        selectedPersonID = state.selectedPersonID
        selectedReviewItemID = state.selectedReviewItemID
        peopleShowsTree = state.peopleShowsTree
        sidebarHidden = state.sidebarHidden
        sidebarWidth = state.sidebarWidth
        reviewExpanded = state.reviewExpanded
        artifactsExpanded = state.artifactsExpanded
        peopleExpanded = state.peopleExpanded
        treeAncestorDepth = state.treeAncestorDepth
        treeDescendantDepth = state.treeDescendantDepth
        inspectorShown = state.inspectorShown
        inspectorWidth = state.inspectorWidth
        frame = state.frame
    }

    private func persist() {
        guard isLoaded, let identity else { return }
        bookmarks.setWindowState(snapshot, forIdentity: identity)
    }
}

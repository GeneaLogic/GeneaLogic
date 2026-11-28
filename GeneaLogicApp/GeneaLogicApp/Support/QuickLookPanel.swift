import AppKit
import Quartz

/// The system Quick Look panel, on an artifact's files (slice 87, G16): Space or ⌘Y on
/// the sidebar's selected artifact, Quick Look on a file row, and on a Trash row.
///
/// **The app delegate controls the panel** (`AppDelegate.acceptsPreviewPanelControl`). The
/// panel looks for a controller along the key window's responder chain, which ends at the
/// delegate, so every window reaches it whatever has the focus, and no SwiftUI view has to
/// be an `NSResponder`.
///
/// **Items are copies, made as the panel asks for each one** (`previewItemURL`), by the
/// same helper as Open in Default App: the package's own bytes are never handed to
/// another process (`ArchiveModel.temporaryCopy`). Made lazily, so opening the panel on an
/// artifact of large scans copies only the one shown.
@MainActor
final class QuickLookPanel: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPanel()

    /// One file the panel can show: its name, and how to get a copy of its bytes.
    struct Item {
        /// The file, as the panel's title shows it.
        let name: String
        /// Makes the copy the panel reads, or `nil` if the file can't be read.
        let copy: @MainActor () -> URL?
    }

    /// What the panel is showing, and which window's model asked: a window that closes
    /// takes its items with it.
    private(set) var items: [Item] = []
    private(set) weak var owner: AnyObject?
    /// What was asked for (`key(_:file:)`), so asking again closes the panel and asking
    /// for something else switches it.
    private(set) var shownKey: String?
    /// Where the panel should open. Applied again as it takes control, since the first
    /// time it opens the data source is only attached then, and an index set before it
    /// has no items to land on (`/code-review`).
    private var pendingIndex = 0
    /// The copies already made, by index, so stepping back doesn't copy again.
    private var previews: [Int: PreviewItem] = [:]

    /// What a request shows: an artifact's (or a trashed item's) files, opening on `file`
    /// when one was named. Naming another file of the same artifact is a new request.
    nonisolated static func key(_ item: String, file: String? = nil) -> String {
        file.map { "\(item)/\($0)" } ?? item
    }

    /// Whether asking for `key` closes the panel rather than showing it: only when it is
    /// up, for this window, on what was asked for last. Quick Look on another row switches.
    nonisolated static func closes(
        isVisible: Bool, sameOwner: Bool, shownKey: String?, key: String
    ) -> Bool {
        isVisible && sameOwner && shownKey == key
    }

    /// Whether the panel is up.
    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Shows `items` from `index`, or closes the panel if it is already showing what `key`
    /// names for `owner` (Space and ⌘Y toggle it, as in Finder).
    func toggle(_ items: [Item], at index: Int, key: String, for owner: AnyObject) {
        if Self.closes(
            isVisible: isVisible, sameOwner: self.owner === owner, shownKey: shownKey, key: key)
        {
            close()
            return
        }
        show(items, at: index, key: key, for: owner)
    }

    /// Shows `items` from `index`, replacing whatever the panel showed.
    func show(_ items: [Item], at index: Int, key: String, for owner: AnyObject) {
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        self.items = items
        self.owner = owner
        shownKey = key
        previews = [:]
        pendingIndex = min(max(index, 0), items.count - 1)
        let panel = QLPreviewPanel.shared()!
        if panel.dataSource as AnyObject? === self { applyItems(to: panel) }
        if !panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    }

    /// Follows a new selection while the panel is up, as Finder's does: `items` replace
    /// the current ones, or an empty list closes it. Does nothing while it is down, or up
    /// for another window.
    func follow(_ items: [Item], at index: Int, key: String, for owner: AnyObject) {
        guard isVisible, self.owner === owner else { return }
        if items.isEmpty {
            close()
        } else {
            show(items, at: index, key: key, for: owner)
        }
    }

    /// Closes the panel, if `owner` (when given) is the window it shows for.
    func close(for owner: AnyObject? = nil) {
        if let owner, self.owner !== owner { return }
        if isVisible { QLPreviewPanel.shared().orderOut(nil) }
        items = []
        previews = [:]
        shownKey = nil
        self.owner = nil
    }

    private func applyItems(to panel: QLPreviewPanel) {
        panel.reloadData()
        panel.currentPreviewItemIndex = pendingIndex
    }

    // MARK: - Panel control (from `AppDelegate`)

    func beginControl(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
        applyItems(to: panel)
    }

    func endControl(_ panel: QLPreviewPanel) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { items.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int)
        -> (any QLPreviewItem)!
    {
        MainActor.assumeIsolated { preview(at: index) }
    }

    private func preview(at index: Int) -> PreviewItem? {
        guard items.indices.contains(index) else { return nil }
        if let made = previews[index] { return made }
        let item = items[index]
        let made = PreviewItem(url: item.copy(), title: item.name)
        previews[index] = made
        return made
    }

    // MARK: - QLPreviewPanelDelegate

    /// Space or ⌘Y with the panel up closes it, as in Finder. The panel is key while it
    /// shows, so neither reaches the window: the sidebar never sees Space, and File ▸
    /// Quick Look has no window model to act on (`/code-review`).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown,
            Self.closesPanel(
                key: event.charactersIgnoringModifiers ?? "",
                modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        else { return false }
        MainActor.assumeIsolated { close() }
        return true
    }

    /// The keys that close the panel from inside it: Space, and ⌘Y, which opened it.
    nonisolated static func closesPanel(key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let modifiers = modifiers.subtracting([.capsLock, .numericPad, .function])
        return (key == " " && modifiers.isEmpty) || (key.lowercased() == "y" && modifiers == .command)
    }
}

/// A file the panel shows: a copy's URL, titled with the user's filename rather than the
/// copy's. Immutable, so the panel may read it from any thread.
nonisolated private final class PreviewItem: NSObject, QLPreviewItem, Sendable {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL?, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

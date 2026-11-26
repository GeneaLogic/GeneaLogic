import AppKit

/// The system's recent documents for this app, behind the Dock menu; each one noted also
/// joins Apple ▸ Recent Items, which is every app's. Told of what `ArchiveBookmarks` opens
/// and of Clear Menu, never read for the app's own menu (slice 85b): an ad-hoc signed build
/// loses the system's list at every rebuild, and it can't be observed. A seam, so a test
/// doesn't write to the developer's own list.
///
/// **No removal of one archive.** AppKit has none, and clearing the list and noting the
/// rest again lost what AppKit couldn't hand back: everything from before a rebuild (in the
/// hand-test), and presumably an archive on a drive that isn't connected. The system's list
/// keeps a removed recent until it ages out or Clear Menu, as Apple ▸ Recent Items does.
@MainActor
protocol SystemRecents {
    /// Puts an archive at the front. Needs its sandbox access.
    func note(_ url: URL)
    /// Empties this app's list (Clear Menu). Apple ▸ Recent Items keeps its entries.
    func clear()
}

/// The real list. Choosing from it arrives as an ordinary open
/// (`AppDelegate.application(_:open:)`), with access, so it needs no
/// `NSDocumentController` subclass.
struct SharedSystemRecents: SystemRecents {
    private var controller: NSDocumentController { .shared }

    func note(_ url: URL) {
        controller.noteNewRecentDocumentURL(url)
    }

    func clear() {
        controller.clearRecentDocuments(nil)
    }
}

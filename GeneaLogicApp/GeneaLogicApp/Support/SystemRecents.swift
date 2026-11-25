import AppKit

/// The system's recent documents, behind the Dock menu and Apple ▸ Recent Items. Told what
/// `ArchiveBookmarks` records, never read for the app's own menu (slice 85b): an ad-hoc
/// signed build loses the system's list at every rebuild, and it can't be observed. A seam,
/// so a test doesn't write to the developer's own list.
@MainActor
protocol SystemRecents {
    /// Puts an archive at the front. Needs its sandbox access.
    func note(_ url: URL)
    func remove(_ url: URL)
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

    /// The system has no way to remove one, so the list is cleared and the rest noted
    /// again, from its own URLs: they carry the access that noting needs.
    func remove(_ url: URL) {
        let all = controller.recentDocumentURLs
        let removed = url.canonicalArchiveURL
        let kept = all.filter { $0.canonicalArchiveURL != removed }
        guard kept.count < all.count else { return }
        controller.clearRecentDocuments(nil)
        for url in kept.reversed() { controller.noteNewRecentDocumentURL(url) }
    }

    func clear() {
        controller.clearRecentDocuments(nil)
    }
}

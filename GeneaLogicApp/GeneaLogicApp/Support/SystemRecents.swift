import AppKit

/// The system's recent documents, behind the Dock menu and Apple ▸ Recent Items. Told what
/// `ArchiveBookmarks` records from here on (not seeded with what it already lists, and with
/// the system's own length), never read for the app's own menu (slice 85b): an ad-hoc
/// signed build loses the system's list at every rebuild, and it can't be observed. A seam,
/// so a test doesn't write to the developer's own list.
@MainActor
protocol SystemRecents {
    /// Puts an archive at the front. Needs its sandbox access.
    func note(_ url: URL)
    /// Takes an archive out, wherever it is now: the system's entries follow a move, so it
    /// may be at any of `urls`.
    func remove(_ urls: [URL])
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
    func remove(_ urls: [URL]) {
        let all = controller.recentDocumentURLs
        let removed = Set(urls.map(\.canonicalArchiveURL))
        let kept = all.filter { !removed.contains($0.canonicalArchiveURL) }
        guard kept.count < all.count else { return }
        controller.clearRecentDocuments(nil)
        for url in kept.reversed() { controller.noteNewRecentDocumentURL(url) }
    }

    func clear() {
        controller.clearRecentDocuments(nil)
    }
}

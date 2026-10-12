import Foundation

/// Persists **app-scoped security-scoped bookmarks** for the archives the user has
/// opened, so access (and the windows themselves) can survive relaunch — a restored
/// `URL` window-value carries no live sandbox scope, so we re-derive one from a
/// bookmark (ARCHITECTURE.md §7). Requires the
/// `com.apple.security.files.bookmarks.app-scope` entitlement.
///
/// Two concerns, deliberately separate:
///   - **`bookmarks`** (`path → Data`) is the *access* mechanism — the source of
///     truth that `ArchiveAccessStore.ensureAccess` resolves on window restore /
///     reopen. Pruned only when a bookmark fails to resolve (archive deleted).
///   - **`recents`** (ordered `[path]`) is the *display* list behind File ▸ Open
///     Recent. "Clear Menu" empties it but leaves the bookmarks intact, so an
///     already-open (or restoring) window can still re-acquire access.
///
/// All paths are standardized file-URL paths (`url.standardizedFileURL.path`).
/// Backed by `UserDefaults`; tiny and synchronous, fine for the handful of archives
/// a user keeps.
@MainActor
@Observable
final class ArchiveBookmarks {
    static let shared = ArchiveBookmarks()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bookmarksKey = "archiveBookmarks"
    @ObservationIgnored private let recentsKey = "recentArchivePaths"
    @ObservationIgnored private let recentsLimit = 10

    /// The recent archives' standardized paths, most-recent-first. Observed source
    /// of truth for File ▸ Open Recent (so the menu updates live), mirrored into
    /// `UserDefaults` on every change.
    private(set) var recents: [String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recents = defaults.stringArray(forKey: recentsKey) ?? []
    }

    // MARK: - Recording

    /// Records `url` as opened: stores a fresh app-scoped security-scoped bookmark
    /// for it and moves it to the front of the recents list (de-duplicated, capped).
    /// Best-effort — a bookmark that can't be created (e.g. a transient I/O error)
    /// simply isn't persisted; the in-session live scope still works.
    func remember(_ url: URL) {
        let key = url.standardizedFileURL.path
        if let data = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        {
            var all = bookmarkData()
            all[key] = data
            setBookmarkData(all)
        }
        moveToFront(key)
    }

    /// Moves an already-recorded archive to the front of the recents list **without**
    /// touching its bookmark — the "opened again from Open Recent" bump (TextEdit-style).
    /// The reopen paths re-derive access via `ensureAccess` (which doesn't record a
    /// bookmark, unlike `acquire`/`remember`), so they call this to keep the most
    /// recently opened archive on top.
    func promote(_ url: URL) {
        moveToFront(url.standardizedFileURL.path)
    }

    /// Front-inserts `key` into the recents list, de-duplicated and capped.
    private func moveToFront(_ key: String) {
        var paths = recents
        paths.removeAll { $0 == key }
        paths.insert(key, at: 0)
        if paths.count > recentsLimit { paths = Array(paths.prefix(recentsLimit)) }
        setRecents(paths)
    }

    // MARK: - Resolving

    /// Resolves the persisted bookmark for `url`'s path back into a security-scoped
    /// URL (the caller is responsible for `startAccessingSecurityScopedResource()`).
    /// Refreshes a stale bookmark in place. Returns `nil` — and prunes the entry —
    /// if there's no bookmark or it no longer resolves (archive moved away/deleted).
    func resolve(_ url: URL) -> URL? {
        let key = url.standardizedFileURL.path
        guard let data = bookmarkData()[key] else { return nil }

        var isStale = false
        guard
            let resolved = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &isStale)
        else {
            forget(pathKey: key)
            return nil
        }

        if isStale {
            // Re-mint from the resolved URL so the next launch starts fresh.
            if let refreshed = try? resolved.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            {
                var all = bookmarkData()
                all[key] = refreshed
                setBookmarkData(all)
            }
        }
        return resolved
    }

    // MARK: - Recents (Open Recent menu)

    /// The recent archives, most-recent-first, as URLs for the Open Recent menu.
    func recentURLs() -> [URL] {
        recents.map { URL(fileURLWithPath: $0) }
    }

    /// Clears the Open Recent list. Bookmarks are intentionally **kept** so any
    /// window still open (or restoring) can re-acquire access.
    func clearRecents() {
        setRecents([])
    }

    /// Drops a single path from both the recents list and the bookmark store —
    /// used when a resolve fails, so a vanished archive stops haunting the menu.
    func forget(pathKey key: String) {
        setRecents(recents.filter { $0 != key })

        var all = bookmarkData()
        all[key] = nil
        setBookmarkData(all)
    }

    // MARK: - Storage

    private func setRecents(_ paths: [String]) {
        recents = paths
        defaults.set(paths, forKey: recentsKey)
    }

    private func bookmarkData() -> [String: Data] {
        defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }

    private func setBookmarkData(_ value: [String: Data]) {
        defaults.set(value, forKey: bookmarksKey)
    }
}

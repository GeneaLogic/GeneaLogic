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
///     already-open (or restoring) window can still re-acquire access. The system's own
///     recents (the Dock menu, Apple ▸ Recent Items) are told of each change to it
///     (`SystemRecents`, slice 85b), not seeded from it or held to its length.
///   - **window states** are how each archive's window was left (slice 85), keyed by
///     the archive's file identity rather than its path (`identity(of:)`). They don't
///     share the bookmarks' lifetime: only the cap below drops one.
///
/// All paths are standardized file-URL paths (`url.standardizedFileURL.path`).
/// Backed by `UserDefaults`; tiny and synchronous, fine for the handful of archives
/// a user keeps.
@MainActor
@Observable
final class ArchiveBookmarks {
    static let shared = ArchiveBookmarks(systemRecents: SharedSystemRecents())

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemRecents: any SystemRecents
    @ObservationIgnored private let bookmarksKey = "archiveBookmarks"
    @ObservationIgnored private let recentsKey = "recentArchivePaths"
    @ObservationIgnored private let recentsLimit = 10
    @ObservationIgnored private let windowStatesKey = "archiveWindowStates"
    /// How many archives' window states are kept, the most recently opened first. Nothing
    /// else drops one (see `forget`), so this is what bounds them.
    @ObservationIgnored private let windowStatesLimit: Int
    /// The stored records, encoded, read from `defaults` once. A write re-encodes only its
    /// own record: a selection step writes one.
    @ObservationIgnored private var windowStatesCache: [String: Data]?

    /// The recent archives' standardized paths, most-recent-first. Observed source
    /// of truth for File ▸ Open Recent (so the menu updates live), mirrored into
    /// `UserDefaults` on every change.
    private(set) var recents: [String]

    init(
        defaults: UserDefaults = .standard, systemRecents: any SystemRecents,
        windowStatesLimit: Int = 100
    ) {
        self.defaults = defaults
        self.systemRecents = systemRecents
        self.windowStatesLimit = windowStatesLimit
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
        systemRecents.note(url)
    }

    /// Moves an already-recorded archive to the front of the recents list **without**
    /// touching its bookmark — the "opened again from Open Recent" bump (TextEdit-style).
    /// The reopen paths re-derive access via `ensureAccess` (which doesn't record a
    /// bookmark, unlike `acquire`/`remember`), so they call this to keep the most
    /// recently opened archive on top.
    func promote(_ url: URL) {
        // Nothing there: the archive moved, and its bookmark followed it. The window that
        // opens says so, and a dead path mustn't be told to the system.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        moveToFront(url.standardizedFileURL.path)
        systemRecents.note(url)
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

    /// Resolves a **recent** to reopen it, following the archive if it has moved: when its
    /// bookmark finds it somewhere else, the bookmark and the recent take that path, so the
    /// archive opens where it is. Returns the security-scoped URL to start access on, or
    /// `nil` (and the entry is pruned) as `resolve` does. The caller promotes it.
    ///
    /// Only a move the bookmark saw: one resolves by path first, so an archive put at the
    /// old path is the one that opens, as before.
    func resolveRecent(_ url: URL) -> URL? {
        guard let resolved = resolve(url) else { return nil }
        let old = url.standardizedFileURL.path
        let new = resolved.standardizedFileURL.path
        guard new != old else { return resolved }
        var all = bookmarkData()
        all[new] = all.removeValue(forKey: old)
        setBookmarkData(all)
        // The new path goes to the front when the caller promotes it.
        setRecents(recents.filter { $0 != old })
        // The system's entry followed the move already.
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
        systemRecents.clear()
    }

    /// Takes one archive out of the recents (the welcome window's Remove from Recents). Its
    /// bookmark is **kept**, as by Clear Menu: the archive may be open, and its window needs
    /// it to restore.
    func removeRecent(_ url: URL) {
        let key = url.standardizedFileURL.path
        setRecents(recents.filter { $0 != key })

        // The system's entry follows a moved archive, so look where the bookmark finds it
        // too, unless that is another recent's place. Without mounting a volume for it.
        var places = [URL(fileURLWithPath: key, isDirectory: true)]
        var isStale = false
        if let data = bookmarkData()[key],
            let moved = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting],
                relativeTo: nil, bookmarkDataIsStale: &isStale),
            !recents.contains(moved.standardizedFileURL.path)
        {
            places.append(moved)
        }
        systemRecents.remove(places)
    }

    /// Drops a single path from both the recents list and the bookmark store —
    /// used when a resolve fails, so a vanished archive stops haunting the menu.
    ///
    /// **Window states are left alone** (slice 85's `/code-review`). One is keyed by its
    /// archive's identity, so it can't be inherited by whatever takes this path, and a path
    /// can't say which record was this archive's anyway: a record moved away from it is not
    /// re-pathed until it is reopened. Removing a recent mustn't reset the archive's window,
    /// and a bookmark that fails to resolve may only be on a drive that isn't mounted.
    func forget(pathKey key: String) {
        setRecents(recents.filter { $0 != key })
        systemRecents.remove([URL(fileURLWithPath: key, isDirectory: true)])

        var all = bookmarkData()
        all[key] = nil
        setBookmarkData(all)
    }

    // MARK: - Window state (slice 85)

    /// How the archive with this identity (`identity(of:)`) was left on this Mac, or `nil`
    /// if it is new here.
    func windowState(forIdentity identity: String) -> WindowState? {
        guard let data = windowStates()[identity] else { return nil }
        return (try? JSONDecoder().decode(StoredWindowState.self, from: data))?.state
    }

    /// Records how the archive with this identity was left, and that it was just opened.
    /// Past the cap, the least recently opened records go.
    func setWindowState(_ state: WindowState, forIdentity identity: String) {
        var states = windowStates()
        guard let data = try? JSONEncoder().encode(StoredWindowState(state: state, opened: .now))
        else { return }
        states[identity] = data
        if states.count > windowStatesLimit {
            let decoded = states.compactMapValues {
                try? JSONDecoder().decode(StoredWindowState.self, from: $0)
            }
            let oldest = decoded.sorted { $0.value.opened > $1.value.opened }
                .dropFirst(windowStatesLimit)
            for (evicted, _) in oldest { states[evicted] = nil }
            // A record that no longer decodes has no date to sort by; it goes first.
            for key in states.keys where decoded[key] == nil { states[key] = nil }
        }
        setWindowStates(states)
    }

    /// The key an archive's window state is stored under: its **file identity**, the
    /// volume's UUID and the folder's inode, or its path where the volume gives none.
    ///
    /// A move or rename on the volume keeps the identity, and a copy doesn't get it. So a
    /// moved archive keeps its state, and a Finder copy starts fresh, as does another
    /// archive put where a moved one used to be. A cross-volume move or a restore from
    /// backup starts fresh too, the accepted cost.
    ///
    /// Not through the bookmarks, which looked like the same thing: a bookmark resolves by
    /// **path** first, so an archive placed at a moved one's old path would inherit its
    /// state. Nor the kernel's document identifier, which APFS assigns lazily.
    ///
    /// **Read from a fresh `URL`**: a `URL` caches its resource values, so asking a
    /// long-lived one after the folder was replaced returns the old folder's inode. Needs
    /// the archive's sandbox access.
    static func identity(of url: URL) -> String {
        let path = url.standardizedFileURL.path
        let fresh = URL(fileURLWithPath: path, isDirectory: true)
        let values = try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey, .fileIdentifierKey])
        guard let volume = values?.volumeUUIDString, let inode = values?.fileIdentifier else {
            return "path:\(path)"
        }
        return "\(volume):\(inode)"
    }

    /// A window state and when its archive was last opened, for the cap.
    private struct StoredWindowState: Codable {
        var state: WindowState
        var opened: Date
    }

    // MARK: - Storage

    private func setRecents(_ paths: [String]) {
        recents = paths
        defaults.set(paths, forKey: recentsKey)
    }

    /// The records, encoded per record so one that doesn't decode drops alone. Cached
    /// after the first read; this object is the only writer.
    private func windowStates() -> [String: Data] {
        if let windowStatesCache { return windowStatesCache }
        let raw = defaults.dictionary(forKey: windowStatesKey) as? [String: Data] ?? [:]
        windowStatesCache = raw
        return raw
    }

    private func setWindowStates(_ value: [String: Data]) {
        windowStatesCache = value
        defaults.set(value, forKey: windowStatesKey)
    }

    private func bookmarkData() -> [String: Data] {
        defaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }

    private func setBookmarkData(_ value: [String: Data]) {
        defaults.set(value, forKey: bookmarksKey)
    }
}

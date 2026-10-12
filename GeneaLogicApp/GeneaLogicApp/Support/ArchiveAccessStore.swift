import Foundation

/// Bridges security-scoped access to an archive URL across the value-based
/// `WindowGroup(for: URL.self)` boundary.
///
/// `openWindow(value:)` **serializes** the URL to hand it to the new window (the
/// same mechanism state restoration uses), so the deserialized copy that reaches
/// the archive window can't `startAccessingSecurityScopedResource()` on its own
/// (it returns `false`). The fix: at the moment we still hold the *original*
/// scoped URL from a picker, `acquire(_:)` starts access and **retains** that
/// original URL here. Starting a security-scoped resource activates a sandbox
/// extension process-wide for that path, so once acquired, any window in this
/// process can `Archive.open(at:)` the (path-equal) URL until `release(_:)`.
///
/// `acquire` is idempotent per path and `release` removes the entry, which stays
/// balanced under the value-based group's window de-duplication (one window per
/// URL → one acquire that matters, one release on that window's close).
///
/// Powerbox-vended URLs (`NSOpenPanel` / `NSSavePanel`) are already accessible
/// and report `false` from `start…`; the store records that (`started == false`)
/// and simply skips the balancing `stop…`. `.fileImporter` URLs report `true`
/// and are stopped on release.
///
/// Live scope is session-scoped (it holds URL objects, not bookmarks). Persistence
/// *across* relaunch is delegated to `ArchiveBookmarks`: `acquire` records an
/// app-scoped bookmark, and `ensureAccess` re-derives a live scope from one when a
/// restored / reopened window arrives without it (ARCHITECTURE.md §7).
@MainActor
@Observable
final class ArchiveAccessStore {
    static let shared = ArchiveAccessStore()
    private init() {}

    private struct Entry {
        /// The original, still-scoped URL object — retained so its sandbox
        /// extension stays active for the lifetime of the window.
        let url: URL
        /// Whether `startAccessingSecurityScopedResource()` actually granted a
        /// scope that must be balanced with a `stop…` (true for `.fileImporter`
        /// URLs, false for already-accessible Powerbox URLs).
        let started: Bool
    }

    private var held: [URL: Entry] = [:]

    /// One live window per archive, keyed by canonical URL → the owning window's
    /// token. Backs `claimWindow`/`resignWindow` — a safety net against a duplicate
    /// window `WindowGroup(for:)` can't dedup on its own (slice 31). See
    /// `claimWindow`.
    private var windowClaims: [URL: UUID] = [:]

    /// Whether at least one archive is currently open in the session. A welcome
    /// window observes this to dismiss itself once it's redundant (SwiftUI
    /// spawns a fresh window to deliver each Finder-open, leaving the prior
    /// welcome window behind — see `RootWindow`).
    var hasOpenArchive: Bool { !held.isEmpty }

    // MARK: - Single-window-per-archive registry

    /// Claims the single window slot for `url` on behalf of `token` (one token per
    /// archive window). Returns `true` if this window owns the slot (proceed),
    /// `false` if another window already holds it (the caller should `dismiss()` —
    /// it's a duplicate).
    ///
    /// **Why this exists.** `WindowGroup(for: URL.self)` de-duplicates by value only
    /// among windows *already in the scene table*, so it can't stop a duplicate that
    /// races state restoration (slice 31). `ArchiveOpenCoordinator` already prevents
    /// that race by deferring the Finder-open's `openWindow` until *after*
    /// restoration — so the restored window is always in the scene table first, and a
    /// deferred open just focuses it. This registry is the **safety net**: should a
    /// second window ever appear, it's necessarily the later (post-restoration) one,
    /// so a plain **first-wins** rule dismisses it and keeps the restored window. (The
    /// document architecture, `NSDocumentController`/`DocumentGroup`, has this kind of
    /// URL-keyed open registry built in; we reimplement it because the package/engine
    /// design rules `DocumentGroup` out.)
    func claimWindow(_ url: URL, token: UUID) -> Bool {
        let key = url.canonicalArchiveURL
        if let owner = windowClaims[key] { return owner == token }
        windowClaims[key] = token
        return true
    }

    /// Relinquishes `url`'s window slot if `token` owns it. Returns `true` when this
    /// window was the owner — the signal to also `release(_:)` the archive's access
    /// (a dismissed *duplicate* was never the owner, so it must **not** release the
    /// scope the surviving window still relies on).
    @discardableResult
    func resignWindow(_ url: URL, token: UUID) -> Bool {
        let key = url.canonicalArchiveURL
        guard windowClaims[key] == token else { return false }
        windowClaims[key] = nil
        return true
    }

    /// Begins (or no-ops, if already held) session access to `url`. Call this
    /// while still holding the original picker URL, immediately before
    /// `openWindow(value:)` / setting a window's URL binding. Also records an
    /// app-scoped bookmark so this archive can be reopened/restored next launch.
    func acquire(_ url: URL) {
        let key = url.canonicalArchiveURL
        if held[key] == nil {
            let started = url.startAccessingSecurityScopedResource()
            held[key] = Entry(url: url, started: started)
        }
        // Record the bookmark while access is active (a picker/Powerbox URL is
        // user-selected and accessible here), and bump it to the front of recents.
        ArchiveBookmarks.shared.remember(url)
    }

    /// Ensures session access to `url` is held — the restore/reopen path. If a live
    /// scope already exists (e.g. `acquire` ran first), it's a no-op success. Else
    /// it resolves the persisted bookmark for `url`, starts a scope on the resolved
    /// URL, and retains it under `url`'s key (so the later `release(url)` balances).
    /// Returns whether access is now available — `false` means no usable bookmark
    /// (never opened here, or the archive moved/was deleted), and the caller should
    /// surface a "couldn't reopen" state.
    @discardableResult
    func ensureAccess(to url: URL) -> Bool {
        let key = url.canonicalArchiveURL
        if held[key] != nil { return true }
        guard let resolved = ArchiveBookmarks.shared.resolve(url) else { return false }
        let started = resolved.startAccessingSecurityScopedResource()
        held[key] = Entry(url: resolved, started: started)
        return true
    }

    /// Reopens a **recent** archive: canonicalizes `url`, re-derives sandbox access
    /// from its persisted bookmark, and — on success — bumps it to the top of Recent
    /// (TextEdit-style). Returns the canonical URL the caller opens a window for
    /// (`openWindow(value:)`) or binds a welcome window to. A failed reopen isn't
    /// promoted — `ensureAccess` self-prunes the dead bookmark, and the opened window
    /// then shows the "couldn't reopen" state. The single source of the recent-reopen
    /// policy, shared by File ▸ Open Recent and the welcome-screen Recent list.
    @discardableResult
    func reopenRecent(_ url: URL) -> URL {
        let canonical = url.canonicalArchiveURL
        if ensureAccess(to: canonical) {
            ArchiveBookmarks.shared.promote(canonical)
        }
        return canonical
    }

    /// Records session access to `url` **without** starting a scope or storing a
    /// bookmark — for a path this process can already reach on its own.
    ///
    /// A test seam (slice 52's app test target), in the same spirit as
    /// `Archive.lockTimeout`. Tests build archives under the host's own container,
    /// which needs no security scope, but `ensureAccess` still refuses them
    /// because there is neither a live entry nor a saved bookmark. Going through
    /// `acquire` instead would mint a real security-scoped bookmark and write it
    /// into the *developer's own* app defaults, which is both a side effect on the
    /// user's Open Recent menu and slow enough under the test host's sandbox to
    /// dominate the suite's runtime.
    func adoptAlreadyReachable(_ url: URL) {
        let key = url.canonicalArchiveURL
        if held[key] == nil { held[key] = Entry(url: url, started: false) }
    }

    /// Ends session access to `url`, balancing any scope `acquire(_:)` started.
    /// Call this when the archive window closes.
    func release(_ url: URL) {
        let key = url.canonicalArchiveURL
        guard let entry = held.removeValue(forKey: key) else { return }
        if entry.started { entry.url.stopAccessingSecurityScopedResource() }
    }
}

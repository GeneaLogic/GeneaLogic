import Foundation

extension URL {
    /// A stable canonical form for an archive URL, used as the **window-dedup key**
    /// for the value-based `WindowGroup(for: URL.self)` and as the access-store key.
    ///
    /// A `.genea` is a **package (directory)**, so the *same* archive can arrive as
    /// URLs that differ only by a **trailing slash**: Finder's `onOpenURL` delivers
    /// `…/x.genea/`, while a value round-tripped through state restoration (or built
    /// from a raw string) may lack it. A directory URL with a trailing slash is **not**
    /// `==` to one without, and `standardizedFileURL` does **not** reconcile them
    /// (verified empirically). That defeats `WindowGroup`'s value de-duplication, so
    /// double-clicking an already-open (or just-restored) archive spawns a **second**
    /// window for it (slice 31).
    ///
    /// Rebuilding from `.path` with `isDirectory: true` normalizes the trailing slash
    /// (a `.genea` is always a directory, so forcing it is correct and avoids a
    /// filesystem stat), making the restored value and a fresh Finder open compare
    /// equal so dedup focuses the existing window. `.path` is unchanged by this, so it
    /// stays a drop-in key for `ArchiveBookmarks` (which keys by `.path`). Symlink
    /// resolution is deliberately **not** done here: it wouldn't collapse the `/Users`
    /// firmlink case anyway, and it would risk re-keying existing bookmarks.
    var canonicalArchiveURL: URL {
        URL(fileURLWithPath: standardizedFileURL.path, isDirectory: true)
    }
}

import SwiftUI

/// The content of one window in the value-based `WindowGroup(for: URL.self)`.
///
/// The window's bound value drives what it shows: `nil` is the welcome screen,
/// a non-`nil` URL is that archive. Opening from the welcome screen writes the
/// binding, which transforms *this* window into the archive in place (no
/// lingering empty window). A fresh window — launch, Dock reopen — starts at
/// `nil` and shows welcome.
struct RootWindow: View {
    @Binding var url: URL?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let url {
                // `.id(url)` ties the container's identity (and its per-window
                // `ArchiveModel`) to the URL, so the model is never reused for a
                // different archive.
                ArchiveContainerView(url: url)
                    .id(url)
            } else {
                WelcomeView(url: $url)
            }
        }
        .onOpenURL { incoming in
            // Finder double-click / "Open With" on a .genea package. Route through
            // the value-based `openWindow`, which *de-duplicates*: a re-open of an
            // already-open archive focuses its window instead of spawning a second.
            //
            // `acquire` gets the **original** security-scoped URL now (it starts the
            // scope and mints the bookmark from it); canonicalizing first would strip
            // the scope, since `canonicalArchiveURL` rebuilds the URL from a path.
            //
            // The `openWindow` is deferred through `ArchiveOpenCoordinator` until
            // after state restoration, so an open of a just-restored archive
            // *focuses* its restored window (bringing it to front) instead of racing
            // it into a duplicate (slice 31). The window value is canonicalized so it
            // matches the restored window's (possibly slash-different) value.
            ArchiveAccessStore.shared.acquire(incoming)
            let value = incoming.canonicalArchiveURL
            ArchiveOpenCoordinator.shared.requestOpen {
                openWindow(value: value)
            }
        }
        // A welcome window must not coexist with an open archive. Two ways one
        // ends up redundant: it was on screen when the first archive opened
        // (`false → true` transition), or SwiftUI spawned it to deliver a
        // Finder-open while an archive was *already* open (no transition — caught
        // by `initial: true`). Either way, dismiss it — but only while it's still
        // the welcome screen (`url == nil`), which spares a window that is itself
        // becoming an archive (the welcome-screen buttons set `url` in place).
        .onChange(of: ArchiveAccessStore.shared.hasOpenArchive, initial: true) { _, hasArchive in
            if hasArchive && url == nil {
                dismiss()
            }
        }
    }
}

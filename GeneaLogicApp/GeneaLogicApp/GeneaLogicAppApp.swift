import AppKit
import SwiftUI

@main
struct GeneaLogicAppApp: App {
    // Opts the app into secure state restoration. Without an `NSApplicationDelegate`
    // returning `true` here, macOS 14+ disables window restoration entirely (and logs
    // a warning) — so a SwiftUI app that wants its `WindowGroup(for:)` windows to
    // restore needs this hook.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // One archive per window, keyed by the archive's URL. The value-based
        // group de-duplicates by value, so opening an already-open archive
        // focuses its window instead of spawning a second (this is also what
        // retires the old "Finder double-click opens a second window" issue). A
        // `nil` value is the welcome state; see `RootWindow`. (ARCHITECTURE.md §7.)
        WindowGroup(for: URL.self) { $url in
            RootWindow(url: $url)
        }
        // Restore archive windows across launches via the **OS** mechanism, which
        // correctly honors the user's "Close windows when quitting an app" setting
        // (clean-slate users get a clean slate; restore users get their windows
        // back). The system persists each window's bare `URL` value, which carries
        // no live sandbox scope, so a restored window re-derives one from that
        // archive's app-scoped bookmark in `ArchiveModel.load()` (via
        // `ArchiveAccessStore.ensureAccess`); a window whose archive has since been
        // moved/deleted shows a clear "can no longer reach this archive" state.
        // (ARCHITECTURE.md §7.)
        .restorationBehavior(.automatic)
        .commands {
            ArchiveCommands()
        }

        // Popped-out file previews (the inline preview pane's "open in a separate
        // window" action). Keyed by a `FilePreviewRequest` carrying a temp-copy URL;
        // restoration is disabled since that URL is session-only and a preview window
        // isn't worth restoring.
        WindowGroup(for: FilePreviewRequest.self) { $request in
            FilePreviewWindow(request: request)
        }
        .restorationBehavior(.disabled)
    }
}

/// Minimal delegate: opts into secure state restoration (see the adaptor above) and
/// signals when launch + window restoration have completed, so buffered Finder-open
/// requests run *after* the restored windows exist (slice 31 — see
/// `ArchiveOpenCoordinator`).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Turn off automatic window tabbing app-wide. Our archive windows are
        // value-based `WindowGroup(for: URL.self)` scenes, not tabbable documents,
        // so AppKit's "Show Tab Bar"/"Show All Tabs"/merge-into-tabs machinery just
        // crashes when exercised — remove those View-menu items entirely (Enter Full
        // Screen is separate and stays).
        NSWindow.allowsAutomaticWindowTabbing = false

        // AppKit restores windows before this fires; drain any buffered opens now
        // (the coordinator adds one runloop hop for SwiftUI scene registration).
        MainActor.assumeIsolated { ArchiveOpenCoordinator.shared.launchDidFinish() }
    }
}

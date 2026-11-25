import AppKit
import SwiftUI

@main
struct GeneaLogicAppApp: App {
    // Opts the app into secure state restoration. Without an `NSApplicationDelegate`
    // returning `true` here, macOS 14+ disables window restoration entirely (and logs
    // a warning) — so a SwiftUI app that wants its `WindowGroup(for:)` windows to
    // restore needs this hook.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // The delegate and its coordinator have no environment of their own to open a
        // window from (slice 85b).
        let _ = wireOpenCoordinator()

        // One archive per window, keyed by the archive's URL. The value-based
        // group de-duplicates by value, so opening an already-open archive
        // focuses its window instead of spawning a second (this is also what
        // retires the old "Finder double-click opens a second window" issue).
        // (ARCHITECTURE.md §7.)
        //
        // First, so it is the app's primary scene: a primary `Window` quits the app when
        // it closes.
        WindowGroup(for: URL.self) { $url in
            ArchiveWindow(url: url)
        }
        // The delegate opens documents. Without this, SwiftUI also spawned an empty window
        // to deliver each one to.
        .handlesExternalEvents(matching: [])
        // Nothing to show without an archive; `ArchiveOpenCoordinator` decides what a
        // launch brings up.
        .defaultLaunchBehavior(.suppressed)
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
        // An archive's first window opens at this size; a reopened one keeps its own. The minimum is `ArchiveContainerView`'s (slice 81, G9).
        .defaultSize(width: Layout.ArchiveWindow.defaultWidth, height: Layout.ArchiveWindow.defaultHeight)
        .commands {
            // View ▸ Show/Hide Sidebar (⌃⌘S). On Tree, which has no split view, the
            // responder chain disables it.
            SidebarCommands()
            ArchiveCommands()
        }

        // The welcome window (slice 85b, G24): single-instance, and free to sit beside open
        // archives. SwiftUI lists it in the Window menu under its title, with this key
        // (Xcode's). `ArchiveOpenCoordinator` presents it at launch and on a Dock click.
        Window("Welcome to GeneaLogic", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .keyboardShortcut("1", modifiers: [.command, .shift])
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .handlesExternalEvents(matching: [])

        // Popped-out file previews (the inline preview pane's "open in a separate
        // window" action). Keyed by a `FilePreviewRequest` carrying a temp-copy URL;
        // restoration is disabled since that URL is session-only and a preview window
        // isn't worth restoring.
        WindowGroup(for: FilePreviewRequest.self) { $request in
            FilePreviewWindow(request: request)
        }
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .handlesExternalEvents(matching: [])
    }

    private func wireOpenCoordinator() {
        ArchiveOpenCoordinator.shared.openArchive = { openWindow(value: $0) }
        ArchiveOpenCoordinator.shared.openWelcome = { openWindow(id: WelcomeView.windowID) }
    }
}

/// The app's launch, open and reopen events, handed to `ArchiveOpenCoordinator`; and the
/// opt-in to secure state restoration (see the adaptor above).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Turn off automatic window tabbing app-wide. Our archive windows are
        // value-based `WindowGroup(for: URL.self)` scenes, not tabbable documents,
        // so AppKit's "Show Tab Bar"/"Show All Tabs"/merge-into-tabs machinery just
        // crashes when exercised — remove those View-menu items entirely (Enter Full
        // Screen is separate and stays).
        NSWindow.allowsAutomaticWindowTabbing = false

        // AppKit restores windows before this fires; one runloop hop lets SwiftUI
        // register their scenes.
        DispatchQueue.main.async { ArchiveOpenCoordinator.shared.launchDidFinish() }
    }

    /// Finder, the Dock menu and Apple ▸ Recent Items. Here rather than in `onOpenURL`,
    /// which a window receives: SwiftUI spawned a window to deliver each one.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL {
            // On the **original** scoped URL (it starts the scope and mints the bookmark
            // from it); canonicalizing first would strip the scope, since
            // `canonicalArchiveURL` rebuilds the URL from a path.
            ArchiveAccessStore.shared.acquire(url)
            ArchiveOpenCoordinator.shared.open(url)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        return ArchiveOpenCoordinator.shared.reopen()
    }
}

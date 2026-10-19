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
        // SPIKE 77, question 1: archives as read-only documents. The
        // `WindowGroup(for: URL.self)` and its commands are out while this is tried;
        // welcome and New Archive are question 5.
        DocumentGroup { document in
            ArchiveDocumentView(document: document)
        } makeReadableDocument: { configuration, _ in
            ArchiveDocument(configuration: configuration)
        }

        // SPIKE 77, question 0.
        DocumentGroup { document in
            ScratchDocumentView(document: document)
        } makeDocument: { configuration, _ in
            ScratchDocument(configuration: configuration)
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

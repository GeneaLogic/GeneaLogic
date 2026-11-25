import AppKit

/// Decides which window a launch, a Finder open or a Dock click brings up: an archive's,
/// the welcome window (slice 85b), or the ones already there.
///
/// **Opens wait for state restoration**, so an open of an already-restored archive
/// **focuses** its restored window instead of racing it and spawning a duplicate (slice
/// 31). `openWindow(value:)` focuses an existing window for that value, but only once it
/// is in the scene table. On relaunch the OS restores the archive's window *and* delivers
/// the document-open; AppKit restores windows *before* `applicationDidFinishLaunching`
/// (the ordering `NSDocument` apps rely on), so opens are buffered until then, plus one
/// runloop hop for SwiftUI to register the restored scenes.
///
/// **The welcome window waits for the same moment**, when it is known whether anything
/// else came up. That is why it isn't SwiftUI's to present at launch: a Finder open must
/// not flash it.
@MainActor
final class ArchiveOpenCoordinator {
    static let shared = ArchiveOpenCoordinator()

    /// Opens, or focuses, the window of the archive at a canonical URL; and the welcome
    /// window. Set by the app's scene, where `openWindow` is available.
    var openArchive: (URL) -> Void = { _ in }
    var openWelcome: () -> Void = {}

    /// Whether the app has a window, on screen or in the Dock.
    private let hasWindows: @MainActor () -> Bool
    /// `true` once launch + state restoration have completed. Until then, opens are
    /// buffered rather than run against a half-restored scene table.
    private var launchFinished = false
    /// Archives to open that arrived during launch, in order.
    private var pending: [URL] = []

    init(hasWindows: @escaping @MainActor () -> Bool = ArchiveOpenCoordinator.appHasWindows) {
        self.hasWindows = hasWindows
    }

    /// Opens an archive whose access is already held: now if launch has completed (the
    /// common "double-click while open" case), otherwise once it has.
    func open(_ url: URL) {
        let url = url.canonicalArchiveURL
        if launchFinished {
            openArchive(url)
        } else {
            pending.append(url)
        }
    }

    /// Called once AppKit has restored windows and SwiftUI has registered their scenes
    /// (a runloop hop after `applicationDidFinishLaunching`). Runs the buffered opens, or
    /// shows the welcome window if the launch brought up nothing at all.
    func launchDidFinish() {
        launchFinished = true
        let urls = pending
        pending.removeAll()
        if urls.isEmpty {
            showWelcomeIfEmpty()
        } else {
            urls.forEach(openArchive)
        }
    }

    /// A Dock click, or any other reopen. Returns whether AppKit should do its own part,
    /// which is to bring back a minimized window.
    func reopen() -> Bool {
        guard launchFinished else { return true }
        return !showWelcomeIfEmpty()
    }

    /// A window that had no archive after all has closed, and it counted as one when the
    /// launch finished.
    func emptyWindowDidClose() {
        showWelcomeIfEmpty()
    }

    @discardableResult
    private func showWelcomeIfEmpty() -> Bool {
        guard !hasWindows() else { return false }
        openWelcome()
        return true
    }

    /// An ordinary window: not a panel, and not one of the helpers AppKit keeps.
    private static func appHasWindows() -> Bool {
        NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeMain }
    }
}

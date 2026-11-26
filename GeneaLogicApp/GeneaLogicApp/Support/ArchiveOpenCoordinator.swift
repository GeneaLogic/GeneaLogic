import AppKit

/// Decides which window a launch, a Finder open or a Dock click brings up: an archive's,
/// the welcome window (slice 85b), or the ones already there.
///
/// **Opens wait for state restoration**, so an open of an already-restored archive
/// **focuses** its restored window instead of racing it and spawning a duplicate (slice
/// 31). `openWindow(value:)` focuses an existing window for that value, but only once it
/// is in the scene table. On relaunch the OS restores the archive's window *and* delivers
/// the document-open, so opens are buffered until AppKit has both finished launching and
/// finished restoring windows, in whichever order (`NSWindowRestoration.h` allows either),
/// plus one runloop hop for SwiftUI to register the restored scenes.
///
/// **The welcome window waits for the same moment**, when it is known whether anything
/// else came up. That is why it isn't SwiftUI's to present at launch: a Finder open must
/// not flash it. It closes whenever an archive window opens, however it came to
/// (`archiveWindowDidOpen`).
@MainActor
final class ArchiveOpenCoordinator {
    static let shared = ArchiveOpenCoordinator()

    /// Opens, or focuses, the window of the archive at a canonical URL; and opens and
    /// closes the welcome window. Set by the app's scene, where `openWindow` is available.
    var openArchive: (URL) -> Void = { _ in }
    var openWelcome: () -> Void = {}
    var closeWelcome: () -> Void = {}

    /// Whether the app has a window, on screen or in the Dock.
    private let hasWindows: @MainActor () -> Bool
    /// Whether the app is hidden. Its open windows then report that they aren't visible, so
    /// `hasWindows` can't be asked until it is shown.
    private let isHidden: @MainActor () -> Bool
    /// The two halves of a finished launch.
    private var didLaunch = false
    private var didRestore = false
    /// `true` once launch + state restoration have completed. Until then, opens are
    /// buffered rather than run against a half-restored scene table.
    private var launchFinished: Bool { didLaunch && didRestore }
    /// Whether to ask for the welcome window again when the app is shown.
    private var checkWhenShown = false
    /// Archives to open that arrived during launch, in order.
    private var pending: [URL] = []

    init(
        hasWindows: @escaping @MainActor () -> Bool = ArchiveOpenCoordinator.appHasWindows,
        isHidden: @escaping @MainActor () -> Bool = { NSApp.isHidden }
    ) {
        self.hasWindows = hasWindows
        self.isHidden = isHidden
    }

    /// Opens an archive whose access is already held, and closes the welcome window: now if
    /// launch has completed (the common "double-click while open" case), otherwise once it
    /// has. Every open goes through here, so the welcome window closes whichever way an
    /// archive was opened.
    func open(_ url: URL) {
        let url = url.canonicalArchiveURL
        if launchFinished {
            show(url)
        } else {
            pending.append(url)
        }
    }

    /// The app has finished launching (a runloop hop after the notification, so SwiftUI has
    /// registered the scenes).
    func launchDidFinish() {
        guard !didLaunch else { return }
        didLaunch = true
        startIfReady()
    }

    /// AppKit has finished restoring windows (and a runloop hop, as above). Posted even when
    /// there were none.
    func restorationDidFinish() {
        guard !didRestore else { return }
        didRestore = true
        startIfReady()
    }

    /// Runs the buffered opens, or shows the welcome window if the launch brought up nothing
    /// at all.
    private func startIfReady() {
        guard launchFinished else { return }
        let urls = pending
        pending.removeAll()
        if urls.isEmpty {
            showWelcomeIfEmpty()
        } else {
            urls.forEach(show)
        }
    }

    private func show(_ url: URL) {
        openArchive(url)
        closeWelcome()
    }

    /// A Dock click, or any other reopen. Returns whether AppKit should do its own part,
    /// which is to bring back a minimized window.
    func reopen() -> Bool {
        guard launchFinished else { return true }
        return !showWelcomeIfEmpty()
    }

    /// The app was shown after being hidden (and a runloop hop, so its windows are back).
    func appDidUnhide() {
        guard checkWhenShown else { return }
        checkWhenShown = false
        showWelcomeIfEmpty()
    }

    /// An archive's window is up: one that was opened, or one restored.
    func archiveWindowDidOpen() {
        closeWelcome()
    }

    @discardableResult
    private func showWelcomeIfEmpty() -> Bool {
        guard !isHidden() else {
            checkWhenShown = true
            return false
        }
        guard !hasWindows() else { return false }
        openWelcome()
        return true
    }

    /// An ordinary window, on screen or minimized: titled, and not a panel. Not
    /// `canBecomeMain`, which a minimized window reports `false` (85b's hand-test: a Dock
    /// click with one minimized brought up the welcome window). A closed window SwiftUI
    /// keeps around is neither visible nor minimized.
    private static func appHasWindows() -> Bool {
        NSApp.windows.contains {
            ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
                && !($0 is NSPanel)
        }
    }
}

import AppKit
import SwiftUI

/// Keeps an archive window's frame in its `WindowState` (slice 85), so the frame
/// follows the archive rather than the window: applied when the window opens, saved
/// when a resize or move ends. A record with no frame leaves the window at its default
/// size (slice 81).
///
/// **Not AppKit's frame autosave**, which the spec first had: SwiftUI's windows keep a
/// frame autosave name of SwiftUI's own, and a name set on them saved nothing (85's
/// hand-test). `frameDescriptor` is the same string the autosave would store, screen
/// included, so `setFrame(from:)` handles a display that has since gone.
///
/// Hosted zero-size in the window's background, once the window has loaded its record
/// (`ArchiveWindowState.isLoaded`). Reads and writes the state outside any view body,
/// so a move re-renders nothing.
struct WindowFrameKeeper: NSViewRepresentable {
    let state: ArchiveWindowState

    func makeNSView(context: Context) -> KeeperView {
        KeeperView(state: state)
    }

    func updateNSView(_ view: KeeperView, context: Context) {}

    final class KeeperView: NSView {
        private let state: ArchiveWindowState
        private var observers: [NSObjectProtocol] = []
        /// Saves wait until the record's frame has been applied, so SwiftUI's opening
        /// size can't overwrite it.
        private var isRestored = false

        init(state: ArchiveWindowState) {
            self.state = state
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, observers.isEmpty else { return }
            // A hop later: SwiftUI sizes a new window after its content first appears,
            // and would undo a frame applied now.
            let saved = state.frame
            DispatchQueue.main.async { [weak self, weak window] in
                if let saved, let window { window.setFrame(from: saved) }
                self?.isRestored = true
            }
            // A live resize saves once, at its end; a move, a zoom or a programmatic
            // resize save as they happen.
            let names: [Notification.Name] = [
                NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification,
                NSWindow.didResizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                }
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                observers.forEach(NotificationCenter.default.removeObserver)
                observers = []
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func save() {
            // Not mid-drag, and not full screen, whose frame is the screen's.
            guard isRestored, let window, !window.inLiveResize,
                !window.styleMask.contains(.fullScreen)
            else { return }
            state.frame = window.frameDescriptor
        }
    }
}

import AppKit
import SwiftUI

/// Saves and restores an archive window's frame under its record's name (slice 85),
/// through AppKit's frame autosave, so the frame follows the archive rather than the
/// window. A name with nothing saved under it leaves the window at its default size
/// (slice 81).
///
/// Hosted zero-size in the window's background. Attached once the window owns its
/// archive (`ArchiveWindowState.isLoaded`), so it never claims a name that is about to
/// change.
struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> FrameAutosaveView {
        FrameAutosaveView(name: name)
    }

    func updateNSView(_ view: FrameAutosaveView, context: Context) {}

    final class FrameAutosaveView: NSView {
        let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            // Restore first: setting the name alone doesn't apply a saved frame.
            _ = window.setFrameUsingName(name)
            if !window.setFrameAutosaveName(name) {
                // **A name is one window's** (85's `/code-review`): AppKit refuses it
                // while another window holds it, and SwiftUI can keep a closed window
                // alive. One archive has one open window (slice 31), so the holder is
                // this archive's closed one: take the name from it.
                for other in NSApp.windows where other !== window && other.frameAutosaveName == name
                {
                    other.setFrameAutosaveName("")
                }
                window.setFrameAutosaveName(name)
            }
        }

        /// Gives the name up as the window goes, so a reopened archive's window can take
        /// it at once.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, let window, window.frameAutosaveName == name {
                window.setFrameAutosaveName("")
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

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
            window.setFrameAutosaveName(name)
        }
    }
}

import Foundation

/// Sequences Finder/`onOpenURL` open requests **after** state restoration, so an
/// open of an already-restored archive **focuses** its restored window instead of
/// racing it and spawning a duplicate (slice 31).
///
/// `openWindow(value:)` on a value-based `WindowGroup` focuses an existing window
/// for that value if one is present — but only if it's already in the scene table.
/// On relaunch the OS restores the archive's window *and* delivers the document-open;
/// if the open is handled before restoration has registered the restored window, a
/// second window is created. AppKit restores windows *before* `applicationDidFinish`
/// `Launching` (the ordering `NSDocument` apps rely on), so we buffer open requests
/// until then (plus one runloop hop for SwiftUI to register the restored scenes) and
/// only then run them — at which point `openWindow(value:)` deduplicates onto the
/// restored window and brings it to the front.
@MainActor
final class ArchiveOpenCoordinator {
    static let shared = ArchiveOpenCoordinator()
    private init() {}

    /// `true` once launch + state restoration have completed. Until then, open
    /// requests are buffered rather than run against a half-restored scene table.
    private var launchFinished = false
    /// Open requests that arrived during launch, run in order once restoration is done.
    private var pending: [() -> Void] = []

    /// Runs `open` now if launch/restoration is already complete (the app was already
    /// running — the common "double-click while open" case), otherwise buffers it
    /// until `launchDidFinish()`. `open` should perform the `openWindow(value:)`.
    func requestOpen(_ open: @escaping () -> Void) {
        if launchFinished {
            open()
        } else {
            pending.append(open)
        }
    }

    /// Called from `applicationDidFinishLaunching` (after AppKit has restored windows).
    /// Defers one runloop hop so SwiftUI has registered the restored scenes for
    /// `openWindow`'s value de-duplication, then drains any buffered opens.
    func launchDidFinish() {
        DispatchQueue.main.async {
            self.launchFinished = true
            let work = self.pending
            self.pending.removeAll()
            work.forEach { $0() }
        }
    }
}

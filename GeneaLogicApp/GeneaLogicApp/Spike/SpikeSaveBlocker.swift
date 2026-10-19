// SPIKE 77 — throwaway. Never merged.
//
// Menu pruning loses to SwiftUI's menu rebuilds, so claim the document's save-family
// actions in the responder chain instead, ahead of the document, and report them
// disabled. ⌘S then beeps instead of replacing the package.

import AppKit
import SwiftUI
import os

final class SpikeSaveBlocker: NSResponder, NSMenuItemValidation {
    static let blocked: Set<Selector> = [
        #selector(NSDocument.save(_:)), #selector(NSDocument.saveAs(_:)),
        #selector(NSDocument.saveTo(_:)), #selector(NSDocument.duplicate(_:)),
        #selector(NSDocument.revertToSaved(_:)), #selector(NSDocument.browseVersions(_:)),
        #selector(NSDocumentController.newDocument(_:)),
    ]


    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        return !Self.blocked.contains(action)
    }

    @objc func saveDocument(_ sender: Any?) {}
    @objc func saveDocumentAs(_ sender: Any?) {}
    @objc func saveDocumentTo(_ sender: Any?) {}
    @objc func duplicateDocument(_ sender: Any?) {}
    @objc func revertDocumentToSaved(_ sender: Any?) {}
    @objc func browseDocumentVersions(_ sender: Any?) {}
    @objc func newDocument(_ sender: Any?) {}
}

/// Inserts a `SpikeSaveBlocker` right after the hosting window in its responder chain.
struct SpikeSaveBlockerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !(window.nextResponder is SpikeSaveBlocker) else { return }
            let blocker = SpikeSaveBlocker()
            blocker.nextResponder = window.nextResponder
            window.nextResponder = blocker
            spikeQ1Log.notice(
                "BLOCKER installed; next=\(String(describing: blocker.nextResponder), privacy: .public)"
            )
        }
    }
}

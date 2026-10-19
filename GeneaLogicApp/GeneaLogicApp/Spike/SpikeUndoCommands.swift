// SPIKE 77 — throwaway. Never merged.
//
// Edit ▸ Undo/Redo for an archive window whose model keeps its own `UndoManager`.
// A text field being edited keeps ⌘Z for its typing (the standard `undo:` action down
// the responder chain); otherwise the menu drives the archive's stack.

import AppKit
import SwiftUI

struct SpikeUndoCommands: Commands {
    @FocusedValue(\.archiveModel) private var activeModel

    var body: some Commands {
        // A read-only archive must never be saved: Save, even unedited, replaces the
        // whole package. Remove the save group.
        CommandGroup(replacing: .saveItem) {}

        CommandGroup(replacing: .undoRedo) {
            Button(undoTitle) { perform(undo: true) }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!canUndo)
            Button(redoTitle) { perform(undo: false) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canRedo)
        }
    }

    /// The field editor of a text field that is being edited, if it has something to undo.
    private var editingField: NSTextView? {
        guard let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isFieldEditor else {
            return nil
        }
        return view
    }

    private var archiveUndo: UndoManager? { activeModel?.undoManager }

    private var canUndo: Bool {
        editingField?.undoManager?.canUndo == true || archiveUndo?.canUndo == true
    }
    private var canRedo: Bool {
        editingField?.undoManager?.canRedo == true || archiveUndo?.canRedo == true
    }

    private var undoTitle: String {
        if editingField?.undoManager?.canUndo == true { return "Undo Typing" }
        return archiveUndo?.undoMenuItemTitle ?? "Undo"
    }

    private var redoTitle: String {
        if editingField?.undoManager?.canRedo == true { return "Redo Typing" }
        return archiveUndo?.redoMenuItemTitle ?? "Redo"
    }

    private func perform(undo: Bool) {
        if let field = editingField,
            undo ? field.undoManager?.canUndo == true : field.undoManager?.canRedo == true
        {
            NSApp.sendAction(Selector(undo ? "undo:" : "redo:"), to: nil, from: nil)
        } else if undo {
            archiveUndo?.undo()
        } else {
            archiveUndo?.redo()
        }
    }
}

import AppKit
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The file verbs that hand an attached file to something outside the archive window:
/// a separate preview window, the default app, a save panel. Shared by the document
/// header, the Files rows, and the Artifact ▸ Selected File menu. Each works on a copy;
/// the original inside the package is never handed out.
///
/// Built where it is used, inside an action, so no view takes it (or a closure for it)
/// as an input.
@MainActor
struct ArtifactFileActions {
    let model: ArchiveModel
    let artifactID: ArtifactID
    let openWindow: OpenWindowAction

    /// Opens `entry` in a separate preview window, over a session-temp copy.
    func popOut(_ entry: FileEntry) {
        guard
            let copy = model.temporaryCopy(
                of: entry.uid, in: artifactID, originalName: entry.originalName)
        else { return }
        openWindow(value: FilePreviewRequest(url: copy, title: entry.originalName))
    }

    /// Opens a session-temp copy of `entry` in the user's default app for that type.
    func openExternally(_ entry: FileEntry) {
        guard
            let copy = model.temporaryCopy(
                of: entry.uid, in: artifactID, originalName: entry.originalName)
        else { return }
        NSWorkspace.shared.open(copy)
    }

    /// Exports a copy of `entry` to a user-chosen location via the save panel.
    func saveCopy(_ entry: FileEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.originalName
        panel.canCreateDirectories = true
        panel.title = "Save a Copy"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        model.exportFile(entry.uid, in: artifactID, to: destination)
    }
}

import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Trash (recoverable deletes)

    /// The artifacts currently in the archive's `.trash/`, most recently deleted
    /// first — what the trash sheet lists. Empty when no archive is open.
    func trashedArtifacts() -> [TrashedArtifact] {
        archive?.trashedArtifacts() ?? []
    }

    /// Restores a trashed artifact back into the archive (the trash sheet's Restore
    /// action) and refreshes the browse list. **Undoable**: ⌘Z re-deletes it (back to
    /// the Trash), ⌘⇧Z restores again — the same delete↔restore ping-pong as the
    /// sidebar Delete, so the undo stack stays coherent with out-of-band recovery from
    /// the sheet (undoing a delete and restoring from the sheet are two doors to one
    /// store). Without this, a restore would leave the original delete's undo pointing
    /// at an entry the restore already consumed.
    func restoreFromTrash(_ uid: ArtifactID) {
        mutate(unopened: "Open an archive before restoring.") { archive in
            _ = try archive.restoreFromTrash(uid)
        } commit: { [self] _ in
            registerArtifactRedelete(of: uid, actionName: "Restore Artifact")
            bumpAndRefresh()
        }
    }

    /// Permanently deletes one trashed artifact (the per-row "Delete Permanently"
    /// action) — irreversible; the bytes leave the package.
    func deleteFromTrash(_ uid: ArtifactID) {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.deleteFromTrash(uid)
        } commit: { _ in
        }
    }

    /// Permanently empties the trash (the sheet's "Empty Trash" action) —
    /// irreversible; clears both trashed artifacts **and** trashed files. Any
    /// in-session ⌘Z that still points at a now-purged entry no-ops gracefully if
    /// invoked (see `registerFileRevert` / `registerArtifactRestore`).
    func emptyTrash() {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.emptyTrash()
        } commit: { _ in
        }
    }

    /// The files currently in the archive's `.trash/`, most recently detached first —
    /// the trash sheet's Files section. Empty when no archive is open.
    func trashedFiles() -> [TrashedFile] {
        archive?.trashedFiles() ?? []
    }

    /// Restores a trashed file back onto the artifact it was detached from (the trash
    /// sheet's per-file Restore). **Undoable** via the same `revert` ping-pong as a
    /// detach: modeling the restore as an `.added` change means ⌘Z re-detaches it (back
    /// to the Trash) and ⌘⇧Z restores again — so the in-session undo stack and the
    /// sheet stay two doors to one store (mirrors artifact `restoreFromTrash`).
    func restoreFile(_ trashed: TrashedFile) {
        mutate(unopened: "Open an archive before restoring.") { archive in
            try archive.restoreFile(trashed.uid)
        } commit: { [self] entry in
            registerFileRevert(
                FileChange(artifactID: trashed.artifactUID, operation: .added(entry)),
                actionName: "Restore File")
            bumpAndRefresh()
        }
    }

    /// Permanently deletes one trashed file (the per-row "Delete Permanently") —
    /// irreversible; the bytes leave the package.
    func deleteFileFromTrash(_ uid: FileID) {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.deleteFileFromTrash(uid)
        } commit: { _ in
        }
    }
}

import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Menu-command routing (UI audit F6)

    /// An artifact-scoped verb the menu bar wants run against `selectedArtifact`.
    /// The detail view observes it and drives its own sheet state. Attach and
    /// Delete are routed separately (`beginAttachOrScan` / `pendingArtifactDeletion`).
    enum ArtifactCommand { case addEvent, addPlace, addPerson, editTranscript }

    /// A per-file verb the menu bar wants run against `selectedFile`. The detail
    /// view (which owns the file selection and the preview/export handlers)
    /// observes and dispatches it.
    enum FileCommand {
        case openSeparateWindow, openInDefaultApp, saveCopy, replace, delete
    }

    /// Requests an artifact-scoped command from the menu bar.
    func requestArtifactCommand(_ command: ArtifactCommand) { pendingArtifactCommand = command }

    /// Requests a per-file command from the menu bar.
    func requestFileCommand(_ command: FileCommand) { pendingFileCommand = command }

    /// Requests confirm-and-delete of the selected artifact from the menu bar.
    func requestDeleteSelectedArtifact() { pendingArtifactDeletion = true }

    /// Requests an inspector-visibility toggle from the menu bar.
    func requestInspectorToggle() { pendingInspectorToggle = true }

    // MARK: - Adding media: the file importer and Continuity Camera

    /// Presents the importer in add-media mode (⌘I / + button): picked files
    /// become new artifacts.
    func beginAddMedia() {
        importMode = .addMedia
        isImporterPresented = true
    }

    /// The toolbar **+**: presents one menu offering **Add Media…** (the file
    /// importer) alongside the Continuity Camera scan options, so adding from disk
    /// and scanning a new artifact live in a single connected menu rather than a
    /// floating pop-up. A scan is routed through the same `ingest` path as Add
    /// Media, so it's metadata-extracted and undoable (⌘Z). Falls back to the plain
    /// importer if no scanner is wired (e.g. before the view appears).
    func beginAddOrScan() {
        guard archive != nil else {
            actionError = "Open an archive before adding media."
            return
        }
        guard let continuityScanner else {
            beginAddMedia()
            return
        }
        continuityScanner.requestAddOrScan(
            leadingTitle: "Add Artifact…",
            onChooseFiles: { [weak self] in self?.beginAddMedia() },
            onScanned: { [weak self] url in self?.ingestScanned([url], mode: .addMedia) })
    }

    /// The per-artifact **Attach File…**: presents **one** connected menu offering
    /// *Attach File…* (the importer) alongside the Continuity Camera scan options, so
    /// attaching from disk and scanning a file into the existing artifact `id` live in
    /// a single connected menu — never a SwiftUI menu that pops a second AppKit menu
    /// (a slice 32 follow-up). Mirrors `beginAddOrScan`; a scan routes through the same
    /// `attach` path (metadata-extracted, undoable), the new file taking the default
    /// role, corrected afterward via the per-file menu. Falls back to the plain
    /// importer if no scanner is wired (e.g. before the view appears).
    func beginAttachOrScan(to id: ArtifactID) {
        guard archive != nil else {
            actionError = "Open an archive before attaching files."
            return
        }
        guard let continuityScanner else {
            beginAttach(to: id)
            return
        }
        continuityScanner.requestAddOrScan(
            leadingTitle: "Attach File…",
            onChooseFiles: { [weak self] in self?.beginAttach(to: id) },
            onScanned: { [weak self] url in self?.ingestScanned([url], mode: .attach(to: id)) })
    }

    /// Presents the importer in attach mode: picked files are attached to the
    /// artifact `id` under the default role (the per-artifact "Attach File…"
    /// action in the detail view). The role is corrected afterward via the
    /// per-file menu (slice 32).
    func beginAttach(to id: ArtifactID) {
        importMode = .attach(to: id)
        isImporterPresented = true
    }

    /// Presents the importer in replace mode: the picked file's content overwrites
    /// the existing file `fileID` on artifact `artifactID`, preserving its uid/path
    /// (the per-file "Replace…" action). Undoable.
    func beginReplace(fileID: FileID, artifactID: ArtifactID) {
        importMode = .replace(fileID: fileID, artifactID: artifactID)
        isImporterPresented = true
    }

    // MARK: - Sheets

    /// Presents the integrity-report sheet (File ▸ Verify Integrity…). The sheet
    /// runs the verification itself, off this synchronous call.
    func beginVerifyIntegrity() {
        isShowingIntegrityReport = true
    }

    /// Presents the trash sheet (File ▸ Show Trash…).
    func beginShowTrash() {
        isShowingTrash = true
    }

    // MARK: - Navigation

    /// Requests a cross-tab jump to the People tab with `id` selected (the resolved-
    /// mention chip's tap). Sets the one-shot `pendingPersonNavigation` intent the
    /// container observes.
    func navigateToPerson(_ id: PersonID) {
        pendingPersonNavigation = id
    }

    /// Requests a cross-tab jump to the Artifacts tab with `id` selected (a person
    /// Sources row's tap, slice 42b — the mirror of `navigateToPerson`). Sets the
    /// one-shot `pendingArtifactNavigation` intent the container observes.
    func navigateToArtifact(_ id: ArtifactID) {
        pendingArtifactNavigation = id
    }
}

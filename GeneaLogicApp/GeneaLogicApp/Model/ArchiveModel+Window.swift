import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Commands (slice 82)

    /// A command waiting for the view that owns it. The fresh `id` makes every request a
    /// new value, so asking for the same command twice runs it twice.
    struct PendingCommand: Equatable {
        let id = UUID()
        let command: ArchiveCommand
        let subject: CommandSubject
    }

    /// Everything command availability depends on, read from this window's state.
    var commandContext: CommandContext {
        CommandContext(
            hasArchive: archive != nil, activeTab: activeTab,
            selectedArtifact: selectedArtifact, selectedFile: selectedFile,
            selectedPerson: selectedPerson, personCount: persons.count,
            isPresentingModal: isPresentingModal, inspectorVisible: inspectorVisible)
    }

    /// Whether a sheet, dialog, alert or panel is up in this window: the ones this model
    /// drives, and the ones views report (`reportsModal`).
    var isPresentingModal: Bool {
        !presentedModals.isEmpty || isImporterPresented || isShowingIntegrityReport
            || isShowingTrash || isCreatingPerson || isShowingError || isShowingInfo
    }

    /// Runs `command` on `subject`, if it can run now. Commands the model can run itself
    /// run here; one that opens a sheet a view owns is left for that view as
    /// `pendingCommand`.
    func perform(_ command: ArchiveCommand, on subject: CommandSubject = .archive) {
        guard commandContext.canPerform(command, on: subject) else { return }
        switch command {
        case .addArtifact:
            pendingTab = .artifacts
            beginAddMedia()
        case .newPerson:
            pendingTab = .people
            isCreatingPerson = true
        case .verifyIntegrity: beginVerifyIntegrity()
        case .showTrash: beginShowTrash()
        case .showTab(let tab): pendingTab = tab
        // Straight to the file importer, *not* the Continuity connected menu: an AppKit
        // `popUpContextMenu` invoked from a menu-bar command has no anchor view and
        // floats as a disconnected menu. The in-pane Attach File… keeps the scan options
        // (`beginAttachOrScan`), where the connected menu anchors correctly.
        case .attachFile:
            if case .artifact(let id) = subject { beginAttach(to: id) }
        default:
            pendingCommand = PendingCommand(command: command, subject: subject)
        }
    }

    /// Takes the pending command if `handles` says the calling view runs it, clearing it
    /// so it runs once. A view calls this from its `onChange(of: pendingCommand)`.
    func claimPendingCommand(
        _ handles: (ArchiveCommand) -> Bool
    ) -> (command: ArchiveCommand, subject: CommandSubject)? {
        guard let pending = pendingCommand, handles(pending.command) else { return nil }
        pendingCommand = nil
        return (pending.command, pending.subject)
    }

    /// Records whether the modal `token` stands for is up (`reportsModal`).
    func setModal(_ token: UUID, presented: Bool) {
        if presented {
            presentedModals.insert(token)
        } else {
            presentedModals.remove(token)
        }
    }

    // MARK: - Adding media: the file importer and Continuity Camera

    /// Presents the importer in add-media mode (⇧⌘I / + button): picked files
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

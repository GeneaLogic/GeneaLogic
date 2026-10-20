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

    /// Routes a freshly captured Continuity Camera file through new-artifact
    /// ingest or attach-to-existing. `.replace` is never a scan target.
    ///
    /// **A scan is deleted only once it has landed** (slice 67). Until then
    /// this removed the temp file as soon as `ingest`/`attach` returned, and
    /// since 52 they only enqueue their write — so the engine found the file
    /// already gone: an empty artifact, and a capture that existed nowhere else.
    /// A scan the engine refuses is **kept** and the error offers it in Finder
    /// (fork b, settled the other way on `/code-review`): a refusal can be
    /// transient — `archiveBusy` after another process holds the lock for five
    /// seconds — and a document scan may be many pages.
    func ingestScanned(_ urls: [URL], mode: ImportMode) {
        let extractor = MetadataExtractors.makeDefault()
        switch mode {
        case .addMedia:
            consumeScans(urls, unopened: "Open an archive before adding media.") { archive in
                Self.ingestEach(urls, into: archive, extractor: extractor)
            } commit: { [self] outcomes in
                commitIngest(outcomes)
            }
        case .attach(let id):
            consumeScans(urls, unopened: "Open an archive before attaching files.") { archive in
                Self.attachEach(urls, to: id, in: archive, extractor: extractor)
            } commit: { [self] outcomes in
                commitAttach(outcomes, to: id)
            }
        case .replace:
            break
        }
    }

    /// What the error alert says: `actionError`, then — while any refused scan
    /// is kept — that it was kept. Composed here rather than written into
    /// `actionError` once, so a later error replacing the text cannot drop it.
    var errorMessage: String {
        let note: String? =
            switch keptScans.count {
            case 0: nil
            case 1: "The scan was kept. Show it in Finder to add it again."
            default: "The scans were kept. Show them in Finder to add them again."
            }
        return [actionError, note].compactMap(\.self).joined(separator: "\n\n")
    }

    /// The scan path's `mutate`: runs `each` — `ingestEach` or `attachEach`,
    /// whose outcomes line up with `urls` — deletes the scans that landed, inside
    /// the write, and keeps the rest.
    ///
    /// Owns its "no archive" case rather than leaving it to `mutate`, whose early
    /// return would skip the work closure — and with it any decision about the
    /// scan at all.
    private func consumeScans<Outcome: FileOutcome>(
        _ urls: [URL], unopened: String,
        each: @escaping @Sendable (Archive) -> [Outcome],
        commit: @escaping @MainActor ([Outcome]) -> Void
    ) {
        guard archive != nil else {
            actionError = unopened
            keepScans(urls)
            return
        }
        mutate(unopened: unopened) { archive in
            let outcomes = each(archive)
            var kept: [URL] = []
            for (url, outcome) in zip(urls, outcomes) {
                if outcome.failure == nil { Self.discardScan(at: url) } else { kept.append(url) }
            }
            return (outcomes: outcomes, kept: kept)
        } commit: { [self] result in
            commit(result.outcomes)
            if !result.kept.isEmpty { keepScans(result.kept) }
        }
    }

    /// Adds `urls` to the scans the alert offers.
    private func keepScans(_ urls: [URL]) {
        keptScans += urls.filter { !keptScans.contains($0) }
    }

    /// Deletes a scan that landed, and the per-capture folder
    /// `ContinuityScanner` wrote it into. `rmdir` only removes an empty
    /// directory, so a URL that did not come from the scanner keeps its parent.
    private nonisolated static func discardScan(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        rmdir(url.deletingLastPathComponent().path)
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

    /// Routes a completed importer selection to new-artifact ingest,
    /// attach-to-existing, or replace, per the mode set when the importer was presented.
    func handleImport(_ urls: [URL]) {
        switch importMode {
        case .addMedia:
            ingest(urls)
        case .attach(let id):
            attach(urls, to: id)
        case .replace(let fileID, let artifactID):
            if let url = urls.first { replaceFile(fileID, in: artifactID, with: url) }
        }
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

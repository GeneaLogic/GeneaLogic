import AppKit
import GeneaLogicArchive
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Copy (slice 87, G6)

    /// The browse summary behind `id`, as the sidebar shows it.
    func summary(of id: ArtifactID) -> ArtifactSummary? {
        artifacts.first { $0.uid == id }
    }

    /// The browse summary behind `id`, as the sidebar shows it.
    func summary(of id: PersonID) -> PersonSummary? {
        persons.first { $0.uid == id }
    }

    /// What ⌘C on the sidebar's selected row copies: an artifact or a person, as a line of
    /// text (`CopiedRecord`). Empty for any other row, which leaves Edit ▸ Copy dimmed.
    func copiedRecords(for item: SidebarItem?) -> [CopiedRecord] {
        let text: String? =
            switch item {
            case .artifact(let id): summary(of: id)?.copyText
            case .person(let id): summary(of: id)?.copyText
            case .review, .trash, nil: nil
            }
        return text.map { [CopiedRecord(text: $0)] } ?? []
    }

    /// A row's Copy, from its context menu: the same line ⌘C copies.
    func copyText(of subject: CommandSubject) {
        let text: String? =
            switch subject {
            case .artifact(let id): summary(of: id)?.copyText
            case .person(let id): summary(of: id)?.copyText
            default: nil
            }
        guard let text else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// A file's Copy: the file itself, as Finder copies one, so a paste into Finder or Mail
    /// gets it under the user's name. Its bytes go out as a copy (`temporaryCopy`), never
    /// the package's own.
    func copyFile(_ fileID: FileID, of artifactID: ArtifactID) {
        guard
            let name = fullArtifact(artifactID)?.files.first(where: { $0.uid == fileID })?
                .originalName,
            let copy = temporaryCopy(of: fileID, in: artifactID, originalName: name)
        else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([copy as NSURL])
    }

    // MARK: - Quick Look (slice 87, G16)

    /// Space and ⌘Y on an artifact, and Quick Look on one of its files: the panel on the
    /// artifact's files, from `file`, else the one the detail previews, else the first. A
    /// second press closes it.
    func toggleQuickLook(_ artifactID: ArtifactID, at file: FileID? = nil) {
        let (items, index) = quickLookItems(of: artifactID, at: file)
        QuickLookPanel.shared.toggle(items, at: index, for: self)
    }

    /// Moves the panel to the newly selected artifact while it is up, as Finder's follows
    /// its selection. With nothing to show, the panel closes.
    func quickLookFollowSelection(_ artifactID: ArtifactID?) {
        let (items, index) = artifactID.map { quickLookItems(of: $0) } ?? ([], 0)
        QuickLookPanel.shared.follow(items, at: index, for: self)
    }

    private func quickLookItems(
        of artifactID: ArtifactID, at file: FileID? = nil
    ) -> ([QuickLookPanel.Item], Int) {
        let files = fullArtifact(artifactID)?.files ?? []
        let items = files.map { entry in
            QuickLookPanel.Item(name: entry.originalName) { [weak self] in
                self?.temporaryCopy(of: entry.uid, in: artifactID, originalName: entry.originalName)
            }
        }
        let start = file ?? (artifactID == selectedArtifact ? selectedFile : nil)
        return (items, start.flatMap { id in files.firstIndex { $0.uid == id } } ?? 0)
    }

    /// Quick Look on a trashed artifact (slice 87, fork 4): what its payload still holds,
    /// read from `.trash/`, so you can see what Delete Permanently… would destroy.
    func quickLookTrashed(_ artifactID: ArtifactID) {
        let items = (archive?.trashedFileContents(ofArtifact: artifactID) ?? []).map(trashItem)
        QuickLookPanel.shared.toggle(items, at: 0, for: self)
    }

    /// Quick Look on a trashed file. A record-only one has no bytes, and its item is dimmed
    /// (`canQuickLookTrashed`).
    func quickLookTrashed(_ file: FileID) {
        let items = archive?.trashedFileContent(file).map { [trashItem($0)] } ?? []
        QuickLookPanel.shared.toggle(items, at: 0, for: self)
    }

    /// Whether a trashed file has bytes to show: not a record-only entry.
    func canQuickLookTrashed(_ file: FileID) -> Bool {
        trashedFilesWithContent.contains(file)
    }

    private func trashItem(_ content: TrashedFileContent) -> QuickLookPanel.Item {
        QuickLookPanel.Item(name: content.originalName) { [weak self] in
            self?.temporaryCopy(
                of: content.url, id: content.uid.raw, originalName: content.originalName)
        }
    }
}

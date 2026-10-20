import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Browsing, sorting and filtering

    /// Whether any filter is active — a non-blank search **or** a selected tag.
    var isFiltering: Bool {
        !searchText.trimmed.isEmpty || !selectedTags.isEmpty
    }

    /// What the browser actually shows: the full list when no filter is active,
    /// otherwise the current filtered results — then ordered by the active sort.
    var displayedArtifacts: [ArtifactSummary] {
        sorted(isFiltering ? filterResults : artifacts)
    }

    /// How the browse list can be ordered (sidebar Sort menu, UI audit F7). Each
    /// case sorts a field already on `ArtifactSummary`, so sorting is client-side —
    /// no engine query.
    enum ArtifactSortKey: String, CaseIterable, Identifiable {
        case title
        case dateAdded
        case primaryDate

        var id: String { rawValue }

        /// The menu's section-row label for picking this key.
        var label: String {
            switch self {
            case .title: "Title"
            case .dateAdded: "Date Added"
            case .primaryDate: "Primary Date"
            }
        }

        /// Direction labels, phrased for the key (clearer than a bare
        /// "Ascending/Descending" for dates).
        var ascendingLabel: String {
            switch self {
            case .title: "A to Z"
            case .dateAdded: "Oldest First"
            case .primaryDate: "Earliest First"
            }
        }
        var descendingLabel: String {
            switch self {
            case .title: "Z to A"
            case .dateAdded: "Newest First"
            case .primaryDate: "Latest First"
            }
        }
    }

    /// Orders `list` by the active sort key + direction. Stable: equal primary keys
    /// fall back to title then uid so the order never jitters. For `.primaryDate`,
    /// undated artifacts sort **last** regardless of direction.
    private func sorted(_ list: [ArtifactSummary]) -> [ArtifactSummary] {
        let ascending = sortAscending
        return list.sorted { a, b in
            switch sortKey {
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                if r != .orderedSame {
                    return ascending ? r == .orderedAscending : r == .orderedDescending
                }
            case .dateAdded:
                // The uid is a time-ordered UUIDv7, so its raw string sorts by creation time.
                if a.uid.raw != b.uid.raw {
                    return ascending ? a.uid.raw < b.uid.raw : a.uid.raw > b.uid.raw
                }
            case .primaryDate:
                // Order by the EDTF-parsed chronological bound, not the raw string —
                // a lexicographic compare mis-sorts masked/approximate dates (e.g.
                // "19XX" vs "1920"). Undated *and* unparseable-as-date values sort last.
                let x = a.primaryDate.flatMap { EDTFDate.parse($0)?.sortBound }
                let y = b.primaryDate.flatMap { EDTFDate.parse($0)?.sortBound }
                switch (x, y) {
                case let (x?, y?) where x != y:
                    return ascending ? x < y : x > y
                case (nil, _?): return false  // undated → after a dated one
                case (_?, nil): return true  // dated → before an undated one
                default: break  // both nil, or equal bounds → fall through to tiebreak
                }
            }
            // Tiebreak: title, then uid — deterministic and stable.
            let t = a.title.localizedStandardCompare(b.title)
            if t != .orderedSame { return t == .orderedAscending }
            return a.uid.raw < b.uid.raw
        }
    }

    /// Every distinct tag across the open archive's artifacts, with how many
    /// artifacts carry it, sorted by tag name. Drives the toolbar Filter menu.
    /// Tags are compared case-insensitively but presented in their first-seen
    /// original casing. Derived from the loaded browse summaries — no extra query.
    var tagFacets: [TagFacet] {
        var counts: [String: (display: String, count: Int)] = [:]
        for artifact in artifacts {
            for tag in artifact.tags {
                let key = tag.lowercased()
                if let existing = counts[key] {
                    counts[key] = (existing.display, existing.count + 1)
                } else {
                    counts[key] = (tag, 1)
                }
            }
        }
        return
            counts
            .map { TagFacet(key: $0.key, display: $0.value.display, count: $0.value.count) }
            .sorted { $0.display.localizedStandardCompare($1.display) == .orderedAscending }
    }

    /// One selectable tag in the Filter menu: its lowercased match `key`, the
    /// `display` casing to show, and how many artifacts carry it.
    struct TagFacet: Identifiable {
        let key: String
        let display: String
        let count: Int
        var id: String { key }
    }

    /// What a completed import should do — set when the (single, shared) importer
    /// is presented, read by `handleImport`. Only one `.fileImporter` may be live
    /// per view hierarchy, so add-media and attach-to-existing multiplex this one.
    enum ImportMode: Equatable {
        /// Each picked file becomes a *new* artifact (the `+` / drag-in path).
        case addMedia
        /// Each picked file is attached to an existing artifact under the default
        /// role (`Self.defaultFileRole`); the user re-assigns the role afterward
        /// via the per-file menu (slice 32 — a sensible default in all cases plus
        /// a way to change it later, rather than an inconsistent pre-pick).
        case attach(to: ArtifactID)
        /// The first picked file replaces the content of an existing file entry
        /// (any extra selection is ignored — replace targets one file).
        case replace(fileID: FileID, artifactID: ArtifactID)
    }

    /// The role every newly added file gets — new-artifact ingest and
    /// attach-to-existing alike (slice 32). Chosen as the archival original by
    /// default; correct it afterward with `setFileRole` (the per-file Role menu).
    ///
    /// `nonisolated` because `ingest`/`attach` read it inside `mutate`'s off-main
    /// work closure (52). It is an immutable value in a `Sendable` enum; only the
    /// module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` put it on the actor.
    nonisolated static let defaultFileRole: FileRole = .preservationMaster

    /// Runs the active filter through the engine's index-backed
    /// `artifacts(matching:)` into `filterResults`: free text over title + inline
    /// transcript + notes + the text of any `role: .transcript` *file* (§5.1),
    /// AND an exact whole-tag match for every selected tag. With no filter active
    /// it clears the results (`displayedArtifacts` then shows the full list).
    func applyFilters() {
        let query = searchText.trimmed
        guard let archive, isFiltering else {
            filterResults = []
            return
        }
        filterResults = archive.artifacts(
            matching: ArtifactQuery(
                text: query.isEmpty ? nil : query,
                tags: Array(selectedTags)))
    }

    /// Toggles tag `key` (already lowercased) in the Filter menu and re-runs the
    /// filter.
    func toggleTag(_ key: String) {
        if selectedTags.contains(key) {
            selectedTags.remove(key)
        } else {
            selectedTags.insert(key)
        }
        applyFilters()
    }

    /// Clears the tag filter (leaves the text search untouched) and re-runs.
    func clearTagFilter() {
        selectedTags.removeAll()
        applyFilters()
    }

    // MARK: - Artifacts and files (read, edit, delete — undoable)

    /// Fetches the full `Artifact` record behind a browse summary, for editing.
    /// The browse list carries only the derived `ArtifactSummary`; the editor
    /// needs the whole record (notes, language, events, …). `nil` if the archive
    /// isn't open or the id is unknown.
    func fullArtifact(_ id: ArtifactID) -> Artifact? {
        archive?.artifact(withID: id)
    }

    /// The on-disk URL of an attached file's bytes inside the package, for the
    /// **inline** (in-process) Quick Look preview. `nil` if nothing is open or the
    /// id is unknown. Read-only — see the engine's `fileURL(of:in:)`.
    func fileURL(of fileID: FileID, in artifactID: ArtifactID) -> URL? {
        archive?.fileURL(of: fileID, in: artifactID)
    }

    /// Writes a **copy** of an attached file to `destination` (the "Save a Copy…"
    /// export). Never hands out the original inside the package. Errors → `actionError`.
    func exportFile(_ fileID: FileID, in artifactID: ArtifactID, to destination: URL) {
        guard let source = fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            actionError = describe(error)
        }
    }

    /// A session-temp **copy** of an attached file under `originalName`, for handing
    /// to another process — "Open in Default App" or a pop-out preview window — so
    /// the package original is never exposed (an external app could otherwise mutate
    /// package contents and desync the manifest/index). `nil` on failure (which also
    /// sets `actionError`). Copies are namespaced by file id under the temp dir, so
    /// reopening the same file reuses one path.
    func temporaryCopy(of fileID: FileID, in artifactID: ArtifactID, originalName: String) -> URL? {
        guard let source = fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return nil
        }
        let name = originalName.isEmpty ? source.lastPathComponent : originalName
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneaLogicPreview", isDirectory: true)
            .appendingPathComponent(fileID.raw, isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            actionError = describe(error)
            return nil
        }
    }

    /// Re-runs the metadata extractor against an **already-stored** file on demand
    /// and drops any embedded metadata into the session suggestion cache for its
    /// artifact (`capturedMetadata`) — the on-demand counterpart to ingest-time
    /// capture, lifting the limit that suggestions only ever appeared for files
    /// added *this* session.
    ///
    /// Nothing is written to the record: the captured values stay read-only
    /// suggestions (ARCHITECTURE.md §6.4, the scan-date trap), promoted into an
    /// `Event`/`Location` only through the human-confirmed Apply step. Reads the
    /// package file directly (the app holds the archive's security scope). A file
    /// with no extractable metadata reports it via the benign `actionInfo`.
    func scanFileForMetadata(_ fileID: FileID, in artifactID: ArtifactID, originalName: String) {
        guard let archive else { return }
        guard let extractor = MetadataExtractors.makeDefault() else {
            actionError = "Metadata extraction isn't available on this platform."
            return
        }
        guard let url = archive.fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return
        }
        do {
            let embedded = try extractor.extract(from: url)
            if embedded.isEmpty {
                showInfo(
                    "No embedded metadata found in “\(originalName).”",
                    title: "Scan for Metadata")
            } else {
                capturedMetadata[artifactID] = embedded
            }
        } catch {
            actionError = describe(error)
        }
    }

    /// Applies `mutate` to an artifact's record through the engine — the **sole**
    /// in-place writer — then refreshes the browse list so the change is visible
    /// (a renamed title, a changed tier, …). The selection is keyed by
    /// `ArtifactID`, so it survives the refresh. Errors surface as `actionError`.
    ///
    /// Provenance is intentionally left untouched: an `Artifact`'s `provenance`
    /// records its *creation*, and `updateMetadata` only bumps `schemaVersion`.
    /// Callers that append a new assertion (the apply-suggestion path) do so under
    /// the artifact's existing human/asserted provenance umbrella — the model has
    /// no per-event provenance, and a human-reviewed suggestion is an honest human
    /// assertion, not a machine one (ARCHITECTURE.md §6.4).
    ///
    /// The edit is **undoable**: the full record is snapshotted before and after,
    /// and an inverse registered on the window's `UndoManager` under `actionName`
    /// (so the Edit menu reads "Undo \(actionName)"). Undo/redo are themselves
    /// ordinary engine writes that restore a snapshot — the engine stays the sole
    /// writer (§7).
    /// **`edit` is `@Sendable` because it runs off the main actor** (52), applied
    /// to the record the engine reads *under the archive lock*. Keeping it there
    /// rather than applying it to a main-actor snapshot is the point: a snapshot
    /// taken before a five-second wait for another process, then written back
    /// wholesale, would silently clobber whatever that process committed in the
    /// meantime. Every call site passes a closure over value types, so the
    /// annotation costs nothing.
    ///
    /// **The undo snapshot is taken on the write queue, for the same reason**
    /// (52's `/code-review`). Reading `before` on the main actor read it *at
    /// enqueue time*, so two edits to one record issued back to back both
    /// snapshotted the original: the second edit's undo restored a state that
    /// skipped the first, and one ⌘Z silently discarded two edits. Inside `work`
    /// the serial queue guarantees the first edit has already committed.
    func updateMetadata(
        of id: ArtifactID, actionName: String = "Edit",
        _ edit: @escaping @Sendable (inout Artifact) -> Void
    ) {
        guard archive?.artifact(withID: id) != nil else {
            actionError =
                archive == nil
                ? "Open an archive before editing." : "Couldn't load this artifact to edit."
            return
        }
        mutate(unopened: "Open an archive before editing.") { archive in
            let before = archive.artifact(withID: id)
            try archive.updateMetadata(of: id, edit)
            return (before, archive.artifact(withID: id))
        } commit: { [self] before, after in
            if let before, let after {
                registerArtifactRestore(
                    of: id, to: before, redoingTo: after, actionName: actionName)
            }
            bumpAndRefresh()
        }
    }

    /// Registers an undo that restores artifact `id` to the `target` snapshot, and
    /// (when invoked) re-registers the symmetric redo to `redoTarget` — so undo and
    /// redo ping-pong indefinitely. Restoring a whole-record snapshot is safe for
    /// metadata edits: they never touch `files`, so the snapshot's file list always
    /// matches what's on disk (file *content* changes go through `revert`, not here).
    private func registerArtifactRestore(
        of id: ArtifactID, to target: Artifact, redoingTo redoTarget: Artifact, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
            model.registerArtifactRestore(
                of: id, to: redoTarget, redoingTo: target, actionName: actionName)
            model.mutate(unopened: "Open an archive before editing.") { archive in
                try archive.updateMetadata(of: id) { $0 = target }
            } commit: { _ in
                model.bumpAndRefresh()
            }
        }
    }

    /// Replaces the content of `fileID` on `artifactID` with the file at `url`
    /// (the per-file "Replace…" action, via the importer), undoably.
    /// The security scope is opened and closed **inside** `work` (52): the copy
    /// now happens on the write queue, so a `defer` out here would drop the scope
    /// while the copy is still reading the source.
    private func replaceFile(_ fileID: FileID, in artifactID: ArtifactID, with url: URL) {
        mutate(unopened: "Open an archive before replacing files.") { archive in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try archive.replaceFile(fileID, in: artifactID, copyingFrom: url)
        } commit: { [self] change in
            registerFileRevert(change, actionName: "Replace File")
            bumpAndRefresh()
        }
    }

    /// Detaches `fileID` from `artifactID` (the per-file "Delete" action), undoably —
    /// the engine stages the file's bytes so the deletion can be reverted.
    func detachFile(_ fileID: FileID, from artifactID: ArtifactID) {
        mutate(unopened: "Open an archive before deleting files.") { archive in
            try archive.detachFile(fileID, in: artifactID)
        } commit: { [self] change in
            registerFileRevert(change, actionName: "Delete File")
            bumpAndRefresh()
        }
    }

    /// Changes `fileID`'s role on `artifactID` (the per-file Role menu, slice 32),
    /// undoably. A no-op change (the role is already `role`) does nothing and
    /// registers no undo step. Content, uid, and path are untouched.
    func setFileRole(_ fileID: FileID, in artifactID: ArtifactID, to role: FileRole) {
        mutate(unopened: "Open an archive before changing a file’s role.") { archive in
            try archive.setFileRole(fileID, in: artifactID, to: role)
        } commit: { [self] prior in
            guard prior != role else { return }
            registerFileRoleRestore(fileID, in: artifactID, to: prior, redoingTo: role)
            bumpAndRefresh()
        }
    }

    /// Registers an undo that sets `fileID`'s role back to `role`, then re-registers
    /// the symmetric redo (`redoRole`) — so a role change undoes/redoes indefinitely,
    /// like the metadata and file-revert paths. If the file or artifact has since
    /// gone out-of-band, the step no-ops **gracefully** (a benign notice, not an
    /// error), with the stack advancing.
    private func registerFileRoleRestore(
        _ fileID: FileID, in artifactID: ArtifactID, to role: FileRole, redoingTo redoRole: FileRole
    ) {
        registerUndoStep(actionName: "Change File Role") { model in
            // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
            model.registerFileRoleRestore(fileID, in: artifactID, to: redoRole, redoingTo: role)
            model.mutate(unopened: "Open an archive before changing a file’s role.") { archive in
                _ = try archive.setFileRole(fileID, in: artifactID, to: role)
            } commit: { _ in
                model.bumpAndRefresh()
            } failure: { error in
                switch error {
                case ArchiveError.fileNotFound, ArchiveError.artifactNotFound:
                    model.showInfo(
                        "That file is no longer in the archive, so its role can’t be changed back.",
                        title: "Can’t Change Role")
                    return true
                default:
                    return false
                }
            }
        }
    }

    /// Registers an undo that reverts `change` through the engine and re-registers
    /// the inverse for redo (`Archive.revert` returns the opposite change), so file
    /// add/remove/replace undo and redo ping-pong like the metadata path above.
    ///
    /// A detached file's bytes live in the persistent `.trash/` (not in-session temp),
    /// so an undo/redo step can find its bytes **permanently removed** (Empty Trash /
    /// Delete Permanently from the sheet) or its file/artifact gone out-of-band. Those
    /// no-op **gracefully**: a benign notice (not an error), with no inverse
    /// re-registered, so the stack simply advances — exactly like the artifact
    /// delete/restore path (the menu title can't be relabeled after the fact, NSUndoManager).
    func registerFileRevert(_ change: FileChange, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.revertFile(change, actionName: actionName)
        }
    }

    /// Carries a counterpart's payload from the `commit` that computes it to the
    /// undo step that was registered before it existed.
    ///
    /// **The file paths are the one place the general rule needs help.** Every
    /// other counterpart is known up front (a snapshot, a uid, a captured
    /// record), so it can be registered synchronously with its payload in hand.
    /// A file revert's inverse is *computed by the engine* — reverting a detach
    /// re-attaches the bytes and mints a fresh trash entry for the redo to find,
    /// and nothing can predict that id. Registering after the await would file
    /// the step on the wrong stack (see *Undo across the actor hop* in
    /// `ArchiveModel.swift`), so the registration goes up on time and reads its
    /// payload from here when it runs.
    private final class PendingFileChange {
        var change: FileChange?
    }

    /// The artifact-deletion twin of `PendingFileChange`: re-deleting an artifact
    /// stages a *new* folder in the trash, so the restore that reverses it can't
    /// be described until the delete has run.
    private final class PendingDeletion {
        var deletion: ArtifactDeletion?
    }

    /// Reverts `change` and registers the step that reverses *that* — the body
    /// behind both a fresh registration and a promised one, so the ping-pong has
    /// one implementation rather than two that must agree.
    private func revertFile(_ change: FileChange, actionName: String) {
        let inverse = PendingFileChange()
        // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
        registerFileRevert(pending: inverse, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.revert(change)
        } commit: { [self] produced in
            inverse.change = produced
            bumpAndRefresh()
        } failure: { [self] error in
            switch error {
            case ArchiveError.fileTrashEntryNotFound:
                showInfo(
                    "That file was permanently removed from the Trash, so it can’t be brought back.",
                    title: "Can’t Restore File")
            case ArchiveError.artifactNotFound:
                showInfo(
                    "The artifact this file belonged to no longer exists, so the file can’t be restored.",
                    title: "Can’t Restore File")
            case ArchiveError.fileNotFound:
                showInfo(
                    "That file is no longer attached to the artifact.", title: "Already Removed")
            default:
                return false
            }
            return true
        }
    }

    /// Registers the reverse of a revert whose payload is still being computed.
    /// If the revert failed, the promise stays empty and this step no-ops — the
    /// same graceful advance the purged-trash cases already take.
    private func registerFileRevert(pending: PendingFileChange, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            guard let change = pending.change else { return }
            model.revertFile(change, actionName: actionName)
        }
    }

    /// Deletes the artifact `id` and its files (the sidebar "Delete Artifact"
    /// action), undoably — the engine stages the whole folder so the deletion can be
    /// reverted. If the deleted artifact was the selection, the detail pane falls
    /// back to its placeholder on its own (the id stops resolving).
    func deleteArtifact(_ id: ArtifactID) {
        mutate(unopened: "Open an archive before deleting.") { archive in
            try archive.removeArtifact(id)
        } commit: { [self] deletion in
            registerArtifactRestore(of: id, deletion: deletion, actionName: "Delete Artifact")
            bumpAndRefresh()
        }
    }

    /// Registers an undo that **restores** a deleted artifact, then registers the
    /// symmetric redo (delete again, producing a fresh staged folder) — the undo
    /// side of a *deletion*. Undo and redo ping-pong as in the file/metadata paths.
    /// `actionName` names the originating action in the Edit menu ("Delete Artifact").
    func registerArtifactRestore(
        of id: ArtifactID, deletion: ArtifactDeletion, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            model.restoreArtifact(deletion, of: id, actionName: actionName)
        }
    }

    /// The promised-payload variant, for a redelete whose staged folder isn't
    /// known until the delete lands. An empty promise means the delete failed, so
    /// there is nothing to restore and the step no-ops — see `PendingFileChange`
    /// for why this shape exists at all.
    private func registerArtifactRestore(
        of id: ArtifactID, pending: PendingDeletion, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            guard let deletion = pending.deletion else { return }
            model.restoreArtifact(deletion, of: id, actionName: actionName)
        }
    }

    /// Restores `deletion` and registers the redelete that reverses it — the body
    /// both registrations above run, so the ping-pong has one implementation.
    private func restoreArtifact(
        _ deletion: ArtifactDeletion, of id: ArtifactID, actionName: String
    ) {
        // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
        registerArtifactRedelete(of: id, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.restoreArtifact(deletion)
        } commit: { [self] _ in
            bumpAndRefresh()
        } failure: { [self] error in
            // The artifact's bytes were permanently removed (Empty Trash / Delete
            // Permanently) after this undo was registered — there's nothing to bring
            // back. No-op gracefully with a benign notice, not an error. The redo is
            // on the stack (it had to go up before the await), and re-deleting an
            // artifact that was never restored no-ops just as gracefully.
            guard case ArchiveError.trashEntryNotFound = error else { return false }
            showInfo(
                "That artifact was permanently removed from the Trash, so it can’t be "
                    + "brought back.", title: "Can’t Restore Artifact")
            return true
        }
    }

    /// Registers an undo that **deletes** artifact `id`, then registers the
    /// symmetric redo (restore it) — the undo side of an *addition* (and the redo
    /// side of a deletion). `ingest` calls this directly so adding a new artifact is
    /// undoable: the first ⌘Z removes it (the engine stages its folder so it can come
    /// back), ⌘⇧Z restores it (uid faithful). `actionName` names it in the Edit menu
    /// ("Add Artifact" for ingest, "Delete Artifact" when reached via the delete redo).
    func registerArtifactRedelete(of id: ArtifactID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            // This is the one counterpart shape that *must* wait for its payload
            // (the fresh `ArtifactDeletion`), so it takes the same promise route
            // as the file paths.
            let deletion = PendingDeletion()
            model.registerArtifactRestore(of: id, pending: deletion, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.removeArtifact(id)
            } commit: { produced in
                deletion.deletion = produced
                model.bumpAndRefresh()
            } failure: { error in
                // The artifact is already gone (e.g. removed out-of-band) — nothing to
                // delete. No-op gracefully and let the stack advance.
                guard case ArchiveError.artifactNotFound = error else { return false }
                model.showInfo(
                    "That artifact is no longer in the archive.", title: "Already Removed")
                return true
            }
        }
    }

    // MARK: - Ingest and attach

    /// Ingests `urls` (from `.fileImporter` or drag-and-drop) into the open
    /// archive: each becomes a new artifact with the source file attached as its
    /// preservation master.
    ///
    /// Errors for individual files are collected into `actionError` (the most
    /// recent one wins) without stopping the rest of the batch. Refreshes the
    /// artifact list once at the end.
    ///
    /// **Undoable as one step.** Each created artifact registers a "delete me" undo
    /// (`registerArtifactRedelete`); because the whole batch runs in a single
    /// run-loop event, the window's `UndoManager` groups those registrations, so one
    /// ⌘Z removes every artifact the call added and ⌘⇧Z brings them all back (uid
    /// faithful — the engine stages each folder). This is the same event-grouping the
    /// multi-file Attach path relies on.
    /// **The whole batch is one `mutate`** (52), not one per file: the undo
    /// registrations have to land in a single run-loop turn for `NSUndoManager`
    /// to group them, and a hop per file would scatter them across turns — one
    /// ⌘Z per file instead of one for the add. The per-file error collection
    /// moves into the work closure with them and is reported at the end.
    func ingest(_ urls: [URL]) {
        let extractor = MetadataExtractors.makeDefault()
        mutate(unopened: "Open an archive before adding media.") { archive in
            Self.ingestEach(urls, into: archive, extractor: extractor)
        } commit: { [self] outcomes in
            commitIngest(outcomes)
        }
    }

    /// `ingest`'s work: one outcome per URL, **in `urls` order** — the scan path
    /// pairs them back up by position (`consumeScans`).
    private nonisolated static func ingestEach(
        _ urls: [URL], into archive: Archive, extractor: (any MetadataExtractor)?
    ) -> [IngestOutcome] {
        var outcomes: [IngestOutcome] = []
        for url in urls {
            // fileImporter/drag URLs may be security-scoped; the archive needs to
            // read the source file to copy it in.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Set once the artifact exists, so a file that then fails to attach
            // still reports the artifact it left behind (slice 67's
            // `/code-review`): without it, commit never registered the add's
            // undo, and an empty artifact sat in the archive with no ⌘Z.
            var added: ArtifactID?
            do {
                let title = url.deletingPathExtension().lastPathComponent
                let artifact = try archive.addArtifact(
                    // **No source tier.** Ingest cannot know the genre of a file that
                    // was just dragged in, and until 46b it asserted `compiled` anyway
                    // — the lowest tier, and a claim that an original held as an image
                    // is somebody's conclusion. Absent means unstated; the sidebar
                    // surfaces the count so the debt is visible rather than silently
                    // wrong.
                    ArtifactDraft(title: title, mediaType: .image))
                added = artifact.uid
                let attached = try archive.attachFile(
                    copyingFrom: url, to: artifact.uid, role: Self.defaultFileRole,
                    extractor: extractor)
                outcomes.append(
                    .init(artifact: artifact.uid, embedded: attached.embeddedMetadata))
            } catch {
                outcomes.append(.init(artifact: added, failure: error))
            }
        }
        return outcomes
    }

    /// `ingest`'s commit. An artifact whose file failed to attach is registered
    /// and selected like any other — it exists, so it must be undoable — and the
    /// failure is reported beside it.
    private func commitIngest(_ outcomes: [IngestOutcome]) {
        var created: ArtifactID?
        for outcome in outcomes {
            if let failure = outcome.failure { actionError = describe(failure) }
            guard let id = outcome.artifact else { continue }
            if let embedded = outcome.embedded, !embedded.isEmpty {
                capturedMetadata[id] = embedded
            }
            // Make the add undoable: the first undo deletes this artifact (its
            // folder, including the file just attached), redo restores it.
            registerArtifactRedelete(of: id, actionName: "Add Artifact")
            created = id
        }
        bumpAndRefresh()
        // Select the new artifact so its document/inspector shows at once (slice
        // 29). A multi-file add lands on the last one created. Only set when a
        // create actually succeeded, so a wholly-failed ingest leaves selection be.
        if let created { lastCreatedArtifact = created }
    }

    /// What the scan path needs from either outcome type: whether the file landed.
    /// `nonisolated` like the outcomes themselves — it is read inside the write.
    private nonisolated protocol FileOutcome: Sendable {
        var failure: Error? { get }
    }

    /// One file's result from a batch ingest, carried back to the main actor so
    /// the undo registration and the error report happen there, together.
    ///
    /// `nonisolated`: it is *constructed* off-main, inside the work closure, and
    /// only read on the main actor. A pure value type, already `Sendable`.
    private nonisolated struct IngestOutcome: FileOutcome {
        var artifact: ArtifactID?
        var embedded: EmbeddedMetadata?
        var failure: Error?

        init(artifact: ArtifactID, embedded: EmbeddedMetadata?) {
            self.artifact = artifact
            self.embedded = embedded
        }
        /// `artifact` is the one created before the failure, if any.
        init(artifact: ArtifactID?, failure: Error) {
            self.artifact = artifact
            self.failure = failure
        }
    }

    /// Attaches `urls` to the existing artifact `id` under the default role
    /// (`Self.defaultFileRole`, slice 32). Mirrors `ingest`'s per-file error
    /// handling and security scoping, but adds files to an artifact instead of
    /// minting new ones.
    ///
    /// Any embedded metadata the newly attached file carries is captured into the
    /// session cache for `id` (last file wins) — still surfaced read-only, never
    /// auto-applied (ARCHITECTURE.md §6.4).
    /// One `mutate` for the whole batch, for the same undo-grouping reason as
    /// `ingest`.
    private func attach(_ urls: [URL], to id: ArtifactID) {
        let extractor = MetadataExtractors.makeDefault()
        mutate(unopened: "Open an archive before attaching files.") { archive in
            Self.attachEach(urls, to: id, in: archive, extractor: extractor)
        } commit: { [self] outcomes in
            commitAttach(outcomes, to: id)
        }
    }

    /// `attach`'s work: one outcome per URL, in `urls` order (see `ingestEach`).
    private nonisolated static func attachEach(
        _ urls: [URL], to id: ArtifactID, in archive: Archive,
        extractor: (any MetadataExtractor)?
    ) -> [AttachOutcome] {
        var outcomes: [AttachOutcome] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let attached = try archive.attachFile(
                    copyingFrom: url, to: id, role: Self.defaultFileRole,
                    extractor: extractor)
                outcomes.append(
                    .init(entry: attached.entry, embedded: attached.embeddedMetadata))
            } catch {
                outcomes.append(.init(failure: error))
            }
        }
        return outcomes
    }

    /// `attach`'s commit.
    private func commitAttach(_ outcomes: [AttachOutcome], to id: ArtifactID) {
        for outcome in outcomes {
            if let failure = outcome.failure { actionError = describe(failure) }
            guard let entry = outcome.entry else { continue }
            if let embedded = outcome.embedded, !embedded.isEmpty {
                capturedMetadata[id] = embedded
            }
            // Attaching is undoable: model it as an `.added` change whose revert
            // detaches the file (staging its bytes for redo).
            registerFileRevert(
                FileChange(artifactID: id, operation: .added(entry)),
                actionName: "Attach File")
        }
        bumpAndRefresh()
    }

    /// One file's result from a batch attach — the `ingest` twin.
    /// Constructed off-main and read on the main actor, exactly like
    /// `IngestOutcome` above — `nonisolated` for the same reason.
    private nonisolated struct AttachOutcome: FileOutcome {
        var entry: FileEntry?
        var embedded: EmbeddedMetadata?
        var failure: Error?

        init(entry: FileEntry, embedded: EmbeddedMetadata?) {
            self.entry = entry
            self.embedded = embedded
        }
        init(failure: Error) { self.failure = failure }
    }

    // MARK: - The importer's result, and Continuity Camera scans

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
}

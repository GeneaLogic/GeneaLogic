import Foundation
import GeneaLogicModel

/// File operations enforcing the §4.2.1 file-naming invariant.
extension Archive {
    /// Copies the file at `sourceURL` into the artifact `id`'s folder, computes
    /// its SHA-256, assigns a package-controlled collision-free `path`, and
    /// records a new `FileEntry` in the artifact's `record.json` and the
    /// archive's `manifest.json`.
    ///
    /// Implements every requirement in ARCHITECTURE.md §4.2.1:
    /// - `path` is package-assigned; the incoming basename is **never** trusted
    ///   for it (`Slug.sanitize` + `Slug.makeUnique` derive it).
    /// - `originalName` preserves the user's filename (display/export only).
    /// - Uniqueness is checked under case-folding + Unicode NFC.
    /// - Unsafe characters are sanitized; only `record.json`/`manifest.json` are
    ///   reserved.
    /// - No silent overwrite — a brand-new `FileID` is always minted here;
    ///   `replaceFile` is the targeted-overwrite path.
    /// - Byte-identical content already in the artifact is detected (by
    ///   `sha256`) and reported via `AttachedFile.duplicatesOf`, but the new
    ///   file is still stored — see the de-dup judgment call below.
    ///
    /// - Parameters:
    ///   - sourceURL: A local file URL to copy in. Must be a readable regular file.
    ///   - id: The artifact to attach the file to.
    ///   - role: The file's role (`preservation-master`, `access-copy`, …).
    ///   - extractor: An optional injected `MetadataExtractor` (§6.4). If
    ///     supplied, it runs against the **copied-in** file (so results describe
    ///     what the archive now holds) and its output is surfaced via
    ///     `AttachedFile.embeddedMetadata` — never written to any genealogical
    ///     field. See `EmbeddedMetadata.swift` for why nothing is persisted.
    /// - Returns: The created `FileEntry` plus extractor output / dedup info.
    /// - Throws: `ArchiveError.artifactNotFound`, `.sourceFileNotReadable`, or
    ///   filesystem/checksum errors.
    @discardableResult
    public func attachFile(
        copyingFrom sourceURL: URL,
        to id: ArtifactID,
        role: FileRole,
        extractor: (any MetadataExtractor)? = nil
    ) throws -> AttachedFile {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ArchiveError.sourceFileNotReadable(sourceURL)
        }

        return try withState { _, index in
            guard var artifact = try index.artifact(id), let slug = try index.slug(for: id) else {
                throw ArchiveError.artifactNotFound(id)
            }

            // Before the copy, not after it: a refused attach must leave no file
            // behind (slice 58 — see `refuseToTouchDriftedArtifact`).
            try refuseToTouchDriftedArtifact(slug: slug)

            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            let originalName = sourceURL.lastPathComponent
            let sanitizedCandidate = Slug.sanitize(basename: originalName)
            let existingPaths = artifact.files.map(\.path)
            let assignedPath = Slug.makeUnique(sanitizedCandidate, against: existingPaths)

            // Belt-and-suspenders: `makeUnique` already treats reserved names as
            // taken, so this should be unreachable — but a silent collision with
            // `record.json` would be catastrophic, so we guard it explicitly.
            if Slug.isReserved(assignedPath) {
                throw ArchiveError.nameCollisionWithReserved(assignedPath)
            }

            let destinationURL = artifactDirectory.appendingPathComponent(assignedPath)
            try AtomicIO.copyFile(from: sourceURL, to: destinationURL)

            let sha256 = try Checksum.sha256Hex(ofFileAt: destinationURL)
            let byteLength = try fileSize(at: destinationURL)

            // Content de-duplication (§4.2.1, §10 open question 6): detect
            // byte-identical files already in *this* artifact and report them.
            //
            // **Judgment call (flagged for review):** the architecture doc
            // leans toward "report it and let the app/user decide; off-by-default
            // for silent reuse" — i.e. never silently skip the copy. This
            // implementation always stores the new file (so `attachFile` is
            // never silently a no-op and the caller's mental model — "I attached
            // a file, I get a FileEntry for it" — always holds) and surfaces
            // every same-sha256 sibling via `AttachedFile.duplicatesOf` so the
            // caller can offer "reference the existing file instead" as a
            // follow-up `detachFile` if they choose. Detection is scoped to the
            // *current artifact* (not archive-wide) because that's what
            // `attachFile` can answer cheaply from data it already has in hand;
            // archive-wide duplicate discovery is `artifacts(containingFileWithSHA256:)`.
            let duplicates = artifact.files.filter { $0.sha256 == sha256 }

            let fileID = IdentifierMinter.file()
            let entry = FileEntry(
                uid: fileID,
                path: assignedPath,
                originalName: originalName,
                role: role,
                format: (sourceURL.pathExtension as NSString).uppercased,
                byteLength: byteLength,
                sha256: sha256
            )

            artifact.files.append(entry)
            artifact.schemaVersion = SchemaVersion.current
            try writeAuthoredJSON(artifact, to: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)

            let embeddedMetadata = try extractor?.extract(from: destinationURL)

            return AttachedFile(
                entry: entry, embeddedMetadata: embeddedMetadata, duplicatesOf: duplicates)
        }
    }

    /// Replaces the **content** of an existing file entry, identified by its
    /// `FileID`, with the file at `sourceURL`. The entry's `uid` is preserved (so
    /// existing references keep working); `originalName`, `format`, `byteLength`,
    /// and `sha256` are refreshed to describe the new content, and `path` is a
    /// fresh package-assigned name derived from the new `originalName`. `role` is
    /// left as-is — replacing content doesn't change intent.
    ///
    /// **The path moves, and that is what makes it crash-safe** (slice 65, fork
    /// d). It used to be kept, so the new bytes overwrote the old in place before
    /// the record was rewritten — and a crash between the two left new bytes
    /// under the old hash: a `.checksumMismatch` that `rebaseline()` could not
    /// clear, with the old bytes staged outside the package. Now replace has
    /// `attachFile`'s shape: copy to a free path, rewrite the record, then unlink
    /// the old path — so a cut leaves the old state plus a stray, or the new state
    /// plus a stray, both reported as `.unreferencedFile`. `path` was always
    /// non-authoritative (§4.2.1); the `uid` is the stable reference.
    ///
    /// This is the **only** sanctioned way to overwrite file content
    /// (ARCHITECTURE.md §4.2.1: "Replacing an existing file happens only when
    /// the app explicitly targets that file by its `uid`") — `attachFile` always
    /// creates a new entry and never overwrites.
    ///
    /// - Returns: A `FileChange` (`.replaced`) capturing the prior content, for
    ///   `revert(_:)` (app-layer undo).
    /// - Throws: `ArchiveError.artifactNotFound`, `.fileNotFound`,
    ///   `.sourceFileNotReadable`, or filesystem/checksum errors.
    @discardableResult
    public func replaceFile(_ fileID: FileID, in artifactID: ArtifactID, copyingFrom sourceURL: URL)
        throws -> FileChange
    {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            throw ArchiveError.sourceFileNotReadable(sourceURL)
        }
        return try setFileContent(fileID, in: artifactID, copyingFrom: sourceURL, restoring: nil)
    }

    /// Detaches a file from an artifact, **reversibly and persistently** — the file's
    /// bytes are moved into the package's `.trash/<file-uid>/` (keyed by the `FIL-`
    /// id; `FIL-`/`ART-` prefixes can't collide there) before the record/index/manifest
    /// forget it, so a detached file survives quit and can be recovered via
    /// `restoreFile(_:)` (the cross-session Trash UI) *or* the in-session undo path
    /// (`revert` of the returned change) — the two are views on the same store, exactly
    /// like artifact deletion (§7).
    ///
    /// A missing on-disk file (out-of-band edit) degrades to a **record-only** trash
    /// entry (no payload) whose restore re-adds the entry without bytes.
    ///
    /// - Returns: A `FileChange` (`.removed`) naming the removed entry, for
    ///   `revert(_:)` (app-layer undo); the bytes themselves live in `.trash/`.
    /// - Throws: `ArchiveError.artifactNotFound` or `.fileNotFound`.
    @discardableResult
    public func detachFile(_ fileID: FileID, in artifactID: ArtifactID) throws -> FileChange {
        try withState { _, index in
            guard var artifact = try index.artifact(artifactID),
                let slug = try index.slug(for: artifactID)
            else {
                throw ArchiveError.artifactNotFound(artifactID)
            }
            guard let entryIndex = artifact.files.firstIndex(where: { $0.uid == fileID }) else {
                throw ArchiveError.fileNotFound(fileID, on: artifactID)
            }

            // Before the bytes move into `.trash/` — a refused detach must leave
            // the file where it is (slice 58).
            try refuseToTouchDriftedArtifact(slug: slug)

            let entry = artifact.files[entryIndex]
            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            let fileURL = artifactDirectory.appendingPathComponent(entry.path)

            let trashEntry = TrashEntry(
                kind: .file,
                deletedAt: ISO8601DateFormatter().string(from: Date()),
                file: FileTrashInfo(
                    entry: entry, artifactUID: artifactID, artifactTitle: artifact.title))

            // Move the bytes into the trash (atomic rename within the package) *before*
            // dropping the entry, so the detach can be reverted. If the file is already
            // gone, fall back to a record-only entry (restore re-adds without bytes).
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try TrashStore.stash(item: fileURL, uid: fileID.raw, entry: trashEntry, in: rootURL)
            } else {
                try TrashStore.stashRecordOnly(uid: fileID.raw, entry: trashEntry, in: rootURL)
            }

            // A deliberate removal, so the merge may treat a stale manifest
            // naming it as behind us (slice 50b, `/code-review`).
            noteAuthoredRemoval(at: fileURL)

            artifact.files.remove(at: entryIndex)
            artifact.schemaVersion = SchemaVersion.current

            try writeAuthoredJSON(artifact, to: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)

            return FileChange(artifactID: artifactID, operation: .removed(entry))
        }
    }

    /// Restores a detached file from the trash, re-attaching it to the artifact it was
    /// detached from and clearing its `.trash/` entry. The file's `uid` is faithful;
    /// its original package path is reused when still free, otherwise a fresh
    /// collision-free one is assigned (the path is non-authoritative, §4.2.1). This is
    /// the single restore path for both the in-session undo stack (`revert` of a
    /// `.removed` change) and the cross-session Trash UI.
    ///
    /// A record-only trash entry (the file's bytes were already gone at detach) restores
    /// the entry alone — `verifyIntegrity()` then reports the missing content, as before.
    ///
    /// - Throws: `ArchiveError.fileTrashEntryNotFound` if no recoverable entry exists
    ///   (never detached, already restored, or permanently deleted);
    ///   `ArchiveError.artifactNotFound` if the artifact it belonged to no longer exists
    ///   (the file can't be re-homed).
    @discardableResult
    public func restoreFile(_ fileID: FileID) throws -> FileEntry {
        try withState { _, index in
            guard let trash = TrashStore.entry(uid: fileID.raw, in: rootURL),
                trash.kind == .file, let info = trash.file
            else {
                throw ArchiveError.fileTrashEntryNotFound(fileID)
            }
            let artifactID = info.artifactUID
            guard var artifact = try index.artifact(artifactID),
                let slug = try index.slug(for: artifactID)
            else {
                throw ArchiveError.artifactNotFound(artifactID)
            }

            // Before the bytes come back out of `.trash/` (slice 58).
            try refuseToTouchDriftedArtifact(slug: slug)

            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            var restored = info.entry
            // Free **on disk** as well as in the record (`/code-review`, 65): the
            // record is written before the move now, so a move refused by a
            // stray already sitting at the name — what a cut attach or replace
            // leaves behind — would leave the record claiming the stray's bytes.
            let taken =
                artifact.files.map(\.path)
                + ((try? FileManager.default.contentsOfDirectory(atPath: artifactDirectory.path))
                    ?? [])
            // Compared the way the engine compares names (case-fold + NFC), since
            // a case-insensitive volume refuses `B.jpg` over `b.jpg` too.
            if Slug.makeUnique(restored.path, against: taken) != restored.path {
                let candidate = Slug.sanitize(basename: restored.originalName)
                restored.path = Slug.makeUnique(candidate, against: taken)
            }

            // **The record first, then the bytes, then the entry** (slice 65, fork
            // e). The record is what makes the file live, and the open after a
            // crash finishes any restore whose record landed — bytes back to the
            // path the record names, entry dropped. The old order moved and purged
            // first, so a cut before the record left the bytes claimed by nothing
            // and listed nowhere.
            artifact.files.append(restored)
            artifact.schemaVersion = SchemaVersion.current

            try writeAuthoredJSON(artifact, to: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            // With the record, so a move or purge that throws leaves the index
            // agreeing with the record it already wrote — the session carries on
            // from this row, and the drift guard stands down once the write is
            // flagged interrupted (`/code-review`, 66).
            try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)

            // Move the trashed bytes back into place (atomic rename within the package);
            // a record-only entry has no payload, so the entry restores without content.
            let payload = TrashStore.payloadURL(uid: fileID.raw, in: rootURL)
            let destination = artifactDirectory.appendingPathComponent(restored.path)
            if FileManager.default.fileExists(atPath: payload.path) {
                try FileManager.default.moveItem(at: payload, to: destination)
                WriteCheckpoint.reached("moved", at: destination)
                // **And again now the bytes are back** (slice 66). The upsert reads
                // a transcript's text off disk into `search_text`, and the one
                // above ran with nothing at the path, so a restored transcript was
                // unsearchable until something rebuilt the index.
                try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)
            }
            try TrashStore.purge(uid: fileID.raw, in: rootURL)

            return restored
        }
    }

    /// The files currently in the trash, **most recently deleted first** — what a Trash
    /// UI lists alongside `trashedArtifacts()`. Reads only the `deletion.json` sidecars
    /// (name + owning-artifact title are denormalized there), so no payload is decoded.
    public func trashedFiles() -> [TrashedFile] {
        withReadState { _, _ in
            TrashStore.entries(in: rootURL).compactMap { _, entry in
                guard entry.kind == .file, let info = entry.file else { return nil }
                return TrashedFile(
                    uid: info.entry.uid, originalName: info.entry.originalName,
                    artifactUID: info.artifactUID, artifactTitle: info.artifactTitle,
                    deletedAt: entry.deletedAt)
            }
        }
    }

    /// Permanently deletes one trashed file — irreversible (the bytes leave the
    /// package). Lenient if `fileID` isn't in the trash.
    public func deleteFileFromTrash(_ fileID: FileID) throws {
        try withState { _, _ in try TrashStore.purge(uid: fileID.raw, in: rootURL) }
    }

    /// Changes an attached file's `role` (preservation-master ↔ access-copy ↔
    /// derivative ↔ transcript), leaving its content, `uid`, and `path` untouched —
    /// a metadata-only edit of the file's archival intent. This is the sanctioned way
    /// to correct a role after the fact (the app pre-assigns one at attach time, §4.2.1
    /// puts no constraint on how many files hold a given role).
    ///
    /// Returns the file's **prior** role, so the caller (the app's in-session
    /// UndoManager) can reverse the change with another `setFileRole`. A no-op change
    /// (role already `role`) still returns the current role but skips the write.
    ///
    /// - Throws: `ArchiveError.artifactNotFound` or `.fileNotFound`.
    @discardableResult
    public func setFileRole(_ fileID: FileID, in artifactID: ArtifactID, to role: FileRole)
        throws -> FileRole
    {
        try withState { _, index in
            guard var artifact = try index.artifact(artifactID),
                let slug = try index.slug(for: artifactID)
            else {
                throw ArchiveError.artifactNotFound(artifactID)
            }
            guard let entryIndex = artifact.files.firstIndex(where: { $0.uid == fileID }) else {
                throw ArchiveError.fileNotFound(fileID, on: artifactID)
            }

            let priorRole = artifact.files[entryIndex].role
            guard priorRole != role else { return priorRole }

            artifact.files[entryIndex].role = role
            artifact.schemaVersion = SchemaVersion.current

            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            try writeAuthoredJSON(artifact, to: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)

            return priorRole
        }
    }

    /// The on-disk URL of an attached file's bytes **inside the package** — for
    /// callers that need the actual file (preview, exporting a copy). Returns `nil`
    /// if the artifact or file id is unknown (or the slug can't be resolved).
    ///
    /// **Read-only.** The URL points inside the package; mutating it out-of-band
    /// desyncs `manifest.json`/the index and breaks `verifyIntegrity()` — change
    /// content through `replaceFile`/`detachFile` instead. The `path` is
    /// package-assigned and non-authoritative (§4.2.1), so don't persist the URL
    /// across edits — re-resolve by id. Doesn't check existence; a record can
    /// outlive its bytes after an out-of-band deletion (that's `verifyIntegrity()`'s
    /// job to report), in which case the URL simply won't resolve to a file.
    public func fileURL(of fileID: FileID, in artifactID: ArtifactID) -> URL? {
        withIndex { index in
            guard let artifact = try? index.artifact(artifactID),
                let slug = try? index.slug(for: artifactID),
                let entry = artifact.files.first(where: { $0.uid == fileID })
            else {
                return nil
            }
            return ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
                .appendingPathComponent(entry.path)
        }
    }

    /// Reverses a `FileChange` produced by `attachFile`/`detachFile`/`replaceFile`
    /// (or by a previous `revert`), restoring the affected file to its prior state
    /// **faithfully** — a re-added file keeps its original `uid` (its package path
    /// is reused when free, otherwise reassigned, since the path is non-authoritative).
    ///
    /// Returns the *opposite* `FileChange`, so undo and redo are the same call:
    /// `revert(revert(change))` round-trips. This is the engine primitive the app's
    /// in-session UndoManager drives; it makes no persistence promise beyond the
    /// lifetime of the staged bytes (§7, app-layer durability).
    @discardableResult
    public func revert(_ change: FileChange) throws -> FileChange {
        switch change.operation {
        case .added(let entry):
            // Undo an add → remove it. `detachFile` trashes the bytes, so the
            // resulting `.removed` is itself reversible (redo restores from trash).
            return try detachFile(entry.uid, in: change.artifactID)

        case .removed(let entry):
            // Undo a removal → restore the file from the trash (re-attaches the exact
            // entry to its artifact and clears the trash entry). Throws
            // `fileTrashEntryNotFound` if the bytes were permanently removed since.
            let restored = try restoreFile(entry.uid)
            return FileChange(artifactID: change.artifactID, operation: .added(restored))

        case .replaced(let fileID, let priorEntry, let stagedPriorContent):
            // Undo a replacement → restore the prior content + entry (staging the
            // current content first, so redo can put it back).
            let redo = try setFileContent(
                fileID, in: change.artifactID, copyingFrom: stagedPriorContent,
                restoring: priorEntry)
            try? FileManager.default.removeItem(at: stagedPriorContent)
            return redo
        }
    }

    // MARK: - Reversible-op internals

    /// Replaces `fileID`'s content with the bytes at `sourceURL` — at a fresh
    /// path, never over the current one (see `replaceFile`) — staging the current
    /// content first and returning a `.replaced` `FileChange` that captures it.
    /// When `entryOverride` is `nil` (a user `replaceFile`) the entry's
    /// descriptive fields are refreshed from `sourceURL`; when it is supplied (a
    /// `revert`) the entry is restored to it verbatim, its path included unless
    /// another file has taken it since.
    private func setFileContent(
        _ fileID: FileID, in artifactID: ArtifactID, copyingFrom sourceURL: URL,
        restoring entryOverride: FileEntry?
    ) throws -> FileChange {
        try withState { _, index in
            guard var artifact = try index.artifact(artifactID),
                let slug = try index.slug(for: artifactID)
            else {
                throw ArchiveError.artifactNotFound(artifactID)
            }
            guard let entryIndex = artifact.files.firstIndex(where: { $0.uid == fileID }) else {
                throw ArchiveError.fileNotFound(fileID, on: artifactID)
            }

            // Before the destination is overwritten — a refused replace must
            // leave the existing content intact (slice 58).
            try refuseToTouchDriftedArtifact(slug: slug)

            let artifactDirectory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            let priorEntry = artifact.files[entryIndex]
            let priorURL = artifactDirectory.appendingPathComponent(priorEntry.path)

            // A fresh path, never the one holding the current bytes (fork d): the
            // name a revert restores when it is still free, otherwise one derived
            // from the incoming name, exactly as `attachFile` derives it.
            let taken = artifact.files.map(\.path)
            let freshPath = Slug.makeUnique(
                entryOverride?.path ?? Slug.sanitize(basename: sourceURL.lastPathComponent),
                against: taken)
            if Slug.isReserved(freshPath) {
                throw ArchiveError.nameCollisionWithReserved(freshPath)
            }
            let destinationURL = artifactDirectory.appendingPathComponent(freshPath)

            // Stage the bytes being replaced (in-session undo), copy the new ones
            // in beside them, and only then point the record at them.
            let stagedPrior = try Self.stageBytes(of: priorURL)
            try AtomicIO.copyFile(from: sourceURL, to: destinationURL)

            var entry = entryOverride ?? priorEntry
            entry.path = freshPath
            if entryOverride == nil {
                entry.originalName = sourceURL.lastPathComponent
                entry.format = (sourceURL.pathExtension as NSString).uppercased
                entry.byteLength = try fileSize(at: destinationURL)
                entry.sha256 = try Checksum.sha256Hex(ofFileAt: destinationURL)
            }
            artifact.files[entryIndex] = entry
            artifact.schemaVersion = SchemaVersion.current

            try writeAuthoredJSON(artifact, to: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            try index.upsert(artifact, slug: slug, artifactDirectory: artifactDirectory)

            // The old bytes go last — a deliberate removal, noted for 50b's merge
            // the way `detachFile` notes its own.
            try removeAuthoredFile(at: priorURL)

            return FileChange(
                artifactID: artifactID,
                operation: .replaced(
                    fileID: fileID, priorEntry: priorEntry, stagedPriorContent: stagedPrior))
        }
    }

    /// Copies a file's bytes into a temporary staging area (outside the package),
    /// returning the staged URL. Used to preserve content a destructive op
    /// (`replaceFile`) would otherwise lose, so it can be reverted. (`detachFile`
    /// stages into the persistent `.trash/` instead; only the in-session-only
    /// replace path stages to temp.)
    private static func stageBytes(of fileURL: URL) throws -> URL {
        let stagingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GeneaLogicUndo", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let stagedURL = stagingRoot.appendingPathComponent(UUID().uuidString)
        try AtomicIO.copyFile(from: fileURL, to: stagedURL)
        return stagedURL
    }

    fileprivate func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

/// A reversible file-content change, returned by `detachFile`/`replaceFile` (and
/// formed by the caller from an `attachFile`). Pass it to `revert(_:)` to undo the
/// change; `revert` returns the *opposite* `FileChange`, so undo/redo is a
/// ping-pong of `revert` calls (`revert(revert(c))` round-trips).
///
/// **Durability differs by operation.** A *detached* file's bytes go into the
/// package's persistent `.trash/` (recoverable across sessions via `restoreFile`),
/// so a `.removed` change need only name the entry — its bytes are found by uid.
/// A *replaced* file's prior content is staged to a temporary directory **outside**
/// the package and is **in-session only** — once the host's undo history is gone, so
/// is that staged content (ARCHITECTURE.md §7, app-layer durability).
public struct FileChange: Sendable {
    /// What happened, and what `revert` needs to reverse it.
    public enum Operation: Sendable {
        /// A file was added (e.g. by `attachFile`). Reverting removes it (to the trash).
        case added(FileEntry)
        /// A file was removed (`detachFile`); its bytes live in `.trash/<entry.uid>/`.
        /// Reverting restores it from the trash (`restoreFile`).
        case removed(FileEntry)
        /// A file's content was replaced (`replaceFile`). `priorEntry` and
        /// `stagedPriorContent` capture what it was before. Reverting restores them.
        case replaced(fileID: FileID, priorEntry: FileEntry, stagedPriorContent: URL)
    }

    /// The artifact the change applies to.
    public let artifactID: ArtifactID
    /// The change itself.
    public let operation: Operation

    public init(artifactID: ArtifactID, operation: Operation) {
        self.artifactID = artifactID
        self.operation = operation
    }
}

/// A trashed file as listed by `trashedFiles()`: enough to show it and put it back.
/// Its bytes live in the package's `.trash/<uid>/payload` (absent for a record-only
/// entry). Restoring re-attaches it to the artifact it was detached from.
public struct TrashedFile: Sendable, Equatable {
    /// The detached file's `FIL-` id (also its `.trash/<uid>/` folder name).
    public let uid: FileID
    /// The user's filename, for display.
    public let originalName: String
    /// The artifact it was detached from, where `restoreFile` re-attaches it.
    public let artifactUID: ArtifactID
    /// The title of the artifact it was detached from ("deleted from …").
    public let artifactTitle: String
    /// ISO 8601 timestamp of deletion.
    public let deletedAt: String
}

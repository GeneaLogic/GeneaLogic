import Foundation
import GeneaLogicModel

/// Artifact CRUD (ARCHITECTURE.md §6.3, §4.2).
extension Archive {
    /// Creates a new artifact from `draft`, minting its `ART-` id, writing
    /// `artifacts/<slug>/record.json`, and updating the manifest + index.
    ///
    /// The folder slug is derived from the title (`Slug.slugify`) and
    /// disambiguated against existing artifact folder names, including ones the
    /// index cannot see (`takenArtifactSlugs`) — it is a friendly convenience,
    /// **never** the authoritative identity (ARCHITECTURE.md §4.1).
    ///
    /// - Returns: The created `Artifact`, including its minted `uid`.
    @discardableResult
    public func addArtifact(_ draft: ArtifactDraft) throws -> Artifact {
        try withState { manifest, index in
            let id = IdentifierMinter.artifact()
            let provenance = draft.provenance ?? Provenance.assertedNow()

            let artifact = Artifact(
                uid: id,
                title: draft.title,
                mediaType: draft.mediaType,
                sourceAuthorityTier: draft.sourceAuthorityTier,
                sourceDerivation: draft.sourceDerivation,
                originalFormat: draft.originalFormat,
                language: draft.language,
                events: draft.events,
                personsMentioned: draft.personsMentioned,
                locations: draft.locations,
                transcript: draft.transcript,
                files: [],
                externalIdentifiers: draft.externalIdentifiers,
                retrieval: draft.retrieval,
                provenance: provenance,
                tags: draft.tags,
                notes: draft.notes
            )

            let baseSlug = Slug.slugify(draft.title, fallback: id.raw.lowercased())
            let slug = try Slug.makeUnique(
                baseSlug, againstNormalized: takenArtifactSlugs(index: index, manifest: manifest),
                alsoTaken: isOccupiedOnDisk)

            let recordURL = ArchiveLayout.recordURL(in: rootURL, slug: slug)
            try writeAuthoredJSON(artifact, to: recordURL)

            try index.upsert(
                artifact, slug: slug,
                artifactDirectory: ArchiveLayout.artifactDirectory(in: rootURL, slug: slug))

            return artifact
        }
    }

    /// Atomically rewrites the artifact's sidecar after applying `mutate` to an
    /// in-memory copy (ARCHITECTURE.md §6.3: `updateMetadata(of:_:)`).
    ///
    /// `mutate` may change any field — including `files`, though `attachFile`/
    /// `replaceFile`/`detachFile` are the sanctioned way to change *file content*
    /// (they own copying, checksumming, and naming). Hand-editing `files[]` here
    /// is possible but the caller is responsible for keeping it consistent with
    /// what's actually on disk; `verifyIntegrity()` will catch drift.
    ///
    /// - Throws: `ArchiveError.artifactNotFound` if `id` doesn't exist.
    public func updateMetadata(of id: ArtifactID, _ mutate: (inout Artifact) -> Void) throws {
        try withState { _, index in
            guard var artifact = try index.artifact(id), let slug = try index.slug(for: id) else {
                throw ArchiveError.artifactNotFound(id)
            }

            mutate(&artifact)
            artifact.uid = id  // identity is not mutable via this path
            artifact.schemaVersion = SchemaVersion.current

            let recordURL = ArchiveLayout.recordURL(in: rootURL, slug: slug)
            try writeAuthoredJSON(artifact, to: recordURL)

            try index.upsert(
                artifact, slug: slug,
                artifactDirectory: ArchiveLayout.artifactDirectory(in: rootURL, slug: slug))
        }
    }

    /// Removes an artifact and its entire folder (sidecar + every attached file),
    /// **reversibly and persistently** — the folder is moved into the package's
    /// `.trash/<uid>/` before the index/manifest forget it, so it survives quit and
    /// can be recovered via `restoreFromTrash(_:)` (the cross-session Trash UI) *or*
    /// `restoreArtifact(_:)` (the in-session undo path); the two are views on the
    /// same store. Returns an `ArtifactDeletion` token for the undo path.
    ///
    /// **Conclusions are left untouched (judgment call, §2.3):** any
    /// `EvidenceLink`/`PersonMention` referencing this artifact is left dangling
    /// rather than rewritten — an evidence-layer operation must not silently mutate
    /// conclusions records. `verifyIntegrity()` (or a future
    /// `findDanglingReferences()`) is where such dangles are surfaced for review.
    /// This is *also* what keeps the deletion cleanly reversible: nothing in
    /// `conclusions/` changes, so restoring the artifact re-validates any links that
    /// pointed at it.
    ///
    /// - Throws: `ArchiveError.artifactNotFound` if `id` doesn't exist.
    @discardableResult
    public func removeArtifact(_ id: ArtifactID) throws -> ArtifactDeletion {
        try withState { _, index in
            guard let artifact = try index.artifact(id), let slug = try index.slug(for: id) else {
                throw ArchiveError.artifactNotFound(id)
            }

            let directory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            // **A newer record is not this build's to delete** (`/code-review`,
            // 70). The folder leaves by rename, so the drift guard — and the stamp
            // check inside it — never sees this record; the deletion would reach
            // the manifest as one judged by a build that cannot read what it
            // removed. Only the stamp: whether a removal should also refuse
            // ordinary drift is a question this slice does not reopen.
            let recordURL = ArchiveLayout.recordURL(in: rootURL, slug: slug)
            try Migration.refuseIfAhead(
                recordAt: recordURL, path: ArchiveLayout.relativePath(of: recordURL, in: rootURL))
            let entry = TrashEntry(
                kind: .artifact,
                deletedAt: ISO8601DateFormatter().string(from: Date()),
                artifact: ArtifactTrashInfo(uid: id, title: artifact.title, originalSlug: slug))

            // **The record is going, and the manifest recompute has to be told**
            // (slice 60b, `/code-review`). The folder leaves by rename rather than
            // unlink, so it never passes `removeAuthoredFile`; without this, an
            // artifact deleted while the index has no settled witness leaves its
            // `record.json` entry in the manifest for ever. Payload files need no
            // such note — `awaitedPaths` only ever carries engine-authored paths.
            noteAuthoredRemoval(at: ArchiveLayout.recordURL(in: rootURL, slug: slug))
            // **And journaled, for the same reason** (slice 69, fork c): a crash
            // before the index commits leaves the record staged as a preserved
            // copy, and only a journaled unlink lets recovery discard it — the
            // folder is in the trash, not lost.
            IndexDirtyMarker.journalRemoval(
                of: ArchiveLayout.relativePath(
                    of: ArchiveLayout.recordURL(in: rootURL, slug: slug), in: rootURL),
                in: rootURL)
            // **And its payload, which is a deliberate removal too** (slice 50b,
            // `/code-review`). These need no note for `awaitedPaths`, which only
            // carries engine-authored paths — but `recordWhatThisMutationSuperseded`
            // arms the merge's drop rule from exactly this set, and a payload path
            // that merely *fell out* of the manifest is not evidence anyone deleted
            // it. Inert in `authoredEntries`, which never iterates payload paths.
            for file in artifact.files {
                noteAuthoredRemoval(at: directory.appendingPathComponent(file.path))
            }

            if FileManager.default.fileExists(atPath: directory.path) {
                // Move the whole folder into the trash (atomic rename within the package).
                try TrashStore.stash(item: directory, uid: id.raw, entry: entry, in: rootURL)
            } else {
                // Folder already gone (out-of-band edit): self-heal by reconstructing
                // the record into the trash payload from the index copy, so restore is
                // uniform (it always reads the payload). Files stay missing — integrity
                // would flag them anyway.
                try TrashStore.stashSeeded(uid: id.raw, entry: entry, in: rootURL) { payload in
                    try AtomicIO.writeJSON(
                        artifact,
                        to: payload.appendingPathComponent(ArchiveLayout.recordFileName))
                }
            }

            try index.removeArtifact(id)

            return ArtifactDeletion(uid: id)
        }
    }

    /// Restores an artifact removed by `removeArtifact` (the in-session undo path).
    /// A thin alias over `restoreFromTrash(_:)` keyed by the deletion's uid — the
    /// undo stack and the Trash UI recover from the *same* `.trash/` store.
    public func restoreArtifact(_ deletion: ArtifactDeletion) throws {
        try restoreFromTrash(deletion.uid)
    }

    /// Restores the trashed artifact `uid` back into `artifacts/`, re-inserting it
    /// into the index + manifest and clearing its `.trash/` entry. The `uid` is
    /// faithful; the original slug is reused when still free, otherwise a fresh
    /// collision-free one is assigned (the slug is a non-authoritative friendly
    /// name, §4.1). The restored record is read from the trashed payload, so this is
    /// the single restore path for both the undo stack and the Trash UI.
    ///
    /// - Throws: `ArchiveError.trashEntryNotFound` if no recoverable entry exists.
    @discardableResult
    public func restoreFromTrash(_ uid: ArtifactID) throws -> Artifact {
        try withState { manifest, index in
            let payload = TrashStore.payloadURL(uid: uid.raw, in: rootURL)
            let payloadRecord = payload.appendingPathComponent(ArchiveLayout.recordFileName)
            guard FileManager.default.fileExists(atPath: payloadRecord.path) else {
                throw ArchiveError.trashEntryNotFound(uid)
            }
            let recordBytes = try Data(contentsOf: payloadRecord)
            let artifact = try GeneaLogicJSONCoding.decoder.decode(Artifact.self, from: recordBytes)

            // Reuse the original slug when free; otherwise mint a fresh unique one.
            let originalSlug = TrashStore.entry(uid: uid.raw, in: rootURL)?.artifact?.originalSlug
            let taken = try takenArtifactSlugs(
                index: index, manifest: manifest,
                restoring: (uid, Checksum.sha256Hex(of: recordBytes)))
            let preferred =
                originalSlug ?? Slug.slugify(artifact.title, fallback: uid.raw.lowercased())
            let slug =
                try Slug.isTaken(preferred, againstNormalized: taken, alsoTaken: isOccupiedOnDisk)
                ? Slug.makeUnique(
                    Slug.slugify(artifact.title, fallback: uid.raw.lowercased()),
                    againstNormalized: taken, alsoTaken: isOccupiedOnDisk)
                : preferred

            let directory = ArchiveLayout.artifactDirectory(in: rootURL, slug: slug)
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The record comes back by rename, never through `writeAuthoredData`,
            // so it journals the bytes it puts back itself (slice 69,
            // `/code-review`): that cancels the `unlink` its removal journaled,
            // which would otherwise let recovery discard the copy of a later,
            // out-of-band loss of this path while the sentinel stands.
            IndexDirtyMarker.journalWrite(
                of: ArchiveLayout.relativePath(
                    of: directory.appendingPathComponent(ArchiveLayout.recordFileName), in: rootURL),
                sha256: Checksum.sha256Hex(of: recordBytes), in: rootURL)
            // Move the payload back into place (atomic rename), then drop the now
            // payload-less `.trash/<uid>/` (its leftover deletion.json).
            try FileManager.default.moveItem(at: payload, to: directory)
            WriteCheckpoint.reached("moved", at: directory)
            try TrashStore.purge(uid: uid.raw, in: rootURL)

            try index.upsert(artifact, slug: slug, artifactDirectory: directory)
            // The record is live again, so every copy of it is redundant now, not
            // at the next rebuild — by uid, the rule `rebuild`'s prune applies,
            // wherever it was staged. Left standing, a copy kept its repair offer,
            // and a repair would carry the restored record off to `.damaged/` or
            // write a second folder claiming its uid (`/code-review`, 58b).
            try index.discardPreservedRecords(of: uid.raw)

            return artifact
        }
    }

    /// The artifacts currently in the trash, **most recently deleted first** — what
    /// a Trash UI lists. Reads only the `deletion.json` sidecars (title is
    /// denormalized there), so it doesn't decode each payload.
    public func trashedArtifacts() -> [TrashedArtifact] {
        withReadState { _, _ in
            TrashStore.entries(in: rootURL).compactMap { uid, entry in
                guard entry.kind == .artifact, let info = entry.artifact else { return nil }
                return TrashedArtifact(
                    uid: info.uid, title: info.title,
                    deletedAt: entry.deletedAt, originalSlug: info.originalSlug)
            }
        }
    }

    /// Permanently deletes one trashed artifact — irreversible (the bytes leave the
    /// package). Lenient if `uid` isn't in the trash.
    public func deleteFromTrash(_ uid: ArtifactID) throws {
        try withState { _, _ in try TrashStore.purge(uid: uid.raw, in: rootURL) }
    }

    /// Permanently empties the trash — irreversible. Lenient if it's already empty.
    public func emptyTrash() throws {
        try withState { _, _ in try TrashStore.purgeAll(in: rootURL) }
    }

    /// The artifact folder names a **new** folder must not take (slice 58b), for
    /// `addArtifact` and `restoreFromTrash` to make their slug unique against —
    /// together with `isOccupiedOnDisk`, which is probed per candidate.
    ///
    /// **The index alone is not enough.** A folder whose `record.json` the walk
    /// skipped as unreadable (55) has no row, so a new artifact titled like it was
    /// given its folder: refused by 58's drift guard (an unrelated add failing
    /// over a name), or — where the guard stands down, as it does for a
    /// rebaselined straggler — written over it, after which the next rebuild's
    /// staging replaced the old record's preserved copy with the new record's
    /// row. A name is taken when any of these hold:
    ///
    /// - **The index has it**, for every record that reads.
    /// - **A preserved artifact record names it**, even once the folder is gone.
    ///   A sidecar that *vanished* keeps its copy (58) and its repair offer (59),
    ///   which writes back to that path: a new artifact sitting there would be
    ///   carried off to `.damaged/` by the repair, and its row would displace the
    ///   copy at the next rebuild. **Except the copy of the record being
    ///   restored**: a deletion that arrives by sync takes the folder out from
    ///   under the index, so the rebuild keeps a copy of that very record at its
    ///   old path; restoring it there is the record coming back to its own
    ///   folder, and taking a fresh slug instead strands it when the other
    ///   machine's restored folder lands under the old name (`ManifestABATests`).
    /// - **The manifest names its record** (`/code-review`, 58b). A delivery can
    ///   bring the manifest before the folder it describes, and a folder still in
    ///   flight is in neither the index nor on disk: a new artifact given its name
    ///   is overwritten, or conflicted, when it lands. **Except an entry whose
    ///   checksum is the restored record's own bytes** — the same exception as
    ///   the copy's, for when this machine's manifest still lists the folder a
    ///   delivered deletion took; the path cannot say whose entry it is, but the
    ///   checksum can.
    /// - **Something is at that path on disk** (`isOccupiedOnDisk`), readable or
    ///   not — which also keeps a new artifact out of a stray folder with no
    ///   `record.json` at all.
    ///
    /// Trashed artifacts' original slugs are deliberately **not** taken: a
    /// restore already assigns a fresh one when its old name is in use.
    ///
    /// Returned in `Slug.normalizedForComparison` form, so a restore testing two
    /// candidates folds the set once.
    private func takenArtifactSlugs(
        index: ArchiveIndex, manifest: Manifest,
        restoring restored: (uid: ArtifactID, recordSHA256: String)? = nil
    ) throws -> Set<String> {
        var taken = Set(try index.allSlugs().lazy.filter { $0.key != restored?.uid }.map(\.value))
        taken.formUnion(try index.preservedArtifactSlugs(excluding: restored?.uid))
        // A cheap suffix test first: nearly every entry is a payload file.
        for entry in manifest.files where entry.path.hasSuffix(ArchiveLayout.recordFileName) {
            if entry.sha256 != restored?.recordSHA256,
                let slug = ArchiveLayout.artifactSlug(ofRecordPath: entry.path)
            {
                taken.insert(slug)
            }
        }
        return Set(taken.map(Slug.normalizedForComparison))
    }

    /// Whether anything — a folder, a file, a dangling link — is at
    /// `artifacts/<slug>`.
    ///
    /// **Probed, not listed.** Listing `artifacts/` cost ~8% of an add (+12.5 ms
    /// at 10,000 artifacts, SLICE-LOG 58b), and a probe costs a `stat`. The names
    /// `takenArtifactSlugs` returns compare case-fold + NFC; the disk compares the
    /// way its volume does. On a case- and normalization-insensitive volume —
    /// APFS's default — that is the same rule. On a case-sensitive one a
    /// *hand-made* folder differing only in case or normalization does not block
    /// the name, and the two coexist there — but clash if the archive is later
    /// copied to a case-insensitive volume. The engine never makes such a folder
    /// itself (`slugify` lowercases and folds accents), so only a hand can.
    ///
    /// **`lstat`, and only `ENOENT` is free** (`/code-review`, 58b, twice):
    /// `fileExists` follows a link, so a dangling one read as free and the write
    /// into it failed; and an `EACCES` or `EIO` read as free too. It throws
    /// instead — reading it as *occupied* would loop for ever on an `artifacts/`
    /// that refuses every probe.
    private func isOccupiedOnDisk(_ slug: String) throws -> Bool {
        try !AtomicIO.isAbsent(ArchiveLayout.artifactDirectory(in: rootURL, slug: slug))
    }
}

/// A reversible artifact deletion, returned by `removeArtifact` and passed to
/// `restoreArtifact` (the in-session undo path). Opaque to callers: it just names
/// the deleted artifact's uid, whose recoverable bytes live in the package's
/// `.trash/<uid>/`. Unlike the bytes — which are persistent — this token is meant
/// for the host's in-session undo history (§7); the same artifact is also
/// recoverable across sessions via `trashedArtifacts()` + `restoreFromTrash(_:)`.
public struct ArtifactDeletion: Sendable {
    let uid: ArtifactID
}

/// A trashed artifact as listed by `trashedArtifacts()`: enough to show it and put
/// it back. The bytes live in the package's `.trash/<uid>/payload/`.
public struct TrashedArtifact: Sendable, Equatable {
    public let uid: ArtifactID
    public let title: String
    /// ISO 8601 timestamp of deletion.
    public let deletedAt: String
    public let originalSlug: String
}

extension Provenance {
    /// The default provenance the engine stamps on records the caller didn't
    /// supply one for: a human assertion, timestamped now, not yet specially
    /// reviewed. (CLAUDE.md: "provenance on every assertion, even pre-AI" —
    /// this is the floor every engine-created record meets.)
    static func assertedNow() -> Provenance {
        Provenance(
            createdBy: .human,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            tool: nil,
            reviewStatus: .asserted
        )
    }

    /// The provenance stamp for machine-suggested conclusions (used by `link`
    /// when no explicit provenance is supplied) — `createdBy: .machine` would be
    /// dishonest for a *manually*-created link, so this is `.human`/`.asserted`
    /// by default; see the judgment call in `Archive+Conclusions.swift`.
    static func assertedNow(tool: String?) -> Provenance {
        Provenance(
            createdBy: tool == nil ? .human : .machine,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            tool: tool,
            reviewStatus: .asserted
        )
    }
}

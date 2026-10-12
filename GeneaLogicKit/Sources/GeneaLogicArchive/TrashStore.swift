import Foundation
import GeneaLogicModel

/// The package-internal trash store: moves deleted items aside into `.trash/<uid>/`
/// and brings them back, **kind-agnostically**. All the filesystem mechanics live
/// here once; callers (`removeArtifact`/`restoreArtifact` today, a detached-file path
/// later) supply the kind-specific `TrashEntry` and decide what restoring *means*.
///
/// `.trash/` is inside the package and on the same volume as `artifacts/`, so a stash
/// and a take are **atomic renames** (`moveItem`), not copies — fast and crash-safe.
/// `.trash/` is a sibling of `artifacts/`, so the index/manifest/integrity passes
/// (all scoped to `artifacts/` + `conclusions/`) never see what's parked here.
///
/// Operations here are pure filesystem; the calling `Archive` method holds the
/// state lock and owns index/manifest updates.
enum TrashStore {
    /// Writes `deletion.json`, then moves `item` (an artifact folder or a single
    /// file) into `.trash/<uid>/payload`. A pre-existing entry for `uid` is
    /// cleared first (defensive — uids are unique, so this only matters after
    /// out-of-band tampering).
    ///
    /// **Record first** (slice 65, fork e). The other order left a stash that
    /// died between the two as a folder no listing names — an artifact in neither
    /// `artifacts/` nor the trash, reported only as a missing record. This way a
    /// torn stash is a *listed* entry with no payload yet, which the open after
    /// the crash recognizes and drops (`reconcileAfterInterruptedWrite`).
    ///
    /// **A move that throws takes the record back out** (`/code-review`, 65).
    /// Nothing else would: a failure that authored no sidecar clears the sentinel,
    /// so no reconcile runs, and the trash would list a subject that is still live
    /// — whose restore then appends a second entry with the same `FIL-` uid.
    static func stash(item: URL, uid: String, entry: TrashEntry, in root: URL) throws {
        try resetEntryDirectory(uid: uid, in: root)
        try writeRecord(entry, uid: uid, in: root)
        do {
            try FileManager.default.moveItem(
                at: item, to: ArchiveLayout.trashPayloadURL(in: root, uid: uid))
        } catch {
            try? purge(uid: uid, in: root)
            throw error
        }
        WriteCheckpoint.reached("moved", at: ArchiveLayout.trashPayloadURL(in: root, uid: uid))
    }

    /// Writes `deletion.json`, then creates `.trash/<uid>/payload` and lets
    /// `seed` populate it. Used when the live folder was already gone at delete
    /// time (out-of-band edit): the record is reconstructed into the payload from
    /// the in-memory copy so restore stays uniform (always reads the payload).
    /// Record first, and taken back out on failure, for the reasons `stash` gives.
    static func stashSeeded(
        uid: String, entry: TrashEntry, in root: URL, seed: (_ payload: URL) throws -> Void
    ) throws {
        try resetEntryDirectory(uid: uid, in: root)
        try writeRecord(entry, uid: uid, in: root)
        let payload = ArchiveLayout.trashPayloadURL(in: root, uid: uid)
        do {
            try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
            WriteCheckpoint.reached("created", at: payload)
            try seed(payload)
        } catch {
            try? purge(uid: uid, in: root)
            throw error
        }
    }

    /// Writes a trash entry that has **no payload** — only `deletion.json`. Used
    /// when there are no bytes to stage (a file whose on-disk content was already
    /// gone at delete time): the entry still lists and can be restored from the
    /// record alone (re-adding the metadata without content). For an artifact's
    /// record-only fallback use `stashSeeded` instead, which reconstructs a payload.
    static func stashRecordOnly(uid: String, entry: TrashEntry, in root: URL) throws {
        try resetEntryDirectory(uid: uid, in: root)
        try writeRecord(entry, uid: uid, in: root)
    }

    /// Every readable trash entry, **newest deletion first**; entries whose
    /// `deletion.json` is missing or undecodable are skipped (never a hard failure —
    /// the trash is best-effort recoverable storage, not authoritative state).
    /// Hidden folders are skipped too: they are purges in progress (see `purge`).
    static func entries(in root: URL) -> [(uid: String, entry: TrashEntry)] {
        let trashDir = ArchiveLayout.trashDirectory(in: root)
        guard
            let dirs = try? FileManager.default.contentsOfDirectory(
                at: trashDir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        else { return [] }

        var result: [(uid: String, entry: TrashEntry)] = []
        for dir in dirs {
            let uid = dir.lastPathComponent
            guard let entry = entry(uid: uid, in: root) else { continue }
            result.append((uid: uid, entry: entry))
        }
        return result.sorted { $0.entry.deletedAt > $1.entry.deletedAt }
    }

    /// The decoded `deletion.json` for `uid`, or `nil` if absent/undecodable.
    static func entry(uid: String, in root: URL) -> TrashEntry? {
        let recordURL = ArchiveLayout.trashRecordURL(in: root, uid: uid)
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? GeneaLogicJSONCoding.decoder.decode(TrashEntry.self, from: data)
    }

    /// The payload URL for `uid` (its bytes, present iff the entry has staged any).
    static func payloadURL(uid: String, in root: URL) -> URL {
        ArchiveLayout.trashPayloadURL(in: root, uid: uid)
    }

    /// The prefix of an entry folder a purge has taken out of the listing and not
    /// yet finished deleting.
    private static let purgingPrefix = ".purging-"

    /// Permanently removes the trash entry for `uid` (payload + record). Lenient: a
    /// missing entry is a no-op, so emptying or purging is idempotent.
    ///
    /// **One rename takes the whole entry out of the listing, then it is deleted**
    /// (slice 65, `/code-review`). A recursive delete is not atomic, and either
    /// order of its two halves leaves a lie behind a crash: record first left a
    /// payload no listing names, payload first left a `.file` entry with nothing
    /// to restore — indistinguishable from a legitimate record-only one, so its
    /// restore re-added the entry over bytes that no longer exist. Renaming to a
    /// hidden name is one step that every listing skips; the open after a crash
    /// finishes the delete.
    static func purge(uid: String, in root: URL) throws {
        let entryDir = ArchiveLayout.trashEntryDirectory(in: root, uid: uid)
        guard FileManager.default.fileExists(atPath: entryDir.path) else { return }
        let doomed = ArchiveLayout.trashDirectory(in: root)
            .appendingPathComponent("\(purgingPrefix)\(uid)-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: entryDir, to: doomed)
        WriteCheckpoint.reached("moved", at: doomed)
        try FileManager.default.removeItem(at: doomed)
        WriteCheckpoint.reached("unlinked", at: doomed)
    }

    /// Permanently removes the entire trash, an entry at a time so each goes
    /// atomically (see `purge`). Lenient when `.trash/` doesn't exist.
    static func purgeAll(in root: URL) throws {
        let trashDir = ArchiveLayout.trashDirectory(in: root)
        guard
            let dirs = try? FileManager.default.contentsOfDirectory(
                at: trashDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }
        for dir in dirs { try purge(uid: dir.lastPathComponent, in: root) }
        // What is left is hidden: an unfinished purge's folder, or a temp file.
        try FileManager.default.removeItem(at: trashDir)
        WriteCheckpoint.reached("unlinked", at: trashDir)
    }

    /// **Puts a stash or a restore that died part-way on the side its sidecars
    /// name** — the arbiter the format already has (slice 65, fork e). Run by the
    /// open that finds the sentinel, after the rebuild, so the index is what the
    /// sidecars say.
    ///
    /// - **A file whose record still claims it** is a detach that died before
    ///   the record moved on, or a restore that died after it did: its bytes go
    ///   back to the path the record names, and the entry goes.
    /// - **An artifact entry with no payload** restores nothing: a stash that
    ///   died before its move, or a restore that died after it.
    /// - **A folder with neither record nor payload** is a stash that died before
    ///   writing anything; **a hidden purging folder** is a purge that did.
    ///
    /// **Not a subject a delivery is bringing** (`/code-review`, 65). The sentinel
    /// says this machine crashed, not who wrote a `.trash/` entry, and a sync
    /// delivery brings `.trash/` and `artifacts/` in any order: another machine's
    /// detach whose record has not landed looks exactly like a torn one of ours,
    /// and putting its bytes back would strand them and purge its trash entry
    /// everywhere. `arriving` answers that per record path, from the manifest. A
    /// `.trash/` entry that arrives before even the manifest does is
    /// indistinguishable, and is the residue.
    ///
    /// A payload with no `deletion.json` is left alone: since 65 nothing writes
    /// that shape, so it is a stash torn by an earlier build, and recovering one
    /// is out of scope. Best-effort throughout — a step that fails leaves the
    /// entry as it found it.
    static func reconcileAfterInterruptedWrite(
        in root: URL, index: ArchiveIndex, arriving: (_ recordPath: String) -> Bool
    ) {
        let fm = FileManager.default
        let trashDir = ArchiveLayout.trashDirectory(in: root)
        guard
            let directories = try? fm.contentsOfDirectory(
                at: trashDir, includingPropertiesForKeys: nil, options: [])
        else { return }

        func recordPath(slug: String) -> String {
            ArchiveLayout.relativePath(of: ArchiveLayout.recordURL(in: root, slug: slug), in: root)
        }

        for directory in directories {
            let name = directory.lastPathComponent
            if name.hasPrefix(purgingPrefix) {
                try? fm.removeItem(at: directory)
                continue
            }
            guard !name.hasPrefix(".") else { continue }
            let uid = name
            let payload = payloadURL(uid: uid, in: root)
            let hasPayload = fm.fileExists(atPath: payload.path)
            guard let entry = entry(uid: uid, in: root) else {
                if !hasPayload { try? purge(uid: uid, in: root) }
                continue
            }
            switch entry.kind {
            case .artifact:
                guard !hasPayload, let info = entry.artifact else { continue }
                let slug = (try? index.slug(for: info.uid)) ?? info.originalSlug
                guard !arriving(recordPath(slug: slug)) else { continue }
                try? purge(uid: uid, in: root)
            case .file:
                guard let info = entry.file,
                    let artifact = try? index.artifact(info.artifactUID),
                    let claimed = artifact.files.first(where: { $0.uid == info.entry.uid }),
                    let slug = try? index.slug(for: artifact.uid),
                    !arriving(recordPath(slug: slug))
                else { continue }
                if hasPayload {
                    let destination = ArchiveLayout.artifactDirectory(in: root, slug: slug)
                        .appendingPathComponent(claimed.path)
                    guard !fm.fileExists(atPath: destination.path),
                        (try? fm.moveItem(at: payload, to: destination)) != nil
                    else { continue }
                    WriteCheckpoint.reached("moved", at: destination)
                }
                try? purge(uid: uid, in: root)
            }
        }
    }

    // MARK: - Internals

    private static func resetEntryDirectory(uid: String, in root: URL) throws {
        let entryDir = ArchiveLayout.trashEntryDirectory(in: root, uid: uid)
        try purge(uid: uid, in: root)
        try FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)
        WriteCheckpoint.reached("created", at: entryDir)
    }

    private static func writeRecord(_ entry: TrashEntry, uid: String, in root: URL) throws {
        try AtomicIO.writeJSON(entry, to: ArchiveLayout.trashRecordURL(in: root, uid: uid))
    }
}

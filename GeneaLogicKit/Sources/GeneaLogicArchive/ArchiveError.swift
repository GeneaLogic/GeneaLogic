import Foundation
import GeneaLogicModel

/// Why `abandonDelivery(path:)` refused — see
/// `ArchiveError.notAwaitingDelivery(path:reason:)`.
public enum NotAwaitingReason: Sendable, Equatable {
    /// `manifest.files` has no entry for the path.
    case notInManifest
    /// The file on disk is exactly what the manifest records, so nothing is
    /// outstanding for it.
    case fileMatches
    /// The file disagrees with the manifest, but no delivery covers the entry —
    /// the finding is damage, and `verifyIntegrity()` reports it as such.
    case notADelivery
    /// The path is an artifact **payload** file, whose expected checksum the
    /// manifest does not author — it is re-derived every commit from the
    /// `record.json` that claims the file. Dropping the entry therefore achieves
    /// nothing: the next recompute puts it straight back.
    case notManifestAuthored
    /// A write to this archive died before its manifest was updated, and
    /// `verifyIntegrity()` classifies that ahead of an arrival. The local bytes
    /// may be half a commit rather than a good older version, so blessing them
    /// is `rebaseline()`'s decision, behind its own warning.
    case interruptedWrite
}

/// Errors thrown by `Archive` and its supporting types.
public enum ArchiveError: Error, Equatable, CustomStringConvertible {
    /// `create(at:)` was called at a location that already contains an archive
    /// (a `manifest.json` is already present).
    case alreadyExists(URL)

    /// `open(at:)` was called at a location that is not a directory, or has no
    /// `manifest.json`.
    case notAnArchive(URL)

    /// The on-disk `manifest.json` could not be read or decoded. `underlying` is
    /// a one-line human reason (`DecodingFailure.summary`), not an error dump.
    ///
    /// There is deliberately no skip path here (slice 63, fork e): the manifest
    /// is the archive's ledger and `archiveUID`, and reconstructing it from the
    /// sidecars on open is the laundering 49 fork (a) gates behind a human
    /// decision. What the message can honestly add is what is still true — the
    /// records are untouched — and where the file can come from.
    case corruptManifest(URL, underlying: String)

    /// No artifact with the given id exists in this archive.
    case artifactNotFound(ArtifactID)

    /// `restoreFromTrash(_:)` was given a uid that has no recoverable entry in
    /// `.trash/` (never deleted, already restored, or emptied).
    case trashEntryNotFound(ArtifactID)

    /// `restoreFile(_:)` was given a file uid that has no recoverable entry in
    /// `.trash/` (never detached, already restored, or permanently deleted).
    case fileTrashEntryNotFound(FileID)

    /// No file with the given id exists on the given artifact.
    case fileNotFound(FileID, on: ArtifactID)

    /// No person with the given id exists in this archive.
    case personNotFound(PersonID)

    /// No relationship with the given id exists in this archive.
    case relationshipNotFound(RelationshipID)

    /// No evidence link with the given id exists in this archive.
    case evidenceLinkNotFound(EvidenceLinkID)

    /// No dismissal with the given id exists in this archive.
    case dismissalNotFound(DismissalID)

    /// `dismiss(_:between:and:...)` was given the same person twice. Every subject in
    /// the vocabulary is a claim *between* two people, so a pair that is one person is
    /// not something any suggestion lane can propose or a human decline.
    case cannotDismissPersonAgainstItself(PersonID)

    /// `link(_:to:...)` was given a `MentionRef` whose `localRef` does not match
    /// any `PersonMention.localRef` in the named artifact's `personsMentioned`.
    case mentionNotFound(String, on: ArtifactID)

    /// `mergePersons(_:into:)` was given the same person twice. Merging a record
    /// into itself has no meaning, and the cascade would delete the survivor.
    case cannotMergePersonIntoItself(PersonID)

    /// The source file for `attachFile`/`replaceFile` does not exist or is not a
    /// regular file.
    case sourceFileNotReadable(URL)

    /// A sanitized candidate name still collided with a reserved name
    /// (`record.json`/`manifest.json`) after disambiguation — should not happen
    /// in practice (disambiguation always finds a free name), but guards against
    /// a logic error silently producing a colliding path.
    case nameCollisionWithReserved(String)

    /// `repair()` was invoked — it is a flagged stub in Phase 1 (see its doc comment).
    case repairNotImplemented

    /// A record's file on disk is not the one GeneaLogic last wrote, and the
    /// mutation would have overwritten it (slice 58, fork f). **Nothing was
    /// written** — the point of the error is that the other version still exists.
    /// See `Archive.refuseToOverwriteDriftedRecord`; `rebaseline()` is the
    /// resolution.
    case recordDriftedOnDisk(path: String)

    /// The same refusal as `recordDriftedOnDisk`, on an archive that is **part
    /// way through receiving a change from another machine** (slice 60,
    /// hand-test). **Nothing was written.**
    ///
    /// It is a separate case purely because the *advice* inverts. Accepting the
    /// current contents is right for a hand edit and destructive here: it records
    /// the stale local bytes as the truth, so the incoming record lands as a
    /// reported corruption rather than an adoption and the other machine's change
    /// is discarded. The remedy is to wait for the delivery to finish, after
    /// which the edit proceeds normally.
    case recordAwaitingDelivery(path: String)

    /// The same refusal again, on an archive whose index **has never settled a
    /// delivery** and so cannot tell the two apart (slice 60b, fork c).
    /// **Nothing was written.**
    ///
    /// It exists because both other messages would be a claim this state does not
    /// support. `recordDriftedOnDisk` says to accept the current contents, which
    /// discards an incoming version if that is what this is;
    /// `recordAwaitingDelivery` says to wait, which promises an arrival on
    /// evidence the archive does not have. What it can honestly say is that the
    /// file differs from what GeneaLogic recorded and this machine has no history
    /// to judge it by — reached whenever `.index/` is fresh, which any copy,
    /// restore or `rsync` that drops it produces.
    case recordDriftedWithNoHistory(path: String)

    /// `repairRecord(atPath:)` was asked to restore a record the index kept no
    /// copy of (slice 59). A normal state, not a fault: a record that never
    /// decoded on any rebuild was never in the index, and the copy does not
    /// survive the rebuilds that unlink the database (58). Ask
    /// `repairPlan(forRecordAt:)` first.
    case noPreservedCopy(path: String)

    /// The preserved copy does not re-create the bytes the manifest recorded for
    /// that path, and the caller did not say to accept an inexact restore
    /// (slice 59, fork a). **Nothing was written.**
    ///
    /// What produces it is version skew: a sidecar written by a newer GeneaLogic
    /// carrying fields this version doesn't model, which decode drops and
    /// re-encode omits. The restore is then the last version *this* GeneaLogic
    /// could read rather than the last version written, so it is a different
    /// offer and is made separately.
    case repairNotByteExact(path: String)

    /// `abandonDelivery(path:)` was asked for a path the archive is **not**
    /// waiting on — slice 50d fork (b). **Nothing was written.**
    ///
    /// Three shapes reach it, and the third is the one the gate exists for: the
    /// manifest does not name the path at all; it names it and the file on disk
    /// matches, so there is no expectation to withdraw; or it names it, the file
    /// disagrees, and **no delivery covers the entry** — which is *damage*, not a
    /// delivery that stopped coming. Letting the verb through there would re-mint
    /// rot from disk into the manifest under a friendlier name than `rebaseline`,
    /// which is exactly the laundering 49 fork (a) gates behind a human decision
    /// **per finding**. `reason` says which shape it was so a host can explain
    /// it rather than repeating the request back.
    case notAwaitingDelivery(path: String, reason: NotAwaitingReason)

    /// Another process held the archive's write lock for longer than
    /// `ArchiveLock.timeout` (slice 47, fork d). The URL is the archive root;
    /// `holderPID` is the pid the lockfile records, where it is obtainable — so
    /// a UI can name the other process rather than reporting a generic failure.
    case archiveBusy(URL, holderPID: Int32?)

    /// The archive's lockfile (`.index/lock`) could not be opened or locked at
    /// all — a read-only or otherwise unusable `.index/`, not contention.
    /// Distinct from `archiveBusy` because waiting will not help.
    case lockUnavailable(URL, underlying: String)

    /// The archive — `manifest.json`, or one record in it — carries a format
    /// version newer than this build writes (slice 64, forks c and d). **Nothing
    /// was written.** `path` is archive-relative and names the file whose stamp
    /// said so; `found` is that stamp, `supported` is `SchemaVersion.current`.
    ///
    /// A record's stamp may say it before the manifest does: a sync provider
    /// delivers files one at a time, and a record edited on a machine that has
    /// upgraded the archive lands before the manifest that records the upgrade.
    /// Either way the evidence is the same — the *archive* is newer than this
    /// build knows — and it is refused at the door rather than decoded with the
    /// fields this build does not model dropped and written back down.
    ///
    /// **This is not 55's forbidden refusal.** That rule forbids closing the
    /// archive over a file the engine cannot *read*; this closes it over a file
    /// it reads perfectly, with the reason and the fix in the message. The trade
    /// is stated rather than hidden: a hand-edited `"schemaVersion": "9.9"` locks
    /// the archive, naming the file and the field — a field the spec says the
    /// engine owns.
    case archiveNewerThanBuild(path: String, found: String, supported: String)

    /// The archive's format is older than this build writes and it has not been
    /// upgraded (slice 64, fork a). **Nothing was written.** Migration is
    /// explicit: `Archive.upgrade(at:)` (`genea upgrade`) runs the pipeline, and
    /// the person running it is consenting to lock out any machine still on the
    /// older build — which is why `open` does not do it silently.
    case needsUpgrade(from: String, to: String)

    /// `upgrade(at:)` found no chain of steps from the archive's version to this
    /// build's. Either the manifest's `schemaVersion` was edited to a version no
    /// build has written, or the build is missing a step it should have — the
    /// message assumes the first, since the second cannot ship.
    case noUpgradePath(from: String, to: String)

    /// `repairRecord(atPath:)` was asked to restore a record that is not damaged
    /// — it reads perfectly, and is absent from the index only because its
    /// format stamp is older than the archive's (slice 64, fork e). **Nothing was
    /// written.** Restoring the preserved copy over it would replace the record
    /// with an earlier version of itself, which is the data loss the version
    /// rule exists to prevent; the record is migration's to bring forward.
    case repairNotForOlderFormat(path: String)

    /// `deleteVanishedRecord(atPath:)` found something at `path` (slice 58d):
    /// the record is unreadable rather than gone, or its file came back since a
    /// host last looked. **Nothing was changed** — checked under the write lock.
    case recordNotMissing(path: String)

    /// A restore of the record at `path` — Restore, or the restore Delete runs
    /// first (slice 71) — found a **file** at `by`, where a folder on that path
    /// should be. The record is missing, but nothing can be put back under a
    /// file. **Nothing was changed**; once `by` is moved aside, either works.
    case recordPathBlocked(path: String, by: String)

    /// A SQLite call against the `.index/index.sqlite` derived index failed.
    /// `context` names the operation (e.g. `"open"`, `"prepare upsert artifact"`)
    /// and `message`/`code` are SQLite's own `sqlite3_errmsg`/result code —
    /// surfaced verbatim so a failure here is debuggable rather than a bare
    /// "something went wrong."
    case indexError(context: String, message: String, code: Int32)

    public var description: String {
        switch self {
        case .alreadyExists(let url):
            return "An archive already exists at \(url.path)."
        case .notAnArchive(let url):
            return "No GeneaLogic archive found at \(url.path) (missing manifest.json)."
        case .corruptManifest(let url, let underlying):
            return
                "\(url.lastPathComponent) in \(url.deletingLastPathComponent().path) could "
                + "not be read: \(underlying). The archive's records are untouched — "
                + "restore \(url.lastPathComponent) from a backup or another copy of the "
                + "archive."
        case .artifactNotFound(let id):
            return "No artifact with id \(id.raw)."
        case .trashEntryNotFound(let id):
            return "No recoverable trash entry for artifact \(id.raw)."
        case .fileTrashEntryNotFound(let id):
            return "No recoverable trash entry for file \(id.raw)."
        case .fileNotFound(let fileID, let artifactID):
            return "No file with id \(fileID.raw) on artifact \(artifactID.raw)."
        case .personNotFound(let id):
            return "No person with id \(id.raw)."
        case .relationshipNotFound(let id):
            return "No relationship with id \(id.raw)."
        case .evidenceLinkNotFound(let id):
            return "No evidence link with id \(id.raw)."
        case .dismissalNotFound(let id):
            return "No dismissal with id \(id.raw)."
        case .cannotDismissPersonAgainstItself(let id):
            return "Cannot record a dismissal between person \(id.raw) and itself."
        case .mentionNotFound(let localRef, let artifactID):
            return "No person mention with localRef '\(localRef)' on artifact \(artifactID.raw)."
        case .cannotMergePersonIntoItself(let id):
            return "Cannot merge person \(id.raw) into itself."
        case .sourceFileNotReadable(let url):
            return "Cannot read source file at \(url.path)."
        case .nameCollisionWithReserved(let name):
            return "Generated name '\(name)' collides with a reserved name."
        case .repairNotImplemented:
            return "Archive.repair() is not implemented in Phase 1 (stub)."
        case .recordDriftedOnDisk(let path):
            return
                "\(path) changed on disk after GeneaLogic last wrote it, so nothing was "
                + "written. Verify the archive's integrity and accept its current contents "
                + "to keep the version that is on disk, then try again."
        case .recordAwaitingDelivery(let path):
            return
                "\(path) is still arriving from another machine, so nothing was written. "
                + "Wait for the change to finish arriving, then try again. Do not accept "
                + "the current contents — that would discard the incoming version."
        case .recordDriftedWithNoHistory(let path):
            return
                "\(path) is not the version GeneaLogic recorded, so nothing was written. "
                + "This copy of the archive has no history yet, so it cannot tell a damaged "
                + "file from a change still arriving from another machine — check the file "
                + "before either accepting its current contents or waiting."
        case .noPreservedCopy(let path):
            return
                "GeneaLogic has no saved copy of \(path), so it cannot be restored. "
                + "The file has to be repaired by hand or replaced from a backup."
        case .notAwaitingDelivery(let path, let reason):
            switch reason {
            case .notInManifest:
                return
                    "\(path) is not tracked by this archive's manifest, so there is no "
                    + "delivery to stop waiting for."
            case .fileMatches:
                return
                    "\(path) already matches what the manifest records, so nothing is "
                    + "awaited for it."
            case .notADelivery:
                return
                    "\(path) disagrees with the manifest, but no delivery from another "
                    + "machine accounts for it — that is damage, not a delivery that "
                    + "stopped coming. Verify the archive and repair the file; do not "
                    + "abandon it."
            case .notManifestAuthored:
                return
                    "\(path) is a file attached to an artifact, and its checksum is "
                    + "recorded by the artifact that claims it rather than by the "
                    + "manifest, so there is no manifest expectation to withdraw. If the "
                    + "file is never going to arrive, detach it from its artifact."
            case .interruptedWrite:
                return
                    "A write to this archive did not finish, so \(path) may be half a "
                    + "change of this machine's own rather than an older version of "
                    + "someone else's. Check the file, then accept the archive's current "
                    + "contents to keep it as it stands."
            }
        case .repairNotByteExact(let path):
            return
                "The saved copy of \(path) is not byte-identical to what the manifest "
                + "recorded, so nothing was written. It is the last version this "
                + "GeneaLogic could read, which may be missing fields written by a newer "
                + "one. Restore it explicitly to accept that."
        case .archiveNewerThanBuild(let path, let found, let supported):
            return
                "\(path) was written in archive format \(found), and this GeneaLogic writes "
                + "\(supported). Nothing was changed. Update GeneaLogic to open this "
                + "archive — or, if nobody has, check the file's schemaVersion, which "
                + "GeneaLogic sets itself."
        case .needsUpgrade(let from, let to):
            return
                "This archive is in format \(from), and this GeneaLogic writes \(to). Nothing "
                + "was changed. Run `genea upgrade` to bring the archive forward — after "
                + "which any machine still on an older GeneaLogic will no longer be able to "
                + "open it."
        case .noUpgradePath(let from, let to):
            return
                "This archive says it is in format \(from), which no GeneaLogic has written, "
                + "so there is no upgrade to \(to) from it. Nothing was changed. Check "
                + "manifest.json's schemaVersion."
        case .repairNotForOlderFormat(let path):
            return
                "\(path) is not damaged: it reads, but it was written in an older archive "
                + "format than the rest of the archive, so nothing was written. Restoring "
                + "the saved copy would replace it with an earlier version of itself; an "
                + "upgrade is what brings it forward."
        case .recordNotMissing(let path):
            return
                "Something is at \(path), so nothing was deleted — the record isn't missing. "
                + "Check the archive again."
        case .recordPathBlocked(let path, let blocker):
            return
                "\(blocker) is a file, not a folder, so \(path) can't be put back there. "
                + "Nothing was changed. Move that file aside and try again."
        case .archiveBusy(let url, let pid):
            let who = pid.map { " (process \($0))" } ?? ""
            return "Another process\(who) is writing the archive at \(url.path)."
        case .lockUnavailable(let url, let underlying):
            return "Could not lock the archive at \(url.path): \(underlying)"
        case .indexError(let context, let message, let code):
            return "Index error during \(context): \(message) (SQLite code \(code))."
        }
    }
}

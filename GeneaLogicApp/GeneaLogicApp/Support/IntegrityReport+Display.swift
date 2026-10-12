import Foundation
import GeneaLogicArchive

extension IntegrityReport.Issue {
    /// Whether an issue is a real data problem (a tracked file is gone, corrupt,
    /// or the wrong size) or merely informational (an extra file lying in an
    /// artifact folder). Drives the report's grouping and tint.
    enum Severity: CaseIterable {
        case corruption
        case stray
        /// A write that died before the manifest caught up (slice 49). Its own
        /// tier because it is neither: the file is probably the *newer* version
        /// and the manifest is behind, which is a different thing to tell
        /// someone than "your data is damaged."
        case interrupted
        /// A change still arriving from another machine (slice 60). Shares
        /// `interrupted`'s reasoning — the manifest is ahead of the disk, which is
        /// not damage — but must be its own tier because the *remedy* is the
        /// opposite: Accept Current Contents is exactly what must not be done, or
        /// the incoming version is discarded.
        case arriving
        /// A second file claiming to be a record the archive already has
        /// (slice 50c). **Not `stray`,** though it is equally not damage: a
        /// stray file is junk nobody claims, and "Stray Files" invites the user
        /// to delete it unread — while this one holds a version of their own
        /// data, quite possibly the edit another machine made. The section it
        /// gets its own name for is the whole point.
        case duplicate
    }

    var severity: Severity {
        switch self {
        // An unreadable record (slice 55) groups with corruption rather than
        // earning a fourth tier: whatever the cause, a record the archive cannot
        // read is data the user has lost sight of, which is what that section
        // means. Its `detail` carries the part that is specific to it.
        // A misnamed record (slice 50c) groups here for `.unreadableRecord`'s
        // reason and not `.duplicate`'s: the archive is not serving that record
        // at all, so this is data the user has lost sight of — the opposite of a
        // second copy of something they still have.
        case .checksumMismatch, .missingFile, .sizeMismatch, .unreadableRecord, .misnamedRecord:
            .corruption
        case .unreferencedFile: .stray
        case .interruptedWrite: .interrupted
        case .awaitingDelivery: .arriving
        case .conflictingCopy: .duplicate
        }
    }

    // `path` used to be duplicated here; it is `IntegrityReport.Issue`'s own
    // property now (the engine needs it for `isResolvableByRebaseline`), and one
    // switch over the cases is enough.

    /// A short kind label shown as the row's headline.
    var summary: String {
        switch self {
        case .checksumMismatch: "Checksum mismatch"
        case .missingFile: "Missing file"
        case .sizeMismatch: "Size mismatch"
        case .unreferencedFile: "Unreferenced file"
        case .interruptedWrite: "Interrupted write"
        case .awaitingDelivery: "Still arriving"
        case .unreadableRecord(_, .undecodable): "Unreadable record"
        case .unreadableRecord(_, .olderFormat): "Record in an older format"
        case .conflictingCopy: "Conflicting copy"
        case .misnamedRecord: "Record under the wrong name"
        }
    }

    /// A one-line explanation of the issue, shown beneath the path.
    var detail: String {
        switch self {
        case .checksumMismatch:
            "On-disk contents differ from the recorded SHA-256 (corruption or an out-of-band edit)."
        case .missingFile:
            "Listed in the manifest but absent on disk."
        case .sizeMismatch(_, let expected, let actual):
            Self.sizeDifference(expected: expected, actual: actual)
        case .unreferencedFile:
            "Present in an artifact folder but tracked by neither its record nor the manifest."
        case .interruptedWrite:
            "A write to this archive didn't finish. This file may simply be newer than the "
                + "record of it — check it, then use Accept Current Contents."
        case .awaitingDelivery:
            "A change to this file is still arriving from another machine. Wait for it to "
                + "finish — don't use Accept Current Contents, which would discard it."
        case .unreadableRecord(_, .undecodable):
            "This record couldn't be read, so everything in it is missing from the archive's "
                + "index. The rest of the archive opened normally."
        case .unreadableRecord(_, .olderFormat):
            // Not damage (slice 64): the file is intact and Repair refuses it, so the
            // wording must not read as a loss to be recovered.
            "This record was written in an older archive format than the archive itself, so "
                + "it's left out of the index until an upgrade brings it forward. The file is "
                + "intact — don't repair or replace it."
        case .conflictingCopy:
            "A second copy of a record this archive already has, most likely left by a sync "
                + "service that couldn't merge it. The archive is using the original, not this "
                + "file — look at it before deleting it, because it holds a version of your data."
        case .misnamedRecord(_, let uid):
            "This file holds record \(uid) but isn't named for it, and no file that is holds it "
                + "either — so the archive isn't using it at all. This may be the only copy. "
                + "Rename it to \(uid).json, then use Rebuild Index to pick it up."
        }
    }

    /// "Expected X, found Y" — in friendly units when those two actually read
    /// differently, and in exact bytes when they do not.
    ///
    /// **`.byteCount` rounds, and a manifest mismatch is often small** (hand-test):
    /// 1,656 against 1,652 bytes both format as "2 kB", so the row said *Expected
    /// 2 kB, found 2 kB* — a finding that reads as a bug in the app rather than one
    /// in the archive. The friendly form is kept where it is informative, because
    /// "Expected 4.2 MB, found 1.1 MB" is easier to act on than nine digits; it is
    /// dropped the moment it would print the same number twice.
    static func sizeDifference(expected: Int64, actual: Int64) -> String {
        let friendlyExpected = expected.formatted(.byteCount(style: .file))
        let friendlyActual = actual.formatted(.byteCount(style: .file))
        guard friendlyExpected == friendlyActual else {
            return "Expected \(friendlyExpected), found \(friendlyActual)."
        }
        return "Expected \(expected.formatted()) bytes, found \(actual.formatted()) bytes."
    }

    /// SF Symbol for the row.
    var systemImage: String {
        switch severity {
        case .corruption: "exclamationmark.octagon.fill"
        case .stray: "questionmark.folder.fill"
        case .interrupted: "clock.badge.exclamationmark.fill"
        case .arriving: "arrow.down.circle.fill"
        case .duplicate: "doc.on.doc.fill"
        }
    }

    /// A stable, content-derived identity for `ForEach` (no two issues share a
    /// kind *and* a path, so this is unique and deterministic across re-renders —
    /// no transient `UUID` churn).
    var id: String { "\(summary)#\(path)" }
}

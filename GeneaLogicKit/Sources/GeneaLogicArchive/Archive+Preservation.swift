import Foundation
import GeneaLogicModel

/// The last copy of a record the archive can no longer read (slice 58).
extension Archive {

    /// A record that could not be read from disk, and the bytes the index still
    /// holds for it.
    ///
    /// **`json` is not a reconstruction.** The index stores each record as the
    /// output of the same deterministic encoder (`GeneaLogicJSONCoding.encoder`,
    /// `.sortedKeys`) that wrote the sidecar, so it is byte-identical to the file
    /// as GeneaLogic last wrote it — which is what lets 59 restore it *and prove
    /// the restoration exact* against the manifest's recorded `sha256`, rather
    /// than regenerating something plausible from a cache.
    ///
    /// It is emphatically **not** a live record: it is deliberately absent from
    /// every lookup (see `ArchiveIndex.preservedRecord(atPath:)`), and this type
    /// hands out bytes rather than an `Artifact`/`Person`/… so that a caller
    /// cannot mistake one for the other. A record written by a *newer*
    /// GeneaLogic may not even round-trip through this version's model — the
    /// case 59's checksum gate exists to catch.
    public struct PreservedRecord: Sendable, Equatable {
        /// Archive-relative path of the file this is a copy of — one of
        /// `StandingFindings.unreadableRecords` or `StandingFindings.vanished`.
        public let path: String

        /// The record's `uid`, as the index recorded it. A `String` because the
        /// kind is only knowable from `path`, and this call refuses to guess.
        public let uid: String

        /// The sidecar's bytes, as GeneaLogic last wrote them.
        public let json: Data

        public init(path: String, uid: String, json: Data) {
            self.path = path
            self.uid = uid
            self.json = json
        }
    }

    /// The preserved copy for `path`, if a rebuild had one to keep.
    ///
    /// **Ask; don't assume from the findings.** Some of
    /// `standingFindings().unreadableRecords` have no copy — a record that never
    /// decoded on any rebuild (a corrupt file dropped in from elsewhere) was
    /// never in the index, so there is nothing to return. And some paths with a
    /// copy are in no finding of that kind: a sidecar that has *vanished* is
    /// skipped by the walk silently and reported as a missing file instead. A row
    /// that promises a restore it cannot perform is the lie 56 was careful not to
    /// tell, so the presence of the copy is the thing to test.
    public func preservedRecord(atPath path: String) throws -> PreservedRecord? {
        try withIndex { index in
            try index.preservedRecord(atPath: path).map {
                PreservedRecord(path: path, uid: $0.uid, json: $0.json)
            }
        }
    }

    /// Every path that has a preserved copy, sorted.
    public func preservedRecordPaths() throws -> [String] {
        try withIndex { index in try index.preservedRecordPaths() }
    }

    /// Discards the preserved copy for `path`. Lenient if there isn't one. A copy
    /// otherwise goes only when its record reads again (58 fork c) or when a
    /// rebuild finds it was **deleted** — the manifest has let the path go and
    /// nothing is there (58c; see `ArchiveIndex.rebuild`).
    ///
    /// **This can be the last copy of a record**, which is why nothing in the
    /// engine calls it: a rebuild keeps a lost record's copy, a repair (59)
    /// consumes it, and anything else needs a human to say so.
    ///
    /// **For a record whose sidecar vanished, this is accepting the loss** (58c).
    /// Its manifest entry — and an artifact's payload entries — are carried only
    /// on the copy's account, so this mutation's `commitManifest` drops them: the
    /// `missingFile` finding goes, and an artifact's masters leave the integrity
    /// surface with their record. `rebaseline()` deliberately does not do this.
    /// For an unreadable record the file is still there, so its entry stays.
    ///
    /// **Hosts don't call this** (58d): deleting a missing record is
    /// `deleteVanishedRecord(atPath:)`, which restores the record and deletes it
    /// the ordinary way, so it can be undone.
    public func discardPreservedRecord(atPath path: String) throws {
        try withState { _, index in
            try index.discardPreservedRecord(atPath: path)
        }
    }
}

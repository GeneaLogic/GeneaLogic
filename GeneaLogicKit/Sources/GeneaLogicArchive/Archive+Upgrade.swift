import Foundation
import GeneaLogicModel

/// Bringing an archive forward to this build's format version (slice 64, fork a).
///
/// `open` refuses an older archive rather than upgrading it, because an upgrade
/// is not free for the *other* machines: every one still on the older build loses
/// the archive the moment this one writes the new version. So the person, not the
/// engine, decides — `genea upgrade`, and later an app affordance once there is a
/// version to upgrade to.
extension Archive {

    /// What `upgrade(at:)` did.
    public struct UpgradeOutcome: Sendable, Equatable {
        /// The manifest's version before — equal to `to` when there was nothing
        /// to do.
        public let from: String
        /// `SchemaVersion.current`.
        public let to: String

        public var wasAlreadyCurrent: Bool { from == to }

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// Upgrades the archive at `url` to `SchemaVersion.current`, in place.
    ///
    /// Runs `Migration`'s chain from the archive's version, stamping the
    /// manifest after each step; then opens the archive once, which rebuilds this
    /// machine's index from the rewritten files and re-mints the manifest entries
    /// the steps invalidated. An archive already at the current version is left
    /// exactly as it is — no write, not even `updatedAt` — unless its manifest is
    /// a straggler behind its records (see `Migration.check`), in which case the
    /// open corrects the stamp and nothing else.
    ///
    /// - Throws: `ArchiveError.archiveNewerThanBuild` when the archive is *ahead*
    ///   of this build (nothing to upgrade to, and nothing is touched);
    ///   `ArchiveError.noUpgradePath` when its version is one no build has
    ///   written; otherwise what `open` throws.
    public static func upgrade(at url: URL) throws -> UpgradeOutcome {
        try upgrade(at: url, migration: .shared)
    }

    /// The testable form — see `Migration.shared`.
    static func upgrade(at url: URL, migration: Migration) throws -> UpgradeOutcome {
        let fm = FileManager.default
        let manifestURL = ArchiveLayout.manifestURL(in: url)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.notAnArchive(url)
        }
        try fm.createDirectory(
            at: ArchiveLayout.indexDirectory(in: url), withIntermediateDirectories: true)
        let fileLock = try ArchiveLock(at: ArchiveLayout.lockURL(in: url), archiveRoot: url)

        enum Work {
            case nothing
            case stragglerManifest
            case migrated(from: String)
        }
        let work = try fileLock.withLock { () throws -> Work in
            var manifest = try readManifest(at: manifestURL)
            if manifest.schemaVersion == SchemaVersion.current {
                // The door still runs (`/code-review`, 70): a record ahead of a
                // current manifest makes the archive newer than this build, and
                // `upgrade` saying *already current* where `open` refuses would be
                // two answers about one archive.
                try Migration.check(manifest: manifest, archiveAt: url)
                return .nothing
            }
            // The same question `open` asks, with the same answer for a manifest
            // that is merely behind an archive already at this build's version
            // (`/code-review`, 64): nothing to migrate — the open below puts the
            // straggler's stamp right, as any open would.
            let from: String
            do {
                try Migration.check(manifest: manifest, archiveAt: url)
                return .stragglerManifest
            } catch ArchiveError.needsUpgrade(let archiveVersion, _) {
                from = archiveVersion
            }
            // Resolved in full before the first step runs, so a gap in the chain
            // is a refusal and never a half-migrated archive.
            let chain = try migration.path(from: from)

            for step in chain {
                let rewritten = Set(try step.apply(url))
                // Re-read rather than trusting the copy in hand: a step is
                // entitled to rewrite the manifest's *files* (renaming a
                // sidecar, say), just not to stamp it.
                manifest = try readManifest(at: manifestURL)
                // The entries for what the step rewrote describe bytes that no
                // longer exist. Absent means *unverified, never tampered* (49,
                // fork f), so the commit below re-mints them from disk — the
                // one situation, besides `rebaseline()`, where that is right:
                // the engine itself just wrote those files.
                manifest.files.removeAll { rewritten.contains($0.path) }
                manifest.schemaVersion = step.toVersion
                manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
                try writeManifest(manifest, at: url)
            }

            // This machine's index rows were decoded from the old shape. The
            // dirty sentinel makes the open below rebuild them **in place** —
            // never by unlinking, which would lose 58's preserved copies. Other
            // machines' indexes are their own, and rebuild through the witness
            // when the rewritten manifest reaches them.
            try IndexDirtyMarker.set(in: url)
            return .migrated(from: from)
        }

        switch work {
        case .nothing:
            return UpgradeOutcome(from: SchemaVersion.current, to: SchemaVersion.current)
        case .stragglerManifest:
            // An open is exactly the write that puts the stamp right, and no other.
            _ = try open(at: url)
            return UpgradeOutcome(from: SchemaVersion.current, to: SchemaVersion.current)
        case .migrated(let from):
            // Rebuilds under the sentinel, then one empty mutation whose closing
            // commit recomputes the manifest — minting the entries dropped above.
            let archive = try open(at: url)
            try archive.withState { _, _ in }
            return UpgradeOutcome(from: from, to: SchemaVersion.current)
        }
    }
}

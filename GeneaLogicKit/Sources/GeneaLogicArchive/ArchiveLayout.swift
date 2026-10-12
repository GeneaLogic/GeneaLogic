import Foundation
import GeneaLogicModel

/// Centralizes the on-disk layout conventions from ARCHITECTURE.md §3 and the
/// format spec §2, so every part of the engine agrees on where things live.
enum ArchiveLayout {
    static let manifestFileName = "manifest.json"
    static let recordFileName = "record.json"

    static let artifactsDirectoryName = "artifacts"
    static let conclusionsDirectoryName = "conclusions"
    static let schemaDirectoryName = "schema"
    static let indexDirectoryName = ".index"
    static let trashDirectoryName = ".trash"
    static let damagedDirectoryName = ".damaged"
    static let trashPayloadName = "payload"
    static let trashRecordFileName = "deletion.json"

    static let personsDirectoryRelativePath = "\(conclusionsDirectoryName)/persons"
    static let relationshipsDirectoryRelativePath = "\(conclusionsDirectoryName)/relationships"
    static let linksDirectoryRelativePath = "\(conclusionsDirectoryName)/links"
    static let dismissalsDirectoryRelativePath = "\(conclusionsDirectoryName)/dismissals"

    /// The name the schema spec is copied in under, matching §3's
    /// `schema/genealogic-archive-1.0.md`.
    static let schemaSpecFileName = "genealogic-archive-1.0.md"

    static func manifestURL(in root: URL) -> URL {
        root.appendingPathComponent(manifestFileName)
    }

    static func artifactsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(artifactsDirectoryName, isDirectory: true)
    }

    static func artifactDirectory(in root: URL, slug: String) -> URL {
        artifactsDirectory(in: root).appendingPathComponent(slug, isDirectory: true)
    }

    static func recordURL(in root: URL, slug: String) -> URL {
        artifactDirectory(in: root, slug: slug).appendingPathComponent(recordFileName)
    }

    /// The slug in an artifact record path — `artifacts/<slug>/record.json` —
    /// or `nil` for any other path. The inverse of `recordURL(in:slug:)`'s
    /// relative form, and the one place that shape is parsed (58b). Empty
    /// components are skipped, as `RepairTarget` always skipped them.
    static func artifactSlug(ofRecordPath path: String) -> String? {
        guard path.hasSuffix("/\(recordFileName)") else { return nil }
        let components = path.split(separator: "/")
        guard components.count == 3, components[0] == artifactsDirectoryName else {
            return nil
        }
        return String(components[1])
    }

    static func personsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(personsDirectoryRelativePath, isDirectory: true)
    }

    static func relationshipsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(relationshipsDirectoryRelativePath, isDirectory: true)
    }

    static func linksDirectory(in root: URL) -> URL {
        root.appendingPathComponent(linksDirectoryRelativePath, isDirectory: true)
    }

    static func dismissalsDirectory(in root: URL) -> URL {
        root.appendingPathComponent(dismissalsDirectoryRelativePath, isDirectory: true)
    }

    /// `conclusions/<kind>/<uid>.json` — one conclusion record's sidecar.
    static func recordURL(in root: URL, person id: PersonID) -> URL {
        personsDirectory(in: root).appendingPathComponent("\(id.raw).json")
    }

    static func recordURL(in root: URL, relationship id: RelationshipID) -> URL {
        relationshipsDirectory(in: root).appendingPathComponent("\(id.raw).json")
    }

    static func recordURL(in root: URL, link id: EvidenceLinkID) -> URL {
        linksDirectory(in: root).appendingPathComponent("\(id.raw).json")
    }

    static func recordURL(in root: URL, dismissal id: DismissalID) -> URL {
        dismissalsDirectory(in: root).appendingPathComponent("\(id.raw).json")
    }

    static func schemaDirectory(in root: URL) -> URL {
        root.appendingPathComponent(schemaDirectoryName, isDirectory: true)
    }

    /// `.index/` — the reserved top-level directory (format spec §2). Excluded
    /// from `manifest.files` and exempted from `verifyIntegrity()`'s
    /// unreferenced-file sweep (Archive+Integrity.swift).
    ///
    /// A **container**, not an index: since slice 48 every machine writes into
    /// its own subdirectory of this one, so nothing lives directly here. Callers
    /// want `indexDirectory(in:)` — this exists for the passes that reason about
    /// the reserved name itself.
    static func indexContainerDirectory(in root: URL) -> URL {
        root.appendingPathComponent(indexDirectoryName, isDirectory: true)
    }

    /// `.index/<machine-key>/` — **this machine's** persistent, rebuildable
    /// index home (ARCHITECTURE.md §5; slice 48).
    ///
    /// One level deeper than it looks, and that level is the whole point: the
    /// package is synced, so a shared `.index/` had two machines writing one
    /// `index.sqlite`, one `lock` and one `dirty`. See `MachineKey` for what
    /// keys a machine and why. Everything below is derived from here, so the
    /// database, the lockfile and the dirty sentinel all move together.
    ///
    /// Nesting needs no new exclusions: the manifest recompute, the index
    /// rebuild and the integrity sweep are all scoped to `artifacts/` +
    /// `conclusions/`, so they walk past `.index/` at any depth.
    static func indexDirectory(in root: URL) -> URL {
        indexContainerDirectory(in: root)
            .appendingPathComponent(MachineKey.current, isDirectory: true)
    }

    /// A name in `directory` for a file the engine keeps rather than deletes —
    /// `<stem>-<UTC yyyyMMdd-HHmmss>.<ext>`, with a counter when one is already
    /// taken in the same second. UTC, so the order reads correctly on a machine
    /// that travels. Shared by `.damaged/` (slice 59) and a replaced index (69),
    /// so kept files are named one way.
    static func keptFileURL(in directory: URL, stem: String, extension ext: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(stem)-\(formatter.string(from: Date()))"
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var attempt = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(attempt).\(ext)")
            attempt += 1
        }
        return candidate
    }

    /// `.index/<machine-key>/index.sqlite` — the derived-index database file.
    static func indexDatabaseURL(in root: URL) -> URL {
        indexDirectory(in: root).appendingPathComponent("index.sqlite")
    }

    /// `.index/<machine-key>/lock` — the `flock(2)` target for `ArchiveLock`
    /// (slice 47, fork c).
    ///
    /// It lives beside the index rather than at the package root because a lock
    /// is exactly as machine-local and disposable as the index it guards, and
    /// `.index/` is already excluded from `manifest.files`, the index rebuild,
    /// and `verifyIntegrity()`'s unreferenced-file sweep. At the root it would
    /// surface in all three (and in any future BagIt conformance).
    ///
    /// **Resolved here, never hardcoded**, along with `indexDirtyMarkerURL` —
    /// which is what let slice 48 move both under a machine key by editing
    /// `indexDirectory(in:)` alone. Per-machine is right for a lock as well as a
    /// database: `flock(2)` never crossed machines anyway (one kernel, one
    /// arbiter), so a shared lockfile bought nothing that a per-machine one
    /// does not.
    static func lockURL(in root: URL) -> URL {
        indexDirectory(in: root).appendingPathComponent("lock")
    }

    /// `.index/<machine-key>/dirty` — the mutation-in-flight sentinel (see
    /// `IndexDirtyMarker`). Machine-local because the mutation it records was.
    static func indexDirtyMarkerURL(in root: URL) -> URL {
        indexDirectory(in: root).appendingPathComponent("dirty")
    }

    /// `.index/<machine-key>/interrupted` — an interrupted write left unresolved
    /// (see `InterruptedWriteMarker`). Machine-local for the same reason.
    static func interruptedWriteMarkerURL(in root: URL) -> URL {
        indexDirectory(in: root).appendingPathComponent("interrupted")
    }

    /// `.trash/` — recoverable storage for deleted items (ARCHITECTURE.md §3).
    /// Like `.index/`, a top-level **reserved** directory; because it is a *sibling*
    /// of `artifacts/`, the index rebuild, manifest recompute, and integrity sweep
    /// (all scoped to `artifacts/` + `conclusions/`) never descend into it — so a
    /// trashed item stays invisible to lookups and verification with no extra
    /// exclusion logic, and `rebuildIndex()` can never resurrect it.
    static func trashDirectory(in root: URL) -> URL {
        root.appendingPathComponent(trashDirectoryName, isDirectory: true)
    }

    /// `.trash/<uid>/` — one trashed item's home (its `payload` + `deletion.json`).
    static func trashEntryDirectory(in root: URL, uid: String) -> URL {
        trashDirectory(in: root).appendingPathComponent(uid, isDirectory: true)
    }

    /// `.trash/<uid>/payload` — the moved-aside bytes: an artifact folder today, a
    /// single file once detached-file trash ships (the kind tells callers which).
    static func trashPayloadURL(in root: URL, uid: String) -> URL {
        trashEntryDirectory(in: root, uid: uid).appendingPathComponent(trashPayloadName)
    }

    /// `.trash/<uid>/deletion.json` — the `TrashEntry` sidecar.
    static func trashRecordURL(in root: URL, uid: String) -> URL {
        trashEntryDirectory(in: root, uid: uid).appendingPathComponent(trashRecordFileName)
    }

    /// `.damaged/` — quarantined originals: the file a repair found in place
    /// before it restored the last copy GeneaLogic wrote (slice 59, fork c). The
    /// third top-level **reserved** directory, and like the other two a sibling of
    /// `artifacts/`, so every pass that is scoped to `artifacts/` + `conclusions/`
    /// walks past it without needing to know it exists.
    ///
    /// **Deliberately not `.trash/<something>/`,** though the fork proposed it.
    /// `.trash/` is a uid-keyed namespace — `TrashStore.entries` enumerates its
    /// children and reads each name as an item uid — so a folder in there under
    /// any other name is indistinguishable from a *corrupt trash entry*, surviving
    /// on the leniency that exists for those rather than by design. The meanings
    /// differ too, and in the direction that costs data: `.trash/` holds what the
    /// user deleted and can restore, and emptying it (`TrashStore.purgeAll`,
    /// which removes the whole directory) is permanent — so quarantined bytes
    /// parked there would be destroyed by a button whose listing never showed
    /// them. Nothing here is restorable by any action: putting a damaged record
    /// back is not something to offer, and these bytes are kept for a human to
    /// read, not for the engine to use.
    static func damagedDirectory(in root: URL) -> URL {
        root.appendingPathComponent(damagedDirectoryName, isDirectory: true)
    }

    /// Whether an archive-relative path names a file the **engine** authors — an
    /// artifact's `record.json` or a conclusion record — as opposed to payload
    /// the user attached (slice 49).
    ///
    /// The distinction matters because the two have different authorities for
    /// their checksums: a payload file's lives in the `record.json` that claims
    /// it, an authored file's lives only in `manifest.json`. It is what
    /// `verifyIntegrity()` classifies an interrupted write by, exactly what
    /// `rebaseline()` re-mints, and what `IntegrityReport.rebaselinableIssues`
    /// reports to a host.
    ///
    /// The archive's schema-spec copy is deliberately *not* included, in all
    /// three: nothing mutates it after `create`, so a difference there is damage
    /// rather than a write that died or an edit to bless.
    static func isEngineAuthored(relativePath path: String) -> Bool {
        if path.hasPrefix("\(conclusionsDirectoryName)/") { return true }
        return path.hasPrefix("\(artifactsDirectoryName)/")
            && path.hasSuffix("/\(recordFileName)")
    }

    /// The path of `url` relative to `root`, using forward slashes — the form
    /// stored in `ManifestEntry.path` ("relative to the archive root").
    static func relativePath(of url: URL, in root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath) {
            var relative = String(path.dropFirst(rootPath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            return relative
        }
        return path
    }
}

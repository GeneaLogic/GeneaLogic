import Foundation
import GeneaLogicModel

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Format-version migration (ARCHITECTURE.md §6.5; spec §8; slice 64).
///
/// `manifest.json` and every record carry `schemaVersion`, and **the version is
/// archive-wide**: every record's stamp MUST equal the manifest's, and a build
/// edits an archive only at the version it writes. Two consequences shape this
/// type:
///
/// - **Migration is explicit, not automatic** (fork a). `open` on an older
///   archive does not upgrade it; it throws `ArchiveError.needsUpgrade`, and
///   `Archive.upgrade(at:)` — `genea upgrade` — runs the pipeline when a person
///   asks, because upgrading locks out every machine still on the older build.
/// - **There is no forward compatibility.** An archive newer than this build is
///   refused at the door (`ArchiveError.archiveNewerThanBuild`), whether the
///   manifest says so or a single record does. Loading it with the unknown
///   fields dropped and writing the record back down is the silent downgrade
///   the slice exists to prevent.
///
/// **Mechanism:** an ordered chain of `Step`s, each upgrading the on-disk
/// archive in place from one version to the next. `Archive.upgrade` walks the
/// chain from the manifest's version to `SchemaVersion.current`; after each step
/// it stamps the manifest with the step's `toVersion` and drops the manifest
/// entries for the files the step rewrote, so the commit that follows re-mints
/// them from the bytes now on disk (the same mechanism `rebaseline()` uses, for
/// the same reason: the engine itself just wrote those files, so their old
/// entries are void). Version comparison is `SchemaVersion.isNewer` —
/// `major.minor` as integers, unparsable is newer.
///
/// **The chain is empty**: `"1.0"` is the only version that has ever existed.
/// What a real step will need, decided when 1.1 exists rather than guessed now:
/// the per-record shape that lets it absorb a *straggler* — a record still at
/// the older version in an archive already upgraded (the walk reports these as
/// `.olderFormat`), which an upgrade re-run over a mostly-current archive must
/// bring forward without re-migrating what is already there.
struct Migration: Sendable {
    /// One version-to-version upgrade step.
    struct Step: Sendable {
        /// The version this step upgrades *from* (e.g. `"1.0"`).
        let fromVersion: String
        /// The version this step produces (e.g. `"1.1"`).
        let toVersion: String
        /// Performs the on-disk rewrite. Receives the archive's root directory
        /// and returns the archive-relative paths of every file it rewrote, so
        /// their manifest entries can be re-minted. Implementations MUST use
        /// `AtomicIO` for any rewrite so a failure mid-migration never corrupts
        /// a sidecar, and must leave `manifest.json`'s `schemaVersion` alone —
        /// the pipeline stamps it.
        let apply: @Sendable (URL) throws -> [String]
    }

    /// The ordered chain of upgrade steps. Add steps here (in order) as the
    /// format evolves.
    let steps: [Step]

    /// The build's own chain. Tests inject a fake one through the initializer
    /// (fork f): a policy nobody can exercise is a claim, not a test, and with
    /// no second version the refusal and the upgrade are otherwise unreachable
    /// through the public API.
    static let shared = Migration(steps: [])

    init(steps: [Step]) {
        self.steps = steps
    }

    /// What `open` asks: may this build open the archive at `root`, whose
    /// manifest is `manifest`? Silent when it may; otherwise the refusal to
    /// throw.
    ///
    /// **A manifest behind the build is not, by itself, an archive behind the
    /// build** (`/code-review`, 64). Sync delivers files one at a time in both
    /// directions: a manifest written on a machine that had not yet upgraded
    /// can land on an archive that has, and taking its stamp at face value
    /// would demand an upgrade that already happened — exactly what fork (g)
    /// says must not occur. The evidence that settles it is fork (c)'s own: a
    /// record newer than the manifest means the archive is newer than the
    /// manifest says. So an older manifest costs one pass over the record
    /// stamps — never on the common path — and the archive's version is the
    /// newest stamp found: at the build's version, the manifest is a straggler
    /// and the next write puts it right; behind it, the archive needs an
    /// upgrade from *that* version; ahead of it, the door.
    ///
    /// **A current manifest reads the stamps of what moved, and only those**
    /// (slice 70, fork a). The other order of the same delivery — the record
    /// ahead of the manifest that records the upgrade — used to pass here
    /// untouched, and with the witness matching, `open` reused the index and
    /// nothing ever read the file. A record that arrived since the manifest was
    /// written has no entry in it, or (when it replaced one) almost always a
    /// different size, so those are the only files whose stamp is read: one
    /// directory listing per record directory and one `stat` per record, which
    /// neither reads nor materializes an unchanged file. **Measured** (warm
    /// cache): 53 ms at 30k records, about 1.4× the manifest decode every open
    /// already pays. A newer record exactly the size of its entry passes —
    /// the accepted limit; every path that would write over it, or judge it,
    /// reads its stamp first (`refuseIfAhead(recordAt:path:)`).
    static func check(manifest: Manifest, archiveAt root: URL) throws {
        let manifestVersion = manifest.schemaVersion
        if manifestVersion == SchemaVersion.current {
            return try refuseIfAnyMovedRecordIsAhead(of: manifest, in: root)
        }
        if SchemaVersion.isNewer(manifestVersion, than: SchemaVersion.current) {
            throw ArchiveError.archiveNewerThanBuild(
                path: ArchiveLayout.manifestFileName, found: manifestVersion,
                supported: SchemaVersion.current)
        }
        var archiveVersion = manifestVersion
        if let newest = newestRecordStamp(in: root, where: { _, _, _ in true }),
            SchemaVersion.isNewer(newest.version, than: manifestVersion)
        {
            if SchemaVersion.isNewer(newest.version, than: SchemaVersion.current) {
                throw ArchiveError.archiveNewerThanBuild(
                    path: newest.path, found: newest.version, supported: SchemaVersion.current)
            }
            archiveVersion = newest.version
        }
        if archiveVersion != SchemaVersion.current {
            throw ArchiveError.needsUpgrade(from: archiveVersion, to: SchemaVersion.current)
        }
    }

    /// Fork (a)'s scan — see `check(manifest:archiveAt:)`. Also run by
    /// `verifyIntegrity()`, whose hash pass sees only files the manifest names:
    /// a newer record that arrived under an open handle with no entry would
    /// otherwise come back from it as a clean archive.
    ///
    /// **Two kinds of record are not read** (`/code-review`, 70):
    ///
    /// - **One whose bytes are not on this machine.** Reading it would download it
    ///   — the transfer 57b took out of every ordinary call. A newer one is then
    ///   met by the walk, or by the drift guard, which hashes the file anyway.
    /// - **One with no entry, when the manifest records no record checksums at
    ///   all.** That is a manifest last written before slice 49, where *no entry*
    ///   is every record and says nothing about what moved; reading them all on
    ///   every open is the cost fork (a) rejected. The first commit mints the
    ///   entries, and after that a missing one means what it says.
    static func refuseIfAnyMovedRecordIsAhead(of manifest: Manifest, in root: URL) throws {
        let sizes = Dictionary(
            manifest.files.lazy.map { ($0.path, $0.byteLength) },
            uniquingKeysWith: { first, _ in first })
        let recordsChecksums = manifest.files.contains {
            ArchiveLayout.isEngineAuthored(relativePath: $0.path)
        }
        let moved = { (path: String, size: Int64, dataless: Bool) -> Bool in
            guard !dataless else { return false }
            guard let recorded = sizes[path] else { return recordsChecksums }
            return recorded != size
        }
        if let newest = newestRecordStamp(in: root, where: moved) {
            try refuseIfAhead(newest.version, path: newest.path)
        }
    }

    /// Throws `archiveNewerThanBuild` if the record file at `url` carries a
    /// format stamp ahead of this build (slice 70, fork b) — silent for a file
    /// that is absent or has no readable stamp, which is damage and not this
    /// check's to name.
    ///
    /// **Asked wherever the engine has already found a record that is not what
    /// it last wrote, before it calls that damage**: the drift guard, the hash
    /// pass and Repair. Fork (a)'s open-time scan misses a newer record exactly
    /// the size of its entry, and a handle that is already open never runs that
    /// scan; each of these is where such a record would otherwise be written
    /// over or reported as corruption. One small read, and only of a file that
    /// already disagrees with the manifest.
    static func refuseIfAhead(recordAt url: URL, path: String) throws {
        guard let version = stamp(ofRecordAt: url) else { return }
        try refuseIfAhead(version, path: path)
    }

    /// The refusal itself, for a stamp already in hand — the one copy of it,
    /// which `ArchiveIndex.rebuild`'s walk applies too (`/code-review`, 70), so
    /// the door and the walk cannot disagree about which records are ahead.
    /// Unparsable is newer (64, fork c).
    static func refuseIfAhead(_ version: String, path: String) throws {
        if SchemaVersion.isNewer(version, than: SchemaVersion.current) {
            throw ArchiveError.archiveNewerThanBuild(
                path: path, found: version, supported: SchemaVersion.current)
        }
    }

    /// The `schemaVersion` the file at `url` carries, read without decoding the
    /// rest — so a record this build cannot otherwise decode still counts, which
    /// is the point: that is the record most likely to be ahead.
    private static func stamp(ofRecordAt url: URL) -> String? {
        struct Stamp: Decodable {
            let schemaVersion: String
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? GeneaLogicJSONCoding.decoder.decode(Stamp.self, from: data))?.schemaVersion
    }

    /// The newest stamp among the record files `include` admits, with the file
    /// that carries it — or `nil` when none has a readable stamp. `include` is
    /// given each file's archive-relative path, `st_size`, and whether its bytes
    /// are off this machine, before anything is read, so a caller that wants
    /// only what moved pays for no other read.
    private static func newestRecordStamp(
        in root: URL, where include: (String, Int64, Bool) -> Bool
    ) -> (path: String, version: String)? {
        var newest: (path: String, version: String)?
        forEachRecordFile(in: root) { path, st in
            guard include(path, Int64(st.st_size), Archive.isDataless(st)),
                let version = stamp(ofRecordAt: root.appendingPathComponent(path))
            else { return }
            if newest == nil || SchemaVersion.isNewer(version, than: newest!.version) {
                newest = (path, version)
            }
        }
        return newest
    }

    /// Every record file — each artifact folder's `record.json` and every
    /// `.json` in a conclusion directory, whatever it is called (a conflicted
    /// copy from a newer build is the same evidence) — with its `stat`.
    ///
    /// **`readdir` and `fstatat`, not `FileManager`** (slice 70). This runs on
    /// every open, and `contentsOfDirectory(at:)` builds a URL per entry: 3× the
    /// cost at 30k records (177 ms against 53). Hidden entries are skipped, as
    /// `.skipsHiddenFiles` did.
    private static func forEachRecordFile(in root: URL, _ body: (String, stat) -> Void) {
        let artifacts = ArchiveLayout.artifactsDirectoryName
        forEachEntry(in: root.appendingPathComponent(artifacts, isDirectory: true)) { slug, at in
            let relative = "\(slug)/\(ArchiveLayout.recordFileName)"
            if let st = at(relative) { body("\(artifacts)/\(relative)", st) }
        }
        for directory in [
            ArchiveLayout.personsDirectoryRelativePath,
            ArchiveLayout.relationshipsDirectoryRelativePath,
            ArchiveLayout.linksDirectoryRelativePath,
            ArchiveLayout.dismissalsDirectoryRelativePath,
        ] {
            forEachEntry(in: root.appendingPathComponent(directory, isDirectory: true)) {
                name, at in
                guard name.lowercased().hasSuffix(".json"), let st = at(name) else { return }
                body("\(directory)/\(name)", st)
            }
        }
    }

    /// Lists `directory` (nothing, if it cannot be opened) and hands each
    /// non-hidden name to `body` with a lookup that `stat`s a path relative to
    /// the directory — a regular file's `stat`, else `nil`.
    private static func forEachEntry(
        in directory: URL, _ body: (String, (String) -> stat?) -> Void
    ) {
        let fd = directory.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_DIRECTORY) } ?? -1
        }
        guard fd >= 0 else { return }
        guard let dir = fdopendir(fd) else {
            close(fd)
            return
        }
        defer { closedir(dir) }  // closes `fd` too
        let lookup = { (relative: String) -> stat? in
            var st = stat()
            guard fstatat(fd, relative, &st, 0) == 0, st.st_mode & S_IFMT == S_IFREG else {
                return nil
            }
            return st
        }
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(cString: bytes.bindMemory(to: CChar.self).baseAddress!)
            }
            if name.hasPrefix(".") { continue }
            body(name, lookup)
        }
    }

    /// The steps that take `from` to `SchemaVersion.current`, in order — or the
    /// refusal, when there is no such chain.
    func path(from: String) throws -> [Step] {
        var chain: [Step] = []
        var current = from
        while current != SchemaVersion.current {
            guard let step = steps.first(where: { $0.fromVersion == current }) else {
                throw ArchiveError.noUpgradePath(from: from, to: SchemaVersion.current)
            }
            chain.append(step)
            current = step.toVersion
        }
        return chain
    }
}

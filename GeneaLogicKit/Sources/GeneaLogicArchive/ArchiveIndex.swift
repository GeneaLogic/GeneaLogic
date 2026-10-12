import Foundation
import GeneaLogicModel

/// **SQLite-backed persistent projection** of the archive's sidecars +
/// conclusions, living at `<root>/.index/index.sqlite` (ARCHITECTURE.md §5,
/// §5.1; §10 "Resolved" — SQLite driver).
///
/// **What's locked vs. internal:** the public query surface
/// (`Archive.artifact(withID:)`, `.artifacts(matching:)`, `.artifacts(mentioning:)`,
/// the `person(...)` parallels, `ArtifactSummary`/`PersonSummary`/`ArtifactQuery`/
/// `PersonQuery`, all in `Archive+Lookup.swift`) is final per CLAUDE.md and is
/// UNCHANGED by this type's replacement of the old in-memory `ArchiveIndex`. This
/// type — its storage, its schema, its rebuild walk — is `internal`, never exposed.
///
/// **Schema (one row per record, keyed by `uid`):** each table stores the
/// canonical `GeneaLogicJSONCoding`-encoded JSON blob for the record plus the
/// handful of columns needed for indexed point lookups (`slug`,
/// `artifact_uid`/`person_uid` on `link`, `sha256` on `file`). `file` and `place`
/// are denormalized projections *out* of those blobs rather than record tables of
/// their own. `meta` records the index-schema version (also mirrored into
/// `PRAGMA user_version` for a cheap pre-decode compatibility check on `open`).
///
/// **Why reuse Swift predicates instead of SQL `WHERE` (judgment call, flagged
/// for review):** `artifacts(matching:)`/`persons(matching:)` filter on
/// free-text substrings across several optional fields, tag sets, EDTF
/// date-range overlap of possibly-partial/approximate dates, etc. — exactly the
/// logic `Archive+Lookup.swift`'s private `matches`/`summarize`/`displayName`/
/// `earliestDate` (via `EDTFDate`) already implement and the tests already pin
/// down. Re-expressing that as SQL would risk subtle behavioral
/// drift (e.g. SQLite's `LIKE` case-folding rules differ from Swift's
/// `.lowercased()`) for the sake of "is it in SQL" with no test coverage to
/// catch the difference. So: indexed SQL `WHERE` is used only for genuine
/// point/equality lookups (`uid`, `sha256`, `externalIdentifier`'s linear scan
/// is unchanged, `atPath` slug matching); the fuzzy `matching:`/`mentioning:`
/// queries load the full candidate set via `allArtifacts()`/`allPersons()`,
/// decode JSON → model values, and hand them to the *same* Swift predicates as
/// before. FTS5 is compiled in (`SQLITE_ENABLE_FTS5`) for a future SQL-native
/// text index — adding it later is additive (a new table + an additional fast
/// path), not an API change, so it's left for later.
///
/// **Connection lifetime & locking:** one `SQLiteDatabase` (one `sqlite3*`) is
/// opened for the archive's lifetime and held here; it is only ever touched from
/// inside `Archive.withState`/`withIndex`, both of which hold `Archive`'s
/// `NSLock` for their entire body — so there is never concurrent access to the
/// connection from this process. Closed via `SQLiteDatabase.deinit` when this
/// `ArchiveIndex` is deallocated (i.e. when the owning `Archive` is).
///
/// **Consistency contract (unchanged from the in-memory version):** every
/// mutating `Archive` method calls one of this type's `upsert`/`removeArtifact`
/// methods as part of the same `withState` call that rewrites the sidecar — SQL
/// upsert/delete happens inline, there is no separate "commit" step. `rebuild()`
/// (driving `Archive.rebuildIndex()`) exists for the out-of-band-edit case (§5.1:
/// a hand-edited sidecar, files added on another machine).
final class ArchiveIndex {
    /// The index-schema version this build writes/expects. Bump when the table
    /// shapes below change in a way that isn't simply "re-derivable by
    /// `rebuild()`" — i.e. essentially never, since `rebuild()` always
    /// regenerates everything from scratch; this exists mainly so
    /// `Archive.open` can detect "a future version of GeneaLogic wrote this
    /// `.index/`, my schema doesn't match" and rebuild rather than mis-decode.
    ///
    /// **v2** added the `artifact.search_text` column (extracted `role: .transcript`
    /// file text — see `upsert`). The bump is what makes existing `.index/` caches
    /// regenerate: `Archive.openOrRebuildIndex` replaces a version-mismatched file
    /// and rebuilds from scratch, so no `ALTER TABLE` migration is needed.
    ///
    /// **v3** added the `place` table (slice 45o) — every place string any record
    /// writes, which is what lets the matcher tell a bare town from a bare country
    /// without a gazetteer. See `allPlaceStrings()`.
    ///
    /// **v4** added the `dismissal` table (slice 45m) — the suggestions a human
    /// declined, which every suggestion sweep must subtract before it offers a pair.
    ///
    /// **v5** widened `file` with `path` and `byte_length` (slice 49), so the
    /// manifest recompute — which since that slice runs on *every* mutation,
    /// conclusion writes included — can build the payload entries from one join
    /// rather than decoding every artifact's JSON. Measured over 500 artifacts:
    /// `allArtifacts()` 4.63 ms/call vs `allPayloadFiles()` 0.34 ms/call. End to
    /// end a conclusion write on that archive went 21.7 ms → 18.4 ms; the rest of
    /// what scales with artifact count is serializing and writing the bigger
    /// manifest, which is fork (c)'s knowingly-accepted cost.
    ///
    /// **v6** added the `unreadable_record` table (slice 55) — the records a
    /// rebuild had to skip because they could not be read or decoded. It is a
    /// finding, not content, and it lives here so it survives an `open()` that
    /// does no rebuild; every rebuild re-derives it, so the index stays a
    /// rebuildable cache. The bump costs nothing extra: an archive on v5 rebuilds
    /// once on next open, which is exactly when the table gets populated.
    ///
    /// **v7** added the `orphaned_record` table (slice 58) — the last index row of
    /// each record the walk had to skip. That row is a *byte-identical copy of the
    /// sidecar*, written by the same deterministic encoder, and once the file is
    /// corrupt it is the only surviving one; before this, a rebuild deleted it.
    ///
    /// **The bump was itself the sharp edge** — a version mismatch replaces the
    /// file, and replacing it unlinked every copy, so installing v7 destroyed the
    /// copy of a record damaged at upgrade time on its way in. **Since slice 69 a
    /// replaced file's copies are carried into the new one**, its live rows
    /// included (`carryPreservedCopies(from:)`), so a future bump keeps them as a
    /// same-schema rebuild does.
    static let schemaVersion: Int32 = 7

    private let db: SQLiteDatabase

    /// Opens (or creates) the index database at `url` with the current schema.
    /// Does NOT decide whether to rebuild — that's `Archive.open`'s job (it
    /// compares `userVersion()` against `schemaVersion` first).
    private init(db: SQLiteDatabase) {
        self.db = db
    }

    /// Opens the index database at `url`, creating the schema (idempotent —
    /// `CREATE TABLE IF NOT EXISTS`) if absent.
    static func open(at url: URL) throws -> ArchiveIndex {
        let db = try SQLiteDatabase(at: url)
        let index = ArchiveIndex(db: db)
        try index.createSchemaIfNeeded()
        return index
    }

    /// Opens the database already at `url` if it is **usable as-is** — the
    /// header opens, `user_version` is this build's, every page passes
    /// `quick_check`, and the schema can be brought current — and `nil` when the
    /// caller should replace it with a new file.
    ///
    /// **Evidence replaces it at once**: a stale or newer schema, a non-`ok`
    /// check, `SQLITE_CORRUPT` or `SQLITE_NOTADB`. **A probe that could not run is
    /// not evidence** (slice 69, fork b) — an unfinished `quick_check` replacing
    /// the file was how every preserved copy went — so:
    ///
    /// - `SQLITE_BUSY` / `SQLITE_LOCKED` **throw**: another connection holds the
    ///   file, so it is in use, not broken, and a new file would strand that
    ///   connection (47). The open fails having touched nothing.
    /// - **Anything else is retried once**, after a pause — a sync client
    ///   evicting the file mid-scan, an `IOERR` that clears. Failing twice, it
    ///   is replaced after all (revised on `/code-review`): throwing on a
    ///   *persistent* `IOERR`, `READONLY` or `CANTOPEN` made every open of the
    ///   archive fail with no way back, and since fork (a) replacing keeps the
    ///   copies — carried, or the file kept where they cannot be.
    ///
    /// **Nothing is written to a file this rejects:** the schema is created only
    /// once the version and the check have passed. `open(at:)` creates it first,
    /// which on another version's database can fail on a column it does not have.
    static func openExisting(at url: URL) throws -> ArchiveIndex? {
        do {
            return try probeExisting(at: url)
        } catch  where SQLiteDatabase.isInUse(error) {
            throw error
        } catch {
            Thread.sleep(forTimeInterval: probeRetryDelay)
        }
        do {
            return try probeExisting(at: url)
        } catch  where SQLiteDatabase.isInUse(error) {
            throw error
        } catch {
            return nil
        }
    }

    /// How long a probe that could not run waits before its one retry.
    static let probeRetryDelay: TimeInterval = 0.2

    /// One attempt of `openExisting`: `nil` on evidence, a throw when a probe
    /// could not run.
    private static func probeExisting(at url: URL) throws -> ArchiveIndex? {
        do {
            try IndexProbeFault.check(.open, at: url)
            let db = try SQLiteDatabase(at: url)
            try IndexProbeFault.check(.userVersion, at: url)
            guard try db.userVersion() == schemaVersion else { return nil }
            try IndexProbeFault.check(.quickCheck, at: url)
            guard try db.passesQuickCheck() else { return nil }
            try IndexProbeFault.check(.schema, at: url)
            let index = ArchiveIndex(db: db)
            try index.createSchemaIfNeeded()
            return index
        } catch  where SQLiteDatabase.isCorruption(error) {
            return nil
        }
    }

    /// `PRAGMA user_version` of the opened database — used by `Archive.open` to
    /// decide between "use as-is" and "rebuild" (see that doc comment).
    func userVersion() throws -> Int32 {
        try db.userVersion()
    }

    /// Whether the database's pages are usable, not just its header (slice 63,
    /// fork f) — see `SQLiteDatabase.passesQuickCheck`. `Archive.open` treats a
    /// `false` (or a throw) as *unopenable*: recreate and rebuild.
    func passesQuickCheck() throws -> Bool {
        try db.passesQuickCheck()
    }

    /// The connection's busy timeout (slice 47). Exposed so a test can assert it
    /// on the connection an `Archive` is actually using, not just on a
    /// hand-built one.
    func busyTimeout() throws -> Int32 {
        try db.busyTimeout()
    }

    /// `PRAGMA data_version` for this connection — see `SQLiteDatabase.dataVersion`.
    func dataVersion() throws -> Int32 {
        try db.dataVersion()
    }

    private func createSchemaIfNeeded() throws {
        try db.exec(
            """
            CREATE TABLE IF NOT EXISTS artifact (
                uid         TEXT PRIMARY KEY,
                slug        TEXT NOT NULL,
                json        BLOB NOT NULL,
                search_text TEXT
            );
            CREATE TABLE IF NOT EXISTS person (
                uid  TEXT PRIMARY KEY,
                json BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS relationship (
                uid  TEXT PRIMARY KEY,
                json BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS link (
                uid          TEXT PRIMARY KEY,
                artifact_uid TEXT NOT NULL,
                person_uid   TEXT NOT NULL,
                json         BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS link_person_uid ON link(person_uid);
            CREATE TABLE IF NOT EXISTS file (
                sha256       TEXT NOT NULL,
                artifact_uid TEXT NOT NULL,
                path         TEXT NOT NULL DEFAULT '',
                byte_length  INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS file_sha256 ON file(sha256);
            CREATE INDEX IF NOT EXISTS file_artifact_uid ON file(artifact_uid);
            CREATE TABLE IF NOT EXISTS place (
                value      TEXT NOT NULL,
                record_uid TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS place_record_uid ON place(record_uid);
            CREATE TABLE IF NOT EXISTS dismissal (
                uid          TEXT PRIMARY KEY,
                person1_uid  TEXT NOT NULL,
                person2_uid  TEXT NOT NULL,
                json         BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS dismissal_person1_uid ON dismissal(person1_uid);
            CREATE INDEX IF NOT EXISTS dismissal_person2_uid ON dismissal(person2_uid);
            CREATE TABLE IF NOT EXISTS unreadable_record (
                path   TEXT PRIMARY KEY,
                reason TEXT NOT NULL DEFAULT 'undecodable'
            );
            CREATE TABLE IF NOT EXISTS orphaned_record (
                path TEXT PRIMARY KEY,
                uid  TEXT NOT NULL,
                json BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settled_file (
                path        TEXT PRIMARY KEY,
                sha256      TEXT NOT NULL,
                byte_length INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS superseded_file (
                path        TEXT NOT NULL,
                sha256      TEXT NOT NULL,
                byte_length INTEGER NOT NULL,
                PRIMARY KEY (path, sha256)
            );
            CREATE TABLE IF NOT EXISTS deleted_path (
                path TEXT PRIMARY KEY
            );
            CREATE TABLE IF NOT EXISTS abandoned_path (
                path   TEXT PRIMARY KEY,
                sha256 TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS contested_file (
                path               TEXT PRIMARY KEY,
                theirs_sha256      TEXT NOT NULL,
                theirs_byte_length INTEGER NOT NULL,
                ours_sha256        TEXT NOT NULL,
                ours_byte_length   INTEGER NOT NULL
            );
            """)
        try addUnreadableRecordReasonIfMissing()
        // If this is a brand-new file, userVersion() reads 0 — set it once so a
        // freshly-created empty index is immediately recognized as current
        // (Archive.create's "the empty index is consistent with the empty
        // archive" requirement).
        if try db.userVersion() == 0 {
            try db.setUserVersion(Self.schemaVersion)
        }
    }

    /// `unreadable_record.reason` (slice 64, fork e), added to an index written
    /// before it by `ALTER TABLE` rather than by a `schemaVersion` bump.
    ///
    /// The fork's text said bump — "free-by-construction, as 55's was" — and it
    /// is not free: a version mismatch takes `Archive.openOrRebuildIndex`'s
    /// *new-file* path, which then unlinked the database and with it every
    /// preserved copy of an unreadable record (58's note on v7; carried across
    /// since slice 69, but a bump still costs a full walk). This column is additive in
    /// both directions — the rows an older rebuild wrote could only ever have
    /// meant `undecodable`, which is the default, and an older build's
    /// `INSERT (path)` still works — so it takes the `meta` table's route and
    /// costs an archive nothing on the way in.
    private func addUnreadableRecordReasonIfMissing() throws {
        var hasReason = false
        let info = try db.prepare("PRAGMA table_info(unreadable_record);")
        try db.query(info) { row in
            if db.columnText(row, 1) == "reason" { hasReason = true }
        }
        guard !hasReason else { return }
        try db.exec(
            "ALTER TABLE unreadable_record ADD COLUMN reason TEXT NOT NULL DEFAULT 'undecodable';"
        )
    }

    // MARK: - Mutation (keeps the index in lockstep with the sidecars)

    /// Upserts an artifact row, including the `search_text` projection of its
    /// `role: .transcript` files' text. `artifactDirectory` is the artifact's
    /// on-disk folder (`artifacts/<slug>/`); the transcript files are read from
    /// there at index time so `matches` can search their content without I/O per
    /// query. Reading is best-effort — an unreadable or non-UTF-8 transcript file
    /// simply contributes nothing (see `transcriptFileText`).
    func upsert(_ artifact: Artifact, slug: String, artifactDirectory: URL) throws {
        let json = try GeneaLogicJSONCoding.encoder.encode(artifact)
        let searchText = Self.transcriptFileText(for: artifact, in: artifactDirectory)
        let stmt = try db.prepare(
            "INSERT INTO artifact (uid, slug, json, search_text) VALUES (?, ?, ?, ?) "
                + "ON CONFLICT(uid) DO UPDATE SET slug = excluded.slug, json = excluded.json, "
                + "search_text = excluded.search_text;")
        try db.bind(artifact.uid.raw, at: 1, on: stmt)
        try db.bind(slug, at: 2, on: stmt)
        try db.bind(json, at: 3, on: stmt)
        if let searchText {
            try db.bind(searchText, at: 4, on: stmt)
        } else {
            try db.bindNull(at: 4, on: stmt)
        }
        try db.run(stmt)

        // `file` is a denormalized projection of `artifact.files[]`, rebuilt
        // wholesale on every upsert — simplest way to keep it in lockstep without
        // diffing old vs. new file lists. It carries `path`/`byte_length`
        // alongside the checksum (v5) so the manifest recompute can build every
        // payload entry from one join instead of decoding every artifact's JSON
        // on every mutation (review finding, 49).
        let delete = try db.prepare("DELETE FROM file WHERE artifact_uid = ?;")
        try db.bind(artifact.uid.raw, at: 1, on: delete)
        try db.run(delete)

        for file in artifact.files {
            let insert = try db.prepare(
                "INSERT INTO file (sha256, artifact_uid, path, byte_length) VALUES (?, ?, ?, ?);")
            try db.bind(file.sha256, at: 1, on: insert)
            try db.bind(artifact.uid.raw, at: 2, on: insert)
            try db.bind(file.path, at: 3, on: insert)
            try db.bind(file.byteLength, at: 4, on: insert)
            try db.run(insert)
        }

        try replacePlaces(of: artifact.uid.raw, with: Self.places(in: artifact))
    }

    func removeArtifact(_ id: ArtifactID) throws {
        let deleteArtifact = try db.prepare("DELETE FROM artifact WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: deleteArtifact)
        try db.run(deleteArtifact)

        let deleteFiles = try db.prepare("DELETE FROM file WHERE artifact_uid = ?;")
        try db.bind(id.raw, at: 1, on: deleteFiles)
        try db.run(deleteFiles)

        try replacePlaces(of: id.raw, with: [])
    }

    func removePerson(_ id: PersonID) throws {
        let stmt = try db.prepare("DELETE FROM person WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        try db.run(stmt)

        try replacePlaces(of: id.raw, with: [])
    }

    func removeRelationship(_ id: RelationshipID) throws {
        let stmt = try db.prepare("DELETE FROM relationship WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        try db.run(stmt)

        try replacePlaces(of: id.raw, with: [])
    }

    func removeLink(_ id: EvidenceLinkID) throws {
        let stmt = try db.prepare("DELETE FROM link WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        try db.run(stmt)
    }

    func removeDismissal(_ id: DismissalID) throws {
        let stmt = try db.prepare("DELETE FROM dismissal WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        try db.run(stmt)
    }

    func upsert(_ person: Person) throws {
        let json = try GeneaLogicJSONCoding.encoder.encode(person)
        let stmt = try db.prepare(
            "INSERT INTO person (uid, json) VALUES (?, ?) "
                + "ON CONFLICT(uid) DO UPDATE SET json = excluded.json;")
        try db.bind(person.uid.raw, at: 1, on: stmt)
        try db.bind(json, at: 2, on: stmt)
        try db.run(stmt)

        try replacePlaces(of: person.uid.raw, with: Self.places(in: person))
    }

    func upsert(_ relationship: Relationship) throws {
        let json = try GeneaLogicJSONCoding.encoder.encode(relationship)
        let stmt = try db.prepare(
            "INSERT INTO relationship (uid, json) VALUES (?, ?) "
                + "ON CONFLICT(uid) DO UPDATE SET json = excluded.json;")
        try db.bind(relationship.uid.raw, at: 1, on: stmt)
        try db.bind(json, at: 2, on: stmt)
        try db.run(stmt)

        try replacePlaces(of: relationship.uid.raw, with: Self.places(in: relationship))
    }

    func upsert(_ link: EvidenceLink) throws {
        let json = try GeneaLogicJSONCoding.encoder.encode(link)
        let stmt = try db.prepare(
            "INSERT INTO link (uid, artifact_uid, person_uid, json) VALUES (?, ?, ?, ?) "
                + "ON CONFLICT(uid) DO UPDATE SET artifact_uid = excluded.artifact_uid, "
                + "person_uid = excluded.person_uid, json = excluded.json;")
        try db.bind(link.uid.raw, at: 1, on: stmt)
        try db.bind(link.artifactUid.raw, at: 2, on: stmt)
        try db.bind(link.personUid.raw, at: 3, on: stmt)
        try db.bind(json, at: 4, on: stmt)
        try db.run(stmt)
    }

    /// A dismissal carries no place, so — unlike the other conclusion records — it
    /// owns no `place` rows to replace.
    func upsert(_ dismissal: Dismissal) throws {
        let json = try GeneaLogicJSONCoding.encoder.encode(dismissal)
        let stmt = try db.prepare(
            "INSERT INTO dismissal (uid, person1_uid, person2_uid, json) VALUES (?, ?, ?, ?) "
                + "ON CONFLICT(uid) DO UPDATE SET person1_uid = excluded.person1_uid, "
                + "person2_uid = excluded.person2_uid, json = excluded.json;")
        try db.bind(dismissal.uid.raw, at: 1, on: stmt)
        try db.bind(dismissal.person1Uid.raw, at: 2, on: stmt)
        try db.bind(dismissal.person2Uid.raw, at: 3, on: stmt)
        try db.bind(json, at: 4, on: stmt)
        try db.run(stmt)
    }

    // MARK: - Places (slice 45o)

    /// Replaces every `place` row owned by one record.
    ///
    /// Wholesale, like `file`'s projection above and for the same reason: diffing an
    /// old place list against a new one buys nothing and is one more thing to get
    /// wrong. A record with no places writes no rows, which is also how a removal is
    /// expressed — `removePerson` and friends call this with an empty list.
    ///
    /// `record_uid` needs no companion "which table" column because a `uid` is a
    /// type-prefixed UUIDv7 (`ART-…`, `PER-…`, `REL-…`): the prefix already says which
    /// record owns the row, so artifacts, persons and relationships can share one table
    /// without ambiguity.
    private func replacePlaces(of recordUID: String, with values: [String]) throws {
        let delete = try db.prepare("DELETE FROM place WHERE record_uid = ?;")
        try db.bind(recordUID, at: 1, on: delete)
        try db.run(delete)

        for value in values {
            let insert = try db.prepare("INSERT INTO place (value, record_uid) VALUES (?, ?);")
            try db.bind(value, at: 1, on: insert)
            try db.bind(recordUID, at: 2, on: insert)
            try db.run(insert)
        }
    }

    /// Every place string an artifact writes: its own `locations`, the places its
    /// `events` name, and the places recorded against each person it mentions.
    static func places(in artifact: Artifact) -> [String] {
        var values = artifact.locations.map(\.asRecorded)
        values.append(contentsOf: artifact.events.compactMap(\.location))
        for mention in artifact.personsMentioned {
            values.append(contentsOf: mention.facts.compactMap(\.place))
        }
        return values.filter { !$0.isEmpty }
    }

    /// Every place string a concluded person writes.
    static func places(in person: Person) -> [String] {
        person.facts.compactMap(\.place).filter { !$0.isEmpty }
    }

    /// Every place string a relationship writes — a marriage place is as good a
    /// statement about how this archive names places as a birth place is.
    static func places(in relationship: Relationship) -> [String] {
        relationship.facts.compactMap(\.place).filter { !$0.isEmpty }
    }

    /// Every distinct place string in the archive, in no particular order.
    ///
    /// **Raw strings, not a derived judgment about them.** What the matcher does with
    /// these — deciding that a value the archive writes as `Rypin, Poland` proves a
    /// bare `Rypin` is a town — is `PlaceVocabulary`'s rule, and it lives in
    /// `GeneaLogicMatch` where a change to it is a code change plus a
    /// `Matcher.toolIdentifier` bump. Storing the conclusion here instead would put a
    /// scoring rule inside a rebuildable cache, where changing it would silently need
    /// an index rebuild to take effect.
    ///
    /// This table is the reason the vocabulary can be identical on every matching entry
    /// point: the alternative was decoding every artifact in the archive to explain the
    /// score of a single pair.
    func allPlaceStrings() throws -> [String] {
        let stmt = try db.prepare("SELECT DISTINCT value FROM place;")
        var values: [String] = []
        try db.query(stmt) { row in
            values.append(db.columnText(row, 0))
        }
        return values
    }

    // MARK: - Point lookups

    func artifact(_ id: ArtifactID) throws -> Artifact? {
        let stmt = try db.prepare("SELECT json FROM artifact WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: Artifact?
        try db.query(stmt) { row in
            result = try GeneaLogicJSONCoding.decoder.decode(
                Artifact.self, from: db.columnData(row, 0))
        }
        return result
    }

    func slug(for id: ArtifactID) throws -> String? {
        let stmt = try db.prepare("SELECT slug FROM artifact WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: String?
        try db.query(stmt) { row in result = db.columnText(row, 0) }
        return result
    }

    func person(_ id: PersonID) throws -> Person? {
        let stmt = try db.prepare("SELECT json FROM person WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: Person?
        try db.query(stmt) { row in
            result = try GeneaLogicJSONCoding.decoder.decode(
                Person.self, from: db.columnData(row, 0))
        }
        return result
    }

    func relationship(_ id: RelationshipID) throws -> Relationship? {
        let stmt = try db.prepare("SELECT json FROM relationship WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: Relationship?
        try db.query(stmt) { row in
            result = try GeneaLogicJSONCoding.decoder.decode(
                Relationship.self, from: db.columnData(row, 0))
        }
        return result
    }

    func evidenceLink(_ id: EvidenceLinkID) throws -> EvidenceLink? {
        let stmt = try db.prepare("SELECT json FROM link WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: EvidenceLink?
        try db.query(stmt) { row in
            result = try GeneaLogicJSONCoding.decoder.decode(
                EvidenceLink.self, from: db.columnData(row, 0))
        }
        return result
    }

    func dismissal(_ id: DismissalID) throws -> Dismissal? {
        let stmt = try db.prepare("SELECT json FROM dismissal WHERE uid = ?;")
        try db.bind(id.raw, at: 1, on: stmt)
        var result: Dismissal?
        try db.query(stmt) { row in
            result = try GeneaLogicJSONCoding.decoder.decode(
                Dismissal.self, from: db.columnData(row, 0))
        }
        return result
    }

    /// Artifact ids owning at least one `FileEntry` with this `sha256`
    /// (`artifacts(containingFileWithSHA256:)`) — an indexed `WHERE`, since this
    /// is a genuine equality lookup, not a fuzzy predicate.
    func artifactIDs(withFileSHA256 sha256: String) throws -> Set<ArtifactID> {
        let stmt = try db.prepare("SELECT DISTINCT artifact_uid FROM file WHERE sha256 = ?;")
        try db.bind(sha256, at: 1, on: stmt)
        var result: Set<ArtifactID> = []
        try db.query(stmt) { row in result.insert(ArtifactID(db.columnText(row, 0))) }
        return result
    }

    // MARK: - Bulk reads (candidate sets for the Swift predicates in Archive+Lookup)

    /// Every artifact, decoded. Used by `artifacts()`, `artifacts(matching:)`,
    /// `artifacts(containingFileWithSHA256:)`'s summarize step, and `rebuild()`'s
    /// "did the edit take" comparisons in tests — see the type doc comment for
    /// why this loads everything rather than pushing the predicate into SQL.
    func allArtifacts() throws -> [Artifact] {
        let stmt = try db.prepare("SELECT json FROM artifact;")
        var result: [Artifact] = []
        try db.query(stmt) { row in
            result.append(
                try GeneaLogicJSONCoding.decoder.decode(Artifact.self, from: db.columnData(row, 0)))
        }
        return result
    }

    /// Every artifact, decoded, paired with its `search_text` projection (the
    /// indexed `role: .transcript` file text, or `nil`). Backs
    /// `artifacts(matching:)`'s free-text predicate so it can search transcript
    /// *file* content — which lives outside `record.json` — without re-reading
    /// files at query time.
    func allArtifactsWithSearchText() throws -> [(artifact: Artifact, searchText: String?)] {
        let stmt = try db.prepare("SELECT json, search_text FROM artifact;")
        var result: [(Artifact, String?)] = []
        try db.query(stmt) { row in
            let artifact = try GeneaLogicJSONCoding.decoder.decode(
                Artifact.self, from: db.columnData(row, 0))
            let text = db.columnText(row, 1)
            result.append((artifact, text.isEmpty ? nil : text))
        }
        return result
    }

    /// Concatenated UTF-8 text of an artifact's `role: .transcript` files, read
    /// from `artifactDirectory`, or `nil` if there are none / none are readable
    /// as text. **Best-effort by design:** a transcript stored as a binary or
    /// non-UTF-8 file contributes nothing rather than failing the upsert — the
    /// search index is a convenience cache, not authoritative (§5.1), so a file
    /// it can't read is simply not searchable, not an error.
    static func transcriptFileText(for artifact: Artifact, in artifactDirectory: URL) -> String? {
        let texts = artifact.files
            .filter { $0.role == .transcript }
            .compactMap { file -> String? in
                let url = artifactDirectory.appendingPathComponent(file.path)
                guard let data = try? Data(contentsOf: url) else { return nil }
                return String(data: data, encoding: .utf8)
            }
            .filter { !$0.isEmpty }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// `uid -> slug` for every artifact (the old `ArchiveIndex.artifactSlugs`).
    func allSlugs() throws -> [ArtifactID: String] {
        let stmt = try db.prepare("SELECT uid, slug FROM artifact;")
        var result: [ArtifactID: String] = [:]
        try db.query(stmt) { row in
            result[ArtifactID(db.columnText(row, 0))] = db.columnText(row, 1)
        }
        return result
    }

    func allPersons() throws -> [Person] {
        let stmt = try db.prepare("SELECT json FROM person;")
        var result: [Person] = []
        try db.query(stmt) { row in
            result.append(
                try GeneaLogicJSONCoding.decoder.decode(Person.self, from: db.columnData(row, 0)))
        }
        return result
    }

    func allRelationships() throws -> [Relationship] {
        let stmt = try db.prepare("SELECT json FROM relationship;")
        var result: [Relationship] = []
        try db.query(stmt) { row in
            result.append(
                try GeneaLogicJSONCoding.decoder.decode(
                    Relationship.self, from: db.columnData(row, 0)))
        }
        return result
    }

    func allLinks() throws -> [EvidenceLink] {
        let stmt = try db.prepare("SELECT json FROM link;")
        var result: [EvidenceLink] = []
        try db.query(stmt) { row in
            result.append(
                try GeneaLogicJSONCoding.decoder.decode(
                    EvidenceLink.self, from: db.columnData(row, 0)))
        }
        return result
    }

    func allDismissals() throws -> [Dismissal] {
        let stmt = try db.prepare("SELECT json FROM dismissal;")
        var result: [Dismissal] = []
        try db.query(stmt) { row in
            result.append(
                try GeneaLogicJSONCoding.decoder.decode(
                    Dismissal.self, from: db.columnData(row, 0)))
        }
        return result
    }

    /// One row per attached file, with the owning artifact's slug — everything
    /// the manifest's payload entries need (`artifacts/<slug>/<path>`, the
    /// checksum `record.json` authored, and the size), and nothing else.
    ///
    /// The point is what it *doesn't* do: `allArtifacts()` decodes every
    /// artifact's JSON, which the recompute paid on every mutation for the sake
    /// of three fields per file. See `schemaVersion` v5.
    func allPayloadFiles() throws -> [(
        slug: String, path: String, sha256: String, byteLength: Int64
    )] {
        let stmt = try db.prepare(
            "SELECT a.slug, f.path, f.sha256, f.byte_length FROM file f "
                + "JOIN artifact a ON a.uid = f.artifact_uid;")
        var result: [(slug: String, path: String, sha256: String, byteLength: Int64)] = []
        try db.query(stmt) { row in
            result.append(
                (
                    slug: db.columnText(row, 0), path: db.columnText(row, 1),
                    sha256: db.columnText(row, 2), byteLength: db.columnInt64(row, 3)
                ))
        }
        return result
    }

    /// The uids of every conclusion record, grouped by the directory each kind
    /// is filed under.
    struct ConclusionUIDs {
        var persons: [String]
        var relationships: [String]
        var links: [String]
        var dismissals: [String]
    }

    /// Every conclusion record's uid, by kind — `SELECT uid` only, decoding
    /// nothing.
    ///
    /// Exists for the manifest recompute (slice 49), which needs the *names* of
    /// every `conclusions/**` file on every mutation and none of their contents.
    /// `allPersons()` and friends would decode the whole conclusion layer to
    /// throw all of it away.
    func allConclusionUIDs() throws -> ConclusionUIDs {
        ConclusionUIDs(
            persons: try uids(inTable: "person"),
            relationships: try uids(inTable: "relationship"),
            links: try uids(inTable: "link"),
            dismissals: try uids(inTable: "dismissal")
        )
    }

    /// `table` is a compile-time literal from `allConclusionUIDs` only — never
    /// caller-supplied — so interpolating it is not an injection surface (SQLite
    /// cannot bind an identifier).
    private func uids(inTable table: String) throws -> [String] {
        let stmt = try db.prepare("SELECT uid FROM \(table);")
        var result: [String] = []
        try db.query(stmt) { row in result.append(db.columnText(row, 0)) }
        return result
    }

    // MARK: - Rebuild (full walk of sidecars + conclusions)

    /// Rebuilds the index from scratch by walking the on-disk archive at `root`,
    /// replacing every row. This is the single source of truth for "what does
    /// the index contain" — `Archive.open` (on a missing/stale `.index/`) and
    /// `Archive.rebuildIndex()` both call this, so they can never silently
    /// diverge. Runs inside a transaction so a crash mid-rebuild leaves the
    /// previous (still-valid, if stale) index intact rather than half-truncated.
    ///
    /// **A record it cannot read is skipped, not fatal (slice 55).** Until then a
    /// single undecodable `record.json` threw out of here, and since `open()`
    /// rebuilds whenever `.index/` is missing, stale or dirty, one corrupt byte
    /// in one sidecar made the *whole archive* fail to open. The boundary is
    /// per-record: anything that goes wrong reading or decoding one file — a
    /// truncated write, a hand-edit that broke the JSON, a permissions problem,
    /// a record from a newer GeneaLogic — skips that file and is reported. What
    /// still throws is the index failing to store what it did read (SQLite
    /// errors, the transaction, the schema write): a rebuild that cannot record
    /// its results is not a degraded result but no result.
    ///
    /// The skipped paths replace `unreadable_record` inside the same transaction,
    /// so the finding commits with the rows it explains and a rollback discards
    /// both. They also come back to the caller, so a rebuild that was *asked* for
    /// can report without a second query.
    ///
    /// **A skipped record keeps its row, in `orphaned_record` (slice 58).** The
    /// `json` column is not a derived summary — it is the sidecar's own bytes,
    /// from the same deterministic encoder (`GeneaLogicJSONCoding.encoder`,
    /// `.sortedKeys`) that `AtomicIO.writeJSON` used to write the file — so once
    /// the file is corrupt this is the only surviving copy of it, and clearing the
    /// tables destroyed it. Two paths led there and the second is worse: **Rebuild
    /// Index**, offered as the primary action beside the damage that motivates it,
    /// and `Archive.open`, which rebuilds on a missing/stale/dirty index *before
    /// the user is told anything is wrong*. See `preservedRecord(atPath:)` for why
    /// the copy lives in a table of its own rather than behind a flag.
    ///
    /// **A second copy of a record is not loaded at all (slice 50c).** A sync
    /// provider that cannot merge one file leaves one beside it, and this walk
    /// used to be name-blind in both directions: every `*.json` under
    /// `conclusions/<kind>/` was decoded and upserted, and every subdirectory of
    /// `artifacts/` had its `record.json` read, so two files could claim one uid
    /// and `contentsOfDirectory` order decided which one a query returned — after
    /// which the next ordinary mutation wrote that winner back into the canonical
    /// sidecar. `RecordDiscovery` holds the rules; `manifestRecordPaths` is what
    /// fork (e) resolves an artifact-folder contest with (and what 58c's prune
    /// tells a deleted record by), and callers get it from
    /// `RecordDiscovery.recordPaths(in:)`. The copies are not recorded
    /// here — `verifyIntegrity()` finds them by walking the same directories, so
    /// a copy that appears between rebuilds is still reported.
    ///
    /// **A record's format stamp is checked against the archive's version (slice
    /// 64, fork c), and the two directions are not symmetric.** A record *newer*
    /// than it is evidence the archive is newer than this build knows — the
    /// manifest recording the upgrade has simply not arrived yet — and it
    /// **throws** `ArchiveError.archiveNewerThanBuild`, closing the archive over a
    /// file it read perfectly. That is the one deliberate exception to 55's rule
    /// above, made in as many words in the spec (§8): a build does not edit what
    /// it cannot fully understand, and decoding the record here is the first step
    /// of editing it. A record *older* is a straggler migration can absorb; it is
    /// skipped like an undecodable one and reported with `.olderFormat`, so
    /// nothing offers to repair it.
    ///
    /// **The reference is the build's version, not `manifestVersion`**
    /// (`/code-review`, 64). `Archive.open` and `withState` admit a manifest only
    /// at or behind the build's version, and one *behind* it is a straggler
    /// manifest on an archive already upgraded (fork g) — every record this
    /// build wrote is rightly ahead of it, and comparing against it refused the
    /// archive's own records. The parameter stays for the guard: a manifest ahead
    /// of the build cannot reach here, and is refused again anyway, because
    /// loading records at a version this build does not write is the one thing
    /// the walk must never do.
    ///
    /// - Returns: Every record skipped, with why, sorted by path.
    ///
    /// **`unlinkedByDiedWrite` is what a crash recovery passes** — the paths the
    /// dirty marker's journal says a mutation that died had unlinked
    /// (`IndexDirtyMarker.journaledRemovals`). A removal cut between its unlink
    /// and its commit leaves the index still holding the record, so this rebuild
    /// stages a copy of it; a path in this set that is gone has that copy
    /// discarded, so the removal ends in the deletion (`Archive.removeAuthoredFile`)
    /// instead of being carried as a loss (58c, second `/code-review`).
    ///
    /// **Only those paths** (slice 69, fork c). 58c discarded the copy of every
    /// record that went missing since the last rebuild, so a file lost out of band
    /// in the same window lost its copy, its manifest entry and its `missingFile`
    /// finding together, with no trace. The journal is the narrower source: a
    /// sentinel with none (written before slice 68, or an append that failed)
    /// discards nothing, and the cut removal reads as a loss with a copy — the
    /// direction a human can still discard.
    @discardableResult
    func rebuild(
        walking root: URL, manifestRecordPaths: Set<String>, manifestVersion: String,
        unlinkedByDiedWrite: Set<String> = []
    ) throws -> [(path: String, reason: UnreadableRecordReason)] {
        if SchemaVersion.isNewer(manifestVersion, than: SchemaVersion.current) {
            throw ArchiveError.archiveNewerThanBuild(
                path: ArchiveLayout.manifestFileName, found: manifestVersion,
                supported: SchemaVersion.current)
        }
        let archiveVersion = SchemaVersion.current
        var skipped: [(path: String, reason: UnreadableRecordReason)] = []
        try db.exec("BEGIN IMMEDIATE;")
        do {
            // Before the tables are cleared, because afterwards there is nothing
            // left to preserve. Which of these rows to *keep* isn't known until
            // the walk has finished, so everything is staged and the rest pruned
            // below — in SQLite rather than in memory, so a rebuild never holds
            // the whole index at once.
            try stagePreservationCandidates()

            // **Every table is one of two kinds** (slice 66, fork a), and
            // `RebuildAgreementTests` fails on a table that is neither:
            //
            // - *Derived* — cleared here and re-derived by the walk, which must
            //   reproduce byte-for-byte what the incremental `upsert`/`remove…`
            //   path left: `artifact`, `person`, `relationship`, `link`, `file`,
            //   `place`, `dismissal`, `unreadable_record`.
            // - *Memory* — never cleared here: `orphaned_record`, `meta`,
            //   `settled_file`, `superseded_file`, `deleted_path`,
            //   `abandoned_path`, `contested_file`.
            //
            // `orphaned_record` is this rebuild's only memory of the previous one,
            // and a record that is *still* unreadable must keep the copy staged by
            // an earlier rebuild (the live tables have nothing to re-stage for
            // it); staging replaces a row by path, and the rows whose uid the walk
            // finds live again are pruned below — so a *different* record now
            // reading at an orphan's path displaces it. The engine no longer
            // arranges that (58b: a new folder never takes an orphan's slug), so
            // only a folder placed there by hand can, and choosing which of two
            // copies to keep under one path is not this rebuild's to decide. The
            // rest are not derived from the walk at all but say what this index
            // was last *settled against*, what this machine's own writes replaced
            // or removed, what a human here stopped waiting for, and which
            // delivered entries a merge overruled — and clearing them would make
            // every rebuild forget all of it. `deleted_path` especially: a rebuild
            // after a deletion walks an archive where the record is simply *not
            // there*, which is the one state the walk cannot tell from a delivery
            // that has not landed.
            try db.exec(
                "DELETE FROM artifact; DELETE FROM person; DELETE FROM relationship; "
                    + "DELETE FROM link; DELETE FROM file; DELETE FROM place; "
                    + "DELETE FROM dismissal; DELETE FROM unreadable_record;")

            let artifactsRoot = root.appendingPathComponent(
                ArchiveLayout.artifactsDirectoryName, isDirectory: true)
            if let artifactDirs = try? FileManager.default.contentsOfDirectory(
                at: artifactsRoot, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
            {
                // The path this walk has settled on for each uid so far. Two
                // folders claiming one `ART-…` is a conflicted copy of the folder
                // (slice 50c), and `RecordDiscovery` decides it pairwise as the
                // walk goes, so a duplicate costs one extra upsert and never a
                // second pass over every artifact.
                var chosen: [ArtifactID: String] = [:]

                for dir in artifactDirs {
                    let isDirectory =
                        (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                    guard isDirectory else { continue }
                    let recordURL = dir.appendingPathComponent(ArchiveLayout.recordFileName)
                    guard FileManager.default.fileExists(atPath: recordURL.path) else { continue }

                    let recordPath = ArchiveLayout.relativePath(of: recordURL, in: root)
                    let artifact: Artifact
                    do {
                        let data = try Data(contentsOf: recordURL)
                        artifact = try GeneaLogicJSONCoding.decoder.decode(
                            Artifact.self, from: data)
                    } catch {
                        skipped.append((recordPath, .undecodable))
                        continue
                    }
                    try Migration.refuseIfAhead(artifact.schemaVersion, path: recordPath)
                    if SchemaVersion.isNewer(archiveVersion, than: artifact.schemaVersion) {
                        skipped.append((recordPath, .olderFormat))
                        continue
                    }

                    if let incumbent = chosen[artifact.uid],
                        RecordDiscovery.chooseArtifactRecord(
                            from: [incumbent, recordPath], incumbents: manifestRecordPaths)
                            != recordPath
                    {
                        continue
                    }

                    chosen[artifact.uid] = recordPath
                    try upsert(artifact, slug: dir.lastPathComponent, artifactDirectory: dir)
                }
            }

            try loadConclusions(
                from: root.appendingPathComponent(
                    ArchiveLayout.personsDirectoryRelativePath, isDirectory: true),
                in: root, skipped: &skipped,
                archiveVersion: archiveVersion,
                decode: { try GeneaLogicJSONCoding.decoder.decode(Person.self, from: $0) },
                uid: { $0.uid.raw },
                version: { $0.schemaVersion },
                store: { try self.upsert($0) })

            try loadConclusions(
                from: root.appendingPathComponent(
                    ArchiveLayout.relationshipsDirectoryRelativePath, isDirectory: true),
                in: root, skipped: &skipped,
                archiveVersion: archiveVersion,
                decode: { try GeneaLogicJSONCoding.decoder.decode(Relationship.self, from: $0) },
                uid: { $0.uid.raw },
                version: { $0.schemaVersion },
                store: { try self.upsert($0) })

            try loadConclusions(
                from: root.appendingPathComponent(
                    ArchiveLayout.linksDirectoryRelativePath, isDirectory: true),
                in: root, skipped: &skipped,
                archiveVersion: archiveVersion,
                decode: { try GeneaLogicJSONCoding.decoder.decode(EvidenceLink.self, from: $0) },
                uid: { $0.uid.raw },
                version: { $0.schemaVersion },
                store: { try self.upsert($0) })

            try loadConclusions(
                from: root.appendingPathComponent(
                    ArchiveLayout.dismissalsDirectoryRelativePath, isDirectory: true),
                in: root, skipped: &skipped,
                archiveVersion: archiveVersion,
                decode: { try GeneaLogicJSONCoding.decoder.decode(Dismissal.self, from: $0) },
                uid: { $0.uid.raw },
                version: { $0.schemaVersion },
                store: { try self.upsert($0) })

            skipped.sort { $0.path < $1.path }
            for (path, reason) in skipped {
                let stmt = try db.prepare(
                    "INSERT INTO unreadable_record (path, reason) VALUES (?, ?);")
                try db.bind(path, at: 1, on: stmt)
                try db.bind(reason.rawValue, at: 2, on: stmt)
                try db.run(stmt)
            }

            // **Keyed on the uid being live again, not on the path being
            // reported unreadable** (review finding, 58). Fork (c) says a copy is
            // dropped when the record reads again or when a human discards it,
            // never otherwise, and "is it in `unreadable_record`?" answers a
            // narrower question than that: a sidecar that is *gone* — deleted in
            // Finder, dropped by a sync — is skipped by the walk without ever
            // being reported unreadable, so keying on that list threw its copy
            // away, which is the one thing this table exists to prevent.
            //
            // A record the walk could read has a row again, so the copy is
            // redundant. That reading is also what keeps a **renamed** artifact
            // folder from leaving a phantom: the record is live under its new
            // path, its uid is back, and the stale copy staged against the old
            // path goes — where a path-keyed rule would have kept a "restorable"
            // duplicate of a perfectly healthy record.
            try db.exec(
                "DELETE FROM orphaned_record WHERE uid IN ("
                    + "SELECT uid FROM artifact UNION ALL SELECT uid FROM person "
                    + "UNION ALL SELECT uid FROM relationship UNION ALL SELECT uid FROM link "
                    + "UNION ALL SELECT uid FROM dismissal);")

            try pruneDeletedRecordCopies(keepingPathsIn: manifestRecordPaths, root: root)
            if !unlinkedByDiedWrite.isEmpty {
                try discardPreservedRecords(
                    atPaths: try preservedRecordPaths().filter {
                        unlinkedByDiedWrite.contains($0)
                            && Self.isGone(root.appendingPathComponent($0)) == true
                    })
            }

            try db.setUserVersion(Self.schemaVersion)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
        return skipped
    }

    /// Walks one `conclusions/<kind>/` directory. `decode` is the skippable half
    /// (see `rebuild`); `store` is not — its failures are the index's own.
    ///
    /// **Only `<uid>.json` is loaded (slice 50c).** A file that decodes but whose
    /// name is not the uid inside it is a second copy of a record — a sync
    /// provider's conflicted copy, or a hand-rename — and loading it let it win
    /// the uid on enumeration order and be written back over the real sidecar by
    /// the next mutation. It is **not** `skipped`: that list means *could not be
    /// read or decoded*, and this file read perfectly. `verifyIntegrity()` reports
    /// it as `.conflictingCopy` instead.
    private func loadConclusions<Record>(
        from directory: URL,
        in root: URL,
        skipped: inout [(path: String, reason: UnreadableRecordReason)],
        archiveVersion: String,
        decode: (Data) throws -> Record,
        uid: (Record) -> String,
        version: (Record) -> String,
        store: (Record) throws -> Void
    ) throws {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return }

        for file in files where file.pathExtension.lowercased() == "json" {
            let path = ArchiveLayout.relativePath(of: file, in: root)
            let record: Record
            do {
                record = try decode(try Data(contentsOf: file))
            } catch {
                skipped.append((path, .undecodable))
                continue
            }
            // Ahead of the archive is refused whatever the file is called: a
            // conflicted copy from a newer build is the same evidence about the
            // archive as the record itself would be. Behind it is judged only for
            // the file that *is* the record.
            try Migration.refuseIfAhead(version(record), path: path)
            guard RecordDiscovery.isCanonicalConclusionFile(file, uid: uid(record)) else {
                continue
            }
            if SchemaVersion.isNewer(archiveVersion, than: version(record)) {
                skipped.append((path, .olderFormat))
                continue
            }
            try store(record)
        }
    }

    // MARK: - What this index was built from (slice 60)

    /// The `meta` key the manifest witness is stored under.
    private static let witnessKey = "manifestWitness"

    /// The witness this index was last built or committed against, or `nil` if
    /// it has none — an index written before slice 60, or one whose row is
    /// unparseable. **Callers must read `nil` as *unknown*, therefore stale**,
    /// which costs one rebuild on the first open after the upgrade.
    ///
    /// **This is why the `meta` table needs no `schemaVersion` bump.** It is
    /// added by `CREATE TABLE IF NOT EXISTS` and is additive for an older build,
    /// which never looks at it. A bump would be actively harmful here: a version
    /// mismatch takes `Archive.openOrRebuildIndex`'s *new-file* path, which
    /// unlinks the database before rebuilding — destroying the preserved copies
    /// of unreadable records that slice 58 exists to keep (see `schemaVersion`'s
    /// note on v7). Adopting this feature must not cost an archive the one copy
    /// of a record it cannot read.
    func manifestWitness() throws -> ManifestWitness? {
        try metaValue(Self.witnessKey).flatMap(ManifestWitness.init(storedValue:))
    }

    /// The `meta` key holding the digest the `settled_file` rows were written
    /// from — the marker that says whether those rows describe the witness above
    /// (slice 60c).
    private static let settledFilesKey = "settledFiles"

    /// Records the witness this index now reflects, **together with the entries
    /// it is a digest of** (slice 60c).
    ///
    /// `files` is not optional and not a second call, deliberately: the witness
    /// is what says *a* delivery is in flight and these rows are what say *which
    /// files it covers*, so a state where one has advanced and the other has not
    /// would let the engine answer the per-entry question from a manifest it no
    /// longer holds. One call, one transaction, and no call site that can forget.
    ///
    /// **The rows are rewritten only when they would change.** The witness digest
    /// is a function of exactly these three fields over exactly these entries, so
    /// a digest equal to the one the rows were last written from means the rows
    /// are already right — which is the common case, since the witness is
    /// re-recorded on every mutation and on every open whose stamp moved without
    /// its contents changing. An index written before this slice has no marker
    /// row at all, so it rewrites once and is backfilled from then on.
    func setManifestWitness(_ witness: ManifestWitness, files: [ManifestEntry]) throws {
        try db.exec("BEGIN IMMEDIATE;")
        do {
            if try metaValue(Self.settledFilesKey) != witness.digest {
                try db.exec("DELETE FROM settled_file;")
                // **`OR IGNORE`, and one statement for the whole list.** A
                // manifest naming the same path twice is not this engine's
                // output, but nothing rejects one on load and every other reader
                // of `manifest.files` already tolerates it by keeping the first
                // (`authoredBaseline`, `authoredEntries`, `repairPlans`, all with
                // `uniquingKeysWith:`) — so the primary key must not be the one
                // place a duplicate makes the archive *fail to open*
                // (`/code-review`). Preparing once rather than per row is the
                // other half: it was ~80% of the rewrite (see the measurement on
                // `Archive.commitManifest`).
                let stmt = try db.prepare(
                    "INSERT OR IGNORE INTO settled_file (path, sha256, byte_length) "
                        + "VALUES (?1, ?2, ?3);")
                defer { db.finalize(stmt) }
                for entry in files {
                    try db.bind(entry.path, at: 1, on: stmt)
                    try db.bind(entry.sha256, at: 2, on: stmt)
                    try db.bind(entry.byteLength, at: 3, on: stmt)
                    try db.runReusing(stmt)
                }
                try setMetaValue(Self.settledFilesKey, to: witness.digest)
            }
            try setMetaValue(Self.witnessKey, to: witness.storedValue)
            try db.exec("COMMIT;")
        } catch {
            try? db.exec("ROLLBACK;")
            throw error
        }
    }

    /// **What this machine's local writes superseded** — the third point of
    /// reference the merge needs, and the one neither the manifest nor the
    /// settled entries can supply (slice 50).
    ///
    /// The settled entries say what we hold; the arriving manifest says what the
    /// sender holds. When those disagree and the disk still holds ours, *the two
    /// possible stories are indistinguishable*: their manifest may predate our
    /// write (a race, and ours is ahead), or it may describe an edit of theirs
    /// still on its way (a delivery, and theirs is ahead). These rows break the
    /// tie by evidence rather than by guess: an arriving entry that is one of the
    /// versions our own writes replaced proves the sender has not heard about
    /// those writes, so the race reading is the true one.
    ///
    /// **Every predecessor, not just the first** (`/code-review`). Keeping only
    /// the entry a path started from is right for a machine editing offline and
    /// **wrong the moment the two machines exchange anything**: once the other
    /// machine adopts our E1 and writes again, its manifest legitimately names
    /// E1, and if we have meanwhile moved to E2 that E1 must still be recognised
    /// as behind us. It is not the *first* version that identifies a stale
    /// manifest, it is any version we have moved on from — so this is a set per
    /// path, `INSERT OR IGNORE` on `(path, sha256)`.
    ///
    /// **Rows, not one blob, and that is a cost decision** (`/code-review`). A
    /// blob has to be decoded and re-encoded on *every* manifest-changing
    /// mutation just to add one predecessor — O(everything ever edited) under the
    /// archive lock, on a path the blob's own justification claimed it never took.
    /// Rows make the write O(paths this mutation changed) and leave the whole-set
    /// read to the merge, which is rare. This is the opposite trade from
    /// `settled_file`, whose measurement chose bulk rewrites, because the access
    /// pattern is the opposite.
    ///
    /// **Machine-local and expendable**, like everything else in `.index/`. It
    /// survives `rebuild(walking:)` — which deliberately keeps this table, `meta`
    /// and `settled_file` — and is lost only when the database is unlinked and
    /// recreated (`openOrRebuildIndex`'s missing/unopenable/schema-stale branch)
    /// or when the index is deleted outright. The merge then falls back to taking
    /// the arriving manifest whole, which is slice 60's behaviour: safe, and it
    /// merely leaves a race unresolved until local writes record evidence again.
    ///
    /// **The residue, stated rather than implied:** an archive that syncs with
    /// nothing prunes nothing, so its rows grow with every distinct version of
    /// every path it has ever edited. That is affordable *because* it is rows —
    /// the write stays O(paths this mutation changed) and only the merge, which
    /// is rare, reads the set — but it is unbounded, and a retention rule wants
    /// evidence this slice does not have. Watch for it the way slice 48's parked
    /// sweep watches for abandoned machine directories.
    func supersededFiles() throws -> [String: [ManifestEntry]] {
        var result: [String: [ManifestEntry]] = [:]
        let stmt = try db.prepare("SELECT path, sha256, byte_length FROM superseded_file;")
        try db.query(stmt) { row in
            let path = db.columnText(row, 0)
            result[path, default: []].append(
                ManifestEntry(
                    path: path, sha256: db.columnText(row, 1),
                    byteLength: db.columnInt64(row, 2)))
        }
        return result
    }

    /// Adds `entries` to the set above, ignoring any already recorded.
    func noteSuperseded(_ entries: [ManifestEntry]) throws {
        guard !entries.isEmpty else { return }
        let stmt = try db.prepare(
            "INSERT OR IGNORE INTO superseded_file (path, sha256, byte_length) "
                + "VALUES (?1, ?2, ?3);")
        defer { db.finalize(stmt) }
        for entry in entries {
            try db.bind(entry.path, at: 1, on: stmt)
            try db.bind(entry.sha256, at: 2, on: stmt)
            try db.bind(entry.byteLength, at: 3, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// Drops every predecessor recorded for `paths` — used when the other machine
    /// is proved to hold our current version, at which point none of them can
    /// identify a stale manifest any more.
    func forgetSuperseded(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("DELETE FROM superseded_file WHERE path = ?;")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// **Paths this machine's own writes *removed*** — the positive evidence a
    /// deletion leaves behind, and the fact slice 50b's drop rule turns on.
    ///
    /// **It exists because absence is not evidence** (`/code-review`, 50b). The
    /// rule first read fact (i) off `settled_file`: a path our settled entries do
    /// not name, which "only a manifest we committed after deleting produces". It
    /// does not. `settled_file` moves only when a mutation starts current or a
    /// delivery settles, so while one is stuck in flight it lags arbitrarily — a
    /// record created *and then edited* in that window is in `superseded_file`
    /// and has never been in `settled_file`. If its file was then lost out of
    /// band and an older manifest naming the superseded version arrived, all
    /// three facts passed, the entry was dropped, and a real loss went
    /// unreported. Recording the deletion where it happens cannot fail that way:
    /// nothing but a removal writes here.
    ///
    /// **Additive, and no `schemaVersion` bump** — the same argument `meta`
    /// carries: an older build never looks at it, and a newer build finding it
    /// empty simply does not drop anything, which is slice 50's behaviour. A bump
    /// would take `Archive.openOrRebuildIndex`'s new-file path and destroy 58's
    /// preserved copies.
    func deletedPaths() throws -> Set<String> {
        var result: Set<String> = []
        let stmt = try db.prepare("SELECT path FROM deleted_path;")
        try db.query(stmt) { row in result.insert(db.columnText(row, 0)) }
        return result
    }

    /// Notes that this machine removed `paths`.
    func noteDeleted(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("INSERT OR IGNORE INTO deleted_path (path) VALUES (?);")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// Drops the note for `paths` — called when a path is authored again, since
    /// a record that is back is no longer one we removed, and leaving the note
    /// would license dropping its entry if the new file were later lost.
    func forgetDeleted(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("DELETE FROM deleted_path WHERE path = ?;")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// **Paths a human told this machine to stop waiting for**, each with the
    /// checksum the abandonment left standing — the trail slice 50d's
    /// `abandonDelivery(path:)` leaves, and the reason an abandonment is not
    /// indistinguishable from an ordinary write.
    ///
    /// **It is a note, never a finding.** `IntegrityReport.abandonedPaths`
    /// carries it beside `issues` rather than in them, so `isClean` stays true:
    /// nothing here is wrong with the archive. What it answers is the question a
    /// user has later — *why does this record hold my version and not theirs?* —
    /// which nothing else on disk can, because the manifest entry an abandonment
    /// mints looks exactly like one an ordinary commit mints.
    ///
    /// **The checksum is what makes the note self-pruning**, and that is why it
    /// is stored rather than derived. A note means anything only while the entry
    /// it explains is still the one standing; once the version lands after all,
    /// or the record is edited here, the entry did not come from the
    /// abandonment and saying so would misattribute it. Clearing it from the
    /// mutation path instead was tried and is not enough — an arrival is adopted
    /// through `commitManifest`'s delivered-manifest branch, which recomputes
    /// nothing and so has no before-and-after to compare (found by
    /// `aVersionThatLandsAfterAnAbandonmentIsStillTakenUp`). Holding the hash
    /// lets any reader decide it against the manifest in front of them.
    ///
    /// The empty string is the **absent** case: the abandonment dropped the
    /// entry because nothing had ever arrived, so the note stands exactly while
    /// the manifest still names no such path.
    ///
    /// **Additive, and no `schemaVersion` bump**, for the reason `deleted_path`
    /// gives above: an older build never looks at it, a newer build finding it
    /// empty simply reports no notes, and a bump would take
    /// `Archive.openOrRebuildIndex`'s new-file path and destroy 58's preserved
    /// copies.
    func abandonedNotes() throws -> [String: String] {
        var result: [String: String] = [:]
        let stmt = try db.prepare("SELECT path, sha256 FROM abandoned_path;")
        try db.query(stmt) { row in
            result[db.columnText(row, 0)] = db.columnText(row, 1)
        }
        return result
    }

    /// Notes that a human abandoned the delivery of `path`, recording the
    /// checksum the manifest is left holding for it — the empty string where the
    /// entry was dropped because no file had arrived.
    func noteAbandoned(path: String, sha256: String) throws {
        let stmt = try db.prepare(
            "INSERT OR REPLACE INTO abandoned_path (path, sha256) VALUES (?, ?);")
        try db.bind(path, at: 1, on: stmt)
        try db.bind(sha256, at: 2, on: stmt)
        try db.run(stmt)
    }

    /// Drops notes that no longer describe the manifest — see `abandonedNotes()`.
    func forgetAbandoned(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("DELETE FROM abandoned_path WHERE path = ?;")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// **Delivered entries 50's merge overruled**, by path — kept so the decision
    /// can be revisited when the overruled version turns up on disk (slice 50e).
    ///
    /// The merge keeps ours (or drops a path we deleted) when the arriving entry is
    /// a version our own writes replaced, reading that as *the sender never heard
    /// of our write*. A version can recur, though — an undo writes the exact
    /// snapshot back — and then the sender's record lands after its manifest with
    /// bytes the merge already decided against. The two manifests cannot tell the
    /// cases apart; the disk can, later, and this table is what lets it be asked.
    ///
    /// Machine-local and expendable like `superseded_file`: survives a rebuild,
    /// lost only with the database, after which the merge behaves as it did before
    /// 50e. **Additive, and no `schemaVersion` bump**, for `abandonedNotes()`'s
    /// reason.
    func contestedEntries() throws -> [String: ContestedEntry] {
        var result: [String: ContestedEntry] = [:]
        let stmt = try db.prepare(
            "SELECT path, theirs_sha256, theirs_byte_length, ours_sha256, ours_byte_length "
                + "FROM contested_file;")
        try db.query(stmt) { row in
            let path = db.columnText(row, 0)
            let oursSHA256 = db.columnText(row, 3)
            result[path] = ContestedEntry(
                theirs: ManifestEntry(
                    path: path, sha256: db.columnText(row, 1), byteLength: db.columnInt64(row, 2)),
                ours: oursSHA256.isEmpty
                    ? nil
                    : ManifestEntry(
                        path: path, sha256: oursSHA256, byteLength: db.columnInt64(row, 4)))
        }
        return result
    }

    /// Records that a merge overruled each of `contests`, replacing any earlier note
    /// for the same path.
    func noteContested(_ contests: [ContestedEntry]) throws {
        guard !contests.isEmpty else { return }
        let stmt = try db.prepare(
            "INSERT OR REPLACE INTO contested_file "
                + "(path, theirs_sha256, theirs_byte_length, ours_sha256, ours_byte_length) "
                + "VALUES (?1, ?2, ?3, ?4, ?5);")
        defer { db.finalize(stmt) }
        for contest in contests {
            try db.bind(contest.theirs.path, at: 1, on: stmt)
            try db.bind(contest.theirs.sha256, at: 2, on: stmt)
            try db.bind(contest.theirs.byteLength, at: 3, on: stmt)
            try db.bind(contest.ours?.sha256 ?? "", at: 4, on: stmt)
            try db.bind(contest.ours?.byteLength ?? 0, at: 5, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// The digest of the manifest this machine last wrote — what lets a merge
    /// tell its own manifest, read back, from one that arrived (slice 50e). `nil`
    /// for an index that has never recorded one.
    func lastWrittenManifestDigest() throws -> String? {
        try metaValue("lastWrittenManifestDigest")
    }

    func setLastWrittenManifestDigest(_ digest: String) throws {
        try setMetaValue("lastWrittenManifestDigest", to: digest)
    }

    /// Drops the notes for `paths` — resolved, or no longer standing.
    func forgetContested(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("DELETE FROM contested_file WHERE path = ?;")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// The digest the `settled_file` rows below were written from, or `nil` for an
    /// index that has none — one written before slice 60c.
    ///
    /// It identifies the rows, which is what makes it a sound cache key for them
    /// (see `Archive.cachedSettledFiles`), and it is what lets a caller skip
    /// reading rows that are not there.
    func settledFilesDigest() throws -> String? {
        try metaValue(Self.settledFilesKey)
    }

    /// The entries of the manifest this index last settled, keyed by path — the
    /// per-entry half of the witness (slice 60c).
    ///
    /// **Empty is a meaningful answer, not a missing one.** An index written
    /// before this slice has a witness and no rows, and reads as *no per-entry
    /// history*: every path is then unmatched, which is exactly slice 60's
    /// archive-wide behaviour for the one window before the next settling
    /// backfills the rows. See `DeliveryCoverage`.
    func settledFiles() throws -> [String: ManifestEntry] {
        var result: [String: ManifestEntry] = [:]
        let stmt = try db.prepare("SELECT path, sha256, byte_length FROM settled_file;")
        try db.query(stmt) { row in
            let path = db.columnText(row, 0)
            result[path] = ManifestEntry(
                path: path, sha256: db.columnText(row, 1),
                byteLength: db.columnInt64(row, 2))
        }
        return result
    }

    private func metaValue(_ key: String) throws -> String? {
        var stored: String?
        let stmt = try db.prepare("SELECT value FROM meta WHERE key = ?1;")
        try db.bind(key, at: 1, on: stmt)
        try db.query(stmt) { row in stored = db.columnText(row, 0) }
        return stored
    }

    private func setMetaValue(_ key: String, to value: String) throws {
        let stmt = try db.prepare(
            "INSERT INTO meta (key, value) VALUES (?1, ?2) "
                + "ON CONFLICT(key) DO UPDATE SET value = excluded.value;")
        try db.bind(key, at: 1, on: stmt)
        try db.bind(value, at: 2, on: stmt)
        try db.run(stmt)
    }

    /// The records the last rebuild had to skip, sorted — see `rebuild`. Both
    /// reasons: every caller of this form wants *what is absent from the index*,
    /// which is the property the two share.
    func unreadableRecordPaths() throws -> [String] {
        var result: [String] = []
        let stmt = try db.prepare("SELECT path FROM unreadable_record ORDER BY path;")
        try db.query(stmt) { row in result.append(db.columnText(row, 0)) }
        return result
    }

    /// The same list with why each was skipped. A reason this build does not
    /// know — a row written by a newer one — reads as `.undecodable`, the
    /// reason that offers the least.
    func unreadableRecords() throws -> [(path: String, reason: UnreadableRecordReason)] {
        var result: [(path: String, reason: UnreadableRecordReason)] = []
        let stmt = try db.prepare("SELECT path, reason FROM unreadable_record ORDER BY path;")
        try db.query(stmt) { row in
            result.append(
                (
                    db.columnText(row, 0),
                    UnreadableRecordReason(rawValue: db.columnText(row, 1)) ?? .undecodable
                ))
        }
        return result
    }

    /// Why the record at `path` was skipped, or `nil` when it was not.
    func unreadableRecordReason(atPath path: String) throws -> UnreadableRecordReason? {
        var reason: UnreadableRecordReason?
        let stmt = try db.prepare("SELECT reason FROM unreadable_record WHERE path = ?;")
        try db.bind(path, at: 1, on: stmt)
        try db.query(stmt) { row in
            reason = UnreadableRecordReason(rawValue: db.columnText(row, 0)) ?? .undecodable
        }
        return reason
    }

    // MARK: - Preserved copies of unreadable records (slice 58)

    /// Copies every live row into `orphaned_record`, keyed by the path the record
    /// occupies on disk, so `rebuild` can keep the ones its walk turns out not to
    /// be able to read. Called inside `rebuild`'s transaction, immediately before
    /// the tables are cleared; everything it stages that *is* readable is pruned
    /// again at the end of the same transaction.
    ///
    /// **The path is reconstructed, not stored**, because no table records one —
    /// an artifact's comes from its `slug` column and a conclusion's from its
    /// `uid`, which is exactly how `Archive+Conclusions` names the files it
    /// writes. A hand-placed conclusion file under some *other* name therefore
    /// stages a path that matches nothing and is pruned; it loses preservation,
    /// never gains a wrong copy, since only paths the walk actually reported as
    /// unreadable survive.
    ///
    /// The directory names are compile-time constants from `ArchiveLayout` — the
    /// same reason interpolating them is safe as in `uids(inTable:)`.
    ///
    /// **What copying everything costs, measured rather than assumed** (review
    /// finding, 58 — the objection is that almost every staged row is deleted
    /// again moments later). Over 600 records: rebuild **34.2 ms with staging vs
    /// 33.1 ms without** (medians of 7, warm), because the copy is intra-database
    /// — no parsing, no per-record syscalls — against a walk that reads, decodes
    /// and re-encodes every file. The index file's high-water mark goes 385 KB →
    /// 737 KB, and **stays there** across repeated rebuilds rather than growing:
    /// the deleted pages are free-listed and reused. Judged worth it; the
    /// alternative that avoids the copy is to defer clearing the live tables and
    /// delete by exclusion afterwards, which trades this for a much larger change
    /// to the one function that must never lose rows.
    private func stagePreservationCandidates() throws {
        try db.exec(Self.recordTables.map { Self.stagingSQL($0, schema: "main") }.joined())
    }

    /// The tables whose rows are records — and so preservation candidates — each
    /// with the SQL for the path its record occupies on disk. One list, so a new
    /// record table is one entry here.
    private static let recordTables: [(table: String, path: String)] = [
        (
            "artifact",
            "'\(ArchiveLayout.artifactsDirectoryName)/' || slug || '/\(ArchiveLayout.recordFileName)'"
        ),
        ("person", "'\(ArchiveLayout.personsDirectoryRelativePath)/' || uid || '.json'"),
        (
            "relationship",
            "'\(ArchiveLayout.relationshipsDirectoryRelativePath)/' || uid || '.json'"
        ),
        ("link", "'\(ArchiveLayout.linksDirectoryRelativePath)/' || uid || '.json'"),
        ("dismissal", "'\(ArchiveLayout.dismissalsDirectoryRelativePath)/' || uid || '.json'"),
    ]

    /// Copies `schema`'s rows of one record table into `main.orphaned_record`
    /// under the path each occupies on disk (see `stagePreservationCandidates`
    /// for why it is rebuilt).
    private static func stagingSQL(_ table: (table: String, path: String), schema: String) -> String
    {
        "INSERT OR REPLACE INTO main.orphaned_record (path, uid, json) "
            + "SELECT \(table.path), uid, json FROM \(schema).\(table.table);"
    }

    /// Carries the preserved copies out of the database at `previous` — the file
    /// `Archive.openOrRebuildIndex` is about to replace — into this one (slice 69,
    /// fork a). Called on the new file before its first rebuild, which then keeps
    /// exactly what a same-schema rebuild of the old file would have kept.
    ///
    /// **Its live rows are carried too, as candidates.** A rebuild stages the live
    /// tables before clearing them (`stagePreservationCandidates`), and that is
    /// what keeps a copy of a record that turned unreadable since the last one; a
    /// new file has no live rows to stage, so a record unreadable at the moment of
    /// a schema bump lost its copy on the way in (58's note on v7). Staged in the
    /// same order — earlier copies first, live rows replacing them by path — and
    /// the rebuild prunes every one whose uid it finds live.
    ///
    /// **Only tables that are there**: a database from before v7 has no
    /// `orphaned_record` and one from before v4 no `dismissal`, and that is not a
    /// failure. The columns read — `uid`, `json`, `slug` — have the same shape in
    /// every version.
    ///
    /// **Returns whether everything was carried.** Each statement commits on its
    /// own, so whatever a damaged file still yields is kept even when the rest of
    /// it cannot be read; `false` tells the caller to keep the file rather than
    /// delete the only place the rest might be.
    func carryPreservedCopies(from previous: URL) -> Bool {
        do {
            let attach = try db.prepare("ATTACH DATABASE ? AS previous;")
            do {
                try db.bind(previous.path, at: 1, on: attach)
            } catch {
                db.finalize(attach)
                throw error
            }
            try db.run(attach)
        } catch {
            return false
        }
        defer { try? db.exec("DETACH DATABASE previous;") }

        var tables: Set<String> = []
        do {
            let stmt = try db.prepare(
                "SELECT name FROM previous.sqlite_master WHERE type = 'table';")
            try db.query(stmt) { row in tables.insert(db.columnText(row, 0)) }
        } catch {
            return false
        }

        var carriedEverything = true
        if tables.contains("orphaned_record") {
            do {
                try db.exec(
                    "INSERT OR REPLACE INTO main.orphaned_record (path, uid, json) "
                        + "SELECT path, uid, json FROM previous.orphaned_record;")
            } catch {
                carriedEverything = false
            }
        }
        for table in Self.recordTables where tables.contains(table.table) {
            do {
                try db.exec(Self.stagingSQL(table, schema: "previous"))
            } catch {
                carriedEverything = false
            }
        }
        return carriedEverything
    }

    /// Drops the copy of every record that was **deleted** rather than lost (slice
    /// 58c): the manifest this rebuild was given no longer names its path, and
    /// nothing is on disk there.
    ///
    /// On disk the two look the same — a sidecar deleted in Finder, dropped by a
    /// sync, or deleted on the other machine is simply absent, which is why 58
    /// keeps a copy of every one. **The manifest tells them apart:** only a commit
    /// drops an entry, so a lost file keeps its entry (reported `missingFile`, and
    /// its copy kept for the repair), while a deletion delivered from another
    /// machine arrives with a manifest that has already let it go. Left alone, that
    /// copy was kept for good — nothing prunes a uid that is never live again —
    /// shown nowhere, and since 58b it reserved the folder's name.
    ///
    /// **Over the whole table, not just this rebuild's staging**: a delivery that
    /// lands the file's removal before the manifest has its copy staged one
    /// rebuild earlier, against a manifest that still named it. And a file that is
    /// *there* keeps its copy whatever the manifest says — unreadable is damage,
    /// not a deletion. The one loss this misreads — a file lost out of band just as
    /// an older manifest that never named it arrives — is one that manifest has
    /// already made unreported (49 fork f), so the copy would be the same
    /// invisible row.
    ///
    /// The table holds only the records some rebuild could not read, so the probe
    /// is a handful of `lstat`s, not a walk.
    private func pruneDeletedRecordCopies(
        keepingPathsIn manifestRecordPaths: Set<String>, root: URL
    ) throws {
        try discardPreservedRecords(
            atPaths: try preservedRecordPaths().filter {
                !manifestRecordPaths.contains($0)
                    && Self.isGone(root.appendingPathComponent($0)) == true
            })
    }

    /// Whether nothing can be at `url`: `true` for `ENOENT`, and for `ENOTDIR` —
    /// a path component is a plain file, so nothing exists beneath it (second
    /// `/code-review`); `false` when something is there; **`nil` when the file
    /// system cannot say** (`EACCES`, `EIO`). A prune keeps the copy on `nil`: it
    /// runs inside the rebuild's transaction, where a throw failed the open over a
    /// cleanup the walk itself tolerates, and keeping is the side a later rebuild
    /// can still correct.
    static func isGone(_ url: URL) -> Bool? {
        do {
            return try AtomicIO.isAbsent(url)
        } catch let error as POSIXError where error.code == .ENOTDIR {
            return true
        } catch {
            return nil
        }
    }

    /// Drops the copies at `paths`, one prepared statement for the lot.
    private func discardPreservedRecords(atPaths paths: [String]) throws {
        guard !paths.isEmpty else { return }
        let stmt = try db.prepare("DELETE FROM orphaned_record WHERE path = ?;")
        defer { db.finalize(stmt) }
        for path in paths {
            try db.bind(path, at: 1, on: stmt)
            try db.runReusing(stmt)
        }
    }

    /// The last index row of the record at `path`, if the rebuild that skipped it
    /// had one to keep — the sidecar's own bytes, not a summary of them.
    ///
    /// **It lives in a table of its own so that it is unreachable from every other
    /// query, by construction rather than by discipline.** A preserved record is
    /// one the archive *cannot currently read from disk*; surfacing it in a browse
    /// list would invert 55 and 56's whole story and show a phantom that looks
    /// healthy. A `quarantined` flag on the live rows would have left that
    /// correctness to every `SELECT` anyone writes from now on — the same
    /// reasoning as 57's `FileSweepReport` not being an `IntegrityReport`.
    func preservedRecord(atPath path: String) throws -> (uid: String, json: Data)? {
        let stmt = try db.prepare("SELECT uid, json FROM orphaned_record WHERE path = ?;")
        try db.bind(path, at: 1, on: stmt)
        var result: (uid: String, json: Data)?
        try db.query(stmt) { row in
            result = (uid: db.columnText(row, 0), json: db.columnData(row, 1))
        }
        return result
    }

    /// The paths that have a preserved copy, sorted.
    ///
    /// It neither contains nor is contained by `unreadableRecordPaths()`. A
    /// record can be unreadable with nothing kept for it (it never decoded on any
    /// rebuild, so there was never a row to keep), and a record whose file has
    /// *vanished* keeps a copy without being reported unreadable (the walk skips
    /// an absent sidecar silently; `verifyIntegrity()` reports it as a missing
    /// file instead).
    func preservedRecordPaths() throws -> [String] {
        var result: [String] = []
        let stmt = try db.prepare("SELECT path FROM orphaned_record ORDER BY path;")
        try db.query(stmt) { row in result.append(db.columnText(row, 0)) }
        return result
    }

    /// The slugs of every preserved **artifact** record but `excluded`'s own — the
    /// folders 58b's `takenArtifactSlugs` must not hand out. Conclusion copies are
    /// left in the table, not materialized and thrown away.
    func preservedArtifactSlugs(excluding excluded: ArtifactID?) throws -> [String] {
        var result: [String] = []
        let stmt = try db.prepare(
            "SELECT path FROM orphaned_record WHERE path LIKE '\(ArchiveLayout.artifactsDirectoryName)/%' "
                + "AND uid <> ?;")
        try db.bind(excluded?.raw ?? "", at: 1, on: stmt)
        try db.query(stmt) { row in
            if let slug = ArchiveLayout.artifactSlug(ofRecordPath: db.columnText(row, 0)) {
                result.append(slug)
            }
        }
        return result
    }

    /// Drops the "could not read this" finding for `path` — what a repair does
    /// once the record at that path reads again (slice 59), so the banner and the
    /// placeholder row go without waiting for the next rebuild to notice.
    ///
    /// Narrower than it looks: the rest of `unreadable_record` is left alone,
    /// because repairing one record says nothing about the others.
    func clearUnreadableRecord(atPath path: String) throws {
        let stmt = try db.prepare("DELETE FROM unreadable_record WHERE path = ?;")
        try db.bind(path, at: 1, on: stmt)
        try db.run(stmt)
    }

    /// Drops every preserved copy of `uid`, wherever it was staged — what a record
    /// becoming live again means, the same rule `rebuild`'s prune applies (58b).
    func discardPreservedRecords(of uid: String) throws {
        let stmt = try db.prepare("DELETE FROM orphaned_record WHERE uid = ?;")
        try db.bind(uid, at: 1, on: stmt)
        try db.run(stmt)
    }

    /// Drops the preserved copy for `path`. Lenient if there isn't one.
    func discardPreservedRecord(atPath path: String) throws {
        let stmt = try db.prepare("DELETE FROM orphaned_record WHERE path = ?;")
        try db.bind(path, at: 1, on: stmt)
        try db.run(stmt)
    }
}

/// One delivered entry 50's merge overruled: what the sender's manifest said, and
/// what the merge kept in its place — `nil` when it dropped the path, the 50b
/// half (slice 50e).
struct ContestedEntry: Equatable {
    let theirs: ManifestEntry
    let ours: ManifestEntry?
}

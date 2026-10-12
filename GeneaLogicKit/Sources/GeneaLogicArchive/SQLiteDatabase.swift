import CSQLite
import Foundation

/// A thin Swift wrapper around the vendored SQLite C API (`CSQLite`), scoped to
/// exactly what `ArchiveIndex` needs: open a file-backed connection, run DDL,
/// and prepare/bind/step/finalize statements.
///
/// **Concurrency model (judgment call, flagged for review):** `Archive` already
/// serializes ALL access — reads and writes — through its own `NSLock`
/// (`withState`/`withIndex` in `Archive.swift`). `SQLiteDatabase` therefore owns
/// exactly ONE `sqlite3*` connection for the archive's lifetime and assumes its
/// caller holds that lock; it adds no locking of its own. `SQLITE_THREADSAFE=1`
/// (set in `Package.swift`) is defense-in-depth for SQLite's own internal
/// bookkeeping, not a substitute for `Archive`'s lock — this type is `final
/// class`, not `Sendable`, precisely so a future caller can't reach for it
/// without going through `Archive`.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    /// The database file, for `WriteCheckpoint` — each statement that can write
    /// is a cut a crash could land on (slice 65).
    private let url: URL

    /// SQLite's `SQLITE_TRANSIENT` destructor constant. The amalgamation exposes
    /// it as a function-pointer macro that doesn't import into Swift (per the
    /// spike's `main.swift`), so it's reconstructed here once and reused by
    /// every bind call — telling SQLite to copy the bound bytes immediately,
    /// since the Swift `String`/`Data` backing them isn't guaranteed to outlive
    /// the call.
    static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// How long a statement waits for another *process*'s conflicting SQLite
    /// lock before returning `SQLITE_BUSY` (slice 47).
    ///
    /// Without this, a competing write returned `SQLITE_BUSY` **immediately** and
    /// the mutation threw — the single most likely way two GeneaLogic processes
    /// on one archive failed. `ArchiveLock` already serializes *writers*, so what
    /// remains for this to absorb is a reader (which deliberately takes no
    /// archive lock) holding a shared lock while a writer wants an exclusive one.
    ///
    /// Matched to `ArchiveLock.timeout` on purpose: both answer "how long is a
    /// competing process allowed to make us wait", and having them disagree would
    /// just mean one of the two decides in practice.
    static let busyTimeoutMilliseconds: Int32 = 5_000

    /// Opens (creating if absent) a file-backed SQLite database at `url`.
    /// The containing directory must already exist.
    init(at url: URL) throws {
        self.url = url
        let rc = sqlite3_open(url.path, &handle)
        guard rc == SQLITE_OK else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw ArchiveError.indexError(context: "open \(url.path)", message: message, code: rc)
        }
        // Foreign keys aren't load-bearing for this schema (every table is
        // independently rebuildable from the sidecars), but enabling them
        // costs nothing and catches accidental orphan rows during development.
        try exec("PRAGMA foreign_keys = ON;")
        // Set through the PRAGMA rather than `sqlite3_busy_timeout()` — they are
        // the same mechanism, but only the PRAGMA also *reads back*, which is
        // what makes `busyTimeout()` (and the test that pins it) possible.
        try exec("PRAGMA busy_timeout = \(Self.busyTimeoutMilliseconds);")
    }

    /// `PRAGMA data_version` — a counter that changes when **another**
    /// connection commits to this database, and provably never when *this* one
    /// does (SQLite guarantees the value is stable across your own commits).
    ///
    /// That asymmetry is the whole point: it lets a long-lived reader detect
    /// another process's writes without diffing content and without mistaking
    /// its own writes for someone else's. ARCHITECTURE.md §10.5 names it as the
    /// detection primitive; slice 51 is what finally uses it.
    func dataVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA data_version;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw ArchiveError.indexError(
                context: "read data_version", message: lastErrorMessage(), code: rc)
        }
        return sqlite3_column_int(stmt, 0)
    }

    /// The connection's current busy timeout, in milliseconds.
    func busyTimeout() throws -> Int32 {
        let stmt = try prepare("PRAGMA busy_timeout;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw ArchiveError.indexError(
                context: "read busy_timeout", message: lastErrorMessage(), code: rc)
        }
        return sqlite3_column_int(stmt, 0)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more `;`-separated statements with no parameters and no
    /// result rows (DDL, `PRAGMA`, simple `DELETE`/`BEGIN`/`COMMIT`, …).
    func exec(_ sql: String) throws {
        var errmsg: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let message = errmsg.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errmsg)
            throw ArchiveError.indexError(context: "exec", message: message, code: rc)
        }
        WriteCheckpoint.reached("sql exec", at: url)
    }

    /// Reads `PRAGMA user_version` (used to record/check the index-schema version).
    func userVersion() throws -> Int32 {
        let stmt = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw ArchiveError.indexError(
                context: "read user_version", message: lastErrorMessage(), code: rc)
        }
        return sqlite3_column_int(stmt, 0)
    }

    /// `PRAGMA quick_check` (slice 63, fork f): whether every page of the file is a
    /// well-formed b-tree page. `false` for a file whose header SQLite accepts but
    /// whose contents it cannot use — the one shape of corruption `open` and
    /// `user_version` (both header-only) cannot see. Reads the whole file once,
    /// linear in its size; it skips `integrity_check`'s index-versus-table
    /// cross-check, which is what makes it cheap enough to run on every open.
    func passesQuickCheck() throws -> Bool {
        let stmt = try prepare("PRAGMA quick_check;")
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW else {
            throw ArchiveError.indexError(
                context: "quick_check", message: lastErrorMessage(), code: rc)
        }
        return columnText(stmt, 0) == "ok"
    }

    /// Whether `error` is SQLite saying the **file** is bad — `SQLITE_CORRUPT` or
    /// `SQLITE_NOTADB` — rather than that it could not look (slice 69, fork b).
    ///
    /// Only these are evidence about the bytes. `IOERR`, `BUSY`, `NOMEM` and the
    /// rest say the read did not happen, and a database replaced on one of those
    /// was replaced on no evidence at all. Primary code, so an extended code
    /// (`SQLITE_CORRUPT_INDEX`, …) reads as its family.
    static func isCorruption(_ error: Error) -> Bool {
        guard case ArchiveError.indexError(_, _, let code) = error else { return false }
        let primary = code & 0xff
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Whether `error` is another connection holding the database — `SQLITE_BUSY`
    /// or `SQLITE_LOCKED`, after the busy timeout. The file is in use, which is
    /// the one thing it certainly is not: broken (slice 69, fork b).
    static func isInUse(_ error: Error) -> Bool {
        guard case ArchiveError.indexError(_, _, let code) = error else { return false }
        let primary = code & 0xff
        return primary == SQLITE_BUSY || primary == SQLITE_LOCKED
    }

    /// Sets `PRAGMA user_version`. `PRAGMA` doesn't accept bound parameters, so
    /// the integer is interpolated directly — safe here because it is always an
    /// engine-controlled `Int32` constant (`ArchiveIndex.schemaVersion`), never
    /// user input.
    func setUserVersion(_ version: Int32) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    /// Prepares `sql` into a statement handle. Caller owns finalization.
    func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw ArchiveError.indexError(
                context: "prepare(\(sql))", message: lastErrorMessage(), code: rc)
        }
        return stmt
    }

    /// `sqlite3_errmsg` for the last operation on this connection.
    func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }

    // MARK: - Bind helpers (1-based column indices, matching sqlite3_bind_*)

    /// Binds the string's **full** UTF-8 length, not `-1` (slice 63, fork g). With
    /// `-1` SQLite reads to the first NUL, and the format stores `\u0000` verbatim —
    /// a place or path carrying one was indexed cut short, and the `file` table
    /// feeds the manifest recompute, so the manifest would name a path that does
    /// not exist.
    func bind(_ value: String, at index: Int32, on stmt: OpaquePointer) throws {
        let rc = sqlite3_bind_text(
            stmt, index, value, Int32(value.utf8.count), Self.transientDestructor)
        try checkBind(rc, "bind text at \(index)")
    }

    func bind(_ value: Data, at index: Int32, on stmt: OpaquePointer) throws {
        let rc = value.withUnsafeBytes { bytes -> Int32 in
            sqlite3_bind_blob(
                stmt, index, bytes.baseAddress, Int32(bytes.count), Self.transientDestructor)
        }
        try checkBind(rc, "bind blob at \(index)")
    }

    func bind(_ value: Int64, at index: Int32, on stmt: OpaquePointer) throws {
        let rc = sqlite3_bind_int64(stmt, index, value)
        try checkBind(rc, "bind int64 at \(index)")
    }

    func bindNull(at index: Int32, on stmt: OpaquePointer) throws {
        let rc = sqlite3_bind_null(stmt, index)
        try checkBind(rc, "bind null at \(index)")
    }

    private func checkBind(_ rc: Int32, _ context: String) throws {
        guard rc == SQLITE_OK else {
            throw ArchiveError.indexError(context: context, message: lastErrorMessage(), code: rc)
        }
    }

    // MARK: - Step / column helpers

    /// Steps a statement expected to produce no result rows (INSERT/UPDATE/DELETE).
    /// Finalizes on every path.
    func run(_ stmt: OpaquePointer) throws {
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw ArchiveError.indexError(context: "step", message: lastErrorMessage(), code: rc)
        }
        WriteCheckpoint.reached("sql step", at: url)
    }

    /// Steps a statement expected to produce no result rows and **resets it for
    /// reuse** instead of finalizing, so a bulk write prepares once rather than
    /// once per row (slice 60c: re-preparing was ~80% of a `settled_file`
    /// rewrite). The caller owns the statement and must `finalize` it.
    func runReusing(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw ArchiveError.indexError(context: "step", message: lastErrorMessage(), code: rc)
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        WriteCheckpoint.reached("sql step", at: url)
    }

    /// Releases a statement stepped with `runReusing`.
    func finalize(_ stmt: OpaquePointer) {
        sqlite3_finalize(stmt)
    }

    /// Steps a SELECT, calling `row` for each `SQLITE_ROW`. Finalizes on every path.
    func query(_ stmt: OpaquePointer, _ row: (OpaquePointer) throws -> Void) throws {
        defer { sqlite3_finalize(stmt) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                try row(stmt)
            } else if rc == SQLITE_DONE {
                break
            } else {
                throw ArchiveError.indexError(
                    context: "step query", message: lastErrorMessage(), code: rc)
            }
        }
    }

    /// Read by byte count, not as a C string — the other half of `bind(String)`'s
    /// NUL rule (slice 63, fork g): `String(cString:)` stops at the first NUL too.
    func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(stmt, index) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
    }

    func columnInt64(_ stmt: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(stmt, index)
    }

    func columnData(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

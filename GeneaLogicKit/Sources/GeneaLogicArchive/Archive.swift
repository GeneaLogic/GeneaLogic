import Foundation
import GeneaLogicModel

/// An open GeneaLogic archive: a directory package, edited in place
/// (ARCHITECTURE.md §3, §6.3).
///
/// `Archive` is a reference type (`final class`) — not because records are
/// mutable references (they remain `Codable`/`Sendable` value types, returned as
/// snapshots per §5.1) but because the archive itself owns shared, mutable
/// engine state: the open directory handle, the in-memory index, and the
/// currently-loaded manifest, all of which every mutation must keep in lockstep.
/// A value-type `Archive` would make that coherence the caller's problem.
///
/// Conforms to `@unchecked Sendable`: all mutable state is confined behind the
/// `lock`, and every public method takes it before touching `manifest`/`index`.
///
/// **Three locks, three jobs (slice 47, re-ordered in 52).**
///
/// - `writerLock` serializes *this process's* writers against each other. It
///   exists so `fileLock` — which is not re-entrant, and whose `flock` is owned
///   by a file description shared by every thread here — only ever has one
///   in-process user at a time.
/// - `fileLock` (an `flock(2)` on `.index/lock`) serializes this process against
///   *other* processes: the app open on an archive while an agent drives `genea`
///   at it.
/// - `lock` guards `manifest`/`index` themselves. Mutations take it for the body
///   of the write; readers take only this one.
///
/// **The order matters, and it is `writerLock` → `fileLock` → `lock`** — not the
/// `lock` → `fileLock` of slice 47. Waiting for another process takes up to
/// `ArchiveLock.timeout` (5s), and under the old order the waiter held `lock`
/// throughout, so every *reader* queued behind it: a measured `artifacts()` on
/// another thread cost **1.82s** while a competing process held the archive.
/// That is what made slice 52's "mutations off the main actor" insufficient on
/// its own — moving the write to a background thread relocated the block to the
/// app's next read (the 1s external-change poll, or any detail-pane render)
/// rather than removing it. With the flock taken *outside* `lock`, the same read
/// costs 0.5ms. Readers can never deadlock against it because they never want
/// either of the other two locks. See `ArchiveLock` for why readers are exempt
/// from the flock and what staleness that admits.
public final class Archive: @unchecked Sendable {
    /// The archive's root directory URL.
    public let rootURL: URL

    /// Guards `manifest` and `index`. Held only for the body of a write, never
    /// across the wait for another process — see the type's doc comment.
    private let lock = NSLock()
    /// Serializes this process's own writers, so the non-re-entrant `fileLock`
    /// has exactly one in-process user at a time.
    private let writerLock = NSLock()
    private var manifest: Manifest
    /// `ArchiveIndex` is a reference type (it owns the `.index/index.sqlite`
    /// connection) — see its doc comment. It is `let`, not `var`: there is no
    /// "swap the index" operation, only mutation through its own methods, all
    /// of which (like `manifest`'s mutations) happen under `lock`.
    private let index: ArchiveIndex
    /// The cross-process write lock. Held open for this `Archive`'s lifetime;
    /// actually *locked* only for the body of a mutation (`withState`).
    private let fileLock: ArchiveLock

    /// Whether a write is known to have died between its sidecar and its
    /// manifest, leaving some entry describing bytes that are no longer there
    /// (slice 49, fork e). It is what lets a mismatch on an engine-authored file
    /// be reported as `.interruptedWrite` — suspect — rather than
    /// `.checksumMismatch` — corrupt.
    ///
    /// **Three transitions, and each is needed:**
    ///
    /// - **Set at `open()`** when `.index/dirty` was already there — and then
    ///   **settled** by `recoverFromInterruptedWrite()`, which keeps it only if
    ///   the manifest really is behind the rebuilt index and records that in
    ///   `InterruptedWriteMarker`, which later opens read (slice 65). It cannot
    ///   be read at verify time
    ///   instead: the marker is also set by every mutation *in flight*, so a
    ///   verify running beside a healthy concurrent write would read it and
    ///   report that write's ordinary progress as a died one.
    /// - **Set when a mutation of ours throws *having already authored a file***
    ///   (`withState`), which is the same situation arriving from the other
    ///   direction: the sidecar may already be on disk with the manifest still
    ///   describing the previous bytes. Without this, a verify later in the *same
    ///   session* would call our own half-finished write corruption, and only a
    ///   reopen would tell the truth (review finding, 49). **The "having already
    ///   authored a file" half is not a nicety** — see `withState`'s catch: once
    ///   58's drift guard began consulting this flag, arming it on failures that
    ///   wrote nothing let the guard's own refusal (and any unrelated validation
    ///   error) switch the guard off.
    /// - **Cleared by `rebaseline()`**, the one operation that actually resolves
    ///   it, which takes the marker away too. Not by an ordinary successful
    ///   mutation: that re-mints the entry for the file *it* wrote and says
    ///   nothing about whichever record was in flight when the write died.
    ///
    /// Guarded by `lock`, like `manifest`.
    var hasUnresolvedInterruptedWrite: Bool

    /// The bytes an interrupted write of ours left, by archive-relative path →
    /// SHA-256 — **the only thing 58's drift guard lets past while the flag above
    /// is up** (slice 68, fork c).
    ///
    /// The guard used to skip on the flag alone, which switched it off for the
    /// whole archive, across launches, until *Accept Current Contents*: a delivery
    /// or an agent's edit to any other record in that window was overwritten
    /// silently. The crash's own bytes are the one mismatch that must not block an
    /// edit, so the exemption is those and no wider. Keyed by hash as well as path,
    /// so bytes that move again after the crash are guarded like any other drift.
    ///
    /// **Taken from what we wrote, never inferred from what differs** (`/code-review`).
    /// The first cut exempted every engine-authored mismatch the recovering open
    /// found, which swept in any hand edit or delivery already on disk — on any
    /// record — and, for a pre-68 marker, everything that had drifted since the
    /// crash. Now the source is `IndexDirtyMarker`'s write-ahead journal (after a
    /// crash) or `authoredWrites` (a failure in this session), so a byte we did not
    /// write is never exempt. A pre-68 marker carries no journal and exempts
    /// nothing: the refusal's remedy is the one the interrupted write already asks
    /// for.
    ///
    /// **Pruned when we touch the path again**: a later successful write or
    /// removal of ours supersedes the crash's bytes, so they stop being exempt —
    /// otherwise those exact bytes put back by a sync or a restore would pass.
    /// Emptied by a `rebaseline()` that resolves the flag, and consulted only
    /// while the flag is up.
    ///
    /// Guarded by `lock`.
    var interruptedWriteExemptions: [String: String] = [:]

    /// Manifest entries minted from the bytes written **during the current
    /// mutation**, keyed by archive-relative path (slice 49).
    ///
    /// Populated by `writeAuthoredJSON`, consumed and cleared by `withState`'s
    /// closing `commitManifest`. Only ever touched from inside `withState`, so
    /// `lock` covers it.
    private var authoredWrites: [String: ManifestEntry] = [:]

    /// Engine-authored paths **this mutation deliberately removed** — the mirror
    /// of `authoredWrites`, and the thing that tells a deletion from a file that
    /// has not arrived yet (slice 60b, `/code-review`).
    ///
    /// Without it, `awaitedPaths` carries a deleted record's manifest entry
    /// forward on the reasoning that the index no longer naming a path means the
    /// file is still in flight. That reasoning is only sound for a path nobody
    /// asked to delete. When it is wrong the damage is permanent and
    /// self-sustaining: the phantom entry names a file that will never exist, so
    /// `manifestDeliveryLooksComplete` is false for ever, the witness can never
    /// settle, every later mutation carries the entry again, and
    /// `verifyIntegrity()` reports a missing file on every open from then on —
    /// with `deliveryIsInFlight` false, so no surface explains it.
    ///
    /// Populated by `removeAuthoredFile(at:)`, cleared by `withState` alongside
    /// `authoredWrites`. A path that is removed and then written again in the
    /// same mutation is a write: `authoredWrites` is consulted first.
    private var authoredRemovals: Set<String> = []

    /// Engine-authored paths **this mutation abandoned the delivery of** (slice
    /// 50d) — the one source of `abandoned_path` rows.
    ///
    /// It exists to keep the note from erasing itself. `recordWhatThisMutationSuperseded`
    /// clears an abandonment note whenever a path's entry moves, which is the
    /// right rule for every *later* mutation and exactly wrong for the one doing
    /// the abandoning: dropping the entry is how an abandonment is performed, so
    /// without this the row would be written and cleared inside one commit.
    ///
    /// Same lifecycle as `authoredWrites`, and `lock` covers it for the same
    /// reason.
    var abandonedThisMutation: Set<String> = []

    /// The manifest's recorded hash for each engine-authored path, as it stood
    /// when the **current mutation** began — what `writeAuthoredJSON` compares a
    /// sidecar against before overwriting it (slice 58, fork f).
    ///
    /// **Snapshotted into a property rather than read from `manifest`**, and that
    /// is structural, not stylistic: `withState` hands its body an `inout`
    /// binding to `self.manifest`, so reaching back through `self` for it from
    /// inside that body is a Swift exclusive-access violation that traps at
    /// runtime — the exact bug `commitManifest`'s note records. Same lifecycle as
    /// `authoredWrites`, and `lock` covers it for the same reason.
    private var authoredBaseline: [String: String] = [:]

    /// Paths the drift guard has already cleared **in the current mutation** —
    /// so a cascade's pre-flight and the chokepoint that follows it hash each
    /// record once, not twice, under the lock (slice 68, `/code-review`). Same
    /// lifecycle as `authoredWrites`.
    private var driftClearedThisMutation: Set<String> = []

    /// Whether the current mutation is a `rebaseline()` that resolved an
    /// interrupted write — the one success that may clear a sentinel it did not
    /// set (slice 65). Same lifecycle as `authoredWrites`.
    private var resolvedInterruptedWriteThisMutation = false

    /// Whether this mutation is a **witness-driven rebuild adopting a manifest
    /// somebody else wrote** (slice 60, fork e).
    ///
    /// Set by `reconcileIfStale()` and honoured — and reset — by
    /// `commitManifest`, which then takes an entirely different closing path: it
    /// **neither recomputes nor rewrites** `manifest.json`, and it proves the
    /// delivery whole before recording a witness.
    ///
    /// **Both halves are load-bearing, and the recompute half is the one that
    /// destroys data** (`/code-review`, slice 60). `recomputeManifestFiles`
    /// derives the authored set *from the index*, so a record the delivery has
    /// not brought yet is absent from the rebuilt index, contributes no path, and
    /// its entry is deleted — from the one document that says the file is
    /// expected. A staleness poll against a manifest-first delivery therefore
    /// rewrote the delivered manifest down to whatever had arrived. The entry is
    /// also exactly what the completeness check needs to see, so recomputing
    /// first made that check unable to fail: it inspected a manifest scrubbed of
    /// the very files that were missing, blessed the witness, and left a new
    /// record invisible permanently.
    ///
    /// Same lifecycle as `authoredWrites`, and `lock` covers it for the same
    /// reason.
    private var adoptingDeliveredManifest = false

    /// The shortest and longest a reconcile waits before re-attempting a delivery
    /// that would not settle — see `noteReconcileOutcome()`.
    ///
    /// **A test seam, like `lockTimeout`; production leaves the defaults.** A
    /// test that drives a delivery in one synchronous run would otherwise be
    /// asserting the clock rather than the convergence it means to assert, and
    /// sleeping through a real back-off in the suite is worse than parameterizing
    /// it. `ReconcileBackoffTests` covers the seam's own behaviour.
    var reconcileBackoffBounds: (minimum: Duration, maximum: Duration) {
        get {
            lock.lock()
            defer { lock.unlock() }
            return backoffBounds
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            backoffBounds = newValue
            reconcileBackoff = newValue.minimum
        }
    }

    private var backoffBounds: (minimum: Duration, maximum: Duration) = (
        .seconds(1), .seconds(30)
    )

    /// The settled entries the last `deliveryCoverage()` read, under the witness
    /// digest they belong to — guarded by `lock` (slice 60c, `/code-review`).
    ///
    /// **Keyed on the marker the rows were written under, so it needs no
    /// invalidation.** Rows and marker are written by one call, and the marker is
    /// re-read from the index on every question, so another process's settling
    /// produces a different key and misses. What it removes is the repeat: an in-flight archive is asked
    /// this once a second by the app's sweep, and the answer only changes when
    /// something settles. Measured at 20,000 entries the scan it skips is 10 ms,
    /// lock-held.
    private var cachedSettledFiles: (digest: String, files: [String: ManifestEntry])?

    /// The manifest stamp of the last reconcile that did **not** settle, the
    /// current wait, and when the next attempt is allowed. All guarded by `lock`.
    private var unsettledStamp: ManifestWitness.Stamp?

    /// Slice 50e's revisit: when a failed adoption may be retried, how long the
    /// next wait is, and what each probed record held at its last size and mtime.
    /// All guarded by `lock`.
    private var contestRetryAfter: ContinuousClock.Instant?
    private var contestBackoff: Duration = .seconds(1)
    private var contestProbes:
        [String: (size: Int64, modified: Double, sha256: String, holds: Bool)] = [:]
    private var reconcileBackoff: Duration = .seconds(1)
    private var nextReconcileAttempt: ContinuousClock.Instant?

    /// Whether the index matched the manifest **when this mutation started**, and
    /// so whether this mutation is entitled to certify it afterwards (slice 60,
    /// `/code-review`).
    ///
    /// A mutation records a witness on the way out. Doing that unconditionally
    /// meant any unrelated local edit — one `addPerson` — certified whatever
    /// state the index was in: a delivery that had arrived but not been noticed
    /// got stamped "current", `indexLooksStale()` agreed from then on, and the
    /// delivered record never appeared, through any number of reopens, with
    /// `verifyIntegrity()` reporting nothing. So the bless is conditional on
    /// having been current to begin with, which is one `stat` in the common case
    /// (our own last commit recorded the stamp of the file it wrote).
    private var indexWasCurrentAtStart = false

    /// How long a mutation waits for a competing process before throwing
    /// `ArchiveError.archiveBusy`. A test seam — production leaves the default.
    ///
    /// Guarded by `writerLock` — **not** `lock`, which no longer excludes a
    /// writer (52's re-ordering). `writerLock` is the one a mutation holds across
    /// `ArchiveLock.acquire`, so it is the only one that keeps setting the
    /// timeout from racing the waiter reading it.
    var lockTimeout: TimeInterval {
        get {
            writerLock.lock()
            defer { writerLock.unlock() }
            return fileLock.timeout
        }
        set {
            writerLock.lock()
            defer { writerLock.unlock() }
            fileLock.timeout = newValue
        }
    }

    init(
        rootURL: URL, manifest: Manifest, index: ArchiveIndex, fileLock: ArchiveLock,
        interruptedWriteOnOpen: Bool = false, interruptedWriteExemptions: [String: String] = [:]
    ) {
        self.rootURL = rootURL
        self.manifest = manifest
        self.index = index
        self.fileLock = fileLock
        self.hasUnresolvedInterruptedWrite = interruptedWriteOnOpen
        self.interruptedWriteExemptions = interruptedWriteExemptions
    }

    // MARK: - Create

    /// Creates a new, empty archive at `url` (a directory; created if absent).
    ///
    /// Writes `manifest.json` (minting a fresh `ArchiveID`) and copies the
    /// schema spec into `schema/` inside the archive, per ARCHITECTURE.md §3
    /// ("the schema spec travels with the archive").
    ///
    /// - Throws: `ArchiveError.alreadyExists` if `url` already contains a
    ///   `manifest.json`; filesystem errors otherwise.
    public static func create(at url: URL, name: String? = nil) throws -> Archive {
        let fm = FileManager.default
        let manifestURL = ArchiveLayout.manifestURL(in: url)

        // The lock has to exist before the `alreadyExists` guard, not after the
        // archive is built (review finding, 47): with the guard outside it, two
        // concurrent `create`s both saw no `manifest.json`, both proceeded, and
        // the second silently overwrote the first's `archiveUID` instead of
        // throwing. Creating the root and `.index/` up front is what makes a
        // lockfile possible at all, and is harmless — if the path turns out to
        // already hold an archive, `.index/` was there anyway.
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.indexDirectory(in: url), withIntermediateDirectories: true)
        let fileLock = try ArchiveLock(at: ArchiveLayout.lockURL(in: url), archiveRoot: url)

        let archive = try fileLock.withLock {
            try createLocked(at: url, name: name, manifestURL: manifestURL, fileLock: fileLock)
        }

        // Recompute the manifest's file list now that the schema spec has landed,
        // so `manifest.json` is internally consistent from the start (the spec
        // file is itself part of the integrity surface). Deliberately *outside*
        // the lock above: it goes through `withState`, which takes the same lock,
        // and `ArchiveLock` is not re-entrant — the inner scoped release would
        // drop the outer hold. Safe to run unlocked because the archive now has
        // a `manifest.json`, so a competing `create` fails its guard, and
        // `withState`'s manifest re-read means a competing mutation can't be
        // clobbered.
        try archive.withState { _, _ in }
        // **A fresh archive is current by construction, and must say so** (slice
        // 60): its index was built empty alongside an empty archive. Without this
        // the first mutation would find no recorded witness, read that as "not
        // current", and decline to record one — leaving a brand-new archive
        // permanently claiming staleness it does not have.
        archive.recordWitnessForFreshArchive()
        return archive
    }

    /// The body of `create(at:)`, run under the archive lock: everything from the
    /// existence check to a usable `Archive`, with no nested locking.
    private static func createLocked(
        at url: URL, name: String?, manifestURL: URL, fileLock: ArchiveLock
    ) throws -> Archive {
        let fm = FileManager.default
        if fm.fileExists(atPath: manifestURL.path) {
            throw ArchiveError.alreadyExists(url)
        }

        try fm.createDirectory(
            at: ArchiveLayout.artifactsDirectory(in: url), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.personsDirectory(in: url), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.relationshipsDirectory(in: url), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.linksDirectory(in: url), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.dismissalsDirectory(in: url), withIntermediateDirectories: true)
        try fm.createDirectory(
            at: ArchiveLayout.schemaDirectory(in: url), withIntermediateDirectories: true)
        // `.index/` is already there — `create(at:)` had to make it before this
        // method could have a lockfile to take.

        try copyEmbeddedSchemaSpec(into: url)

        let manifest = Manifest(
            archiveUID: IdentifierMinter.archive(),
            name: name,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            files: []
        )
        try AtomicIO.writeJSON(manifest, to: manifestURL)

        // A fresh `index.sqlite` with the current schema and zero rows — already
        // consistent with the empty archive just created, so no walk is needed.
        let index = try ArchiveIndex.open(at: ArchiveLayout.indexDatabaseURL(in: url))

        return Archive(rootURL: url, manifest: manifest, index: index, fileLock: fileLock)
    }

    private static func copyEmbeddedSchemaSpec(into root: URL) throws {
        guard
            let resourceURL = Bundle.module.url(
                forResource: ArchiveLayout.schemaSpecFileName.replacingOccurrences(
                    of: ".md", with: ""),
                withExtension: "md")
        else {
            // Should not happen — the resource is declared in Package.swift —
            // but a missing bundled spec must not prevent archive creation.
            return
        }
        let data = try Data(contentsOf: resourceURL)
        let destination = ArchiveLayout.schemaDirectory(in: root)
            .appendingPathComponent(ArchiveLayout.schemaSpecFileName)
        try AtomicIO.write(data, to: destination)
    }

    // MARK: - Open

    /// Opens an existing archive at `url`.
    ///
    /// Reads `manifest.json`, checks its format version against this build's
    /// (see `Migration` — an older archive is **not** upgraded here, and a newer
    /// one is refused), and opens the persistent `.index/index.sqlite` lookup
    /// index (ARCHITECTURE.md §5.1; see `ArchiveIndex`).
    ///
    /// **A refused open leaves everything outside `.index/` untouched** (slice
    /// 64). The version check runs before the rebuild and before the merge, so
    /// the archive's authoritative files are never written by a build that may
    /// not understand them; what a refused open may leave in `.index/` — the
    /// directory, the lockfile — is machine-local and non-authoritative, and is
    /// never seen by the build that does own the archive.
    ///
    /// **Open vs. rebuild policy (judgment call, flagged for review):** if
    /// `.index/index.sqlite` exists, opens, AND its `PRAGMA user_version`
    /// matches `ArchiveIndex.schemaVersion`, it is used **as-is** — no walk, no
    /// rebuild, even on every `open()` (the whole point of persisting it). If
    /// it's missing, the file can't be opened as a SQLite database (corrupt /
    /// truncated by an interrupted write), or its schema version is stale, the
    /// index is rebuilt from scratch via `ArchiveIndex.rebuild(walking:)` — the
    /// same full walk the old in-memory `ArchiveIndex.build(walking:)` did,
    /// just persisted afterward. This makes "stale/corrupt index" self-healing
    /// on the next `open()` without any explicit user action, at the cost of
    /// one full walk for that one open — judged acceptable since a
    /// version-mismatch only happens across a GeneaLogic upgrade, and a corrupt
    /// `.index/` should be rare (it's not on the `AtomicIO` write-then-rename
    /// path the rest of the format uses, since it's mutated in-place via SQL).
    ///
    /// **Opening takes the cross-process lock (slice 47)** for migration and the
    /// index decision below, both of which write. Without it, two processes
    /// opening the same archive at once could migrate or rebuild concurrently.
    ///
    /// **Since slice 50 an open can also rewrite `manifest.json`**, which is new:
    /// adopting a manifest from another machine now merges it against what this
    /// machine's own writes superseded, and a merge that changes something is
    /// written back. It is not a new *access* requirement — open already creates
    /// `.index/`, takes the lock, and may rebuild — but it is the first time a
    /// plain open touches the archive's authoritative document, and it is worth
    /// knowing when reading a `manifest.json` mtime after one.
    ///
    /// - Throws: `ArchiveError.notAnArchive` if `url` has no `manifest.json`;
    ///   `ArchiveError.corruptManifest` if it cannot be decoded;
    ///   `ArchiveError.archiveNewerThanBuild` if the manifest — or, on a
    ///   rebuild, any record — carries a newer format version than this build;
    ///   `ArchiveError.needsUpgrade` if the manifest carries an older one;
    ///   `ArchiveError.archiveBusy` if another process is mid-mutation and stays
    ///   that way; filesystem errors otherwise.
    public static func open(at url: URL) throws -> Archive {
        let fm = FileManager.default
        let manifestURL = ArchiveLayout.manifestURL(in: url)
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw ArchiveError.notAnArchive(url)
        }

        try fm.createDirectory(
            at: ArchiveLayout.indexDirectory(in: url), withIntermediateDirectories: true)
        let fileLock = try ArchiveLock(at: ArchiveLayout.lockURL(in: url), archiveRoot: url)

        let (archive, walked) = try fileLock.withLock {
            // Stamped **before** the read, and before the rebuild that may follow:
            // a manifest delivered while we are walking must make the next stat
            // differ, not be silently adopted as the one we digested.
            let manifestStamp = ManifestWitness.stamp(of: manifestURL)
            var manifest = try readManifest(at: manifestURL)

            // The door (slice 64). Before anything that writes — the rebuild and
            // the merge both do — so a refusal here has touched nothing.
            try Migration.check(manifest: manifest, archiveAt: url)

            // Read before `openOrRebuildIndex`, which rebuilds when the marker
            // is set — see `interruptedWriteOnOpen`.
            let interrupted = IndexDirtyMarker.isSet(in: url)
            let (index, rebuilt) = try openOrRebuildIndex(
                at: url,
                manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                manifestVersion: manifest.schemaVersion)
            let adopted = try adoptManifestWitness(
                index, at: url, manifest: manifest, stampedBefore: manifestStamp,
                alreadyRebuilt: rebuilt)
            manifest = adopted.manifest
            let archive = Archive(
                rootURL: url, manifest: manifest, index: index, fileLock: fileLock,
                interruptedWriteOnOpen: interrupted || InterruptedWriteMarker.isSet(in: url),
                interruptedWriteExemptions: InterruptedWriteMarker.exemptions(in: url))
            // The recovery a crash needs, once (slice 65): put torn trash
            // operations on the side their sidecars name, then decide whether
            // the manifest is behind and write that verdict down.
            if interrupted { archive.recoverFromInterruptedWrite() }
            return (archive, adopted.walked)
        }

        // **A version an earlier merge ruled against may have landed** (slice
        // 50e). Through the reconcile the poll uses — one path, so the two cannot
        // drift — and only after 65's recovery, which must judge the manifest a
        // crash left rather than one this rewrote. Outside the lock, because that
        // reconcile takes it. Opportunistic: a failure leaves the note for the next
        // open or poll, never fails the open.
        if archive.contestedVersionLanded() {
            _ = try? archive.reconcile(indexJustWalked: walked)
        }
        return archive
    }

    /// Implements the open-vs-rebuild policy documented on `open(at:)`.
    ///
    /// **Why the file-existence check (judgment call, flagged for review):**
    /// `sqlite3_open` happily *creates* a fresh, empty, well-formed database at
    /// `dbURL` if nothing is there yet — `ArchiveIndex.open` would then report
    /// `userVersion() == ArchiveIndex.schemaVersion` (an empty index sets its
    /// own version on creation, so an empty *existing* archive's index is
    /// trivially "current"), which would make a MISSING `.index/index.sqlite`
    /// indistinguishable from a freshly-created EMPTY one — exactly the "open
    /// vs. rebuild" distinction this method exists to make. So: check
    /// `fileExists` first; only attempt the "open as-is" path if a file was
    /// actually there before `sqlite3_open` could have created one.
    /// **Slice 47 added a fourth rebuild trigger:** a leftover `.index/dirty`
    /// sentinel, meaning some earlier mutation started and never finished — a
    /// crash between the sidecar write and the index write, or an index write
    /// that failed outright. That is *content* drift, which none of the other
    /// three triggers can see (the file is present, opens fine, and is
    /// schema-current). Caller holds the archive lock.
    ///
    /// **Why the dirty case must NOT delete the file (review finding, 47).** The
    /// three original triggers are all "this file is unusable", so deleting and
    /// recreating it was free. A dirty sentinel is the opposite: the file is
    /// perfectly good and only its *contents* are behind. Unlinking it there is
    /// actively harmful, because another process may hold a live connection to
    /// that inode — its handle would stop seeing new records and its next
    /// mutation would fail with `attempt to write a readonly database`, *after*
    /// having already written the sidecar, and stay broken until relaunch. The
    /// archive lock does not protect against this: a handle holds it only for the
    /// duration of a mutation, not for its lifetime. So the dirty case rebuilds
    /// **in place** — which `ArchiveIndex.rebuild` already does, inside
    /// `BEGIN IMMEDIATE`, and which every open connection sees as an ordinary
    /// commit.
    ///
    /// **Recreating was never free, either (slice 69, fork a).** The file holds
    /// 58's preserved copies — sometimes a record's last — and the unlink took
    /// them all: on every schema bump, every corrupt index, and every
    /// `quick_check` that merely failed to run. The old file is now moved aside
    /// and its copies carried into the new one, and it is deleted only once they
    /// have been; a file that cannot be read in full is kept beside the index.
    private static func openOrRebuildIndex(
        at url: URL, manifestRecordPaths: Set<String>, manifestVersion: String
    ) throws
        -> (ArchiveIndex, rebuilt: Bool)
    {
        let dbURL = ArchiveLayout.indexDatabaseURL(in: url)
        // What a mutation that died had unlinked (slice 69, fork c) — empty when
        // no write was interrupted, and then nothing is discarded.
        let unlinked =
            IndexDirtyMarker.isSet(in: url) ? IndexDirtyMarker.journaledRemovals(in: url) : []

        // `open` and `user_version` read only the header, so a file with a valid
        // header and corrupt pages passed both and then failed the archive's open
        // from inside the in-place rebuild (slice 63, fork f). `quick_check` reads
        // every page, and a failure joins the *unusable* triggers below — not the
        // dirty case, which rebuilds in place because the file is good. A probe
        // that could not run is no evidence (slice 69, fork b): it is retried,
        // and a file another connection holds fails the open having touched
        // nothing — see `ArchiveIndex.openExisting`.
        if FileManager.default.fileExists(atPath: dbURL.path) {
            if let index = try ArchiveIndex.openExisting(at: dbURL) {
                // Healthy and schema-current. Use as-is unless a mutation was
                // interrupted, or an earlier open moved a file aside and never
                // carried it — then re-derive its contents in place.
                let carried = carryReplacedIndexes(into: index, at: url)
                guard IndexDirtyMarker.isSet(in: url) || carried else {
                    return (index, rebuilt: false)
                }
                try index.rebuild(
                    walking: url, manifestRecordPaths: manifestRecordPaths,
                    manifestVersion: manifestVersion, unlinkedByDiedWrite: unlinked)
                // The marker is not cleared here: `recoverFromInterruptedWrite()`
                // clears it once it has recorded whether a write was left
                // unresolved (slice 65).
                return (index, rebuilt: true)
            }
            try moveIndexAside(dbURL)
        }

        // Missing, corrupt, or another schema's — the only cases that genuinely
        // need a *new file* (a stale schema can't be reshaped by `CREATE TABLE IF
        // NOT EXISTS`, and a corrupt one can't be rebuilt in place). Rebuild from
        // the sidecars + conclusions, which are authoritative, so this always
        // converges on them — carrying the old file's preserved copies across
        // first (slice 69, fork a), which until then went with its unlink.
        let index = try ArchiveIndex.open(at: dbURL)
        carryReplacedIndexes(into: index, at: url)
        try index.rebuild(
            walking: url, manifestRecordPaths: manifestRecordPaths,
            manifestVersion: manifestVersion, unlinkedByDiedWrite: unlinked)
        return (index, rebuilt: true)
    }

    /// Renames the index at `dbURL` out of the way, to a **pending** name —
    /// `index-replaced-<when>.sqlite` beside it (slice 69, fork a).
    ///
    /// **Pending until carried, by name, not by this open** (`/code-review`). The
    /// carry runs in `carryReplacedIndexes`, which every open calls, so a process
    /// that dies — or an open that throws — between this move and the carry
    /// leaves a file the next open finds and carries, rather than one nothing
    /// reads again.
    ///
    /// **With its journal**: a hot `-journal` left at the old name would be rolled
    /// back into the *new* database by SQLite on its first read, and the moved
    /// file needs it to read as it last committed. If a sidecar cannot follow,
    /// everything moved goes back and the open fails, so the two are never
    /// parted.
    private static func moveIndexAside(_ dbURL: URL) throws {
        let fm = FileManager.default
        let aside = ArchiveLayout.keptFileURL(
            in: dbURL.deletingLastPathComponent(), stem: replacedIndexStem, extension: "sqlite")
        try fm.moveItem(at: dbURL, to: aside)
        var moved: [(from: URL, to: URL)] = [(dbURL, aside)]
        do {
            for suffix in sqliteSidecarSuffixes {
                let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
                guard fm.fileExists(atPath: sidecar.path) else { continue }
                let destination = URL(fileURLWithPath: aside.path + suffix)
                try fm.moveItem(at: sidecar, to: destination)
                moved.append((sidecar, destination))
            }
        } catch {
            for move in moved.reversed() { try? fm.moveItem(at: move.to, to: move.from) }
            throw error
        }
    }

    /// Carries every pending replaced index beside this one into `index` — see
    /// `ArchiveIndex.carryPreservedCopies(from:)` — and returns whether there was
    /// any, in which case the caller must rebuild so the carried rows are pruned
    /// against what is live.
    ///
    /// A file carried in full is deleted. One that cannot be is renamed
    /// `index-unreadable-…` and **kept, never deleted by the engine, and not
    /// retried**: a file that failed once fails again, and retrying would make
    /// every open of the archive a rebuild.
    @discardableResult
    private static func carryReplacedIndexes(into index: ArchiveIndex, at root: URL) -> Bool {
        let fm = FileManager.default
        let directory = ArchiveLayout.indexDirectory(in: root)
        let pending = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(replacedIndexStem + "-") && $0.hasSuffix(".sqlite") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
        for file in pending {
            if index.carryPreservedCopies(from: file) {
                for suffix in [""] + sqliteSidecarSuffixes {
                    try? fm.removeItem(at: URL(fileURLWithPath: file.path + suffix))
                }
                continue
            }
            let kept = ArchiveLayout.keptFileURL(
                in: directory, stem: unreadableIndexStem, extension: "sqlite")
            for suffix in [""] + sqliteSidecarSuffixes {
                try? fm.moveItem(
                    at: URL(fileURLWithPath: file.path + suffix),
                    to: URL(fileURLWithPath: kept.path + suffix))
            }
        }
        return !pending.isEmpty
    }

    /// A replaced index awaiting its carry, and one kept because it could not be.
    private static let replacedIndexStem = "index-replaced"
    private static let unreadableIndexStem = "index-unreadable"

    /// The files SQLite keeps beside a database under its name.
    private static let sqliteSidecarSuffixes = ["-journal", "-wal", "-shm"]

    /// **The fifth rebuild trigger (slice 60):** the index was built from a
    /// manifest that is no longer the one on disk.
    ///
    /// The other four — missing, unopenable, schema-stale, and 47's dirty
    /// sentinel — all answer *is this database usable?* This one answers *does it
    /// reflect the files?*, which is the question a hand edit, a `git merge` or a
    /// sync delivery from another machine actually poses. Called under the
    /// archive lock, on the open path only; `reconcileIfStale()` is the same
    /// decision for a handle that is already open.
    ///
    /// `alreadyRebuilt` short-circuits the comparison rather than the recording:
    /// a rebuild that just walked the disk *is* current by construction, and
    /// still needs its witness written down.
    ///
    /// **Returns the manifest the index was actually made current against**,
    /// which since slice 50 is not always the one on disk when this was called:
    /// adopting merges the arriving manifest with the entries the index last
    /// settled, and a merge that changes something is written back. The caller
    /// must use the returned value — an `Archive` holding the pre-merge manifest
    /// would serve a `files` list its own `manifest.json` no longer agrees with.
    ///
    /// Also says whether the index was walked, here or by the caller's rebuild —
    /// so a reconcile straight after the open need not walk it again (50e).
    private static func adoptManifestWitness(
        _ index: ArchiveIndex, at url: URL, manifest deliveredManifest: Manifest,
        stampedBefore manifestStamp: ManifestWitness.Stamp?, alreadyRebuilt: Bool
    ) throws -> (manifest: Manifest, walked: Bool) {
        var manifest = deliveredManifest
        var walked = alreadyRebuilt
        let current = ManifestWitness.of(manifest, stampedBefore: manifestStamp)

        if !alreadyRebuilt {
            // An index with no witness reads as *unknown*, therefore stale: an
            // archive written before this slice rebuilds once, on its first open
            // after the upgrade, and is current from then on.
            if let recorded = try? index.manifestWitness(),
                recorded.describesSameFiles(as: current)
            {
                // Same files. The stamp may still have moved (a manifest
                // rewritten with identical contents), so re-record to keep the
                // cheap gate useful; nothing is rebuilt. It is also where an
                // index written before slice 60c is backfilled with the settled
                // entries it has no rows for: the digest is unchanged, so this
                // costs one rewrite on one open and nothing after it.
                //
                // **Unless the manifest's version is behind the archive's** (slice
                // 64, fork g): a straggler manifest naming the same files still
                // needs its stamp put right, and the merge below is what writes
                // it — so that case falls through, without a rebuild.
                if manifest.schemaVersion == SchemaVersion.current {
                    try? index.setManifestWitness(current, files: manifest.files)
                    return (manifest, false)
                }
            } else {
                try index.rebuild(
                    walking: url,
                    manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                    manifestVersion: manifest.schemaVersion)
                walked = true
            }
        }

        let stamp = try mergeDeliveredManifest(
            &manifest, index: index, at: url, stampedBefore: manifestStamp)
        try recordWitness(
            ManifestWitness.of(manifest, stampedBefore: stamp),
            on: index, at: url, manifest: manifest)
        return (manifest, walked)
    }

    /// **Reconciles a manifest somebody else wrote with the entries this index
    /// last settled, and writes the result back if it differs** (slice 50).
    ///
    /// The two adoption paths — `open()`'s and `reconcileIfStale()`'s — share it,
    /// because they face the identical situation: a `manifest.json` that came
    /// from elsewhere, which slice 60 taught the engine to adopt wholesale. Doing
    /// that loses whatever the sending machine had not yet heard about, and the
    /// loss is not cosmetic; see `ManifestMerge` for the wedge it produces.
    ///
    /// It is **inert whenever the manifest and the settled entries agree**, which
    /// is every case but a genuine divergence: `ManifestMerge.merge` returns
    /// `nil`, nothing is written, and the caller keeps the stamp it already had.
    ///
    /// - Parameter fallback: the stamp the caller already holds for the manifest
    ///   as it arrived, returned unchanged when nothing is merged. A stamp is
    ///   only ever re-taken by a write, per `writeManifest`'s ordering rule.
    private static func mergeDeliveredManifest(
        _ manifest: inout Manifest, index: ArchiveIndex, at url: URL,
        stampedBefore fallback: ManifestWitness.Stamp?
    ) throws -> ManifestWitness.Stamp? {
        let delivered = manifest.files
        // Whether this is a manifest from elsewhere or the one this machine last
        // wrote, read back — only the first can prove a sender caught up (50e).
        let fromElsewhere =
            (try? index.lastWrittenManifestDigest()) != ManifestWitness.digest(of: manifest)
        let settled = (try? index.settledFiles()) ?? [:]
        let superseded = (try? index.supersededFiles()) ?? [:]
        let deleted = (try? index.deletedPaths()) ?? []
        // Snapshotted before the merge rewrites `manifest.files`: the prune asks
        // what the sender said, not what we concluded.
        defer {
            pruneSupersededFiles(superseded, against: delivered, settled: settled, on: index)
            pruneDeletedPaths(deleted, at: url, on: index)
        }
        let merged = ManifestMerge.merge(
            delivered: delivered, settled: settled, superseded: superseded,
            deleted: deleted, root: url)
        // **What the merge overruled is provisional** (slice 50e): kept, so the
        // decision can be revisited if the version it ruled against lands.
        if let merged { noteContests(delivered: delivered, merged: merged, on: index) }
        defer {
            pruneStaleContests(
                against: manifest.files, caughtUpWith: fromElsewhere ? delivered : nil,
                on: index)
        }
        // **The merged manifest carries the newer version, never a straggler's**
        // (slice 64, fork g). A manifest written on a machine that had not yet
        // upgraded can land on one that has; adopting its stamp would put the
        // archive back to the older version on paper while its records are at
        // the newer one, and the next open here would demand an upgrade that
        // already happened. A *newer* stamp cannot reach this point — `open` and
        // `withState` both refuse it first — so in practice this is "ours".
        let version = ManifestMerge.schemaVersion(
            delivered: manifest.schemaVersion, ours: SchemaVersion.current)
        guard merged != nil || version != manifest.schemaVersion else { return fallback }
        if let merged { manifest.files = merged }
        manifest.schemaVersion = version
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
        return try writeManifest(manifest, at: url, noting: index)
    }

    /// Drops the evidence for paths the sender has **caught up on** — proved by
    /// its manifest naming the very entry we hold (slice 50).
    ///
    /// Without this the record of what our writes superseded only ever grows, and
    /// it keeps claiming a local edit is unheard-of long after the other machine
    /// has taken it. Runs on `delivered`, the manifest as it arrived, and so is
    /// computed before the merge rewrites it.
    ///
    /// **Every predecessor for that path goes at once**, not just the one that
    /// matches: a sender holding our current entry is behind on none of them.
    private static func pruneSupersededFiles(
        _ superseded: [String: [ManifestEntry]], against delivered: [ManifestEntry],
        settled: [String: ManifestEntry], on index: ArchiveIndex
    ) {
        guard !superseded.isEmpty else { return }
        let caughtUp = delivered.filter { superseded[$0.path] != nil && settled[$0.path] == $0 }
        try? index.forgetSuperseded(paths: caughtUp.map(\.path))
    }

    /// Drops the deletion note for any path that is **back on disk**
    /// (`/code-review`, slice 50b).
    ///
    /// The local write path forgets a note when *this machine* authors the path
    /// again, which misses the way a deleted record most often returns: the merge
    /// keeping theirs, because a delete loses to an edit. The note would then
    /// outlive the deletion for ever and arm the drop rule if that file were
    /// later lost. **A note only means anything while the path is absent**, so
    /// that is the whole test — one `lstat` per noted path, on the reconcile path
    /// only, and the set is small because it holds deletions rather than
    /// versions.
    private static func pruneDeletedPaths(
        _ deleted: Set<String>, at url: URL, on index: ArchiveIndex
    ) {
        guard !deleted.isEmpty else { return }
        let back = deleted.filter { !ManifestMerge.nothingIsThere(at: $0, root: url) }
        try? index.forgetDeleted(paths: Array(back))
    }

    /// Notes each delivered entry the merge overruled — kept ours in its place, or
    /// dropped it (slice 50e). An entry the merge's second pass put back is not one.
    private static func noteContests(
        delivered: [ManifestEntry], merged: [ManifestEntry], on index: ArchiveIndex
    ) {
        let kept = Dictionary(merged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let overruled = delivered.filter { kept[$0.path] != $0 }.map {
            ContestedEntry(theirs: $0, ours: kept[$0.path])
        }
        try? index.noteContested(overruled)
    }

    /// The contests in `notes` whose note still describes `files`: the manifest
    /// holds exactly the entry the merge kept, or still names nothing where it
    /// dropped one.
    private static func standingContests(
        _ notes: [String: ContestedEntry], against files: [ManifestEntry]
    ) -> [ContestedEntry] {
        guard !notes.isEmpty else { return [] }
        let entries = Dictionary(
            files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return notes.values.filter { entries[$0.theirs.path] == $0.ours }
    }

    /// **Drops a contest the moment the manifest stops holding what the merge kept**
    /// (slice 50e, fork c) — a later local write to the path, or another delivery
    /// that moved its entry. A note left standing past our own next edit would let
    /// their version landing afterwards replace that edit silently: the provider
    /// keeping one side of a real conflict, which must stay reported.
    ///
    /// **And when the sender has caught up** — its manifest names the entry we
    /// kept, so the version the merge ruled against is behind it. That is 50's own
    /// proof, with one guard it did not need: `caughtUpWith` is passed only for a
    /// manifest **from elsewhere**. While any delivery is in flight, every open
    /// re-merges the manifest *this machine* wrote, which names ours by
    /// construction, and taking that as the proof dropped the note before the
    /// record it waited for could land (found by the `deliver.sh revert`
    /// hand-test). A note left standing would otherwise let an out-of-band restore
    /// of the old bytes, long after, be adopted where 49 says it must be reported
    /// (`/code-review`).
    static func pruneStaleContests(
        against files: [ManifestEntry], caughtUpWith delivered: [ManifestEntry]? = nil,
        on index: ArchiveIndex
    ) {
        guard let notes = try? index.contestedEntries(), !notes.isEmpty else { return }
        let standing = Set(standingContests(notes, against: files).map(\.theirs.path))
        let sent = delivered.map {
            Dictionary($0.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        try? index.forgetContested(
            paths: notes.filter { path, note in
                !standing.contains(path) || sent.map { $0[path] == note.ours } == true
            }.map(\.key))
    }

    /// The standing contests whose overruled version is on disk, which `holds`
    /// answers per entry (slice 50e).
    ///
    /// **Only a record triggers it** (`/code-review`). A record is small and ours
    /// to hash, so "their version is here" is exact; a payload file may be a
    /// dataless placeholder, answerable by size alone, and a same-length payload of
    /// ours would have read as theirs and reversed 50's decision on the spot. A
    /// payload contest travels with its artifact's record instead: the record is
    /// the arbiter, and it names the payload it claims.
    private static func landedContests(
        _ notes: [String: ContestedEntry], against files: [ManifestEntry],
        holds: (ManifestEntry) -> Bool
    ) -> [ContestedEntry] {
        let standing = standingContests(notes, against: files)
        let records = standing.filter {
            ArchiveLayout.isEngineAuthored(relativePath: $0.theirs.path) && holds($0.theirs)
        }
        let folders = records.compactMap { contest -> String? in
            let path = contest.theirs.path
            guard path.hasPrefix("\(ArchiveLayout.artifactsDirectoryName)/"),
                path.hasSuffix("/\(ArchiveLayout.recordFileName)")
            else { return nil }
            return String(path.dropLast(ArchiveLayout.recordFileName.count))
        }
        let payloads = standing.filter { contest in
            !ArchiveLayout.isEngineAuthored(relativePath: contest.theirs.path)
                && folders.contains { contest.theirs.path.hasPrefix($0) }
        }
        return records + payloads
    }

    /// **Reverses a merge's decision once the version it ruled against is on
    /// disk** (slice 50e). The merge kept ours on the reading that the sender had
    /// never heard of our write; their record landing with exactly the bytes their
    /// manifest named proves otherwise — they heard, and wrote that version again
    /// (an undo, a restore from the trash).
    ///
    /// Their entry goes into `manifest` verbatim and the file is rewritten. That is
    /// **an entry they authored**, never one minted from disk, so 49's laundering
    /// rule holds here exactly as it does in the merge. The evidence the merge used
    /// goes with it — the superseded versions, the deletion note — because the
    /// sender has demonstrably moved past our write. The caller re-walks the index.
    ///
    /// - Returns: whether anything was adopted, and the stamp of the manifest
    ///   written (per `writeManifest`).
    static func adoptLandedContests(
        _ manifest: inout Manifest, index: ArchiveIndex, at url: URL
    ) throws -> (adopted: Bool, stamp: ManifestWitness.Stamp?) {
        let notes = try index.contestedEntries()
        let landed = landedContests(notes, against: manifest.files) {
            ManifestMerge.diskHolds($0, root: url)
        }
        guard !landed.isEmpty else { return (false, nil) }
        let paths = Set(landed.map(\.theirs.path))
        manifest.files.removeAll { paths.contains($0.path) }
        manifest.files.append(contentsOf: landed.map(\.theirs))
        manifest.files.sort { $0.path < $1.path }
        manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
        let stamp = try writeManifest(manifest, at: url, noting: index)
        try index.forgetContested(paths: Array(paths))
        try index.forgetSuperseded(paths: Array(paths))
        try index.forgetDeleted(paths: Array(paths))
        return (true, stamp)
    }

    /// The cheap half of the revisit, for the reconcile gate (`/code-review`):
    /// one indexed read, empty on an archive no merge has overruled; then a `stat`
    /// per standing record note, hashed only when the size already matches theirs
    /// and cached against size and mtime, so a poll does not re-hash a file that
    /// has not changed. Only when one of them hits is the manifest read, to ask
    /// whether the note still stands. Skipped while a failed adoption backs off.
    func contestedVersionLanded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let retryAfter = contestRetryAfter, ContinuousClock.now < retryAfter { return false }
        guard let notes = try? index.contestedEntries(), !notes.isEmpty else { return false }
        let holds = { (entry: ManifestEntry) in self.probeContestLocked(entry) }
        let candidates = notes.filter {
            ArchiveLayout.isEngineAuthored(relativePath: $0.key) && holds($0.value.theirs)
        }
        guard !candidates.isEmpty else { return false }
        reloadManifest()
        return !Self.landedContests(candidates, against: manifest.files, holds: holds).isEmpty
    }

    /// Whether the record at `entry.path` is `entry`, remembered against the file's
    /// size and mtime. Caller holds `lock`.
    private func probeContestLocked(_ entry: ManifestEntry) -> Bool {
        let url = rootURL.appendingPathComponent(entry.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value, size == entry.byteLength
        else { return false }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if let probe = contestProbes[entry.path], probe.size == size, probe.modified == modified,
            probe.sha256 == entry.sha256
        {
            return probe.holds
        }
        let holds = ManifestMerge.diskHolds(entry, root: rootURL)
        contestProbes[entry.path] = (size, modified, entry.sha256, holds)
        return holds
    }

    /// Writes `manifest.json` and returns a stamp that may be recorded for it —
    /// `nil` when the file changed underneath the write.
    ///
    /// **Stamping after our own write is the one case where "stamp first" does
    /// not apply — but only if the file is still ours** (`/code-review`, slice
    /// 60). The archive lock excludes other GeneaLogic processes and not a sync
    /// daemon, so a manifest overwritten between the rename and this `stat` would
    /// be stamped while the digest describes what *we* wrote, pinning the cheap
    /// gate to "unchanged" for ever — the same failure the open path was fixed
    /// for.
    ///
    /// The size we just wrote is the check. It is cheap and it fails safe: a
    /// stamp we cannot vouch for is dropped, and a witness with no stamp makes
    /// the gate decline to skip rather than skip wrongly.
    ///
    /// **Residue, stated rather than implied:** an overwrite that lands in that
    /// window *and* is byte-length-identical still passes. Closing it needs the
    /// manifest re-read and re-digested after writing, which is a cost every
    /// mutation would pay for a window this narrow.
    @discardableResult
    ///
    /// `noting` records the digest of what was written, so a later merge can tell
    /// this machine's own manifest, read back, from one that arrived (slice 50e).
    static func writeManifest(
        _ manifest: Manifest, at url: URL, noting index: ArchiveIndex? = nil
    ) throws -> ManifestWitness.Stamp? {
        let manifestURL = ArchiveLayout.manifestURL(in: url)
        let written = try AtomicIO.writeJSON(manifest, to: manifestURL)
        try? index?.setLastWrittenManifestDigest(ManifestWitness.digest(of: manifest))
        let after = ManifestWitness.stamp(of: manifestURL)
        return after?.size == Int64(written.count) ? after : nil
    }

    /// Writes the witness down — unless the files it describes do not all appear
    /// to be there yet, in which case it writes nothing and leaves the index
    /// witnessless so the next check runs again (slice 60, fork e).
    static func recordWitness(
        _ witness: ManifestWitness, on index: ArchiveIndex, at url: URL, manifest: Manifest
    ) throws {
        let settled = ((try? index.settledFiles()) ?? [:])
        if manifestDeliveryLooksComplete(root: url, manifest: manifest, settled: settled) {
            // **The entries go down with the witness, in the same call** (slice
            // 60c): the witness says a delivery is in flight and these say which
            // files it covers, and an engine holding one without the other would
            // answer the per-entry question from a manifest it no longer has.
            try index.setManifestWitness(witness, files: manifest.files)
            return
        }
        // **Incomplete: leave the witness we already had, rather than clearing
        // it.** Both give fork (e) what it needs — the recorded witness still
        // disagrees with the disk, so the next check re-fires — but only this one
        // keeps the fact that distinguishes *arriving* from *damaged*.
        //
        // Clearing made those indistinguishable, and the hand-test's own archive
        // proved it: `manifestDeliveryLooksComplete` was false for **any**
        // mismatch, which is exactly what `verifyIntegrity()` reports, so a
        // corrupt payload file cleared the witness and then read as a delivery in
        // flight. (60c narrowed that check to the delivery's own entries, which
        // is what stops a damaged archive being unable to settle at all — but
        // keeping the last witness is still what makes *arriving* and *damaged*
        // distinguishable in the first place.) Keeping the last settled witness breaks the circle, because
        // **corruption does not change `manifest.json`**: a rotted file leaves the
        // settled witness still describing the manifest on disk, so it is damage;
        // a manifest that no longer matches the settled one can only have come
        // from somewhere else, so it is an arrival. See `deliveryIsInFlight`.
        //
        // **There is no longer an exception for having no witness at all**
        // (slice 60b). Slice 60 recorded one unconditionally in that case, so
        // that a fault in a pre-60 archive still reported as the damage it is —
        // but "no previous state to differ from" is not "this state is
        // complete", and on a first open with no `.index/` part-way through a
        // delivery the two come apart: the witness certified files nobody had
        // seen, `manifest.json` never moved again, nothing re-fired, and
        // `verifyIntegrity()` called the archive healthy while a delivered
        // record stayed invisible to every query. Writing nothing here leaves
        // the state `.unknown`, which `indexLooksStale()` already treats as
        // stale, so the next open resolves it on its own.
        //
        // What the exception was protecting is now `WitnessState`'s job instead:
        // `.unknown` reads as damage everywhere a false arrival would mislead
        // (see `deliveryIsInFlight`), which is the same outcome by an honest
        // route. The cost is fork (e)'s, accepted with its measurement: a
        // genuinely damaged archive whose files are the *wrong size* re-walks on
        // every open rather than once. Rot that preserves length still settles
        // here, since this check is `st_size`.
    }

    static func readManifest(at url: URL) throws -> Manifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ArchiveError.corruptManifest(
                url, underlying: DecodingFailure.summary(of: error))
        }
        do {
            return try GeneaLogicJSONCoding.decoder.decode(Manifest.self, from: data)
        } catch {
            throw ArchiveError.corruptManifest(
                url, underlying: DecodingFailure.summary(of: error))
        }
    }

    // MARK: - External change detection

    /// An opaque token that changes when **another process** commits to this
    /// archive, and never when this one does (slice 51).
    ///
    /// It exists so a long-lived handle — the Mac app holding a window open —
    /// can tell that an agent driving `genea` has written something, and reload
    /// its lists. Slice 47 made the two processes *safe*; this is what makes the
    /// second one *visible*. Comparing tokens is the whole protocol: any change
    /// means "re-read whatever you cached", never what changed.
    ///
    /// **What it does not see:** a `record.json` edited by hand or delivered by
    /// cloud sync, which no process committed through this engine and so bumps
    /// nothing. That is ARCHITECTURE.md §10.4's still-open gap.
    ///
    /// `nil` means the token could not be read at all (a broken index), which a
    /// caller should treat as "no information", not as "nothing changed".
    public func externalChangeToken() -> Int? {
        withIndex { try? $0.dataVersion() }.map(Int.init)
    }

    /// Rebuilds the index if the archive's files are no longer the ones it was
    /// built from, and reports whether it did (slice 60).
    ///
    /// **This is the out-of-band case `externalChangeToken()` structurally
    /// cannot see.** That token is `PRAGMA data_version`, which moves when
    /// another *process* commits through this engine — so it catches an agent
    /// driving `genea`, and never catches a `record.json` edited in a text
    /// editor, restored from a backup, merged by `git`, or delivered by cloud
    /// sync from another machine. Those change the files without any engine
    /// committing anything, which is ARCHITECTURE.md §10.4's gap.
    ///
    /// **It adopts a change that arrives with its manifest, and only that.** A
    /// bare hand edit of one `record.json` moves no manifest and is deliberately
    /// left to `verifyIntegrity()` and `rebaseline()` — see `ManifestWitness`. A caller that
    /// polls for external change wants both, and this one is the more expensive,
    /// so call it second.
    ///
    /// **Cheap when nothing changed, which is nearly always** (fork c): one
    /// `stat(2)` of `manifest.json` and an integer compare. Only when that moves
    /// does it read and digest the manifest, and only when the digest differs
    /// does it rebuild.
    ///
    /// **Not cheap when something did**: a rebuild walks every sidecar and
    /// conclusion. Callers on an actor whose responsiveness matters should call
    /// this off it — the app does, for the same reason slice 52 moved mutations
    /// off the main actor.
    ///
    /// - Returns: `true` if the index was rebuilt, meaning anything cached from
    ///   it should be re-read.
    @discardableResult
    public func reconcileIfStale() throws -> Bool {
        guard indexLooksStale() || contestedVersionLanded() else { return false }
        return try reconcile(indexJustWalked: false)
    }

    /// The body `reconcileIfStale()` and `open(at:)` share (slice 50e: one path,
    /// so the two cannot drift). `indexJustWalked` is the open's: it rebuilt a
    /// moment ago, so the index already reflects the disk, landed bytes included,
    /// and a second walk would be pure cost.
    func reconcile(indexJustWalked: Bool) throws -> Bool {
        let rebuilt: Bool
        do {
            rebuilt = try withState { manifest, index in
                // A version an earlier merge ruled against has landed (slice 50e):
                // their entry goes into the manifest, which is written here because
                // the adopting commit below never writes what it did not merge.
                let landed = try Self.adoptLandedContests(&manifest, index: index, at: rootURL)
                // Re-checked under the lock, against the manifest `withState` has
                // just re-read: between the gate above and here, another thread of
                // ours — or another process — may have rebuilt already, and a second
                // full walk would be pure cost. `indexWasCurrentAtStart` is that same
                // comparison, already made by `withState`.
                guard !indexWasCurrentAtStart || landed.adopted else { return false }
                if !indexJustWalked {
                    try index.rebuild(
                        walking: rootURL,
                        manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                        manifestVersion: manifest.schemaVersion)
                }
                // Consumed by this mutation's closing `commitManifest`, which for
                // this one call adopts the manifest instead of recomputing it.
                adoptingDeliveredManifest = true
                return true
            }
        } catch {
            // **A rebuild that throws is an unsettled reconcile too**
            // (`/code-review`, 64). Since that slice the walk can refuse — a
            // record ahead of the build — and a refusal that skipped this left
            // `indexLooksStale()` true with no back-off armed, so the app's
            // one-second poll, which `try?`s this call, walked every sidecar
            // under the archive lock on every tick until the manifest landed:
            // the storm the back-off exists to stop. The witness is unchanged
            // and the manifest is not, so this arms it keyed on that manifest.
            noteReconcileOutcome()
            // The same for an adoption (50e, `/code-review`): its gate is not the
            // witness, so it gets a back-off of its own.
            noteContestOutcome(failed: true)
            throw error
        }

        if rebuilt { noteReconcileOutcome() }
        noteContestOutcome(failed: false)
        return rebuilt
    }

    /// Arms or clears the back-off on `contestedVersionLanded()` — doubling from
    /// the reconcile back-off's floor to its cap, like `noteReconcileOutcome()`.
    private func noteContestOutcome(failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard failed else {
            contestRetryAfter = nil
            contestBackoff = backoffBounds.minimum
            return
        }
        contestRetryAfter = ContinuousClock.now + contestBackoff
        contestBackoff = min(contestBackoff * 2, backoffBounds.maximum)
    }

    /// Records whether the rebuild just made actually **settled** — and if not,
    /// how long to leave it before trying again (slice 60, fork e's back-off;
    /// `/code-review` found it specced but unimplemented).
    ///
    /// An unsettled reconcile is one whose delivery did not look whole, so no
    /// witness was recorded. Without a back-off that state makes
    /// `indexLooksStale()` unconditionally true, and the app's one-second poll
    /// then takes the archive lock and walks every sidecar **every tick**, for as
    /// long as one large file is in flight — turning a slow download into a
    /// rebuild storm that also blocks the other process's writes.
    ///
    /// **Keyed on the manifest's stamp, so progress resets it.** If the manifest
    /// changes, the delivery has moved on and is worth looking at immediately;
    /// only repeatedly failing to settle *the same* manifest backs off, doubling
    /// from a second to a cap of half a minute.
    private func noteReconcileOutcome() {
        lock.lock()
        defer { lock.unlock() }
        let stamp = ManifestWitness.stamp(of: ArchiveLayout.manifestURL(in: rootURL))
        // "Settled" now means the recorded witness describes the manifest on
        // disk — not merely that one exists, since an unsettled reconcile leaves
        // the previous witness in place rather than clearing it. `.matches` only:
        // an unsettled rebuild that recorded nothing leaves `.unknown`, which is
        // precisely the state that must keep backing off (slice 60b).
        let settled = witnessStateLocked() == .matches
        guard !settled else {
            unsettledStamp = nil
            reconcileBackoff = backoffBounds.minimum
            return
        }
        if unsettledStamp != stamp {
            unsettledStamp = stamp
            reconcileBackoff = backoffBounds.minimum
        } else {
            reconcileBackoff = min(reconcileBackoff * 2, backoffBounds.maximum)
        }
        nextReconcileAttempt = ContinuousClock.now + reconcileBackoff
    }

    /// The cheap half of `reconcileIfStale()`: does the manifest still look like
    /// the one the index was built from?
    ///
    /// Takes only the process-local lock, per `ArchiveLock`'s reader policy — it
    /// decides whether to *start* a mutation and must not queue behind another
    /// process to do so.
    private func indexLooksStale() -> Bool {
        let manifestURL = ArchiveLayout.manifestURL(in: rootURL)
        guard let recorded = withIndex({ try? $0.manifestWitness() }) else {
            // No witness: an index written before this slice, or one deliberately
            // cleared by an incomplete delivery. Unknown is stale — but if it is
            // the *same* incomplete delivery we already rebuilt for, wait rather
            // than walking the archive again on every tick.
            return !isBackingOff(manifestURL)
        }
        // The gate. A stamp that still matches means `manifest.json` has not been
        // touched since we recorded it, so nothing it describes has changed.
        if recorded.stampMatches(manifestURL) { return false }
        guard let onDisk = ManifestWitness.read(from: manifestURL) else {
            // Unreadable right now — not evidence of staleness, and rebuilding
            // from a manifest we cannot read is not a repair. Say no and let the
            // next poll ask again.
            return false
        }
        if recorded.describesSameFiles(as: onDisk) { return false }
        // Stale — but if it is the *same* manifest we already rebuilt for and
        // could not settle, wait rather than walking the archive again on every
        // tick. The back-off gates every stale answer, not only the
        // no-witness one: an unsettled reconcile now leaves the previous witness
        // in place, so this is the branch it comes back through.
        return !isBackingOff(manifestURL)
    }

    /// Whether we are inside the back-off window for a delivery that has not
    /// changed since the last unsettled attempt. See `noteReconcileOutcome()`.
    private func isBackingOff(_ manifestURL: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let unsettledStamp, let deadline = nextReconcileAttempt else { return false }
        guard unsettledStamp == ManifestWitness.stamp(of: manifestURL) else { return false }
        return ContinuousClock.now < deadline
    }

    /// Whether the archive is **part-way through receiving a change from
    /// somewhere else** — `manifest.json` is not the one the index last settled,
    /// which only a change from elsewhere can bring about, since corruption
    /// leaves the manifest untouched (slice 60; see `recordWitness` for why the
    /// first, circular version of this signal was replaced).
    ///
    /// It is what lets `verifyIntegrity()` and `sweepFileSizes()` say *this file
    /// has not arrived yet* instead of *this file is damaged*, and what stops the
    /// drift guard recommending a `rebaseline` that would discard the incoming
    /// version. Archive-wide, like 47's sentinel, with the same consequence: it
    /// says a delivery is in flight, never which files it covers — **which is why
    /// those three now ask `deliveryCoverage()` instead** (slice 60c). What is
    /// left here is the whole-archive question, which is the one 61's bar asks.
    ///
    /// Takes only the process-local lock — it is consulted on read paths that
    /// deliberately take no archive lock.
    ///
    /// **Public since slice 61**, which is the app's whole signal: the window
    /// says *receiving a change from another machine* while this is true, and
    /// stops the moment it goes false. That boundary is deliberately the
    /// *adoption* rather than the arrival of the last file — a bar that cleared
    /// when the bytes landed would go away up to a back-off before the record it
    /// announced actually appeared in the list. Nothing about detection changed
    /// for it (61 is otherwise app-only); this is the same fact 60 already
    /// computed on every poll, said out loud.
    ///
    /// **`.unknown` is not in flight** (slice 60b, fork b). An index that has
    /// never settled anything has no previous state for the disk to differ from,
    /// so it cannot support a claim that something is arriving — and everything
    /// downstream of this flag *relabels a finding*: `verifyIntegrity()` turns
    /// *missing* into *not here yet*, the drift guard turns *accept the current
    /// contents* into *wait*, and 61's bar announces another machine by name. A
    /// false arrival is misleading in all three, so unknown reads as damage,
    /// which is also the pre-60 behaviour the no-witness exception was protecting
    /// — now on purpose rather than as a side effect of the exception's placement.
    /// The other direction of this rule is `awaitedPaths(carriedFrom:)`, where
    /// unknown must go the *other* way.
    public var deliveryIsInFlight: Bool { witnessState() == .disagrees }

    /// The same fact **per file** (slice 60c) — what the flag above could never
    /// say, since it reports that *a* delivery is in flight and never which files
    /// it covers.
    ///
    /// Every consumer that relabels a *finding* wants this one rather than the
    /// flag: relabelling all of them made damage that predated the delivery
    /// report as *still arriving*, so `genea verify` told the user to wait for a
    /// file that will never arrive and the standing damage banner went quiet for
    /// the duration. The flag itself is unchanged and still right for 61's bar,
    /// which is a whole-window statement about the archive.
    ///
    /// **The settled entries are read only when something is in flight**, which
    /// is rare and short: on the ordinary path this costs exactly what
    /// `deliveryIsInFlight` costs and touches no rows. A read that fails leaves
    /// them empty, which `DeliveryCoverage` documents as falling back to slice
    /// 60's coarse answer rather than to a fresh accusation of damage.
    func deliveryCoverage() -> DeliveryCoverage {
        lock.lock()
        defer { lock.unlock() }
        return deliveryCoverageLocked()
    }

    /// The same, for callers already holding `lock` — the drift guard runs inside
    /// `withState`, and `lock` is not recursive.
    func deliveryCoverageLocked() -> DeliveryCoverage {
        // **`.disagrees` has two shapes, and only one of them can be asked about
        // a file.** When the manifest reads, its entries are what the delivery is
        // bringing and the comparison below is meaningful. When it does not —
        // 60b's outside writer caught mid-write — every consumer is holding the
        // *settled* manifest instead (`withReadState` and `reloadManifest` both
        // keep the last good one), so comparing it against the settled rows would
        // find every path unchanged and call the whole delivery damage. There is
        // nothing to compare, so the archive-wide answer is the honest one.
        //
        // Which shape it is comes back **from the same comparison**, rather than
        // from decoding `manifest.json` a second time to find out
        // (`/code-review`).
        let comparison = witnessComparisonLocked()
        guard comparison.state == .disagrees else { return .noDeliveryInFlight }
        // The marker names the manifest the rows describe, so it identifies the
        // rows themselves — a better cache key than the witness digest, which the
        // backfill path can leave unchanged while writing rows. Absent means an
        // index that has none, and answers without reading any.
        guard comparison.readTheManifest,
            let digest = (try? index.settledFilesDigest()) ?? nil
        else { return .wholeArchive }
        if let cachedSettledFiles, cachedSettledFiles.digest == digest {
            return DeliveryCoverage(isInFlight: true, settled: cachedSettledFiles.files)
        }
        guard let settled = try? index.settledFiles() else { return .wholeArchive }
        cachedSettledFiles = (digest, settled)
        return DeliveryCoverage(isInFlight: true, settled: settled)
    }

    /// Whether a mutation of ours is currently **blocked waiting for another
    /// process** to release the archive lock.
    ///
    /// The difference between "this write is slow" and "this write is stuck
    /// behind someone else", which nothing above the engine can tell on its own.
    /// The app uses it so its waiting indicator only claims another process when
    /// there is one — a long local write (a big ingest, an index rebuild) is slow
    /// for reasons of its own and should not be blamed on an agent.
    ///
    /// Takes none of this archive's locks, so it answers immediately even while a
    /// mutation is parked.
    public var isWaitingForAnotherProcess: Bool { fileLock.isContended }

    // MARK: - Shared mutation plumbing (used by Archive+Artifacts/Files/Conclusions/Integrity)

    /// **The mutation chokepoint.** Executes `body` holding all three locks,
    /// giving it mutable access to the manifest and the index. Every public
    /// mutating method funnels through this, so "the index reflects the last
    /// committed state" (§5.1) is structural rather than a per-call discipline,
    /// and so is "one writer at a time, machine-wide".
    ///
    /// Three things happen around `body`, in order (slice 47):
    ///
    /// 1. **The archive lock is taken** and released on every path, so a
    ///    competing process waits rather than interleaving. It throws
    ///    `ArchiveError.archiveBusy` after `lockTimeout` — which is why this is
    ///    `throws` and not `rethrows`. **That wait happens outside `lock`**
    ///    (52), so a reader is never parked behind another process; see the
    ///    type's doc comment for the measurement that forced the change.
    /// 2. **`manifest.json` is re-read** (fork g). Ours may be stale: another
    ///    process could have renamed the archive since we opened it, and
    ///    `commitManifest` would then write our old `name` straight back over
    ///    theirs. `files` already self-corrects via `recomputeManifestFiles`;
    ///    this closes `name`/`updatedAt`, at one 5 KB read per mutation.
    /// 3. **The dirty sentinel brackets the body** (fork f), so a mutation that
    ///    dies partway through is detectable on the next `open()`. Note it is
    ///    *not* cleared on a throw — see `IndexDirtyMarker` for why that
    ///    asymmetry is deliberate.
    /// 4. **The manifest is committed** once the body returns (slice 49). Every
    ///    mutation ends this way now, rather than each method remembering to
    ///    call `commitManifest` itself: since `manifest.files` covers the
    ///    engine-authored JSON as well as the payload, a mutation that forgot
    ///    the call would leave a live sidecar's recorded hash behind its bytes
    ///    and the next `verifyIntegrity()` would report the archive's own write
    ///    as damage. `commitManifest` writes nothing when the file list is
    ///    unchanged, so the mutations that touch no tracked file (a trash purge,
    ///    an index rebuild) still don't rewrite `manifest.json`.
    ///
    /// `index` is not `inout` — `ArchiveIndex` is a reference type now that it
    /// owns a SQLite connection (see its doc comment), so mutating it (via its
    /// own throwing `upsert`/`removeArtifact` methods) doesn't require
    /// write-back. `manifest` remains `inout`: it's still a value type, and
    /// `commitManifest` writes back through this same binding (see its doc
    /// comment for why that matters).
    func withState<T>(_ body: (inout Manifest, ArchiveIndex) throws -> T) throws -> T {
        writerLock.lock()
        defer { writerLock.unlock() }
        return try fileLock.withLock {
            lock.lock()
            defer { lock.unlock() }
            reloadManifest()
            // The same door `open` has, for a handle that was already open when a
            // newer manifest landed (slice 64): the app holds its window open for
            // hours, and a sync delivery in that time is exactly the case the
            // version rule is for. One string compare, before the dirty marker,
            // so a refusal has written nothing and triggers nothing.
            if SchemaVersion.isNewer(manifest.schemaVersion, than: SchemaVersion.current) {
                throw ArchiveError.archiveNewerThanBuild(
                    path: ArchiveLayout.manifestFileName, found: manifest.schemaVersion,
                    supported: SchemaVersion.current)
            }
            indexWasCurrentAtStart = witnessStateLocked() == .matches
            // A marker that is ALREADY here belongs to an unresolved divergence —
            // an earlier mutation of ours that threw, or another process that
            // died mid-write. It is not ours to clear just because *this*
            // mutation succeeds: only `open()`'s rebuild actually resolves the
            // divergence, so clearing it here would erase the one signal that
            // triggers that rebuild (review finding, 47).
            let hadUnresolvedDivergence = IndexDirtyMarker.isSet(in: rootURL)
            try IndexDirtyMarker.set(in: rootURL)
            authoredWrites.removeAll()
            authoredRemovals.removeAll()
            abandonedThisMutation.removeAll()
            driftClearedThisMutation.removeAll()
            resolvedInterruptedWriteThisMutation = false
            defer {
                authoredWrites.removeAll()
                authoredRemovals.removeAll()
                abandonedThisMutation.removeAll()
                driftClearedThisMutation.removeAll()
                resolvedInterruptedWriteThisMutation = false
            }
            // **Both flags are cleared on every exit, not just the committing
            // one.** `commitManifest` consumes them, and a body that throws never
            // reaches it — so without this, a reconcile whose rebuild failed would
            // leave `adoptingDeliveredManifest` set and the *next* mutation would
            // silently skip recomputing and writing `manifest.json`. Same shape as
            // `authoredWrites` above, and the same reason.
            defer {
                adoptingDeliveredManifest = false
                indexWasCurrentAtStart = false
            }
            authoredBaseline = Dictionary(
                manifest.files.lazy
                    .filter { ArchiveLayout.isEngineAuthored(relativePath: $0.path) }
                    .map { ($0.path, $0.sha256) },
                uniquingKeysWith: { first, _ in first })
            defer { authoredBaseline.removeAll() }
            do {
                let result = try body(&manifest, index)
                try commitManifest(&manifest, index: index)
                // A sentinel that was already here is an earlier divergence's,
                // not ours to clear (47) — unless this mutation is the
                // `rebaseline()` that resolved it, having rebuilt the index and
                // re-minted the manifest, which is everything it stood for.
                if !hadUnresolvedDivergence || resolvedInterruptedWriteThisMutation {
                    IndexDirtyMarker.clear(in: rootURL)
                }
                if resolvedInterruptedWriteThisMutation {
                    InterruptedWriteMarker.clear(in: rootURL)
                    interruptedWriteExemptions.removeAll()
                } else {
                    pruneInterruptedWriteExemptions()
                }
                return result
            } catch {
                // **Only a mutation that authored something can have died
                // between its sidecar and its manifest** (review finding, 58).
                // `authoredWrites` is populated by `writeAuthoredJSON` *after*
                // its atomic write lands, so an empty one proves no
                // engine-authored file changed here — and a failure that changed
                // no file is not an interrupted write, whatever else it is.
                //
                // 49 set the flag on every failure, which was conservative in the
                // only direction it then mattered: the flag downgrades a
                // `.checksumMismatch` to a `.interruptedWrite`, and over-reporting
                // "suspect" is harmless. It stopped being harmless when 58's drift
                // guard started *consulting* the flag to decide whether to protect
                // a file. Two ways that bit, both confirmed:
                //
                // - **The guard disabled itself.** Its refusal throws from inside
                //   this body, which armed the flag, which is the first thing the
                //   guard checks — so an immediate identical retry sailed through
                //   and overwrote the very file the refusal had just protected.
                // - **Any unrelated failure disarmed it.** A validation-only
                //   throw (`personNotFound`) that writes nothing armed the flag
                //   too, and left the sentinel behind for the next process to
                //   re-arm it from — so one failed edit turned the guard off for
                //   the rest of that session and the start of the next.
                //
                // The sentinel goes with it, for the same reason and with the
                // same proof: nothing was authored, so nothing is out of step and
                // there is no divergence for the next `open()` to resolve. A
                // sentinel that was *already* here still stays (47's rule — it
                // belongs to an earlier divergence, not to this call).
                //
                // **Known residue, stated rather than papered over:** a mutation
                // that moves files before touching the index — `removeArtifact`
                // stashing a folder into `.trash/` — and then fails *inside* the
                // index call authors nothing, so it no longer schedules a rebuild.
                // Reaching it takes a SQLite failure, and it leaves a stale row
                // that `verifyIntegrity()` reports as missing files rather than
                // anything silent.
                if authoredWrites.isEmpty {
                    if !hadUnresolvedDivergence { IndexDirtyMarker.clear(in: rootURL) }
                } else {
                    // The sentinel stays behind (deliberately — see above), and it
                    // may be bracketing a sidecar that landed before the failure
                    // with a manifest that never caught up. Remember that here as
                    // well as on disk, so a `verifyIntegrity()` later in this same
                    // session classifies the mismatch the way a reopened archive
                    // would (review finding, 49).
                    hasUnresolvedInterruptedWrite = true
                    // And exempt exactly what it left from the drift guard (68):
                    // the bytes are ours, written a moment ago, so the next edit
                    // of that record must not be refused as somebody else's.
                    for (path, entry) in authoredWrites {
                        interruptedWriteExemptions[path] = entry.sha256
                    }
                }
                throw error
            }
        }
    }

    /// Whether a write is known to have died before the manifest caught up, so a
    /// mismatch on an engine-authored file should be reported as suspect rather
    /// than corrupt. See `hasUnresolvedInterruptedWrite` for the three
    /// transitions.
    var interruptedWriteSuspected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasUnresolvedInterruptedWrite
    }

    /// The same fact for a caller **already holding `lock`** — `withState`'s body
    /// is inside it and `lock` is not recursive, so reaching for the property
    /// above from there self-deadlocks (found the moment
    /// `abandonDelivery(path:)`'s interrupted-write guard was written). Same
    /// shape, and the same reason, as `deliveryCoverageLocked()`.
    var interruptedWriteSuspectedLocked: Bool { hasUnresolvedInterruptedWrite }

    /// Records that the interrupted-write divergence has been resolved.
    ///
    /// **Only `rebaseline()` may call this, and only from inside `withState`**
    /// (whose `lock` this relies on). An ordinary mutation must not: it re-mints
    /// the entry for the file it wrote and knows nothing about whichever record
    /// was in flight when the earlier write died. If the rebaseline itself then
    /// fails, `withState`'s catch sets the flag straight back.
    func resolveInterruptedWrite() {
        hasUnresolvedInterruptedWrite = false
        resolvedInterruptedWriteThisMutation = true
    }

    /// **Settles the flag an open raised from a leftover sentinel** — keeping it
    /// only if the crash actually left the manifest behind the archive (slice
    /// 65, fork f).
    ///
    /// A crash between `dirty` and the first write, or between the manifest
    /// commit and the clear, diverged nothing, yet used to leave the banner up
    /// and 58's drift guard off until the user ran *Accept Current Contents*. So
    /// after the rebuild, the manifest is compared with what the rebuild saw,
    /// entry by entry, with the same rule `verifyIntegrity()` uses to call a
    /// disagreement `.interruptedWrite` — which is what keeps the flag set
    /// **iff** such a finding exists.
    ///
    /// **An entry a delivery is bringing is not residue while its bytes are the
    /// ones last settled** (60c): an arrival that has not landed differs from the
    /// manifest too, for a reason that is not a crash. Bytes that have moved
    /// since settling were moved here, by the write that died — and that is the
    /// case `abandonDelivery(path:)` must keep refusing, since blessing them would
    /// make half a commit of ours the version of record.
    ///
    /// **When something is left, it is written down** (`InterruptedWriteMarker`)
    /// as well as raised in memory, so a second open says what the first did.
    /// The sentinel used to be cleared unconditionally and nothing kept the
    /// verdict, so a user who quit without accepting was told on the next launch
    /// that the half-written record was corrupt. `rebaseline()` is what clears
    /// it — see `withState`.
    ///
    /// What it does *not* count is an entry the manifest lacks: a record or a
    /// payload the crash wrote and the manifest never heard of is unverified,
    /// not suspect (49, fork f), and the next commit mints it.
    ///
    /// **And it decides what the drift guard exempts** (slice 68, fork c): a
    /// residue path the crashed write journaled, while it still holds the bytes
    /// that write put there. A residue that could not be computed exempts nothing.
    ///
    /// **An earlier crash's exemptions are candidates too** (slice 68, hand-test):
    /// a second crash before anyone accepts the first journals only its own
    /// writes, and taking the journal alone dropped the first crash's record — the
    /// one the banner is still about — so it could no longer be edited.
    private func settleInterruptedWriteLocked(journaled: [String: String]) {
        let candidates = interruptedWriteExemptions.merging(journaled) { _, newer in newer }
        guard let residue = try? interruptedWriteResidueLocked() else {
            hasUnresolvedInterruptedWrite = true
            interruptedWriteExemptions = [:]
            InterruptedWriteMarker.set(in: rootURL, exempting: [:])
            return
        }
        if residue.isEmpty {
            hasUnresolvedInterruptedWrite = false
            interruptedWriteExemptions = [:]
            InterruptedWriteMarker.clear(in: rootURL)
        } else {
            hasUnresolvedInterruptedWrite = true
            interruptedWriteExemptions = candidates.filter { path, sha in
                guard let entry = residue[path] else { return false }
                let actual =
                    entry
                    ?? (try? Checksum.sha256Hex(ofFileAt: rootURL.appendingPathComponent(path)))
                return actual == sha
            }
            InterruptedWriteMarker.set(in: rootURL, exempting: interruptedWriteExemptions)
        }
    }

    /// Drops the exemption for every path this mutation wrote or removed — ours
    /// now, so the crash's bytes no longer stand for it — and rewrites the marker
    /// if that changed it. Caller holds `lock`, at a successful commit.
    private func pruneInterruptedWriteExemptions() {
        let touched = Set(authoredWrites.keys).union(authoredRemovals)
        guard !touched.isDisjoint(with: interruptedWriteExemptions.keys) else { return }
        for path in touched { interruptedWriteExemptions[path] = nil }
        if InterruptedWriteMarker.isSet(in: rootURL) {
            InterruptedWriteMarker.set(in: rootURL, exempting: interruptedWriteExemptions)
        }
    }

    /// Everything the open that finds `.index/dirty` does after the rebuild, run
    /// once (slice 65). The trash reconcile comes first, so the comparison sees
    /// the finished state, and it skips any subject a delivery is bringing — see
    /// `TrashStore.reconcileAfterInterruptedWrite`. The verdict is recorded in
    /// `InterruptedWriteMarker` **before** `dirty` is cleared, so a crash between
    /// the two repeats the recovery rather than losing it.
    func recoverFromInterruptedWrite() {
        lock.lock()
        defer { lock.unlock() }
        let coverage = deliveryCoverageLocked()
        let entries = Dictionary(
            manifest.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        TrashStore.reconcileAfterInterruptedWrite(in: rootURL, index: index) { recordPath in
            guard coverage.isInFlight else { return false }
            return entries[recordPath].map(coverage.covers) ?? true
        }
        settleInterruptedWriteLocked(journaled: IndexDirtyMarker.journaledWrites(in: rootURL))
        IndexDirtyMarker.clear(in: rootURL)
    }

    /// The manifest entries the disk disagrees with in the way a write that died
    /// before its manifest leaves — see `settleInterruptedWriteLocked()`. Caller holds
    /// `lock`.
    ///
    /// Each path maps to the hash this computed for it, so the settle need not
    /// read the file again — `nil` when it decided without one (absent, or a
    /// sidecar whose size already disagrees).
    private func interruptedWriteResidueLocked() throws -> [String: String?] {
        let coverage = deliveryCoverageLocked()
        let evidence = try interruptedWriteEvidence(index: index)
        var residue: [String: String?] = [:]
        for entry in manifest.files {
            let covered = coverage.covers(entry)
            let url = rootURL.appendingPathComponent(entry.path)
            guard
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                    as? NSNumber
            else {
                if !covered && evidence.explains(entry, actualSHA256: nil) {
                    residue[entry.path] = .some(nil)
                }
                continue
            }
            let authored = ArchiveLayout.isEngineAuthored(relativePath: entry.path)
            // A payload whose sidecar agrees with the manifest cannot be residue,
            // whatever its bytes say — skip the hash of what may be a large file.
            guard authored || evidence.sidecarEntries[entry.path] != entry else { continue }
            if !covered, authored, size.int64Value != entry.byteLength {
                residue[entry.path] = .some(nil)
                continue
            }
            guard let actual = try? Checksum.sha256Hex(ofFileAt: url) else { continue }
            if covered, actual == coverage.settledSHA256(of: entry.path) { continue }
            if evidence.explains(entry, actualSHA256: actual) { residue[entry.path] = actual }
        }
        return residue
    }

    /// What the rebuilt index says the archive holds, for deciding whether a
    /// manifest entry is behind it — see `InterruptedWriteEvidence`.
    func interruptedWriteEvidence(index: ArchiveIndex) throws -> InterruptedWriteEvidence {
        let sidecars = try payloadEntries(index: index)
        var referenced = Set(sidecars.map(\.path))
        referenced.formUnion(try authoredPaths(index: index))
        referenced.formUnion(try index.unreadableRecordPaths())
        // A record whose sidecar vanished and left a copy is one the archive still
        // expects (58c, second `/code-review`): its entry is carried on purpose,
        // and reading its absence as a died write's residue kept the flag up on
        // every dirty open and reported a known loss as `interruptedWrite`. A
        // copy of what the died write unlinked is discarded before this is asked
        // (`ArchiveIndex.rebuild(unlinkedByDiedWrite:)`), so a cut removal is
        // still residue.
        referenced.formUnion(try index.preservedRecordPaths())
        return InterruptedWriteEvidence(
            referenced: referenced,
            sidecarEntries: Dictionary(
                sidecars.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }))
    }

    /// Read-only access to manifest + index together, under the process-local
    /// lock **only** — no archive lock, per `ArchiveLock`'s reader policy. Used
    /// by `verifyIntegrity()` and the trash listings, which read but write nothing.
    ///
    /// **It hands out a `Manifest` value and an `ArchiveIndex` reference, and
    /// those are not the same promise.** The manifest is a copy, so it is a true
    /// snapshot; the index is a live handle whose queries run whenever the caller
    /// gets round to them — `verifyIntegrity()` in particular captures it and
    /// queries after this returns, so its index reads are current-at-use, not
    /// current-at-entry. That is pre-existing and harmless (an integrity sweep
    /// does file I/O per entry and holding the lock across all of it would block
    /// every other task), but it is not a "coherent snapshot" and should not be
    /// described as one.
    ///
    /// It **does** re-read the manifest, though, because the two kinds of
    /// staleness a reader can see are not comparable. Index staleness is bounded
    /// by one mutation's duration (the connection is read-through, so it already
    /// sees other processes' commits); manifest staleness was unbounded — loaded
    /// once at `open()` and never refreshed, so a window left open for an hour
    /// would have `verifyIntegrity()` checking an hour-old file list. §10.5 names
    /// that datum specifically. Refreshing needs no archive lock: `AtomicIO`'s
    /// write-then-rename means a reader gets some whole manifest, never a torn one.
    func withReadState<T>(_ body: (Manifest, ArchiveIndex) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        reloadManifest()
        return try body(manifest, index)
    }

    /// Read-only access for the lookup surface (`Archive+Lookup.swift`).
    /// "Read-only" here means "doesn't call `upsert`/`removeArtifact`/`rebuild`"
    /// — `ArchiveIndex`'s query methods (`artifact(_:)`, `allArtifacts()`, …)
    /// still execute SQL `SELECT`s through the shared connection, but take no
    /// lock of their own; `Archive`'s lock is what makes this safe.
    func withIndex<T>(_ body: (ArchiveIndex) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(index)
    }

    /// Refreshes `manifest` from disk. Best-effort on purpose: if the file is
    /// momentarily unreadable we keep the copy we have rather than failing an
    /// otherwise-valid mutation — `AtomicIO`'s write-then-rename means a reader
    /// never sees a *torn* manifest, so the only way this fails is a genuinely
    /// broken file, and the mutation's own `commitManifest` will rewrite it
    /// correctly anyway.
    private func reloadManifest() {
        if let fresh = try? Self.readManifest(at: ArchiveLayout.manifestURL(in: rootURL)) {
            manifest = fresh
        }
    }

    /// Writes an **engine-authored** JSON record — an artifact sidecar, a
    /// conclusion record — and mints its manifest entry from the bytes just
    /// written (slice 49).
    ///
    /// Every write of a file inside `artifacts/` or `conclusions/` goes through
    /// here rather than calling `AtomicIO.writeJSON` directly, because
    /// `manifest.files` now carries these files' checksums and nothing else
    /// re-derives them: `recomputeManifestFiles` carries a present entry forward
    /// **verbatim** (that is what makes rot detectable), so a write that didn't
    /// record its new hash would leave the manifest describing the previous
    /// contents, and the next verify would report the archive's own edit as
    /// corruption.
    ///
    /// Only legal inside `withState` — the entry is buffered until that call's
    /// closing `commitManifest`.
    ///
    /// **It refuses to overwrite a record that changed on disk** — see
    /// `refuseToOverwriteDriftedRecord`.
    ///
    /// **And it journals the bytes before writing them** (slice 68) — see
    /// `IndexDirtyMarker` — so a crash between this and the manifest leaves a
    /// record of which bytes are ours.
    func writeAuthoredJSON(_ value: some Encodable, to url: URL) throws {
        try writeAuthoredData(GeneaLogicJSONCoding.encoder.encode(value), to: url)
    }

    /// Records the intent alone, for the one removal that does not unlink a file:
    /// `removeArtifact` takes the whole folder out by **rename** into `.trash/`,
    /// so `record.json` never passes through `removeAuthoredFile(at:)`.
    ///
    /// Exists so `authoredRemovals` can stay private to this file, which is where
    /// everything that consumes it lives.
    func noteAuthoredRemoval(at url: URL) {
        authoredRemovals.insert(ArchiveLayout.relativePath(of: url, in: rootURL))
    }

    /// Unlinks an engine-authored file and **records that this mutation meant
    /// to** — the removal chokepoint, mirroring `writeAuthoredJSON` (slice 60b,
    /// `/code-review`).
    ///
    /// Seven removal sites had grown the same three lines ("sidecar first, then
    /// the index row"), and each was a place a future one could forget to say
    /// what it had done. The forgetting is not cosmetic: see `authoredRemovals`
    /// for the permanently poisoned manifest it produces.
    ///
    /// **The path is recorded whether or not a file was there**, because the
    /// intent is what the manifest recompute needs, not the unlink. Every caller
    /// already guarded on existence for the same reason: an out-of-band delete
    /// may have got there first, and the entry must still go.
    ///
    /// Ordering is the callers' own and unchanged — sidecar first, then the index
    /// row, so a failure between the two reconciles *toward* deletion on the next
    /// rebuild rather than resurrecting the record.
    ///
    /// **It refuses to unlink a record that changed on disk** (slice 68, fork a),
    /// for the reason `writeAuthoredJSON` refuses to overwrite one: a delete
    /// destroys whatever was there just as surely, and conclusions have no trash
    /// to take it back from — the undo writes the index's copy, not the one that
    /// was on disk. A mutation that writes before it unlinks must check first
    /// (`refuseToTouchDriftedRecords(at:)`), or the refusal lands half-way.
    func removeAuthoredFile(at url: URL) throws {
        let path = ArchiveLayout.relativePath(of: url, in: rootURL)
        try refuseToOverwriteDriftedRecord(at: path, url: url)
        authoredRemovals.insert(path)
        IndexDirtyMarker.journalRemoval(of: path, in: rootURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        WriteCheckpoint.reached("unlinked", at: url)
    }

    /// The same write, from **bytes rather than a value** — called directly only
    /// by `repairRecord(atPath:)` (slice 59).
    ///
    /// A repair holds the sidecar's own bytes and its whole claim is that it puts
    /// *those* back. Handing them through `writeAuthoredJSON` would decode and
    /// re-encode them first, which is a round-trip this call has no reason to
    /// take: the encoder is deterministic, so it would almost always produce the
    /// same bytes, and "almost always" is not what the manifest comparison in
    /// `repairPlan(forRecordAt:)` promised the caller. Writing the bytes makes the
    /// proof and the write the same object.
    ///
    /// `writeAuthoredJSON` is this, after encoding — the encoder is the same one
    /// `AtomicIO.writeJSON` uses.
    func writeAuthoredData(_ data: Data, to url: URL) throws {
        let path = ArchiveLayout.relativePath(of: url, in: rootURL)
        try refuseToOverwriteDriftedRecord(at: path, url: url)
        let sha256 = Checksum.sha256Hex(of: data)
        IndexDirtyMarker.journalWrite(of: path, sha256: sha256, in: rootURL)
        try AtomicIO.write(data, to: url)
        authoredWrites[path] = ManifestEntry(
            path: path, sha256: sha256, byteLength: Int64(data.count))
    }

    /// Throws `ArchiveError.recordDriftedOnDisk` if the file about to be
    /// overwritten is not the one GeneaLogic last wrote (slice 58, fork f).
    ///
    /// **The write path is the other direction of 58's problem.** Preservation
    /// stops a *rebuild* destroying the last copy of a record it can't read; this
    /// stops an *edit* destroying a copy nobody knows exists. `updateMetadata` and
    /// every call like it read from the index and blind-write the sidecar without
    /// ever reading it, so a record that was hand-edited — or written by an agent
    /// driving the CLI while the app is open — looks entirely healthy right up to
    /// the moment the edit discards it. No record data is lost (the write is a
    /// complete record either way), but whatever was on disk is, silently. That is
    /// the §10.4 case arriving through the Inspector.
    ///
    /// **It can afford to be exact where 57's sweep could not.** An edit
    /// overwrites *one small file*, so hashing that one sidecar against its
    /// manifest entry costs microseconds — which is why this catches a same-size
    /// hand-edit, the case the archive-wide size sweep is structurally blind to.
    ///
    /// It sits at this chokepoint rather than on `updateMetadata` so that
    /// conclusions are covered too: an agent editing `conclusions/persons/…` is
    /// the scenario that motivates the check, and one guard here is less code than
    /// a special case per mutation.
    ///
    /// **Four things are deliberately not drift:**
    ///
    /// - **The bytes an unresolved interrupted write left.** After a mutation
    ///   dies between its sidecar and its manifest, that file is *expected* to
    ///   mismatch — 57 established that classification, and refusing it would
    ///   block editing the very record the crash was writing. **Only those bytes**
    ///   (slice 68, fork c): this used to skip on the archive-wide flag, which
    ///   left every other record unguarded until *Accept Current Contents*. See
    ///   `interruptedWriteExemptions`.
    /// - **A path this mutation already wrote.** It mismatches because *we*
    ///   changed it (a merge writes several records; a file operation rewrites the
    ///   record it just changed).
    /// - **A path with no manifest entry** — a brand-new record, or an archive
    ///   written before slice 49 put authored checksums in the manifest. There is
    ///   nothing to compare against, and inventing a baseline is what `rebaseline`
    ///   exists to gate.
    /// - **A file that is absent, or that cannot be read at all.** Absent is a
    ///   repair, not a clobber — there is nothing left to destroy. Present but
    ///   unreadable cannot be *shown* to have drifted, and refusing would leave no
    ///   way forward: the file is already unusable and `rebaseline` cannot hash it
    ///   either.
    ///
    /// The resolution for a real finding is the one that already exists and is
    /// already gated on a human asking in as many words: `rebaseline()` — *Accept
    /// Current Contents…* in the app, `genea rebaseline` in the CLI — which blesses
    /// the on-disk version, after which the edit proceeds.
    ///
    /// **Callable ahead of the write, and some mutations must** — see
    /// `refuseToTouchDriftedArtifact(slug:)`.
    func refuseToOverwriteDriftedRecord(at path: String, url: URL) throws {
        guard authoredWrites[path] == nil, !driftClearedThisMutation.contains(path) else {
            return
        }
        guard let expected = authoredBaseline[path] else {
            // **No baseline is no evidence of drift, and no licence to write over
            // a newer record** (`/code-review`, 70). Without an entry there is no
            // way to tell what moved, so the stamp is read every time — one small
            // read, on a path that is rare (a brand-new record, which is absent,
            // or one whose entry the next commit will mint).
            try Migration.refuseIfAhead(recordAt: url, path: path)
            driftClearedThisMutation.insert(path)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path),
            let actual = try? Checksum.sha256Hex(ofFileAt: url),
            actual != expected,
            !(hasUnresolvedInterruptedWrite && interruptedWriteExemptions[path] == actual)
        else {
            driftClearedThisMutation.insert(path)
            return
        }
        // **A record from a newer GeneaLogic is not drift** (slice 70, fork b).
        // Either refusal below would be right about the write and wrong about
        // the file: *accept the current contents* is then refused as newer, and
        // the file is intact. Asked first, because it outranks anything a
        // delivery or its witness could say about the path.
        try Migration.refuseIfAhead(recordAt: url, path: path)
        // **Mid-delivery the refusal is the same, the advice is not** (slice 60,
        // hand-test). `recordDriftedOnDisk` tells the user to accept the current
        // contents — correct for a hand edit, and destructive here: blessing the
        // stale local bytes makes the incoming record land as a reported
        // corruption instead of an adoption, discarding the change made on the
        // other machine. Waiting is the remedy, so the error says so.
        //
        // **And under `.unknown` neither line is honest** (slice 60b, fork c).
        // With no settled witness the archive cannot tell the two apart, so it
        // says that instead of guessing: *accept the current contents* would
        // discard an incoming version, and *wait* would promise an arrival on
        // evidence that does not exist.
        //
        // **And *wait* is only honest for a file the delivery is actually
        // bringing** (slice 60c). The flag is archive-wide, so any delivery in
        // progress used to turn every drifted record into one that was "still
        // arriving" — the same *wait for a file that will never arrive* this
        // guard's own advice exists to avoid. The entry for this path decides it:
        // unchanged since the last settling, and the drift is local, whatever
        // else is in flight.
        switch witnessStateLocked() {
        case .disagrees:
            if deliveryCoverageLocked().covers(path: path, recordedSHA256: expected) {
                throw ArchiveError.recordAwaitingDelivery(path: path)
            }
            throw ArchiveError.recordDriftedOnDisk(path: path)
        case .unknown: throw ArchiveError.recordDriftedWithNoHistory(path: path)
        case .matches: throw ArchiveError.recordDriftedOnDisk(path: path)
        }
    }

    /// The same refusal, raised **before** a mutation touches an artifact's
    /// payload files (slice 58, hand-test).
    ///
    /// `attachFile`, `replaceFile` and `detachFile` move bytes around the
    /// artifact's folder *first* and write the record afterwards (`restoreFile`
    /// writes the record first since slice 65, and still checks here), so
    /// the chokepoint refusal came too late: attaching a file to an artifact whose
    /// `record.json` had drifted refused the record edit — correctly — but left
    /// the copied file sitting in the folder, claimed by nothing. That is the same
    /// silent side effect the guard exists to prevent, one layer out: the
    /// mutation is refused, so it must leave *nothing* behind.
    ///
    /// The chokepoint keeps its own check because it is what makes the rule
    /// structural rather than a discipline every future mutation has to remember;
    /// it does not hash the file again, since a path cleared here is remembered
    /// for the rest of the mutation (`driftClearedThisMutation`, slice 68).
    ///
    /// **`removeArtifact` deliberately does not call this.** It moves the whole
    /// folder — drifted `record.json` and all — into `.trash/`, which destroys
    /// nothing and stays restorable, so refusing a delete would be a refusal
    /// without a loss to prevent.
    func refuseToTouchDriftedArtifact(slug: String) throws {
        let url = ArchiveLayout.recordURL(in: rootURL, slug: slug)
        try refuseToOverwriteDriftedRecord(
            at: ArchiveLayout.relativePath(of: url, in: rootURL), url: url)
    }

    /// The same refusal, raised **before** a mutation that touches several
    /// records writes any of them (slice 68, fork b).
    ///
    /// `withState` has no rollback, so a cascade refused part-way — a merge whose
    /// last step is unlinking a drifted record, or whose third write meets one —
    /// leaves the writes before it on disk, and having authored something, arms
    /// the interrupted-write flag: the guard's own refusal would become the
    /// divergence it exists to prevent. Checking every path first makes the
    /// refusal leave nothing behind, as `refuseToTouchDriftedArtifact(slug:)`
    /// does for one artifact. The chokepoints keep their own checks.
    func refuseToTouchDriftedRecords(at urls: [URL]) throws {
        for url in urls {
            try refuseToOverwriteDriftedRecord(
                at: ArchiveLayout.relativePath(of: url, in: rootURL), url: url)
        }
    }

    /// Recomputes the manifest's file list, bumps `updatedAt`, and atomically
    /// writes it — operating ONLY on the passed-in `inout` manifest (never
    /// `self.manifest`), so it is safe to call from within a `withState`
    /// closure.
    ///
    /// **Writes nothing when the file list is unchanged (slice 49, fork c).**
    /// `updatedAt` means "when the manifest last changed", and since `files` now
    /// moves on every conclusions write as well as every artifact one, tying the
    /// two together keeps that meaning honest in both directions: a conclusion
    /// edit bumps it (it changed the manifest), a trash purge or an index
    /// rebuild does not (it didn't).
    ///
    /// **Bug fix (flagged for review):** an earlier version of every mutation
    /// method called `self.rewriteManifest()` from inside `withState { manifest,
    /// index in … }` — but `withState` already holds an `inout` access to
    /// `self.manifest`, and `rewriteManifest` read/wrote `self.manifest` too,
    /// which is a Swift exclusive-access violation that traps at runtime
    /// ("Simultaneous accesses to 0x…, but modification requires exclusive
    /// access"). The fix is structural: this method takes the manifest
    /// `inout` from the caller's already-held binding instead of reaching
    /// through `self`, so there is only ever one access in flight. Every
    /// mutation method now calls `commitManifest(&manifest, index: index)` as
    /// its single manifest-write chokepoint, and the old `rewriteManifest()`
    /// (which could not be called safely from `withState`) has been removed.
    func commitManifest(_ manifest: inout Manifest, index: ArchiveIndex) throws {
        let adopting = adoptingDeliveredManifest
        let wasCurrent = indexWasCurrentAtStart
        adoptingDeliveredManifest = false
        indexWasCurrentAtStart = false

        // **Adopting somebody else's manifest: change nothing, decide only.**
        // The manifest on disk came from the machine that made the edit and is
        // the truth here — including its entries for files still in flight. See
        // `adoptingDeliveredManifest` for what recomputing it destroyed.
        if adopting {
            // **Except for the half it is entitled to correct** (slice 50). What
            // arrived is the truth about the files the *sender* wrote; it says
            // nothing about the ones we wrote after its manifest was made, and a
            // provider that had to pick between two manifests dropped exactly
            // those. Merging restores them by selecting between claims that both
            // machines already authored — never by re-hashing — so the rule this
            // branch exists to protect is untouched.
            let stamp = try Self.mergeDeliveredManifest(
                &manifest, index: index, at: rootURL,
                stampedBefore: ManifestWitness.stamp(of: ArchiveLayout.manifestURL(in: rootURL)))
            try Self.recordWitness(
                ManifestWitness.of(manifest, stampedBefore: stamp),
                on: index, at: rootURL, manifest: manifest)
            // An arrival is the event that most often falsifies an abandonment
            // note, and this branch is the only one it comes through.
            pruneStaleAbandonments(against: manifest.files, on: index)
            return
        }

        let previous = manifest.files
        // Stamped before the write, so a manifest that lands underneath us
        // afterwards is not mistaken for the one we wrote.
        var stamp = ManifestWitness.stamp(of: ArchiveLayout.manifestURL(in: rootURL))
        try recomputeManifestFiles(currentManifest: &manifest, index: index)
        // **`previous` is the list the *body* left behind, not the one on disk**,
        // and for one mutation those differ: an abandonment whose file never
        // arrived (slice 50d) removes an entry and mints nothing back, so the
        // recompute reproduces the body's list exactly while `manifest.json`
        // still names the path. Every other mutation writes or re-mints
        // something and so moves the list; this is the only one whose entire
        // effect is a removal that adds nothing. Without the second clause the
        // removal lived in memory until the next `reloadManifest()` threw it
        // away, and the archive stayed wedged (found by
        // `abandoningAnAbsentFileDropsTheEntry`).
        // A manifest this build writes is at this build's version — the archive
        // version is the version of whoever last wrote it. `withState` has already
        // refused a newer one, so this only ever moves a straggler's stamp
        // forward (slice 64, fork g).
        let version = ManifestMerge.schemaVersion(
            delivered: manifest.schemaVersion, ours: SchemaVersion.current)
        if manifest.files != previous || !abandonedThisMutation.isEmpty
            || version != manifest.schemaVersion
        {
            recordWhatThisMutationSuperseded(previous: previous, now: manifest.files, on: index)
            manifest.schemaVersion = version
            manifest.updatedAt = ISO8601DateFormatter().string(from: Date())
            // See `writeManifest` for why the stamp is taken *after* this one
            // write and validated against its length. The residue it documents —
            // a same-length overwrite inside the window — is the conflict case,
            // and slice 50's merge is what now resolves that when it is noticed.
            stamp = try Self.writeManifest(manifest, at: rootURL, noting: index)
        }
        pruneStaleAbandonments(against: manifest.files, on: index)
        // A local write that moved a contested path ends the contest (50e, fork c).
        Self.pruneStaleContests(against: manifest.files, on: index)

        // **The index reflects this manifest, so say so — but only if it did
        // before we started.** A mutation certifies its own work, never somebody
        // else's arrival that nothing has looked at yet; see
        // `indexWasCurrentAtStart`. When it was not current, the recorded witness
        // is left alone, so `indexLooksStale()` still disagrees with the disk and
        // the next reconcile rebuilds.
        //
        // It runs on the unchanged-file-list path too: an archive whose index has
        // no witness yet otherwise stays witnessless through every mutation that
        // happens not to change the list. There the cost is a digest of the
        // in-memory entries plus one `stat` — no walk, no hashing of any file,
        // and (since the digest is unchanged) no row written.
        //
        // **What it costs when the list *did* change, measured rather than
        // asserted** (`/code-review`, slice 60c). The settled entries are then
        // rewritten, which is O(entries) SQL under the archive lock: at 1,000
        // entries **2.1 ms**, at 20,000 **45 ms** — against **1.3 ms** and
        // **21 ms** for writing `manifest.json` itself in the same mutation.
        // Preparing the insert once instead of per row is already in that number
        // and halved it. Accepted rather than optimised further: the alternative
        // storage that writes faster (one blob) reads 6× slower on the in-flight
        // path, and today's real archive has 91 entries. **The escape hatch if a
        // large archive ever makes it bite:** `commitManifest` holds `previous`,
        // and when the marker digest equals the recorded witness the rows are
        // known to describe it — so the delta is computable without reading them
        // back. An option, not a research problem; don't build it on speculation.
        guard wasCurrent else { return }
        try index.setManifestWitness(
            ManifestWitness.of(manifest, stampedBefore: stamp), files: manifest.files)
    }

    /// Notes, per path this mutation changed, **the entry it replaced** — the
    /// evidence a later merge needs that another machine's manifest predates our
    /// write (slice 50; see `ArchiveIndex.supersededFiles()`).
    ///
    /// **Every predecessor is kept, not only the first** (`/code-review`). Keeping
    /// the version a path started from covers a machine editing offline and fails
    /// the moment the two machines exchange anything: once the other machine
    /// adopts our E1 and writes again, its manifest legitimately names E1, and a
    /// local E1→E2 in the meantime must still recognise that as behind us. What
    /// identifies a stale manifest is not the *first* version but **any version we
    /// have moved on from**, so the store is a set per path and this only ever
    /// adds to it.
    ///
    /// It costs one `INSERT OR IGNORE` per path this mutation changed — no read of
    /// the whole set, which is why it is rows and not a blob.
    ///
    /// A path this mutation **created** is deliberately not noted: there is no
    /// entry it replaced, and the arriving manifest cannot name one either, so
    /// there is nothing for the evidence to match. That case keeps slice 49 fork
    /// (f)'s behaviour — an absent entry means *unverified*, and the next
    /// mutation mints it.
    private func recordWhatThisMutationSuperseded(
        previous: [ManifestEntry], now: [ManifestEntry], on index: ArchiveIndex
    ) {
        let after = Dictionary(now.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let replaced = previous.filter { was in
            after[was.path] != was && seen.insert(was.path).inserted
        }
        // **An abandoned entry is not one we superseded** (slice 50d). The
        // difference is the whole point: superseding means *we wrote past this
        // version*, which is what licenses 50's merge to treat an arriving
        // manifest naming it as stale. We never had the abandoned version — we
        // gave up on it — so recording it here would make the genuine delivery,
        // if it ever crossed, look like a manifest that predates us, and 50's
        // merge would discard the very version the user stopped waiting for.
        // That is the difference between *recoverable* and *lost*, and it is
        // what `aVersionThatLandsAfterAnAbandonmentIsStillTakenUp` pins.
        try? index.noteSuperseded(replaced.filter { !abandonedThisMutation.contains($0.path) })

        // **And which of those were removals rather than rewrites** (slice 50b,
        // `/code-review`). A deletion supersedes its entry with *nothing*, and
        // the merge needs to know that positively: reading it off the settled
        // entries instead — a path they do not name — is an absence, and
        // `settled_file` lags arbitrarily while a delivery is stuck, so a record
        // created and edited in that window would qualify without anyone having
        // deleted it. See `ArchiveIndex.deletedPaths()`.
        // **Gated on this mutation's own removals, not on the path leaving the
        // manifest** (`/code-review`). Those are different claims: an entry can
        // fall out because the file was lost out of band and a rebuild took the
        // record with it, or because a `rebaseline` accepted a disk that no
        // longer holds it. Recording either as *we deleted this* arms the drop
        // rule on a path nobody deleted. `authoredRemovals` is the mutation
        // saying so in as many words — and it now covers deliberately removed
        // payload paths as well (`removeArtifact`, `detachFile`), which is what
        // keeps an artifact deletion armed. A mutation whose removal is not
        // noted simply records nothing, which is the pre-50b behaviour: safe.
        let before = Set(previous.map(\.path))
        try? index.noteDeleted(
            paths: replaced.map(\.path).filter {
                after[$0] == nil && authoredRemovals.contains($0)
            })
        // A path authored where there was none is a record that is *back* —
        // created, restored from `.trash/`, or repaired — so its note goes, or a
        // later loss of the new file would read as the old deletion.
        try? index.forgetDeleted(paths: now.map(\.path).filter { !before.contains($0) })

        // **And which of them a human stopped waiting for** (slice 50d), each with
        // the checksum this commit leaves the manifest holding — the empty string
        // where the entry was dropped because nothing had ever arrived. Only the
        // *writing* half lives here: a note goes stale when the entry moves
        // again, and an arrival moves it through a commit path that recomputes
        // nothing, so deciding staleness is left to whoever reads the note
        // against the manifest in front of them (`standingAbandonments`).
        for path in abandonedThisMutation {
            try? index.noteAbandoned(path: path, sha256: after[path]?.sha256 ?? "")
        }
    }

    /// The abandonment notes that still describe `files` — see
    /// `ArchiveIndex.abandonedNotes()`.
    ///
    /// A note stands while the entry it explains is the one standing: the
    /// manifest holds exactly the checksum the abandonment left, or (for one
    /// that dropped the entry) still names no such path. Anything else means the
    /// version landed after all, or the record was edited here, and the entry is
    /// no longer the abandonment's doing.
    func standingAbandonments(against files: [ManifestEntry], on index: ArchiveIndex) -> [String] {
        guard let notes = try? index.abandonedNotes(), !notes.isEmpty else { return [] }
        let entries = Self.entryHashes(files)
        return notes.filter { Self.noteStands($0.value, against: entries[$0.key]) }
            .keys.sorted()
    }

    /// **Deletes the notes that have stopped standing**, rather than leaving them
    /// to be filtered out on every read.
    ///
    /// Filtering alone is not enough, and the difference is a **resurrection**
    /// (`/code-review`): a note whose entry was dropped records the empty string,
    /// so it stops standing when the version lands and the entry reappears — and
    /// stands *again*, permanently, the moment anything removes that entry later,
    /// such as the user deleting the record. The archive then claims a decision
    /// nobody made about a version nobody is waiting for. A note is only ever
    /// true of one manifest, so it is dropped the first time it stops describing
    /// one.
    ///
    /// Called from **both** of `commitManifest`'s paths, because the event that
    /// most often falsifies a note is an *arrival*, which is adopted through the
    /// delivered-manifest branch and recomputes nothing.
    func pruneStaleAbandonments(against files: [ManifestEntry], on index: ArchiveIndex) {
        guard let notes = try? index.abandonedNotes(), !notes.isEmpty else { return }
        let entries = Self.entryHashes(files)
        let stale = notes.filter { path, sha256 in
            // This mutation's own notes were written from this very list, so
            // they stand by construction; excluding them keeps that true even if
            // that ever stops being obvious.
            !abandonedThisMutation.contains(path)
                && !Self.noteStands(sha256, against: entries[path])
        }
        try? index.forgetAbandoned(paths: Array(stale.keys))
    }

    private static func entryHashes(_ files: [ManifestEntry]) -> [String: String] {
        Dictionary(files.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
    }

    /// The one rule both readers above apply: the empty string means *the
    /// abandonment dropped the entry*, and stands exactly while nothing has
    /// taken its place.
    private static func noteStands(_ sha256: String, against entry: String?) -> Bool {
        entry == (sha256.isEmpty ? nil : sha256)
    }

    /// See `create(at:)` — the one place a witness is recorded without a prior
    /// match, because there is nothing yet for the index to be behind.
    private func recordWitnessForFreshArchive() {
        lock.lock()
        defer { lock.unlock() }
        let manifestURL = ArchiveLayout.manifestURL(in: rootURL)
        // Read back rather than digesting `self.manifest`, keeping `read`'s
        // stamp-then-read ordering — and taking the **entries from the same
        // read**, so the digest and the settled rows cannot describe two
        // different manifests (slice 60c).
        guard let (witness, files) = ManifestWitness.readWithFiles(from: manifestURL) else {
            return
        }
        try? index.setManifestWitness(witness, files: files)
    }

    /// What the recorded witness says about `manifest.json` as it is on disk
    /// right now — the same two-stage gate `indexLooksStale()` uses, answered in
    /// full rather than as a bool (slice 60b). Every consumer switches on this;
    /// `WitnessState` says why there are three answers and not two.
    private func witnessState() -> WitnessState {
        lock.lock()
        defer { lock.unlock() }
        return witnessStateLocked()
    }

    /// The same, for callers already holding `lock` — `withState`'s body and the
    /// drift guard both run inside it, and `lock` is not recursive.
    private func witnessStateLocked() -> WitnessState {
        witnessComparisonLocked().state
    }

    /// The same comparison, plus the fact `deliveryCoverage` would otherwise
    /// recompute: **whether `manifest.json` was actually read**, which is what
    /// separates the two shapes of `.disagrees`.
    ///
    /// Folded in here rather than answered by a second decode of the same file
    /// (`/code-review`): the sweep asks this once a second while a delivery is in
    /// flight, and every decode is lock-held.
    private func witnessComparisonLocked() -> (state: WitnessState, readTheManifest: Bool) {
        let manifestURL = ArchiveLayout.manifestURL(in: rootURL)
        guard let recorded = (try? index.manifestWitness()) ?? nil else {
            return (.unknown, false)
        }
        if recorded.stampMatches(manifestURL) { return (.matches, false) }
        // **A manifest we hold a witness for but cannot read is `.disagrees`, not
        // `.unknown`** (slice 60b, `/code-review`). `.unknown` means *this index
        // has never settled anything*, and everything that consumes it says so to
        // the user — `recordDriftedWithNoHistory` in as many words. Here there is
        // a settled witness, so that claim would be false; and the file being
        // unreadable is itself evidence of an outside write, since `AtomicIO`
        // renames a complete, decodable manifest into place and this engine
        // therefore never leaves one in that state.
        //
        // It also keeps this case behaving exactly as it did before the slice,
        // which is the point: 60b's subject is the *no-witness* case, and every
        // other path through here should be untouched.
        //
        // **Residue, stated rather than implied:** a `manifest.json` that is
        // genuinely corrupt, rather than mid-write, reads as a delivery for as
        // long as a handle stays open. That is the call slice 60 already made and
        // rests on the same asymmetry (corruption does not touch
        // `manifest.json`), and it cannot outlive the handle — `open()` refuses
        // the archive outright with `corruptManifest`.
        guard let onDisk = ManifestWitness.read(from: manifestURL) else {
            return (.disagrees, false)
        }
        return (recorded.describesSameFiles(as: onDisk) ? .matches : .disagrees, true)
    }

    /// Recomputes `manifest.files` and assigns it to `manifest`. This defines
    /// **scope**: every file an artifact's `record.json` says belongs to it, plus
    /// every file the engine itself authors — each `artifacts/<slug>/record.json`
    /// and every `conclusions/**` record — plus the self-describing schema copy.
    /// Excluded: `manifest.json` (it cannot list itself), `.index/` and `.trash/`
    /// (reserved, non-authoritative, and outside every pass; spec §2).
    ///
    /// **The list is half derived and half carried forward (slice 49, fork a),
    /// and the difference is the whole point.**
    ///
    /// A *payload* entry is derived: its authoritative checksum was authored into
    /// `record.json` at attach time and is only copied through here, so
    /// re-deriving it every commit can never launder corruption — nothing
    /// re-reads the file. An *authored* entry has no second copy of its hash
    /// anywhere, so the same treatment would erase exactly what it exists to
    /// preserve: bit rot in a `record.json` would be re-hashed, written into the
    /// manifest, and verify clean forever after. Hence the rule:
    ///
    /// - **present entry → carried forward verbatim, never re-hashed;**
    /// - **absent entry → minted from disk** (a record restored from the trash,
    ///   an artifact re-slugged, or an archive written before this slice);
    /// - **written during this mutation → minted from the bytes we wrote**
    ///   (`writeAuthoredJSON`), which is what keeps a legitimate edit from
    ///   reporting as corruption without costing a re-read.
    ///
    /// Deletions and renames need no bookkeeping of their own because the
    /// authored set is enumerated from the index each time: a record that is gone
    /// contributes no path, so its entry simply isn't carried.
    ///
    /// **That shortcut reads "absent from the index" as "deleted", and since
    /// slice 55 there is a third state (review finding, 55): a record that is
    /// still on disk but could not be decoded, and so was skipped by the
    /// rebuild.** Left alone, such a record — and, for an artifact, every payload
    /// file it claims — silently lost its manifest coverage on the next mutation,
    /// and got a *fresh* baseline minted the moment the file decoded again, which
    /// is precisely the laundering the carry-forward rule exists to prevent:
    /// corrupt-then-repair became a way to substitute a record's contents without
    /// `verifyIntegrity()` ever reporting it, bypassing `rebaseline()`'s
    /// only-when-a-human-asks gate. So the rule is completed here:
    ///
    /// - **a record the index cannot see keeps whatever coverage the manifest
    ///   already had** — its own entry, and for an artifact every entry under its
    ///   folder, carried forward verbatim like any other present entry.
    ///
    /// **"Cannot see" includes a record whose sidecar vanished** (slice 58c). A
    /// rebuild after a Finder delete or a dropped sync leaves it no row, so with
    /// a settled witness the next unrelated write read it as a deletion: its
    /// entry went, its `missingFile` finding went with it, and — since 58c reads
    /// a dropped entry as exactly that — so did its preserved copy at the next
    /// rebuild. A record with a preserved copy is therefore carried exactly like
    /// an unreadable one, payload included. **The copy is the evidence, and a
    /// deliberately narrow one:** it exists only while the record's uid is live
    /// nowhere, so a hand-renamed folder (live under its new name) still lets
    /// its old path go, where carrying every vanished path would not. A vanished
    /// file with no copy — a recreated index has none — still loses its entry,
    /// as before this slice.
    ///
    /// **A removal cut between its unlink and its manifest commit leaves the same
    /// state**, and must still end in the deletion (`removeAuthoredFile`): the
    /// crash-recovery rebuild discards the copy of each file the died write's
    /// journal says it unlinked (`ArchiveIndex.rebuild(unlinkedByDiedWrite:)`),
    /// so the cut record has none and is not carried. Every other copy — a loss
    /// before the crash, or out of band beside it — is untouched (slice 69,
    /// fork c). (The first fix switched the carry off for every
    /// record while any interrupted write was unresolved, which let one died
    /// write cost every long-standing copy its entry, and then the copy itself —
    /// second `/code-review`.)
    func recomputeManifestFiles(currentManifest: inout Manifest, index: ArchiveIndex) throws {
        let unreadable = try index.unreadableRecordPaths()
        let unseen =
            try unreadable
            + vanishedRecordPaths(
                index: index, named: currentManifest.files, unreadable: Set(unreadable))
        var entries = try payloadEntries(index: index)
        entries += carriedPayloadEntries(
            forUnreadable: unseen, carriedFrom: currentManifest.files,
            excluding: Set(entries.map(\.path)))
        entries += try authoredEntries(
            index: index, unreadable: unseen, carriedFrom: currentManifest.files)
        currentManifest.files = entries.sorted { $0.path < $1.path }
    }

    /// The preserved copies the manifest still names whose file is **not** one
    /// the walk found unreadable — records whose sidecar vanished (58c; see
    /// `recomputeManifestFiles`). Carried, never minted: the manifest already has
    /// each entry, and there is nothing on disk to hash. Not probed: a copy whose
    /// file came back readable belongs to a record the index names again, and
    /// `authoredEntries` dedupes it.
    private func vanishedRecordPaths(
        index: ArchiveIndex, named entries: [ManifestEntry], unreadable: Set<String>
    ) throws -> [String] {
        let preserved = try index.preservedRecordPaths()
        guard !preserved.isEmpty else { return [] }
        let named = Set(entries.lazy.map(\.path))
        return preserved.filter { named.contains($0) && !unreadable.contains($0) }
    }

    /// The payload entries of an artifact whose `record.json` the rebuild had to
    /// skip. They cannot be derived — `payloadEntries` reads the index's `file`
    /// projection, and an artifact that failed to decode has no rows there — so
    /// the manifest's existing entries for that folder are carried forward
    /// instead. Without this, one unreadable record quietly drops its
    /// preservation masters out of the integrity surface, and rot in them stops
    /// being reported at all (review finding, 55).
    private func carriedPayloadEntries(
        forUnreadable unreadable: [String],
        carriedFrom previous: [ManifestEntry],
        excluding derived: Set<String>
    ) -> [ManifestEntry] {
        let folders = unreadable.compactMap { path -> String? in
            guard path.hasPrefix("\(ArchiveLayout.artifactsDirectoryName)/"),
                path.hasSuffix("/\(ArchiveLayout.recordFileName)")
            else { return nil }
            return String(path.dropLast(ArchiveLayout.recordFileName.count))
        }
        guard !folders.isEmpty else { return [] }

        return previous.filter { entry in
            !derived.contains(entry.path)
                && !ArchiveLayout.isEngineAuthored(relativePath: entry.path)
                && folders.contains { entry.path.hasPrefix($0) }
        }
    }

    /// The files each artifact's `record.json` claims, with the checksums that
    /// record authored — derived fresh every commit, never re-hashed from disk
    /// (see `recomputeManifestFiles`).
    ///
    /// Read from the index's `file` projection rather than by decoding each
    /// artifact, which is the same data one JSON parse cheaper per artifact per
    /// mutation (review finding, 49 — see `ArchiveIndex.schemaVersion` v5).
    private func payloadEntries(index: ArchiveIndex) throws -> [ManifestEntry] {
        try index.allPayloadFiles().map { file in
            let fileURL = ArchiveLayout.artifactDirectory(in: rootURL, slug: file.slug)
                .appendingPathComponent(file.path)
            return ManifestEntry(
                path: ArchiveLayout.relativePath(of: fileURL, in: rootURL),
                sha256: file.sha256,
                byteLength: file.byteLength
            )
        }
    }

    /// One entry per engine-authored file, applying the carry-forward rule in
    /// `recomputeManifestFiles`. A path with no entry to carry and no readable
    /// file on disk contributes nothing — a record whose sidecar has vanished
    /// (and that therefore has no baseline to compare against) is reported by
    /// `findDanglingReferences()`/`rebuildIndex()`, not invented here.
    private func authoredEntries(
        index: ArchiveIndex, unreadable: [String], carriedFrom previous: [ManifestEntry]
    ) throws
        -> [ManifestEntry]
    {
        let carried = Dictionary(
            previous.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in
                first
            })
        var entries: [ManifestEntry] = []
        // A skipped record contributes no path from the index, so it is named
        // here explicitly — otherwise its entry is dropped and re-minted on
        // repair (review finding, 55; see `recomputeManifestFiles`). So is a
        // record that vanished and left a preserved copy (58c).
        var seen = Set<String>()
        let paths =
            try authoredPaths(index: index) + unreadable + awaitedPaths(carriedFrom: previous)
        for path in paths where seen.insert(path).inserted {
            if let fresh = authoredWrites[path] {
                // A path removed and then written again in the same mutation is a
                // write — checked first, so the removal note below cannot swallow
                // it (`authoredRemovals`).
                entries.append(fresh)
            } else if authoredRemovals.contains(path) {
                // **This mutation deliberately removed it, so it gets no entry**,
                // whichever list named it (slice 60b, `/code-review`). Filtered
                // here rather than inside `awaitedPaths` so the rule holds for
                // every source of a path, not just the one that surfaced it.
                continue
            } else if let existing = carried[path] {
                entries.append(existing)
            } else if let minted = mintEntry(at: path) {
                entries.append(minted)
            }
        }
        return entries
    }

    /// Engine-authored paths the manifest names but **nothing on disk has yet
    /// delivered** — named explicitly so an ordinary mutation cannot drop them
    /// (slice 60, second `/code-review`).
    ///
    /// **The same shape as 55's rule for unreadable records, for the same
    /// reason.** `authoredPaths` reads the index, and a record that has not
    /// arrived is not in the index, so it contributes no path and its entry falls
    /// out of the recompute. That is correct for a *deletion* and catastrophic for
    /// a *delivery*: the manifest is the only thing that says the file is
    /// expected, so dropping the entry makes the rewritten manifest look complete,
    /// lets the next reconcile settle it, and loses the record for good when it
    /// finally lands — the outcome `manifestDeliveryLooksComplete` calls worse
    /// than the bug this slice fixes.
    ///
    /// **Gated on the witness positively matching the disk**, so ordinary
    /// deletion is untouched: with a settled witness that describes this
    /// manifest, a path the index no longer knows is a record that was removed,
    /// and its entry goes. Anything less than that — the manifest is one we have
    /// not accounted for, or there is no witness at all — and an unknown path
    /// means "not here *yet*".
    ///
    /// Absent from disk is the whole test — a path that is *present* but not in
    /// the index is an unreadable record, which `unreadable` already covers.
    private func awaitedPaths(carriedFrom previous: [ManifestEntry]) -> [String] {
        // **The other direction of fork (b)'s asymmetry** (slice 60b): unknown
        // belongs on *this* side of the split, with `.disagrees`. Here a false
        // *not*-arriving does not mislead, it **destroys** — the manifest is the
        // only document that says an un-arrived file is expected, so treating
        // unknown as settled lets one unrelated mutation scrub those entries and
        // lose the record for good when it finally lands. That is 60's
        // manifest-scrubbing data loss, walking back in through the unknown door.
        // Only `.matches` — a witness that positively describes this manifest —
        // licenses reading an absent path as a deletion.
        guard witnessStateLocked() != .matches else { return [] }
        return previous.lazy
            .map(\.path)
            .filter { ArchiveLayout.isEngineAuthored(relativePath: $0) }
            .filter {
                !FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent($0).path)
            }
    }

    /// Hashes the file at `path` to establish a baseline for it. `nil` when there
    /// is nothing readable there.
    private func mintEntry(at path: String) -> ManifestEntry? {
        let url = rootURL.appendingPathComponent(path)
        guard let sha256 = try? Checksum.sha256Hex(ofFileAt: url),
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size]
                as? NSNumber
        else { return nil }
        return ManifestEntry(path: path, sha256: sha256, byteLength: size.int64Value)
    }

    /// Every path the engine authors, named from the index rather than by walking
    /// the archive — the walk would cost a full directory enumeration per
    /// mutation to learn what the index already knows.
    private func authoredPaths(index: ArchiveIndex) throws -> [String] {
        var paths: [String] = []
        for slug in try index.allSlugs().values.sorted() {
            paths.append(
                ArchiveLayout.relativePath(
                    of: ArchiveLayout.recordURL(in: rootURL, slug: slug), in: rootURL))
        }

        let conclusions = try index.allConclusionUIDs()
        func add(_ uids: [String], under directory: String) {
            paths += uids.sorted().map { "\(directory)/\($0).json" }
        }
        add(conclusions.persons, under: ArchiveLayout.personsDirectoryRelativePath)
        add(conclusions.relationships, under: ArchiveLayout.relationshipsDirectoryRelativePath)
        add(conclusions.links, under: ArchiveLayout.linksDirectoryRelativePath)
        add(conclusions.dismissals, under: ArchiveLayout.dismissalsDirectoryRelativePath)

        // The archive's copy of the format spec (ARCHITECTURE §3, "the schema
        // spec travels with the archive"). It follows the same carry-forward rule
        // as everything else authored: a future GeneaLogic that ships a revised
        // spec must replace the entry when it replaces the file — through the
        // migration pipeline, which is where such a change lands — or verify will
        // say so out loud, which is the safe direction to fail.
        paths.append("\(ArchiveLayout.schemaDirectoryName)/\(ArchiveLayout.schemaSpecFileName)")
        return paths
    }
}

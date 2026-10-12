import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An **archive-level advisory lock** — `flock(2)` on `.index/lock` — held for
/// the duration of one whole mutation, so two GeneaLogic *processes* on one
/// machine (the classic case: the Mac app open on an archive while an agent
/// drives `genea` at it) take turns instead of racing.
///
/// **Why archive-level and not per-record (slice 47, fork b):** every mutation
/// ends in `commitManifest`, which is archive-wide, so per-artifact locks would
/// serialize there anyway — while adding a lock-ordering problem. Mutations are
/// milliseconds; whole-archive exclusion costs nothing real.
///
/// **Why `flock(2)` and not `fcntl(F_SETLK)`:** `flock` locks are owned by the
/// *open file description*, so the lock is released when the descriptor closes
/// (including on crash), and two descriptors in the same process contend with
/// each other exactly as two processes do — which is what makes this testable
/// in-process. `fcntl` locks are per-(process, inode) and are silently dropped
/// by *any* `close()` of the same file, which is a footgun here.
///
/// **Readers do not take this lock (fork e).** SQLite already gives
/// committed-read consistency across processes, and a shared lock on every
/// lookup would make browsing contend with the agent's writes for no
/// correctness gain. The documented consequence: a read concurrent with a
/// mutation may observe the pre-mutation state — stale, never torn, and bounded
/// by that mutation's duration.
///
/// **Scope, stated plainly:** `flock(2)` is unreliable on network filesystems
/// and cannot serialize two *machines* against a cloud-synced folder. This type
/// makes one machine safe; cross-machine sync is ARCHITECTURE.md §10.5's
/// remaining half.
///
/// **Two consequences worth knowing rather than rediscovering:**
///
/// - The lockfile is opened `O_RDWR`, so opening an archive on a *read-only*
///   volume now fails with `lockUnavailable` where it might previously have
///   opened for browsing. That is not a supported case anyway — the engine is
///   edit-in-place, and `Archive.open` may rebuild the index, which also writes
///   — so it is left as a clean failure rather than a partial-capability mode.
/// - `Archive.open` holds this lock across a full index rebuild, which on a
///   large archive can exceed `timeout`. A second process opening at that exact
///   moment gets `archiveBusy` and can simply retry. Serializing the rebuild is
///   the point; two processes rebuilding one index concurrently is the failure.
final class ArchiveLock {
    /// How long `withLock` waits for a competing process before giving up
    /// (slice 47, fork d: block, then fail loudly — never block forever, which
    /// would hang the app's main actor). Settable so tests don't have to wait
    /// out the production value; production never changes it.
    var timeout: TimeInterval = 5

    /// The lockfile itself. Kept open for the owning `Archive`'s whole lifetime:
    /// `flock` ownership follows the descriptor, so re-opening per mutation
    /// would be both slower and — if the file were ever replaced underneath us —
    /// wrong.
    private let url: URL

    /// The archive this lock belongs to, carried rather than derived.
    ///
    /// It used to be reconstructed by climbing two directories up from `url`,
    /// which was correct for exactly as long as the lockfile sat directly in
    /// `.index/`. Slice 48 moved it to `.index/<machine-key>/lock` and that
    /// climb started reporting `.index/` as the busy archive — a silent wrong
    /// answer in an error message, which is the same class of assumption
    /// `ArchiveLayout` exists to keep in one place. Every caller already holds
    /// the root, so it is passed in and the assumption is gone rather than
    /// re-tuned.
    private let archiveRoot: URL

    private let descriptor: Int32

    /// How many threads are currently *waiting* for this lock — retrying because
    /// another process holds it.
    ///
    /// Diagnostic only; the lock itself is `flock`'s. It exists so the app can
    /// tell a slow write apart from a *blocked* one: without it, an indicator can
    /// only measure elapsed time, and a 20-file ingest or an index rebuild would
    /// announce "another process is writing" when nothing else is running (52's
    /// `/code-review`).
    private let waiting = Mutex(0)

    /// Whether some thread is blocked waiting for another process to let go.
    /// Takes no lock of the archive's, so it is safe to read from the main actor
    /// while a mutation is parked.
    var isContended: Bool { waiting.withLock { $0 > 0 } }

    /// Opens (creating if absent) the lockfile at `url`. Never truncates: two
    /// processes racing here must end up on the *same inode*, or they would
    /// happily lock different files and both proceed.
    init(at url: URL, archiveRoot: URL) throws {
        self.url = url
        self.archiveRoot = archiveRoot
        let fd = url.path.withCString { open($0, O_RDWR | O_CREAT, 0o644) }
        guard fd >= 0 else {
            throw ArchiveError.lockUnavailable(
                url, underlying: String(cString: strerror(errno)))
        }
        self.descriptor = fd
    }

    deinit {
        close(descriptor)
    }

    /// Runs `body` holding the exclusive archive lock, releasing it on every path.
    ///
    /// **Not re-entrant, and not thread-safe against itself.** `flock` itself
    /// tolerates a second `LOCK_EX` on a descriptor it already owns, but this
    /// method's scoped `release()` does not: a second holder's `defer` would drop
    /// the lock while the first still believes it holds it. Because the lock is
    /// owned by the *file description*, that applies to two threads of one
    /// process just as much as to nesting on one thread — they share this
    /// descriptor, so both would sail through `acquire()`.
    ///
    /// Both are prevented structurally rather than detected: every mutation
    /// enters through `Archive.withState`, which takes the non-recursive
    /// `writerLock` first. That is what admits exactly one in-process writer at a
    /// time, which is the precondition this type is written against (before 52
    /// the same job was done by `Archive.lock`, taken in the same position).
    /// `Archive.create` is the one place that had to be written around this
    /// explicitly; see its comment.
    ///
    /// - Throws: `ArchiveError.archiveBusy` if another process still holds the
    ///   lock after `timeout` — carrying its pid where the lockfile records one,
    ///   so the app can say *"another process is writing this archive"* rather
    ///   than surfacing a generic failure.
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try acquire()
        defer { release() }
        return try body()
    }

    private func acquire() throws {
        // Polling rather than a blocking `flock(LOCK_EX)`: a blocking call has no
        // portable timeout (interrupting it needs a signal), and fork (d) requires
        // giving up rather than hanging. Uncontended acquisition still costs one
        // non-blocking syscall — the poll only happens when there is a competitor.
        var delayMicroseconds: UInt32 = 2_000
        let deadline = Date().addingTimeInterval(timeout)
        // Counted only once we have actually failed an attempt, and released on
        // every exit — acquired *or* thrown. An uncontended acquisition never
        // touches it, so `isContended` means what it says.
        var counted = false
        defer { if counted { waiting.withLock { $0 -= 1 } } }

        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                recordHolder()
                return
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                throw ArchiveError.lockUnavailable(
                    url, underlying: String(cString: strerror(code)))
            }
            if !counted {
                waiting.withLock { $0 += 1 }
                counted = true
            }
            guard Date() < deadline else {
                throw ArchiveError.archiveBusy(archiveRoot, holderPID: holderPID())
            }
            // Backoff capped low on purpose: `flock` grants have no fairness
            // guarantee, so a waiter that backs off to tens of milliseconds can
            // be repeatedly beaten by short-lived processes that call `flock`
            // fresh — an agent looping `genea` against an archive the app has
            // open is exactly that shape. 10ms keeps the retry rate high enough
            // to compete while costing nothing measurable in syscalls.
            usleep(delayMicroseconds)
            delayMicroseconds = min(delayMicroseconds * 2, 10_000)
        }
    }

    private func release() {
        _ = flock(descriptor, LOCK_UN)
    }

    /// Stamps our pid into the lockfile so a *blocked* process can name the
    /// holder. Best-effort and purely diagnostic — the lock itself is `flock`'s,
    /// never this content, so a failed write costs a better error message and
    /// nothing else.
    private func recordHolder() {
        let stamp = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = lseek(descriptor, 0, SEEK_SET)
        _ = stamp.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
    }

    /// The pid recorded by whoever holds the lock, if it is readable and parses.
    /// `nil` is a normal answer (a lockfile from an older build, a truncated
    /// write), which is why `archiveBusy` carries an optional.
    private func holderPID() -> Int32? {
        guard let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

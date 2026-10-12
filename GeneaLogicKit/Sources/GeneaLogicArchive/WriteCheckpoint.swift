import Foundation
import Synchronization

/// The crash-cut seam (slice 65, fork a): every on-disk transition a mutation
/// makes reports itself here, so a test can photograph the archive at each one
/// and open the photograph as the archive a crash at that instant would leave.
///
/// **An observer, never a thrower.** A thrown error runs the engine's own
/// cleanup — `AtomicIO` removes its temp, `withState`'s catch clears the
/// sentinel when nothing was authored — which a crash never does, and that
/// error path is already what 47's and 58's tests exercise. So a hook here can
/// look and copy, and the mutation carries on regardless.
///
/// **What fires:** a temp file written, renamed into place, an item moved, an
/// item unlinked, each SQL statement that can write, the dirty marker set, and
/// the instant before it is cleared. A transition with no checkpoint is a cut
/// the property cannot see, so a new write primitive must report here too.
///
/// **Scoped by archive root**, not global: tests run in parallel, and each
/// registers the one archive it is cutting. The production cost is one mutex
/// acquisition and an empty-dictionary check per file operation.
///
/// **Known residue, documented rather than swept:** a crash between
/// `AtomicIO`'s temp write and its rename leaves `.<name>.tmp-<uuid>` beside the
/// destination. It is hidden, so every walk skips it, and sweeping it would
/// need every writer to hold the archive lock, which `Archive.create` does not.
enum WriteCheckpoint {
    typealias Hook = @Sendable (_ event: String, _ url: URL) -> Void

    private static let hooks = Mutex<[String: Hook]>([:])

    /// Reports a transition at `url`. Calls every hook whose registered root
    /// contains `url`; does nothing when none is registered.
    static func reached(_ event: String, at url: URL) {
        let matching = hooks.withLock { hooks -> [Hook] in
            // Before anything else: production never registers a hook, and this
            // runs on every SQL step of a rebuild.
            guard !hooks.isEmpty else { return [] }
            let path = url.standardizedFileURL.path
            return hooks.compactMap { root, hook in
                path == root || path.hasPrefix(root + "/") ? hook : nil
            }
        }
        for hook in matching { hook(event, url) }
    }

    /// Registers `hook` for every transition under `root` until `remove(root:)`.
    static func install(root: URL, _ hook: @escaping Hook) {
        let key = root.standardizedFileURL.path
        hooks.withLock { $0[key] = hook }
    }

    static func remove(root: URL) {
        let key = root.standardizedFileURL.path
        _ = hooks.withLock { $0.removeValue(forKey: key) }
    }
}

/// The probe-failure seam (slice 69, fork b): a test makes one of the checks
/// `ArchiveIndex.openExisting` runs on an existing index throw, as an `IOERR`
/// or an eviction mid-scan would, without needing a disk that fails.
///
/// **A thrower, unlike `WriteCheckpoint`**, because what is under test is the
/// open's answer to a probe that could not run. Scoped by database path, so
/// parallel tests do not see each other's faults; the production cost is one
/// mutex acquisition and an empty-dictionary check per probe, four per open.
enum IndexProbeFault {
    enum Probe: Sendable { case open, userVersion, quickCheck, schema }
    typealias Hook = @Sendable (Probe) throws -> Void

    private static let hooks = Mutex<[String: Hook]>([:])

    static func check(_ probe: Probe, at url: URL) throws {
        let hook = hooks.withLock { hooks -> Hook? in
            guard !hooks.isEmpty else { return nil }
            return hooks[url.standardizedFileURL.path]
        }
        try hook?(probe)
    }

    /// Runs `hook` before each probe of the database at `url` until `remove(at:)`.
    static func install(at url: URL, _ hook: @escaping Hook) {
        let key = url.standardizedFileURL.path
        hooks.withLock { $0[key] = hook }
    }

    static func remove(at url: URL) {
        let key = url.standardizedFileURL.path
        _ = hooks.withLock { $0.removeValue(forKey: key) }
    }
}

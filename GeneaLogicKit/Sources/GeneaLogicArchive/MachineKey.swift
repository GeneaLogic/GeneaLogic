import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// **Which machine this is** — the key that gives every machine its own private
/// `.index/<machine-key>/` inside one shared archive (slice 48).
///
/// `.index/` lives inside the package for locality (ARCHITECTURE.md §3), which
/// means a sync provider replicates it like everything else. With one shared
/// `index.sqlite`, `lock` and `dirty`, two machines write the same three files:
/// the provider has to reconcile a live SQLite database it cannot understand,
/// every handoff destroys the receiving machine's warm cache, and conflicted
/// copies accumulate beside it. Slice 60 made the resulting *staleness*
/// detectable; it did nothing about the collision. A per-machine subdirectory
/// removes it outright — no two machines ever write one file — and each machine
/// keeps its index across handoffs instead of rebuilding.
///
/// **What identifies a machine: the boot volume's UUID**, falling back to
/// `/etc/machine-id` and then to `gethostname()`. Chosen over the alternatives for one reason that outranks
/// the others: the sandboxed app and the unsandboxed `genea` must compute the
/// *same* key, or 47's `flock(2)` stops excluding — two writers on one machine
/// with no arbiter, which is worse than not having the lock at all. That is
/// exactly how `.applicationSupportDirectory` failed when it was the leading
/// candidate for where `.index/` should live. Measured before this was built
/// (2026-08-23): an ad-hoc-signed sandboxed bundle and the plain CLI read the
/// same `volumeUUIDString` for `/`, so this derivation does not repeat that
/// failure. The volume UUID is preferred over the hostname because it survives
/// a machine rename and a reboot — `gethostname()` here returns the mDNS-shaped
/// `Studiobook.local`, which the network can change underneath us.
///
/// **The fallback is announced, not silent** (review finding, 48). The residual
/// risk in this derivation is not that it fails but that it fails *for one
/// process and not the other*: a `vol-` key in the CLI and a `host-` key in the
/// app is two lockfiles, and 47's exclusion is gone with no symptom until two
/// writes collide. So `derivation` is public, the prefix records it on disk, and
/// `genea` says so on stderr whenever it lands on `hostName` — which on Darwin
/// means the volume UUID was unreadable and is therefore worth reading as a
/// warning rather than a detail. The Mac app has no equivalent notice yet; that
/// gap is recorded in slice 48's spec.
///
/// **The archive's *own* volume was rejected**, though it needs no `/` access at
/// all: an archive on a portable drive carried between two machines would give
/// both the same key, silently putting them back on one index.
///
/// **The value is hashed, not written verbatim.** The key is a path component,
/// so a verbatim one makes whatever produced it — including the environment
/// override below — a directory name, with the traversal that implies. Hashing
/// means the input never reaches the filesystem, which is what lets the override
/// skip a charset allow-list rather than depend on one being airtight. It also
/// keeps a hostname out of an archive that may be shared. **The derivation is
/// kept in the clear as a prefix** (`vol-`/`host-`/`test-`) because the failure
/// worth diagnosing at a glance is the app resolving one way and the CLI the
/// other: two directories whose prefixes differ say that immediately, while the
/// value stays opaque.
public enum MachineKey {
    /// The environment variable that forces a key.
    ///
    /// **A testing seam, not configuration** — hence the name. `scripts/deliver.sh`
    /// stands up two "machines" as two directories on one real machine, and
    /// without this they would derive the same key and the rig could not
    /// exercise the thing this slice exists for. It reaches the filesystem only
    /// through the hash, so a value cannot escape `.index/`; what it *can* do is
    /// point one process at a different `lock` from another, which is why the
    /// CLI announces it on stderr whenever it is set.
    public static let overrideEnvironmentVariable = "GENEALOGIC_TEST_MACHINE_KEY"

    /// Where `current` got its value. Public because the two weak derivations
    /// have to be *announceable*: a silent fallback is how one process ends up on
    /// a different lockfile from another (see `hostName`).
    public enum Derivation: String, Sendable {
        /// `overrideEnvironmentVariable` was set.
        case override

        /// The boot volume's UUID — the expected answer on Darwin.
        case volumeUUID

        /// `/etc/machine-id`, the Linux analogue: per-installation and stable
        /// across renames and reboots, which is the property the volume UUID was
        /// chosen for.
        case machineID

        /// `gethostname()` — the last resort, and the one worth saying out loud.
        /// It is unstable by nature: macOS rewrites it from mDNS, and a container
        /// gets a fresh one per run, so a machine that lands here starts a new
        /// index every time its name changes. **On Darwin it also means the boot
        /// volume's UUID was unreadable**, which is the shape of the failure that
        /// would put the sandboxed app and the CLI on different keys.
        case hostName
    }

    /// This process's key, resolved **once**.
    ///
    /// Frozen for the process lifetime deliberately: a `setenv` from another
    /// thread would otherwise let one process resolve two different lock paths
    /// during its own lifetime, which is the single-process form of the
    /// divergence this whole derivation is built to avoid.
    public static var current: String { resolved.key }

    /// Whether `current` came from `overrideEnvironmentVariable`. Frozen with it.
    public static var isOverridden: Bool { resolved.derivation == .override }

    /// Where `current` came from. Frozen with it.
    public static var derivation: Derivation { resolved.derivation }

    private struct Resolved: Sendable {
        let key: String
        let derivation: Derivation
    }

    private static let resolved: Resolved = {
        let (key, derivation) = keyAndDerivation(
            override: ProcessInfo.processInfo.environment[overrideEnvironmentVariable],
            volumeUUID: bootVolumeUUID(),
            machineID: machineID(),
            hostName: hostName())
        return Resolved(key: key, derivation: derivation)
    }()

    /// The derivation itself, with every input injected — pure, and the form the
    /// tests drive, since `current` is frozen and cannot be re-resolved in-process.
    static func keyAndDerivation(
        override raw: String? = nil, volumeUUID: String? = nil, machineID: String? = nil,
        hostName: String
    ) -> (key: String, derivation: Derivation) {
        if let override = normalized(raw) { return (name("test", override), .override) }
        if let volumeUUID = normalized(volumeUUID) { return (name("vol", volumeUUID), .volumeUUID) }
        if let machineID = normalized(machineID) { return (name("mid", machineID), .machineID) }
        return (name("host", hostName), .hostName)
    }

    /// Convenience for the tests that only care about the key.
    static func key(
        override raw: String? = nil, volumeUUID: String? = nil, machineID: String? = nil,
        hostName: String
    ) -> String {
        keyAndDerivation(
            override: raw, volumeUUID: volumeUUID, machineID: machineID, hostName: hostName
        ).key
    }

    /// `<source>-<16 hex>`: SHA-256 over a **source-tagged** string, so a
    /// hostname that happens to look like a volume UUID cannot collide with one.
    private static func name(_ source: String, _ value: String) -> String {
        let digest = Checksum.sha256Hex(of: Data("\(source):\(value)".utf8))
        return "\(source)-\(digest.prefix(16))"
    }

    /// An override that is present but empty (or only whitespace) reads as
    /// *unset*, never as a key: an exported-but-empty variable is a mistake, and
    /// honoring it would hand two machines the same key by accident.
    ///
    /// This is the **only** validation the override gets, and that is a
    /// consequence of hashing rather than an omission: the value never becomes a
    /// path component, so there is no traversal to screen for and a charset
    /// allow-list would be checking something that cannot reach the filesystem.
    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func bootVolumeUUID() -> String? {
        let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString
    }

    /// `/etc/machine-id`, with systemd's documented pre-boot fallback location.
    /// Read on every platform rather than gated on `#if os(Linux)`: absence is
    /// already the "try the next thing" answer, and a gate would be one more
    /// place for the two processes on one machine to disagree.
    private static func machineID() -> String? {
        for path in ["/etc/machine-id", "/var/lib/dbus/machine-id"] {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
                let id = normalized(contents)
            {
                return id
            }
        }
        return nil
    }

    private static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
}

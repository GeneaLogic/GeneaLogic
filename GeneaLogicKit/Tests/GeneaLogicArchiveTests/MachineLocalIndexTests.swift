import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// **The index is machine-local** (slice 48): `.index/<machine-key>/` rather
/// than a shared `.index/`, so two machines syncing one package never write the
/// same `index.sqlite`, `lock` or `dirty`.
///
/// Two halves. The derivation is tested as a pure function — `MachineKey.current`
/// is resolved once per process and deliberately cannot be re-resolved, so a
/// test cannot get a second key out of it. The layout is tested on disk, where
/// the claim that matters is not "the path has a new component" but "another
/// machine's directory is inert": untouched by open and by mutation, and
/// invisible to the manifest and to `verifyIntegrity()`.
struct MachineLocalIndexTests {
    // MARK: - The derivation

    @Test func theBootVolumeUUIDKeysTheMachine() {
        let key = MachineKey.key(
            volumeUUID: "69288A50-426D-46D0-AF29-9CB40157979F",
            hostName: "Studiobook.local")
        #expect(key.hasPrefix("vol-"))
        #expect(key.count == "vol-".count + 16)
    }

    /// The fallbacks exist because `volumeUUIDString` is documented as optional
    /// and is `nil` on platforms that do not carry one (Linux, in practice).
    @Test func theHostnameIsTheLastResortBehindMachineID() {
        let absent = MachineKey.key(hostName: "Studiobook.local")
        let empty = MachineKey.key(volumeUUID: "", hostName: "Studiobook.local")
        #expect(absent.hasPrefix("host-"))
        #expect(absent == empty, "an empty UUID string is no UUID at all")

        // `/etc/machine-id` first, for the same reason the volume UUID beats the
        // hostname: it survives a rename. A container gets a fresh hostname per
        // run, which would otherwise start a new index — and leave the old one
        // behind — every time (review finding, 48).
        let stable = MachineKey.keyAndDerivation(
            override: nil, machineID: "ec2f9a1c", hostName: "buildbox-7f3a")
        #expect(stable.key.hasPrefix("mid-"))
        #expect(stable.derivation == .machineID)
        #expect(
            stable.key
                == MachineKey.keyAndDerivation(
                    override: nil, machineID: "ec2f9a1c", hostName: "buildbox-9999"
                ).key,
            "a renamed host keeps its index")
    }

    /// Every derivation is reportable, because a *silent* fallback is how one
    /// process ends up on a different lockfile from another — the failure that
    /// would undo slice 47 (review finding, 48).
    @Test func theDerivationIsReportedNotJustEncodedInThePrefix() {
        let cases:
            [(MachineKey.Derivation, String, (key: String, derivation: MachineKey.Derivation))] = [
                (
                    .override, "test-",
                    MachineKey.keyAndDerivation(
                        override: "other", volumeUUID: "V", machineID: "M", hostName: "H")
                ),
                (
                    .volumeUUID, "vol-",
                    MachineKey.keyAndDerivation(
                        override: nil, volumeUUID: "V", machineID: "M", hostName: "H")
                ),
                (
                    .machineID, "mid-",
                    MachineKey.keyAndDerivation(
                        override: nil, volumeUUID: nil, machineID: "M", hostName: "H")
                ),
                (
                    .hostName, "host-",
                    MachineKey.keyAndDerivation(
                        override: nil, volumeUUID: nil, machineID: nil, hostName: "H")
                ),
            ]
        for (expected, prefix, actual) in cases {
            #expect(actual.derivation == expected)
            #expect(actual.key.hasPrefix(prefix))
        }
        // Whitespace-only inputs are no input at all, at every step.
        #expect(
            MachineKey.keyAndDerivation(
                override: " ", volumeUUID: " ", machineID: " ", hostName: "H"
            ).derivation == .hostName)
    }

    /// The prefix is in the clear so that a divergence — the app resolving one
    /// way and the CLI the other — is diagnosable from `ls` alone.
    @Test func theDerivationIsVisibleInThePrefixButTheValueIsNot() {
        let volume = MachineKey.key(volumeUUID: "VOL-1", hostName: "host-1")
        let host = MachineKey.key(hostName: "host-1")
        let forced = MachineKey.key(override: "other", volumeUUID: "VOL-1", hostName: "host-1")

        #expect(volume.hasPrefix("vol-"))
        #expect(host.hasPrefix("host-"))
        #expect(forced.hasPrefix("test-"))

        for key in [volume, host, forced] {
            #expect(!key.contains("VOL-1"))
            #expect(!key.contains("host-1"))
            #expect(!key.contains("other"))
            let hex = key.split(separator: "-").last.map(String.init) ?? ""
            #expect(hex.count == 16)
            #expect(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        }
    }

    /// Source-tagged hash input: a hostname that happens to *be* a volume UUID
    /// must not land on the volume-derived key for that same string.
    @Test func theHashIsTaggedWithItsSource() {
        let shared = "69288A50-426D-46D0-AF29-9CB40157979F"
        let asVolume = MachineKey.key(volumeUUID: shared, hostName: "x")
        let asHost = MachineKey.key(hostName: shared)
        #expect(asVolume.dropFirst("vol-".count) != asHost.dropFirst("host-".count))
    }

    @Test func theSameMachineAlwaysResolvesTheSameKey() {
        let first = MachineKey.key(volumeUUID: "V", hostName: "H")
        let second = MachineKey.key(volumeUUID: "V", hostName: "H")
        #expect(first == second)
        #expect(MachineKey.current == MachineKey.current)
    }

    @Test func differentMachinesResolveDifferentKeys() {
        let one = MachineKey.key(volumeUUID: "V-one", hostName: "H")
        let two = MachineKey.key(volumeUUID: "V-two", hostName: "H")
        #expect(one != two)
    }

    // MARK: - The override

    @Test func theOverrideOutranksEveryDerivation() {
        let key = MachineKey.key(override: "other", volumeUUID: "V", hostName: "H")
        #expect(
            key
                == MachineKey.key(
                    override: "other", volumeUUID: "different", machineID: "also",
                    hostName: "also"))
        #expect(key != MachineKey.key(override: "mine", volumeUUID: "V", hostName: "H"))
    }

    /// An exported-but-empty variable is a mistake, and honoring it would hand
    /// two machines one key — the exact failure the slice exists to remove.
    @Test func anEmptyOverrideReadsAsUnset() {
        let derived = MachineKey.key(volumeUUID: "V", hostName: "H")
        #expect(MachineKey.key(override: "", volumeUUID: "V", hostName: "H") == derived)
        #expect(MachineKey.key(override: "   \n", volumeUUID: "V", hostName: "H") == derived)
        #expect(MachineKey.normalized("  other  ") == "other")
    }

    /// Hashing is what makes this safe: the override never becomes a path
    /// component, so a traversal-shaped value cannot escape `.index/` and does
    /// not need a charset allow-list standing in front of it.
    @Test func anOverrideCannotEscapeTheIndexDirectory() {
        for hostile in ["../../../../tmp/evil", "..", "/etc", "a/b", "a\u{0}b"] {
            let key = MachineKey.key(override: hostile, volumeUUID: "V", hostName: "H")
            #expect(key.hasPrefix("test-"))
            #expect(!key.contains("/"))
            #expect(!key.contains("."))
            #expect(key.count == "test-".count + 16)
        }
    }

    // MARK: - The layout on disk

    @Test func theDatabaseLockAndSentinelAllLiveUnderTheMachineKey() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "1920 Census"))

        let machineDirectory = ArchiveLayout.indexDirectory(in: root)
        #expect(machineDirectory.lastPathComponent == MachineKey.current)
        #expect(
            machineDirectory.deletingLastPathComponent()
                == ArchiveLayout.indexContainerDirectory(in: root))

        #expect(
            FileManager.default.fileExists(atPath: ArchiveLayout.indexDatabaseURL(in: root).path))
        #expect(FileManager.default.fileExists(atPath: ArchiveLayout.lockURL(in: root).path))
        for url in [ArchiveLayout.indexDatabaseURL(in: root), ArchiveLayout.lockURL(in: root)] {
            #expect(url.deletingLastPathComponent() == machineDirectory)
        }
        #expect(
            ArchiveLayout.indexDirtyMarkerURL(in: root).deletingLastPathComponent()
                == machineDirectory)

        // Nothing is left directly in the container — the old paths are gone,
        // not merely shadowed.
        let container = ArchiveLayout.indexContainerDirectory(in: root)
        let contents = try FileManager.default.contentsOfDirectory(
            at: container, includingPropertiesForKeys: nil)
        #expect(contents.map(\.lastPathComponent) == [MachineKey.current])
    }

    /// The slice's actual claim: another machine's index is inert. It is not
    /// opened, not written, not rebuilt over, and not reported.
    @Test func anotherMachinesIndexIsUntouchedAndInvisible() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "1920 Census"))

        // What a sync provider would deliver from the other machine.
        let foreign = ArchiveLayout.indexContainerDirectory(in: root)
            .appendingPathComponent("vol-0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let foreignFiles = [
            "index.sqlite": Data("not really a database".utf8),
            "lock": Data(),
            "dirty": Data("2026-08-28T00:00:00Z".utf8),
        ]
        for (name, bytes) in foreignFiles {
            try bytes.write(to: foreign.appendingPathComponent(name))
        }

        let reopened = try Archive.open(at: root)
        try reopened.addArtifact(.sample(title: "1930 Census"))
        try reopened.rebuildIndex()

        for (name, bytes) in foreignFiles {
            let url = foreign.appendingPathComponent(name)
            #expect(FileManager.default.contents(atPath: url.path) == bytes, "\(name) was touched")
        }

        let manifest = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        #expect(!manifest.files.contains { $0.path.hasPrefix(".index") })
        let report = try reopened.verifyIntegrity()
        #expect(report.isClean, "integrity issues: \(report.issues)")
    }

    /// Slice 48 ships **no migration**: an archive written under the old layout
    /// keeps its `.index/index.sqlite` exactly where it was, and the machine
    /// directory starts empty. That costs one rebuild, which the empty directory
    /// would have forced anyway — including for a stale `.index/dirty`, whose
    /// whole job was to force one.
    @Test func aLegacyIndexIsLeftAloneRatherThanMigrated() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        try archive.addArtifact(.sample(title: "1920 Census"))
        let before = archive.artifacts()

        // Reconstruct the pre-48 shape beside the new one.
        let container = ArchiveLayout.indexContainerDirectory(in: root)
        let legacy = container.appendingPathComponent("index.sqlite")
        let legacyBytes = Data("the old shared database".utf8)
        try legacyBytes.write(to: legacy)
        try Data("2026-08-28T00:00:00Z".utf8).write(to: container.appendingPathComponent("dirty"))

        // The machine directory is what a fresh open builds and reads.
        try FileManager.default.removeItem(at: ArchiveLayout.indexDirectory(in: root))
        let reopened = try Archive.open(at: root)
        #expect(reopened.artifacts() == before)

        #expect(FileManager.default.contents(atPath: legacy.path) == legacyBytes)
        #expect(
            FileManager.default.fileExists(
                atPath: container.appendingPathComponent("dirty").path))
        #expect(try reopened.verifyIntegrity().isClean)
    }
}

import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 64 — the version is archive-wide, and there is no forward compatibility.
///
/// The three refusals at the door (manifest newer, a record newer than the
/// manifest, manifest older without an upgrade), each leaving everything outside
/// `.index/` untouched; the straggler skipped and reported with its own reason,
/// and Repair refusing it; the fake-step upgrade round trip (fork f); and the merge
/// keeping the newer version (fork g).
@Suite struct VersionSkewTests {

    // MARK: - Doctoring an archive

    private static func setManifestVersion(_ version: String, in root: URL) throws {
        let url = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: Data(contentsOf: url))
        manifest.schemaVersion = version
        try GeneaLogicJSON.encoder.encode(manifest).write(to: url)
    }

    private static func manifestVersion(in root: URL) throws -> String {
        try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        ).schemaVersion
    }

    /// Rewrites one record's `schemaVersion` in place, leaving every other byte's
    /// meaning alone. Goes through `JSONSerialization` rather than the model so a
    /// version the model would never write can be planted.
    private static func setRecordVersion(_ version: String, at url: URL) throws {
        var object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["schemaVersion"] = version
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    /// Every record file in the archive, archive-relative.
    private static func recordPaths(in root: URL) throws -> [String] {
        let fm = FileManager.default
        var paths: [String] = []
        let artifacts = root.appendingPathComponent("artifacts")
        for dir in (try? fm.contentsOfDirectory(atPath: artifacts.path)) ?? [] {
            let record = artifacts.appendingPathComponent(dir).appendingPathComponent("record.json")
            if fm.fileExists(atPath: record.path) { paths.append("artifacts/\(dir)/record.json") }
        }
        for kind in ["persons", "relationships", "links", "dismissals"] {
            let dir = root.appendingPathComponent("conclusions/\(kind)")
            for file in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            where file.hasSuffix(".json") {
                paths.append("conclusions/\(kind)/\(file)")
            }
        }
        return paths.sorted()
    }

    private static func discardIndex(in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(".index"))
    }

    /// An archive with one artifact and two persons, closed (its handle dropped).
    private static func populatedArchive() throws -> (root: URL, personPath: String) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Census"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        return (root, "conclusions/persons/\(person.uid.raw).json")
    }

    // MARK: - The refusals at the door

    @Test func aNewerManifestIsRefusedAndNothingOutsideTheIndexChanges() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.setManifestVersion("1.1", in: root)
        try Self.discardIndex(in: root)
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: "manifest.json", found: "1.1", supported: SchemaVersion.current)
        ) {
            try Archive.open(at: root)
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    @Test func theRefusalNamesTheFileBothVersionsAndTheFix() {
        let text = ArchiveError.archiveNewerThanBuild(
            path: "manifest.json", found: "1.1", supported: "1.0"
        ).description
        #expect(text.contains("manifest.json was written in archive format 1.1"))
        #expect(text.contains("this GeneaLogic writes 1.0"))
        #expect(text.contains("Nothing was changed"))
        #expect(text.contains("Update GeneaLogic"))
    }

    /// Unparsable compares as newer (fork c): a stamp the build cannot read is not
    /// one it can vouch for.
    @Test(arguments: ["abc", "1", "1.0.1", "1.x", "", "01.0", "+1.0", "1. 0"])
    func anUnparsableManifestVersionIsRefusedAsNewer(_ version: String) throws {
        let (root, _) = try Self.populatedArchive()
        try Self.setManifestVersion(version, in: root)
        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: "manifest.json", found: version, supported: SchemaVersion.current)
        ) {
            try Archive.open(at: root)
        }
    }

    /// The sync window the slice was specced for: the record arrives before the
    /// manifest that records the upgrade. The rebuild reads it perfectly and
    /// refuses anyway, naming the file.
    @Test func aRecordNewerThanTheManifestRefusesTheOpen() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.setRecordVersion("1.1", at: root.appendingPathComponent(personPath))
        try Self.discardIndex(in: root)
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: personPath, found: "1.1", supported: SchemaVersion.current)
        ) {
            try Archive.open(at: root)
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    @Test func aNewerArtifactRecordRefusesTheOpenToo() throws {
        let (root, _) = try Self.populatedArchive()
        let recordPath = try #require(
            try Self.recordPaths(in: root).first { $0.hasPrefix("artifacts/") })
        try Self.setRecordVersion("2.0", at: root.appendingPathComponent(recordPath))
        try Self.discardIndex(in: root)

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: recordPath, found: "2.0", supported: SchemaVersion.current)
        ) {
            try Archive.open(at: root)
        }
    }

    /// The same refusal from a handle that is already open — the app's window,
    /// hours later — when its next rebuild meets the record.
    @Test func anOpenHandleRefusesToRebuildOverANewerRecord() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.setRecordVersion("1.1", at: root.appendingPathComponent(personPath))

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: personPath, found: "1.1", supported: SchemaVersion.current)
        ) {
            try archive.rebuildIndex()
        }
        // The rebuild's transaction rolled back: the index still serves both.
        #expect(archive.persons().count == 2)
    }

    /// And when a newer *manifest* lands on an open handle, the next mutation is
    /// refused before it writes anything.
    @Test func anOpenHandleRefusesToWriteAfterANewerManifestLands() throws {
        let (root, _) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.setManifestVersion("1.1", in: root)
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: "manifest.json", found: "1.1", supported: SchemaVersion.current)
        ) {
            try archive.addPerson(.sample(given: "Nobody", surname: "New"))
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
        #expect(archive.persons().count == 2)
    }

    @Test func anOlderManifestNeedsAnExplicitUpgrade() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.setManifestVersion("0.9", in: root)
        for path in try Self.recordPaths(in: root) {
            try Self.setRecordVersion("0.9", at: root.appendingPathComponent(path))
        }
        try Self.discardIndex(in: root)
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(throws: ArchiveError.needsUpgrade(from: "0.9", to: SchemaVersion.current)) {
            try Archive.open(at: root)
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)

        // The build's own chain has no step, so the upgrade says so — and the
        // wording points at the one place a version no build wrote can come from.
        #expect(throws: ArchiveError.noUpgradePath(from: "0.9", to: SchemaVersion.current)) {
            try Archive.upgrade(at: root)
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
        let text = ArchiveError.noUpgradePath(from: "0.9", to: "1.0").description
        #expect(text.contains("no GeneaLogic has written"))
        #expect(text.contains("schemaVersion"))
    }

    @Test func theUpgradeAdviceSaysWhatItCosts() {
        let text = ArchiveError.needsUpgrade(from: "0.9", to: "1.0").description
        #expect(text.contains("format 0.9"))
        #expect(text.contains("genea upgrade"))
        #expect(text.contains("older GeneaLogic will no longer be able to open it"))
    }

    // MARK: - The straggler (fork c, downward)

    @Test func aRecordOlderThanTheManifestIsSkippedAndReportedWithItsReason() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.setRecordVersion("0.9", at: root.appendingPathComponent(personPath))
        try Self.discardIndex(in: root)

        let archive = try Archive.open(at: root)
        #expect(archive.persons().compactMap(\.displayName) == ["Grace Hopper"])
        #expect(try archive.standingFindings().unreadableRecords == [personPath])
        #expect(
            try archive.verifyIntegrity().issues.contains(
                .unreadableRecord(path: personPath, reason: .olderFormat)))
        #expect(
            try !archive.verifyIntegrity().issues.contains(
                .unreadableRecord(path: personPath, reason: .undecodable)))
        #expect(try archive.rebuildIndex() == [personPath])
    }

    /// A straggler keeps a preserved copy like any skipped record (58) — and
    /// Repair must not offer it (fork e): the copy is an earlier version of an
    /// intact file.
    @Test func repairRefusesAStraggler() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        let fileURL = root.appendingPathComponent(personPath)
        try Self.setRecordVersion("0.9", at: fileURL)
        let doctored = try Data(contentsOf: fileURL)

        // A same-schema rebuild, so the copy survives it.
        #expect(try archive.rebuildIndex() == [personPath])
        #expect(try archive.preservedRecord(atPath: personPath) != nil)

        #expect(try archive.repairPlan(forRecordAt: personPath) == nil)
        #expect(try archive.repairPlans(forRecordsAt: [personPath]).isEmpty)
        #expect(throws: ArchiveError.repairNotForOlderFormat(path: personPath)) {
            try archive.repairRecord(atPath: personPath, acceptingInexactRestore: true)
        }
        #expect(try Data(contentsOf: fileURL) == doctored)
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent(".damaged").path))
    }

    /// *Accept Current Contents* must accept a straggler's bytes (hand-test): the
    /// checksum finding on it clears, while the older-format finding — which a
    /// rebaseline cannot resolve — stays. 59's carve-out is for records nothing
    /// can read, and this one reads.
    @Test func rebaselineAcceptsAStragglersBytes() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.setRecordVersion("0.9", at: root.appendingPathComponent(personPath))
        try archive.rebuildIndex()

        let before = try archive.verifyIntegrity()
        #expect(before.issues.contains { $0.path == personPath && $0.isResolvableByRebaseline })

        try archive.rebaseline()

        let after = try archive.verifyIntegrity()
        #expect(!after.issues.contains { $0.path == personPath && $0.isResolvableByRebaseline })
        #expect(after.issues.contains(.unreadableRecord(path: personPath, reason: .olderFormat)))
        #expect(after.issues.filter { $0.path == personPath }.count == 1)
    }

    // MARK: - The upgrade round trip (fork f)

    /// A fake `0.9 → 1.0` step that rewrites each record's stamp, returning the
    /// paths it touched.
    private static let fakeStep = Migration.Step(fromVersion: "0.9", toVersion: "1.0") { root in
        let paths = try recordPaths(in: root)
        for path in paths {
            try setRecordVersion("1.0", at: root.appendingPathComponent(path))
        }
        return paths
    }

    @Test func anInjectedStepUpgradesTheArchiveAndOpenThenSucceeds() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.setManifestVersion("0.9", in: root)
        for path in try Self.recordPaths(in: root) {
            try Self.setRecordVersion("0.9", at: root.appendingPathComponent(path))
        }
        #expect(throws: ArchiveError.needsUpgrade(from: "0.9", to: SchemaVersion.current)) {
            try Archive.open(at: root)
        }

        let outcome = try Archive.upgrade(at: root, migration: Migration(steps: [Self.fakeStep]))
        #expect(outcome == .init(from: "0.9", to: SchemaVersion.current))
        #expect(!outcome.wasAlreadyCurrent)
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)

        let archive = try Archive.open(at: root)
        // The index was rebuilt from the rewritten files: every record is back,
        // nothing is a straggler, and the manifest entries the step invalidated
        // were re-minted, so the archive verifies clean.
        #expect(archive.persons().count == 2)
        #expect(archive.artifacts().count == 1)
        #expect(archive.persons().contains { personPath.contains($0.uid.raw) })
        #expect(try archive.standingFindings().isEmpty)
        #expect(try archive.verifyIntegrity().isClean)
        #expect(!IndexDirtyMarker.isSet(in: root))
    }

    @Test func upgradeOnACurrentArchiveChangesNothing() throws {
        let (root, _) = try Self.populatedArchive()
        let before = try TestSupport.snapshotOutsideIndex(root)

        let outcome = try Archive.upgrade(at: root)
        #expect(outcome.wasAlreadyCurrent)
        #expect(outcome.to == SchemaVersion.current)
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    @Test func upgradeRefusesANewerArchive() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.setManifestVersion("1.1", in: root)
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: "manifest.json", found: "1.1", supported: SchemaVersion.current)
        ) {
            try Archive.upgrade(at: root)
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    /// A gap in the chain is refused before the first step runs — never a
    /// half-migrated archive.
    @Test func aGapInTheChainRunsNoStep() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.setManifestVersion("0.8", in: root)
        for path in try Self.recordPaths(in: root) {
            try Self.setRecordVersion("0.8", at: root.appendingPathComponent(path))
        }
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(throws: ArchiveError.noUpgradePath(from: "0.8", to: SchemaVersion.current)) {
            try Archive.upgrade(at: root, migration: Migration(steps: [Self.fakeStep]))
        }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    // MARK: - The merge keeps the newer version (fork g)

    @Test func theMergedManifestCarriesTheNewerVersion() {
        #expect(ManifestMerge.schemaVersion(delivered: "0.9", ours: "1.0") == "1.0")
        #expect(ManifestMerge.schemaVersion(delivered: "1.0", ours: "1.0") == "1.0")
        #expect(ManifestMerge.schemaVersion(delivered: "1.1", ours: "1.0") == "1.1")
        #expect(ManifestMerge.schemaVersion(delivered: "2.0", ours: "1.9") == "2.0")
        #expect(ManifestMerge.schemaVersion(delivered: "1.10", ours: "1.9") == "1.10")
        // Unparsable is newer, so it is kept — and the door upstream is what
        // keeps it from ever being written by this build.
        #expect(ManifestMerge.schemaVersion(delivered: "next", ours: "1.0") == "next")
    }

    /// A straggler's manifest — same files, older stamp — delivered onto an open
    /// handle: the next write puts the archive's version back where it was.
    @Test func aStragglerManifestDoesNotDowngradeTheArchive() throws {
        let (root, _) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.setManifestVersion("0.9", in: root)

        _ = try archive.addPerson(.sample(given: "Third", surname: "Person"))
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)
    }

    /// Writes a manifest that is both behind on version and different in files —
    /// what a straggler machine's edit actually delivers — by dropping one entry.
    private static func deliverStragglerManifest(in root: URL) throws {
        let url = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: Data(contentsOf: url))
        manifest.schemaVersion = "0.9"
        manifest.files.removeLast()
        try GeneaLogicJSON.encoder.encode(manifest).write(to: url)
    }

    /// **The reconcile the reviewer reproduced** (`/code-review`, 64): a straggler
    /// manifest with a changed file list lands on an open handle. The rebuild it
    /// triggers must not refuse the archive's own records for being "ahead" of a
    /// manifest that is merely behind — and the write must put the version right.
    @Test func aStragglerManifestWithChangedFilesReconcilesAndIsHealed() throws {
        let (root, _) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.deliverStragglerManifest(in: root)

        #expect(try archive.reconcileIfStale())
        #expect(archive.persons().count == 2)
        #expect(try archive.standingFindings().isEmpty)
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)
    }

    /// The same delivery while the archive is *closed*: the next open must not
    /// demand an upgrade that already happened. The records say the archive is
    /// current; the manifest is the one that is behind, and the open corrects it.
    @Test func aStragglerManifestOnAClosedArchiveOpensAndIsHealed() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.deliverStragglerManifest(in: root)

        let archive = try Archive.open(at: root)
        #expect(archive.persons().count == 2)
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)

        // And with the same files, where no rebuild is needed: healed all the same.
        try Self.setManifestVersion("0.9", in: root)
        _ = try Archive.open(at: root)
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)
    }

    /// `upgrade` on the same archive has nothing to migrate and says so, rather
    /// than running the chain over records that are already current.
    @Test func upgradeOnAStragglerManifestMigratesNothing() throws {
        let (root, _) = try Self.populatedArchive()
        try Self.deliverStragglerManifest(in: root)

        let outcome = try Archive.upgrade(at: root, migration: Migration(steps: [Self.fakeStep]))
        #expect(outcome.wasAlreadyCurrent)
        #expect(try Self.manifestVersion(in: root) == SchemaVersion.current)
    }

    /// The records decide the archive's version, in both directions: behind the
    /// manifest's claim they are stragglers, but a record *ahead of the build* in
    /// an archive whose manifest is behind is still the door.
    @Test func aNewerRecordBehindAnOlderManifestIsStillRefused() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.setManifestVersion("0.9", in: root)
        try Self.setRecordVersion("1.1", at: root.appendingPathComponent(personPath))

        #expect(
            throws: ArchiveError.archiveNewerThanBuild(
                path: personPath, found: "1.1", supported: SchemaVersion.current)
        ) {
            try Archive.open(at: root)
        }
    }

    /// A refused rebuild inside `reconcileIfStale` arms 60's back-off
    /// (`/code-review`, 64): the app's one-second poll must not walk every
    /// sidecar under the lock on every tick until the manifest lands.
    @Test func aRefusedReconcileBacksOff() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        try Self.setRecordVersion("1.1", at: root.appendingPathComponent(personPath))
        // A manifest that differs, so the reconcile has a reason to rebuild.
        let url = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSON.decoder.decode(Manifest.self, from: Data(contentsOf: url))
        manifest.files[0].sha256 = String(repeating: "0", count: 64)
        try GeneaLogicJSON.encoder.encode(manifest).write(to: url)

        #expect(throws: ArchiveError.self) { try archive.reconcileIfStale() }
        // The same manifest, immediately again: waiting, not walking.
        #expect(try archive.reconcileIfStale() == false)
    }

    // MARK: - Before its manifest, with the index kept (slice 70)
    //
    // 64's door tests above discard `.index/`, so every open rebuilt and the walk
    // met the record. The gap was the other open: the manifest current, its
    // witness matching, the index reused as-is, and nothing reading the file.

    /// A newer build's record — its stamp and a field this build does not model —
    /// planted the way a sync delivery would, re-encoded at a different size.
    private static func deliverNewerRecord(at url: URL) throws {
        var object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["schemaVersion"] = "1.1"
        object["futureField"] = "only 1.1 knows what this constrains"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    /// `"1.0"` → `"1.1"` in place: a newer record exactly the size of its
    /// manifest entry, the one fork (a)'s open-time scan cannot see.
    private static func swapStampInPlace(at url: URL) throws {
        let before = try String(contentsOf: url, encoding: .utf8)
        let after = before.replacingOccurrences(
            of: #"("schemaVersion"\s*:\s*")1\.0(")"#, with: "$11.1$2", options: .regularExpression)
        precondition(after != before && after.utf8.count == before.utf8.count)
        try Data(after.utf8).write(to: url)
    }

    private static func newerThanBuild(_ path: String) -> ArchiveError {
        .archiveNewerThanBuild(path: path, found: "1.1", supported: SchemaVersion.current)
    }

    /// The issue's case: the record replaced a sidecar the index already holds.
    @Test func aNewerRecordAheadOfItsManifestIsRefusedWithTheIndexKept() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.deliverNewerRecord(at: root.appendingPathComponent(personPath))
        let before = try TestSupport.snapshotOutsideIndex(root)

        #expect(throws: Self.newerThanBuild(personPath)) { try Archive.open(at: root) }
        #expect(try TestSupport.snapshotOutsideIndex(root) == before)
    }

    @Test func aNewerArtifactRecordAheadOfItsManifestIsRefusedToo() throws {
        let (root, _) = try Self.populatedArchive()
        let path = try #require(try Self.recordPaths(in: root).first { $0.hasPrefix("artifacts/") })
        try Self.deliverNewerRecord(at: root.appendingPathComponent(path))

        #expect(throws: Self.newerThanBuild(path)) { try Archive.open(at: root) }
    }

    /// A record the manifest has never named — a new one from the newer machine —
    /// is read too: having no entry is what marks it as moved.
    @Test func aNewNewerRecordWithNoManifestEntryIsRefused() throws {
        let (root, personPath) = try Self.populatedArchive()
        let newPath = "conclusions/persons/PER-019fe97e-b57d-7029-8000-000000000001.json"
        var object =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: root.appendingPathComponent(personPath))) as! [String: Any]
        object["uid"] = "PER-019fe97e-b57d-7029-8000-000000000001"
        object["schemaVersion"] = "1.1"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: root.appendingPathComponent(newPath))

        #expect(throws: Self.newerThanBuild(newPath)) { try Archive.open(at: root) }
    }

    /// Fork (a)'s accepted limit and fork (b)'s answer to it: the open passes, and
    /// everything that would write over the file or judge it reads its stamp
    /// first — refusing as newer, not as drift or corruption.
    @Test func aSameSizeNewerRecordPassesTheOpenAndIsRefusedWhereItMatters() throws {
        let (root, personPath) = try Self.populatedArchive()
        let url = root.appendingPathComponent(personPath)
        try Self.swapStampInPlace(at: url)
        let planted = try Data(contentsOf: url)

        let archive = try Archive.open(at: root)
        let person = try #require(archive.persons().first { personPath.contains($0.uid.raw) })

        #expect(throws: Self.newerThanBuild(personPath)) {
            try archive.updatePerson(person.uid) { $0.names[0].given = "Augusta" }
        }
        #expect(throws: Self.newerThanBuild(personPath)) { try archive.verifyIntegrity() }
        #expect(throws: Self.newerThanBuild(personPath)) { try archive.rebaseline() }
        #expect(try Data(contentsOf: url) == planted)
    }

    /// The app's window, open for hours when the delivery lands: the next edit of
    /// that record and the next Verify refuse the same way, whatever its size.
    @Test func aNewerRecordLandingUnderAnOpenHandleIsRefusedByTheEditAndVerify() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        let person = try #require(archive.persons().first { personPath.contains($0.uid.raw) })
        let url = root.appendingPathComponent(personPath)
        try Self.deliverNewerRecord(at: url)
        let planted = try Data(contentsOf: url)

        #expect(throws: Self.newerThanBuild(personPath)) {
            try archive.updatePerson(person.uid) { $0.names[0].given = "Augusta" }
        }
        #expect(throws: Self.newerThanBuild(personPath)) { try archive.removePerson(person.uid) }
        #expect(throws: Self.newerThanBuild(personPath)) { try archive.verifyIntegrity() }
        #expect(try Data(contentsOf: url) == planted)
    }

    /// Verify's hash pass only reaches files the manifest names; a new newer
    /// record under an open handle is found by the scan `open` runs.
    @Test func verifyRefusesANewNewerRecordTheManifestDoesNotName() throws {
        let (root, personPath) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        let newPath = "conclusions/persons/PER-019fe97e-b57d-7029-8000-000000000002.json"
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(personPath), to: root.appendingPathComponent(newPath))
        try Self.deliverNewerRecord(at: root.appendingPathComponent(newPath))

        #expect(throws: Self.newerThanBuild(newPath)) { try archive.verifyIntegrity() }
    }

    /// Repair answers a finding from the last rebuild; a newer record delivered
    /// over the damaged file since must not be carried to `.damaged/` and written
    /// over with this build's older copy.
    @Test func repairRefusesWhenANewerRecordReplacedTheDamagedFile() throws {
        let (root, personPath) = try Self.populatedArchive()
        let url = root.appendingPathComponent(personPath)
        let good = try Data(contentsOf: url)
        let archive = try Archive.open(at: root)
        try Data("{ not JSON".utf8).write(to: url)
        try archive.rebuildIndex()
        #expect(try archive.repairPlan(forRecordAt: personPath) != nil)

        try good.write(to: url)
        try Self.deliverNewerRecord(at: url)
        let planted = try Data(contentsOf: url)

        #expect(throws: Self.newerThanBuild(personPath)) {
            try archive.repairRecord(atPath: personPath, acceptingInexactRestore: true)
        }
        #expect(try Data(contentsOf: url) == planted)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent(ArchiveLayout.damagedDirectoryName).path))
    }

    /// The control: a current-version record that moved is read and passes — the
    /// scan refuses on the stamp, never on the move — and an edit is still drift.
    @Test func aCurrentVersionHandEditStillOpensAndIsStillDrift() throws {
        let (root, personPath) = try Self.populatedArchive()
        let url = root.appendingPathComponent(personPath)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["identifierURI"] = "https://example.org/hand-edited"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)

        let archive = try Archive.open(at: root)
        let person = try #require(archive.persons().first { personPath.contains($0.uid.raw) })
        #expect(throws: ArchiveError.recordDriftedOnDisk(path: personPath)) {
            try archive.updatePerson(person.uid) { $0.names[0].given = "Augusta" }
        }
    }

    // MARK: - Review findings (slice 70)

    /// `upgrade` asks the same question `open` does, so the two cannot answer
    /// *already current* and *newer than this build* about one archive.
    @Test func upgradeRefusesARecordAheadOfACurrentManifest() throws {
        let (root, personPath) = try Self.populatedArchive()
        try Self.deliverNewerRecord(at: root.appendingPathComponent(personPath))

        #expect(throws: Self.newerThanBuild(personPath)) { try Archive.upgrade(at: root) }
    }

    /// A manifest written before slice 49 names no record, so *no entry* is every
    /// record and says nothing about what moved: the open does not read them all
    /// (the cost fork a rejected). The drift guard has no baseline there either,
    /// and still reads the stamp before writing over the file.
    @Test func aManifestWithNoRecordChecksumsSkipsTheScanAndTheEditStillRefuses() throws {
        let (root, personPath) = try Self.populatedArchive()
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.files.removeAll { ArchiveLayout.isEngineAuthored(relativePath: $0.path) }
        try GeneaLogicJSON.encoder.encode(manifest).write(to: manifestURL)
        _ = try Archive.open(at: root)  // settles the index against that manifest

        let url = root.appendingPathComponent(personPath)
        try Self.deliverNewerRecord(at: url)
        let planted = try Data(contentsOf: url)
        let archive = try Archive.open(at: root)
        let person = try #require(archive.persons().first { personPath.contains($0.uid.raw) })

        #expect(throws: Self.newerThanBuild(personPath)) {
            try archive.updatePerson(person.uid) { $0.names[0].given = "Augusta" }
        }
        #expect(try Data(contentsOf: url) == planted)
    }

    /// Removing an artifact moves its folder rather than unlinking the record, so
    /// it never passed the drift guard; it reads the stamp itself.
    @Test func removingAnArtifactWhoseRecordIsNewerIsRefused() throws {
        let (root, _) = try Self.populatedArchive()
        let archive = try Archive.open(at: root)
        let artifact = try #require(archive.artifacts().first)
        let path = "artifacts/\(artifact.slug)/record.json"
        try Self.deliverNewerRecord(at: root.appendingPathComponent(path))

        #expect(throws: Self.newerThanBuild(path)) { try archive.removeArtifact(artifact.uid) }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
        #expect(archive.artifact(withID: artifact.uid) != nil)
    }

    /// Repair names what the file is *now*: an older-format finding from the last
    /// rebuild, then a newer version delivered over it, is refused as newer.
    @Test func repairNamesANewerRecordOverAnOlderFormatFinding() throws {
        let (root, personPath) = try Self.populatedArchive()
        let url = root.appendingPathComponent(personPath)
        let archive = try Archive.open(at: root)
        try Self.setRecordVersion("0.9", at: url)
        try archive.rebuildIndex()
        try Self.deliverNewerRecord(at: url)

        #expect(throws: Self.newerThanBuild(personPath)) {
            try archive.repairRecord(atPath: personPath, acceptingInexactRestore: true)
        }
    }
}

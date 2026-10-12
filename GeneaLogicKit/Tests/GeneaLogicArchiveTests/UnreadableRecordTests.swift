import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 55 — a record the index can't read must not close the archive.
///
/// Before this, `ArchiveIndex.rebuild` threw on the first sidecar it could not
/// decode, and `Archive.open` rebuilds whenever `.index/` is missing, stale or
/// dirty — so one corrupt `record.json` cost access to every *other* record. The
/// contract now: skip the record, keep the rest, report the path.
@Suite struct UnreadableRecordTests {

    /// Removes `.index/` so the next `open()` takes the rebuild path — the whole
    /// reason a single bad record used to be fatal.
    private func discardIndex(in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(".index"))
    }

    private func unreadablePaths(_ report: IntegrityReport) -> [String] {
        report.issues.compactMap {
            if case .unreadableRecord(let path, _) = $0 { return path }
            return nil
        }
    }

    // MARK: - The archive opens, and keeps everything else

    @Test func corruptArtifactRecordIsSkippedAndTheArchiveStillOpens() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Broken"))
        let survivor = try archive.addArtifact(.sample(title: "Intact"))

        let brokenSlug = try #require(
            archive.artifacts().first { $0.title == "Broken" }?.slug)
        let record = root.appendingPathComponent("artifacts/\(brokenSlug)/record.json")
        try Data("{ this is not JSON".utf8).write(to: record)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        let titles = reopened.artifacts().map(\.title)
        #expect(titles == ["Intact"])
        #expect(reopened.artifact(withID: survivor.uid) != nil)

        let report = try reopened.verifyIntegrity()
        #expect(unreadablePaths(report) == ["artifacts/\(brokenSlug)/record.json"])
    }

    @Test func corruptConclusionIsSkippedAndTheArchiveStillOpens() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let broken = try archive.addPerson(.sample(given: "Ada", surname: "Broken"))
        _ = try archive.addPerson(.sample(given: "Grace", surname: "Intact"))

        let record = root.appendingPathComponent(
            "conclusions/persons/\(broken.uid.raw).json")
        try Data("{ \"uid\": ".utf8).write(to: record)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().count == 1)
        #expect(reopened.person(withID: broken.uid) == nil)

        let report = try reopened.verifyIntegrity()
        #expect(unreadablePaths(report) == ["conclusions/persons/\(broken.uid.raw).json"])
    }

    /// Valid JSON, wrong shape — a record from a GeneaLogic that writes fields
    /// this one can't satisfy looks exactly like this, and must not be fatal
    /// either.
    @Test func wellFormedJSONOfTheWrongShapeIsSkipped() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())

        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try Data(#"{"somethingElse": true}"#.utf8).write(to: record)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().isEmpty)
        #expect(unreadablePaths(try reopened.verifyIntegrity()).count == 1)
    }

    @Test func truncatedAndEmptyRecordsAreSkipped() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let truncated = try archive.addPerson(.sample(given: "Half", surname: "Written"))
        let empty = try archive.addPerson(.sample(given: "Zero", surname: "Bytes"))
        _ = try archive.addPerson(.sample(given: "Whole", surname: "Record"))

        let truncatedURL = root.appendingPathComponent(
            "conclusions/persons/\(truncated.uid.raw).json")
        let full = try Data(contentsOf: truncatedURL)
        try full.prefix(full.count / 2).write(to: truncatedURL)
        try Data().write(
            to: root.appendingPathComponent("conclusions/persons/\(empty.uid.raw).json"))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().count == 1)
        #expect(unreadablePaths(try reopened.verifyIntegrity()).count == 2)
    }

    /// Fork (e): no threshold. "Everything is corrupt" is still an archive that
    /// opens and explains itself — refusing there is the bug this slice fixes,
    /// just at a different scale.
    @Test func anArchiveWhoseRecordsAreAllCorruptStillOpens() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let people = try (0..<3).map {
            try archive.addPerson(.sample(given: "P\($0)", surname: "Doomed"))
        }

        for person in people {
            try Data("nonsense".utf8).write(
                to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))
        }
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().isEmpty)
        #expect(unreadablePaths(try reopened.verifyIntegrity()).count == 3)
    }

    // MARK: - The finding persists, and clears

    /// Fork (c): the list lives in the index, so an `open()` that does *no*
    /// rebuild still reports it. In-memory would mean the user sees the problem
    /// once and never again.
    @Test func theFindingSurvivesAnOpenThatDoesNotRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        try Data("broken".utf8).write(to: record)
        try discardIndex(in: root)

        // First open rebuilds (no `.index/`) and records the finding.
        let first = try Archive.open(at: root)
        #expect(unreadablePaths(try first.verifyIntegrity()).count == 1)

        // Second open finds a healthy, schema-current index and walks nothing.
        let second = try Archive.open(at: root)
        #expect(
            unreadablePaths(try second.verifyIntegrity()) == [
                "conclusions/persons/\(person.uid.raw).json"
            ])
    }

    @Test func repairingTheRecordAndReindexingClearsTheFinding() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")
        let good = try Data(contentsOf: record)
        try Data("broken".utf8).write(to: record)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(!unreadablePaths(try reopened.verifyIntegrity()).isEmpty)

        try good.write(to: record)
        let skipped = try reopened.rebuildIndex()
        #expect(skipped.isEmpty)
        #expect(reopened.persons().count == 1)
        #expect(unreadablePaths(try reopened.verifyIntegrity()).isEmpty)
    }

    @Test func rebuildIndexReturnsTheSkippedPaths() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        try Data("broken".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))

        let skipped = try archive.rebuildIndex()
        #expect(skipped == ["conclusions/persons/\(person.uid.raw).json"])
    }

    /// A rebaseline accepts the disk as truth — and here the disk is the problem,
    /// so it must not make the finding go away.
    @Test func rebaselineDoesNotResolveAnUnreadableRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        try Data("broken".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        try reopened.rebaseline()

        let report = try reopened.verifyIntegrity()
        #expect(unreadablePaths(report).count == 1)
        #expect(
            report.rebaselinableIssues.allSatisfy {
                if case .unreadableRecord = $0 { return false }
                return true
            })
    }

    // MARK: - Manifest coverage is not lost, and not laundered (review finding, 55)

    /// The regression that matters most: corrupt-then-repair must not be a way to
    /// substitute a record's contents behind `verifyIntegrity()`'s back.
    ///
    /// Slice 49 enumerates the manifest's authored entries from the index, on the
    /// reading that a record absent from the index has been deleted. A skipped
    /// record breaks that reading, so its entry was dropped on the next mutation
    /// and freshly minted from disk once the file decoded again — laundering the
    /// substituted bytes into the manifest and bypassing `rebaseline()`.
    @Test func repairingASkippedRecordDoesNotLaunderSubstitutedContents() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Real", surname: "Person"))
        let record = root.appendingPathComponent(
            "conclusions/persons/\(person.uid.raw).json")

        var substituted =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: record))
            as! [String: Any]
        substituted["notes"] = "contents swapped while the record was unreadable"

        try Data("not JSON".utf8).write(to: record)
        try archive.rebuildIndex()

        try JSONSerialization.data(withJSONObject: substituted, options: [.sortedKeys])
            .write(to: record)
        try archive.rebuildIndex()

        // The manifest still holds the baseline from before the corruption, so
        // the substitution reports exactly as a plain hand-edit would.
        let report = try archive.verifyIntegrity()
        #expect(!report.isClean)
        #expect(
            report.issues.contains {
                if case .checksumMismatch(let path, _, _) = $0 {
                    return path == "conclusions/persons/\(person.uid.raw).json"
                }
                return false
            })

        // And `rebaseline()` — the deliberate human gate — is still what accepts it.
        try archive.rebaseline()
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// An artifact's payload files are derived from the index too, so a skipped
    /// `record.json` took its preservation masters out of the integrity surface
    /// with it — after which rot in them was reported by nothing at all.
    @Test func aSkippedArtifactKeepsItsPayloadFilesCovered() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed"))
        let source = try TestSupport.makeSourceFile(named: "master.tif", contents: "master bytes")
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let payloadPath = "artifacts/\(slug)/\(attached.entry.path)"

        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("artifacts/\(slug)/record.json"))
        try archive.rebuildIndex()
        // A mutation elsewhere is what recomputes the manifest — the point is
        // that an unrelated write must not quietly narrow the archive's coverage.
        _ = try archive.addPerson(.sample())

        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let paths = Set(manifest.files.map(\.path))
        #expect(paths.contains(payloadPath))
        #expect(paths.contains("artifacts/\(slug)/record.json"))

        // Rot in the still-covered master is still reported.
        try Data("ROTTED".utf8).write(to: root.appendingPathComponent(payloadPath))
        #expect(
            try archive.verifyIntegrity().issues.contains {
                if case .checksumMismatch(let path, _, _) = $0 { return path == payloadPath }
                return false
            })
    }

    // MARK: - What is still fatal

    /// Fork (a)'s other side: the skip applies to reading a record, not to the
    /// index failing to store what it read. A rebuild that cannot record its
    /// results is no result, and must not be mistaken for a degraded one — so it
    /// still throws, and still rolls back to the rows it had.
    ///
    /// The failure is induced by dropping a table out from under the archive's
    /// open connection, rather than by making the file unwritable: file
    /// permissions are the one thing that doesn't hold across both platforms
    /// (the Linux CI container runs as root, where they are advisory at best),
    /// and an immutable flag doesn't stop SQLite writing through a descriptor
    /// it already holds — measured, not assumed.
    @Test func aFailureStoringWhatItReadStillThrowsAndRollsBack() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Survives the rollback"))
        _ = try archive.addPerson(.sample())

        let saboteur = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        try saboteur.exec("DROP TABLE person;")

        #expect(throws: (any Error).self) {
            try archive.rebuildIndex()
        }
        // The rebuild had already emptied `artifact` before it hit the missing
        // table; a rollback is the difference between a failed rebuild and a
        // silently gutted index.
        #expect(archive.artifacts().map(\.title) == ["Survives the rollback"])
    }
}

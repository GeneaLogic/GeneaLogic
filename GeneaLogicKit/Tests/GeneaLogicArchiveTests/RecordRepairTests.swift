import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 59 — repair a damaged record from what the archive still knows.
///
/// 56 offered no action on a damaged record and was right to: the uid was inside
/// the file that failed to parse, so every mutation was unavailable by
/// construction. 58 changed that in one case by keeping the last index row — the
/// sidecar's own bytes — and 49 had already put that file's `sha256` in the
/// manifest. So the file can go back *and be proved exact*.
@Suite struct RecordRepairTests {

    /// The bytes GeneaLogic wrote, replaced by `junk` — returning the original for
    /// the restoration to be compared against.
    @discardableResult
    private func corrupt(_ record: URL, with junk: String = "{ not JSON") throws -> Data {
        let original = try Data(contentsOf: record)
        try Data(junk.utf8).write(to: record)
        return original
    }

    /// A person whose sidecar is broken and whose copy is preserved — the state
    /// every repair starts from.
    private func archiveWithABrokenPerson() throws -> (
        archive: Archive, root: URL, path: String, original: Data
    ) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        let original = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()
        return (archive, root, path, original)
    }

    private func damagedFiles(in root: URL) -> [String] {
        let directory = root.appendingPathComponent(ArchiveLayout.damagedDirectoryName)
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        return (names ?? []).sorted()
    }

    // MARK: - The restoration is exact, and provably so

    /// The slice's whole claim: the file comes back byte-identical, the manifest
    /// agrees, and the record is in its list again.
    @Test func repairRestoresTheRecordByteForByte() throws {
        let (archive, root, path, original) = try archiveWithABrokenPerson()

        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(plan.isByteExact)
        #expect(plan.restoredSHA256 == plan.recordedSHA256)

        let outcome = try archive.repairRecord(atPath: path)
        #expect(outcome.wasByteExact)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
        #expect(archive.persons().count == 1)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// An artifact's copy resolves through its folder slug, so its `record.json`
    /// restores the same way — and the files it claims are covered again.
    @Test func repairRestoresAnArtifactRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Deed of Sale"))
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"

        let original = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()
        #expect(archive.artifacts().isEmpty)

        let outcome = try archive.repairRecord(atPath: path)
        #expect(outcome.uid == artifact.uid.raw)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
        #expect(archive.artifact(withID: artifact.uid) != nil)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// The repair answers the finding it was offered from, without waiting for a
    /// rebuild to notice: a row still saying "unreadable record" about a file that
    /// now reads is 56's lie in the other direction.
    @Test func repairClearsTheFindingAndConsumesTheCopy() throws {
        let (archive, _, path, _) = try archiveWithABrokenPerson()
        #expect(try archive.standingFindings().unreadableRecords == [path])

        try archive.repairRecord(atPath: path)

        #expect(try archive.standingFindings().unreadableRecords.isEmpty)
        #expect(try archive.preservedRecordPaths().isEmpty)
        // And the copy stays gone across the rebuild that would have re-staged it
        // had the record still been unreadable.
        try archive.rebuildIndex()
        #expect(try archive.preservedRecordPaths().isEmpty)
        #expect(try archive.standingFindings().unreadableRecords.isEmpty)
    }

    /// Repairing one record says nothing about the others.
    @Test func repairLeavesOtherDamageReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let first = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let second = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        let firstPath = "conclusions/persons/\(first.uid.raw).json"
        let secondPath = "conclusions/persons/\(second.uid.raw).json"

        try corrupt(root.appendingPathComponent(firstPath))
        try corrupt(root.appendingPathComponent(secondPath))
        try archive.rebuildIndex()

        try archive.repairRecord(atPath: firstPath)
        #expect(try archive.standingFindings().unreadableRecords == [secondPath])
        #expect(try archive.preservedRecordPaths() == [secondPath])
    }

    // MARK: - The damaged file is kept, not overwritten (fork c)

    /// The case that matters most is the one where the "damage" was a hand-edit
    /// the user meant — so the bytes found in place are moved aside, never
    /// destroyed.
    @Test func theDamagedFileIsQuarantinedNotOverwritten() throws {
        let (archive, root, path, _) = try archiveWithABrokenPerson()

        let outcome = try archive.repairRecord(atPath: path)

        let quarantined = try #require(outcome.quarantinedPath)
        #expect(quarantined.hasPrefix("\(ArchiveLayout.damagedDirectoryName)/"))
        #expect(quarantined.contains(outcome.uid))
        #expect(
            try Data(contentsOf: root.appendingPathComponent(quarantined))
                == Data("{ not JSON".utf8))
    }

    /// `.damaged/` is a reserved top-level directory like `.index/` and `.trash/`:
    /// outside the manifest, the index and every integrity pass. If it were not,
    /// a repair would trade one standing finding for another.
    @Test func theQuarantineIsOutsideEveryPass() throws {
        let (archive, root, path, _) = try archiveWithABrokenPerson()

        let outcome = try archive.repairRecord(atPath: path)
        let quarantined = try #require(outcome.quarantinedPath)

        let report = try archive.verifyIntegrity()
        #expect(report.isClean)
        #expect(!report.issues.contains { $0.path == quarantined })

        let reopened = try Archive.open(at: root)
        #expect(try reopened.verifyIntegrity().isClean)
        #expect(try reopened.standingFindings().unreadableRecords.isEmpty)
    }

    /// Two repairs of one record keep both originals — a quarantine that
    /// overwrote its own earlier entry would lose the bytes it exists to hold.
    @Test func asecondRepairDoesNotOverwriteTheFirstQuarantine() throws {
        let (archive, root, path, original) = try archiveWithABrokenPerson()

        try archive.repairRecord(atPath: path)
        try corrupt(root.appendingPathComponent(path), with: "{ broken again")
        try archive.rebuildIndex()
        try archive.repairRecord(atPath: path)

        #expect(damagedFiles(in: root).count == 2)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
    }

    /// A sidecar that *vanished* keeps its copy (58) but leaves nothing to
    /// quarantine — the repair is a plain restore.
    ///
    /// **And it must not need accepting.** A deleted sidecar loses its manifest
    /// entry (the carry-forward rule has no file to describe), so an exactness
    /// test alone refused the one case with the strongest claim on a repair — a
    /// warning about version skew, for an overwrite that cannot happen. The gate
    /// asks what is being replaced, which here is nothing.
    @Test func aVanishedSidecarIsRestoredWithNothingToQuarantine() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let path = "conclusions/persons/\(person.uid.raw).json"
        let record = root.appendingPathComponent(path)

        let original = try Data(contentsOf: record)
        try FileManager.default.removeItem(at: record)
        try archive.rebuildIndex()

        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(!plan.replacesFileOnDisk)
        #expect(!plan.requiresExplicitAcceptance)

        let outcome = try archive.repairRecord(atPath: path)
        #expect(outcome.quarantinedPath == nil)
        #expect(try Data(contentsOf: record) == original)
        #expect(archive.persons().count == 1)
        #expect(damagedFiles(in: root).isEmpty)
    }

    // MARK: - Version skew is refused the one-click path (fork a)

    /// The real skew case, built rather than simulated: a sidecar carrying a field
    /// this version doesn't model, blessed by `rebaseline()` so the manifest
    /// records *those* bytes. Decode drops the field, re-encode omits it, and the
    /// copy no longer hashes to what the manifest expects — so the restoration is
    /// not byte-exact and cannot be offered as though it were.
    @Test func aLossyCopyIsRefusedUnlessExplicitlyAccepted() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = "conclusions/persons/\(person.uid.raw).json"
        let record = root.appendingPathComponent(path)

        var object =
            try #require(
                try JSONSerialization.jsonObject(with: try Data(contentsOf: record))
                    as? [String: Any])
        object["fieldFromANewerGeneaLogic"] = "kept by no version of this model"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: record)
        try archive.rebaseline()

        try corrupt(record)
        try archive.rebuildIndex()

        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(!plan.isByteExact)
        #expect(plan.restoredSHA256 != plan.recordedSHA256)

        #expect(throws: ArchiveError.repairNotByteExact(path: path)) {
            try archive.repairRecord(atPath: path)
        }
        // Refused means nothing moved: the damaged file is still where it was.
        #expect(try Data(contentsOf: record) == Data("{ not JSON".utf8))
        #expect(damagedFiles(in: root).isEmpty)
        #expect(try archive.preservedRecordPaths() == [path])

        let outcome = try archive.repairRecord(atPath: path, acceptingInexactRestore: true)
        #expect(!outcome.wasByteExact)
        #expect(archive.persons().count == 1)
        // The field the newer version wrote is gone — which is what the caller
        // was told when they accepted, and why the original is in `.damaged/`.
        let restored = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: record))
                as? [String: Any])
        #expect(restored["fieldFromANewerGeneaLogic"] == nil)
    }

    /// A record with no manifest entry to compare against — an archive written
    /// before 49 put authored checksums in the manifest — is *not* exact. There is
    /// nothing to check, and "cannot tell" belongs with the case that has to be
    /// said out loud. Unlike the vanished sidecar above, this one is replacing a
    /// file, so it has something to lose and must be accepted.
    @Test func aRecordWithNoRecordedChecksumIsNotByteExact() throws {
        let (archive, root, path, _) = try archiveWithABrokenPerson()

        var manifest = try #require(
            try? JSONDecoder().decode(
                Manifest.self,
                from: try Data(contentsOf: root.appendingPathComponent("manifest.json"))))
        manifest.files.removeAll { $0.path == path }
        try JSONEncoder().encode(manifest)
            .write(to: root.appendingPathComponent("manifest.json"))

        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(plan.recordedSHA256 == nil)
        #expect(!plan.isByteExact)
        #expect(throws: ArchiveError.repairNotByteExact(path: path)) {
            try archive.repairRecord(atPath: path)
        }
    }

    /// **The hand-test's find (59): a rebaseline must not bless bytes nothing can
    /// read.** `rebaseline()` re-minted every authored entry from disk, including
    /// for records the rebuild had just reported unreadable — so accepting an
    /// unrelated hand-edit recorded the *corrupt* file's hash as the baseline, the
    /// preserved copy stopped matching it, and a provable one-click restore
    /// silently became the fallback that blames version skew. 49 reasoned this was
    /// harmless because the record stayed invisible either way; it stopped being
    /// harmless when 59 started making a claim from that entry.
    @Test func aRebaselineDoesNotDestroyTheProofOfAnExactRepair() throws {
        let (archive, root, path, _) = try archiveWithABrokenPerson()
        let recorded = try #require(try archive.repairPlan(forRecordAt: path)).recordedSHA256

        // The reason a human reaches for it: an unrelated record edited by hand.
        let other = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        let otherPath = "conclusions/persons/\(other.uid.raw).json"
        let otherURL = root.appendingPathComponent(otherPath)
        var edited =
            try #require(
                try JSONSerialization.jsonObject(with: try Data(contentsOf: otherURL))
                    as? [String: Any])
        edited["handEditedInATextEditor"] = true
        try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys])
            .write(to: otherURL)

        try archive.rebaseline()

        let plan = try #require(try archive.repairPlan(forRecordAt: path))
        #expect(plan.recordedSHA256 == recorded)
        #expect(plan.isByteExact)
        #expect(!plan.requiresExplicitAcceptance)
        try archive.repairRecord(atPath: path)
        #expect(archive.persons().count == 2)

        // And the edit it *was* asked to accept still is: reported clean, with the
        // hand-edited bytes left on disk rather than rewritten.
        #expect(try archive.verifyIntegrity().isClean)
        #expect(
            try String(data: try Data(contentsOf: otherURL), encoding: .utf8)?
                .contains("handEditedInATextEditor") == true)
    }

    // MARK: - Nothing to offer is a normal answer (fork b)

    /// A record that never decoded was never in the index, so there is no copy —
    /// the case the placeholder row must not offer a button for.
    @Test func aRecordWithNoCopyHasNoPlanAndCannotBeRepaired() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let path = "conclusions/persons/PER-never-decoded.json"
        try Data("{ garbage".utf8).write(to: root.appendingPathComponent(path))
        try archive.rebuildIndex()

        #expect(try archive.repairPlan(forRecordAt: path) == nil)
        #expect(throws: ArchiveError.noPreservedCopy(path: path)) {
            try archive.repairRecord(atPath: path)
        }
        // And the file it could not repair is still exactly where it was.
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == Data("{ garbage".utf8))
    }

    /// The plural call is what a host with a list should use, and must answer
    /// exactly what asking one at a time would (review finding, 59) — the point of
    /// it is the manifest read it does once instead of N times.
    @Test func plansForSeveralPathsMatchAskingOneAtATime() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let broken = try archive.addPerson(.sample(given: "Ada", surname: "Broken"))
        let alsoBroken = try archive.addPerson(.sample(given: "Grace", surname: "Broken"))
        _ = try archive.addPerson(.sample(given: "Mary", surname: "Intact"))
        let paths = [
            "conclusions/persons/\(broken.uid.raw).json",
            "conclusions/persons/\(alsoBroken.uid.raw).json",
        ]
        for path in paths { try corrupt(root.appendingPathComponent(path)) }
        // One with damage but no copy, and one shaped like nothing we write.
        try Data("{ garbage".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/PER-never-decoded.json"))
        try archive.rebuildIndex()

        let queried = paths + ["conclusions/persons/PER-never-decoded.json", "manifest.json"]
        let plans = try archive.repairPlans(forRecordsAt: queried)

        #expect(plans.keys.sorted() == paths.sorted())
        for path in queried {
            #expect(plans[path] == (try archive.repairPlan(forRecordAt: path)))
        }
    }

    /// A path shaped like nothing the engine writes has no copy by construction.
    @Test func anUnknownPathShapeIsNotRepairable() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        for path in ["manifest.json", "artifacts/deed/extra.json", "conclusions/notakind/x.json"] {
            #expect(try archive.repairPlan(forRecordAt: path) == nil)
            #expect(throws: ArchiveError.noPreservedCopy(path: path)) {
                try archive.repairRecord(atPath: path)
            }
        }
    }

    // MARK: - The repaired record is a record again

    /// A repair that left the index out of step would put the file back and keep
    /// the record invisible — so the restored record is looked up, edited, and
    /// survives a rebuild.
    @Test func aRepairedRecordIsEditableAndSurvivesARebuild() throws {
        let (archive, _, path, _) = try archiveWithABrokenPerson()
        try archive.repairRecord(atPath: path)

        let person = try #require(archive.persons().first)
        _ = try archive.updatePerson(person.uid) { $0.names[0].given = "Augusta" }
        #expect(archive.person(withID: person.uid)?.names.first?.given == "Augusta")

        try archive.rebuildIndex()
        #expect(archive.persons().count == 1)
        #expect(try archive.verifyIntegrity().isClean)
    }

    /// Every conclusion kind restores, not just the one with a browse list.
    @Test func everyConclusionKindCanBeRepaired() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let one = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let two = try archive.addPerson(.sample(given: "Grace", surname: "Hopper"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: one.uid, person2Uid: two.uid))
        let path = "conclusions/relationships/\(relationship.uid.raw).json"

        let original = try corrupt(root.appendingPathComponent(path))
        try archive.rebuildIndex()
        #expect(archive.relationships().isEmpty)

        try archive.repairRecord(atPath: path)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
        #expect(archive.relationships().count == 1)
    }
}

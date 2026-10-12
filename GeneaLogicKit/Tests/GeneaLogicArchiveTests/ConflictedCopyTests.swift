import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 50c — a second copy of a record must not become the record.
///
/// A sync provider that cannot merge one file leaves a copy beside it (Dropbox
/// `X (conflicted copy).json`, iCloud `X 2.json`), and duplicating a folder does
/// the same one level up. Both discovery walks used to be name-blind: the copy
/// was loaded into the index under the same uid, `contentsOfDirectory` order
/// decided which one every query returned, and the next ordinary mutation wrote
/// that winner back over the canonical sidecar — with `verifyIntegrity()`
/// reporting a clean archive throughout.
@Suite struct ConflictedCopyTests {

    /// Removes `.index/` so the next `open()` walks the disk — the path where a
    /// copy could take the uid.
    private func discardIndex(in root: URL) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(".index"))
    }

    /// Copies `source` to a sibling under `name`, applying `edit` to its text so
    /// the two files are distinguishable — a conflicted copy is only dangerous
    /// because it holds *different* contents.
    @discardableResult
    private func copyAside(
        _ source: URL, as name: String, replacing needle: String, with replacement: String
    ) throws -> URL {
        let text = try String(contentsOf: source, encoding: .utf8)
        let destination = source.deletingLastPathComponent().appendingPathComponent(name)
        try text.replacingOccurrences(of: needle, with: replacement)
            .write(to: destination, atomically: true, encoding: .utf8)
        return destination
    }

    private func conflictingPaths(_ report: IntegrityReport) -> [String] {
        report.issues.compactMap {
            if case .conflictingCopy(let path) = $0 { return path }
            return nil
        }
    }

    private func misnamedPaths(_ report: IntegrityReport) -> [String] {
        report.issues.compactMap {
            if case .misnamedRecord(let path, _) = $0 { return path }
            return nil
        }
    }

    private func personSidecar(in root: URL, _ id: PersonID) -> URL {
        root.appendingPathComponent("conclusions/persons/\(id.raw).json")
    }

    // MARK: - A conclusion: the copy never decides what the archive serves

    @Test func aConflictedCopyOfAPersonDoesNotDecideWhatTheArchiveServes() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        try copyAside(
            personSidecar(in: root, person.uid),
            as: "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json",
            replacing: "Smith", with: "Smyth")
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.person(withID: person.uid)?.names.first?.surname == "Smith")
        #expect(reopened.persons().count == 1)
    }

    /// **The load-bearing regression, in the shape that does not depend on the
    /// filesystem.** Which of two files wins used to be `contentsOfDirectory`
    /// order, so a test that leaves both in place proves the invariant but can
    /// pass on a lucky enumeration. Here the provider renamed the *original*, so
    /// the copy is the only candidate — and before this slice it was adopted as
    /// the record, after which an ordinary mutation wrote it back to the
    /// canonical path and the substitution was permanent and unrecorded.
    @Test func aCopyIsNotAdoptedAsTheRecordEvenWhenItIsTheOnlyFileLeft() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))
        let sidecar = personSidecar(in: root, person.uid)

        let copyName = "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json"
        try FileManager.default.moveItem(
            at: sidecar, to: sidecar.deletingLastPathComponent().appendingPathComponent(copyName))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.person(withID: person.uid) == nil)
        #expect(throws: (any Error).self) {
            try reopened.updatePerson(person.uid) { $0.names.removeAll() }
        }
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        // **Reported as the record under the wrong name, never as a duplicate**
        // (`/code-review`): there is no original here, so "the archive is using
        // the original, not this file" would be false, and the advice that goes
        // with it would destroy the only copy.
        let report = try reopened.verifyIntegrity()
        #expect(conflictingPaths(report).isEmpty)
        #expect(
            report.issues.contains(
                .misnamedRecord(path: "conclusions/persons/\(copyName)", uid: person.uid.raw)))
        // And the record it was standing in for is reported gone, honestly,
        // rather than quietly satisfied by the copy.
        #expect(
            report.issues.contains(.missingFile(path: "conclusions/persons/\(person.uid.raw).json"))
        )
    }

    /// The same claim once more with no ordering in it at all: a copy carrying a
    /// *different* uid than its name. Loaded, it is a whole extra person the
    /// researcher never created, and the manifest then names a sidecar that does
    /// not exist. Its own uid has no file, so it reports as misnamed — the file
    /// is Mary, under John's name.
    @Test func aCopyIsNeverLoadedAsARecordOfItsOwn() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))
        let other = try archive.addPerson(.sample(given: "Mary", surname: "Jones"))

        // A copy of Mary's sidecar, parked beside John's under a conflicted name
        // built from *John's* uid: two ways of being the wrong file at once.
        let copyName = "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json"
        let copy = personSidecar(in: root, person.uid).deletingLastPathComponent()
            .appendingPathComponent(copyName)
        try FileManager.default.copyItem(at: personSidecar(in: root, other.uid), to: copy)
        try FileManager.default.removeItem(at: personSidecar(in: root, other.uid))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().map(\.uid) == [person.uid])
        #expect(reopened.person(withID: other.uid) == nil)
        #expect(
            try reopened.verifyIntegrity().issues.contains(
                .misnamedRecord(path: "conclusions/persons/\(copyName)", uid: other.uid.raw)))
    }

    /// **The invariant itself**, with both files in place as a provider actually
    /// leaves them. Order-dependent before the slice — which is the defect, not a
    /// weakness of the test: the archive served whichever file the filesystem
    /// happened to hand back first.
    @Test func anOrdinaryMutationDoesNotWriteTheCopysContentsIntoTheRecord() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))
        let sidecar = personSidecar(in: root, person.uid)

        try copyAside(
            sidecar, as: "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json",
            replacing: "Smith", with: "Smyth")
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        _ = try reopened.updatePerson(person.uid) { person in
            person.names.append(
                PersonName(type: .married, given: "Johnny", surname: "Smith", full: "Johnny Smith"))
        }

        let onDisk = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(!onDisk.contains("Smyth"))
        #expect(reopened.person(withID: person.uid)?.names.first?.surname == "Smith")
        #expect(
            try reopened.verifyIntegrity().issues.allSatisfy { $0.path != sidecar.lastPathComponent })
    }

    @Test func aConflictedCopyOfAPersonIsReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let copyName = "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json"
        try copyAside(
            personSidecar(in: root, person.uid), as: copyName,
            replacing: "Smith", with: "Smyth")

        let report = try archive.verifyIntegrity()
        #expect(conflictingPaths(report) == ["conclusions/persons/\(copyName)"])
        // The copy is outside the manifest entirely, so it must not make the real
        // record look damaged or absent as well.
        #expect(report.issues.count == 1)
        #expect(!report.isClean)
    }

    @Test func aConflictedCopyOfARelationshipIsReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let parent = try archive.addPerson(.sample(given: "Mary", surname: "Smith"))
        let child = try archive.addPerson(.sample(given: "John", surname: "Smith"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: parent.uid, person2Uid: child.uid))

        let source = root.appendingPathComponent(
            "conclusions/relationships/\(relationship.uid.raw).json")
        let copyName = "\(relationship.uid.raw) 2.json"
        try copyAside(source, as: copyName, replacing: "parentChild", with: "spouse")

        let report = try archive.verifyIntegrity()
        #expect(conflictingPaths(report) == ["conclusions/relationships/\(copyName)"])
    }

    /// Rule (a)'s first half: a file that is simply not named `<uid>.json`. Before
    /// the slice this loaded **and** was reported `missing-file` on the canonical
    /// path in the same breath — two contradictory answers about one record.
    @Test func aHandRenamedConclusionIsNotLoadedAndIsReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let sidecar = personSidecar(in: root, person.uid)
        try FileManager.default.moveItem(
            at: sidecar,
            to: sidecar.deletingLastPathComponent().appendingPathComponent("john-smith.json"))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().isEmpty)
        #expect(
            misnamedPaths(try reopened.verifyIntegrity())
                == ["conclusions/persons/john-smith.json"])
    }

    /// The minimized case slice 63's archive property found on macOS: a uid that
    /// differs from its file name **in case alone** (one flipped bit in `b65`). To
    /// APFS's case-insensitive lookup the canonical name *exists*, so the sole
    /// surviving copy of the record was reported as a `.conflictingCopy` — a
    /// duplicate, with advice to delete it — where Linux said `.misnamedRecord`.
    /// The presence test is now the same exact-string rule the loader applies.
    @Test func aUIDDifferingFromItsFileNameInCaseOnlyIsMisnamedNotADuplicate() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let sidecar = personSidecar(in: root, person.uid)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        let upper = person.uid.raw.uppercased()
        #expect(upper != person.uid.raw, "the minted uid must carry lowercase hex")
        try text.replacingOccurrences(of: person.uid.raw, with: upper)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().isEmpty)
        let report = try reopened.verifyIntegrity()
        #expect(misnamedPaths(report) == ["conclusions/persons/\(person.uid.raw).json"])
        #expect(conflictingPaths(report).isEmpty)
    }

    /// Rule (a)'s second half. Without it the rule would be enforceable by
    /// renaming a file to any plausible-looking uid, which is no rule at all.
    @Test func aCopyNamedForADifferentUIDIsNotLoaded() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let impostor = "PER-01a0557e-0000-7000-8000-000000000000.json"
        try copyAside(
            personSidecar(in: root, person.uid), as: impostor,
            replacing: "Smith", with: "Smyth")
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.persons().count == 1)
        #expect(reopened.person(withID: person.uid)?.names.first?.surname == "Smith")
        #expect(
            conflictingPaths(try reopened.verifyIntegrity())
                == ["conclusions/persons/\(impostor)"])
    }

    // MARK: - An artifact folder: the same defect one level up

    @Test func aDuplicatedArtifactFolderDoesNotDecideWhatTheArchiveServes() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        let folder = root.appendingPathComponent("artifacts/\(slug)")
        let copy = root.appendingPathComponent("artifacts/\(slug) (conflicted copy)")
        try FileManager.default.copyItem(at: folder, to: copy)
        let record = copy.appendingPathComponent("record.json")
        try String(contentsOf: record, encoding: .utf8)
            .replacingOccurrences(of: "Smith family portrait", with: "STALE portrait")
            .write(to: record, atomically: true, encoding: .utf8)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifacts().map(\.title) == ["Smith family portrait"])
        #expect(reopened.artifacts().first?.slug == slug)

        // One finding for the duplicated record, not one per file in its folder.
        #expect(
            conflictingPaths(try reopened.verifyIntegrity())
                == ["artifacts/\(slug) (conflicted copy)/record.json"])
    }

    /// Fork (e)(i): the manifest's incumbent wins even when the copy sorts first,
    /// which is the case a lexicographic rule alone would get backwards.
    @Test func theManifestsIncumbentWinsOverALexicographicallyEarlierCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        let copy = root.appendingPathComponent("artifacts/aaa-sorts-first")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("artifacts/\(slug)"), to: copy)
        let record = copy.appendingPathComponent("record.json")
        try String(contentsOf: record, encoding: .utf8)
            .replacingOccurrences(of: "Smith family portrait", with: "STALE portrait")
            .write(to: record, atomically: true, encoding: .utf8)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifact(withID: artifact.uid)?.title == "Smith family portrait")
        #expect(
            conflictingPaths(try reopened.verifyIntegrity())
                == ["artifacts/aaa-sorts-first/record.json"])
    }

    /// **What Dropbox actually leaves**: a *file*-level conflict inside the
    /// folder. It used to land in "Stray Files" — the one classification that
    /// invites deleting it unread — and is reported once, as the copy it is
    /// (`/code-review`).
    @Test func aCopyOfARecordFileInsideItsFolderIsAConflictingCopyNotAStray() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        try copyAside(
            root.appendingPathComponent("artifacts/\(slug)/record.json"),
            as: "record (conflicted copy).json",
            replacing: "Smith family portrait", with: "STALE portrait")

        let report = try archive.verifyIntegrity()
        let path = "artifacts/\(slug)/record (conflicted copy).json"
        #expect(report.issues == [.conflictingCopy(path: path)])
    }

    /// A genuine stray — payload nobody claims — is untouched by any of this, and
    /// a non-JSON file is never read in to find out it is not a record.
    @Test func anOrdinaryStrayIsStillAStray() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        try Data("not a record".utf8).write(
            to: root.appendingPathComponent("artifacts/\(slug)/leftover.tiff"))

        let report = try archive.verifyIntegrity()
        #expect(report.issues == [.unreferencedFile(path: "artifacts/\(slug)/leftover.tiff")])
    }

    /// The folder-level twin of a misnamed conclusion: `record.json` renamed
    /// out of the way, so nothing in that folder is loaded at all.
    @Test func aRenamedRecordFileLeavesTheArtifactUnderTheWrongName() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        let record = root.appendingPathComponent("artifacts/\(slug)/record.json")
        try FileManager.default.moveItem(
            at: record,
            to: record.deletingLastPathComponent()
                .appendingPathComponent("record (conflicted copy).json"))
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifacts().isEmpty)

        let report = try reopened.verifyIntegrity()
        #expect(
            report.issues.contains(
                .misnamedRecord(
                    path: "artifacts/\(slug)/record (conflicted copy).json",
                    uid: artifact.uid.raw)))
        #expect(conflictingPaths(report).isEmpty)
    }

    // MARK: - What the report does not do

    /// Fork (b): reported, never moved. The bytes are the only copy of what the
    /// other machine wrote, the provider re-delivers them until the conflict is
    /// resolved at its source, and quarantining would mutate the package on a
    /// *read*.
    @Test func verifyingLeavesBothFilesExactlyWhereTheyAreAndConverges() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let sidecar = personSidecar(in: root, person.uid)
        let copy = try copyAside(
            sidecar, as: "\(person.uid.raw) (Ada's conflicted copy 2026-08-29).json",
            replacing: "Smith", with: "Smyth")

        let first = try archive.verifyIntegrity()
        let second = try archive.verifyIntegrity()
        #expect(first.issues == second.issues)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: sidecar.path))
        #expect(fm.fileExists(atPath: copy.path))
        #expect(!fm.fileExists(atPath: root.appendingPathComponent(".damaged").path))
        #expect(try String(contentsOf: copy, encoding: .utf8).contains("Smyth"))
    }

    /// Nothing about a copy is a difference between recorded and actual bytes, so
    /// there is nothing for a rebaseline to bless — and offering one would be a
    /// scary confirmation followed by nothing changing.
    @Test func neitherFindingIsRebaselinable() {
        let copy = IntegrityReport.Issue.conflictingCopy(path: "conclusions/persons/x.json")
        #expect(!copy.isResolvableByRebaseline)
        #expect(copy.path == "conclusions/persons/x.json")

        let misnamed = IntegrityReport.Issue.misnamedRecord(
            path: "conclusions/persons/y.json", uid: "PER-1")
        #expect(!misnamed.isResolvableByRebaseline)
        #expect(misnamed.path == "conclusions/persons/y.json")
    }

    // MARK: - The tie-break itself

    /// The rule must not depend on the order the filesystem hands folders back,
    /// or two machines walking one directory could disagree about which file is
    /// the record. Asserted against both orders rather than trusting either.
    @Test func theArtifactTieBreakIsIndependentOfEnumerationOrder() {
        let incumbent = "artifacts/portrait/record.json"
        let copy = "artifacts/aaa-copy/record.json"

        #expect(
            RecordDiscovery.chooseArtifactRecord(
                from: [incumbent, copy], incumbents: [incumbent]) == incumbent)
        #expect(
            RecordDiscovery.chooseArtifactRecord(
                from: [copy, incumbent], incumbents: [incumbent]) == incumbent)
    }

    /// With no incumbent — an artifact that arrived together with its copy in one
    /// sync, or a manifest written before slice 49 that names no records at all —
    /// the first path wins: arbitrary, but the same on every machine, which is
    /// the property that matters.
    @Test func withNoIncumbentTheFirstPathWins() {
        let a = "artifacts/aaa-copy/record.json"
        let b = "artifacts/portrait/record.json"

        #expect(RecordDiscovery.chooseArtifactRecord(from: [a, b], incumbents: []) == a)
        #expect(RecordDiscovery.chooseArtifactRecord(from: [b, a], incumbents: []) == a)
        #expect(RecordDiscovery.chooseArtifactRecord(from: [], incumbents: []) == nil)
    }

    /// **And it must not be arbitrary in the provider's favour** (`/code-review`).
    /// Compared as whole paths, `' '` (0x20) and `'('` (0x28) both sort under the
    /// separator `'/'` (0x2F), so both providers' names beat the original
    /// deterministically — on exactly the archives with no incumbent to save
    /// them. Compared at the folder, the original is a strict prefix and wins.
    @Test func withNoIncumbentAProvidersOwnNamingDoesNotWin() {
        let original = "artifacts/portrait/record.json"
        for copy in [
            "artifacts/portrait 2/record.json",
            "artifacts/portrait (Ada's conflicted copy 2026-08-29)/record.json",
        ] {
            #expect(
                RecordDiscovery.chooseArtifactRecord(from: [original, copy], incumbents: [])
                    == original)
            #expect(
                RecordDiscovery.chooseArtifactRecord(from: [copy, original], incumbents: [])
                    == original)
        }
    }

    /// The same shape end to end, on an archive whose manifest names no records —
    /// which is every archive written before slice 49.
    @Test func aDuplicatedFolderOnAPreCoverageArchiveStillServesTheOriginal() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        let folder = root.appendingPathComponent("artifacts/\(slug)")
        let copy = root.appendingPathComponent("artifacts/\(slug) 2")
        try FileManager.default.copyItem(at: folder, to: copy)
        let record = copy.appendingPathComponent("record.json")
        try String(contentsOf: record, encoding: .utf8)
            .replacingOccurrences(of: "Smith family portrait", with: "STALE portrait")
            .write(to: record, atomically: true, encoding: .utf8)

        // A manifest that covers nothing, as one written before 49 does.
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: manifestURL))
        manifest.files = []
        try GeneaLogicJSONCoding.encoder.encode(manifest).write(to: manifestURL)
        try discardIndex(in: root)

        let reopened = try Archive.open(at: root)
        #expect(reopened.artifact(withID: artifact.uid)?.title == "Smith family portrait")
        #expect(conflictingPaths(try reopened.verifyIntegrity()) == ["artifacts/\(slug) 2/record.json"])
    }

    /// **The report names the loser the index actually rejected, not the one the
    /// rule would pick today** (`/code-review`). A copy arriving moves no
    /// manifest, so nothing rebuilds; if the manifest has moved for some other
    /// reason since, re-deriving the winner here would name the very file the
    /// archive is serving.
    @Test func theReportNamesTheFolderTheIndexRejectedNotTheOneTheRuleWouldPickNow() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Smith family portrait"))
        let slug = try #require(archive.artifacts().first?.slug)

        let copy = root.appendingPathComponent("artifacts/zzz-sorts-last")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("artifacts/\(slug)"), to: copy)
        try discardIndex(in: root)

        // Rebuilt with the real manifest, so the index loads the incumbent.
        let reopened = try Archive.open(at: root)
        #expect(reopened.artifacts().first?.slug == slug)

        // Now strip the manifest's coverage *without* rebuilding, so the rule and
        // the index would disagree if the rule were re-run.
        let manifestURL = root.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: try Data(contentsOf: manifestURL))
        manifest.files.removeAll { $0.path == "artifacts/\(slug)/record.json" }
        try GeneaLogicJSONCoding.encoder.encode(manifest).write(to: manifestURL)

        let report = try reopened.verifyIntegrity()
        #expect(reopened.artifact(withID: artifact.uid)?.title == "Smith family portrait")
        #expect(conflictingPaths(report) == ["artifacts/zzz-sorts-last/record.json"])
    }

    /// Where the manifest names *both* — an archive that adopted a copy before
    /// this slice — the preference cannot decide, and the stable fallback must
    /// still apply rather than leaving it to enumeration order.
    @Test func twoIncumbentsFallBackToTheSameStableRule() {
        let a = "artifacts/aaa-copy/record.json"
        let b = "artifacts/portrait/record.json"

        #expect(RecordDiscovery.chooseArtifactRecord(from: [a, b], incumbents: [a, b]) == a)
        #expect(RecordDiscovery.chooseArtifactRecord(from: [b, a], incumbents: [a, b]) == a)
    }
}

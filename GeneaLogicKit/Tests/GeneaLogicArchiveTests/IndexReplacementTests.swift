import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import Synchronization
import Testing

/// Slice 69 — preserved copies outlive the index.
///
/// 58's copy of an unreadable record lives in the index, and is sometimes the
/// record's last. Three paths still destroyed it: replacing the database (a schema
/// bump, a corrupt file) unlinked it, an unfinished `quick_check` counted as
/// corruption and took that path, and crash recovery discarded the copy of every
/// record that went missing in its window rather than only the one it was removing.
@Suite struct IndexReplacementTests {

    private func personPath(_ person: Person) -> String {
        "conclusions/persons/\(person.uid.raw).json"
    }

    private func indexURL(in root: URL) -> URL {
        ArchiveLayout.indexDatabaseURL(in: root)
    }

    /// The files beside the index that a replacement kept — pending
    /// (`index-replaced-…`) or given up on (`index-unreadable-…`).
    private func keptIndexes(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: ArchiveLayout.indexDirectory(in: root).path
        )
        .filter { $0.hasPrefix("index-") && $0.hasSuffix(".sqlite") }
    }

    /// An index the open must replace: an older schema's.
    private func makeStale(_ root: URL) throws {
        try SQLiteDatabase(at: indexURL(in: root)).setUserVersion(ArchiveIndex.schemaVersion - 1)
    }

    // MARK: - Fork (a): a new file carries the old one's copies

    /// The copy an earlier rebuild kept survives the bump that replaces its file,
    /// and still restores the record exactly.
    @Test func aSchemaBumpKeepsAnExistingCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = personPath(person)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))
        #expect(try archive.rebuildIndex() == [path])

        try makeStale(root)
        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
        try reopened.repairRecord(atPath: path)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == original)
        #expect(try keptIndexes(in: root).isEmpty, "a file carried in full is not kept")
    }

    /// 58's note on v7: a record that turned unreadable since the last rebuild has
    /// its only copy in the old file's *live* rows, and a new file has none to
    /// stage. Carrying them is what keeps it.
    @Test func aRecordUnreadableAtTheBumpKeepsItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let charles = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = personPath(person)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))

        try makeStale(root)
        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecordPaths() == [path], "only the unreadable record")
        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
        #expect(reopened.persons().map(\.uid) == [charles.uid])
    }

    /// A file the carry cannot read in full is kept beside the index, never
    /// deleted, and the archive still opens on a fresh one.
    @Test func aGarbagePagedIndexIsKeptAside() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        for title in ["One", "Two", "Three"] { _ = try archive.addArtifact(.sample(title: title)) }
        let url = indexURL(in: root)
        var bytes = try Data(contentsOf: url)
        var state: UInt64 = 1
        for offset in 4096..<bytes.count {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[offset] = UInt8(truncatingIfNeeded: state >> 56)
        }
        try bytes.write(to: url)

        let reopened = try Archive.open(at: root)

        #expect(reopened.artifacts().map(\.title).sorted() == ["One", "Three", "Two"])
        let kept = try keptIndexes(in: root)
        #expect(kept.count == 1)
        #expect(kept.first?.hasPrefix("index-unreadable-") == true)
        let keptURL = ArchiveLayout.indexDirectory(in: root).appendingPathComponent(kept[0])
        #expect(try Data(contentsOf: keptURL) == bytes, "kept as it was found")
    }

    /// Not a database at all: nothing to carry, and nothing deleted.
    @Test func randomBytesAreKeptAside() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root).addArtifact(.sample(title: "One"))
        try Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(
            to: indexURL(in: root))

        #expect(try Archive.open(at: root).artifacts().map(\.title) == ["One"])
        #expect(try keptIndexes(in: root).count == 1)
    }

    // MARK: - Fork (b): a probe that could not run is no verdict

    /// `SQLITE_CORRUPT` and `SQLITE_NOTADB` — and their extended codes — are about
    /// the file; everything else is about the read.
    @Test func onlyCorruptionIsEvidence() {
        func error(_ code: Int32) -> ArchiveError {
            .indexError(context: "test", message: "", code: code)
        }
        #expect(SQLiteDatabase.isCorruption(error(11)))  // CORRUPT
        #expect(SQLiteDatabase.isCorruption(error(26)))  // NOTADB
        #expect(SQLiteDatabase.isCorruption(error(11 | (3 << 8))))  // CORRUPT_INDEX
        #expect(!SQLiteDatabase.isCorruption(error(10)))  // IOERR
        #expect(!SQLiteDatabase.isCorruption(error(10 | (2 << 8))))  // IOERR_SHORT_READ
        #expect(!SQLiteDatabase.isCorruption(error(5)))  // BUSY
        #expect(!SQLiteDatabase.isCorruption(error(7)))  // NOMEM
        #expect(!SQLiteDatabase.isCorruption(CocoaError(.fileReadUnknown)))
    }

    /// The issue's own example: another connection holds the database, so the
    /// probe cannot read it. The open fails and the file — copies and all — is
    /// exactly where it was; once the lock goes, the same open succeeds as-is.
    @Test func aProbeThatCannotRunRefusesTheOpen() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(personPath(person)))
        try archive.rebuildIndex()
        let before = try Data(contentsOf: indexURL(in: root))

        let holder = try SQLiteDatabase(at: indexURL(in: root))
        try holder.exec("BEGIN EXCLUSIVE;")
        #expect {
            _ = try Archive.open(at: root)
        } throws: { error in
            guard case ArchiveError.indexError(_, _, let code) = error else { return false }
            return code & 0xff == 5  // BUSY
        }
        try holder.exec("ROLLBACK;")

        #expect(try Data(contentsOf: indexURL(in: root)) == before)
        #expect(try keptIndexes(in: root).isEmpty)
        #expect(try Archive.open(at: root).preservedRecordPaths() == [personPath(person)])
    }

    // MARK: - Fork (c): recovery discards only what the died write unlinked

    /// A removal cut before its commit discards its own copy; a record lost out of
    /// band in the same window keeps its copy, its entry and its finding.
    @Test func aLossBesideACutRemovalKeepsItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let removed = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let lost = try archive.addPerson(.sample(given: "Charles", surname: "Babbage"))
        try IndexDirtyMarker.set(in: root)
        IndexDirtyMarker.journalRemoval(of: personPath(removed), in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(personPath(removed)))
        try FileManager.default.removeItem(at: root.appendingPathComponent(personPath(lost)))

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecordPaths() == [personPath(lost)])
        #expect(try reopened.standingFindings().vanished == [personPath(lost)])
        #expect(try reopened.verifyIntegrity().issues.contains(.missingFile(path: personPath(lost))))
        try reopened.repairRecord(atPath: personPath(lost))
        #expect(reopened.persons().map(\.uid) == [lost.uid])
    }

    /// With no journal — a sentinel from before slice 68 — nothing is discarded:
    /// the cut removal reads as a loss with a copy, the side a human can still
    /// discard.
    @Test func anUnjournaledSentinelDiscardsNothing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(personPath(person)))
        try IndexDirtyMarker.set(in: root)

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecordPaths() == [personPath(person)])
        try reopened.deleteVanishedRecord(atPath: personPath(person))
        #expect(try reopened.preservedRecordPaths().isEmpty)
    }

    /// An artifact leaves by rename into the trash, never through
    /// `removeAuthoredFile`, so it journals its record itself: a real cut after
    /// the move recovers to a deletion, not a vanished record beside its own trash
    /// entry.
    @Test func aCutArtifactRemovalDiscardsItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Letter"))
        let image = TestSupport.makeTempDirectory().appendingPathComponent("image.genea")
        let taken = Mutex(false)
        WriteCheckpoint.install(root: root) { event, url in
            taken.withLock { taken in
                guard !taken, event == "moved", url.path.contains("/.trash/") else { return }
                taken = (try? FileManager.default.copyItem(at: root, to: image)) != nil
            }
        }
        defer { WriteCheckpoint.remove(root: root) }
        _ = try archive.removeArtifact(artifact.uid)
        #expect(taken.withLock { $0 }, "no checkpoint matched")

        let reopened = try Archive.open(at: image)

        #expect(try reopened.preservedRecordPaths().isEmpty)
        #expect(try reopened.standingFindings().vanished.isEmpty)
        #expect(try reopened.restoreFromTrash(artifact.uid).title == "Letter")
    }

    // MARK: - Review: a file moved aside is carried by whichever open comes next

    /// The state an open killed between the move and the carry leaves: no index,
    /// and the old one under its pending name. The next open carries it.
    @Test func aPendingFileIsCarriedByTheNextOpen() throws {
        let (root, path, original) = try archiveWithACopy()
        try FileManager.default.moveItem(
            at: indexURL(in: root),
            to: ArchiveLayout.indexDirectory(in: root)
                .appendingPathComponent("index-replaced-20260101-000000.sqlite"))

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
        #expect(try keptIndexes(in: root).isEmpty)
    }

    /// Or the open got as far as creating the new file: it is healthy and
    /// current, so only the pending file says a rebuild is owed.
    @Test func aPendingFileBesideAHealthyIndexIsCarriedToo() throws {
        let (root, path, original) = try archiveWithACopy()
        try FileManager.default.copyItem(
            at: indexURL(in: root),
            to: ArchiveLayout.indexDirectory(in: root)
                .appendingPathComponent("index-replaced-20260101-000000.sqlite"))
        try FileManager.default.removeItem(at: indexURL(in: root))
        _ = try ArchiveIndex.open(at: indexURL(in: root))

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
        #expect(try keptIndexes(in: root).isEmpty)
    }

    /// One that cannot be carried is kept under its other name and not tried
    /// again, so it does not make every later open a rebuild.
    @Test func anUnreadablePendingFileIsKeptAndNotRetried() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root).addArtifact(.sample(title: "One"))
        let pending = ArchiveLayout.indexDirectory(in: root)
            .appendingPathComponent("index-replaced-20260101-000000.sqlite")
        try Data(repeating: 0x5A, count: 8192).write(to: pending)

        _ = try Archive.open(at: root)
        let kept = try keptIndexes(in: root)
        #expect(kept.count == 1 && kept[0].hasPrefix("index-unreadable-"))

        let stamp = try #require(try attribute(.modificationDate, of: indexURL(in: root)) as? Date)
        _ = try Archive.open(at: root)
        #expect(try attribute(.modificationDate, of: indexURL(in: root)) as? Date == stamp)
        #expect(try keptIndexes(in: root) == kept)
    }

    // MARK: - Review: each probe, and what failing twice means

    private func attribute(_ key: FileAttributeKey, of url: URL) throws -> Any? {
        try FileManager.default.attributesOfItem(atPath: url.path)[key]
    }

    /// An archive whose index holds the copy of an unreadable person.
    private func archiveWithACopy() throws -> (URL, path: String, original: Data) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Ada", surname: "Lovelace"))
        let path = personPath(person)
        let original = try Data(contentsOf: root.appendingPathComponent(path))
        try Data("{ not JSON".utf8).write(to: root.appendingPathComponent(path))
        try archive.rebuildIndex()
        return (root, path, original)
    }

    private static let ioError = ArchiveError.indexError(context: "probe", message: "disk I/O error", code: 10)

    /// The issue's case, at every probe: a check that fails once and then runs
    /// is a check that passed — the file is used as-is, nothing moved.
    @Test(arguments: [IndexProbeFault.Probe.open, .userVersion, .quickCheck, .schema])
    func aProbeThatFailsOnceUsesTheFileAsIs(_ probe: IndexProbeFault.Probe) throws {
        let (root, path, original) = try archiveWithACopy()
        let failures = Mutex(0)
        IndexProbeFault.install(at: indexURL(in: root)) { reached in
            guard reached == probe else { return }
            try failures.withLock { failures in
                failures += 1
                if failures == 1 { throw Self.ioError }
            }
        }
        defer { IndexProbeFault.remove(at: indexURL(in: root)) }
        let inode = try #require(try attribute(.systemFileNumber, of: indexURL(in: root)) as? NSNumber)

        let reopened = try Archive.open(at: root)

        #expect(failures.withLock { $0 } == 2)
        #expect(try attribute(.systemFileNumber, of: indexURL(in: root)) as? NSNumber == inode)
        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
    }

    /// Failing twice, it is replaced (revised on `/code-review`): a persistent
    /// `IOERR` must not make the archive unopenable for good, and replacing
    /// keeps the copy.
    @Test(arguments: [IndexProbeFault.Probe.open, .userVersion, .quickCheck, .schema])
    func aProbeThatKeepsFailingReplacesTheFileAndKeepsTheCopy(_ probe: IndexProbeFault.Probe) throws {
        let (root, path, original) = try archiveWithACopy()
        IndexProbeFault.install(at: indexURL(in: root)) { reached in
            if reached == probe { throw Self.ioError }
        }
        defer { IndexProbeFault.remove(at: indexURL(in: root)) }

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecord(atPath: path)?.json == original)
        #expect(try keptIndexes(in: root).isEmpty)
    }

    /// A file another connection holds is in use, not broken, at any probe.
    @Test(arguments: [IndexProbeFault.Probe.open, .userVersion, .quickCheck, .schema])
    func aProbeFindingTheFileInUseRefusesTheOpen(_ probe: IndexProbeFault.Probe) throws {
        let (root, path, _) = try archiveWithACopy()
        let before = try Data(contentsOf: indexURL(in: root))
        IndexProbeFault.install(at: indexURL(in: root)) { reached in
            if reached == probe {
                throw ArchiveError.indexError(context: "probe", message: "database is locked", code: 5)
            }
        }
        #expect(throws: ArchiveError.self) { _ = try Archive.open(at: root) }
        IndexProbeFault.remove(at: indexURL(in: root))

        #expect(try Data(contentsOf: indexURL(in: root)) == before)
        #expect(try Archive.open(at: root).preservedRecordPaths() == [path])
    }

    // MARK: - Review: a restore takes back its removal's journal entry

    /// While a sentinel stands, an artifact removed and restored from the trash
    /// journals both; a later out-of-band loss of its record is a loss, not the
    /// removal finishing.
    @Test func aRestoredArtifactsLaterLossKeepsItsCopy() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Letter"))
        try IndexDirtyMarker.set(in: root)
        _ = try archive.removeArtifact(artifact.uid)
        _ = try archive.restoreFromTrash(artifact.uid)
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/record.json"
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
        #expect(IndexDirtyMarker.isSet(in: root))

        let reopened = try Archive.open(at: root)

        #expect(try reopened.preservedRecordPaths() == [path])
    }
}

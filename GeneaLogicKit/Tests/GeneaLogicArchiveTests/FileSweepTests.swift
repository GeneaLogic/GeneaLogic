import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 57 — the cheap sweep: existence and size for every manifest entry, one
/// `stat` each, no reads.
///
/// It sits between the two calls that already exist, and the tests that matter
/// most here are the ones holding those two lines: it finds damage
/// `standingFindings()` cannot (a file edited on disk commits nothing to the
/// index), and it misses damage only `verifyIntegrity()` can find (anything that
/// keeps a file's length). A refactor that blurred either line would still pass
/// a suite that only checked the happy path.
@Suite struct FileSweepTests {

    /// Attaches one file and hands back everything needed to damage it on disk.
    private func archiveWithOneFile(contents: String) throws -> (
        archive: Archive, root: URL, filePath: String, fileURL: URL
    ) {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample())
        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: contents)
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        let path = "artifacts/\(slug)/\(attached.entry.path)"
        return (archive, root, path, root.appendingPathComponent(path))
    }

    @Test func aCleanArchiveSweepsClean() throws {
        let (archive, _, _, _) = try archiveWithOneFile(contents: "original")

        let report = archive.sweepFileSizes()
        #expect(report.foundNothingMissing)
        #expect(report.issues.isEmpty)
    }

    /// `checkedFileCount` exists so "found nothing" can be told apart from "had
    /// nothing to check" — the ambiguity that already cost `IntegrityReport` a
    /// hand-test. Asserted as a delta rather than a constant, since what else the
    /// manifest tracks (the schema spec) is not this slice's business.
    @Test func theSweepSaysHowMuchItChecked() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample())
        // Baselined after the artifact, not before: its `record.json` is
        // manifest-tracked too (slice 49), so an earlier baseline measures two
        // additions and calls it one.
        let before = archive.sweepFileSizes().checkedFileCount

        let source = try TestSupport.makeSourceFile(named: "scan.tif", contents: "original")
        _ = try archive.attachFile(copyingFrom: source, to: artifact.uid, role: .preservationMaster)

        #expect(archive.sweepFileSizes().checkedFileCount == before + 1)
    }

    @Test func aDeletedFileIsMissing() throws {
        let (archive, _, path, fileURL) = try archiveWithOneFile(contents: "original")
        try FileManager.default.removeItem(at: fileURL)

        let report = archive.sweepFileSizes()
        #expect(!report.foundNothingMissing)
        #expect(report.issues == [.missingFile(path: path)])
    }

    @Test func aTruncatedFileIsASizeMismatch() throws {
        let (archive, _, path, fileURL) = try archiveWithOneFile(contents: "original")
        try Data("orig".utf8).write(to: fileURL)

        let report = archive.sweepFileSizes()
        #expect(report.issues == [.sizeMismatch(path: path, expected: 8, actual: 4)])
    }

    @Test func aGrownFileIsAlsoASizeMismatch() throws {
        let (archive, _, path, fileURL) = try archiveWithOneFile(contents: "original")
        try Data("original and then some".utf8).write(to: fileURL)

        let report = archive.sweepFileSizes()
        #expect(report.issues == [.sizeMismatch(path: path, expected: 8, actual: 22)])
    }

    /// A directory where a tracked file belongs is absent in the sense that
    /// matters, and is what `verifyIntegrity()` reports for the same shape.
    @Test func aDirectoryWhereAFileBelongsIsMissing() throws {
        let (archive, _, path, fileURL) = try archiveWithOneFile(contents: "original")
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        #expect(archive.sweepFileSizes().issues == [.missingFile(path: path)])
    }

    /// **The cheap/expensive line, and the reason the report is not an
    /// `IntegrityReport`.** Damage that keeps a file's length is invisible here —
    /// which is most bit rot — and this sweep must never be presented as though
    /// it weren't. The expensive call still catches it, so nothing is lost; it
    /// just isn't free.
    @Test func sameSizeRotIsInvisibleToTheSweepAndVisibleToTheHashPass() throws {
        let (archive, _, _, fileURL) = try archiveWithOneFile(contents: "original")
        try Data("rotted!!".utf8).write(to: fileURL)  // same 8 bytes

        let report = archive.sweepFileSizes()
        #expect(report.foundNothingMissing)
        #expect(report.checkedFileCount > 0)  // it did look; it just cannot see this

        #expect(try !archive.verifyIntegrity().isClean)
    }

    /// The other line: 56 reports what the archive already knows, and a file
    /// edited on disk tells it nothing. That gap is what un-parked this slice
    /// off 56's hand-test, so it is held as a test rather than a comment.
    @Test func aDeletedFileIsInvisibleToStandingFindings() throws {
        let (archive, _, _, fileURL) = try archiveWithOneFile(contents: "original")
        try FileManager.default.removeItem(at: fileURL)

        #expect(try archive.standingFindings().isEmpty)
        #expect(!archive.sweepFileSizes().foundNothingMissing)
    }

    /// Fork (d): the sweep reports through the kinds `verifyIntegrity()` already
    /// produces, and reaches for no others — a `.checksumMismatch` or an
    /// `.unreadableRecord` from here would be a claim it did not pay for.
    @Test func theSweepOnlyEverReportsTheTwoCheapKinds() throws {
        let (archive, root, _, fileURL) = try archiveWithOneFile(contents: "original")
        try FileManager.default.removeItem(at: fileURL)
        let person = try archive.addPerson(.sample())
        try Data("not JSON".utf8).write(
            to: root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json"))
        try archive.rebuildIndex()

        for issue in archive.sweepFileSizes().issues {
            switch issue {
            case .missingFile, .sizeMismatch: break
            default: Issue.record("unexpected kind from the cheap sweep: \(issue)")
            }
        }
        // …while the record damage is still reported, by the call that owns it.
        #expect(!(try archive.standingFindings().isEmpty))
    }

    // MARK: - Agreeing with the expensive call

    /// **The two calls must describe one on-disk state the same way.** A mutation
    /// that died between its sidecar write and its manifest write leaves a size
    /// difference, and calling that corruption is an accusation the archive's own
    /// history contradicts — so the cheap sweep classifies it exactly as
    /// `verifyIntegrity()` does. Without this the banner said "2 files are not
    /// the size the archive recorded" and the panel behind it said a change
    /// didn't finish (review finding, 57).
    @Test func anInterruptedWriteIsNotCalledASizeMismatch() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let recordPath = "conclusions/persons/\(person.uid.raw).json"

        // What an interrupted mutation leaves — the sidecar it got as far as, and
        // the marker; `open()` promotes the pair.
        try Data("{}".utf8).write(to: root.appendingPathComponent(recordPath))
        try Data().write(to: root.appendingPathComponent(".index/\(MachineKey.current)/dirty"))
        let reopened = try Archive.open(at: root)

        #expect(reopened.sweepFileSizes().issues == [.interruptedWrite(path: recordPath)])
        // …and the expensive call says the same thing about the same bytes.
        #expect(try reopened.verifyIntegrity().issues.contains(.interruptedWrite(path: recordPath)))
    }

    /// The gate is `isEngineAuthored`, not "anything during an interrupted
    /// write": a preservation master is never written by the mutation that died,
    /// so a wrong-sized one is still a wrong-sized one.
    @Test func aPayloadFileIsStillASizeMismatchDuringAnInterruptedWrite() throws {
        let (archive, root, path, fileURL) = try archiveWithOneFile(contents: "original")
        try Data().write(to: root.appendingPathComponent(".index/\(MachineKey.current)/dirty"))
        let reopened = try Archive.open(at: root)
        _ = archive
        try Data("orig".utf8).write(to: fileURL)

        #expect(
            reopened.sweepFileSizes().issues
                == [.sizeMismatch(path: path, expected: 8, actual: 4)])
    }

    /// A local archive has no cloud placeholders. The dataless count's real
    /// behaviour was settled by measurement rather than by a test (fork c) —
    /// nothing in CI can produce an `SF_DATALESS` file — so what is held here is
    /// only that a healthy local sweep does not invent one.
    @Test func nothingLocalIsDataless() throws {
        let (archive, _, _, _) = try archiveWithOneFile(contents: "original")
        #expect(archive.sweepFileSizes().datalessFileCount == 0)
    }
}

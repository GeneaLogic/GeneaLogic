import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 67 — a Continuity Camera scan survives its own ingest.
///
/// `ingestScanned` used to delete the scan's temp file as soon as `ingest` or
/// `attach` returned, which since 52 is before the write has run. Each test
/// hands it a real file laid out the way `ContinuityScanner` writes one (a
/// folder per capture) and checks both halves: what reached the archive, and
/// what became of the scan — deleted once it landed, kept when it was refused.
@MainActor
@Suite struct ScanIngestTests {

    @Test func aScanAddedAsANewArtifactLandsAndIsDeleted() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let scan = try makeScan(Self.firstPage, in: scans)
        await model.act { model.ingestScanned([scan], mode: .addMedia) }

        #expect(model.actionError == nil)
        let id = try #require(model.artifacts.first?.uid)
        #expect(try contents(of: id, in: model) == [Self.firstPage])
        #expect(isGone(scan))
    }

    @Test func aScanAttachedToAnArtifactLandsAndIsDeleted() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let first = try makeScan(Self.firstPage, in: scans)
        await model.act { model.ingestScanned([first], mode: .addMedia) }
        let id = try #require(model.artifacts.first?.uid)

        let second = try makeScan(Self.secondPage, in: scans)
        await model.act { model.ingestScanned([second], mode: .attach(to: id)) }

        #expect(model.actionError == nil)
        #expect(try Set(contents(of: id, in: model)) == [Self.firstPage, Self.secondPage])
        #expect(isGone(first))
        #expect(isGone(second))
    }

    /// The refusal must be the engine's verdict on the *target*, not "source
    /// not readable" — which is what the pre-67 code produced here, having
    /// deleted the scan before the write ran. That is what tells the two apart.
    @Test func aRefusedScanIsKeptAndOffered() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let scan = try makeScan(Self.firstPage, in: scans)
        let nowhere = ArtifactID("ART-00000000-0000-7000-8000-000000000000")
        await model.act { model.ingestScanned([scan], mode: .attach(to: nowhere)) }

        #expect(model.actionError != nil)
        let message = model.errorMessage
        #expect(message.contains("No artifact with id"), "got: \(message)")
        #expect(message.contains("kept"), "got: \(message)")
        #expect(model.keptScans == [scan])
        #expect(FileManager.default.fileExists(atPath: scan.path))

        // Dismissing the alert forgets the offer, not the file.
        model.isShowingError = false
        #expect(model.keptScans.isEmpty)
        #expect(FileManager.default.fileExists(atPath: scan.path))
    }

    /// The case that settled fork (b) the other way: a refusal that a retry
    /// would get past. Another process holds the lock past the (shortened)
    /// timeout, the write fails `archiveBusy`, and the scan is still there.
    @Test func aScanRefusedByABusyArchiveIsKept() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let archive = try #require(model.archive)
        archive.lockTimeout = 0.2
        let scan = try makeScan(Self.firstPage, in: scans)

        try await AppTestSupport.withCompetitor(holdingTheLockAt: root) {
            await model.act { model.ingestScanned([scan], mode: .addMedia) }
        }

        #expect(model.actionError != nil)
        let message = model.errorMessage
        #expect(message.localizedCaseInsensitiveContains("another"), "got: \(message)")
        #expect(message.contains("The scan was kept"), "got: \(message)")
        #expect(model.keptScans == [scan])
        #expect(FileManager.default.fileExists(atPath: scan.path))
    }

    /// Scans arrive one capture at a time, so two can be refused before the
    /// first alert is dismissed. Both stay offered (cloud review of 67–71): the
    /// second used to replace the first, whose file then had no way back.
    @Test func twoRefusedScansAreBothKept() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let nowhere = ArtifactID("ART-00000000-0000-7000-8000-000000000000")
        let first = try makeScan(Self.firstPage, in: scans)
        await model.act { model.ingestScanned([first], mode: .attach(to: nowhere)) }
        let second = try makeScan(Self.secondPage, in: scans)
        await model.act { model.ingestScanned([second], mode: .attach(to: nowhere)) }

        #expect(model.keptScans == [first, second])
        #expect(model.errorMessage.contains("The scans were kept"), "got: \(model.errorMessage)")
    }

    /// A later error with nothing to do with scans replaces the text, not the
    /// offer: the alert still says the scan is kept, which is still true.
    @Test func anUnrelatedErrorDoesNotDropAKeptScan() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let nowhere = ArtifactID("ART-00000000-0000-7000-8000-000000000000")
        let scan = try makeScan(Self.firstPage, in: scans)
        await model.act { model.ingestScanned([scan], mode: .attach(to: nowhere)) }
        model.actionError = "Something else went wrong."

        #expect(model.keptScans == [scan])
        #expect(
            model.errorMessage
                == "Something else went wrong.\n\nThe scan was kept. Show it in Finder to add it again.")
    }

    /// With no archive, `mutate` returns before its work closure — so the scan
    /// path decides for itself, and keeps the scan.
    @Test func aScanWithNoArchiveOpenIsKept() async throws {
        let scans = try makeScansFolder()
        defer { try? FileManager.default.removeItem(at: scans) }
        let model = ArchiveModel(url: scans.appendingPathComponent("never-opened"))
        #expect(model.archive == nil)

        let scan = try makeScan(Self.firstPage, in: scans)
        model.ingestScanned([scan], mode: .addMedia)

        #expect(model.actionError?.hasPrefix("Open an archive") == true)
        #expect(model.keptScans == [scan])
        #expect(FileManager.default.fileExists(atPath: scan.path))
    }

    /// Not scan-specific: any ingest whose artifact is created and whose file
    /// then fails to attach. The artifact exists, so it must be undoable and
    /// shown — before 67's review it was neither.
    @Test func anIngestWhoseFileFailsLeavesAnUndoableArtifact() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        let scans = try makeScansFolder()
        defer { cleanUp(root, scans) }

        let missing = scans.appendingPathComponent("not-there.pdf")
        await model.act { model.ingest([missing]) }

        #expect(model.actionError != nil)
        let id = try #require(model.artifacts.first?.uid)
        #expect(model.lastCreatedArtifact == id)

        await model.undoAndSettle()
        #expect(model.artifacts.isEmpty)
    }

    // MARK: - Helpers

    private static let firstPage = Data("a scanned page".utf8)
    private static let secondPage = Data("another scanned page".utf8)

    /// A per-test folder for this suite's fake scans, removed by `cleanUp` even
    /// when an assertion fails — so a regression that never deletes a scan does
    /// not also litter the test host's temp directory.
    private func makeScansFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-scans-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A scan the way `ContinuityScanner.deliver` lays one out: its own folder,
    /// a readable name inside it.
    private func makeScan(_ bytes: Data, in scans: URL) throws -> URL {
        let folder = scans.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Scan 2026-10-04 at 16.00.00.pdf")
        try bytes.write(to: url)
        return url
    }

    /// A landed scan takes its capture folder with it.
    private func isGone(_ scan: URL) -> Bool {
        !FileManager.default.fileExists(atPath: scan.deletingLastPathComponent().path)
    }

    /// The bytes of every file the artifact holds, as the archive has them.
    private func contents(of id: ArtifactID, in model: ArchiveModel) throws -> [Data] {
        let files = try #require(model.fullArtifact(id)?.files)
        return try files.map { file in
            try Data(contentsOf: #require(model.fileURL(of: file.uid, in: id)))
        }
    }

    private func cleanUp(_ root: URL, _ scans: URL) {
        AppTestSupport.remove(root)
        try? FileManager.default.removeItem(at: scans)
    }
}

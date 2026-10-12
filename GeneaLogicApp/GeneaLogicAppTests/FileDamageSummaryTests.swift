import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 57 — how the cheap sweep says what it found, and where it says nothing.
///
/// The wording *is* the slice's stated main risk: a cheap check that implies an
/// expensive check's assurance is worse than no check. So the rule with the most
/// riding on it — a clean sweep produces no summary at all — is held here as a
/// test rather than as a convention someone could helpfully "fix" later by adding
/// a reassuring green line.
@MainActor
@Suite struct FileDamageSummaryTests {

    private func report(_ issues: [IntegrityReport.Issue]) -> Archive.FileSweepReport {
        Archive.FileSweepReport(issues: issues, checkedFileCount: 340)
    }

    // MARK: - The clean sweep says nothing

    /// **The load-bearing one.** There is no value to render for a healthy
    /// archive, which is what makes "✓ 340 files checked" unwritable rather than
    /// merely discouraged.
    @Test func aCleanSweepHasNoSummaryAtAll() {
        #expect(FileDamageSummary(report([])) == nil)
        #expect(Archive.FileSweepReport(checkedFileCount: 340).foundNothingMissing)
    }

    /// A report carrying only kinds the sweep cannot produce is still nothing to
    /// say — counting one would be claiming a check nobody paid for.
    @Test func kindsTheSweepCannotProduceAreNotSummarised() {
        #expect(
            FileDamageSummary(
                report([.unreadableRecord(path: "conclusions/x.json", reason: .undecodable)]))
                == nil)
    }

    // MARK: - Headlines

    @Test func oneMissingFile() throws {
        let summary = try #require(FileDamageSummary(report([.missingFile(path: "a/scan.tif")])))
        #expect(summary.headline == "1 file is missing from this archive")
        #expect(summary.missingCount == 1)
    }

    @Test func severalMissingFiles() throws {
        let summary = try #require(
            FileDamageSummary(
                report([
                    .missingFile(path: "a/scan.tif"), .missingFile(path: "b/photo.jpg"),
                ])))
        #expect(summary.headline == "2 files are missing from this archive")
    }

    @Test func oneWrongSizeFile() throws {
        let summary = try #require(
            FileDamageSummary(
                report([.sizeMismatch(path: "a/scan.tif", expected: 700_319, actual: 4096)])))
        #expect(summary.headline == "1 file is not the size the archive recorded")
        #expect(summary.wrongSizeCount == 1)
    }

    /// Mixed findings say "missing or the wrong size" rather than picking one,
    /// because either half alone misdescribes some of the files it is counting.
    @Test func missingAndWrongSizeTogether() throws {
        let summary = try #require(
            FileDamageSummary(
                report([
                    .missingFile(path: "a/scan.tif"),
                    .sizeMismatch(path: "b/photo.jpg", expected: 10, actual: 4),
                ])))
        #expect(summary.headline == "2 files are missing or the wrong size")
        #expect(summary.totalCount == 2)
    }

    // MARK: - Naming the files

    /// Files have no browse list of their own, so the banner is the only place
    /// they are ever named — the same reason 56's banner names the record kinds
    /// with no list.
    @Test func upToThreeFilesAreNamed() throws {
        let summary = try #require(
            FileDamageSummary(
                report([
                    .missingFile(path: "c/three.tif"), .missingFile(path: "a/one.tif"),
                    .missingFile(path: "b/two.tif"),
                ])))
        #expect(summary.pathSummary == "one.tif · two.tif · three.tif")
    }

    @Test func beyondThreeTheRestAreCounted() throws {
        let summary = try #require(
            FileDamageSummary(
                report(
                    (1...5).map { .missingFile(path: "scans/file-\($0).tif") })))
        #expect(summary.pathSummary == "file-1.tif · file-2.tif · file-3.tif · …and 2 more")
    }

    /// **Where "the folder was the redundant half" inverts.** Every artifact
    /// sidecar is `record.json`, so the file name identifies nothing and two
    /// damaged records would read "record.json · record.json" (review finding,
    /// 57). The folder is the identity for these, so it comes back.
    @Test func damagedRecordsAreNamedByTheirFolder() throws {
        let summary = try #require(
            FileDamageSummary(
                report([
                    .missingFile(path: "artifacts/deed-of-sale-1899/record.json"),
                    .missingFile(path: "artifacts/parish-register-1871/record.json"),
                ])))
        #expect(
            summary.pathSummary
                == "deed-of-sale-1899/record.json · parish-register-1871/record.json"
        )
    }

    /// A single damaged record is qualified too — "record.json" alone names
    /// nothing, whether or not a second one collides with it.
    @Test func oneDamagedRecordIsAlsoQualified() throws {
        let summary = try #require(
            FileDamageSummary(
                report([.missingFile(path: "artifacts/deed-of-sale-1899/record.json")])))
        #expect(summary.pathSummary == "deed-of-sale-1899/record.json")
    }

    /// The same rule generalises: two payload files that happen to share a name
    /// are qualified, and unambiguous ones are left short.
    @Test func collidingFileNamesAreQualifiedAndOthersAreNot() throws {
        let summary = try #require(
            FileDamageSummary(
                report([
                    .missingFile(path: "artifacts/deed-1899/scan.tif"),
                    .missingFile(path: "artifacts/parish-1871/scan.tif"),
                    .missingFile(path: "artifacts/manifest-1903/emigration.tif"),
                ])))
        #expect(
            summary.pathSummary
                == "deed-1899/scan.tif · emigration.tif · parish-1871/scan.tif")
    }

    /// The visible line is file names, so the archive-relative paths have to
    /// survive somewhere — otherwise shortening it would have cost the user the
    /// one thing that locates the file.
    @Test func theTooltipKeepsEveryPathInFull() throws {
        let summary = try #require(
            FileDamageSummary(
                report(
                    (1...5).map { .missingFile(path: "artifacts/deed-\($0)/file-\($0).tif") })))
        #expect(summary.pathTooltip.split(separator: "\n").count == 5)
        #expect(summary.pathTooltip.hasPrefix("artifacts/deed-1/file-1.tif"))
    }

    // MARK: - End to end, through the model

    /// Seeds an archive with one attached file and returns where it landed.
    @MainActor
    private func seedOneFile(_ model: ArchiveModel, at root: URL) throws -> String {
        let archive = try #require(model.archive)
        let artifact = try archive.addArtifact(ArtifactDraft(title: "Deed", mediaType: .image))
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("source-\(UUID().uuidString).tif")
        try Data("original".utf8).write(to: source)
        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster)
        let slug = try #require(archive.artifacts().first?.slug)
        return "artifacts/\(slug)/\(attached.entry.path)"
    }

    /// **The case that un-parked this slice.** A file deleted on disk commits
    /// nothing to the index, so 56's findings stay empty and 51's poll never
    /// fires — the damage is invisible until someone pays for a full verify.
    /// Here the window is already open, and the sweep is what closes that gap.
    @Test func aFileDeletedOnDiskIsFoundByTheSweepAndNotBy56() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        let path = try seedOneFile(model, at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))

        let fresh = ArchiveModel(url: root)
        fresh.load()
        await fresh.fileSweepSettled()

        let summary = try #require(fresh.fileDamage)
        #expect(summary.headline == "1 file is missing from this archive")
        #expect(summary.pathSummary == (path as NSString).lastPathComponent)
        #expect(summary.pathTooltip == path)
        #expect(fresh.hasStandingDamage)
        // …and 56's half of the banner has nothing to say about it, which is the
        // whole reason this slice exists.
        #expect(fresh.standingFindings.isEmpty)
    }

    @Test func aTruncatedFileReachesTheBanner() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        let path = try seedOneFile(model, at: root)
        try Data("orig".utf8).write(to: root.appendingPathComponent(path))

        let fresh = ArchiveModel(url: root)
        fresh.load()
        await fresh.fileSweepSettled()

        #expect(fresh.fileDamage?.headline == "1 file is not the size the archive recorded")
    }

    /// A healthy archive publishes no summary — the banner has nothing to show,
    /// and that is the whole of what a clean sweep says.
    @Test func aHealthyArchiveShowsNoBanner() async throws {
        let (model, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }

        _ = try seedOneFile(model, at: root)

        let fresh = ArchiveModel(url: root)
        fresh.load()
        await fresh.fileSweepSettled()

        #expect(fresh.fileDamage == nil)
        #expect(!fresh.hasStandingDamage)
    }
}

/// Slice 60 hand-test — a size mismatch must never print the same number twice.
@Suite struct SizeDifferenceWordingTests {

    /// **The bug as seen:** `manifest.files` recorded 1,656 bytes and the disk held
    /// 1,652, and `.byteCount` rounded both to "2 kB" — so the Verify panel said
    /// *Expected 2 kB, found 2 kB*, which reads as the app being broken rather than
    /// the archive. Manifest mismatches are usually small, so this is the common
    /// case, not the corner.
    @Test func aSmallDifferenceIsShownInExactBytes() {
        let detail = IntegrityReport.Issue.sizeDifference(expected: 1656, actual: 1652)
        #expect(detail == "Expected 1,656 bytes, found 1,652 bytes.")
    }

    /// The friendly form survives where it is actually informative.
    @Test func aLargeDifferenceKeepsFriendlyUnits() {
        let detail = IntegrityReport.Issue.sizeDifference(expected: 4_200_000, actual: 1_100_000)
        #expect(detail.contains("MB"))
        #expect(!detail.contains("bytes"))
    }

    /// The property that matters, over the whole range: the two halves of the
    /// sentence are never the same string.
    @Test func theTwoNumbersAreNeverIdentical() {
        for (expected, actual) in [
            (Int64(1656), Int64(1652)), (954, 981), (0, 1), (1_048_576, 1_048_580),
            (999, 1000), (1_000_000, 1_000_004), (Int64.max, Int64.max - 1),
        ] {
            let detail = IntegrityReport.Issue.sizeDifference(expected: expected, actual: actual)
            let halves = detail.dropLast().components(separatedBy: ", found ")
            #expect(halves.count == 2)
            #expect(
                halves[0].replacingOccurrences(of: "Expected ", with: "") != halves[1],
                "identical halves for \(expected) vs \(actual): \(detail)")
        }
    }
}

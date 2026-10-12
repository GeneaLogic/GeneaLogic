import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 57b, the app half — **the one sentence in this app that claims
/// verification**.
///
/// The engine now skips files whose bytes are not on this machine rather than
/// downloading the archive to hash them, and says so in `notChecked`. That leaves
/// a report that is `isClean` (nothing was found) and not `isComplete` (because
/// most of it was never read), and the whole risk of the change is a panel that
/// renders *Archive Is Intact* from the first half of that. No engine test can
/// see a string in a view, which is why this suite exists.
@MainActor
@Suite struct PartialVerificationTests {

    private func report(
        skipping: [(String, Int64)],
        reason: IntegrityReport.NotCheckedFile.Reason = .notOnThisMachine
    ) -> IntegrityReport {
        IntegrityReport(
            issues: [], trackedFileCount: 3 + skipping.count,
            notChecked: skipping.map { .init(path: $0.0, byteLength: $0.1, reason: reason) })
    }

    @Test func aFullyCheckedCleanArchiveIsIntact() {
        #expect(
            IntegrityReportSheet.showsIntactHeadline(
                report: report(skipping: []), dangling: []))
    }

    /// **The trapdoor.** Clean, and not verified — the headline must not appear.
    @Test func aCleanButIncompleteReportIsNotIntact() {
        let partial = report(skipping: [("artifacts/x/master.tif", 3_221_225_472)])
        #expect(partial.isClean, "nothing was found, because most of it was not read")
        #expect(!IntegrityReportSheet.showsIntactHeadline(report: partial, dangling: []))
    }

    /// The pre-existing gates are untouched: a finding, or a dangling reference,
    /// still suppresses the headline on its own.
    @Test func findingsAndDanglingReferencesStillSuppressIt() {
        let damaged = IntegrityReport(
            issues: [.missingFile(path: "artifacts/x/scan.tif")], trackedFileCount: 3)
        #expect(!IntegrityReportSheet.showsIntactHeadline(report: damaged, dangling: []))
        #expect(
            !IntegrityReportSheet.showsIntactHeadline(
                report: report(skipping: []),
                dangling: [
                    .linkArtifact(
                        link: EvidenceLinkID("LNK-1"), missingArtifact: ArtifactID("ART-1"))
                ]))
    }

    /// **No blank sheet** (60's trapdoor, in this slice's shape). Suppressing the
    /// headline on an otherwise clean report sends it down the list branch, so
    /// the list had better have something in it — and the only thing that can
    /// suppress it there is the not-checked section, which is therefore never
    /// empty when it is needed.
    @Test func suppressingTheHeadlineAlwaysLeavesASectionToRender() {
        for skipping in [[("a.tif", Int64(8))], [("a.tif", 8), ("b.tif", 16)]] {
            let partial = report(skipping: skipping)
            guard !IntegrityReportSheet.showsIntactHeadline(report: partial, dangling: []) else {
                Issue.record("the headline was not suppressed")
                continue
            }
            #expect(!partial.notChecked.isEmpty, "the sheet would render nothing at all")
        }
    }

    /// The section header carries the bill, and the size is the half a person can
    /// decide from — both come free from the manifest.
    @Test func theHeadlineNamesTheCountAndTheSize() {
        let headline = IntegrityReportSheet.notCheckedHeadline(
            report(skipping: [("a.tif", 3_000_000_000), ("b.tif", 221_225_472)]))

        #expect(headline.contains("2 files"))
        #expect(headline.contains("GB"))
    }

    // MARK: - What a row is allowed to say about one file

    /// **The panel must not contradict itself about one file** (`/code-review`).
    /// A dataless file whose recorded size no longer matches appears in *both*
    /// lists — the engine's own `theCostComesFromTheManifestNotTheDisk` pins that
    /// shape — and the row here used to call it "present and the right size"
    /// directly under a Corruption row saying it is not.
    @Test func aRowDoesNotCallAFlaggedFileTheRightSize() {
        let file = IntegrityReport.NotCheckedFile(
            path: "a.tif", byteLength: 8, reason: .notOnThisMachine)

        let quiet = IntegrityReportSheet.notCheckedDetail(file, alsoReported: false)
        #expect(quiet.contains("the size the archive recorded"))

        let flagged = IntegrityReportSheet.notCheckedDetail(file, alsoReported: true)
        #expect(!flagged.contains("the size the archive recorded"))
        #expect(flagged.contains("also reported above"))
    }

    /// Each reason gets its own sentence: "isn't downloaded to this machine" is
    /// false of a file that could not be read, and of one a stopped pass never
    /// reached.
    @Test func everyReasonSaysWhatActuallyHappened() {
        func detail(_ reason: IntegrityReport.NotCheckedFile.Reason) -> String {
            IntegrityReportSheet.notCheckedDetail(
                .init(path: "a.tif", byteLength: 8, reason: reason), alsoReported: false)
        }

        #expect(detail(.notOnThisMachine).contains("isn't downloaded to this machine"))
        #expect(detail(.couldNotRead).contains("couldn't be read"))
        #expect(!detail(.couldNotRead).contains("downloaded to this machine"))
        #expect(detail(.checkWasStopped).contains("stopped"))
        #expect(!detail(.checkWasStopped).contains("downloaded to this machine"))
        // And every reason has its own row icon, so the three read apart at a
        // glance rather than only in prose.
        let symbols = IntegrityReport.NotCheckedFile.Reason.allCases.map(
            IntegrityReportSheet.notCheckedSymbol)
        #expect(Set(symbols).count == symbols.count)
    }

    /// **Priced from what the action would actually fetch.** Downloading does
    /// nothing for a file that failed to read or one a stopped pass never
    /// reached, so quoting their bytes on that button quotes for work it will not
    /// do — and with none of them downloadable, the button isn't offered at all.
    @Test func theDownloadIsPricedFromWhatItWouldFetch() {
        let mixed = IntegrityReport(
            trackedFileCount: 4,
            notChecked: [
                .init(path: "a.tif", byteLength: 1_000_000, reason: .couldNotRead),
                .init(path: "b.tif", byteLength: 8, reason: .notOnThisMachine),
            ])
        #expect(mixed.downloadableByteCount == 8)
        #expect(mixed.notCheckedByteCount == 1_000_008)

        let nothingToFetch = report(skipping: [("a.tif", 8)], reason: .couldNotRead)
        #expect(nothingToFetch.downloadableNotChecked.isEmpty)
        #expect(!nothingToFetch.isComplete, "still not a verification")
    }

    /// One file is one file, not "1 files" — the string is user-facing.
    @Test func oneSkippedFileReadsAsOne() {
        let headline = IntegrityReportSheet.notCheckedHeadline(skipping: [("a.tif", 8)])
        #expect(headline.contains("1 file,"))
    }
}

extension IntegrityReportSheet {
    fileprivate static func notCheckedHeadline(skipping: [(String, Int64)]) -> String {
        notCheckedHeadline(
            IntegrityReport(
                issues: [], trackedFileCount: skipping.count,
                notChecked: skipping.map {
                    .init(path: $0.0, byteLength: $0.1, reason: .notOnThisMachine)
                }))
    }
}

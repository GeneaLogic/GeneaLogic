import ArgumentParser
import Foundation
import GeneaLogicArchive
import Testing

@testable import GeneaLogicCLI

/// Slice 57b — what `genea verify` says about files it did not read.
///
/// **The report lines are tested against a constructed report, not a staged
/// archive**, and that is not a shortcut: no CI machine can make an
/// `SF_DATALESS` file (57 measured the flag by hand and recorded exactly that),
/// so an end-to-end test could only ever exercise the empty case. The engine's
/// skip is held through its own injected seam in `DatalessVerifyTests`; what is
/// left for here is the wording, which is the part a user reads.
@Suite struct VerifyCloudFilesTests {

    private func report(
        skipping: [(String, Int64)], tracked: Int,
        reason: IntegrityReport.NotCheckedFile.Reason = .notOnThisMachine
    ) -> IntegrityReport {
        IntegrityReport(
            issues: [], trackedFileCount: tracked,
            notChecked: skipping.map { .init(path: $0.0, byteLength: $0.1, reason: reason) })
    }

    /// A complete pass still says OK — the line every script and every previous
    /// slice's test reads.
    @Test func aCompletePassStillSaysOK() {
        let line = VerifyCommand.cleanLine(report(skipping: [], tracked: 3))
        #expect(line == "OK: no integrity issues found (3 files tracked).")
    }

    /// **The sentence this slice exists to stop.** No problems were found, so the
    /// report is clean — but a third of the archive was never read, and a line
    /// that said OK would be claiming an assurance nobody paid for.
    @Test func anIncompletePassDoesNotSayOK() {
        let line = VerifyCommand.cleanLine(
            report(skipping: [("artifacts/x/master.tif", 3_221_225_472)], tracked: 3))

        #expect(!line.hasPrefix("OK"))
        #expect(line.contains("PARTIAL"))
        #expect(line.contains("2 files checked"))
        #expect(line.contains("1 of 3"))
    }

    /// The note names each file, its cost, and the flag that pays it — a count on
    /// its own is not a decision.
    @Test func theNoteNamesTheFilesTheirCostAndTheFlag() {
        let lines = VerifyCommand.notCheckedLines(
            report(
                skipping: [("artifacts/x/master.tif", 3_221_225_472), ("artifacts/x/scan.tif", 8)],
                tracked: 4))

        #expect(lines.count == 4)
        #expect(lines[1].contains("artifacts/x/master.tif"))
        #expect(lines[1].contains("(3221225472 bytes)"))
        #expect(lines[1].contains("not downloaded to this machine"))
        #expect(lines[2].contains("artifacts/x/scan.tif"))
        // The total is the manifest's arithmetic, and the flag is named where the
        // user is looking at the bill.
        #expect(lines[3].contains("(3221225480 bytes)"))
        #expect(lines[3].contains("--download-cloud-files"))
    }

    /// **Each line says its own reason** (`/code-review`): "not downloaded" is
    /// true of a placeholder and false of a file that could not be read, and one
    /// blanket sentence over both is wrong about one of them.
    @Test func aFileThatCouldNotBeReadSaysSo() {
        let lines = VerifyCommand.notCheckedLines(
            report(skipping: [("artifacts/x/scan.tif", 8)], tracked: 2, reason: .couldNotRead))

        #expect(lines[1].contains("could not be read"))
        #expect(!lines[1].contains("not downloaded"))
    }

    /// And the flag is offered only when a download would resolve something —
    /// downloading does nothing for a read error or a stopped pass.
    @Test func theFlagIsNotOfferedWhereItWouldNotHelp() {
        let unreadable = VerifyCommand.notCheckedLines(
            report(skipping: [("a.tif", 8)], tracked: 2, reason: .couldNotRead))
        #expect(!unreadable.contains { $0.contains("--download-cloud-files") })

        let stopped = VerifyCommand.notCheckedLines(
            report(skipping: [("a.tif", 8)], tracked: 2, reason: .checkWasStopped))
        #expect(stopped[1].contains("stopped"))
        #expect(!stopped.contains { $0.contains("--download-cloud-files") })

        // Mixed: the offer stands, and says how much of the list it covers.
        let mixed = VerifyCommand.notCheckedLines(
            IntegrityReport(
                trackedFileCount: 3,
                notChecked: [
                    .init(path: "a.tif", byteLength: 8, reason: .couldNotRead),
                    .init(path: "b.tif", byteLength: 8, reason: .notOnThisMachine),
                ]))
        #expect(mixed.last?.contains("the 1 not on this machine") == true)
    }

    /// Nothing skipped, nothing said. The note must not appear on the ordinary
    /// local archive that is every other test in this suite.
    @Test func aCompletePassPrintsNoNote() {
        #expect(VerifyCommand.notCheckedLines(report(skipping: [], tracked: 3)).isEmpty)
    }

    /// The flag parses, and on an archive with no placeholders it changes
    /// nothing — which is the whole of its behaviour on Linux and on any machine
    /// whose archive is local.
    @Test func theFlagParsesAndChangesNothingLocally() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("CloudArchive").path
        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let addOut = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Photo"]).run(
            stdout: addOut, stderr: CollectingOutput())
        let uid = try #require(addOut.allLines.first)
        let source = try TestSupport.makeSourceFile(named: "photo.jpg", contents: "bytes")
        try AttachCommand.parse([archivePath, "--artifact", uid, "--file", source.path]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let plain = CollectingOutput()
        try VerifyCommand.parse([archivePath]).run(stdout: plain, stderr: CollectingOutput())
        let downloading = CollectingOutput()
        try VerifyCommand.parse([archivePath, "--download-cloud-files"]).run(
            stdout: downloading, stderr: CollectingOutput())

        #expect(plain.allLines == downloading.allLines)
        #expect(plain.allLines.contains { $0.hasPrefix("OK") })
        #expect(!plain.allLines.contains { $0.contains("Not checked") })
    }
}

import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Slice 50d — `genea abandon-delivery`, the way out of the one stuck state 50
/// and 50b deliberately left standing.
///
/// The staging is done through the engine (two archives and a hand-stepped
/// delivery, the shape `scripts/deliver.sh` automates); the assertions are on
/// what the CLI says and what it exits with, which is the part this suite owns.
@Suite struct AbandonDeliveryCommandTests {

    /// Other edits a record both machines hold, and only `manifest.json` makes
    /// the crossing — so mine expects a version nothing will ever bring.
    private func stageAStuckDelivery() throws -> (archivePath: String, awaited: String) {
        let other = TestSupport.makeTempDirectory().appendingPathComponent("other.genea")
        let otherArchive = try Archive.create(at: other)
        let ada = try otherArchive.addPerson(PersonDraft(given: "Ada", surname: "Baseline")).uid

        let mine = TestSupport.makeTempDirectory().appendingPathComponent("mine.genea")
        try FileManager.default.copyItem(at: other, to: mine)

        try otherArchive.updatePerson(ada) {
            $0.names.append(PersonName(type: .married, given: "Ada", surname: "OTHER-EDIT"))
        }

        let manifest = "manifest.json"
        try? FileManager.default.removeItem(at: mine.appendingPathComponent(manifest))
        try FileManager.default.copyItem(
            at: other.appendingPathComponent(manifest),
            to: mine.appendingPathComponent(manifest))

        return (mine.path, "conclusions/persons/\(ada.raw).json")
    }

    private func verify(_ path: String) throws -> (lines: [String], failed: Bool) {
        let out = CollectingOutput()
        var failed = false
        do {
            try VerifyCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())
        } catch is ExitCode {
            failed = true
        }
        return (out.allLines, failed)
    }

    /// The whole loop: `verify` names the path and tells the user to wait; when
    /// the waiting is plainly over, `abandon-delivery` clears it and `verify` is
    /// clean — with the decision reported as a note rather than swept away.
    @Test func abandonDeliveryClearsAStuckDeliveryAndSaysSo() throws {
        let staged = try stageAStuckDelivery()

        let stuck = try verify(staged.archivePath)
        #expect(stuck.failed)
        #expect(stuck.lines.contains { $0.contains("awaiting-delivery") })
        #expect(
            stuck.lines.contains { $0.contains("do NOT") && $0.contains("rebaseline") },
            "the advice that makes this verb necessary")

        let out = CollectingOutput()
        try AbandonDeliveryCommand.parse([staged.archivePath, staged.awaited]).run(
            stdout: out, stderr: CollectingOutput())
        #expect(out.allLines.contains { $0.contains("abandoned") && $0.contains(staged.awaited) })

        let clean = try verify(staged.archivePath)
        #expect(!clean.failed)
        #expect(clean.lines.contains { $0.contains("OK") })
        #expect(
            clean.lines.contains { $0.contains("Abandoned deliveries") },
            "the note must survive the archive being clean")
        #expect(clean.lines.contains { $0.contains(staged.awaited) })
    }

    /// A refusal names its reason on stderr and exits non-zero, so a script that
    /// abandons the wrong path is not told it worked.
    @Test func refusingAPathExitsNonZeroAndExplains() throws {
        let staged = try stageAStuckDelivery()
        let stderr = CollectingOutput()
        var failed = false
        do {
            try AbandonDeliveryCommand.parse([staged.archivePath, "conclusions/persons/PER-x.json"])
                .run(stdout: CollectingOutput(), stderr: stderr)
        } catch is ExitCode {
            failed = true
        }
        #expect(failed)
        #expect(stderr.allLines.contains { $0.contains("not tracked") })
        // And it changed nothing: the real stuck path is still stuck.
        #expect(try verify(staged.archivePath).failed)
    }

    /// **One refusal does not discard the decisions already made** (fork d): the
    /// paths are independent, so a bad one is reported while the good one is
    /// still done.
    @Test func oneRefusalDoesNotAbandonTheRestOfTheRequest() throws {
        let staged = try stageAStuckDelivery()
        let stdout = CollectingOutput()
        let stderr = CollectingOutput()
        var failed = false
        do {
            try AbandonDeliveryCommand.parse(
                [staged.archivePath, "conclusions/persons/PER-x.json", staged.awaited]
            ).run(stdout: stdout, stderr: stderr)
        } catch is ExitCode {
            failed = true
        }
        #expect(failed, "a refusal must still be visible in the exit code")
        #expect(stderr.allLines.contains { $0.contains("not tracked") })
        #expect(stdout.allLines.contains { $0.contains("abandoned") })
        #expect(!(try verify(staged.archivePath).failed), "the good path was still cleared")
    }
}

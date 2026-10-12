import ArgumentParser
import Foundation
import GeneaLogicArchive
import Testing

@testable import GeneaLogicCLI

/// Slice 59 (e) — `genea repair`, the verb that answers what `verify` and
/// `reindex` have been naming since 55.
@Suite struct RepairCommandTests {

    /// A CLI archive holding one person whose sidecar has been corrupted, with the
    /// index rebuilt so the copy is preserved — the state a repair starts from.
    private func archiveWithABrokenPerson() throws -> (
        path: String, url: URL, record: String, original: Data
    ) {
        let root = TestSupport.makeTempDirectory()
        let path = root.appendingPathComponent("RepairArchive").path
        let url = URL(fileURLWithPath: path, isDirectory: true)

        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        try PersonAddCommand.parse([path, "--given", "Ada", "--surname", "Lovelace"])
            .run(stdout: CollectingOutput(), stderr: CollectingOutput())

        let personsDirectory = url.appendingPathComponent("conclusions/persons")
        let file = try #require(
            try FileManager.default.contentsOfDirectory(
                at: personsDirectory, includingPropertiesForKeys: nil
            ).first)
        let original = try Data(contentsOf: file)
        try Data("{ not JSON".utf8).write(to: file)

        try ReindexCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        let record = "conclusions/persons/\(file.lastPathComponent)"
        return (path, url, record, original)
    }

    /// The loop the slice exists for: damage, repair, the record is back and the
    /// archive verifies — with the file that was there kept, not overwritten.
    @Test func repairRestoresARecordAndKeepsTheDamagedFile() throws {
        let (path, url, record, original) = try archiveWithABrokenPerson()

        let out = CollectingOutput()
        try RepairCommand.parse([path, "--record", record]).run(
            stdout: out, stderr: CollectingOutput())

        #expect(out.allLines.contains { $0.contains("byte-identical") })
        #expect(out.allLines.contains { $0.contains(".damaged/") })
        #expect(try Data(contentsOf: url.appendingPathComponent(record)) == original)

        let verifyOut = CollectingOutput()
        try VerifyCommand.parse([path]).run(stdout: verifyOut, stderr: CollectingOutput())
        #expect(verifyOut.allLines.contains { $0.contains("OK") })

        let listOut = CollectingOutput()
        try PersonListCommand.parse([path]).run(
            stdout: listOut, stderr: CollectingOutput())
        #expect(listOut.allLines.contains { $0.contains("Ada") })
    }

    /// `verify` says which damaged records can be restored and which cannot,
    /// rather than telling everyone to run a repair most of them have no copy for.
    @Test func verifyNamesTheRepairOnlyWhereThereIsACopy() throws {
        let (path, url, record, _) = try archiveWithABrokenPerson()

        // A second broken record that was never indexed, so nothing was kept.
        try Data("{ garbage".utf8).write(
            to: url.appendingPathComponent("conclusions/persons/PER-never-decoded.json"))
        try ReindexCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())

        let out = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try VerifyCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())
        }

        // A corrupted sidecar is also the wrong size, so it has a line of its own
        // for that — the remedy belongs to the `unreadable-record` line.
        let repairable = try #require(
            out.allLines.first { $0.contains("unreadable-record") && $0.contains(record) })
        #expect(repairable.contains("genea repair"))
        let hopeless = try #require(
            out.allLines.first {
                $0.contains("unreadable-record") && $0.contains("PER-never-decoded")
            })
        #expect(hopeless.contains("no copy"))
        #expect(!hopeless.contains("genea repair"))
    }

    /// **A command a user copies has to run as written** (review finding, 59):
    /// `reindex`'s pointer omitted the archive argument, so pasting it failed on a
    /// missing positional. Both suggested lines are parsed here rather than
    /// eyeballed.
    @Test func theSuggestedCommandsParseAsPrinted() throws {
        let (path, _, record, _) = try archiveWithABrokenPerson()

        let reindexErrors = CollectingOutput()
        try ReindexCommand.parse([path]).run(
            stdout: CollectingOutput(), stderr: reindexErrors)
        let verifyOut = CollectingOutput()
        #expect(throws: ExitCode.self) {
            try VerifyCommand.parse([path]).run(stdout: verifyOut, stderr: CollectingOutput())
        }

        let suggestions = (reindexErrors.allLines + verifyOut.allLines)
            .flatMap { $0.split(separator: "`") }
            .map(String.init)
            .filter { $0.hasPrefix("genea ") }
        #expect(suggestions.contains { $0.contains("repair") })

        for suggestion in suggestions {
            var arguments = suggestion.split(separator: " ").map(String.init)
            arguments.removeFirst()  // the `genea` binary name itself
            // The placeholder stands in for a path the caller substitutes.
            arguments = arguments.map { $0 == "<path>" ? record : $0 }
            #expect(throws: Never.self) { try GeneaLogicCLI.parseAsRoot(arguments) }
        }
    }

    /// Nothing kept means nothing to offer — and the file is left exactly as it is.
    @Test func repairingWithoutACopyFailsAndTouchesNothing() throws {
        let root = TestSupport.makeTempDirectory()
        let path = root.appendingPathComponent("NoCopyArchive").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())

        let record = "conclusions/persons/PER-never-decoded.json"
        try Data("{ garbage".utf8).write(to: url.appendingPathComponent(record))
        try ReindexCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())

        // `ArchiveSubcommand` renders an engine error to stderr and exits non-zero,
        // so the error itself is checked by its message rather than its case.
        let errors = CollectingOutput()
        #expect(throws: ExitCode.self) {
            try RepairCommand.parse([path, "--record", record]).run(
                stdout: CollectingOutput(), stderr: errors)
        }
        #expect(errors.allLines.contains { $0.contains("no saved copy") })
        #expect(
            try Data(contentsOf: url.appendingPathComponent(record)) == Data("{ garbage".utf8))
    }

    /// The skew case has to be asked for in as many words, and says so when it is
    /// used — an agent reading stdout is exactly who that warning is for.
    @Test func anInexactRestoreNeedsTheFlagAndWarnsWhenItRuns() throws {
        let (path, url, record, _) = try archiveWithABrokenPerson()
        let file = url.appendingPathComponent(record)

        // Drop the manifest entry, so there is nothing to prove the copy against —
        // the same "cannot tell" the version-skew case produces.
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: manifestURL))
            as! [String: Any]
        var files = manifest["files"] as! [[String: Any]]
        files.removeAll { ($0["path"] as? String) == record }
        manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: manifestURL)

        let refusal = CollectingOutput()
        #expect(throws: ExitCode.self) {
            try RepairCommand.parse([path, "--record", record]).run(
                stdout: CollectingOutput(), stderr: refusal)
        }
        #expect(refusal.allLines.contains { $0.contains("not byte-identical") })
        #expect(try Data(contentsOf: file) == Data("{ not JSON".utf8))

        let out = CollectingOutput()
        let errors = CollectingOutput()
        try RepairCommand.parse([path, "--record", record, "--accept-inexact"]).run(
            stdout: out, stderr: errors)

        #expect(out.allLines.contains { $0.contains("Restored") })
        #expect(!out.allLines.contains { $0.contains("byte-identical") })
        #expect(errors.allLines.contains { $0.contains("not byte-identical") })
    }

    // MARK: - A record whose file is gone (slice 58d)

    /// A CLI archive holding one person whose file has been deleted, with the
    /// index rebuilt so the copy is preserved.
    private func archiveWithAVanishedPerson() throws -> (path: String, url: URL, record: String) {
        let root = TestSupport.makeTempDirectory()
        let path = root.appendingPathComponent("VanishedArchive").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        try PersonAddCommand.parse([path, "--given", "Ada", "--surname", "Lovelace"])
            .run(stdout: CollectingOutput(), stderr: CollectingOutput())
        let file = try #require(
            try FileManager.default.contentsOfDirectory(
                at: url.appendingPathComponent("conclusions/persons"),
                includingPropertiesForKeys: nil
            ).first)
        try FileManager.default.removeItem(at: file)
        try ReindexCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        return (path, url, "conclusions/persons/\(file.lastPathComponent)")
    }

    private func verifyLines(_ path: String) -> [String] {
        let out = CollectingOutput()
        _ = try? VerifyCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())
        return out.allLines
    }

    /// `verify`'s `missing-file` line names the record and both ways out — and
    /// both commands run as printed.
    @Test func verifyOffersRestoreAndDeleteForAVanishedRecord() throws {
        let (path, _, record) = try archiveWithAVanishedPerson()

        let line = try #require(
            verifyLines(path).first { $0.hasPrefix("missing-file") && $0.contains(record) })
        #expect(line.contains("\"Ada Lovelace\""))
        let suggestions = line.split(separator: "`").map(String.init)
            .filter { $0.hasPrefix("genea ") }
        #expect(suggestions.count == 2)
        #expect(suggestions.contains { $0.hasSuffix("--delete") })
        for suggestion in suggestions {
            let arguments = Array(suggestion.split(separator: " ").map(String.init).dropFirst())
            #expect(throws: Never.self) { try GeneaLogicCLI.parseAsRoot(arguments) }
        }
    }

    @Test func deleteRemovesAMissingPerson() throws {
        let (path, url, record) = try archiveWithAVanishedPerson()

        let out = CollectingOutput()
        try RepairCommand.parse([path, "--record", record, "--delete"]).run(
            stdout: out, stderr: CollectingOutput())

        #expect(out.allLines.contains { $0.hasPrefix("Deleted") })
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent(record).path))
        #expect(verifyLines(path).contains { $0.hasPrefix("OK") })
    }

    /// An unreadable record's file is still there, so it is refused and the copy
    /// stays for the restore.
    @Test func deleteIsRefusedForAnUnreadableRecord() throws {
        let (path, url, record, original) = try archiveWithABrokenPerson()

        let errors = CollectingOutput()
        #expect(throws: ExitCode.self) {
            try RepairCommand.parse([path, "--record", record, "--delete"]).run(
                stdout: CollectingOutput(), stderr: errors)
        }
        #expect(errors.allLines.contains { $0.contains("isn't missing") })

        try RepairCommand.parse([path, "--record", record]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        #expect(try Data(contentsOf: url.appendingPathComponent(record)) == original)
    }

    /// An artifact whose master is still in its folder is deleted with it, into
    /// the trash, and the printed `trash restore` brings both back.
    @Test func deletingAMissingArtifactTrashesItAndTheTrashBringsItBack() throws {
        let root = TestSupport.makeTempDirectory()
        let path = root.appendingPathComponent("ArtifactArchive").path
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        let addOut = CollectingOutput()
        try AddCommand.parse([path, "--title", "Census"]).run(
            stdout: addOut, stderr: CollectingOutput())
        let uid = try #require(addOut.allLines.first)
        let source = try TestSupport.makeSourceFile(named: "scan.jpg", contents: "recto")
        try AttachCommand.parse([path, "--artifact", uid, "--file", source.path]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        let folder = try #require(
            try FileManager.default.contentsOfDirectory(
                at: url.appendingPathComponent("artifacts"), includingPropertiesForKeys: nil
            ).first)
        let record = "artifacts/\(folder.lastPathComponent)/record.json"
        try FileManager.default.removeItem(at: url.appendingPathComponent(record))
        try ReindexCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())

        let out = CollectingOutput()
        try RepairCommand.parse([path, "--record", record, "--delete"]).run(
            stdout: out, stderr: CollectingOutput())
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(verifyLines(path).contains { $0.hasPrefix("OK") })

        let restore = try #require(
            out.allLines.first?.split(separator: "`").map(String.init)
                .first { $0.hasPrefix("genea trash restore") })
        let arguments = Array(restore.split(separator: " ").map(String.init).dropFirst())
        #expect(throws: Never.self) { try GeneaLogicCLI.parseAsRoot(arguments) }
        try TrashRestoreCommand.parse(Array(arguments.dropFirst(2))).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("scan.jpg").path))
    }
}

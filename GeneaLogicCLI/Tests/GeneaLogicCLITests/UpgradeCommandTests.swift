import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// Slice 64 — `genea upgrade`, and what every other verb says at the door.
@Suite struct UpgradeCommandTests {

    private func createArchive() throws -> (path: String, url: URL) {
        let root = TestSupport.makeTempDirectory()
        let path = root.appendingPathComponent("VersionArchive").path
        try CreateCommand.parse([path]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        try PersonAddCommand.parse([path, "--given", "Ada", "--surname", "Lovelace"])
            .run(stdout: CollectingOutput(), stderr: CollectingOutput())
        return (path, URL(fileURLWithPath: path, isDirectory: true))
    }

    /// The first line that is the verb's own answer. On a machine with no stable
    /// identifier — CI's Linux container has no `/etc/machine-id` — every archive
    /// verb first says on stderr which `.index/` key it fell back to (slice 48),
    /// and that note is not the error under test.
    private func firstReply(in output: CollectingOutput) -> String? {
        output.allLines.first { !$0.hasPrefix("note:") }
    }

    private func setManifestVersion(_ version: String, in url: URL) throws {
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        manifest.schemaVersion = version
        try GeneaLogicJSON.encoder.encode(manifest).write(to: manifestURL)
    }

    /// Stamps every person record too — a manifest alone behind the records is a
    /// straggler manifest, not an old archive, and opens.
    private func setArchiveVersion(_ version: String, in url: URL) throws {
        try setManifestVersion(version, in: url)
        let personsDirectory = url.appendingPathComponent("conclusions/persons")
        for file in try FileManager.default.contentsOfDirectory(
            at: personsDirectory, includingPropertiesForKeys: nil)
        {
            var object =
                try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            object["schemaVersion"] = version
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(
                to: file)
        }
    }

    @Test func upgradeOnACurrentArchiveSaysSoAndChangesNothing() throws {
        let (path, url) = try createArchive()
        let manifestURL = url.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifestURL)

        let out = CollectingOutput()
        try UpgradeCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())

        #expect(
            out.allLines == [
                "Archive is already in format \(SchemaVersion.current)."
            ])
        #expect(try Data(contentsOf: manifestURL) == before)
    }

    @Test func aNewerManifestIsRefusedByEveryVerbWithTheFixInTheMessage() throws {
        let (path, url) = try createArchive()
        try setManifestVersion("1.1", in: url)

        let err = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try PersonListCommand.parse([path]).run(stdout: CollectingOutput(), stderr: err)
        }
        let line = try #require(firstReply(in: err))
        #expect(line.hasPrefix("Error: manifest.json was written in archive format 1.1"))
        #expect(line.contains("this GeneaLogic writes \(SchemaVersion.current)"))
        #expect(line.contains("Update GeneaLogic"))

        // `upgrade` has nothing to bring it forward *to*, and says the same thing.
        let upgradeErr = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try UpgradeCommand.parse([path]).run(stdout: CollectingOutput(), stderr: upgradeErr)
        }
        #expect(firstReply(in: upgradeErr)?.contains("Update GeneaLogic") == true)
    }

    @Test func anOlderArchivePointsAtUpgradeWhichNamesTheGap() throws {
        let (path, url) = try createArchive()
        try setArchiveVersion("0.9", in: url)

        let err = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try PersonListCommand.parse([path]).run(stdout: CollectingOutput(), stderr: err)
        }
        let line = try #require(firstReply(in: err))
        #expect(line.hasPrefix("Error: This archive is in format 0.9"))
        #expect(line.contains("Run `genea upgrade`"))

        let upgradeErr = CollectingOutput()
        #expect(throws: ExitCode.failure) {
            try UpgradeCommand.parse([path]).run(stdout: CollectingOutput(), stderr: upgradeErr)
        }
        #expect(
            firstReply(in: upgradeErr)?.contains("format 0.9, which no GeneaLogic has written")
                == true)
    }

    /// A straggler on `verify`: its own line, and no pointer at `genea repair`.
    @Test func verifyNamesAnOlderFormatRecordWithoutOfferingARepair() throws {
        let (path, url) = try createArchive()
        let personsDirectory = url.appendingPathComponent("conclusions/persons")
        let file = try #require(
            try FileManager.default.contentsOfDirectory(
                at: personsDirectory, includingPropertiesForKeys: nil
            ).first)
        var object =
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        object["schemaVersion"] = "0.9"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file)
        try FileManager.default.removeItem(at: url.appendingPathComponent(".index"))

        let out = CollectingOutput()
        #expect(throws: ExitCode.self) {
            try VerifyCommand.parse([path]).run(stdout: out, stderr: CollectingOutput())
        }
        let line = try #require(out.allLines.first { $0.hasPrefix("older-format-record\t") })
        #expect(line.contains("conclusions/persons/\(file.lastPathComponent)"))
        #expect(line.contains("do not repair or replace it"))
        #expect(!line.contains("genea repair"))
        #expect(!out.allLines.contains { $0.hasPrefix("unreadable-record\t") })

        let listOut = CollectingOutput()
        try PersonListCommand.parse([path]).run(stdout: listOut, stderr: CollectingOutput())
        #expect(!listOut.allLines.contains { $0.contains("Ada") })
    }
}

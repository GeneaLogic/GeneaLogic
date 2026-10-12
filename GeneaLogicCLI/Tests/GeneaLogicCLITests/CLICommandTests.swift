import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicCLI

/// End-to-end coverage of the Phase 1b exit criteria, driven through
/// the command types directly (parse argv → run against a temp-directory
/// archive → assert on captured output / exit codes / on-disk engine state).
///
/// Each command's `run(stdout:stderr:)` is the testable entry point (see
/// `CreateCommand` etc.) — `run()` (ArgumentParser's contract) just forwards to
/// it with the real stdout/stderr.
@Suite struct CLICommandTests {

    // MARK: - create / add / attach, verified against the engine

    /// 1. `create` an archive, `add` an artifact (capturing its uid from
    /// stdout), `attach` a file to it — then assert on-disk archive state via
    /// the engine itself (re-opening the archive directly).
    @Test func createAddAttachRoundTrip() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("MyArchive").path

        let create = try CreateCommand.parse([archivePath, "--name", "My Archive"])
        let createOut = CollectingOutput()
        try create.run(stdout: createOut, stderr: CollectingOutput())
        #expect(createOut.text.contains(archivePath))

        let add = try AddCommand.parse([
            archivePath, "--title", "1920 Census", "--media-type", "image",
            "--source-tier", "census", "--tag", "genealogy", "--tag", "illinois",
            "--notes", "Smith family household",
        ])
        let addOut = CollectingOutput()
        try add.run(stdout: addOut, stderr: CollectingOutput())
        let artifactUID = addOut.allLines.first ?? ""
        #expect(artifactUID.hasPrefix("ART-"))

        let sourceFile = try TestSupport.makeSourceFile(named: "census.tif", contents: "scan-bytes")
        let attach = try AttachCommand.parse([
            archivePath, "--artifact", artifactUID, "--file", sourceFile.path,
            "--role", "preservation-master",
        ])
        let attachOut = CollectingOutput()
        try attach.run(stdout: attachOut, stderr: CollectingOutput())
        let attachLine = attachOut.allLines.first ?? ""
        let parts = attachLine.split(separator: "\t", maxSplits: 1).map(String.init)
        #expect(parts.count == 2)
        let fileUID = parts[0]
        let assignedPath = parts[1]
        #expect(fileUID.hasPrefix("FIL-"))
        #expect(assignedPath == "census.tif")

        // Assert on-disk state via the engine directly.
        let engineArchive = try Archive.open(
            at: URL(fileURLWithPath: archivePath, isDirectory: true))
        let artifact = engineArchive.artifact(withID: ArtifactID(artifactUID))
        #expect(artifact?.title == "1920 Census")
        #expect(artifact?.tags == ["genealogy", "illinois"])
        #expect(artifact?.notes == "Smith family household")
        #expect(artifact?.files.count == 1)
        #expect(artifact?.files.first?.uid.raw == fileUID)
        #expect(artifact?.files.first?.path == assignedPath)
    }

    // MARK: - find / ls + the pipe-the-uid workflow

    /// 2. `find`/`list` the artifact and confirm its uid+title appear in the
    /// `<uid>\t<title>` output; use the found uid to `set-meta` and `attach`
    /// (proving the pipe-the-uid workflow).
    @Test func findAndLsOutputFeedSetMetaAndAttach() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("PipeArchive").path

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let addOut = CollectingOutput()
        try AddCommand.parse([
            archivePath, "--title", "Marriage Record 1899",
        ]).run(stdout: addOut, stderr: CollectingOutput())
        let artifactUID = addOut.allLines.first ?? ""

        // `list` prints exactly one tab-separated line for this artifact.
        let lsOut = CollectingOutput()
        try ListCommand.parse([archivePath]).run(stdout: lsOut, stderr: CollectingOutput())
        #expect(lsOut.allLines == ["\(artifactUID)\tMarriage Record 1899"])

        // `find` matches on title text and returns the same line.
        let findOut = CollectingOutput()
        try FindCommand.parse([archivePath, "Marriage"]).run(
            stdout: findOut, stderr: CollectingOutput())
        #expect(findOut.allLines == ["\(artifactUID)\tMarriage Record 1899"])

        // A query that doesn't match returns nothing.
        let emptyFindOut = CollectingOutput()
        try FindCommand.parse([archivePath, "Nonexistent"]).run(
            stdout: emptyFindOut, stderr: CollectingOutput())
        #expect(emptyFindOut.allLines.isEmpty)

        // Pipe the found uid into set-meta.
        let setMetaOut = CollectingOutput()
        try SetMetaCommand.parse([
            archivePath, "--artifact", artifactUID, "--title", "Marriage Record (revised)",
            "--tag", "vital-records",
        ]).run(stdout: setMetaOut, stderr: CollectingOutput())
        #expect(setMetaOut.allLines == ["Updated \(artifactUID)"])

        // Pipe the found uid into attach.
        let sourceFile = try TestSupport.makeSourceFile(named: "marriage.pdf")
        let attachOut = CollectingOutput()
        try AttachCommand.parse([
            archivePath, "--artifact", artifactUID, "--file", sourceFile.path,
        ]).run(stdout: attachOut, stderr: CollectingOutput())
        #expect(attachOut.allLines.first?.contains("marriage.pdf") == true)

        // Verify both edits landed via the engine.
        let engineArchive = try Archive.open(
            at: URL(fileURLWithPath: archivePath, isDirectory: true))
        let artifact = engineArchive.artifact(withID: ArtifactID(artifactUID))
        #expect(artifact?.title == "Marriage Record (revised)")
        #expect(artifact?.tags == ["vital-records"])
        #expect(artifact?.files.count == 1)
    }

    // MARK: - verify: corruption detection + non-zero exit

    /// 3. Corrupt a file in the archive on disk, run `verify`, assert it
    /// reports the mismatch and exits non-zero.
    @Test func verifyDetectsCorruptionAndExitsNonZero() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("VerifyArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let addOut = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Photo"]).run(
            stdout: addOut, stderr: CollectingOutput())
        let artifactUID = addOut.allLines.first ?? ""

        let sourceFile = try TestSupport.makeSourceFile(
            named: "photo.jpg", contents: "original-bytes")
        let attachOut = CollectingOutput()
        try AttachCommand.parse([
            archivePath, "--artifact", artifactUID, "--file", sourceFile.path,
        ]).run(stdout: attachOut, stderr: CollectingOutput())
        let assignedPath =
            attachOut.allLines.first?.split(separator: "\t").last.map(String.init) ?? ""

        // A clean archive verifies OK with exit code 0 (no throw), and says how
        // much it checked — "OK" alone can't distinguish a covered archive from
        // one with nothing tracked (a pre-49 archive, which reports clean by
        // design). Here: the schema spec, the record, and the attached file.
        let cleanOut = CollectingOutput()
        try VerifyCommand.parse([archivePath]).run(stdout: cleanOut, stderr: CollectingOutput())
        #expect(cleanOut.allLines.contains { $0.contains("OK") && $0.contains("3 files tracked") })

        // Corrupt the attached file's bytes on disk.
        let engineArchive = try Archive.open(at: archiveURL)
        let artifact = engineArchive.artifact(withID: ArtifactID(artifactUID))
        let slugPrefix = "artifacts/"
        // Find the artifact's folder by locating the file with `assignedPath`.
        let fm = FileManager.default
        var corruptedFileURL: URL?
        if let artifactsEnumerator = fm.enumerator(
            at: archiveURL.appendingPathComponent("artifacts"), includingPropertiesForKeys: nil)
        {
            for case let fileURL as URL in artifactsEnumerator
            where fileURL.lastPathComponent == assignedPath {
                corruptedFileURL = fileURL
            }
        }
        let target = try #require(corruptedFileURL)
        try "corrupted-bytes!!".write(to: target, atomically: true, encoding: .utf8)
        #expect(artifact?.files.first?.path == assignedPath)
        _ = slugPrefix  // documents the expected layout; not otherwise used

        // verify must report the mismatch and throw a non-zero ExitCode.
        let verifyOut = CollectingOutput()
        let verifyErr = CollectingOutput()
        var thrown: ExitCode?
        do {
            try VerifyCommand.parse([archivePath]).run(stdout: verifyOut, stderr: verifyErr)
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }
        #expect(thrown == .failure)
        #expect(verifyOut.allLines.contains { $0.contains(assignedPath) })
        #expect(
            verifyOut.allLines.contains {
                $0.contains("checksum-mismatch") || $0.contains("size-mismatch")
            })
    }

    // MARK: - reindex: lossless after deleting .index/

    /// 4. Delete `.index/`, run `reindex`, assert lookups still return the same
    /// results — losslessly, with the SQLite-backed index.
    @Test func reindexAfterDeletingIndexDirectoryIsLossless() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("ReindexArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let addOut1 = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Birth Certificate"]).run(
            stdout: addOut1, stderr: CollectingOutput())
        let uid1 = addOut1.allLines.first ?? ""

        let addOut2 = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Death Certificate"]).run(
            stdout: addOut2, stderr: CollectingOutput())
        let uid2 = addOut2.allLines.first ?? ""

        let beforeOut = CollectingOutput()
        try ListCommand.parse([archivePath]).run(stdout: beforeOut, stderr: CollectingOutput())
        let beforeLines = Set(beforeOut.allLines)
        #expect(beforeLines == ["\(uid1)\tBirth Certificate", "\(uid2)\tDeath Certificate"])

        // Delete `.index/` entirely.
        let indexDirectory = archiveURL.appendingPathComponent(".index", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: indexDirectory.path))
        try FileManager.default.removeItem(at: indexDirectory)
        #expect(!FileManager.default.fileExists(atPath: indexDirectory.path))

        // `reindex` must succeed and recreate `.index/` from the sidecars.
        let reindexOut = CollectingOutput()
        try ReindexCommand.parse([archivePath]).run(stdout: reindexOut, stderr: CollectingOutput())
        #expect(reindexOut.allLines.contains { $0.lowercased().contains("rebuilt") })
        #expect(FileManager.default.fileExists(atPath: indexDirectory.path))

        // Lookups are unchanged — losslessly reproduced.
        let afterOut = CollectingOutput()
        try ListCommand.parse([archivePath]).run(stdout: afterOut, stderr: CollectingOutput())
        #expect(Set(afterOut.allLines) == beforeLines)

        let afterFindOut = CollectingOutput()
        try FindCommand.parse([archivePath, "Birth"]).run(
            stdout: afterFindOut, stderr: CollectingOutput())
        #expect(afterFindOut.allLines == ["\(uid1)\tBirth Certificate"])
    }

    // MARK: - rebaseline: the blessed out-of-band edit

    /// Slice 49's user-facing loop: hand-edit a sidecar, `verify` names it as a
    /// checksum mismatch (it cannot tell an edit from rot, and must not guess),
    /// `rebaseline` accepts the file, `verify` is clean again.
    @Test func rebaselineAcceptsAHandEditedSidecar() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("RebaselineArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        try AddCommand.parse([archivePath, "--title", "Marriage Record"]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let recordURL = try #require(
            FileManager.default.enumerator(
                at: archiveURL.appendingPathComponent("artifacts"),
                includingPropertiesForKeys: nil
            )?
            .compactMap { $0 as? URL }
            .first { $0.lastPathComponent == "record.json" })

        var record =
            try JSONSerialization.jsonObject(with: try Data(contentsOf: recordURL))
            as! [String: Any]
        record["notes"] = "edited by hand in a text editor"
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            .write(to: recordURL)

        let dirtyOut = CollectingOutput()
        var thrown: ExitCode?
        do {
            try VerifyCommand.parse([archivePath]).run(
                stdout: dirtyOut, stderr: CollectingOutput())
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }
        #expect(thrown == .failure)
        #expect(dirtyOut.allLines.contains { $0.contains("checksum-mismatch") })

        let rebaselineOut = CollectingOutput()
        try RebaselineCommand.parse([archivePath]).run(
            stdout: rebaselineOut, stderr: CollectingOutput())
        #expect(rebaselineOut.allLines.contains { $0.lowercased().contains("rebaselined") })

        let cleanOut = CollectingOutput()
        try VerifyCommand.parse([archivePath]).run(stdout: cleanOut, stderr: CollectingOutput())
        #expect(cleanOut.allLines.contains { $0.contains("OK") })

        // The edit is also visible to queries — `rebaseline` rebuilds the index
        // onto the disk it just blessed, so the archive agrees with itself.
        let showOut = CollectingOutput()
        try ShowCommand.parse([archivePath, record["uid"] as! String]).run(
            stdout: showOut, stderr: CollectingOutput())
        #expect(showOut.allLines.contains { $0.contains("edited by hand") })
    }

    // MARK: - reindex / verify: the record that could not be read

    /// Slice 55's user-facing loop: a corrupt sidecar no longer costs access to
    /// the archive. Every command still runs, `reindex` warns on stderr about
    /// what it had to skip, and `verify` names the file.
    @Test func aCorruptSidecarIsNamedRatherThanClosingTheArchive() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("UnreadableArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        try AddCommand.parse([archivePath, "--title", "Corrupt Record"]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        let survivorOut = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Intact Record"]).run(
            stdout: survivorOut, stderr: CollectingOutput())
        let survivorUID = survivorOut.allLines.first ?? ""

        let records =
            FileManager.default.enumerator(
                at: archiveURL.appendingPathComponent("artifacts"),
                includingPropertiesForKeys: nil
            )?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "record.json" } ?? []
        let corrupted = try #require(
            records.first {
                let json = try? Data(contentsOf: $0)
                return json.map { String(decoding: $0, as: UTF8.self).contains("Corrupt Record") }
                    ?? false
            })
        try Data("not JSON at all".utf8).write(to: corrupted)

        // `reindex` succeeds — the archive is usable — and says what it skipped.
        let reindexOut = CollectingOutput()
        let reindexErr = CollectingOutput()
        try ReindexCommand.parse([archivePath]).run(stdout: reindexOut, stderr: reindexErr)
        #expect(reindexOut.allLines.contains { $0.lowercased().contains("rebuilt") })
        #expect(reindexErr.allLines.contains { $0.contains("record.json") })

        // The rest of the archive is still there and still queryable.
        let listOut = CollectingOutput()
        try ListCommand.parse([archivePath]).run(stdout: listOut, stderr: CollectingOutput())
        #expect(listOut.allLines == ["\(survivorUID)\tIntact Record"])

        // `verify` names it, and the exit-code contract holds: this is a
        // file-integrity problem, so it is a non-zero exit.
        let verifyOut = CollectingOutput()
        var thrown: ExitCode?
        do {
            try VerifyCommand.parse([archivePath]).run(
                stdout: verifyOut, stderr: CollectingOutput())
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }
        #expect(thrown == .failure)
        #expect(verifyOut.allLines.contains { $0.contains("unreadable-record") })
    }

    // MARK: - verify: a second copy of a record

    /// Slice 50c: a sync provider's conflicted copy is named, with advice that
    /// says the archive is *not* using it — and it is not moved or deleted, so
    /// the user can read what the other machine had before they resolve it.
    @Test func aConflictedCopyIsNamedAndLeftWhereItIs() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("ConflictArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        let personOut = CollectingOutput()
        try PersonAddCommand.parse([archivePath, "--given", "John", "--surname", "Smith"]).run(
            stdout: personOut, stderr: CollectingOutput())
        let uid = try #require(personOut.allLines.last)

        let sidecar = archiveURL.appendingPathComponent("conclusions/persons/\(uid).json")
        let copyName = "\(uid) (Ada's conflicted copy 2026-08-29).json"
        let copy = sidecar.deletingLastPathComponent().appendingPathComponent(copyName)
        try String(contentsOf: sidecar, encoding: .utf8)
            .replacingOccurrences(of: "Smith", with: "Smyth")
            .write(to: copy, atomically: true, encoding: .utf8)

        let verifyOut = CollectingOutput()
        var thrown: ExitCode?
        do {
            try VerifyCommand.parse([archivePath]).run(
                stdout: verifyOut, stderr: CollectingOutput())
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }
        #expect(thrown == .failure)
        let line = try #require(verifyOut.allLines.first { $0.contains("conflicting-copy") })
        #expect(line.contains(copyName))
        #expect(line.contains("using the original"))

        // Reported, never moved (fork b) — and the record itself is untouched.
        #expect(FileManager.default.fileExists(atPath: copy.path))
        #expect(try String(contentsOf: sidecar, encoding: .utf8).contains("Smith"))

        let listOut = CollectingOutput()
        try PersonListCommand.parse([archivePath]).run(
            stdout: listOut, stderr: CollectingOutput())
        #expect(listOut.allLines == ["\(uid)\tJohn Smith"])
    }

    /// The sibling finding, and the one whose wording carries the whole remedy: a
    /// provider that renamed the *original* leaves the only copy of a record
    /// under a name nothing looks for (`/code-review`, 50c).
    @Test func aMisnamedRecordIsNamedWithTheRenameThatRestoresIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("MisnamedArchive").path
        let archiveURL = URL(fileURLWithPath: archivePath, isDirectory: true)

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        let personOut = CollectingOutput()
        try PersonAddCommand.parse([archivePath, "--given", "John", "--surname", "Smith"]).run(
            stdout: personOut, stderr: CollectingOutput())
        let uid = try #require(personOut.allLines.last)

        let sidecar = archiveURL.appendingPathComponent("conclusions/persons/\(uid).json")
        let renamed = "\(uid) (Ada's conflicted copy 2026-08-29).json"
        try FileManager.default.moveItem(
            at: sidecar, to: sidecar.deletingLastPathComponent().appendingPathComponent(renamed))

        let verifyOut = CollectingOutput()
        try? VerifyCommand.parse([archivePath]).run(
            stdout: verifyOut, stderr: CollectingOutput())
        let line = try #require(verifyOut.allLines.first { $0.contains("misnamed-record") })
        #expect(line.contains(renamed))
        #expect(line.contains("may be the only copy"))
        #expect(line.contains("rename it to \(uid).json"))
        // Never the deletion advice, which here would destroy the record.
        #expect(!verifyOut.allLines.contains { $0.contains("conflicting-copy") })
    }

    // MARK: - Error rendering

    /// `ArchiveError` cases render via their `description`, not a raw Swift
    /// dump, and exit non-zero.
    @Test func unknownArtifactProducesReadableErrorAndNonZeroExit() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("ErrArchive").path

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let stderrOut = CollectingOutput()
        var thrown: ExitCode?
        do {
            try SetMetaCommand.parse([
                archivePath, "--artifact", "ART-does-not-exist", "--title", "x",
            ]).run(stdout: CollectingOutput(), stderr: stderrOut)
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }

        #expect(thrown == .failure)
        // **The error line, not the first line.** Since slice 48 `genea` may
        // print a machine-key notice to stderr ahead of anything else — it does
        // on any host where the key falls back to the hostname, which in the
        // Linux container is every run — so asserting positionally made this
        // fail there for a reason that has nothing to do with the error. Found
        // in slice 50, after a stale `.build-linux-GeneaLogicCLI` scratch
        // directory had been hiding the CLI's Linux run since 48 landed.
        let failure = stderrOut.allLines.first { $0.contains("ART-does-not-exist") }
        #expect(failure != nil)
        #expect(failure?.contains("ArchiveError") == false)
    }

    /// `genea create` at a path that's already an archive is `.alreadyExists`.
    /// **`add` no longer characterises a document nobody characterised (46b).** It
    /// defaulted to `compiled`, so an artifact added without the flag asserted
    /// *"somebody's conclusion, not evidence"* about itself and scored 25 — below the 40
    /// an uncatalogued record earns. Absent now means unstated, and `set-meta` can put a
    /// tier on later and take it back off, or "unstated" becomes a one-way door.
    @Test func addLeavesTheSourceTierUnstatedAndSetMetaRoundTripsIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("Untagged").path
        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let addOut = CollectingOutput()
        try AddCommand.parse([archivePath, "--title", "Dragged-in scan"]).run(
            stdout: addOut, stderr: CollectingOutput())
        let uid = addOut.allLines.first ?? ""

        func tier() throws -> SourceAuthorityTier? {
            let archive = try Archive.open(at: URL(fileURLWithPath: archivePath))
            return archive.artifact(withID: ArtifactID(uid))?.sourceAuthorityTier
        }
        #expect(try tier() == nil)

        try SetMetaCommand.parse([
            archivePath, "--artifact", uid, "--source-tier", "government",
        ]).run(stdout: CollectingOutput(), stderr: CollectingOutput())
        #expect(try tier() == .government)

        try SetMetaCommand.parse([archivePath, "--artifact", uid, "--clear-source-tier"]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())
        #expect(try tier() == nil)
    }

    @Test func createTwiceFailsWithReadableError() throws {
        let root = TestSupport.makeTempDirectory()
        let archivePath = root.appendingPathComponent("DupArchive").path

        try CreateCommand.parse([archivePath]).run(
            stdout: CollectingOutput(), stderr: CollectingOutput())

        let stderrOut = CollectingOutput()
        var thrown: ExitCode?
        do {
            try CreateCommand.parse([archivePath]).run(
                stdout: CollectingOutput(), stderr: stderrOut)
        } catch let exitCode as ExitCode {
            thrown = exitCode
        }

        #expect(thrown == .failure)
        #expect(stderrOut.allLines.first?.contains("already exists") == true)
    }
}

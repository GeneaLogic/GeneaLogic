import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea set-role <archive> --artifact <uid> --file <FIL-uid> --role <role>` →
/// `setFileRole`.
///
/// A **flat** verb like its file/artifact siblings (`attach`/`detach`/`set-meta`).
/// This is the headless half of slice 32 — a metadata-only edit of a file's
/// archival intent, the sanctioned way to correct a role after the fact (attach
/// assigns `preservation-master` by default). `setFileRole` returns the *prior*
/// role, which is echoed so the change is visible; a no-op change (role already
/// `role`) reports the unchanged role and skips the write.
struct SetRoleCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set-role",
        abstract: "Change one of an artifact's files' role."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact the file belongs to (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The file's uid (FIL-…).")
    var file: String

    /// Closed vocabulary (`FileRole`) — one of `preservation-master`,
    /// `access-copy`, `derivative`, `transcript`; rejected by ArgumentParser via
    /// the `ExpressibleByArgument` conformance in `AttachCommand`.
    @Option(name: .long, help: "New file role.")
    var role: FileRole

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let priorRole = try opened.setFileRole(
            FileID(file), in: ArtifactID(artifact), to: role)
        if priorRole == role {
            stdout.writeLine("\(file) already has role \(role.rawValue); unchanged.")
        } else {
            stdout.writeLine("Set role of \(file) to \(role.rawValue) (was \(priorRole.rawValue)).")
        }
    }
}

/// `genea replace-file <archive> --artifact <uid> --file <FIL-uid> --with <path>`
/// → `replaceFile(copyingFrom:)`.
///
/// The **only** sanctioned way to overwrite an existing file's content
/// (ARCHITECTURE.md §4.2.1) — `attach` always creates a new entry and never
/// overwrites. The file keeps its uid and role (replacing content doesn't change
/// intent); the bytes, size and checksum change, and so does its package path —
/// the new bytes land at a fresh name derived from the replacement's, and the old
/// path is removed (slice 65: never overwritten in place, so a crash cannot leave
/// new bytes under the old checksum).
struct ReplaceFileCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "replace-file",
        abstract: "Overwrite an existing file's content from a local file."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact the file belongs to (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The file's uid to overwrite (FIL-…).")
    var file: String

    @Option(name: .long, help: "Path to the local file whose bytes replace the current content.")
    var with: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let sourceURL = URL(fileURLWithPath: with)
        _ = try opened.replaceFile(
            FileID(file), in: ArtifactID(artifact), copyingFrom: sourceURL)
        stdout.writeLine("Replaced \(file)")
    }
}

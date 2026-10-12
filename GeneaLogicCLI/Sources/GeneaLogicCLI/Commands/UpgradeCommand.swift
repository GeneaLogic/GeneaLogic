import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea upgrade <archive>` → `Archive.upgrade(at:)` (slice 64, fork a).
///
/// **Deliberately not an `ArchiveSubcommand`**: that protocol opens the archive
/// first, and an archive that needs upgrading is exactly the one `open` refuses.
/// This is the one verb that runs *before* the door.
struct UpgradeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upgrade",
        abstract: "Bring an archive forward to this GeneaLogic's format version.",
        discussion: """
            An archive written by an older GeneaLogic is refused by every other verb until \
            it is upgraded — migration is never automatic, because upgrading locks out any \
            machine still on the older GeneaLogic. An archive already at the current \
            version is left exactly as it is.
            """
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run() throws {
        try run(stdout: StandardOutput.out, stderr: StandardOutput.err)
    }

    func run(stdout: CLIOutput, stderr: CLIOutput) throws {
        let archiveURL = URL(fileURLWithPath: archive, isDirectory: true)
        do {
            let outcome = try Archive.upgrade(at: archiveURL)
            if outcome.wasAlreadyCurrent {
                // Not "nothing changed": an open behind this call puts a straggler
                // manifest's stamp right, which is a write (slice 64, fork g).
                stdout.writeLine("Archive is already in format \(outcome.to).")
            } else {
                stdout.writeLine("Upgraded archive from format \(outcome.from) to \(outcome.to).")
            }
        } catch {
            throw ExitCode(rawValue: CLIError.report(error, to: stderr).rawValue)
        }
    }
}

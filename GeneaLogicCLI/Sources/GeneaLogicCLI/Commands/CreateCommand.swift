import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea create <path> [--name <name>]` → `Archive.create(at:name:)`.
struct CreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new, empty GeneaLogic archive at the given path."
    )

    @Argument(help: "Directory to create the archive in (created if absent).")
    var path: String

    @Option(name: .long, help: "Optional human-readable name for the archive.")
    var name: String?

    func run() throws {
        try run(stdout: StandardOutput.out, stderr: StandardOutput.err)
    }

    /// Testable entry point: `run()` (ArgumentParser's contract) delegates here
    /// with the real stdout/stderr; tests call this directly with a
    /// `CollectingOutput`.
    func run(stdout: CLIOutput, stderr: CLIOutput) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            let archive = try Archive.create(at: url, name: name)
            stdout.writeLine("Created archive at \(archive.rootURL.path)")
        } catch {
            throw ExitCode(rawValue: CLIError.report(error, to: stderr).rawValue)
        }
    }
}

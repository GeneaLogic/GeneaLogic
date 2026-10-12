import ArgumentParser
import Foundation
import GeneaLogicSample

/// `genea sample <path>` → `SampleArchive.build(at:)` (slice 74b): an invented family's
/// archive to try the CLI and the app on.
struct SampleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sample",
        abstract: "Create the sample archive, an invented family, at the given path."
    )

    @Argument(help: "Where to create the sample archive. Nothing may exist there yet.")
    var path: String

    func run() throws {
        try run(stdout: StandardOutput.out, stderr: StandardOutput.err)
    }

    /// Testable entry point; see `CreateCommand.run(stdout:stderr:)`.
    func run(stdout: CLIOutput, stderr: CLIOutput) throws {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try SampleArchive.build(at: url)
            stdout.writeLine("Created the sample archive at \(url.path)")
        } catch {
            throw ExitCode(rawValue: CLIError.report(error, to: stderr).rawValue)
        }
    }
}

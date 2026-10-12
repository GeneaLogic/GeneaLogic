import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea list <archive>` → `artifacts()`.
///
/// **Output discipline (load-bearing):** one artifact per line, strictly
/// `<uid>\t<title>` — no decorative header, no extra columns — so
/// `genea list <archive> | cut -f1` and similar pipelines work (Phase 1b: "`list`/`find`
/// print `uid` + title for piping").
struct ListCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List every artifact as <uid>\\t<title>, one per line."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        for summary in opened.artifacts() {
            stdout.writeLine("\(summary.uid.raw)\t\(summary.title)")
        }
    }
}

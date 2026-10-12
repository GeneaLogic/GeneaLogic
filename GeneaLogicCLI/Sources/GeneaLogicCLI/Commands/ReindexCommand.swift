import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea reindex <archive>` → `rebuildIndex()`.
struct ReindexCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex",
        abstract: "Rebuild the archive's .index/index.sqlite from the on-disk sidecars."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let skipped = try opened.rebuildIndex()
        stdout.writeLine("Index rebuilt.")

        // A rebuild that silently dropped records would be the same failure this
        // path exists to avoid, one level quieter (slice 55). Named on stderr so
        // a script's captured stdout stays "Index rebuilt.", and the exit stays
        // zero: the rebuild did succeed, and `genea verify` is what reports the
        // archive's state.
        guard !skipped.isEmpty else { return }
        stderr.writeLine(
            "warning: \(skipped.count) record(s) could not be read and are absent from the index:")
        for path in skipped {
            stderr.writeLine("  \(path)")
        }
        // Both forms name the archive, because a line a user copies has to run as
        // written — `genea repair --record <path>` alone exits on a missing
        // positional argument (review finding, 59).
        stderr.writeLine(
            "See `genea verify \(archive)`: it says which of them GeneaLogic still has a "
                + "copy of, and `genea repair \(archive) --record <path>` restores those.")
    }
}

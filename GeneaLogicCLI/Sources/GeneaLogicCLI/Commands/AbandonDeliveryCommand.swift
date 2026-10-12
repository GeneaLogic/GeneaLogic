import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea abandon-delivery <archive> <path>…` → `abandonDelivery(path:)`.
///
/// The way out of the one state slices 50 and 50b deliberately left standing:
/// the manifest expects a version of a file that is never going to arrive, and
/// no evidence can say so (slice 50d). `genea verify` reports it as
/// `awaiting-delivery` on every run, and — correctly, for a delivery that is
/// merely slow — tells the user to wait rather than to run `genea rebaseline`.
/// This is how they say the waiting is over for one named file.
///
/// **Paths, plural, but one decision each** (fork d). Repeating the argument is
/// a convenience for a machine that lost several files at once; there is no
/// `--all`, because that is `rebaseline` with a friendlier name and it re-mints
/// from disk archive-wide. Each path is its own mutation, so a refusal on one
/// leaves the others done and is reported on its own line.
struct AbandonDeliveryCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "abandon-delivery",
        abstract: "Stop waiting for a file the manifest expects but that is never going to "
            + "arrive from another machine.",
        discussion: """
            Use this only after `genea verify` has reported the path as \
            `awaiting-delivery` and it has stayed that way — a slow link and a stopped \
            one look identical, so GeneaLogic will not guess for you.

            For each path: if the file is here, the manifest is re-recorded from the copy \
            on this machine, which becomes the version of record. If the file never \
            arrived at all, the expectation is simply dropped.

            Nothing is deleted and no file is touched, so it is recoverable: if the \
            version does turn up later, the next reindex takes it into the index and the \
            next change re-records it.

            It refuses a path the archive is not actually waiting for — in particular one \
            that disagrees with the manifest with no delivery to account for it, which is \
            damage rather than a delivery that stopped coming.
            """
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "Archive-relative path(s) to stop waiting for.")
    var paths: [String]

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        var refused = false
        for path in paths {
            do {
                try opened.abandonDelivery(path: path)
                stdout.writeLine(
                    "abandoned\t\(path)\tthe archive is no longer waiting for this file.")
            } catch let error as ArchiveError {
                // Reported and carried on rather than thrown: with several paths
                // named, one refusal must not discard the decisions already made
                // for the others, and each refusal names its own reason.
                refused = true
                stderr.writeLine("\(path): \(error.description)")
            }
        }
        if refused { throw ExitCode.failure }
    }
}

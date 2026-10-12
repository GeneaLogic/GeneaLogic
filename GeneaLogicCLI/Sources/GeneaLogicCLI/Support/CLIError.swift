import ArgumentParser
import Foundation
import GeneaLogicArchive

/// Renders a thrown error to `stderr` and produces the `ExitCode` ArgumentParser
/// should exit with.
///
/// **Error-rendering contract (judgment call):** `ArchiveError` already has a
/// human-readable `description` (`CustomStringConvertible`) — every command
/// catches `ArchiveError` and prints `error.description` verbatim rather than
/// Swift's default `"ArchiveError.artifactNotFound(ArtifactID(raw: \"ART-…\"))"`
/// dump. Any other error (e.g. a filesystem error from `Foundation`) falls back
/// to `String(describing:)`, which is less polished but still better than a raw
/// crash/backtrace. Every failure path exits non-zero via `ExitCode.failure`
/// (`1`) — `verify`'s "report is not clean" case is the one place a *successful*
/// run still exits non-zero, handled separately in `VerifyCommand`.
enum CLIError {
    /// Prints `error`'s message to `output` (normally `stderr`) and returns the
    /// `ExitCode` the command should throw to terminate the process non-zero.
    static func report(_ error: Error, to output: CLIOutput) -> ExitCode {
        if let archiveError = error as? ArchiveError {
            output.writeLine("Error: \(archiveError.description)")
        } else {
            output.writeLine("Error: \(String(describing: error))")
        }
        return .failure
    }
}

/// A user-facing usage/state error raised from inside a command's body — a bad
/// flag combination (`fact add` with neither `--person` nor `--relationship`), an
/// out-of-range index, a record that isn't the kind the command needs.
///
/// ArgumentParser's own `ValidationError` covers *parse-time* problems, but these
/// checks need the opened archive (or a cross-flag rule) and so happen inside
/// `run`. `CLIError.report`'s `String(describing:)` fallback renders this as its
/// `description`, so it prints as `Error: <message>` like every other failure and
/// exits non-zero.
struct CLIUserError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    /// The shared "you addressed an array element that isn't there" error, used by
    /// every index-addressed edit (`person name set|remove`, `fact remove`,
    /// `event remove`, `place remove`).
    ///
    /// These are the commands that address a record's array by the position a
    /// `show` command prints, and each had drifted to its own phrasing — one
    /// message per site, differing in capitalization and grammar. One constructor
    /// keeps them identical. `see` names the command that prints the indices —
    /// `genea person show` for conclusion edits (the default), `genea show` for
    /// the artifact-side event/place edits.
    static func outOfRange(
        _ kind: String, index: Int, count: Int, see: String = "genea person show"
    )
        -> CLIUserError
    {
        CLIUserError(
            "No \(kind) at index \(index) (there \(count == 1 ? "is" : "are") \(count)). "
                + "See `\(see)`.")
    }
}

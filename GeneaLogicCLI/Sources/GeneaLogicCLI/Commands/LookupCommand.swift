import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea lookup <archive> (--at-path <p> | --external-id <scheme=value> |
/// --sha256 <hash> | --mentions <PER-uid>)` — the four **exact** point lookups
/// the engine exposes over the index, in one command with mutually-exclusive
/// modes.
///
/// Kept apart from `find` on purpose: `find` runs an `ArtifactQuery` (free text +
/// facets AND-combined), while each of these resolves an artifact by an *exact*
/// key. Two return a single artifact (`--at-path`, `--external-id`) and two a set
/// (`--sha256`, `--mentions`), but all emit the same pipe-friendly `<uid>\t<title>`
/// lines as `list`/`find`, so a script consumes them identically.
///
/// **`--mentions` is the conclusions-aware complement to `find --mentioning`.**
/// `find --mentioning <text>` matches a name-as-recorded *substring* across
/// mentions; `lookup --mentions <PER-uid>` follows the `EvidenceLink`s to a
/// concluded person (`artifacts(mentioning:)`). Different questions, different
/// flags.
struct LookupCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "lookup",
        abstract: "Resolve artifacts by an exact key (path, external id, file hash, person)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(
        name: .customLong("at-path"),
        help: "Archive-root-relative path of an artifact's folder or a file it owns.")
    var atPath: String?

    @Option(name: .customLong("external-id"), help: "An external identifier as scheme=value.")
    var externalID: String?

    @Option(name: .long, help: "A file content SHA-256 (the dedup check).")
    var sha256: String?

    @Option(name: .long, help: "A concluded person's uid (PER-…); finds artifacts citing them.")
    var mentions: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        // Exactly one mode. Counting the non-nil flags keeps the "one and only
        // one" rule in a single place rather than a switch over every pairing.
        let modes = [atPath, externalID, sha256, mentions].compactMap { $0 }
        guard modes.count == 1 else {
            throw CLIUserError(
                "Specify exactly one of --at-path, --external-id, --sha256 or --mentions.")
        }

        if let atPath {
            // A single artifact (or none).
            if let artifact = opened.artifact(atPath: atPath) {
                stdout.writeLine("\(artifact.uid.raw)\t\(artifact.title)")
            }
        } else if let externalID {
            let identifier = try ExternalIdentifier.parsing(token: externalID)
            if let artifact = opened.artifact(withExternalIdentifier: identifier) {
                stdout.writeLine("\(artifact.uid.raw)\t\(artifact.title)")
            }
        } else if let sha256 {
            for summary in opened.artifacts(containingFileWithSHA256: sha256) {
                stdout.writeLine("\(summary.uid.raw)\t\(summary.title)")
            }
        } else if let mentions {
            for summary in opened.artifacts(mentioning: PersonID(mentions)) {
                stdout.writeLine("\(summary.uid.raw)\t\(summary.title)")
            }
        }
    }
}

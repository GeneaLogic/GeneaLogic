import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea attach <archive> --artifact <uid> --file <path> [--role <role>]` →
/// `attachFile(copyingFrom:to:role:)`. Prints the minted file uid + assigned
/// `path`; if the attached content duplicates an existing file in the same
/// artifact, notes that on stderr (non-fatal — `attachFile` always stores the
/// new file regardless, per its doc comment).
struct AttachCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach a file to an artifact and print its minted file uid + path."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact's uid (e.g. ART-…).")
    var artifact: String

    @Option(name: .long, help: "Path to the local file to copy in.")
    var file: String

    /// Closed vocabulary (`FileRole`) — `--role` must be one of its raw values
    /// (`preservation-master`, `access-copy`, `derivative`, `transcript`).
    /// Unlike `--media-type`/`--source-tier`, `FileRole` has no `.unknown` case
    /// (CLAUDE.md: closed vocabularies are strict), so an unrecognized value is
    /// rejected by ArgumentParser itself via `ExpressibleByArgument`.
    @Option(name: .long, help: "File role.")
    var role: FileRole = .preservationMaster

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let sourceURL = URL(fileURLWithPath: file)
        let attached = try opened.attachFile(
            copyingFrom: sourceURL, to: ArtifactID(artifact), role: role)
        stdout.writeLine("\(attached.entry.uid.raw)\t\(attached.entry.path)")
        if !attached.duplicatesOf.isEmpty {
            let paths = attached.duplicatesOf.map(\.path).joined(separator: ", ")
            stderr.writeLine(
                "Note: byte-identical content already attached as: \(paths)")
        }
    }
}

/// Lets `--role` be parsed directly into `FileRole` by ArgumentParser, using
/// the enum's existing `String` raw values (e.g. `"preservation-master"`) —
/// the same strings the archive format itself uses (CLAUDE.md: closed
/// vocabularies are strict `String`-backed enums).
extension FileRole: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

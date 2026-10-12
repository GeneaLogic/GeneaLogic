import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea place …` — an artifact's `locations` (ARCHITECTURE.md §4.2).
///
/// The place twin of `event`: evidence, captured as the document records it. A
/// `Location` keeps the place name `asRecorded` plus an optional `normalized`
/// form — the `Event`'s embedded `location` string and this structured
/// `locations` array are distinct model concepts, and this command writes the
/// latter (see the notes on `Location`/`Event`).
struct PlaceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "place",
        abstract: "Add or remove a place recorded by an artifact.",
        subcommands: [PlaceAddCommand.self, PlaceRemoveCommand.self]
    )
}

// MARK: - place add

/// `genea place add <archive> <ART-uid> --as-recorded <s> [--normalized <n>]`
/// → `updateMetadata`, appending a `Location` and printing its minted index.
struct PlaceAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Record a place on an artifact; prints its minted index."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact the place appears in (ART-…).")
    var artifact: String

    @Option(name: .customLong("as-recorded"), help: "The place name exactly as recorded.")
    var asRecorded: String

    @Option(name: .long, help: "A normalized / disambiguated form, if known.")
    var normalized: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let location = Location(asRecorded: asRecorded, normalized: normalized)
        // `updateMetadata` returns Void; capture the minted index in the closure.
        var mintedIndex = 0
        try opened.updateMetadata(of: ArtifactID(artifact)) { record in
            mintedIndex = record.locations.count
            record.locations.append(location)
        }
        stdout.writeLine("\(mintedIndex)\t" + ArtifactFormat.locationLine(location))
    }
}

// MARK: - place remove

/// `genea place remove <archive> <ART-uid> --index <n>` → `updateMetadata`.
/// Index-addressed like `event remove`; the bounds check lives inside the
/// mutate closure.
struct PlaceRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a place by index (see `genea show`)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact (ART-…).")
    var artifact: String

    @Option(name: .long, help: "Which place to remove, as shown by `genea show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        var removed: Location?
        var outOfRange: Int?
        let selected = index

        try opened.updateMetadata(of: id) { record in
            guard record.locations.indices.contains(selected) else {
                outOfRange = record.locations.count
                return
            }
            removed = record.locations.remove(at: selected)
        }

        if let count = outOfRange {
            throw CLIUserError.outOfRange("place", index: selected, count: count, see: "genea show")
        }
        stdout.writeLine(
            "Removed place [\(selected)] from \(id.raw)\t"
                + (removed.map(ArtifactFormat.locationLine) ?? ""))
    }
}

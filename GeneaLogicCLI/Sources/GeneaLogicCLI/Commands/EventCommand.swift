import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea event …` — an artifact's `events` (ARCHITECTURE.md §4.2).
///
/// **Evidence, not conclusion** — the same boundary `mention` respects. An event
/// is "what this document records happened" (a census enumeration, a recorded
/// birth), captured as it appears; deriving a `PersonFact` from it is a separate,
/// human-confirmed act (§2.3, §6.4). So it lives under its own noun with the
/// artifact as a positional argument, exactly like `mention`.
///
/// This closes the load-bearing 44b gap: without it a script can seed a family
/// but not a family *from documents* — a date or place on a record was
/// unwritable headlessly.
struct EventCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "event",
        abstract: "Add or remove an event recorded by an artifact.",
        subcommands: [EventAddCommand.self, EventRemoveCommand.self]
    )
}

// MARK: - event add

/// `genea event add <archive> <ART-uid> --type <t> [--date <d>] [--location <l>]`
/// → `updateMetadata`, appending an `Event` and printing its minted index.
///
/// `--date` accepts the genealogist shorthands the app's date field does (`"abt
/// 1920"`, `"June 1920"`, `"1940s"`) and stores canonical EDTF via
/// `EDTFDate.normalizingShorthand`, exactly as `fact add` does; anything it can't
/// normalize is kept verbatim as free text, never rejected.
struct EventAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Record an event on an artifact; prints its minted index."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact the event is recorded in (ART-…).")
    var artifact: String

    @Option(name: .long, help: "Event type, e.g. Census, Birth, Death, Marriage.")
    var type: String

    @Option(name: .long, help: "Date — EDTF or shorthand (\"abt 1920\", \"June 1920\", \"1940s\").")
    var date: String?

    @Option(name: .long, help: "Location, as recorded in the document.")
    var location: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let storedDate = date.map { EDTFDate.normalizingShorthand($0) }
        let event = Event(type: type, date: storedDate, location: location)

        // `updateMetadata` returns Void, so the minted index is captured inside
        // the closure (against the record the engine loaded), as `mention add`
        // captures its `localRef`.
        var mintedIndex = 0
        try opened.updateMetadata(of: ArtifactID(artifact)) { record in
            mintedIndex = record.events.count
            record.events.append(event)
        }
        // Data columns, not prose: the minted index leads so it composes with
        // `event remove --index` (the `fact`/`attach` precedent).
        stdout.writeLine("\(mintedIndex)\t" + ArtifactFormat.eventLine(event))
    }
}

// MARK: - event remove

/// `genea event remove <archive> <ART-uid> --index <n>` → `updateMetadata`.
///
/// Events are an array with no ids of their own, so they're addressed by the
/// index `genea show` prints. The bounds check runs *inside* the mutate closure,
/// against the record the engine loaded — the established index-addressed-edit
/// pattern (`fact remove`, `person name remove`).
struct EventRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove an event by index (see `genea show`)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact (ART-…).")
    var artifact: String

    @Option(name: .long, help: "Which event to remove, as shown by `genea show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        var removed: Event?
        var outOfRange: Int?
        let selected = index

        try opened.updateMetadata(of: id) { record in
            guard record.events.indices.contains(selected) else {
                outOfRange = record.events.count
                return
            }
            removed = record.events.remove(at: selected)
        }

        if let count = outOfRange {
            throw CLIUserError.outOfRange("event", index: selected, count: count, see: "genea show")
        }
        stdout.writeLine(
            "Removed event [\(selected)] from \(id.raw)\t"
                + (removed.map(ArtifactFormat.eventLine) ?? ""))
    }
}

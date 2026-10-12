import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea relationship …` — the concluded relationship graph (ARCHITECTURE.md
/// §4.5).
///
/// Grouped under a noun like `person`, for the same reason: a flat verb couldn't
/// say what it lists. Only `list` exists here — a single relationship is already
/// viewable per-person through `person show` (which renders each relationship's
/// facts indented by index, the ids `fact remove --relationship` takes). What
/// `person show` can't give is the **flat, whole-graph** view a tree-shaped
/// consumer wants; that's this.
struct RelationshipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relationship",
        abstract: "List concluded relationships.",
        subcommands: [RelationshipListCommand.self]
    )
}

/// `genea relationship list <archive>` → `relationships()`.
///
/// One relationship per line, strictly `<uid>\t<type>\t<person1>\t<person2>` — the
/// same pipe-friendly discipline as `list`/`person list`. The endpoints are the
/// raw `person1Uid`/`person2Uid`; per the §4.5 convention, for a `parent-child`
/// relationship `person1` is the parent and `person2` the child (a couple is
/// symmetric). Ordered by uid (creation order), matching the engine.
struct RelationshipListCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List relationships as <uid>\\t<type>\\t<person1>\\t<person2>, one per line."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        for relationship in opened.relationships() {
            stdout.writeLine(
                "\(relationship.uid.raw)\t\(relationship.type.rawValue)"
                    + "\t\(relationship.person1Uid.raw)\t\(relationship.person2Uid.raw)")
        }
    }
}

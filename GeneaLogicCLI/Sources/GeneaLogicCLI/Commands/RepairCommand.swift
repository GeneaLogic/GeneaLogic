import ArgumentParser
import Foundation
import GeneaLogicArchive

/// `genea repair <archive> --record <path>` → `repairRecord(atPath:)`, and with
/// `--delete` → `deleteVanishedRecord(atPath:)` (slice 58d).
///
/// The verb that answers `genea verify` and `genea reindex`, which have named
/// records they could not read since slice 55 and had nothing to tell anyone to do
/// about them. It restores the record from the copy the index kept (58) and moves
/// the file that was there into `.damaged/`.
///
/// **It restores the last version *GeneaLogic wrote*.** If the file was hand-edited
/// — or written by a newer GeneaLogic — that version is what goes to `.damaged/`,
/// and the restored record will not have it. That is why the command says where the
/// old bytes went every time, rather than only when something looks wrong: an agent
/// reading this output is the case the sentence exists for.
struct RepairCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "repair",
        abstract: "Restore a record GeneaLogic can no longer read, from its saved copy.",
        discussion: """
            The saved copy is the record as GeneaLogic last wrote it, kept in the index. \
            The file found in its place is moved to the archive's .damaged/ directory \
            rather than overwritten, so a hand-edit that this discards can still be \
            recovered by hand.

            There is not always a copy — a record that never decoded was never indexed, \
            and the copy does not survive a rebuild that had to discard the index. Run \
            `genea verify` first: it says which unreadable or missing records can be \
            restored.

            --delete is the other answer for a record whose file is gone: it puts the \
            record back and deletes it the ordinary way, so an artifact goes to the \
            archive's trash (with anything left in its folder) and `genea trash restore` \
            brings it back. It is refused for a record whose file is still there.
            """
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(
        name: .customLong("record"),
        help: "Archive-relative path of the record to restore, e.g. artifacts/deed/record.json.")
    var record: String

    @Flag(
        name: .customLong("accept-inexact"),
        help: "Restore even when the copy is not byte-identical to what the manifest recorded.")
    var acceptInexact = false

    @Flag(
        name: .customLong("delete"),
        help: "Delete a record whose file is gone, instead of restoring it.")
    var delete = false

    func validate() throws {
        if delete && acceptInexact {
            throw ValidationError("--delete and --accept-inexact cannot be used together.")
        }
    }

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        if delete {
            try runDelete(opened, stdout: stdout)
            return
        }
        let outcome = try opened.repairRecord(
            atPath: record, acceptingInexactRestore: acceptInexact)

        if outcome.wasByteExact {
            stdout.writeLine(
                "Restored \(outcome.path) (\(outcome.uid)) — byte-identical to what the "
                    + "manifest recorded.")
        } else {
            stdout.writeLine("Restored \(outcome.path) (\(outcome.uid)).")
            // On stderr because it qualifies the result rather than being it: a
            // script's captured stdout stays the restoration, and the caveat still
            // reaches a human reading the terminal.
            stderr.writeLine(
                "warning: this copy is not byte-identical to what the manifest recorded. It "
                    + "is the last version this GeneaLogic could read, and may be missing "
                    + "fields written by a newer one.")
        }

        if let quarantined = outcome.quarantinedPath {
            stdout.writeLine("The file that was there was moved to \(quarantined).")
        }
    }

    /// Deleting a missing record (slice 58d): restored from its copy, then
    /// deleted the ordinary way. The engine refuses it, under the write lock, when
    /// something is at the path — an unreadable record, or a file that came back.
    private func runDelete(_ opened: Archive, stdout: CLIOutput) throws {
        switch try opened.deleteVanishedRecord(atPath: record) {
        case .artifact(let uid, _):
            stdout.writeLine(
                "Deleted \(record) (\(uid.raw)); the artifact is in the archive's trash — "
                    + "`genea trash restore \(archive) \(uid.raw)` brings it back.")
        case .person(let person):
            stdout.writeLine("Deleted \(record) (\(person.uid.raw)).")
        case .relationship(let relationship):
            stdout.writeLine("Deleted \(record) (\(relationship.uid.raw)).")
        case .link(let link):
            stdout.writeLine("Deleted \(record) (\(link.uid.raw)).")
        case .dismissal(let dismissal):
            stdout.writeLine("Deleted \(record) (\(dismissal.uid.raw)).")
        }
    }
}

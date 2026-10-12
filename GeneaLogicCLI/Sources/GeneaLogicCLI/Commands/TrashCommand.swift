import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea trash …` — the in-package `.trash/` store (slices 20 & 21).
///
/// Deleting an artifact or detaching a file moves its bytes into a reserved
/// `.trash/<uid>/` inside the package rather than destroying them, so a deletion
/// survives quitting the app. The CLI had no view of that store at all; these
/// commands are the headless door to the same one the app's Trash sheet opens.
///
/// **One namespace, two kinds.** Artifacts (`ART-…`) and files (`FIL-…`) share
/// the trash, keyed by their own uids — the `TrashEntry.kind` discriminator — and
/// since the two prefixes cannot collide, `restore`/`remove` take a bare uid and
/// dispatch on it rather than making the caller repeat the kind as a flag.
struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "List, restore, or permanently delete trashed artifacts and files.",
        subcommands: [
            TrashListCommand.self,
            TrashRestoreCommand.self,
            TrashRemoveCommand.self,
            TrashEmptyCommand.self,
        ]
    )
}

// MARK: - trash list

/// `genea trash list <archive>` → `trashedArtifacts()` + `trashedFiles()`.
///
/// One entry per line as `<kind>\t<uid>\t<name>\t<deletedAt>`, artifacts then
/// files — pipe-friendly like `list`/`find`, with `kind` first so
/// `genea trash list a.genea | grep ^file` works.
struct TrashListCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List trashed artifacts and files as <kind>\\t<uid>\\t<name>\\t<deleted-at>."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        for entry in opened.trashedArtifacts() {
            stdout.writeLine(
                "artifact\t\(entry.uid.raw)\t\(entry.title)\t\(entry.deletedAt)")
        }
        for entry in opened.trashedFiles() {
            stdout.writeLine(
                "file\t\(entry.uid.raw)\t\(entry.originalName)\t\(entry.deletedAt)")
        }
    }
}

// MARK: - trash restore

/// `genea trash restore <archive> <uid>` → `restoreFromTrash` / `restoreFile`.
///
/// An artifact comes back uid-faithfully (reusing its slug when still free); a
/// file is re-attached to the artifact it was detached from. Conclusions are
/// untouched either way — a link that dangled while the artifact sat in the trash
/// simply resolves again.
struct TrashRestoreCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a trashed artifact or file by uid."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The trashed record's uid (ART-… or FIL-…).")
    var uid: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        switch try TrashedKind(uid: uid) {
        case .artifact(let id):
            let restored = try opened.restoreFromTrash(id)
            stdout.writeLine("Restored \(restored.uid.raw)\t\(restored.title)")
        case .file(let id):
            let restored = try opened.restoreFile(id)
            stdout.writeLine("Restored \(restored.uid.raw)\t\(restored.originalName)")
        }
    }
}

// MARK: - trash remove

/// `genea trash remove <archive> <uid>` → `deleteFromTrash` / `deleteFileFromTrash`.
///
/// **Irreversible** — this is where the bytes actually go away, the one deletion
/// in the archive with nothing behind it.
///
/// Which is why this command checks the entry exists *first*, rather than
/// leaning on the engine: `deleteFromTrash`/`deleteFileFromTrash` are documented
/// **lenient** about a uid that isn't in the trash (they no-op), so reporting
/// their silence as "Permanently deleted" would tell a user who fat-fingered one
/// hex digit that their entry is gone while it quietly survives — until a later
/// `trash empty` destroys it unexpectedly. A false success is worst precisely
/// here, on the one path with no undo. (`trash restore` needs no such guard: the
/// engine throws there.)
struct TrashRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Permanently delete one trashed artifact or file (irreversible)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The trashed record's uid (ART-… or FIL-…).")
    var uid: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        switch try TrashedKind(uid: uid) {
        case .artifact(let id):
            guard opened.trashedArtifacts().contains(where: { $0.uid == id }) else {
                throw CLIUserError(notInTrash)
            }
            try opened.deleteFromTrash(id)
        case .file(let id):
            guard opened.trashedFiles().contains(where: { $0.uid == id }) else {
                throw CLIUserError(notInTrash)
            }
            try opened.deleteFileFromTrash(id)
        }
        stdout.writeLine("Permanently deleted \(uid)")
    }

    private var notInTrash: String {
        "\(uid) isn't in the trash. See `genea trash list`."
    }
}

// MARK: - trash empty

/// `genea trash empty <archive>` → `emptyTrash()`, clearing both kinds.
/// **Irreversible.**
struct TrashEmptyCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "empty",
        abstract: "Permanently delete everything in the trash (irreversible)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let artifacts = opened.trashedArtifacts().count
        let files = opened.trashedFiles().count
        try opened.emptyTrash()
        stdout.writeLine("Emptied trash: \(artifacts) artifact(s), \(files) file(s)")
    }
}

// MARK: - uid dispatch

/// Which trash entry a bare uid names, decided by its type prefix.
///
/// The uid prefix is authoritative here precisely because it's minted, not typed
/// by a human (CLAUDE.md: "`uid` is a type-prefixed UUIDv7"), so `ART-`/`FIL-`
/// cannot collide and the caller never has to restate the kind.
private enum TrashedKind {
    case artifact(ArtifactID)
    case file(FileID)

    init(uid: String) throws {
        if uid.hasPrefix("ART-") {
            self = .artifact(ArtifactID(uid))
        } else if uid.hasPrefix("FIL-") {
            self = .file(FileID(uid))
        } else {
            throw CLIUserError(
                "\(uid) isn't a trashed record's uid — expected an artifact (ART-…) "
                    + "or file (FIL-…). See `genea trash list`.")
        }
    }
}

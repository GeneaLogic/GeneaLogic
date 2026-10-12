import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea remove <archive> <ART-uid>` → `removeArtifact`.
///
/// A flat, artifact-scoped verb like its Phase-1 siblings (`add`/`attach`/`list`),
/// which is why it isn't `artifact remove`.
///
/// **This is a move to the trash, not a destruction.** The artifact's whole
/// folder is renamed into the package's reserved `.trash/<uid>/` (slice 20), so
/// it survives the process and comes back with `genea trash restore`. Bytes only
/// go away at `genea trash remove`/`empty`. Conclusions are untouched (§2.3): an
/// evidence link citing this artifact dangles while it sits in the trash and
/// resolves again if it's restored — which is also exactly what keeps the
/// deletion reversible.
struct RemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Move an artifact to the archive's trash (restorable)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact's uid (e.g. ART-…).")
    var artifact: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        // Rejections counted too: this is an integrity statement about what the removal
        // leaves dangling, the same scope `findDanglingReferences()` audits — not a
        // conclusions view, where a tombstone would have no business appearing.
        let citingLinks = opened.links(forArtifact: id, includeRejected: true).count

        // `ArtifactDeletion`'s own `uid` is internal to the engine (it's the undo
        // token, not a public accessor), so the id we were given is what we echo.
        _ = try opened.removeArtifact(id)
        stdout.writeLine("Trashed \(id.raw)")
        if citingLinks > 0 {
            stdout.writeLine(
                "\(citingLinks) evidence link(s) now dangle; restoring the artifact "
                    + "resolves them again.")
        }
    }
}

// MARK: - detach

/// `genea detach <archive> --artifact <uid> --file <FIL-uid>` → `detachFile`.
///
/// The file counterpart of `remove`, and trash-backed the same way (slice 21): the
/// bytes move to `.trash/<FIL-uid>/` and `genea trash restore` re-attaches them
/// to the artifact they came from.
struct DetachCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Move one of an artifact's files to the trash (restorable)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact the file belongs to (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The file's uid (FIL-…).")
    var file: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let change = try opened.detachFile(FileID(file), in: ArtifactID(artifact))
        switch change.operation {
        case .removed(let entry):
            stdout.writeLine("Trashed \(entry.uid.raw)\t\(entry.originalName)")
        case .added, .replaced:
            // `detachFile` only ever reports `.removed`; the other cases belong to
            // attach/replace. Nothing sensible to print, so say what happened.
            stdout.writeLine("Detached \(file)")
        }
    }
}

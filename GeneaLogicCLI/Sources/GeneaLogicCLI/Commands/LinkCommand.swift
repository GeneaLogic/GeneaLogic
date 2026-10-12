import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea link <archive> --artifact <ART-uid> --mention <localRef>
/// --person <PER-uid> [--reviewed-by <name>]` → `link(_:to:reviewedBy:)`,
/// printing the minted `LNK-` uid.
///
/// This is the evidence→conclusion bridge: it resolves "the name as it appears
/// in this document" (a `PersonMention`, evidence) to "this person" (a `Person`,
/// a conclusion) — §2.3's two layers, joined by an explicit human act and never
/// by inference. `--mention` is the mention's record-local `localRef` (`p1`,
/// `p2`, …), which `genea show`-style artifact output and the app's inspector
/// both expose.
///
/// `--reviewed-by` records *who* confirmed it (`EvidenceLink.reviewedBy`);
/// omitting it leaves the field `nil` rather than inventing an identity.
struct LinkCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Resolve an artifact's person-mention to a concluded person."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact containing the mention (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The mention's record-local ref (e.g. p1).")
    var mention: String

    @Option(name: .long, help: "The concluded person the mention identifies (PER-…).")
    var person: String

    @Option(name: .customLong("reviewed-by"), help: "Name of the human confirming this link.")
    var reviewedBy: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let ref = MentionRef(artifact: ArtifactID(artifact), localRef: mention)
        let decision = try opened.link(
            ref,
            to: PersonID(person),
            reviewedBy: reviewedBy.map { Reviewer.human($0) } ?? .unspecified
        )
        stdout.writeLine(decision.link.uid.raw)
        CLIReview.reportDisplacement(decision, to: stdout)
    }
}

// MARK: - unlink

/// `genea unlink <archive> <lnk-uid>` → `unlink`.
///
/// Removes only the link. The mention stays on the artifact (it's evidence — the
/// document still records that name) and the person stays concluded; unlinking
/// says "these two are not the same person", not "this name was never written".
struct UnlinkCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "unlink",
        abstract: "Remove an evidence link (the mention and person are untouched)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The evidence link's uid (e.g. LNK-…).")
    var link: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let removed = try opened.unlink(EvidenceLinkID(link))
        stdout.writeLine(
            "Removed \(removed.uid.raw)\t\(removed.artifactUid.raw)\t\(removed.personUid.raw)")
    }
}

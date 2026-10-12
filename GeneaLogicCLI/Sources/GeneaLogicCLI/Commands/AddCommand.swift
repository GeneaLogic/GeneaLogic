import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea add <archive> --title <t> [--media-type <m>] [--source-tier <s>]
/// [--source-derivation <d>] [--tag <tag> ...] [--notes <n>]` → builds an `ArtifactDraft` and calls
/// `addArtifact`, printing the minted `uid`.
struct AddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a new artifact to the archive and print its minted uid."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact's title.")
    var title: String

    /// Open vocabulary (`MediaType`) — any string is accepted; unrecognized
    /// values round-trip via `.unknown(String)`. See `OpenVocabulary+CLI.swift`.
    @Option(name: .customLong("media-type"), help: "Media type (e.g. image, text, document).")
    var mediaType: String = MediaType.image.rawValue

    /// Open vocabulary (`SourceAuthorityTier`) — same `.unknown(String)`
    /// fallback as `--media-type`.
    ///
    /// **No default since 46b.** It defaulted to `compiled`, so every artifact added
    /// without the flag asserted *"somebody's conclusion, not evidence"* about itself and
    /// scored 25 — below the 40 an uncharacterised record earns. Absent now means
    /// *unstated*, the rule `--source-derivation` already followed.
    @Option(
        name: .customLong("source-tier"),
        help: "Source authority tier (e.g. vital, church, government, census, monument).")
    var sourceTier: String?

    /// GPS derivation, orthogonal to `--source-tier`: a register page and an index
    /// entry typed from it are both `church` and are not equal evidence. No default —
    /// absent means *unstated*, never "original".
    @Option(
        name: .customLong("source-derivation"),
        help: "How far the source is from the event (original, derivative, authored).")
    var sourceDerivation: String?

    @Option(name: .long, parsing: .singleValue, help: "A tag to attach (repeatable).")
    var tag: [String] = []

    @Option(name: .long, help: "Free-form notes.")
    var notes: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let draft = ArtifactDraft(
            title: title,
            mediaType: .parsing(mediaType),
            sourceAuthorityTier: sourceTier.map { .parsing($0) },
            sourceDerivation: sourceDerivation.map { .parsing($0) },
            tags: tag,
            notes: notes
        )
        let artifact = try opened.addArtifact(draft)
        stdout.writeLine(artifact.uid.raw)
    }
}

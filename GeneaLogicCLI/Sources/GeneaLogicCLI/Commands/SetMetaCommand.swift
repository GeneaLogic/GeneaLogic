import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea set-meta <archive> --artifact <uid> [--title <t>] [--notes <n>]
/// [--tag <tag> ...] [--clear-tags] [--media-type <m>] [--source-tier <s>]
/// [--source-derivation <d>] [--clear-source-derivation]
/// [--transcript <t>] [--language <l>] [--original-format <f>]
/// [--external-id <scheme=value> ...] [--clear-external-ids]
/// [--retrieval-source <s> --retrieval-date <d> [--retrieval-checksum <c>]]
/// [--clear-retrieval]` → `updateMetadata(of:_:)`.
///
/// **Only-apply-what-was-passed (judgment call):** `updateMetadata`'s `mutate`
/// closure can change any field of `Artifact`, but this command exposes the
/// descriptive subset a human fixes up after `add` — title, notes, tags, media
/// type, source tier, inline transcript, language, original format, external
/// identifiers and retrieval metadata. Each `@Option` is optional and defaults to
/// `nil`; a flag the user didn't pass leaves that field untouched. The two
/// array/object fields follow the `--tag` rule: `--tag` and `--external-id`
/// (repeatable) **replace** their list wholesale, with `--clear-tags` /
/// `--clear-external-ids` the explicit way to empty it, since an absent flag and
/// "set to `[]`" must be distinguishable. `retrieval` needs `source` + `date`
/// together (see `resolvedRetrieval`).
struct SetMetaCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set-meta",
        abstract: "Update an artifact's metadata fields."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The artifact's uid (e.g. ART-…).")
    var artifact: String

    @Option(name: .long, help: "New title.")
    var title: String?

    @Option(name: .long, help: "New free-form notes.")
    var notes: String?

    @Option(name: .long, parsing: .singleValue, help: "Replace tags with these (repeatable).")
    var tag: [String] = []

    @Flag(name: .customLong("clear-tags"), help: "Remove all tags.")
    var clearTags: Bool = false

    @Option(name: .customLong("media-type"), help: "New media type (e.g. image, text, document).")
    var mediaType: String?

    @Option(
        name: .customLong("source-tier"),
        help: "New source authority tier (e.g. vital, church, government, census, monument).")
    var sourceTier: String?

    /// Same settable-and-clearable pair as `--source-derivation` below, which the tier
    /// needed too once 46b made *unstated* a state it can be in.
    @Flag(
        name: .customLong("clear-source-tier"),
        help: "Remove the source authority tier (back to unstated).")
    var clearSourceTier: Bool = false

    /// A settable-and-clearable optional needs both, or "unstated" becomes
    /// unreachable once set — the `--external-id`/`--retrieval` pattern.
    @Option(
        name: .customLong("source-derivation"),
        help: "New source derivation (original, derivative, authored).")
    var sourceDerivation: String?

    @Flag(
        name: .customLong("clear-source-derivation"),
        help: "Remove the source derivation (back to unstated).")
    var clearSourceDerivation: Bool = false

    @Option(name: .long, help: "New inline transcript.")
    var transcript: String?

    @Option(name: .long, help: "New BCP 47 language tag (e.g. en, de-DE).")
    var language: String?

    @Option(
        name: .customLong("original-format"),
        help: "New original-format description (e.g. \"digital scan\", \"original\").")
    var originalFormat: String?

    /// `--external-id scheme=value` (repeatable) **replaces** the whole
    /// `externalIdentifiers` list, like `--tag`; `--clear-external-ids` empties it
    /// (an absent flag and "set to `[]`" must be distinguishable). The scheme is an
    /// open vocabulary; `repository` isn't expressible here — see
    /// `ExternalIdentifier.parsing(token:)`.
    @Option(
        name: .customLong("external-id"), parsing: .singleValue,
        help: "Replace external identifiers with these scheme=value pairs (repeatable).")
    var externalID: [String] = []

    @Flag(name: .customLong("clear-external-ids"), help: "Remove all external identifiers.")
    var clearExternalIDs: Bool = false

    /// `Retrieval` requires both `source` and `date`, so the two must be passed
    /// together (checksum optional); `--clear-retrieval` nils the whole object.
    @Option(
        name: .customLong("retrieval-source"), help: "Retrieval source (with --retrieval-date).")
    var retrievalSource: String?

    @Option(
        name: .customLong("retrieval-date"),
        help: "Retrieval date, ISO 8601 (with --retrieval-source).")
    var retrievalDate: String?

    @Option(name: .customLong("retrieval-checksum"), help: "Retrieval checksum (optional).")
    var retrievalChecksum: String?

    @Flag(name: .customLong("clear-retrieval"), help: "Remove the retrieval metadata.")
    var clearRetrieval: Bool = false

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)

        // Cross-flag rules resolved *before* the write, so a bad combination
        // fails without touching the record.
        let newExternalIDs = try externalID.map { try ExternalIdentifier.parsing(token: $0) }
        let newRetrieval = try resolvedRetrieval()

        try opened.updateMetadata(of: id) { record in
            if let title { record.title = title }
            if let notes { record.notes = notes }
            if !tag.isEmpty { record.tags = tag } else if clearTags { record.tags = [] }
            if let mediaType { record.mediaType = .parsing(mediaType) }
            if let sourceTier {
                record.sourceAuthorityTier = .parsing(sourceTier)
            } else if clearSourceTier {
                record.sourceAuthorityTier = nil
            }
            if let sourceDerivation {
                record.sourceDerivation = .parsing(sourceDerivation)
            } else if clearSourceDerivation {
                record.sourceDerivation = nil
            }
            if let transcript { record.transcript = transcript }
            if let language { record.language = language }
            if let originalFormat { record.originalFormat = originalFormat }
            if !newExternalIDs.isEmpty {
                record.externalIdentifiers = newExternalIDs
            } else if clearExternalIDs {
                record.externalIdentifiers = []
            }
            if let newRetrieval { record.retrieval = newRetrieval }
            if clearRetrieval { record.retrieval = nil }
        }

        stdout.writeLine("Updated \(id.raw)")
    }

    /// The retrieval object to set, or `nil` if the retrieval flags weren't used.
    /// `source` and `date` are required together (the model demands both); passing
    /// only one is a usage error rather than a half-built record.
    private func resolvedRetrieval() throws -> Retrieval? {
        switch (retrievalSource, retrievalDate) {
        case (nil, nil):
            guard retrievalChecksum == nil else {
                throw CLIUserError(
                    "--retrieval-checksum needs --retrieval-source and --retrieval-date.")
            }
            return nil
        case (let source?, let date?):
            return Retrieval(source: source, date: date, checksum: retrievalChecksum)
        default:
            throw CLIUserError("--retrieval-source and --retrieval-date must be given together.")
        }
    }
}

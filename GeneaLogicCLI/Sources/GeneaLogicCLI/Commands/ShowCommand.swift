import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea show <archive> <ART-uid>` — the artifact analog of `person show`: the
/// human-readable register for one document, with the events and places carrying
/// the indices `event remove` / `place remove` take, and the files their `FIL-`
/// uids.
///
/// A **flat** verb like its Phase-1 artifact siblings (`list`/`find`/`remove`),
/// where `person show` is grouped under a noun only because `add`/`list` were
/// already taken. Everything a document records — its descriptive fields, events,
/// places, mentions, files, transcript — is visible here at once, which `list`
/// and `find` (strict `<uid>\t<title>` for piping) deliberately are not.
struct ShowCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show an artifact's fields, events, places, mentions and files."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact's uid (e.g. ART-…).")
    var artifact: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        guard let record = opened.artifact(withID: id) else {
            throw ArchiveError.artifactNotFound(id)
        }

        stdout.writeLine("\(record.uid.raw)\t\(record.title)")

        // Descriptive fields — blanks omitted rather than printed as empty rows.
        stdout.writeLine("  media type: \(record.mediaType.rawValue)")
        // Both source axes print only when stated — absence means *unstated*, and
        // printing a default here would assert a genre or a derivation the researcher
        // never claimed. (The tier joined this rule in 46b.)
        if let tier = record.sourceAuthorityTier {
            stdout.writeLine("  source tier: \(tier.rawValue)")
        }
        if let derivation = record.sourceDerivation {
            stdout.writeLine("  source derivation: \(derivation.rawValue)")
        }
        if let language = record.language, !language.isEmpty {
            stdout.writeLine("  language: \(language)")
        }
        if let format = record.originalFormat, !format.isEmpty {
            stdout.writeLine("  original format: \(format)")
        }
        if !record.tags.isEmpty {
            stdout.writeLine("  tags: \(record.tags.joined(separator: ", "))")
        }
        if let notes = record.notes, !notes.isEmpty {
            stdout.writeLine("  notes: \(notes)")
        }

        section(stdout, "Events", record.events) { ArtifactFormat.eventLine($0) }
        section(stdout, "Places", record.locations) { ArtifactFormat.locationLine($0) }

        stdout.writeLine("Persons Mentioned:")
        if record.personsMentioned.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            // A mention is addressed by its `localRef`, not an index, so the ref
            // leads instead of `[i]` (`mention remove --ref`, `link --mention`).
            for mention in record.personsMentioned {
                stdout.writeLine("  \(mention.localRef)  " + ArtifactFormat.mentionLine(mention))
                // Its recorded facts are indented under it and *do* carry indices —
                // they're what `mention fact remove --index` addresses, and nesting
                // them is the whole point: this is the record saying which of the
                // people it names each date and place belongs to.
                for (index, fact) in mention.facts.enumerated() {
                    stdout.writeLine(
                        "    [\(index)] " + ArtifactFormat.recordedFactLine(fact))
                }
            }
        }

        // Printed after the mentions and only when the record states some: it reads as
        // a footnote to the list above, and an always-present "(none)" would put an
        // empty section on every record in the archive (§6.1 — silence is the norm).
        // Indices, because that is what `mention relate remove --index` takes.
        if !record.mentionRelationships.isEmpty {
            stdout.writeLine("Relationships Stated:")
            for (index, edge) in record.mentionRelationships.enumerated() {
                stdout.writeLine(
                    "  [\(index)] " + ArtifactFormat.mentionRelationshipRow(edge, in: record))
            }
        }

        stdout.writeLine("Files:")
        if record.files.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for file in record.files {
                stdout.writeLine("  \(file.uid.raw)  " + ArtifactFormat.fileLine(file))
            }
        }

        if let transcript = record.transcript, !transcript.isEmpty {
            stdout.writeLine("Transcript:")
            stdout.writeLine("  \(transcript)")
        }

        if !record.externalIdentifiers.isEmpty {
            stdout.writeLine("External Identifiers:")
            for external in record.externalIdentifiers {
                var line = "  \(external.scheme.rawValue)=\(external.value)"
                if let repository = external.repository, !repository.isEmpty {
                    line += "  (\(repository))"
                }
                stdout.writeLine(line)
            }
        }

        if let retrieval = record.retrieval {
            stdout.writeLine("Retrieval:")
            var line = "  \(retrieval.source)  \(retrieval.date)"
            if let checksum = retrieval.checksum, !checksum.isEmpty {
                line += "  \(checksum)"
            }
            stdout.writeLine(line)
        }
    }

    /// Prints an index-carrying section (`Events`/`Places`) or a `(none)` line.
    private func section<T>(
        _ stdout: CLIOutput, _ heading: String, _ items: [T], line: (T) -> String
    ) {
        stdout.writeLine("\(heading):")
        if items.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for (index, item) in items.enumerated() {
                stdout.writeLine("  [\(index)] \(line(item))")
            }
        }
    }
}

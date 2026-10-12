import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea match …` — entity resolution: which mentions in the archive name which
/// concluded persons (ARCHITECTURE.md §4.6).
///
/// **The matcher suggests and never commits.** `suggest` and `explain` compute and
/// print; nothing is written until `confirm` or `reject` records a *human's* verdict.
/// There is deliberately no batch auto-confirm above a threshold — a score is an
/// argument, not a conclusion, and the whole point of storing a decomposed breakdown
/// is that a person reads it.
///
/// **This is the tuning surface.** Scoring only gets good by being run against real
/// data, and a shell loop over a real archive iterates far faster than clicking a
/// queue — which is why the CLI comes before the app here, inverting the order the
/// rest of Phase 3 used. `suggest` takes `--min-confidence` for the same reason:
/// `Archive.defaultMinimumConfidence` is a calibrated default, not a policy, and
/// finding the right floor for a given archive is work this command exists to make
/// possible. `explain` deliberately takes **no** threshold — a pair you named is a pair
/// you want scored, however badly it does.
///
/// A noun with verbs under it, like `person …` / `mention …`, rather than five flat
/// verbs: `confirm` and `reject` mean nothing without saying what they are about.
struct MatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "match",
        abstract: "Suggest, explain, and rule on evidence→person links.",
        subcommands: [
            MatchSuggestCommand.self,
            MatchExplainCommand.self,
            MatchConfirmCommand.self,
            MatchRejectCommand.self,
            MatchUnrejectCommand.self,
        ]
    )
}

// MARK: - The pair

/// The `--artifact` / `--mention` / `--person` triple that names one pair, shared by
/// `explain`, `confirm`, `reject` and `unreject`.
///
/// It is a triple rather than a link uid because these commands address a pair that
/// may have no record yet — that is the ordinary case for `confirm` and `reject`, and
/// the addressing has to be the same for the verb that removes the record as for the
/// ones that write it. It is also exactly columns 1–3 of `match suggest`, so a
/// suggestion pipes into a decision unchanged.
struct MatchPair: ParsableArguments {
    @Option(name: .long, help: "The artifact containing the mention (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The mention's record-local ref, e.g. p1 (`genea mention list`).")
    var mention: String

    @Option(name: .long, help: "The concluded person (PER-…).")
    var person: String

    var mentionRef: MentionRef {
        MentionRef(artifact: ArtifactID(artifact), localRef: mention)
    }

    var personID: PersonID { PersonID(person) }
}

// MARK: - match suggest

/// `genea match suggest <archive> (--person <PER-uid> | --artifact <ART-uid>)
/// [--min-confidence <n>] [--limit <n>]` → `suggestLinks(for:)` /
/// `suggestLinks(forArtifact:)`.
///
/// **Both directions, because resolution is asked from both ends.** From a person:
/// "what else in the archive is about her?" From an artifact: "who on this newly
/// catalogued record is already in the tree?" The engine returns different shapes for
/// the two — a flat ranked list, and one group per unresolved mention — and this
/// prints them as the same six columns so a script never has to branch on which
/// question it asked.
///
/// The artifact direction additionally prints a row for **an unresolved mention
/// nothing matched** (see `MatchFormat.noCandidateLine`), which is the one thing a
/// list of scored pairs cannot express and the case with actual work attached.
struct MatchSuggestCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "suggest",
        abstract: "Suggest links for a person or for an artifact's mentions."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var target: MatchTarget

    @Option(
        name: .customLong("min-confidence"),
        help: "Drop candidates scoring below this (0–100).")
    var minimumConfidence: Int = Archive.defaultMinimumConfidence

    /// Per *mention* in the artifact direction, and over the whole result in the
    /// person direction — the engine's own two meanings, which follow from the shapes:
    /// grouping makes a global cap meaningless (it would silently starve later
    /// mentions of candidates).
    @Option(
        name: .long,
        help: "At most this many suggestions — per mention for --artifact, in total for --person.")
    var limit: Int?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        // **A non-positive limit is refused rather than obeyed.** The engine clamps it
        // to "no results" — a sane answer for a query, and a corrupting one here: an
        // empty candidate list is how this command reports *a mention the archive has
        // nobody for*, so `--limit 0` would print that row for a mention with a
        // 100-scoring candidate. The output would assert "this may be somebody new"
        // because of a flag, which is exactly the false signal 45c's grouping and 45e's
        // create-new guard exist to prevent. A caller asking for at most zero
        // suggestions has made a mistake, and saying so beats answering it.
        if let limit, limit < 1 {
            throw CLIUserError(
                "--limit must be at least 1 (got \(limit)). Omit it for every suggestion.")
        }

        switch try target.resolved() {
        case .person(let id):
            // A typo'd uid must not read as "nothing matched". The engine returns an
            // empty result for a person that doesn't exist — the right answer for a
            // non-throwing query, the wrong one to print at a user who is tuning a
            // threshold and would take it as a signal about the threshold.
            guard opened.person(withID: id) != nil else {
                throw ArchiveError.personNotFound(id)
            }
            let suggestions = opened.suggestLinks(
                for: id, minimumConfidence: minimumConfidence, limit: limit)
            for suggestion in suggestions {
                stdout.writeLine(
                    MatchFormat.suggestionLine(
                        suggestion, in: opened,
                        recordedName: recordedName(of: suggestion.mention, in: opened)))
            }

        case .artifact(let id):
            guard let record = opened.artifact(withID: id) else {
                throw ArchiveError.artifactNotFound(id)
            }
            let grouped = opened.suggestLinks(
                forArtifact: id, minimumConfidence: minimumConfidence, limit: limit)
            // Read once for the whole record, not per mention — this is the "record on
            // disk" reading of `links(forArtifact:)`, needed only to explain an empty
            // candidate list (see `MatchFormat.noCandidateLine`).
            let rejections = opened.links(forArtifact: id, includeRejected: true)
                .filter(\.isRejection)
            for group in grouped {
                let recorded = record.personsMentioned
                    .first { $0.localRef == group.mention.localRef }?
                    .nameAsRecorded
                guard !group.candidates.isEmpty else {
                    stdout.writeLine(
                        MatchFormat.noCandidateLine(
                            group.mention, recordedName: recorded,
                            minimumConfidence: minimumConfidence,
                            rejectedCount: rejections.count {
                                $0.personMentionRef == group.mention.localRef
                            }))
                    continue
                }
                for candidate in group.candidates {
                    stdout.writeLine(
                        MatchFormat.suggestionLine(
                            candidate, in: opened, recordedName: recorded))
                }
            }
        }
    }

    /// The name as this document records it — looked up per suggestion in the person
    /// direction, where every row can be on a different artifact.
    private func recordedName(of mention: MentionRef, in archive: Archive) -> String? {
        archive.artifact(withID: mention.artifact)?
            .personsMentioned
            .first { $0.localRef == mention.localRef }?
            .nameAsRecorded
    }
}

/// The `--person` / `--artifact` direction for `match suggest`, with the "exactly
/// one" rule in one place — the `FactTarget` shape.
struct MatchTarget: ParsableArguments {
    @Option(name: .long, help: "Find mentions that may name this person (PER-…).")
    var person: String?

    @Option(name: .long, help: "Find persons this artifact's mentions may name (ART-…).")
    var artifact: String?

    func resolved() throws -> Resolved {
        switch (person, artifact) {
        case (let person?, nil): return .person(PersonID(person))
        case (nil, let artifact?): return .artifact(ArtifactID(artifact))
        case (nil, nil):
            throw CLIUserError("Specify --person or --artifact.")
        case (.some, .some):
            throw CLIUserError("Specify --person or --artifact, not both.")
        }
    }

    enum Resolved {
        case person(PersonID)
        case artifact(ArtifactID)
    }
}

// MARK: - match explain

/// `genea match explain <archive> --artifact <uid> --mention <ref> --person <uid>`
/// → `matchScore(of:against:)`.
///
/// **The decomposed breakdown for one pair — the text form of what the app will
/// draw.** `suggest` answers "what should I look at?", and therefore hides pairs that
/// are resolved, rejected or weak; this answers "why did *these two* score the way
/// they did?", which is worth asking about exactly those hidden pairs. It applies no
/// threshold and no skip rules, so a rejected pair can be re-examined and a confirmed
/// one audited against what the matcher would say today — which is why it also prints
/// any verdict already on disk, with the confidence **stored at the time** beside the
/// one computed just now.
struct MatchExplainCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Print the decomposed breakdown for one mention↔person pair."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var pair: MatchPair

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let ref = pair.mentionRef
        let personID = pair.personID

        // `matchScore` returns `nil` for all three failures at once. Checking them
        // here costs three index reads and turns "no score" into which record is
        // missing — the difference between a usable error and a shrug.
        guard let artifact = opened.artifact(withID: ref.artifact) else {
            throw ArchiveError.artifactNotFound(ref.artifact)
        }
        guard
            let personMention = artifact.personsMentioned
                .first(where: { $0.localRef == ref.localRef })
        else {
            throw ArchiveError.mentionNotFound(ref.localRef, on: ref.artifact)
        }
        guard let person = opened.person(withID: personID) else {
            throw ArchiveError.personNotFound(personID)
        }
        guard let scored = opened.matchScore(of: ref, against: personID) else {
            throw CLIUserError(
                "The matcher could not score \(ref.localRef) against \(personID.raw).")
        }

        stdout.writeLine(
            "\(ref.artifact.raw)  \(ref.localRef)  \"\(personMention.nameAsRecorded)\"  "
                + artifact.title)
        stdout.writeLine(
            "\(personID.raw)  \(ConclusionsFormat.displayNameOrPlaceholder(person))")
        stdout.writeLine("Confidence: \(scored.aggregateConfidence)")

        let breakdown = scored.breakdown
        stdout.writeLine("Dimensions:")
        stdout.writeLine(
            MatchFormat.dimensionLine(
                "name", breakdown.name, algorithm: breakdown.nameAlgo))
        stdout.writeLine(
            MatchFormat.dimensionLine("birthYear", breakdown.birthYear, deltaUnit: "years apart"))
        stdout.writeLine(MatchFormat.dimensionLine("birthPlace", breakdown.birthPlace))
        stdout.writeLine(
            MatchFormat.dimensionLine("spouseName", breakdown.spouseName, relational: true))
        stdout.writeLine(
            MatchFormat.dimensionLine("parents", breakdown.parents, relational: true))

        stdout.writeLine("Weights:")
        stdout.writeLine("  source authority     \(scored.sourceAuthorityWeight)")
        stdout.writeLine("  information quality  \(scored.informationQualityWeight)")

        // Conflicts are written as sentences by the matcher precisely so they can be
        // printed at a reviewer unchanged (§4.6) — they are not codes to decorate.
        stdout.writeLine("Conflicts:")
        if breakdown.conflicts.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for conflict in breakdown.conflicts { stdout.writeLine("  \(conflict)") }
        }

        stdout.writeLine("Recorded verdict:")
        let verdicts = opened.verdicts(on: ref, as: personID)
        if verdicts.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for verdict in verdicts { stdout.writeLine("  " + MatchFormat.verdictLine(verdict)) }
        }
    }
}

// MARK: - match confirm / reject

/// `genea match confirm <archive> --artifact <uid> --mention <ref> --person <uid>
/// [--reviewed-by <name>]` → `confirm(_:as:)`, printing the minted `LNK-` uid.
///
/// **Not the same command as `genea link`, and the difference is what gets stored.**
/// `link` is for a mention a human resolved unaided, and it writes the honest minimum
/// a breakdown can express. This records that a human agreed with *the matcher*, so
/// it stores the matcher's real dimension scores — not rounded up to 100 because
/// someone said yes. A confirmation is a verdict on the pair, not a re-scoring of the
/// evidence: a link confirmed on a birth year three years off should still say so a
/// decade later.
///
/// The score is recomputed here rather than passed in, which is what a caller holding
/// only the pair wants. It can differ from what `suggest` printed if the archive
/// changed in between — recomputing at the moment of the write is the honest reading
/// of "what the matcher says about this pair now".
struct MatchConfirmCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm",
        abstract: "Record that a mention does name this person, with the matcher's reasoning."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var pair: MatchPair

    @Option(name: .customLong("reviewed-by"), help: "Name of the human confirming this.")
    var reviewedBy: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let decision = try opened.confirm(
            pair.mentionRef, as: pair.personID, reviewedBy: Reviewer.parsing(reviewedBy))
        stdout.writeLine(decision.link.uid.raw)
        CLIReview.reportDisplacement(decision, to: stdout)
    }
}

/// `genea match reject <archive> --artifact <uid> --mention <ref> --person <uid>
/// [--reviewed-by <name>]` → `reject(_:as:)`, printing the minted `LNK-` uid.
///
/// **A rejection is a record, because the alternative is a matcher with no memory.**
/// Suggestions are ephemeral, so declining one in a queue survives nothing; the next
/// run would recompute the identical score and offer the identical pair forever. The
/// tombstone is what makes "no" stick — and it stores the breakdown for the same
/// reason a confirmation does: a rejection *of a strong match* is where the matcher is
/// wrong in a way worth understanding.
///
/// **Scoped to the pair, not the mention.** Rejecting this Szlama forecloses that one
/// candidate; every other stays open and the mention stays unresolved. Reversible with
/// `match unreject`.
struct MatchRejectCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "reject",
        abstract: "Record that a mention does not name this person (a rejection tombstone)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var pair: MatchPair

    @Option(name: .customLong("reviewed-by"), help: "Name of the human rejecting this.")
    var reviewedBy: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let decision = try opened.reject(
            pair.mentionRef, as: pair.personID, reviewedBy: Reviewer.parsing(reviewedBy))
        stdout.writeLine(decision.link.uid.raw)
        CLIReview.reportDisplacement(decision, to: stdout)
    }
}

// MARK: - match unreject

/// `genea match unreject <archive> --artifact <uid> --mention <ref> --person <uid>`
/// → `unlink`, on whatever tombstone the pair holds.
///
/// **A fourth verb in the CLI, but not in the engine.** A tombstone *is* an
/// `EvidenceLink`, so un-rejecting is deleting it and `unlink` already does that —
/// except `unlink` is addressed by uid, and nobody holds the uid of a record they only
/// know as "the pair I said no to". This resolves the pair to that record and removes
/// it, which is the whole of the command.
///
/// **It removes every tombstone on the pair, not the first one.** One verdict per pair
/// is enforced on the write paths, so today there is at most one — but the promise
/// this command makes is that the pair comes back to the queue, and leaving a second
/// tombstone behind would break that promise silently, with the user's only evidence
/// being a suggestion that never reappears. An archive written by another tool, or by
/// a version of this one predating the rule, is exactly where that would bite.
///
/// A **confirmation** is refused rather than removed. The two are the same record type
/// and deleting the wrong one is unrecoverable in a CLI with no undo, so this will not
/// quietly un-resolve a mention on a command that says "unreject"; `genea unlink` is
/// there for that, and the error names it.
struct MatchUnrejectCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "unreject",
        abstract: "Remove a rejection, returning the pair to the suggestion queue."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var pair: MatchPair

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let ref = pair.mentionRef
        let personID = pair.personID
        let verdicts = opened.verdicts(on: ref, as: personID)
        let rejections = verdicts.filter(\.isRejection)

        guard !rejections.isEmpty else {
            let confirmed = verdicts.first.map {
                " This pair is \($0.reviewStatus.rawValue) (\($0.uid.raw)); "
                    + "remove it with `genea unlink` if that is what you meant."
            }
            throw CLIUserError(
                "No rejection recorded for \(ref.localRef) on \(ref.artifact.raw) "
                    + "as \(personID.raw)." + (confirmed ?? ""))
        }

        for rejection in rejections {
            let removed = try opened.unlink(rejection.uid)
            stdout.writeLine(
                "Removed \(removed.uid.raw)\t\(removed.artifactUid.raw)\t"
                    + "\(removed.personMentionRef)\t\(removed.personUid.raw)")
        }
    }
}

// MARK: - Shared lookups

extension Archive {
    /// Every link already on disk for one pair — **rejections included**, which is the
    /// point: this backs `explain`'s audit line and `unreject`'s target lookup, and
    /// both of them exist to act on tombstones. This is the "record on disk" reading of
    /// `links(forArtifact:)`, not the "citation" one, so it opts in deliberately.
    fileprivate func verdicts(on mention: MentionRef, as personID: PersonID) -> [EvidenceLink] {
        links(forArtifact: mention.artifact, includeRejected: true)
            .filter { $0.personMentionRef == mention.localRef && $0.personUid == personID }
    }
}

extension Reviewer {
    /// `--reviewed-by`'s two states: a name, or no identity at all. Omitting the flag
    /// leaves `reviewedBy` `nil` rather than inventing an identity — the rule `genea
    /// link` established, shared here so the three review verbs cannot drift.
    fileprivate static func parsing(_ name: String?) -> Reviewer {
        name.map { Reviewer.human($0) } ?? .unspecified
    }
}

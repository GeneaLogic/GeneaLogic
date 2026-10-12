import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea person …` — the concluded-person surface (ARCHITECTURE.md §4.3).
///
/// Grouped under a noun rather than added as more flat verbs (`add`/`list` are
/// already taken by artifacts): the Phase-1 commands are artifact-scoped by
/// convention, and Phase 3 adds three more record kinds, so `person add` /
/// `person list` disambiguates where a flat `add` could not.
struct PersonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "person",
        abstract: "Create, list, inspect, edit and remove concluded persons.",
        subcommands: [
            PersonAddCommand.self,
            PersonListCommand.self,
            PersonShowCommand.self,
            PersonNameCommand.self,
            PersonDuplicatesCommand.self,
            PersonDismissCommand.self,
            PersonUndismissCommand.self,
            PersonDismissalsCommand.self,
            PersonMergeCommand.self,
            PersonRemoveCommand.self,
        ]
    )
}

// MARK: - person duplicates

/// `genea person duplicates <archive> [--min-confidence <n>] [--limit <n>] [--explain]`
/// → `duplicateCandidates(minimumConfidence:limit:)`.
///
/// **The finding half of `person merge`** (slice 45j). Merge has been usable by hand
/// since 45f; what was missing is knowing *which* two records to point it at, which
/// until now meant reading the People list. This prints each unordered pair once, ranked,
/// with the decomposed reasoning behind `--explain`.
///
/// **It suggests and never commits**, like `match suggest` — and here that separation is
/// load-bearing rather than stylistic: the action on the other side is the most
/// destructive operation the engine has. There is deliberately no `--merge-above`.
///
/// **A pair the user has declined is not listed** — `person dismiss` records the *no*
/// (slice 45m, §6.6), and every sweep over this direction subtracts it. Until that record
/// existed this direction shipped to the CLI alone, precisely because an on-demand report
/// needs no memory: you run it, you read it, nothing re-offers anything at you tomorrow.
struct PersonDuplicatesCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicates",
        abstract: "Find pairs of concluded persons that may be one person."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(
        name: .customLong("min-confidence"),
        help: "Drop pairs scoring below this (0–100).")
    var minimumConfidence: Int = Archive.defaultMinimumDuplicateConfidence

    @Option(name: .long, help: "At most this many pairs, highest-scoring first.")
    var limit: Int?

    @Flag(
        name: .long,
        help: "Print the decomposed breakdown for each pair instead of one row each.")
    var explain: Bool = false

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        // Refused rather than clamped, as `match suggest` refuses it: the engine reads a
        // non-positive limit as "no results", and an empty result from *this* command
        // reads as "no duplicates in this archive" — a reassuring answer to print because
        // of a flag.
        if let limit, limit < 1 {
            throw CLIUserError(
                "--limit must be at least 1 (got \(limit)). Omit it for every pair.")
        }

        let candidates = opened.duplicateCandidates(
            minimumConfidence: minimumConfidence, limit: limit)

        guard explain else {
            for candidate in candidates {
                stdout.writeLine(MatchFormat.duplicateLine(candidate, in: opened))
            }
            return
        }

        for (offset, candidate) in candidates.enumerated() {
            if offset > 0 { stdout.writeLine("") }
            write(candidate, in: opened, to: stdout)
        }
    }

    /// The decomposed register for one pair — `match explain`'s layout, minus the two
    /// GPS weights.
    ///
    /// **Their absence is the honest output, not an omission**: those weights measure a
    /// *source*, and neither side of this comparison is one. Printing `0` or `100` for
    /// them would be inventing a figure; printing "(not applicable)" would imply the
    /// score has a slot for something it structurally cannot have.
    private func write(_ candidate: DuplicateCandidate, in archive: Archive, to stdout: CLIOutput) {
        for id in [candidate.person1, candidate.person2] {
            let name = archive.person(withID: id).map(ConclusionsFormat.displayNameOrPlaceholder)
            stdout.writeLine("\(id.raw)  \(name ?? "(missing)")")
        }
        stdout.writeLine("Confidence: \(candidate.match.aggregateConfidence)")

        let breakdown = candidate.match.breakdown
        stdout.writeLine("Dimensions:")
        stdout.writeLine(
            MatchFormat.dimensionLine("name", breakdown.name, algorithm: breakdown.nameAlgo))
        stdout.writeLine(
            MatchFormat.dimensionLine("birthYear", breakdown.birthYear, deltaUnit: "years apart"))
        stdout.writeLine(MatchFormat.dimensionLine("birthPlace", breakdown.birthPlace))
        stdout.writeLine(
            MatchFormat.dimensionLine("spouseName", breakdown.spouseName, relational: true))
        stdout.writeLine(
            MatchFormat.dimensionLine("parents", breakdown.parents, relational: true))

        // Written as sentences by the matcher precisely so they reach a reader unchanged
        // (§4.6). On this surface they are the most important lines on the page: a
        // conflict is usually how two people who share a name are told apart.
        stdout.writeLine("Conflicts:")
        if breakdown.conflicts.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for conflict in breakdown.conflicts { stdout.writeLine("  \(conflict)") }
        }
    }
}

// MARK: - person dismiss / undismiss / dismissals

/// `genea person dismiss <archive> <a> <b> [--subject <s>]` → `dismiss` (slice 45m).
///
/// **The verb `person duplicates` was missing.** Merging is what you do when two records
/// *are* one person; this is what you do when they aren't, and without it the pair is
/// re-offered by every later sweep — harmless in an on-demand report, corrosive in the
/// app's review queue, which is the surface this record was written for.
///
/// Scored from the current archive when the pair is one the matcher would offer, so the
/// record keeps the reasoning that was declined (45c: declining a *strong* candidate is
/// the interesting record). A pair below the floor is dismissable too, and simply stores
/// no breakdown — nothing has to be invented to record a human's judgement.
struct PersonDismissCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "dismiss",
        abstract: "Record that a suggestion about two persons was declined."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The first person's uid (e.g. PER-…).")
    var person: String

    @Argument(help: "The second person's uid.")
    var other: String

    @Option(
        name: .long,
        help: """
            What is being declined: same-person, parent-child, couple. For parent-child, \
            the first uid is the proposed parent.
            """)
    var subject: String = DismissalSubject.samePerson.rawValue

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let declined = try Self.declinedSubject(subject)
        let first = PersonID(person)
        let second = PersonID(other)

        // Only the duplicate lane has a score to preserve; the relationship subjects are
        // 45l's and carry none. Looked up rather than recomputed so the stored breakdown
        // is the one this command could have printed a moment earlier.
        let candidate =
            declined == .samePerson
            ? opened.duplicateCandidates().first(where: {
                Set([$0.person1, $0.person2]) == Set([first, second])
            })
            : nil

        let dismissal = try opened.dismiss(
            declined, between: first, and: second,
            match: candidate?.match.breakdown,
            aggregateConfidence: candidate?.match.aggregateConfidence)

        stdout.writeLine(
            "\(dismissal.uid.raw)\t\(dismissal.subject.rawValue)\t"
                + "\(dismissal.person1Uid.raw)\t\(dismissal.person2Uid.raw)")
    }

    /// Parses `--subject`, **rejecting** anything this build doesn't know.
    ///
    /// The vocabulary is open, and the *format* must keep accepting values a later version
    /// wrote — but that is a rule about **reading**. Minting one here is different: a
    /// subject nothing in this build produces is a subject nothing in it consumes, so a
    /// typo would write a record that suppresses nothing, exit 0, and look like it worked.
    /// Worse, `undismiss` with the same typo would silently match nothing while the real
    /// dismissal survived. Open on the way in, closed on the way out.
    static func declinedSubject(_ raw: String) throws -> DismissalSubject {
        let parsed = DismissalSubject.parsingLeniently(raw)
        guard DismissalSubject.knownCases.contains(parsed) else {
            let known = DismissalSubject.knownCases.map(\.rawValue).joined(separator: ", ")
            throw CLIUserError(
                "Unknown --subject \"\(raw)\". Expected one of: \(known).")
        }
        return parsed
    }
}

/// `genea person undismiss <archive> <a> <b> [--subject <s>]` → `undismiss`.
///
/// **Deletion is the retraction** — there is no third verb (45c's rule, applied to this
/// record). Retracting something never declined prints nothing and exits cleanly: it is
/// the state the caller asked for.
struct PersonUndismissCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "undismiss",
        abstract: "Retract a dismissal, returning the pair to the suggestion queue."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The first person's uid (e.g. PER-…).")
    var person: String

    @Argument(help: "The second person's uid.")
    var other: String

    @Option(
        name: .long,
        help: "Which claim to un-decline: same-person, parent-child, couple.")
    var subject: String = DismissalSubject.samePerson.rawValue

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let removed = try opened.undismiss(
            try PersonDismissCommand.declinedSubject(subject),
            between: PersonID(person), and: PersonID(other))
        for dismissal in removed {
            stdout.writeLine("Removed \(dismissal.uid.raw)\t\(dismissal.subject.rawValue)")
        }
    }
}

/// `genea person dismissals <archive> [--person <uid>]` → `dismissals()`.
///
/// The one surface that makes a *no* visible. Without it a dismissal is invisible by
/// design — it works by making something not appear — and a pair suppressed by a decision
/// the user has forgotten would be unexplainable.
struct PersonDismissalsCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "dismissals",
        abstract: "List the suggestions that have been declined."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "Only dismissals naming this person.")
    var person: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let records =
            person.map { opened.dismissals(involving: PersonID($0)) } ?? opened.dismissals()
        for dismissal in records {
            let confidence = dismissal.aggregateConfidence.map { "\($0)" } ?? ""
            stdout.writeLine(
                "\(dismissal.uid.raw)\t\(dismissal.subject.rawValue)\t"
                    + "\(dismissal.person1Uid.raw)\t\(dismissal.person2Uid.raw)\t\(confidence)")
        }
    }
}

// MARK: - person add

/// `genea person add <archive> [--given <g>] [--surname <s>] [--full <f>]
/// [--name-type <t>]` → `addPerson`, printing the minted `PER-` uid.
///
/// Builds the person's single initial name explicitly rather than going through
/// `PersonDraft(given:surname:)`'s convenience path, so `--full` and
/// `--name-type` are expressible; for the plain given/surname case the result is
/// identical to what `PersonDraft.resolvedNames()` would synthesize (a `.birth`
/// name whose `full` is the two joined).
struct PersonAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a concluded person and print its minted uid."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "Given name(s).")
    var given: String?

    @Option(name: .long, help: "Surname(s).")
    var surname: String?

    @Option(name: .long, help: "Full name, if it isn't just given + surname.")
    var full: String?

    @Option(
        name: .customLong("name-type"),
        help: "Name type: birth, married, also-known-as, nickname.")
    var nameType: String = NameType.birth.rawValue

    /// A person's names come from different records and are routinely in different
    /// languages and scripts, so the tags belong on the name, not the person.
    @Option(name: .long, help: "BCP 47 language of this name (e.g. ru, pl, yi).")
    var language: String?

    @Option(name: .long, help: "ISO 15924 script of this name (e.g. Cyrl, Latn, Hebr).")
    var script: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        guard given != nil || surname != nil || full != nil else {
            throw CLIUserError("Specify at least one of --given, --surname or --full.")
        }
        let name = PersonName.deriving(
            type: .parsing(nameType), given: given, surname: surname, full: full,
            language: language, script: script)
        let person = try opened.addPerson(PersonDraft(names: [name]))
        stdout.writeLine(person.uid.raw)
    }
}

// MARK: - person list

/// `genea person list <archive> [--match <query>]` → `persons()` /
/// `persons(matching:)`.
///
/// Same pipe-friendly discipline as `list`/`find`: one person per line, strictly
/// `<uid>\t<display name>`. A person with no usable name prints an **empty**
/// second column rather than a `(unnamed)` placeholder — a placeholder would be
/// indistinguishable from a real name in `cut -f2`, and an empty field is the
/// honest "no name recorded" (`person show` is where placeholders belong).
struct PersonListCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List concluded persons as <uid>\\t<display name>, one per line."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "Only list persons matching this free-text query (names, places).")
    var match: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let summaries =
            match.map { opened.persons(matching: PersonQuery(text: $0)) } ?? opened.persons()
        for summary in summaries {
            stdout.writeLine("\(summary.uid.raw)\t\(summary.displayName ?? "")")
        }
    }
}

// MARK: - person show

/// `genea person show <archive> <uid>` — the human-readable register: names,
/// facts, relationships (phrased from this person's point of view) and the
/// artifacts citing them, each row carrying the uid or index the mutating
/// commands take.
///
/// This is the one place the whole conclusions graph around a person is visible
/// at once, so it's also how a script discovers the ids `fact`/`unrelate`/
/// `unlink` need.
struct PersonShowCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show a person's names, facts, relationships and sources."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The person's uid (e.g. PER-…).")
    var person: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = PersonID(person)
        guard let record = opened.person(withID: id) else {
            throw ArchiveError.personNotFound(id)
        }

        stdout.writeLine("\(record.uid.raw)\t\(ConclusionsFormat.displayNameOrPlaceholder(record))")

        stdout.writeLine("Names:")
        if record.names.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for (index, name) in record.names.enumerated() {
                stdout.writeLine("  [\(index)] \(ConclusionsFormat.nameLine(name))")
            }
        }

        stdout.writeLine("Facts:")
        if record.facts.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for (index, fact) in record.facts.enumerated() {
                stdout.writeLine("  [\(index)] \(ConclusionsFormat.factLine(fact))")
            }
        }

        let relationships = opened.relationships(of: id)
        stdout.writeLine("Relationships:")
        if relationships.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for relationship in relationships {
                let other = ConclusionsFormat.otherEndpoint(of: relationship, from: id)
                let role = ConclusionsFormat.role(of: relationship, from: id)
                stdout.writeLine(
                    "  \(relationship.uid.raw)  \(role)  "
                        + ConclusionsFormat.personLabel(other, in: opened))
                // A relationship's own facts (a couple's marriage/divorce, a
                // parent-child link's nature) are indented under it — they're
                // addressed as `fact remove --relationship <uid> --index <n>`.
                for (index, fact) in relationship.facts.enumerated() {
                    stdout.writeLine("      [\(index)] \(ConclusionsFormat.factLine(fact))")
                }
            }
        }

        let links = opened.links(for: id)
        stdout.writeLine("Sources:")
        if links.isEmpty {
            stdout.writeLine("  (none)")
        } else {
            for link in links {
                let artifact = opened.artifact(withID: link.artifactUid)
                let title = artifact?.title ?? "(deleted artifact)"
                let recorded =
                    artifact?.personsMentioned
                    .first { $0.localRef == link.personMentionRef }?
                    .nameAsRecorded
                let asRecorded = recorded.map { "  as recorded: \"\($0)\"" } ?? ""
                stdout.writeLine(
                    "  \(link.uid.raw)  \(link.artifactUid.raw)  \(title)\(asRecorded)")
            }
        }
    }
}

// MARK: - person name

/// `genea person name …` — the person's `names` array.
///
/// **A person has *several* names, so this is an array command, not a setter.**
/// The first cut here was a single `person set` that edited a name in place,
/// which quietly made a married or alias name unrecordable — a person can only
/// ever have the one name they were created with. `add`/`set`/`remove` mirrors the
/// `fact` family (and the app's Names section) and makes the whole array
/// reachable. Names stay under `person` rather than going top-level like `fact`
/// because, unlike a fact, a name belongs to exactly one kind of record.
struct PersonNameCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "name",
        abstract: "Add, edit, or remove one of a person's names.",
        subcommands: [
            PersonNameAddCommand.self,
            PersonNameSetCommand.self,
            PersonNameRemoveCommand.self,
        ]
    )
}

/// `genea person name add <archive> <uid> [--given <g>] [--surname <s>]
/// [--full <f>] [--name-type <t>] [--language <l>] [--script <s>]` → `updatePerson`, appending a name.
///
/// This is how a married name, alias or nickname gets recorded alongside the
/// birth name a person was created with.
struct PersonNameAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add another name to a person (married, alias, nickname…)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The person's uid (e.g. PER-…).")
    var person: String

    @Option(name: .long, help: "Given name(s).")
    var given: String?

    @Option(name: .long, help: "Surname(s).")
    var surname: String?

    @Option(name: .long, help: "Full name, if it isn't just given + surname.")
    var full: String?

    @Option(
        name: .customLong("name-type"),
        help: "Name type: birth, married, also-known-as, nickname.")
    var nameType: String = NameType.married.rawValue

    /// A person's names come from different records and are routinely in different
    /// languages and scripts, so the tags belong on the name, not the person.
    @Option(name: .long, help: "BCP 47 language of this name (e.g. ru, pl, yi).")
    var language: String?

    @Option(name: .long, help: "ISO 15924 script of this name (e.g. Cyrl, Latn, Hebr).")
    var script: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        guard given != nil || surname != nil || full != nil else {
            throw CLIUserError("Specify at least one of --given, --surname or --full.")
        }
        let name = PersonName.deriving(
            type: .parsing(nameType), given: given, surname: surname, full: full,
            language: language, script: script)
        let updated = try opened.updatePerson(PersonID(person)) { $0.names.append(name) }
        // Data columns, not prose — the minted index is the addressable thing
        // (`person name remove --index`), so it leads, exactly as `attach` leads with
        // the file uid it minted.
        stdout.writeLine("\(updated.names.count - 1)\t" + ConclusionsFormat.nameLine(name))
    }
}

/// `genea person name set <archive> <uid> [--index <n>] [--given <g>]
/// [--surname <s>] [--full <f>] [--name-type <t>] [--language <l>] [--script <s>]` → `updatePerson`.
///
/// Only the flags actually passed change — the same "apply what was passed" rule
/// `set-meta` documents — so `--surname` alone renames without disturbing the
/// given name or the type. `--index` defaults to `0` (the display name); a
/// person with no names at all gets one, so this doubles as "give this person a
/// name". Editing past the end is an error rather than a silent append, since a
/// stale index usually means the caller is addressing a name that has since been
/// removed (that's what `add` is for).
struct PersonNameSetCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Edit one of a person's existing names."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The person's uid (e.g. PER-…).")
    var person: String

    @Option(name: .long, help: "Which name to edit (see `person show`). Defaults to the first.")
    var index: Int = 0

    @Option(name: .long, help: "New given name(s).")
    var given: String?

    @Option(name: .long, help: "New surname(s).")
    var surname: String?

    @Option(name: .long, help: "New full name.")
    var full: String?

    @Option(
        name: .customLong("name-type"),
        help: "New name type: birth, married, also-known-as, nickname.")
    var nameType: String?

    @Option(name: .long, help: "New BCP 47 language for this name (e.g. ru, pl, yi).")
    var language: String?

    @Option(name: .long, help: "New ISO 15924 script for this name (e.g. Cyrl, Latn, Hebr).")
    var script: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        guard
            given != nil || surname != nil || full != nil || nameType != nil || language != nil
                || script != nil
        else {
            throw CLIUserError(
                "Specify at least one of --given, --surname, --full, --name-type, --language "
                    + "or --script.")
        }

        // The bounds check lives *inside* the mutate closure, against the record
        // the engine actually loaded — the app's established pattern for
        // index-addressed edits (a caller's index can go stale before the write).
        // `updatePerson`'s closure can't throw, so an out-of-range index leaves
        // the record untouched and surfaces after the call; the cost is one
        // no-op rewrite of an unchanged sidecar on that error path.
        var indexError: CLIUserError?
        let selected = index
        let updated = try opened.updatePerson(PersonID(person)) { record in
            if record.names.isEmpty && selected == 0 {
                record.names.append(PersonName(type: .birth))
            }
            guard record.names.indices.contains(selected) else {
                indexError = .outOfRange("name", index: selected, count: record.names.count)
                return
            }
            let before = record.names[selected]
            if let nameType { record.names[selected].type = .parsing(nameType) }
            if let given { record.names[selected].given = given }
            if let surname { record.names[selected].surname = surname }
            if let language { record.names[selected].language = language }
            if let script { record.names[selected].script = script }
            if let full {
                record.names[selected].full = full
            } else if before.hasDerivedFull {
                // Every consumer prefers `full` (`resolvedText`, the engine's
                // `PersonSummary.displayName`, the app, the tree), so editing only
                // the parts and leaving a stale `full` makes the rename invisible
                // *everywhere* and the record self-contradicting. Re-derive it —
                // but only when `full` was ours to begin with (`hasDerivedFull`):
                // a `full` the author typed ("Anna Maria von Meyer") carries
                // information the parts don't, and must survive a `--surname` fix.
                record.names[selected].full =
                    PersonName.deriving(
                        type: record.names[selected].type,
                        given: record.names[selected].given,
                        surname: record.names[selected].surname
                    ).full
            }
        }
        if let indexError { throw indexError }

        stdout.writeLine(
            "Updated \(updated.uid.raw)\t\(ConclusionsFormat.displayNameOrPlaceholder(updated))")
    }
}

/// `genea person name remove <archive> <uid> --index <n>` → `updatePerson`.
///
/// A person is allowed to end up with no names at all (the format permits it and
/// `person list` renders it as an empty name column), so this doesn't refuse to
/// remove the last one.
struct PersonNameRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove one of a person's names by index."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The person's uid (e.g. PER-…).")
    var person: String

    @Option(name: .long, help: "Which name to remove, as shown by `genea person show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        var removed: PersonName?
        var outOfRange: Int?
        let selected = index

        try opened.updatePerson(PersonID(person)) { record in
            guard record.names.indices.contains(selected) else {
                outOfRange = record.names.count
                return
            }
            removed = record.names.remove(at: selected)
        }

        if let count = outOfRange {
            throw CLIUserError.outOfRange("name", index: selected, count: count)
        }
        stdout.writeLine(
            "Removed name [\(selected)] from \(person)\t"
                + (removed.map(ConclusionsFormat.nameLine) ?? ""))
    }
}

// MARK: - person merge

/// `genea person merge <archive> <absorbed> --into <survivor>` → `mergePersons`.
///
/// **The one command that cascades**, and the reason it reads the way it does. Every
/// other removal here leaves dangles and says so; this one repoints instead, which means
/// it silently rewrites records the caller never named. So it prints all of them: what
/// moved, what was dropped, and what a drop stranded. A cascade nobody can see is the
/// failure mode.
///
/// **`--into` is a flag, not a second positional**, because the two arguments are not
/// interchangeable and there is no undo here: `merge PER-a PER-b` reads equally well as
/// either direction, and getting it backwards deletes the wrong record. Naming the
/// survivor at the call site makes the direction unmistakable in a shell history too.
struct PersonMergeCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge one concluded person into another (records are repointed, not orphaned)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The duplicate person's uid — this record is absorbed and removed.")
    var person: String

    @Option(name: .customLong("into"), help: "The surviving person's uid — this record is kept.")
    var into: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let decision = try opened.mergePersons(PersonID(person), into: PersonID(into))

        stdout.writeLine(
            "Merged \(decision.absorbed.uid.raw) into \(decision.survivor.uid.raw)\t"
                + ConclusionsFormat.displayNameOrPlaceholder(decision.survivor))

        let gainedNames = decision.survivor.names.count - decision.survivorBefore.names.count
        let gainedFacts = decision.survivor.facts.count - decision.survivorBefore.facts.count
        if gainedNames > 0 || gainedFacts > 0 {
            stdout.writeLine(
                "Kept from the absorbed record: \(gainedNames) name(s), \(gainedFacts) fact(s).")
        }

        // Endpoint moves only — a record touched just to follow a citation onto a combined
        // link may belong to two bystanders, and reporting it as repointed would be false.
        if !decision.relinkedLinks.isEmpty || !decision.repointedRelationships.isEmpty {
            stdout.writeLine(
                "Repointed: \(decision.relinkedLinks.count) evidence link(s), "
                    + "\(decision.repointedRelationships.count) relationship(s).")
        }
        if decision.citationFollowingRewrites > 0 {
            stdout.writeLine(
                "Updated \(decision.citationFollowingRewrites) other record(s) citing a "
                    + "combined link.")
        }

        // Named individually, not counted: these are records that no longer exist, and a
        // bare number is not something a user can go look at.
        for link in decision.droppedLinks {
            stdout.writeLine(
                "Dropped link \(link.uid.raw) (\(link.reviewStatus.rawValue)) — "
                    + "the merge put two verdicts on one mention.")
        }
        for relationship in decision.droppedRelationships {
            let reason =
                relationship.involves(decision.absorbed.uid)
                    && relationship.involves(decision.survivor.uid)
                ? "it related the two merged persons to each other"
                : "an identical relationship already existed"
            stdout.writeLine(
                "Dropped relationship \(relationship.uid.raw) (\(relationship.type.rawValue)) — \(reason)."
            )
        }

        // The contradiction is called out in its own words: the user had recorded that
        // these two were not one person, and this command has just overruled that. A
        // cascade effect that reverses an earlier *human judgement* is the one this
        // report must not fold into a count.
        let contradicted = Set(decision.contradictedDismissals.map(\.uid))
        for dismissal in decision.droppedDismissals {
            let reason =
                contradicted.contains(dismissal.uid)
                ? "this merge contradicts it — you had declined \"\(dismissal.subject.rawValue)\" "
                    + "for these two"
                : "an identical dismissal already existed"
            stdout.writeLine("Dropped dismissal \(dismissal.uid.raw) — \(reason).")
        }

        if !decision.strandedCitations.isEmpty {
            stdout.writeLine(
                "\(decision.strandedCitations.count) citation(s) now dangle — see `genea verify`.")
        }
    }
}

// MARK: - person remove

/// `genea person remove <archive> <uid>` → `removePerson`.
///
/// **No cascade (§2.3), and the command says so.** Removing a person leaves any
/// relationship or evidence link naming them dangling rather than rewriting other
/// conclusion records — that's the engine's documented behavior and what keeps
/// the removal reversible. Since a CLI has no undo stack to soften it, the
/// command *counts* the records that will be left dangling and reports them, so
/// the consequence is visible at the moment it happens; `genea verify` also
/// surfaces the surviving dangles afterward (its informational
/// dangling-references sweep).
struct PersonRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a concluded person (relationships/links are left dangling)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The person's uid (e.g. PER-…).")
    var person: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = PersonID(person)
        let danglingRelationships = opened.relationships(of: id).count
        // Rejections counted too — see the same note in `RemoveCommand`: what a removal
        // leaves dangling is an integrity question, not a conclusions one.
        let danglingLinks = opened.links(for: id, includeRejected: true).count
        // A dismissal naming a removed person keeps suppressing a suggestion, and
        // `restorePerson` is one undo away — so it is dangling in the same sense the
        // others are, and worth the same warning.
        let danglingDismissals = opened.dismissals(involving: id).count

        let removed = try opened.removePerson(id)
        stdout.writeLine(
            "Removed \(removed.uid.raw)\t\(ConclusionsFormat.displayNameOrPlaceholder(removed))")
        if danglingRelationships > 0 || danglingLinks > 0 || danglingDismissals > 0 {
            stdout.writeLine(
                "Left dangling: \(danglingRelationships) relationship(s), "
                    + "\(danglingLinks) evidence link(s), \(danglingDismissals) dismissal(s). "
                    + "Remove them with `genea unrelate` / `genea unlink` / "
                    + "`genea person undismiss`.")
        }
    }
}

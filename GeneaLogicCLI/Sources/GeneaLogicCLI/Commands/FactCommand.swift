import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea fact …` — add or remove a concluded fact.
///
/// **One command for both stores, routed by target — the CLI twin of the app's
/// unified `FactEditorSheet`.** A fact about one person (birth, death,
/// residence) lives on `Person.facts`; a fact about two (marriage, divorce,
/// annulment) lives on `Relationship.facts` so it isn't duplicated onto each
/// spouse (§4.5). Both are the same `PersonFact` shape — GEDCOM X models person
/// and relationship facts with one `Fact` type — so one grammar with
/// `--person` / `--relationship` beats two near-identical command families.
struct FactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact",
        abstract: "Add or remove a fact on a person or a relationship.",
        subcommands: [FactAddCommand.self, FactRemoveCommand.self]
    )
}

/// The `--person` / `--relationship` target shared by `fact add` and `fact remove`,
/// with the "exactly one" rule in one place.
struct FactTarget: ParsableArguments {
    @Option(name: .long, help: "The person the fact is about (PER-…).")
    var person: String?

    @Option(
        name: .long,
        help: "The relationship the fact is about, e.g. a couple's marriage (REL-…).")
    var relationship: String?

    /// Resolves to exactly one target, or explains what's missing.
    func resolved() throws -> Resolved {
        switch (person, relationship) {
        case (let person?, nil): return .person(PersonID(person))
        case (nil, let relationship?): return .relationship(RelationshipID(relationship))
        case (nil, nil):
            throw CLIUserError("Specify --person or --relationship.")
        case (.some, .some):
            throw CLIUserError("Specify --person or --relationship, not both.")
        }
    }

    enum Resolved {
        case person(PersonID)
        case relationship(RelationshipID)
    }
}

// MARK: - fact add

/// `genea fact add <archive> (--person <uid> | --relationship <uid>) --type <t>
/// [--date <d>] [--place <p>]` → `updatePerson` / `updateRelationship`.
///
/// `--date` accepts the genealogist shorthands the app's date field does
/// (`"abt 1920"`, `"before 1950"`, `"June 1920"`, `"1940s"`) and stores canonical
/// EDTF via `EDTFDate.normalizingShorthand`; anything it can't normalize is kept
/// verbatim as free text, never rejected — genealogy has to allow the
/// unparseable. The stored value is echoed so a script can see what it got.
struct FactAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a fact to a person or a relationship."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var target: FactTarget

    @Option(name: .long, help: "Fact type, e.g. Birth, Death, Residence, Marriage, Divorce.")
    var type: String

    @Option(name: .long, help: "Date — EDTF or shorthand (\"abt 1920\", \"June 1920\", \"1940s\").")
    var date: String?

    @Option(name: .long, help: "Place, as recorded.")
    var place: String?

    @Option(
        name: .long,
        help: "Value for a value-bearing fact, e.g. an occupation or physical description.")
    var value: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let factType = FactType.parsing(type)
        let storedDate = date.map { EDTFDate.normalizingShorthand($0) }
        let fact = PersonFact(type: factType, date: storedDate, place: place, value: value)

        switch try target.resolved() {
        case .person(let id):
            try FactScope.validate(factType, for: .person)
            let updated = try opened.updatePerson(id) { $0.facts.append(fact) }
            // Data columns, not prose: the minted index leads, so it composes
            // with `fact remove --index` (the `attach` precedent).
            stdout.writeLine("\(updated.facts.count - 1)\t" + ConclusionsFormat.factLine(fact))
        case .relationship(let id):
            guard let existing = opened.relationship(withID: id) else {
                throw ArchiveError.relationshipNotFound(id)
            }
            try FactScope.validate(factType, for: .relationship(existing.type))

            // A parent-child qualifier **replaces** rather than accumulates: the
            // five are mutually-exclusive answers to one question ("what kind of
            // parent is this?"), which is why the app's nature menu replaces too
            // (`setParentChildQualifier`). Appending instead would let a link
            // assert two natures at once — a state the app cannot produce and
            // does not render (both its readers take the *first* qualifier), so
            // a CLI-seeded fixture could encode something the app treats as
            // impossible, then silently drop it on the next edit.
            let replacesQualifier = FactType.parentChildCases.contains(factType)
            let updated = try opened.updateRelationship(id) { record in
                if replacesQualifier {
                    record.facts.removeAll { FactType.parentChildCases.contains($0.type) }
                }
                record.facts.append(fact)
            }
            stdout.writeLine("\(updated.facts.count - 1)\t" + ConclusionsFormat.factLine(fact))
        }
    }
}

// MARK: - fact remove

/// `genea fact remove <archive> (--person <uid> | --relationship <uid>) --index <n>`
/// → `updatePerson` / `updateRelationship`.
///
/// Facts are an array with no ids of their own, so they're addressed by the index
/// `person show` prints. The bounds check runs *inside* the mutate closure,
/// against the record the engine loaded, matching the app's pattern for
/// index-addressed edits.
struct FactRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a fact by index (see `genea person show`)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @OptionGroup var target: FactTarget

    @Option(name: .long, help: "Which fact to remove, as shown by `genea person show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        // `updatePerson`/`updateRelationship` take a non-throwing closure, so an
        // out-of-range index is captured and rethrown after the call; the record
        // is left untouched (at the cost of one no-op rewrite on that path).
        var removed: PersonFact?
        var outOfRange: Int?

        func mutate(_ facts: inout [PersonFact]) {
            guard facts.indices.contains(index) else {
                outOfRange = facts.count
                return
            }
            removed = facts.remove(at: index)
        }

        let owner: String
        switch try target.resolved() {
        case .person(let id):
            try opened.updatePerson(id) { mutate(&$0.facts) }
            owner = id.raw
        case .relationship(let id):
            try opened.updateRelationship(id) { mutate(&$0.facts) }
            owner = id.raw
        }

        if let count = outOfRange {
            throw CLIUserError.outOfRange("fact", index: index, count: count)
        }
        stdout.writeLine(
            "Removed fact [\(index)] from \(owner)\t"
                + (removed.map(ConclusionsFormat.factLine) ?? ""))
    }
}

// MARK: - Fact-type scoping

/// Keeps a fact in the store that fits it.
///
/// **Deliberately stricter than the format, for known values only.** The three
/// `FactType` subsets partition the known vocabulary — person facts, couple
/// facts, parent-child qualifiers — and writing one into the wrong store isn't a
/// preference, it's a fact that will never render (the app's Facts timeline reads
/// couple facts off relationships, not off `Person.facts`). So a *known* type is
/// checked against its target, while an unrecognized one passes through
/// untouched: the format's open vocabularies must keep round-tripping values this
/// version has never heard of.
enum FactScope {
    enum Target {
        case person
        case relationship(RelationshipType)
    }

    static func validate(_ type: FactType, for target: Target) throws {
        guard FactType.knownCases.contains(type) else { return }

        let allowed: [FactType]
        let description: String
        switch target {
        case .person:
            allowed = FactType.personCases
            description = "a person"
        case .relationship(.couple):
            allowed = FactType.coupleCases
            description = "a couple"
        case .relationship(.parentChild):
            allowed = FactType.parentChildCases
            description = "a parent-child relationship"
        case .relationship(.unknown):
            // An unrecognized relationship type has no defined fact scope, so
            // there is nothing to check against — let it through.
            return
        }

        guard allowed.contains(type) else {
            throw CLIUserError(
                "\(type.rawValue) isn't a fact about \(description). Valid types here: "
                    + allowed.map(\.rawValue).joined(separator: ", ") + ".")
        }
    }
}

import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea mention …` — an artifact's `personsMentioned` (ARCHITECTURE.md §4.2).
///
/// **Evidence, not identity** — the invariant this command family exists to
/// respect. A mention is "the name exactly as it appears in this document"; it is
/// never a tree identity. Turning one into a concluded person is a separate,
/// explicit act (`genea link`), which is also why these live under their own noun
/// rather than as flags on `genea add`.
///
/// This closes the gap that made `link` unusable headlessly: mentions were only
/// creatable in the app's inspector, so a script could conclude persons but had
/// nothing on the evidence side to attach them to.
struct MentionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mention",
        abstract: "Record, list, and remove the persons named in an artifact.",
        subcommands: [
            MentionAddCommand.self,
            MentionListCommand.self,
            MentionFactCommand.self,
            MentionRelateCommand.self,
            MentionRemoveCommand.self,
        ]
    )
}

// MARK: - mention add

/// `genea mention add <archive> <artifact-uid> --name <as recorded>
/// [--role <r>] [--quality <q>] [--age <a>]` → `updateMetadata`, printing the
/// minted `localRef`.
///
/// **`localRef` is minted, never supplied** — the lowest unused `p<n>`, computed
/// against the record *inside* the mutation, mirroring the app's rule (slice 19).
/// It's the anchor an `EvidenceLink` points at, so letting a caller choose it
/// would invite collisions with mentions added elsewhere; it's printed instead,
/// which is what `genea link --mention` wants.
///
/// **…but never a ref a surviving link still points at.** Removing a mention
/// deliberately leaves its links dangling (§2.3), so a plain "lowest unused"
/// rule would hand the freed ref to the *next* mention and silently re-bind that
/// stale link to a different person — turning a visible dangle into an invisible
/// wrong conclusion. So the mint also skips any ref still referenced by
/// `links(forArtifact:)`. **A stated relationship claims a ref just as firmly**
/// (slice 45k), so the record's own `mentionRelationships` are passed too. The rule
/// itself lives in `GeneaLogicModel`
/// (`PersonMention.nextLocalRef(in:claimedBy:statedIn:)`) so the app and the CLI mint
/// identically — it is a format-level rule, and the two hand-written copies it
/// replaced had both drifted into the bug above (slice 44c).
struct MentionAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Record a person named in an artifact; prints its minted localRef."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact the name appears in (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The name exactly as recorded in the document.")
    var name: String

    /// Open vocabulary as of slice 44h — a register naming a role we haven't
    /// enumerated must be recordable, not rejected — so this takes a plain string
    /// and folds it through `OpenVocabulary+CLI`'s case-insensitive parse rather
    /// than being an `ExpressibleByArgument` the parser can reject.
    ///
    /// Dropping `ExpressibleByArgument` also dropped the value list ArgumentParser
    /// used to render into `--help` and shell completions for free, so the help text
    /// is **generated from `knownCases`** instead of naming a hand-picked few. That
    /// discoverability is what keeps a user from typing a variant of a role we do
    /// know (`"god-parent"`), which would mint an `.unknown` twin that renders
    /// identically but never compares equal — the drift the case-fold exists to stop.
    @Option(
        name: .long,
        help: """
            Role in the document; any value is accepted. Known: \
            \(PersonRole.knownCases.map(\.rawValue).joined(separator: ", ")).
            """)
    var role: String = PersonRole.subject.rawValue

    /// The **default** for this mention's recorded facts, not a quality of the
    /// person — set it to whatever most of them are and state the exceptions with
    /// `mention fact add --quality`.
    @Option(
        name: .long,
        help: "Default quality for this mention's facts (the informant's proximity).")
    var quality: InformationQuality = .undetermined

    @Option(name: .long, help: "Age as recorded in the document, if stated.")
    var age: String?

    /// BCP 47 tag of the *name*, not the document (`Artifact.language`) — a
    /// Russian-language register routinely records Polish and Yiddish names.
    @Option(
        name: .customLong("name-language"),
        help: "BCP 47 language of the recorded name (e.g. ru, pl, yi).")
    var nameLanguage: String?

    /// ISO 15924 script code. Orthogonal to the language: a transliterated Russian
    /// name is language `ru`, script `Latn`. This is what lets a matcher pick a
    /// phonetic algorithm instead of keying Cyrillic with Latin phonetics.
    @Option(
        name: .customLong("name-script"),
        help: "ISO 15924 script of the recorded name (e.g. Cyrl, Latn, Hebr).")
    var nameScript: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        // Refs a surviving link still points at, so the mint can't hand one out
        // again and silently re-bind that link — see `PersonMention.nextLocalRef`.
        // **Tombstones claim a ref too** (`includeRejected: true`): a rejection is
        // scoped to one mention, so reusing the ref it names would quietly turn "not
        // this person" into a rejection of whoever the new mention is.
        let linked = opened.links(forArtifact: id, includeRejected: true)

        var mintedRef = ""
        try opened.updateMetadata(of: id) { record in
            let ref = PersonMention.nextLocalRef(
                in: record.personsMentioned, claimedBy: linked,
                statedIn: record.mentionRelationships)
            mintedRef = ref
            record.personsMentioned.append(
                PersonMention(
                    localRef: ref,
                    nameAsRecorded: name,
                    role: .parsing(role),
                    informationQuality: quality,
                    nameLanguage: nameLanguage,
                    nameScript: nameScript,
                    attributes: age.map { ["ageAsRecorded": $0] }
                ))
        }
        stdout.writeLine(mintedRef)
    }
}

extension InformationQuality: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

// MARK: - mention list

/// `genea mention list <archive> <artifact-uid>` — one mention per line as
/// `<localRef>\t<name as recorded>\t<role>`, the refs `genea link` takes.
struct MentionListCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List an artifact's mentions as <localRef>\\t<name>\\t<role>."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact (ART-…).")
    var artifact: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        guard let record = opened.artifact(withID: id) else {
            throw ArchiveError.artifactNotFound(id)
        }
        for mention in record.personsMentioned {
            stdout.writeLine(
                "\(mention.localRef)\t\(mention.nameAsRecorded)\t\(mention.role.rawValue)")
        }
    }
}

// MARK: - mention fact

/// `genea mention fact …` — the facts a document records **about one of the people
/// it names** (`PersonMention.facts`, slice 44h).
///
/// **Deliberately not folded into `genea fact`.** That command adds a *concluded*
/// fact, and it takes one grammar for persons and relationships precisely because
/// both stores hold the same `PersonFact` — the justification slice 44b wrote down.
/// That justification does not carry here: a `RecordedFact` is a different type in
/// a different layer, kept separate so evidence never points into `conclusions/`
/// (§2.3). Routing it through the conclusions command would put the CLI's grammar
/// at odds with the format's own boundary. Nesting under the evidence noun matches
/// `genea person name add|remove` exactly.
struct MentionFactCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fact",
        abstract: "Record what a document says about one of the people it names.",
        subcommands: [MentionFactAddCommand.self, MentionFactRemoveCommand.self]
    )
}

/// `genea mention fact add <archive> <artifact-uid> --ref <localRef> --type <t>
/// [--date <d>] [--place <p>] [--quality <q>]` → `updateMetadata`, printing the
/// minted index.
///
/// This is what makes a multi-person record legible: a census household or a
/// metrical register names several people, and until now a recorded birth year
/// could only be attached to the *document*, not to whichever person it is about.
///
/// `--date` runs through `EDTFDate.normalizingShorthand` exactly like `fact add`
/// and `event add`; anything it can't normalize is stored verbatim as free text.
struct MentionFactAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Add a recorded fact to a mention; prints its minted index."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact the mention is on (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The mention's localRef (see `genea mention list`).")
    var ref: String

    @Option(name: .long, help: "Fact type, e.g. Birth, Death, Residence, Marriage.")
    var type: String

    @Option(name: .long, help: "Date — EDTF or shorthand (\"abt 1920\", \"June 1920\", \"1940s\").")
    var date: String?

    @Option(name: .long, help: "Place, as recorded.")
    var place: String?

    @Option(
        name: .long,
        help: "Value for a value-bearing fact, e.g. an occupation or physical description.")
    var value: String?

    /// Per-*field* GPS quality. Omitted means "as good as the mention" — the
    /// inherit rule, not `undetermined` (see `RecordedFact.informationQuality`).
    @Option(
        name: .long,
        help: "Quality for this fact alone; omit to inherit the mention's.")
    var quality: InformationQuality?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        let factType = FactType.parsing(type)
        try RecordedFactScope.validate(factType)
        let fact = RecordedFact(
            type: factType,
            date: date.map { EDTFDate.normalizingShorthand($0) },
            place: place,
            value: value,
            informationQuality: quality)

        // `updateMetadata` returns Void, so the minted index is captured in the
        // closure — the `mention add` / `event add` pattern.
        var mintedIndex: Int?
        try opened.updateMetadata(of: id) { record in
            guard let position = record.personsMentioned.firstIndex(where: { $0.localRef == ref })
            else { return }
            record.personsMentioned[position].facts.append(fact)
            mintedIndex = record.personsMentioned[position].facts.count - 1
        }
        guard let mintedIndex else {
            throw CLIUserError("No mention \(ref) on \(id.raw). See `genea mention list`.")
        }
        // Data column first, so it composes with `mention fact remove --index`.
        stdout.writeLine("\(mintedIndex)\t" + ArtifactFormat.recordedFactLine(fact))
    }
}

/// `genea mention fact remove <archive> <artifact-uid> --ref <localRef> --index <n>`
/// → `updateMetadata`. Recorded facts are an array with no ids of their own, so
/// they're addressed by the index `genea show` prints; the bounds check runs
/// *inside* the mutate closure, against the record the engine loaded.
struct MentionFactRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a mention's recorded fact by index (see `genea show`)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact the mention is on (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The mention's localRef (see `genea mention list`).")
    var ref: String

    @Option(name: .long, help: "Which recorded fact to remove, as shown by `genea show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        var removed: RecordedFact?
        var outOfRange: Int?
        var foundMention = false

        try opened.updateMetadata(of: id) { record in
            guard let position = record.personsMentioned.firstIndex(where: { $0.localRef == ref })
            else { return }
            foundMention = true
            guard record.personsMentioned[position].facts.indices.contains(index) else {
                outOfRange = record.personsMentioned[position].facts.count
                return
            }
            removed = record.personsMentioned[position].facts.remove(at: index)
        }

        guard foundMention else {
            throw CLIUserError("No mention \(ref) on \(id.raw). See `genea mention list`.")
        }
        if let count = outOfRange {
            throw CLIUserError.outOfRange(
                "recorded fact", index: index, count: count, see: "genea show")
        }
        stdout.writeLine(
            "Removed recorded fact [\(index)] from \(ref) on \(id.raw)\t"
                + (removed.map(ArtifactFormat.recordedFactLine) ?? ""))
    }
}

/// Keeps a recorded fact to a type that can be an observation about one named
/// person, mirroring `FactScope` on the conclusions side.
///
/// Only the parent-child qualifiers are refused: they describe the nature of a
/// concluded *edge* between two identities, so they cannot be something a document
/// records about a single person. An unrecognized type still passes through — the
/// format's open vocabularies must keep round-tripping values this version has
/// never heard of.
enum RecordedFactScope {
    static func validate(_ type: FactType) throws {
        guard FactType.knownCases.contains(type) else { return }
        guard FactType.recordedCases.contains(type) else {
            throw CLIUserError(
                "\(type.rawValue) describes a parent-child relationship, not something a "
                    + "record states about one person. Assert it with `genea fact add "
                    + "--relationship`.")
        }
    }
}

// MARK: - mention relate

/// `genea mention relate …` — the relationships **a document states** between the
/// people it names (`Artifact.mentionRelationships`, slice 45k).
///
/// Nested under the evidence noun for the same reason `mention fact` is: an edge
/// between two mentions is a statement about *this page*, not a conclusion about two
/// identities. Asserting that two concluded persons are parent and child is
/// `genea relate` / `genea fact --relationship`, one layer over.
struct MentionRelateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relate",
        abstract: "State a relationship the document draws between two of its mentions.",
        subcommands: [MentionRelateAddCommand.self, MentionRelateRemoveCommand.self]
    )
}

/// `genea mention relate add <archive> <artifact-uid> --ref1 <localRef>
/// --ref2 <localRef> [--type parent-child]` → `updateMetadata`, printing the minted
/// index.
///
/// **The direction is §4.5's and the flags say so**: for `parent-child`, `--ref1` is
/// the *parent*. Naming them `--parent`/`--child` would read better for that one type
/// and be a lie for `couple`, whose endpoints are symmetric — and the numbered pair is
/// what the format stores, so a reader comparing the JSON to the command sees the same
/// two fields rather than a translation.
struct MentionRelateAddCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "State a relationship between two mentions; prints its minted index."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact both mentions are on (ART-…).")
    var artifact: String

    @Option(name: .long, help: "First mention's localRef — the parent, for parent-child.")
    var ref1: String

    @Option(name: .long, help: "Second mention's localRef — the child, for parent-child.")
    var ref2: String

    /// Open vocabulary, like every other type flag: a register stating a relation this
    /// version hasn't enumerated must be recordable rather than rejected.
    @Option(
        name: .long,
        help: """
            Relationship the document states; any value is accepted. Known: \
            \(RelationshipType.knownCases.map(\.rawValue).joined(separator: ", ")).
            """)
    var type: String = RelationshipType.parentChild.rawValue

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        guard ref1 != ref2 else {
            throw CLIUserError(
                "A mention cannot be related to itself. See `genea mention list`.")
        }

        let edge = MentionRelationship(
            type: .parsing(type), person1Ref: ref1, person2Ref: ref2)

        // Validated **before** the mutation, not inside it. `updateMetadata` commits
        // whatever the closure leaves behind, so a closure that inspects the record and
        // declines still rewrites `record.json`, re-upserts the index and commits the
        // manifest — a rejected command that writes. An edge naming a mention that isn't
        // there is exactly the dangling reference `genea verify` reports, and there is no
        // reason to let the CLI author one. (Removals still strand edges — §2.3, not this.)
        guard let record = opened.artifact(withID: id) else {
            throw ArchiveError.artifactNotFound(id)
        }
        let refs = Set(record.personsMentioned.map(\.localRef))
        let missing = [ref1, ref2].filter { !refs.contains($0) }
        guard missing.isEmpty else {
            throw CLIUserError(
                "No mention \(missing.joined(separator: ", ")) on \(id.raw). "
                    + "See `genea mention list`.")
        }
        // `statesSameRelationship`, not `==`: a `couple` is symmetric, so the reverse
        // pair is the same statement and storing it would be the double-entry the
        // format forbids (§6.1).
        guard !record.mentionRelationships.contains(where: { $0.statesSameRelationship(as: edge) })
        else {
            throw CLIUserError(
                "\(id.raw) already states that relationship. One edge is one entry — "
                    + "see `genea show`.")
        }

        var mintedIndex: Int?
        try opened.updateMetadata(of: id) { record in
            record.mentionRelationships.append(edge)
            mintedIndex = record.mentionRelationships.count - 1
        }
        guard let mintedIndex else { throw ArchiveError.artifactNotFound(id) }
        stdout.writeLine("\(mintedIndex)\t" + ArtifactFormat.mentionRelationshipLine(edge))
    }
}

/// `genea mention relate remove <archive> <artifact-uid> --index <n>` →
/// `updateMetadata`. Edges have no ids of their own, so they are addressed by the
/// index `genea show` prints, and the bounds check runs inside the mutate closure —
/// the `mention fact remove` shape exactly.
struct MentionRelateRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a stated relationship by index (see `genea show`)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact (ART-…).")
    var artifact: String

    @Option(name: .long, help: "Which stated relationship to remove, as shown by `genea show`.")
    var index: Int

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        // Bounds-checked before the mutation for the same reason as `relate add`: a
        // closure that declines still commits a write, so an out-of-range index would
        // rewrite the record it refused to change.
        guard let record = opened.artifact(withID: id) else {
            throw ArchiveError.artifactNotFound(id)
        }
        guard record.mentionRelationships.indices.contains(index) else {
            throw CLIUserError.outOfRange(
                "stated relationship", index: index,
                count: record.mentionRelationships.count, see: "genea show")
        }

        var removed: MentionRelationship?
        try opened.updateMetadata(of: id) { record in
            // Re-checked against the record the engine loaded: the read above is a
            // separate load, and the index it validated could be stale by now.
            guard record.mentionRelationships.indices.contains(index) else { return }
            removed = record.mentionRelationships.remove(at: index)
        }
        stdout.writeLine(
            "Removed stated relationship [\(index)] from \(id.raw)\t"
                + (removed.map(ArtifactFormat.mentionRelationshipLine) ?? ""))
    }
}

// MARK: - mention remove

/// `genea mention remove <archive> <artifact-uid> --ref <localRef>` →
/// `updateMetadata`.
///
/// Removing a mention can leave an `EvidenceLink` pointing at a `localRef` that
/// no longer exists — the §2.3 no-cascade rule again, and the same shape the app
/// has (its row trash deletes the evidence, leaving the link behind). The command
/// reports the count itself, at the moment it happens, rather than cascading or
/// staying silent; `genea verify` also surfaces such stale links after the fact
/// (its informational dangling-references sweep, `findDanglingReferences()`).
struct MentionRemoveCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a mention by its localRef."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The artifact (ART-…).")
    var artifact: String

    @Option(name: .long, help: "The mention's localRef (see `genea mention list`).")
    var ref: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let id = ArtifactID(artifact)
        // Rejections counted too — an integrity statement about what this removal
        // strands, matching `findDanglingReferences()`'s scope.
        let danglingLinks = opened.links(forArtifact: id, includeRejected: true)
            .filter { $0.personMentionRef == ref }
            .count

        var found = false
        // A mention's `facts` are destroyed with it, and the CLI has no undo. That is
        // owned data, not a dangling reference — a *stronger* case for the "say what
        // this removal cost, at the moment it happens" rule than the links below, not
        // a weaker one. Counted before the write, since the record is gone after.
        var destroyedFacts = 0
        // Stated relationships are **left behind**, not cascaded — the same §2.3 rule
        // the links follow, and the reason `findDanglingReferences()` looks for them.
        var strandedEdges = 0
        try opened.updateMetadata(of: id) { record in
            destroyedFacts = record.personsMentioned
                .filter { $0.localRef == ref }
                .reduce(0) { $0 + $1.facts.count }
            strandedEdges = record.mentionRelationships.filter { $0.involves(ref) }.count
            let remaining = record.personsMentioned.filter { $0.localRef != ref }
            found = remaining.count != record.personsMentioned.count
            record.personsMentioned = remaining
        }
        guard found else {
            throw CLIUserError(
                "No mention \(ref) on \(id.raw). See `genea mention list`.")
        }

        stdout.writeLine("Removed mention \(ref) from \(id.raw)")
        if destroyedFacts > 0 {
            stdout.writeLine(
                "Also removed: \(destroyedFacts) recorded fact(s) this document stated "
                    + "about \(ref).")
        }
        if strandedEdges > 0 {
            stdout.writeLine(
                "Left dangling: \(strandedEdges) stated relationship(s) naming \(ref). "
                    + "Remove them with `genea mention relate remove`.")
        }
        if danglingLinks > 0 {
            stdout.writeLine(
                "Left dangling: \(danglingLinks) evidence link(s) pointing at \(ref). "
                    + "Remove them with `genea unlink`.")
        }
    }
}

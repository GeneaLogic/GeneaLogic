import ArgumentParser
import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// `genea relate <archive> (--parent <uid> --child <uid> | --partner <uid>
/// --partner <uid>) [--nature <t>]` → `addRelationship`, printing the minted
/// `REL-` uid.
///
/// **Flags name the roles, not the storage slots.** The §4.5 convention
/// (`person1Uid` is the parent, `person2Uid` the child; a couple is symmetric)
/// is an internal contract the caller shouldn't have to hold in their head — the
/// app solves this with a perspective picker ("…is a parent of Ann Smith"), and
/// the CLI solves it with role-named flags that map onto the convention here.
/// `--partner` is repeated twice because a couple's two endpoints are
/// interchangeable; there is no first or second partner to name.
///
/// `--nature` records *what kind* of parent-child link this is (adoptive, step,
/// foster, guardian, or explicitly biological) as a fact on the relationship —
/// the slice-44f representation, which needs no format change because
/// `Relationship.facts` already exists. **Omitting it means unspecified, never
/// "biological"**: a researcher who hasn't established the nature of a link must
/// not have one asserted on their behalf.
struct RelateCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "relate",
        abstract: "Assert a parent-child or couple relationship; prints its minted uid."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Option(name: .long, help: "The parent's uid (with --child).")
    var parent: String?

    @Option(name: .long, help: "The child's uid (with --parent).")
    var child: String?

    @Option(
        name: .long, parsing: .singleValue,
        help: "A partner's uid; pass twice for a couple.")
    var partner: [String] = []

    @Option(
        name: .long,
        help: """
            Nature of a parent-child link: BiologicalParent, AdoptiveParent, \
            StepParent, FosterParent, GuardianParent. Omit to leave it unspecified.
            """)
    var nature: String?

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let draft = try makeDraft()
        let relationship = try opened.addRelationship(draft)
        stdout.writeLine(relationship.uid.raw)
    }

    /// Resolves the mutually-exclusive flag pair into a `RelationshipDraft`,
    /// applying the §4.5 endpoint convention.
    private func makeDraft() throws -> RelationshipDraft {
        let isParentChild = parent != nil || child != nil
        let isCouple = !partner.isEmpty

        guard isParentChild != isCouple else {
            throw CLIUserError(
                "Specify either --parent and --child, or --partner twice — not both.")
        }

        // `addRelationship` only checks that both endpoints *exist*, so nothing
        // downstream stops a person being their own parent or spouse. The app's
        // pickers exclude the subject; the CLI has to say it out loud, or it
        // writes a nonsensical conclusion and feeds a self-loop to the tree.
        func rejectSelfRelation(_ a: String, _ b: String) throws {
            guard a != b else {
                throw CLIUserError("A person can't be related to themselves.")
            }
        }

        if isCouple {
            guard partner.count == 2 else {
                throw CLIUserError("A couple needs exactly two --partner uids.")
            }
            if nature != nil {
                throw CLIUserError(
                    "--nature qualifies a parent-child link; a couple's marriage or divorce is "
                        + "a fact instead (`genea fact add --relationship <uid> --type Marriage`).")
            }
            try rejectSelfRelation(partner[0], partner[1])
            return RelationshipDraft(
                type: .couple,
                person1Uid: PersonID(partner[0]),
                person2Uid: PersonID(partner[1])
            )
        }

        guard let parent, let child else {
            throw CLIUserError("--parent and --child must be given together.")
        }
        try rejectSelfRelation(parent, child)
        return RelationshipDraft(
            type: .parentChild,
            person1Uid: PersonID(parent),
            person2Uid: PersonID(child),
            facts: try natureFacts()
        )
    }

    /// `--nature` as a `PersonFact`, validated against `FactType.parentChildCases`.
    ///
    /// This is one of two places the CLI is deliberately *stricter* than the open
    /// vocabulary (`FactScope.validate` is the other): a fact type is only a parent-child qualifier if it's one of the
    /// five that answer "what kind of parent is this?", so `--nature Marriage`
    /// (a couple fact) or `--nature Birth` (a person fact) is a mistake worth
    /// catching rather than a value worth preserving. A genuinely unrecognized
    /// string still round-trips — the format's openness is intact for vocabularies
    /// that grow.
    private func natureFacts() throws -> [PersonFact] {
        guard let nature else { return [] }
        let type = FactType.parsing(nature)
        if FactType.knownCases.contains(type), !FactType.parentChildCases.contains(type) {
            throw CLIUserError(
                "--nature must be a parent-child qualifier "
                    + "(\(FactType.parentChildCases.map(\.rawValue).joined(separator: ", "))), "
                    + "not \(type.rawValue).")
        }
        return [PersonFact(type: type)]
    }
}

// MARK: - unrelate

/// `genea unrelate <archive> <rel-uid>` → `removeRelationship`.
///
/// Takes the uid `person show` prints, and removes only that relationship — the
/// two persons and any evidence links are untouched (§2.3, no cascade).
struct UnrelateCommand: ArchiveSubcommand {
    static let configuration = CommandConfiguration(
        commandName: "unrelate",
        abstract: "Remove a relationship by uid (the persons themselves are untouched)."
    )

    @Argument(help: "Path to the archive.")
    var archive: String

    @Argument(help: "The relationship's uid (e.g. REL-…).")
    var relationship: String

    func run(archive opened: Archive, stdout: CLIOutput, stderr: CLIOutput) throws {
        let removed = try opened.removeRelationship(RelationshipID(relationship))
        stdout.writeLine("Removed \(removed.uid.raw)\t\(removed.type.rawValue)")
    }
}

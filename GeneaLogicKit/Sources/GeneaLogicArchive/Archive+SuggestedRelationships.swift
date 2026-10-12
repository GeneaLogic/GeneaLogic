import Foundation
import GeneaLogicMatch
import GeneaLogicModel

/// Suggested relationships — proposing the conclusion a record already states (slice 45l).
///
/// The gap this closes was in the archive rather than in the design: the Sidney Feldberg
/// death certificate names his parents, both are resolved to concluded persons, and
/// `conclusions/` said nothing about it. Nothing anywhere derived a **relationship** from
/// what a record states; 42c/45i do it for *facts* only, so the cataloguer re-asserted by
/// hand what the document in front of them had already said.
///
/// ## What counts as the record saying it
///
/// Two readings, in strict order — the same fallback 45k gave the matcher, so the matcher
/// and this derivation never disagree about what a record says:
///
/// 1. **A stated edge** (`Artifact.mentionRelationships`, §6.1) is the record speaking.
///    No interpretation is applied to it at all; it is read verbatim, direction included.
/// 2. **Otherwise the roles**, through 45g's star rule — a record is a star around its
///    centre, never a graph — via ``GeneaLogicMatch/Matcher/principalRole(among:)``, the
///    one implementation of where that centre is.
///
/// The preference is per **slot**, not per record, exactly as 45k scopes the matcher's:
/// a record that states who the bride's parents are has said nothing about the groom's, so
/// stating one edge must not silence the inference everywhere else. See
/// ``RecordRelationReading``.
///
/// ## Inference concludes only where the centre is one person
///
/// This is where 45l is deliberately stricter than the matcher, and the reason is the
/// asymmetry between the two acts. The matcher scores a *positive-only* dimension: reading
/// a marriage register's four parents best-of costs nothing when it guesses wrong, because
/// a wrong guess simply fails to corroborate. Writing a conclusion from the same guess
/// asserts that this bride's mother is that groom's mother, which is not something the
/// record says at all. So an inferred statement is offered only where the record's centre
/// resolves to exactly one person — a marriage register's four parents stay unassignable
/// until its edges are stated, which is precisely the work 45k exists to make possible.
///
/// ## Ephemeral, like every other suggestion here
///
/// Nothing is written until a human confirms. A re-run reflects the archive as it is now,
/// so there is no suggestion record to go stale — see `Archive+Matching.swift`'s header for
/// why the whole mini-phase is built this way. The one thing that *is* stored is a **no**,
/// and it was already built: 45m's `Dismissal`, with subject `parent-child` or `couple`
/// and no breakdown, because a suggestion read off a stated edge and two confirmed links
/// carries no score and synthesizing one would be a lie in the shape of a number.
extension Archive {

    // MARK: - Suggestion

    /// Every relationship the archive's records state (or unambiguously imply) between two
    /// concluded persons, that `conclusions/` does not yet assert.
    ///
    /// The worklist direction (the Review lane). One suggestion per pair-and-type however
    /// many records support it: two documents naming the same father are one conclusion
    /// with two citations, not two rows proposing the same edge twice.
    ///
    /// - Parameter limit: At most this many suggestions; `nil` for all.
    /// - Returns: Suggestions in **document order** — by the first record that supports
    ///   each, then by the pair. There is no score to rank on here (fork (b)/45m: these
    ///   suggestions are derived, not measured), and a queue that reordered itself between
    ///   launches would be a bug a test could not pin.
    public func suggestedRelationships(limit: Int? = nil) -> [SuggestedRelationship] {
        suggestedRelationships(artifact: nil, person: nil, limit: limit)
    }

    /// The suggestions **naming this person at either endpoint** — the person pane's
    /// direction, beside its Relationships section.
    ///
    /// The third filter over one derivation, added on the same reasoning as the second: the
    /// person pane already pairs Facts with Suggested Facts, so Relationships standing alone
    /// was an asymmetry a reader would read as *there is nothing to promote here*. Like the
    /// artifact direction it filters rather than re-derives, so no surface can offer an edge
    /// another considers settled.
    public func suggestedRelationships(
        for personID: PersonID, limit: Int? = nil
    ) -> [SuggestedRelationship] {
        suggestedRelationships(artifact: nil, person: personID, limit: limit)
    }

    /// The suggestions **this record takes part in** — the artifact inspector's direction
    /// (fork (a)): the cataloguer is standing on the document that states the relationship,
    /// which is where the judgement is actually made.
    ///
    /// Deliberately a *filter* over the whole-archive derivation rather than a scan of one
    /// record. A suggestion is a claim about a pair of persons, and whether it has already
    /// been asserted or declined is an archive-wide question; deriving it from one artifact
    /// would let the inspector offer an edge the lane considers settled, and the user would
    /// have no way to tell which surface was right. It also means a row confirmed from here
    /// cites **every** record that supports it, not only the one on screen.
    ///
    /// - Returns: Empty if `artifactID` doesn't exist, or if it supports nothing new.
    public func suggestedRelationships(
        forArtifact artifactID: ArtifactID, limit: Int? = nil
    ) -> [SuggestedRelationship] {
        suggestedRelationships(artifact: artifactID, person: nil, limit: limit)
    }

    private func suggestedRelationships(
        artifact: ArtifactID?, person: PersonID?, limit: Int?
    ) -> [SuggestedRelationship] {
        withIndex { index in
            // Every read is linear and happens once for the whole pass — this sweep is
            // wired into the app's ordinary refresh, unlike the quadratic duplicate scan.
            let artifacts = ((try? index.allArtifacts()) ?? []).sorted { $0.uid.raw < $1.uid.raw }
            // §2.3: removals don't cascade, so a confirmed link can outlive the person it
            // names. Offering that pair would be worse than useless — the row's own Record
            // button throws `personNotFound`, which is the one thing a Review row must never
            // do (45m's stale-merge bug, in a lane that cannot re-scan its way out of it).
            let living = Set(((try? index.allPersons()) ?? []).map(\.uid))
            let resolutions = Self.resolutions(in: (try? index.allLinks()) ?? [])
                .filter { living.contains($0.value.personUid) }
            let settled = Self.settled(
                relationships: (try? index.allRelationships()) ?? [],
                dismissals: (try? index.allDismissals()) ?? [])

            var found: [SuggestedRelationship] = []
            var position: [StatementKey: Int] = [:]

            for record in artifacts {
                for statement in RecordRelationReading.statements(in: record) {
                    guard
                        let evidence = Self.resolve(
                            statement, in: record, using: resolutions)
                    else { continue }

                    let key = StatementKey(
                        type: statement.type, person1: evidence.person1, person2: evidence.person2)
                    guard !settled.contains(key) else { continue }

                    if let at = position[key] {
                        found[at].evidence.append(evidence.evidence)
                    } else {
                        position[key] = found.count
                        found.append(
                            SuggestedRelationship(
                                type: statement.type,
                                person1: evidence.person1,
                                person2: evidence.person2,
                                evidence: [evidence.evidence]))
                    }
                }
            }

            // The narrowing directions, applied **after** the whole answer is built rather
            // than while building it: a suggestion is a claim about a pair, and whether it
            // has been asserted or declined is an archive-wide question.
            if let artifact {
                found = found.filter { $0.evidence.contains { $0.artifact == artifact } }
            }
            if let person {
                found = found.filter { $0.person1 == person || $0.person2 == person }
            }
            if let limit { return Array(found.prefix(max(0, limit))) }
            return found
        }
    }

    // MARK: - Promotion

    /// Records the suggestion as a concluded relationship.
    ///
    /// **`.humanVerified`, `createdBy: .machine`** (fork (d)) — 45c's rule that a
    /// confirmation records *what was computed and who agreed to it*, rather than
    /// laundering a derived proposal into a hand-made assertion. The relationship cites
    /// both endpoints' evidence links, from every record that supports it, so the tree can
    /// say why it believes the edge.
    ///
    /// **Idempotent**, like ``dismiss(_:between:and:match:aggregateConfidence:dismissedBy:)``
    /// and for the same reason: recording a claim the archive already asserts returns the
    /// existing record rather than minting a second. The sweep subtracts asserted edges, so
    /// this is only reachable from a *stale* list — two windows on one archive, or a queue
    /// left open while the CLI wrote — which is the ordinary case, not a rare one. Two
    /// records for one conclusion would make undo half-effective (⌘Z removes one, the tree
    /// still draws the edge) and give `revertMerge` two rows to reconcile where there was
    /// one judgement.
    ///
    /// A caller that registers undo must therefore ask ``asserts(_:between:and:)`` **first**
    /// — the returned record looks identical either way, and undoing a conclusion this click
    /// did not create is the one thing an undo must never do (45m's review, on the
    /// dismissal side of the same shape).
    ///
    /// - Throws: `ArchiveError.personNotFound` if either person has since been removed.
    @discardableResult
    public func confirm(_ suggestion: SuggestedRelationship) throws -> Relationship {
        if let existing = withIndex({ index in
            ((try? index.allRelationships()) ?? [])
                .sorted { $0.uid.raw < $1.uid.raw }
                .first {
                    $0.states(
                        suggestion.type, between: suggestion.person1, and: suggestion.person2)
                }
        }) {
            return existing
        }

        let now = ISO8601DateFormatter().string(from: Date())
        return try addRelationship(
            RelationshipDraft(
                type: suggestion.type,
                person1Uid: suggestion.person1,
                person2Uid: suggestion.person2,
                supportedByLinks: suggestion.supportedByLinks,
                reviewStatus: .humanVerified,
                provenance: Provenance(
                    createdBy: .machine,
                    createdAt: now,
                    tool: SuggestedRelationship.toolIdentifier,
                    reviewStatus: .humanVerified)))
    }

    /// Whether `conclusions/` already asserts this claim — the positive twin of
    /// ``isDismissed(_:between:and:)``, and what a caller checks before registering an undo
    /// for ``confirm(_:)``.
    public func asserts(
        _ type: RelationshipType, between person1: PersonID, and person2: PersonID
    ) -> Bool {
        withIndex { index in
            ((try? index.allRelationships()) ?? []).contains {
                $0.states(type, between: person1, and: person2)
            }
        }
    }

    /// Records that a human declined the suggestion, so it is not offered again (45m).
    ///
    /// No breakdown and no aggregate: this suggestion was *read off* a record, not scored,
    /// which is the case 45m made the field optional for.
    @discardableResult
    public func dismiss(
        _ suggestion: SuggestedRelationship, dismissedBy: Reviewer = .unspecified
    ) throws -> Dismissal {
        try dismiss(
            suggestion.dismissalSubject,
            between: suggestion.person1, and: suggestion.person2,
            dismissedBy: dismissedBy)
    }

    // MARK: - The two subtractions

    /// Which mention each **confirmed** link resolves, and to whom.
    ///
    /// A rejection tombstone resolves nothing (45c) and is skipped, as is a
    /// `machine-suggested` link — GeneaLogic never writes one, and an unreviewed guess from
    /// a foreign writer is not the human judgement a conclusion may be built on.
    ///
    /// **A mention with two confirmed links contributes nothing.** `link()` has no
    /// one-per-`localRef` guard, so a mention pointing at two persons is reachable; it is a
    /// contradiction about who this name is, and there is no honest way to pick an end for
    /// an edge out of it.
    private static func resolutions(in links: [EvidenceLink]) -> [MentionRef: EvidenceLink] {
        var byMention: [MentionRef: [EvidenceLink]] = [:]
        for link in links where link.reviewStatus == .humanConfirmed {
            let ref = MentionRef(artifact: link.artifactUid, localRef: link.personMentionRef)
            byMention[ref, default: []].append(link)
        }
        return byMention.compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    /// The statements `conclusions/` has already settled — asserted **or** declined.
    ///
    /// Both are the same subtraction from this queue's point of view: the human has
    /// answered, and re-offering the pair is what the Review section's ability to reach
    /// empty depends on not doing. The two arrive through the same canonical key, so a
    /// symmetric `couple` counts as settled from **either** direction (§4.5) and a
    /// directional `parent-child` does not — declining *she is his mother* leaves *he is
    /// her father* an open question, which is the whole point of storing the direction.
    ///
    /// A `same-person` dismissal is not a statement any relationship type makes, and is
    /// dropped rather than parsed into one: 45j's lane owns that subject.
    private static func settled(
        relationships: [Relationship], dismissals: [Dismissal]
    ) -> Set<StatementKey> {
        var keys = Set(
            relationships.map {
                StatementKey(type: $0.type, person1: $0.person1Uid, person2: $0.person2Uid)
            })
        for dismissal in dismissals where dismissal.subject != .samePerson {
            keys.insert(
                StatementKey(
                    type: RelationshipType(parsing: dismissal.subject.rawValue),
                    person1: dismissal.person1Uid,
                    person2: dismissal.person2Uid))
        }
        return keys
    }

    /// Resolves one record-level statement onto two concluded persons, or `nil` when the
    /// record cannot support a conclusion from it.
    ///
    /// Three ways that happens, and all three are ordinary states rather than errors: an
    /// endpoint whose mention is unresolved (the commonest — the work is simply not done
    /// yet), an endpoint naming a mention the record no longer carries (a dangling edge,
    /// which `findDanglingReferences()` reports and this must not silently promote), and
    /// **both endpoints resolving to one person**, which would be a self-loop — the shape
    /// 45f's merge already drops rather than writes.
    private static func resolve(
        _ statement: RecordStatement,
        in artifact: Artifact,
        using resolutions: [MentionRef: EvidenceLink]
    ) -> (person1: PersonID, person2: PersonID, evidence: RelationshipEvidence)? {
        guard
            let link1 = resolutions[
                MentionRef(artifact: artifact.uid, localRef: statement.person1Ref)],
            let link2 = resolutions[
                MentionRef(artifact: artifact.uid, localRef: statement.person2Ref)],
            link1.personUid != link2.personUid
        else { return nil }

        // Canonical order for a symmetric type, as given for a directional one — the same
        // rule `Dismissal.canonicalPair` applies to the pair on the far side of a decline,
        // through the single owner of the symmetry question.
        let flip = statement.type.isSymmetric && link2.personUid.raw < link1.personUid.raw
        let (first, second) = flip ? (link2, link1) : (link1, link2)
        let (firstRef, secondRef) =
            flip
            ? (statement.person2Ref, statement.person1Ref)
            : (statement.person1Ref, statement.person2Ref)

        return (
            first.personUid, second.personUid,
            RelationshipEvidence(
                artifact: artifact.uid,
                basis: statement.basis,
                person1Ref: firstRef,
                person2Ref: secondRef,
                person1Link: first.uid,
                person2Link: second.uid)
        )
    }
}

// MARK: - StatementKey

/// A relationship claim as one hashable value: the type plus the pair, already in the
/// order that type stores. Symmetry is applied by the caller (through
/// ``RelationshipType/isSymmetric``) before a key is built, for the reason `PairKey`
/// carries no ordering rule either — a key that canonicalized on its own would be a second
/// owner of the question.
struct StatementKey: Hashable {
    var type: String
    var person1: String
    var person2: String

    init(type: RelationshipType, person1: PersonID, person2: PersonID) {
        self.type = type.rawValue
        if type.isSymmetric, person2.raw < person1.raw {
            self.person1 = person2.raw
            self.person2 = person1.raw
        } else {
            self.person1 = person1.raw
            self.person2 = person2.raw
        }
    }
}

// MARK: - Reading one record

/// What a single record places between two of the people it names — the stated edges it
/// carries, plus the ones its roles unambiguously imply.
///
/// **Pure and record-local**: it knows nothing about persons, links or conclusions, which
/// is what makes it testable on its own and keeps the resolution rules in one place above.
enum RecordRelationReading {

    /// Every relation this record asserts between two of its mentions, stated ones first.
    static func statements(in artifact: Artifact) -> [RecordStatement] {
        var found: [RecordStatement] = []
        var seen: Set<StatementRefKey> = []

        func offer(_ statement: RecordStatement) {
            // A self-edge is a data error, not a statement: it says a mention is its own
            // parent. It goes no further here (`findDanglingReferences` is where the
            // record's own errors are reported).
            guard statement.person1Ref != statement.person2Ref else { return }
            guard seen.insert(StatementRefKey(statement)).inserted else { return }
            found.append(statement)
        }

        let edges = artifact.mentionRelationships
        for edge in edges {
            offer(
                RecordStatement(
                    type: edge.type, person1Ref: edge.person1Ref, person2Ref: edge.person2Ref,
                    basis: .stated))
        }
        for inferred in inferredStatements(in: artifact, given: edges) { offer(inferred) }
        return found
    }

    /// The star inference (45g), applied only where it yields one answer.
    ///
    /// Runs per **slot** against the stated edges, which is 45k's correction carried over:
    /// a record that states the centre's parents has said nothing about the centre's
    /// partner, so filling one slot must not silence the other. Reading either silence as
    /// denial would mean that adding information to a half-catalogued record *removes* a
    /// suggestion it used to make.
    private static func inferredStatements(
        in artifact: Artifact, given edges: [MentionRelationship]
    ) -> [RecordStatement] {
        let mentions = artifact.personsMentioned
        guard let principalRole = Matcher.principalRole(among: mentions.map(\.role)) else {
            // No centre: two witnesses to a deed are related to each other by nothing the
            // document says, and inventing the edge is worse than leaving the work undone.
            return []
        }
        let principals = mentions.filter { $0.role == principalRole }

        // The slots the record's own edges already fill, read from the *centre's* end,
        // because every inference below is a statement about the centre's family.
        let statedChild = Set(edges.compactMap(\.childRef))
        let statedPartner = Set(
            edges.filter { $0.type == .couple }.flatMap { [$0.person1Ref, $0.person2Ref] })

        // **A `spouse` centre means the record is a couple document, and a couple
        // document's parents are unassignable — however many of its parties have been
        // entered so far.**
        //
        // This is scoped to the *kind* of centre rather than to a head-count, which is the
        // correction `/code-review` made. Counting principals reads "two spouses named →
        // ambiguous" and lets a **half-catalogued** register through the single-centre path
        // below: bride entered, groom not yet, both fathers entered, and every one of those
        // fathers is attributed to the bride. That is the exact conclusion the guard exists
        // to refuse, produced by a record that is *less* complete than the one it refuses —
        // and it would appear and then silently disappear as cataloguing continued.
        //
        // The couple edge itself is the one thing such a record says unambiguously, and only
        // once both parties are named: with one spouse mention the partner is a person the
        // document names and the archive has not been told about yet.
        if principalRole == .spouse {
            guard principals.count == 2 else { return [] }
            let (first, second) = (principals[0], principals[1])
            guard !statedPartner.contains(first.localRef),
                !statedPartner.contains(second.localRef)
            else { return [] }
            return [
                RecordStatement(
                    type: .couple, person1Ref: first.localRef, person2Ref: second.localRef,
                    basis: .inferredFromRoles)
            ]
        }

        // A `subject` centre. Two subjects is its own ambiguity — a photograph of two
        // people states nothing about which of them the parents beside them belong to.
        guard principals.count == 1, let centre = principals.first else { return [] }

        var found: [RecordStatement] = []
        if !statedChild.contains(centre.localRef) {
            // §4.5's direction: the parent is `person1`.
            found += mentions.filter { $0.role == .parent }
                .map {
                    RecordStatement(
                        type: .parentChild, person1Ref: $0.localRef,
                        person2Ref: centre.localRef, basis: .inferredFromRoles)
                }
        }
        if !statedPartner.contains(centre.localRef) {
            found += mentions.filter { $0.role == .spouse && $0.localRef != centre.localRef }
                .map {
                    RecordStatement(
                        type: .couple, person1Ref: centre.localRef, person2Ref: $0.localRef,
                        basis: .inferredFromRoles)
                }
        }
        return found
    }

    /// Two statements about the same refs, compared the way the format compares edges —
    /// through ``MentionRelationship/statesSameRelationship(as:)``'s rule, so a `couple`
    /// stated one way round and inferred the other is one statement, not two.
    private struct StatementRefKey: Hashable {
        var type: String
        var ref1: String
        var ref2: String

        init(_ statement: RecordStatement) {
            type = statement.type.rawValue
            if statement.type.isSymmetric, statement.person2Ref < statement.person1Ref {
                ref1 = statement.person2Ref
                ref2 = statement.person1Ref
            } else {
                ref1 = statement.person1Ref
                ref2 = statement.person2Ref
            }
        }
    }
}

/// One relation a record places between two of its mentions, before anything is known
/// about who those mentions are.
struct RecordStatement: Equatable {
    var type: RelationshipType
    /// For `parent-child`, the **parent** (§4.5's direction, unchanged across both layers).
    var person1Ref: String
    var person2Ref: String
    var basis: RelationshipBasis
}

// MARK: - SuggestedRelationship

/// A relationship the archive's records support and `conclusions/` does not yet assert —
/// the relationship analogue of a suggested fact (42c/45i).
///
/// **Not a record**, for the reason `SuggestedLink` and `DuplicateCandidate` aren't: no
/// uid, no provenance, no sidecar, so there is no code path that could accidentally persist
/// one. Confirming it writes a `Relationship`; declining it writes a `Dismissal`.
///
/// It carries **no confidence**, and that absence is deliberate. This is not a guess about
/// identity that a matcher scored — the links at both ends were already confirmed by a
/// human, and the edge between them is what the document says. What a reviewer needs to see
/// is therefore not a number but *which record says it, and whether the record said it
/// outright* — which is what ``evidence`` carries.
public struct SuggestedRelationship: Sendable, Equatable {

    /// Identifies this derivation in a promoted relationship's `provenance.tool`.
    ///
    /// Its **own** identifier, not the matcher's: nothing here is scored, so borrowing
    /// `Matcher.toolIdentifier` would make a promoted relationship indistinguishable from
    /// something the scorer produced, and would tie its version to score changes that
    /// cannot affect it.
    public static let toolIdentifier = "genealogic-relationships/1"

    /// What is proposed, from the same open vocabulary as `Relationship.type`.
    public var type: RelationshipType

    /// The first endpoint. For `parent-child` the proposed **parent** (§4.5); for a
    /// symmetric type, the lower `uid`.
    public var person1: PersonID

    /// The second endpoint; for `parent-child` the proposed **child**.
    public var person2: PersonID

    /// Every record that supports this, in document order — at least one.
    public var evidence: [RelationshipEvidence]

    public init(
        type: RelationshipType,
        person1: PersonID,
        person2: PersonID,
        evidence: [RelationshipEvidence]
    ) {
        self.type = type
        self.person1 = person1
        self.person2 = person2
        self.evidence = evidence
    }

    /// The links a promoted relationship cites: both endpoints' links from every
    /// supporting record, de-duplicated, in the order the evidence was read.
    public var supportedByLinks: [EvidenceLinkID] {
        var seen: Set<String> = []
        var links: [EvidenceLinkID] = []
        for item in evidence {
            for link in [item.person1Link, item.person2Link] where seen.insert(link.raw).inserted {
                links.append(link)
            }
        }
        return links
    }

    /// Whether any supporting record states the edge outright, rather than the roles
    /// implying it — the distinction a reviewer reads before agreeing.
    public var isStated: Bool { evidence.contains { $0.basis == .stated } }

    /// The subject a decline is stored under (45m). The two vocabularies name the same
    /// relations identically, by design, so this is a parse and not a translation.
    public var dismissalSubject: DismissalSubject {
        DismissalSubject(parsing: type.rawValue)
    }
}

/// One record's worth of support for a suggested relationship: which document, which two
/// mentions on it, the confirmed links that resolve them, and whether the record stated the
/// relation or its roles implied it.
public struct RelationshipEvidence: Sendable, Equatable {
    public var artifact: ArtifactID
    public var basis: RelationshipBasis
    /// The `localRef` standing at `person1`'s end on this record.
    public var person1Ref: String
    public var person2Ref: String
    public var person1Link: EvidenceLinkID
    public var person2Link: EvidenceLinkID

    public init(
        artifact: ArtifactID,
        basis: RelationshipBasis,
        person1Ref: String,
        person2Ref: String,
        person1Link: EvidenceLinkID,
        person2Link: EvidenceLinkID
    ) {
        self.artifact = artifact
        self.basis = basis
        self.person1Ref = person1Ref
        self.person2Ref = person2Ref
        self.person1Link = person1Link
        self.person2Link = person2Link
    }
}

/// How a record supports a relationship — **the reasoning, in the absence of a score**.
///
/// A closed vocabulary and not a stored one: it is computed on every read and never written
/// to disk, so there is no unknown value to preserve.
public enum RelationshipBasis: String, Sendable, Equatable {
    /// The record states the edge outright (`mentionRelationships`, §6.1).
    case stated
    /// The roles on the record imply it, through 45g's star rule.
    case inferredFromRoles
}

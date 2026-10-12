import Foundation
import GeneaLogicModel

/// Merging two concluded persons that describe one human being (slice 45f).
///
/// **This is §2.3's one exception to the no-cascade rule.** Every other removal in the
/// engine deliberately leaves dangles — `removePerson` says so in its own doc comment,
/// and 44g's repair path exists because of it. Merge cannot: the absorbed person is not
/// *gone*, they were never a second person, so every record naming them is still true
/// and has to be repointed rather than orphaned. Leaving the dangles here would turn a
/// correction into damage.
///
/// That inverts the undo shape too. The snapshot ping-pong every other conclusions
/// mutation uses cannot reverse a rewrite that spans N records, so this file's writes
/// return a ``MergeDecision`` carrying the **before**-state of everything they touched,
/// and ``Archive/revertMerge(_:)`` puts it all back. It is `ReviewDecision`'s pattern
/// (45c) one step up in blast radius.
///
/// **Nothing new is minted.** A merge repoints, unions and deletes; it creates no uid.
/// That is what makes the revert a pure restore, with nothing to un-create.
extension Archive {

    // MARK: - mergePersons

    /// Merges `absorbed` into `survivor`: every record naming the absorbed person is
    /// repointed at the survivor, the two records' names and facts are union'd, and the
    /// absorbed sidecar is removed.
    ///
    /// The survivor keeps its own `uid` and `provenance` — it is the same concluded
    /// identity, and a "merged from …" audit field would be a format change (45f's spec
    /// puts one out of scope). `identifierURI` falls back to the absorbed person's when
    /// the survivor has none.
    ///
    /// - Returns: A ``MergeDecision`` describing everything the cascade did, which
    ///   ``revertMerge(_:)`` consumes and both front ends report.
    /// - Throws: `ArchiveError.personNotFound` if either person is missing;
    ///   `ArchiveError.cannotMergePersonIntoItself` if they are the same person.
    @discardableResult
    public func mergePersons(
        _ absorbedID: PersonID, into survivorID: PersonID
    ) throws -> MergeDecision {
        try withState { _, index in
            guard absorbedID != survivorID else {
                throw ArchiveError.cannotMergePersonIntoItself(survivorID)
            }
            guard let survivorBefore = try index.person(survivorID) else {
                throw ArchiveError.personNotFound(survivorID)
            }
            guard let absorbed = try index.person(absorbedID) else {
                throw ArchiveError.personNotFound(absorbedID)
            }

            let links = try index.allLinks()
            let relationships = try index.allRelationships()
            let dismissals = try index.allDismissals()

            let linkPlan = Self.planLinks(links, absorbing: absorbedID, into: survivorID)
            let relationshipPlan = Self.planRelationships(
                relationships, absorbing: absorbedID, into: survivorID,
                repointing: linkPlan.repointed)
            let dismissalPlan = Self.planDismissals(
                dismissals, absorbing: absorbedID, into: survivorID)

            // The merged survivor. Citations are repointed *before* the union so two
            // facts that differ only by a collapsed link uid dedupe as the duplicates
            // they are.
            var survivor = survivorBefore
            survivor.names = Self.union(
                survivorBefore.names, absorbed.names)
            survivor.facts = Self.unionFacts(
                Self.repointing(survivorBefore.facts, using: linkPlan.repointed),
                Self.repointing(absorbed.facts, using: linkPlan.repointed))
            survivor.identifierURI = survivorBefore.identifierURI ?? absorbed.identifierURI

            // Every *other* person can cite a collapsed link too — `supportedByLinks`
            // names a link uid, and nothing scopes it to the person the link is about.
            var rewrittenPersons: [Person] = []
            var repointedPersons: [Person] = []
            if !linkPlan.repointed.isEmpty {
                for person in try index.allPersons().sorted(by: { $0.uid.raw < $1.uid.raw })
                where person.uid != survivorID && person.uid != absorbedID {
                    var updated = person
                    updated.facts = Self.repointing(person.facts, using: linkPlan.repointed)
                    if updated != person {
                        rewrittenPersons.append(person)
                        repointedPersons.append(updated)
                    }
                }
            }

            // --- Writes, in the order that survives a failure between any two of them.
            //
            // Write everything that stays, *then* delete what it displaced — 45d's
            // lesson, for the same reason: `withState` has no rollback, so a throw after
            // a delete destroys a record the returned decision would have named. The
            // failure window here holds a *superset* of the truth (a link on both
            // persons, a duplicate edge), which is visible and repairable; the reverse
            // order loses records with nothing left to report them.
            //
            // And none of it starts until every record it touches is known not to
            // have drifted (slice 68, fork b) — `applyCascade` checks the same lists
            // it executes.
            try applyCascade(
                writing: linkPlan.relinked.map(ConclusionWrite.link)
                    + relationshipPlan.written.map(ConclusionWrite.relationship)
                    + repointedPersons.map(ConclusionWrite.person)
                    + dismissalPlan.written.map(ConclusionWrite.dismissal)
                    + [.person(survivor)],
                removing: linkPlan.dropped.map { .link($0.uid) }
                    + relationshipPlan.dropped.map { .relationship($0.uid) }
                    + dismissalPlan.dropped.map { .dismissal($0.uid) }
                    + [.person(absorbedID)],
                index: index)

            return MergeDecision(
                survivor: survivor,
                survivorBefore: survivorBefore,
                absorbed: absorbed,
                relinkedLinks: linkPlan.relinkedBefore,
                droppedLinks: linkPlan.dropped,
                rewrittenRelationships: relationshipPlan.writtenBefore,
                droppedRelationships: relationshipPlan.dropped,
                rewrittenDismissals: dismissalPlan.writtenBefore,
                droppedDismissals: dismissalPlan.dropped,
                rewrittenPersons: rewrittenPersons,
                strandedCitations: try strandedCitations(
                    naming: Set(linkPlan.dropped.map(\.uid))
                        .subtracting(linkPlan.repointed.keys),
                    index: index))
        }
    }

    // MARK: - revertMerge

    /// Undoes a merge, restoring every record ``mergePersons(_:into:)`` touched to the
    /// state named in `decision`.
    ///
    /// A pure restore: the merge minted nothing, so there is nothing to un-create — each
    /// step rewrites a sidecar its uid already identifies and re-upserts the index row,
    /// exactly as `restorePerson`/`restoreLink` do. That also makes it idempotent, so a
    /// half-applied revert can simply be run again.
    public func revertMerge(_ decision: MergeDecision) throws {
        try withState { _, index in
            // All or nothing, like the merge it undoes (slice 68, fork b).
            try applyCascade(
                writing: [.person(decision.absorbed), .person(decision.survivorBefore)]
                    + decision.rewrittenPersons.map(ConclusionWrite.person)
                    + (decision.relinkedLinks + decision.droppedLinks).map(ConclusionWrite.link)
                    + (decision.rewrittenRelationships + decision.droppedRelationships)
                    .map(ConclusionWrite.relationship)
                    + (decision.rewrittenDismissals + decision.droppedDismissals)
                    .map(ConclusionWrite.dismissal),
                removing: [],
                index: index)
        }
    }

    // MARK: - Link planning

    /// What the cascade will do to the evidence links, decided before anything is
    /// written.
    struct LinkPlan {
        /// Links to write, already repointed at the survivor.
        var relinked: [EvidenceLink] = []
        /// The same links as they were, for the revert.
        var relinkedBefore: [EvidenceLink] = []
        /// Links removed because the merge put two verdicts on one triple.
        var dropped: [EvidenceLink] = []
        /// Dropped link → the link that now says the same thing, for `supportedByLinks`.
        var repointed: [EvidenceLinkID: EvidenceLinkID] = [:]
    }

    /// Repoints every link naming the absorbed person and resolves the collisions that
    /// causes.
    ///
    /// **A pair holds one verdict** (45c), and the merge is what can put two on one
    /// `(artifact, localRef, person)` triple: a confirmation from one person and a
    /// rejection tombstone from the other. The confirmation wins. The tombstone said
    /// *this mention is not that person*, and the merge asserts the two persons are one
    /// — it is the later and more specific human judgement, so it settles the
    /// contradiction it created.
    ///
    /// **Tombstones are repointed like anything else** when they don't collide. 45c's
    /// rule is *does this surface mean citation, or record on disk*, and this one means
    /// records on disk: a tombstone left naming the absorbed uid would dangle, and worse,
    /// would stop foreclosing the pair it was written to foreclose.
    ///
    /// Two links that say the *same* thing — both confirmations — collapse to the lower
    /// uid, and the dropped one's citations are repointed onto it (``LinkPlan/repointed``)
    /// rather than stranded: they assert the identical fact, so the citation is still
    /// true, and stranding it would destroy a `supportedByLinks` entry the user never
    /// touched. Every *other* drop reports its strands instead of being quietly repaired.
    static func planLinks(
        _ links: [EvidenceLink], absorbing absorbedID: PersonID, into survivorID: PersonID
    ) -> LinkPlan {
        var plan = LinkPlan()

        // Grouped by the triple the links will share *after* the rewrite; a group of one
        // has no collision to resolve.
        let involved =
            links
            .filter { $0.personUid == absorbedID || $0.personUid == survivorID }
            .sorted { $0.uid.raw < $1.uid.raw }
        let groups = Dictionary(grouping: involved) {
            MentionRef(artifact: $0.artifactUid, localRef: $0.personMentionRef)
        }

        for key in groups.keys.sorted(by: {
            ($0.artifact.raw, $0.localRef) < ($1.artifact.raw, $1.localRef)
        }) {
            let group = groups[key] ?? []
            guard let kept = Self.survivingVerdict(among: group, keeping: survivorID) else {
                continue
            }

            // **The merge only resolves the collisions it causes** — the same rule
            // `planRelationships` follows, and it has to be stated the same way here.
            // What the merge creates is a collision *across* the two persons: the verdict
            // that wins stands, and the losing **side** goes. Duplicates within one side
            // are an anomaly that already existed (45c's one-verdict rule says they
            // shouldn't, but a concurrent writer can leave one), and deleting those would
            // remove records for reasons unrelated to the operation the user asked for,
            // inside a single undo step labelled "merge". A group that is all one side has
            // no cross-collision at all, so nothing is dropped.
            //
            // Note this still drops *several* losers when it should: if the absorbed
            // person holds the winning confirmation and the survivor holds two tombstones,
            // each tombstone genuinely collides with that confirmation.
            let losingSide: PersonID = kept.personUid == survivorID ? absorbedID : survivorID
            var droppedHere: Set<EvidenceLinkID> = []
            for link in group where link.personUid == losingSide {
                plan.dropped.append(link)
                droppedHere.insert(link.uid)
                // Only a confirmation collapsing into a confirmation is the *same*
                // assertion. A dropped tombstone is a different claim, and repointing a
                // citation onto the confirmation that replaced it would silently turn a
                // "no" into evidence.
                if !link.isRejection && !kept.isRejection {
                    plan.repointed[link.uid] = kept.uid
                }
            }

            // **Every surviving link naming the absorbed person is repointed**, not just
            // the winning verdict. When the survivor's side loses, the absorbed person can
            // keep more than one link on this triple — its own pre-existing duplicate,
            // which the rule above deliberately leaves alone — and the absorbed record is
            // about to be deleted, so anything still naming it would dangle.
            for link in group
            where link.personUid == absorbedID && !droppedHere.contains(link.uid) {
                var relinked = link
                relinked.personUid = survivorID
                plan.relinkedBefore.append(link)
                plan.relinked.append(relinked)
            }
        }

        return plan
    }

    /// Which of several links on one triple states the verdict that stands.
    ///
    /// Preference order is 45c's: a human confirmation outranks a human rejection, and
    /// both outrank a stray `.machineSuggested` — an unreviewed guess (which GeneaLogic
    /// never writes) does not outlive a human verdict on its pair.
    ///
    /// **Within a status, the survivor's own record is kept** — not the older one. The
    /// obvious tie-break, lowest uid, silently isn't one: `UUIDv7` here is explicitly not
    /// monotonic within a millisecond (see `UUIDv7.swift`), so two records created in the
    /// same instant — a script, a test, an app minting two things in one pass — sort by
    /// their *random* bits, and which of the user's records survived would be a coin flip.
    /// Keeping the survivor's is both stable and the answer that matches what was asked
    /// for: the user named which person to keep, so their record is the one folded *into*.
    /// Lowest uid remains the last resort, when neither side is the survivor's.
    private static func survivingVerdict(
        among group: [EvidenceLink], keeping survivorID: PersonID
    ) -> EvidenceLink? {
        func best(_ status: LinkReviewStatus) -> EvidenceLink? {
            let candidates = group.filter { $0.reviewStatus == status }
            return candidates.first { $0.personUid == survivorID }
                ?? candidates.min { $0.uid.raw < $1.uid.raw }
        }
        return best(.humanConfirmed) ?? best(.humanRejected)
            ?? group.min { $0.uid.raw < $1.uid.raw }
    }

    // MARK: - Relationship planning

    /// What the cascade will do to the relationships.
    struct RelationshipPlan {
        /// Relationships to write (repointed endpoints, and/or facts union'd in).
        var written: [Relationship] = []
        /// The same relationships as they were, for the revert.
        var writtenBefore: [Relationship] = []
        /// Self-loops and collapsed duplicates.
        var dropped: [Relationship] = []
    }

    /// Repoints relationship endpoints, drops the self-loops that creates, and collapses
    /// the edges the merge duplicates.
    ///
    /// Both cleanups exist because the alternative is drawn: a relationship between the
    /// two merged persons becomes a person married to themselves, which the tree
    /// projection would have to render, and two identical parent-child edges show the
    /// same relative twice in the Relatives list. Neither carries anything the survivor
    /// doesn't already have.
    ///
    /// **A collapsed duplicate's facts and citations are union'd into the kept edge**,
    /// not discarded — a marriage date recorded on one of the two edges is a fact about
    /// the couple, and the edge it happened to be filed on is an accident of which
    /// duplicate the user was looking at.
    ///
    /// Identity is `(type, endpoints)`, with **`couple` compared unordered** (§4.5: its
    /// endpoints are symmetric) and everything else ordered — `parent-child` reversed is
    /// a different claim, and an open-vocabulary type this build has never heard of gets
    /// the conservative reading rather than a guess about its symmetry.
    static func planRelationships(
        _ relationships: [Relationship],
        absorbing absorbedID: PersonID,
        into survivorID: PersonID,
        repointing repointed: [EvidenceLinkID: EvidenceLinkID]
    ) -> RelationshipPlan {
        var plan = RelationshipPlan()

        /// The identity two edges collide on.
        struct EdgeKey: Hashable {
            var type: RelationshipType
            var endpoints: [String]
        }
        func key(of relationship: Relationship) -> EdgeKey {
            let pair = [relationship.person1Uid.raw, relationship.person2Uid.raw]
            return EdgeKey(
                type: relationship.type,
                endpoints: relationship.type == .couple ? pair.sorted() : pair)
        }

        // Everything the merge can touch, **the survivor's own edges first** — so a
        // collapse keeps the record belonging to the person the user chose to keep, and
        // folds the absorbed one's facts into it. Ordering by uid instead would decide it
        // by coin flip for edges created in the same millisecond, since this archive's
        // `UUIDv7` is deliberately not monotonic below that resolution (see
        // `survivingVerdict` for the same reasoning on links). Uid orders within each
        // group, so the pass is still deterministic.
        let candidates =
            relationships
            .filter {
                $0.involves(absorbedID) || $0.involves(survivorID)
                    || $0.supportedByLinks.contains { repointed[$0] != nil }
                    || $0.facts.contains { fact in
                        fact.supportedByLinks.contains { repointed[$0] != nil }
                    }
            }
            .sorted {
                ($0.involves(absorbedID) ? 1 : 0, $0.uid.raw)
                    < ($1.involves(absorbedID) ? 1 : 0, $1.uid.raw)
            }

        var keptByKey: [EdgeKey: Int] = [:]  // index into `plan.written`
        var keptWasRepointed: [EdgeKey: Bool] = [:]
        var before: [RelationshipID: Relationship] = [:]

        for original in candidates {
            // **Only a relationship the merge actually moved may be dropped by it.** A
            // self-loop or a duplicate edge among the survivor's *own* relationships
            // predates this operation, and removing it here would delete a record for
            // reasons the user never asked about, inside an undo step labelled "merge".
            // Those are `findDanglingReferences`/editing territory.
            let repointedEndpoint = original.involves(absorbedID)

            var updated = original
            if updated.person1Uid == absorbedID { updated.person1Uid = survivorID }
            if updated.person2Uid == absorbedID { updated.person2Uid = survivorID }
            updated.supportedByLinks = Self.repointing(updated.supportedByLinks, using: repointed)
            updated.facts = Self.repointing(updated.facts, using: repointed)

            // A person is not their own parent or spouse. Reachable exactly when the two
            // merged persons were related to each other, which is the archive a merge is
            // fixing.
            if repointedEndpoint, updated.person1Uid == updated.person2Uid {
                plan.dropped.append(original)
                continue
            }

            let edge = key(of: updated)
            if let existing = keptByKey[edge], repointedEndpoint || keptWasRepointed[edge] == true {
                plan.written[existing].facts = Self.unionFacts(
                    plan.written[existing].facts, updated.facts)
                plan.written[existing].supportedByLinks = Self.union(
                    plan.written[existing].supportedByLinks, updated.supportedByLinks)
                plan.dropped.append(original)
            } else if keptByKey[edge] == nil {
                keptByKey[edge] = plan.written.count
                keptWasRepointed[edge] = repointedEndpoint
                plan.written.append(updated)
                before[original.uid] = original
            } else {
                // A pre-existing duplicate among the survivor's own edges: left exactly as
                // it was, and not even rewritten.
                before[original.uid] = original
                plan.written.append(updated)
            }
        }

        // Only the edges that actually changed are worth a write — the sweep above
        // deliberately includes untouched relationships so a collapse can pick the older
        // of the two, and rewriting one that ended up identical would put a pointless
        // record in the revert.
        var written: [Relationship] = []
        var writtenBefore: [Relationship] = []
        for relationship in plan.written {
            guard let original = before[relationship.uid], original != relationship else {
                continue
            }
            written.append(relationship)
            writtenBefore.append(original)
        }
        plan.written = written
        plan.writtenBefore = writtenBefore
        return plan
    }

    // MARK: - Dismissal planning

    /// What the cascade will do to the dismissals (slice 45m).
    struct DismissalPlan {
        /// Dismissals to write, already repointed at the survivor.
        var written: [Dismissal] = []
        /// The same records as they were, for the revert.
        var writtenBefore: [Dismissal] = []
        /// Self-referential dismissals and collapsed duplicates.
        var dropped: [Dismissal] = []
    }

    /// Repoints dismissals naming the absorbed person, drops the self-referential records
    /// that creates, and collapses the duplicates.
    ///
    /// **The self-referential case is the interesting one, and it is the user contradicting
    /// themselves.** A dismissal saying *these two are not the same person* becomes, after
    /// a merge of exactly those two, *this person is not themselves*. That is not a record
    /// to keep or to repair — it is a judgement the user has just overruled with a later
    /// and more specific one, the same shape as 45c's confirmation beating a tombstone. So
    /// it is dropped, and **reported** (``MergeDecision/contradictedDismissals``): silently
    /// deleting the earlier judgement would be the one cascade effect a user could not see.
    ///
    /// The same holds for the relationship subjects, which is why the rule is written over
    /// the pair rather than over `same-person` alone: merging two persons the user said
    /// were not a couple leaves "this person is not their own spouse", equally meaningless.
    ///
    /// **Only what the merge moved may be dropped by it** — the rule `planLinks` and
    /// `planRelationships` both follow. A pre-existing self-referential dismissal (which
    /// `dismiss` refuses to create, but a hand-edited archive can hold) is left exactly as
    /// it is: removing it here would delete a record for reasons unrelated to the operation
    /// the user asked for, inside one undo step labelled "merge".
    static func planDismissals(
        _ dismissals: [Dismissal], absorbing absorbedID: PersonID, into survivorID: PersonID
    ) -> DismissalPlan {
        var plan = DismissalPlan()

        // The survivor's own records first, so a collapse keeps the one belonging to the
        // person the user chose to keep; uid orders within each group, so the pass stays
        // deterministic without depending on `UUIDv7` being monotonic (see
        // `survivingVerdict` for why lowest-uid is not a tie-break here).
        let candidates =
            dismissals
            .filter { $0.involves(absorbedID) }
            .sorted { $0.uid.raw < $1.uid.raw }

        var kept: [Dismissal] = dismissals.filter { !$0.involves(absorbedID) }

        for original in candidates {
            var updated = original
            if updated.person1Uid == absorbedID { updated.person1Uid = survivorID }
            if updated.person2Uid == absorbedID { updated.person2Uid = survivorID }

            // *X is not X* — the contradiction described above.
            if updated.person1Uid == updated.person2Uid {
                plan.dropped.append(original)
                continue
            }

            // Repointing can restate something already on record: the user declined the
            // same claim against both duplicates. One judgement, one record.
            if kept.contains(where: { $0.declinesSameAs(updated) }) {
                plan.dropped.append(original)
                continue
            }

            // Canonical order is a property of the stored pair, and repointing can break
            // it — so it is re-applied here rather than assumed to survive the rewrite.
            let (first, second) = Dismissal.canonicalPair(
                updated.person1Uid, updated.person2Uid, subject: updated.subject)
            updated.person1Uid = first
            updated.person2Uid = second

            kept.append(updated)
            plan.written.append(updated)
            plan.writtenBefore.append(original)
        }

        return plan
    }

    // MARK: - Unions and citation repointing

    /// Appends the values of `absorbed` that `survivor` doesn't already hold, in order.
    ///
    /// Exact equality, deliberately: two names that differ in any field are two
    /// assertions, and a merge is not the place to decide that "Chana" and "Anna" are the
    /// same name. Contradictions survive the merge visible, which is the honest state —
    /// the user prunes them from the editors that already exist.
    static func union<T: Equatable>(_ survivor: [T], _ absorbed: [T]) -> [T] {
        survivor + absorbed.filter { !survivor.contains($0) }
    }

    /// Folds `absorbed`'s facts into `survivor`'s, treating **the same claim from two
    /// records as one conclusion with two citations**.
    ///
    /// A `PersonFact` is a claim (type + date + place + value) plus the evidence behind it
    /// (`supportedByLinks`), and those two halves merge differently. Exact equality —
    /// which is right for names — reads a differing citation list as a differing
    /// assertion, and that is backwards: **agreeing about a birth is what corroboration
    /// looks like**, and it is the *normal* shape here, because 42c's *record a fact from
    /// linked evidence* stamps every fact with the link it came from. Two duplicate
    /// persons built from their own sources therefore always disagree on the citations
    /// while agreeing on everything a reader can see, and the merge produced two
    /// identical-looking rows (found by hand-testing 45f). It is also what
    /// `planRelationships` already does when it collapses a duplicate edge — the same
    /// concept deserved the same answer.
    ///
    /// The **claim** must still match exactly: `1881` and `1881~` stay two facts, because
    /// deciding those are the same claim is a judgement about the evidence, not about
    /// bookkeeping.
    ///
    /// Only the absorbed record's facts are folded. Two identical-claim facts the survivor
    /// *already* held are an anomaly this operation didn't cause and doesn't adopt — the
    /// same rule the relationship and link cleanups follow.
    static func unionFacts(_ survivor: [PersonFact], _ absorbed: [PersonFact]) -> [PersonFact] {
        /// Everything about a fact except the evidence for it.
        func claim(_ fact: PersonFact) -> [String?] {
            [fact.type.rawValue, fact.date, fact.place, fact.value]
        }

        var merged = survivor
        for fact in absorbed {
            if let existing = merged.firstIndex(where: { claim($0) == claim(fact) }) {
                merged[existing].supportedByLinks = union(
                    merged[existing].supportedByLinks, fact.supportedByLinks)
            } else {
                merged.append(fact)
            }
        }
        return merged
    }

    /// Rewrites `supportedByLinks` entries naming a collapsed link to name the link that
    /// replaced it, dropping the duplicates that creates.
    static func repointing(
        _ supports: [EvidenceLinkID], using repointed: [EvidenceLinkID: EvidenceLinkID]
    ) -> [EvidenceLinkID] {
        var seen: Set<EvidenceLinkID> = []
        return supports.map { repointed[$0] ?? $0 }.filter { seen.insert($0).inserted }
    }

    static func repointing(
        _ facts: [PersonFact], using repointed: [EvidenceLinkID: EvidenceLinkID]
    ) -> [PersonFact] {
        guard !repointed.isEmpty else { return facts }
        return facts.map {
            var fact = $0
            fact.supportedByLinks = repointing(fact.supportedByLinks, using: repointed)
            return fact
        }
    }
}

// MARK: - MergeDecision

/// What a merge actually did — the return of ``Archive/mergePersons(_:into:)``.
///
/// Every array holds **before**-state, which is what makes ``Archive/revertMerge(_:)``
/// a pure restore. The one exception is ``survivor``, the merged record as written, so a
/// caller can show the result without re-reading it.
///
/// It is also the report. A cascade that silently rewrote a dozen records would be the
/// engine's least legible operation; naming each one lets the CLI print it and the app
/// surface it beside undo, the way 45d's displacement report does for a superseded link.
public struct MergeDecision: Sendable, Equatable {
    /// The survivor as it now stands — names and facts union'd, citations repointed.
    public var survivor: Person

    /// The survivor as it was, for the revert.
    public var survivorBefore: Person

    /// The removed person, uid-faithful, for the revert.
    public var absorbed: Person

    /// Links repointed onto the survivor, **as they were**.
    public var relinkedLinks: [EvidenceLink]

    /// Links removed because the merge put two verdicts on one triple — a tombstone
    /// beaten by a confirmation, or a duplicate confirmation collapsed into the older
    /// one.
    public var droppedLinks: [EvidenceLink]

    /// Relationships the merge rewrote (repointed endpoint, or facts union'd in from a
    /// collapsed duplicate), **as they were**.
    public var rewrittenRelationships: [Relationship]

    /// Relationships removed: self-loops between the two merged persons, and duplicate
    /// edges collapsed into an older identical one.
    public var droppedRelationships: [Relationship]

    /// Dismissals repointed onto the survivor (45m), **as they were**.
    public var rewrittenDismissals: [Dismissal]

    /// Dismissals removed: the ones the merge made self-referential, and duplicates
    /// collapsed into a record that already said the same thing. See
    /// ``contradictedDismissals`` for the half worth telling the user about.
    public var droppedDismissals: [Dismissal]

    /// Other persons whose `supportedByLinks` citations were repointed onto a surviving
    /// link, **as they were**. Usually empty.
    public var rewrittenPersons: [Person]

    /// `supportedByLinks` citations left dangling by a dropped link, in the shape
    /// `findDanglingReferences()` reports. Empty unless a fact cited a link that had no
    /// equivalent to be repointed onto.
    public var strandedCitations: [DanglingReference]

    public init(
        survivor: Person,
        survivorBefore: Person,
        absorbed: Person,
        relinkedLinks: [EvidenceLink] = [],
        droppedLinks: [EvidenceLink] = [],
        rewrittenRelationships: [Relationship] = [],
        droppedRelationships: [Relationship] = [],
        rewrittenDismissals: [Dismissal] = [],
        droppedDismissals: [Dismissal] = [],
        rewrittenPersons: [Person] = [],
        strandedCitations: [DanglingReference] = []
    ) {
        self.survivor = survivor
        self.survivorBefore = survivorBefore
        self.absorbed = absorbed
        self.relinkedLinks = relinkedLinks
        self.droppedLinks = droppedLinks
        self.rewrittenRelationships = rewrittenRelationships
        self.droppedRelationships = droppedRelationships
        self.rewrittenDismissals = rewrittenDismissals
        self.droppedDismissals = droppedDismissals
        self.rewrittenPersons = rewrittenPersons
        self.strandedCitations = strandedCitations
    }

    // MARK: - Reporting

    /// The relationships whose **endpoint moved** onto the survivor.
    ///
    /// Not the same set as ``rewrittenRelationships``, which also holds edges the merge
    /// touched only to update a `supportedByLinks` citation that named a collapsed link —
    /// and those can belong to two people who have nothing to do with this merge. Both
    /// front ends report "moved onto ⟨survivor⟩", and saying that about a bystanders'
    /// marriage would be false, so the distinction is drawn **here** rather than
    /// re-derived (differently) at each call site.
    public var repointedRelationships: [Relationship] {
        rewrittenRelationships.filter { $0.involves(absorbed.uid) }
    }

    /// The dismissals the merge **contradicted**: the user had recorded that these two
    /// persons were not the same (or not a couple, or not parent and child), and merging
    /// them says otherwise.
    ///
    /// Distinguished here rather than at each call site, for the reason
    /// ``repointedRelationships`` is: ``droppedDismissals`` also holds records collapsed
    /// because a duplicate already said the same thing, which is bookkeeping and not worth
    /// a sentence. A dropped record naming **both** merged persons is the contradiction —
    /// the only one of the cascade's effects that reverses an earlier human judgement, so
    /// it is the one a front end must not swallow.
    public var contradictedDismissals: [Dismissal] {
        droppedDismissals.filter { $0.involves(absorbed.uid) && $0.involves(survivor.uid) }
    }

    /// How many records were rewritten *only* to follow a citation onto the link that
    /// replaced a collapsed duplicate — relationships and other persons alike. These moved
    /// nothing and belong to nobody in particular; they are worth a count, not a claim.
    public var citationFollowingRewrites: Int {
        rewrittenRelationships.count - repointedRelationships.count + rewrittenPersons.count
    }
}

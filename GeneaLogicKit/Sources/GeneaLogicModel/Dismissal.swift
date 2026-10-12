/// A human's recorded *no* about a suggestion over two concluded persons — "these two
/// are not the same person", "this record does not make her his mother" (slice 45m).
///
/// Serialized as `conclusions/dismissals/<UID>.json`. Documented in spec §6.6.
///
/// ## Why it is a record
///
/// The same reason a rejection tombstone is one (45c): **suggestions are ephemeral**, so
/// nothing about declining one survives closing the queue, and the next sweep recomputes
/// the identical score and offers the identical pair, forever. What makes that intolerable
/// rather than merely annoying is *where* the pairs land — the Review section is a
/// work-owed surface whose meaning depends on being able to reach empty, so two genuinely
/// distinct same-named relatives would hold the whole section permanently non-empty.
///
/// It could not be an `EvidenceLink`: there is no mention here to tombstone. It must not
/// be a `Relationship` with an open type either — *not the same person* is an identity
/// assertion, not a family relation, and every consumer of `relationships()` (Tree,
/// Relatives, `personView`'s partner/parent projection) would have to learn to filter it,
/// which is the misfiling 45h corrected. A `distinctFrom: [PersonID]` field on `Person`
/// stores each edge twice and lets the halves disagree, the shape 45k's fork rejected.
///
/// ## One record type, a typed subject
///
/// Two suggestion lanes can be declined over the same pair of ids, and they mean different
/// things: 45j proposes that two persons are one, 45l proposes a relationship between
/// them. So the subject is carried, and declining a `parent-child` suggestion leaves a
/// `couple` suggestion for the same pair entirely open.
///
/// ## What it deliberately does not carry
///
/// **No status field, and no fourth verb.** A dismissal is reversed by *deleting* it — the
/// pair returns to the queue and no state is left behind, exactly as `unlink()` reverses a
/// rejection tombstone. A retraction tombstone over a dismissal would be a tombstone of a
/// tombstone, and every read applying the skip rule would have to filter it.
public struct Dismissal: Codable, Sendable, Equatable {
    /// Type-prefixed UUIDv7 identifier, e.g. `"DSM-018f…"`.
    public var uid: DismissalID

    /// Schema version for migration support.
    public var schemaVersion: String

    /// What was declined (spec §7, open).
    public var subject: DismissalSubject

    /// The first person. For a **directional** subject (`parent-child`) this is the
    /// proposed *parent* — §4.5's convention, so the direction means one thing across
    /// every layer. For a symmetric subject the pair is stored in canonical uid order
    /// (`person1Uid < person2Uid`), which is what makes one dismissal one record.
    public var person1Uid: PersonID

    /// The second person; for `parent-child` the proposed **child**.
    public var person2Uid: PersonID

    /// The reasoning the user was looking at when they declined, when the suggestion had
    /// any — the matcher's decomposed breakdown, stored for the reason a rejection
    /// tombstone stores one: declining a *strong* candidate is where the matcher is wrong
    /// in a way worth understanding, and discarding the score erases exactly that.
    ///
    /// **Optional, because not every declinable suggestion is scored.** 45l's suggested
    /// relationships are read off a stated `mentionRelationships` edge plus two confirmed
    /// links; they have no breakdown, and inventing one would be a lie in the shape of a
    /// number.
    public var match: MatchBreakdown?

    /// The rolled-up confidence of ``match``, when there was one. Absent together with it.
    public var aggregateConfidence: Int?

    /// Identifier of the human who declined, or `nil`. A dismissal is a human act by
    /// definition — GeneaLogic never writes one from a machine — so there is no
    /// `createdBy` question to answer here, only *which* human.
    public var dismissedBy: String?

    /// ISO 8601 timestamp of the dismissal, or `nil`.
    public var dismissedAt: String?

    /// Provenance of this record.
    public var provenance: Provenance

    public init(
        uid: DismissalID,
        subject: DismissalSubject,
        person1Uid: PersonID,
        person2Uid: PersonID,
        match: MatchBreakdown? = nil,
        aggregateConfidence: Int? = nil,
        dismissedBy: String? = nil,
        dismissedAt: String? = nil,
        provenance: Provenance
    ) {
        self.uid = uid
        self.schemaVersion = SchemaVersion.current
        self.subject = subject
        self.person1Uid = person1Uid
        self.person2Uid = person2Uid
        self.match = match
        self.aggregateConfidence = aggregateConfidence
        self.dismissedBy = dismissedBy
        self.dismissedAt = dismissedAt
        self.provenance = provenance
    }
}

// MARK: - Pair identity

extension Dismissal {

    /// Whether `person` is one of the two endpoints.
    public func involves(_ person: PersonID) -> Bool {
        person1Uid == person || person2Uid == person
    }

    /// The endpoint opposite `person`, or `nil` when `person` is not an endpoint at all.
    /// A self-referential dismissal returns that same person.
    public func other(from person: PersonID) -> PersonID? {
        if person1Uid == person { return person2Uid }
        if person2Uid == person { return person1Uid }
        return nil
    }

    /// Whether this record declines the **same claim** as `subject` over `person1`/
    /// `person2` — the comparison "one dismissal is one record" needs, and the one `==`
    /// cannot make.
    ///
    /// For a symmetric subject the reversed pair is the *same* statement written the other
    /// way round; equality sees two different values, and a writer guarding duplicates
    /// with `==` alone stores both. That is 45k's shipped bug restated, found by hand-test
    /// after its tests passed, so the rule lives here rather than at each call site.
    public func declines(
        _ subject: DismissalSubject, between person1: PersonID, and person2: PersonID
    ) -> Bool {
        guard self.subject == subject else { return false }
        if subject.isSymmetric {
            return (person1Uid == person1 && person2Uid == person2)
                || (person1Uid == person2 && person2Uid == person1)
        }
        return person1Uid == person1 && person2Uid == person2
    }

    /// Whether this record declines the same claim as `other`.
    public func declinesSameAs(_ other: Dismissal) -> Bool {
        declines(other.subject, between: other.person1Uid, and: other.person2Uid)
    }

    /// The endpoints in the order this subject stores them: as given for a directional
    /// subject, lower uid first for a symmetric one.
    ///
    /// Canonicalizing at the **write** boundary is what lets every read compare pairs
    /// directly. It is deliberately not applied to a directional subject, where swapping
    /// the endpoints states the opposite thing.
    public static func canonicalPair(
        _ person1: PersonID, _ person2: PersonID, subject: DismissalSubject
    ) -> (PersonID, PersonID) {
        guard subject.isSymmetric, person2.raw < person1.raw else { return (person1, person2) }
        return (person2, person1)
    }
}

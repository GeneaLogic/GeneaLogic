/// A concluded relationship between two persons (parent-child, couple, etc.).
///
/// Serialized as `conclusions/relationships/<UID>.json` inside the archive.
/// Documented in ARCHITECTURE.md §4.5.
///
/// NOTE (uid typing): All uid fields are `String` in Phase 0. Flagged for Opus review.
///
/// NOTE (person1Uid / person2Uid ordering): The doc does not specify which person
/// is which in a `parent-child` relationship — whether `person1` is always the parent
/// or the child is unspecified. This is modeled as-is (two ordered uid fields) with
/// the semantic ordering left to application convention. Flagged for Opus review.
///
/// NOTE (supportedByLinks): Array of `EvidenceLink` uid strings. Empty array default
/// is used (not nil) since it is an array in the JSON. Flagged for Opus review.
///
/// NOTE (person1Uid / person2Uid convention — resolved slice 43): for a
/// `parent-child` relationship, **`person1Uid` is the parent and `person2Uid` is the
/// child**. The doc originally left this unspecified; the relationships UI needs a
/// fixed convention to render "parent of" / "child of" correctly, so this is now the
/// contract (ARCHITECTURE.md §4.5). For a `couple` the two endpoints are symmetric
/// (no ordering meaning).
public struct Relationship: Codable, Sendable, Equatable {
    /// Type-prefixed UUIDv7 identifier, e.g. `"REL-018f…"`.
    public var uid: RelationshipID

    /// Schema version for migration support.
    public var schemaVersion: String

    /// The type of relationship (parent-child, couple, etc.).
    public var type: RelationshipType

    /// First person in the relationship. For `parent-child`, this is the **parent**.
    public var person1Uid: PersonID

    /// Second person in the relationship. For `parent-child`, this is the **child**.
    public var person2Uid: PersonID

    /// Facts that describe this relationship as an event — e.g. a couple's
    /// **marriage/divorce/annulment** date + place (ARCHITECTURE.md §4.5). A
    /// multi-person event is a fact on the relationship, not duplicated onto each
    /// spouse, so there is one source of truth. Reuses `PersonFact` (GEDCOM X models
    /// Person and Relationship facts with one `Fact` shape); empty for a bare
    /// parent-child link. Added in slice 43 — see `init(from:)` for the additive
    /// (back-compatible) decode.
    public var facts: [PersonFact]

    /// Ids of `EvidenceLink` records that support this relationship.
    public var supportedByLinks: [EvidenceLinkID]

    /// Human-review state of this relationship.
    public var reviewStatus: ReviewStatus

    /// Provenance of this concluded relationship.
    public var provenance: Provenance

    public init(
        uid: RelationshipID,
        type: RelationshipType,
        person1Uid: PersonID,
        person2Uid: PersonID,
        facts: [PersonFact] = [],
        supportedByLinks: [EvidenceLinkID] = [],
        reviewStatus: ReviewStatus,
        provenance: Provenance
    ) {
        self.uid = uid
        self.schemaVersion = SchemaVersion.current
        self.type = type
        self.person1Uid = person1Uid
        self.person2Uid = person2Uid
        self.facts = facts
        self.supportedByLinks = supportedByLinks
        self.reviewStatus = reviewStatus
        self.provenance = provenance
    }

    // Custom coding so `facts` (added slice 43) decodes as `[]` when absent from an
    // older sidecar — an additive, back-compatible format widening (no schema bump;
    // §4.2 EDTF-style superset reasoning). All other keys decode strictly. `encode`
    // always emits `facts`, matching the model's "always emit array keys" style
    // (as `Person.facts` does via synthesized Codable).
    private enum CodingKeys: String, CodingKey {
        case uid, schemaVersion, type, person1Uid, person2Uid, facts
        case supportedByLinks, reviewStatus, provenance
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(RelationshipID.self, forKey: .uid)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        type = try container.decode(RelationshipType.self, forKey: .type)
        person1Uid = try container.decode(PersonID.self, forKey: .person1Uid)
        person2Uid = try container.decode(PersonID.self, forKey: .person2Uid)
        facts = try container.decodeIfPresent([PersonFact].self, forKey: .facts) ?? []
        supportedByLinks = try container.decode([EvidenceLinkID].self, forKey: .supportedByLinks)
        reviewStatus = try container.decode(ReviewStatus.self, forKey: .reviewStatus)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(type, forKey: .type)
        try container.encode(person1Uid, forKey: .person1Uid)
        try container.encode(person2Uid, forKey: .person2Uid)
        try container.encode(facts, forKey: .facts)
        try container.encode(supportedByLinks, forKey: .supportedByLinks)
        try container.encode(reviewStatus, forKey: .reviewStatus)
        try container.encode(provenance, forKey: .provenance)
    }
}

// MARK: - Endpoint accessors

/// Readers for the endpoint conventions, so the meaning of `person1Uid` /
/// `person2Uid` is decoded in **one** place.
///
/// Without these, every consumer re-derives "which endpoint is the parent" from the
/// §4.5 convention by hand — it was open-coded in the app's person detail and fact
/// editor before the tree projection became a third site. A future change to the
/// convention, or a qualified parent-child edge (adoption, step-parenthood), should
/// have exactly one place to update.
extension Relationship {

    /// The **parent** endpoint of a `parent-child` relationship (§4.5: `person1Uid`),
    /// or `nil` for any other relationship type.
    public var parent: PersonID? {
        guard case .parentChild = type else { return nil }
        return person1Uid
    }

    /// The **child** endpoint of a `parent-child` relationship (§4.5: `person2Uid`),
    /// or `nil` for any other relationship type.
    public var child: PersonID? {
        guard case .parentChild = type else { return nil }
        return person2Uid
    }

    /// Whether `person` is one of this relationship's two endpoints.
    public func involves(_ person: PersonID) -> Bool {
        person1Uid == person || person2Uid == person
    }

    /// The endpoint opposite `person`, or `nil` when `person` is not an endpoint at
    /// all. Type-agnostic: for a `couple` the two endpoints are symmetric, and for a
    /// `parent-child` this answers "the other party" without implying which role
    /// either holds — use ``parent`` / ``child`` when the role is what matters.
    ///
    /// A self-referential relationship (both endpoints the same person) returns that
    /// same person.
    public func other(from person: PersonID) -> PersonID? {
        if person1Uid == person { return person2Uid }
        if person2Uid == person { return person1Uid }
        return nil
    }

    /// Whether this record asserts the **same claim** as `type` over `person1`/`person2` —
    /// the comparison `==` cannot make, and the mirror of
    /// ``Dismissal/declines(_:between:and:)`` on the positive side of the same pair.
    ///
    /// Symmetry comes from ``RelationshipType/isSymmetric``, the single owner: for a
    /// `couple` the reversed pair is the same statement written the other way round, while
    /// a `parent-child` compares strictly because reversing it states the opposite thing.
    ///
    /// Added in slice 45l, where two readers arrived at once — the suggestion sweep's
    /// "already asserted" subtraction and `confirm`'s idempotence guard — and a second
    /// hand-rolled copy of the symmetry rule is precisely how the two halves of a symmetric
    /// pair start to disagree.
    public func states(
        _ type: RelationshipType, between person1: PersonID, and person2: PersonID
    ) -> Bool {
        guard self.type == type else { return false }
        if type.isSymmetric {
            return (person1Uid == person1 && person2Uid == person2)
                || (person1Uid == person2 && person2Uid == person1)
        }
        return person1Uid == person1 && person2Uid == person2
    }
}

/// A relationship **the document itself states** between two of the people it names
/// (slice 45k) — "this death certificate says Sidney's parents are these two."
///
/// This is the evidence-layer mirror of `Relationship` (§4.5) and deliberately not the
/// same type: its endpoints are record-local `PersonMention.localRef`s, not `PersonID`s,
/// so it asserts nothing about identity. Two mentions being father and son here is a
/// statement about *this page*; whether either resolves to a concluded person is a
/// separate act, and promoting the edge into `conclusions/` is a separate one again
/// (slice 45l).
///
/// ## Why the edges are stated rather than inferred
///
/// `PersonRole` answers *what part did this person play in the document* — informant,
/// witness, registrar. It cannot also answer *who is whose*: a marriage register names
/// two parties and both sets of parents, and which pair of parents belongs to which
/// spouse is simply not expressible as one tag per person. The matcher's workaround was
/// to read the record as a star around its focal mention and score all four parents
/// best-of (see `Matcher`); that is a shape imposed by a missing edge, not something the
/// record said. So the edge is said.
///
/// ## Shape
///
/// **Not** GEDCOM's `FAM`/`HUSB`/`WIFE`: an edge is one symmetric-or-directional pair,
/// which keeps `couple` genuinely symmetric and needs no second spelling for a same-sex
/// couple. And **one edge is one record** — stored once at the artifact level rather
/// than as a `relatedTo` list on each mention, because storing each edge twice invites
/// the two halves to disagree and makes the archive own a validation-and-repair problem
/// forever.
///
/// Documented in `Artifact.mentionRelationships[]` (spec §6.1).
public struct MentionRelationship: Codable, Sendable, Equatable, Hashable {
    /// What relation the record states, from the same open vocabulary as the concluded
    /// `Relationship.type` — the two layers must name the same relation identically, or
    /// promoting an edge to a conclusion (45l) means translating between vocabularies.
    public var type: RelationshipType

    /// The first endpoint, as a `PersonMention.localRef` on the **same artifact**.
    /// For `parentChild` this is the **parent** — §4.5's convention, unchanged, so the
    /// direction means one thing across both layers.
    public var person1Ref: String

    /// The second endpoint, as a `PersonMention.localRef` on the same artifact.
    /// For `parentChild` this is the **child**. For `couple` the endpoints are
    /// symmetric and carry no ordering meaning.
    public var person2Ref: String

    public init(type: RelationshipType, person1Ref: String, person2Ref: String) {
        self.type = type
        self.person1Ref = person1Ref
        self.person2Ref = person2Ref
    }

    // MARK: - Endpoint accessors

    /// The **parent** endpoint of a `parentChild` edge, or `nil` for any other type —
    /// the mirror of `Relationship.parent`, so the §4.5 direction is decoded in one
    /// place on this side too.
    public var parentRef: String? {
        guard case .parentChild = type else { return nil }
        return person1Ref
    }

    /// The **child** endpoint of a `parentChild` edge, or `nil` for any other type.
    public var childRef: String? {
        guard case .parentChild = type else { return nil }
        return person2Ref
    }

    /// Whether `ref` is one of this edge's two endpoints.
    public func involves(_ ref: String) -> Bool {
        person1Ref == ref || person2Ref == ref
    }

    /// This edge with every `old` endpoint replaced by `new`, direction untouched.
    ///
    /// Exists for the editor that lets you state a relationship **while adding** the
    /// mention at one end of it: the ref is minted at write time, so the edge is staged
    /// against a placeholder and rebound the instant the real ref exists. Kept here
    /// rather than in the UI because it must not become "swap the endpoints" by
    /// accident — `parentChild` means the opposite thing reversed.
    public func rebinding(_ old: String, to new: String) -> MentionRelationship {
        MentionRelationship(
            type: type,
            person1Ref: person1Ref == old ? new : person1Ref,
            person2Ref: person2Ref == old ? new : person2Ref)
    }

    /// Whether this edge states the **same thing** as `other` — the comparison the
    /// format's "one edge is one entry" rule needs, and the one `==` cannot make.
    ///
    /// A `couple` is symmetric, so `(p2, p3)` and `(p3, p2)` are one statement written
    /// two ways; equality sees two different values, and a writer that guards duplicates
    /// with `==` alone will happily store both. That is exactly the "each edge stored
    /// twice, free to disagree" state the artifact-level shape exists to prevent — and
    /// it arises from something as ordinary as removing a partner edge and re-adding it
    /// from the other person's row.
    ///
    /// A `parentChild` is directional and compares strictly: `(a, b)` and `(b, a)` are
    /// contradictory claims, not duplicates, and collapsing them would hide a real
    /// error. An `.unknown` type is treated as directional too, since a vocabulary this
    /// version has never seen is one whose symmetry it cannot know.
    public func statesSameRelationship(as other: MentionRelationship) -> Bool {
        guard type == other.type else { return false }
        if type.isSymmetric {
            return (person1Ref == other.person1Ref && person2Ref == other.person2Ref)
                || (person1Ref == other.person2Ref && person2Ref == other.person1Ref)
        }
        return person1Ref == other.person1Ref && person2Ref == other.person2Ref
    }

    /// The endpoint opposite `ref`, or `nil` when `ref` is not an endpoint. Type-agnostic:
    /// use ``parentRef``/``childRef`` when which end matters. A self-edge (both endpoints
    /// the same mention) returns that same ref.
    public func other(from ref: String) -> String? {
        if person1Ref == ref { return person2Ref }
        if person2Ref == ref { return person1Ref }
        return nil
    }
}

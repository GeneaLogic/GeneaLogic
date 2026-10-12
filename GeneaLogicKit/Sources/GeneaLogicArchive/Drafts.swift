import Foundation
import GeneaLogicModel

/// "Draft" input types for the mutating-add APIs (ARCHITECTURE.md §6.3:
/// `archive.addArtifact(.init(title:tier:))`, `archive.addPerson(.init(given:surname:))`).
///
/// **Judgment call (flagged for review):** the architecture sketch shows these as
/// initializer-style calls but does not specify their full shape. Drafts here
/// intentionally mirror the *user-supplied subset* of each record's fields —
/// everything the engine itself owns (`uid`, `schemaVersion`, `provenance.createdAt`,
/// computed file fields, …) is excluded. `provenance` is included as an optional
/// override (defaulting to a sensible `human`/`asserted` provenance stamped with
/// the current time) because callers — especially future machine-driven callers
/// (OCR/NER in Phase 6) — legitimately need to assert `createdBy: .machine`.

// MARK: - ArtifactDraft

/// The descriptive subset of `Artifact` a caller supplies to `addArtifact`. The
/// engine mints `uid`, stamps `schemaVersion`, derives the on-disk slug, and
/// fills in `provenance.createdAt`/`reviewStatus` defaults if not overridden.
public struct ArtifactDraft: Sendable, Equatable {
    public var title: String
    public var mediaType: MediaType
    /// Absent means *unstated*, never a default genre (slice 46b) — the same rule as
    /// `sourceDerivation` below. A caller that has not characterised the document must
    /// not have a genre asserted on its behalf; see `Artifact.sourceAuthorityTier`.
    public var sourceAuthorityTier: SourceAuthorityTier?
    /// GPS source derivation (original / derivative / authored) — see
    /// `Artifact.sourceDerivation`. Absent means *unstated*, never "original".
    public var sourceDerivation: SourceDerivation?
    public var originalFormat: String?
    public var language: String?
    public var events: [Event]
    public var personsMentioned: [PersonMention]
    public var locations: [Location]
    public var transcript: String?
    public var externalIdentifiers: [ExternalIdentifier]
    public var retrieval: Retrieval?
    public var tags: [String]
    public var notes: String?

    /// Provenance override. When `nil`, the engine stamps
    /// `Provenance(createdBy: .human, createdAt: <now>, reviewStatus: .asserted)`.
    /// Supplying one lets machine-driven callers (future OCR/NER pipelines, the
    /// CLI's `--machine` flows, …) assert `createdBy: .machine` honestly from
    /// the start, per CLAUDE.md's "provenance on every assertion" rule.
    public var provenance: Provenance?

    public init(
        title: String,
        mediaType: MediaType,
        sourceAuthorityTier: SourceAuthorityTier? = nil,
        sourceDerivation: SourceDerivation? = nil,
        originalFormat: String? = nil,
        language: String? = nil,
        events: [Event] = [],
        personsMentioned: [PersonMention] = [],
        locations: [Location] = [],
        transcript: String? = nil,
        externalIdentifiers: [ExternalIdentifier] = [],
        retrieval: Retrieval? = nil,
        tags: [String] = [],
        notes: String? = nil,
        provenance: Provenance? = nil
    ) {
        self.title = title
        self.mediaType = mediaType
        self.sourceAuthorityTier = sourceAuthorityTier
        self.sourceDerivation = sourceDerivation
        self.originalFormat = originalFormat
        self.language = language
        self.events = events
        self.personsMentioned = personsMentioned
        self.locations = locations
        self.transcript = transcript
        self.externalIdentifiers = externalIdentifiers
        self.retrieval = retrieval
        self.tags = tags
        self.notes = notes
        self.provenance = provenance
    }
}

// MARK: - PersonDraft

/// The descriptive subset of `Person` a caller supplies to `addPerson`.
///
/// **Judgment call:** the §6.3 sketch shows `addPerson(.init(given: "John",
/// surname: "Smith"))` — a flat given/surname pair, simpler than `Person.names`'s
/// full `[PersonName]`. This draft offers *both*: the convenience flat pair (for
/// the common "I just want to record a person" case, producing a single
/// `.birth`-typed `PersonName`) and a full `names`/`facts` override for richer
/// callers (GEDCOM import in Phase 5, the app's person editor). Exactly one of
/// `(given/surname)` or `names` should be meaningfully populated; if both are,
/// `names` wins (it's the more specific input). Flagged for review — a cleaner
/// design might split this into two initializers or drop the convenience pair
/// once the app's real person-creation flow is known.
public struct PersonDraft: Sendable, Equatable {
    public var given: String?
    public var surname: String?
    public var names: [PersonName]
    public var facts: [PersonFact]
    public var identifierURI: String?
    public var provenance: Provenance?

    public init(
        given: String? = nil,
        surname: String? = nil,
        names: [PersonName] = [],
        facts: [PersonFact] = [],
        identifierURI: String? = nil,
        provenance: Provenance? = nil
    ) {
        self.given = given
        self.surname = surname
        self.names = names
        self.facts = facts
        self.identifierURI = identifierURI
        self.provenance = provenance
    }

    /// Resolves to the `[PersonName]` actually stored: `names` if non-empty,
    /// otherwise a single name synthesized from `given`/`surname` (if either is
    /// set), otherwise empty.
    func resolvedNames() -> [PersonName] {
        if !names.isEmpty { return names }
        if given != nil || surname != nil {
            // `PersonName.deriving` is the one definition of "what `full` should be
            // when nobody authored one", shared with the app and CLI (slice 44c).
            return [PersonName.deriving(type: .birth, given: given, surname: surname)]
        }
        return []
    }
}

// MARK: - RelationshipDraft

/// The descriptive subset of `Relationship` a caller supplies to `addRelationship`.
public struct RelationshipDraft: Sendable, Equatable {
    public var type: RelationshipType
    public var person1Uid: PersonID
    public var person2Uid: PersonID
    /// Relationship-scoped facts (a couple's marriage/divorce/annulment). Usually
    /// empty at creation — facts are added later via `updateRelationship` (§4.5).
    public var facts: [PersonFact]
    public var supportedByLinks: [EvidenceLinkID]
    public var reviewStatus: ReviewStatus
    public var provenance: Provenance?

    public init(
        type: RelationshipType,
        person1Uid: PersonID,
        person2Uid: PersonID,
        facts: [PersonFact] = [],
        supportedByLinks: [EvidenceLinkID] = [],
        reviewStatus: ReviewStatus = .asserted,
        provenance: Provenance? = nil
    ) {
        self.type = type
        self.person1Uid = person1Uid
        self.person2Uid = person2Uid
        self.facts = facts
        self.supportedByLinks = supportedByLinks
        self.reviewStatus = reviewStatus
        self.provenance = provenance
    }
}

// MARK: - Reviewer

/// Identifies who performed a manual review action (`link(_:to:reviewedBy:)`).
///
/// **Judgment call (flagged for review):** `EvidenceLink.reviewedBy` is modeled
/// in Phase 0 as a bare `String?` (a human reviewer's name/id). The §6.3 sketch
/// shows `reviewedBy: .human`, which reads like an enum case, not an identity
/// string — but `EvidenceLink.reviewedBy` clearly wants to record *who*, not just
/// *that a human did it* (the `provenance.createdBy: human|machine` distinction
/// already covers the latter). This type reconciles the two: it's the engine-level
/// argument to `link(...)`, and `.human(name)` carries an optional identity string
/// that becomes `EvidenceLink.reviewedBy`, while `.unspecified` leaves it `nil`.
/// If a real user-account model lands later, this is the type to extend (or
/// replace) — it is *not* persisted itself, only its resolved `String?` is.
public enum Reviewer: Sendable, Equatable {
    /// A human reviewer, optionally identified by name/account id.
    case human(String? = nil)
    /// No reviewer identity supplied; `reviewedBy` is left `nil`.
    case unspecified

    var resolvedName: String? {
        switch self {
        case .human(let name): name
        case .unspecified: nil
        }
    }
}

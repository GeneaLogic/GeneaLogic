import GeneaLogicModel

/// The two inputs the scorer compares, as plain values.
///
/// **This file is the seam that keeps `GeneaLogicMatch` archive-free.** The scorer
/// never opens an archive, reads a sidecar, or touches the SQLite index; it is handed
/// two value views and returns a ``ScoredMatch``. Projecting an `Archive` into these
/// views — walking relationships to find partners and parents, gathering an artifact's
/// other mentions — is slice 45b's job on the other side of this boundary.
///
/// The seam earns its keep three ways: the scorer is testable without a filesystem,
/// its scores are reproducible from data you can write down in a test, and the Phase 4
/// Vapor target can reuse it without inheriting the engine.

// MARK: - Place vocabulary

/// What the archive's own place strings prove about how deep a bare place name lies
/// (slice 45o).
///
/// ## The knowledge this supplies
///
/// ``PlaceMatching`` has no gazetteer, so two records both saying bare `Łomża` and two
/// both saying bare `Poland` are the same input to it: one component, equal. Slice 45n
/// settled that by refusing to guess — such a pair scores `unqualified`, below the
/// corroboration threshold — and accepted the consequence that an archive recording
/// towns bare gets no place corroboration at all.
///
/// The missing knowledge is usually sitting in the archive already. If *any* place
/// string in it is written `Rypin, Poland`, then this researcher has recorded `Rypin`
/// as something lying under `Poland` — so a bare `Rypin` elsewhere is not a country,
/// and an agreement on it is town-level agreement. That is outside knowledge without an
/// outside data source: **the archive testifying about itself.**
///
/// ## The rule, and the two ways of getting it wrong
///
/// A value is proven specific when some place string writes it **first with at least
/// one component after it**. Leading-and-not-alone proves both halves at once: there is
/// something coarser above it, so it is not a top-level name; and it leads, so some
/// record named it as the finest level it knew.
///
/// Both looser readings were tried against the real corpus and both fail on it:
///
/// - *Any non-final component* — the first phrasing — admits `NY` out of `Brooklyn, NY,
///   USA` and `Apt 4` out of `87 Sackman Street, Apt 4, Brooklyn, NY`. A state
///   scored at town strength is the overclaim slice 45n had just finished removing.
/// - *Leading, and never seen with anything below it* admits neither, but the street
///   addresses in the corpus then block `Brooklyn` — a genuine town, and exactly the
///   case this exists to rescue.
///
/// **Single-component strings contribute nothing**, which is the same rule stated from
/// the other side: a bare `Poland` is precisely the input whose depth is unknown, so it
/// cannot be evidence about depth. Only qualified strings testify.
///
/// ## Why it is a value handed in
///
/// The scorer never opens an archive — see this file's header. The vocabulary is built
/// on the archive side (`MatchCorpus`, from the index's `place` projection) and passed
/// down like `partnerNames`/`parentNames` already are. It must be **the same vocabulary
/// on every entry point**: it changes scores, so a suggestion queue and the explain path
/// that justifies one of its rows have to build it identically, or the explanation
/// reports a different number than the row it explains.
public struct PlaceVocabulary: Sendable, Equatable {

    /// Normalized values some place string writes as its leading component while
    /// naming at least one coarser one.
    private var specificValues: Set<String>

    /// The vocabulary that proves nothing — every single-component equality stays
    /// `unqualified`, which is slice 45n's behavior exactly.
    ///
    /// This is the honest default for a caller scoring outside an archive, and what
    /// makes 45n's calibration still readable in the dimension tests.
    public static let empty = PlaceVocabulary(specificValues: [])

    private init(specificValues: Set<String>) {
        self.specificValues = specificValues
    }

    /// Builds the vocabulary from every place string the archive records — artifact
    /// locations, event locations, mention facts, person facts, relationship facts.
    ///
    /// Order and duplication in `placeStrings` are irrelevant: the result is a set.
    public init(placeStrings: some Sequence<String>) {
        var values: Set<String> = []
        for place in placeStrings {
            guard let components = PlaceMatching.components(place), components.count > 1
            else { continue }
            values.insert(components[0])
        }
        specificValues = values
    }

    /// Whether the archive has proved this place value lies below the top level while
    /// being the finest level some record named.
    ///
    /// Takes the value **unnormalized**, and normalizes it here, so that no caller has
    /// to know the vocabulary is keyed on normalized text.
    public func isProvenSpecific(_ value: String) -> Bool {
        contains(normalized: NameNormalization.normalize(value))
    }

    /// The same question asked with an already-normalized value — the scorer's path,
    /// which has one in hand and runs once per candidate pair.
    func contains(normalized value: String) -> Bool {
        specificValues.contains(value)
    }
}

// MARK: - Person view

/// What the matcher needs to know about a **concluded person** (§4.3).
///
/// `partnerNames` and `parentNames` are pre-resolved by the caller rather than
/// derived here, because deriving them means walking `Relationship` records and
/// fetching the person on the far end — archive work, by definition. They are the
/// conclusions-side counterpart of a mention's co-mentions, and feed the relational
/// `spouseName` / `parents` dimensions.
public struct PersonMatchView: Sendable, Equatable {
    /// The person being scored against. Carried so a caller can key results by it;
    /// the scorer itself never reads it.
    public var personID: PersonID

    /// Every name this person carries — all of them are candidates, since the
    /// document may record a married name, a birth name, or an alias.
    public var names: [PersonName]

    /// The person's concluded facts, read for birth year and birth place.
    public var facts: [PersonFact]

    /// Names of this person's known partners, from `couple` relationships.
    public var partnerNames: [PersonName]

    /// Names of this person's known parents, from `parent-child` relationships in
    /// which this person is the child (§4.5's `person1` = parent convention).
    public var parentNames: [PersonName]

    public init(
        personID: PersonID,
        names: [PersonName],
        facts: [PersonFact] = [],
        partnerNames: [PersonName] = [],
        parentNames: [PersonName] = []
    ) {
        self.personID = personID
        self.names = names
        self.facts = facts
        self.partnerNames = partnerNames
        self.parentNames = parentNames
    }
}

// MARK: - Mention view

/// What the matcher needs to know about **one person named in one source document**
/// (§4.2) — the evidence side of the comparison.
///
/// The source's two authority axes ride here rather than in a separate view: a
/// mention is never scored outside the context of the artifact that carries it, and
/// the weights (§4.6) are computed from the pair together. Both are optional because
/// both are optional on `Artifact`, and **absent means unstated** — never "original",
/// never a default tier.
public struct MentionMatchView: Sendable, Equatable {
    /// The artifact carrying this mention. Carried for the caller's benefit; the
    /// scorer never reads it.
    public var artifactID: ArtifactID

    /// The mention's record-local ref. As above: carried, not read.
    public var localRef: String

    /// The name exactly as this document records it.
    public var nameAsRecorded: String

    /// BCP 47 language tag of ``nameAsRecorded``, or `nil`.
    public var nameLanguage: String?

    /// ISO 15924 script code of ``nameAsRecorded``, or `nil`. **This is what selects
    /// a phonetic keyer** — see ``NameMatching`` for what happens when the script is
    /// explicitly non-Latin.
    public var nameScript: String?

    /// This person's role in the document.
    public var role: PersonRole

    /// The mention's default information quality — the value a ``RecordedFact`` takes
    /// when it doesn't state its own.
    public var informationQuality: InformationQuality

    /// What this document records about this person (44h's mention-scoped facts).
    /// This is what makes the birth dimensions attributable on a multi-person record.
    public var facts: [RecordedFact]

    /// The **other** people named on the same record. The relational dimensions are
    /// derived from these by role, per §4.6 — a `.spouse` co-mention is compared
    /// against the person's partners, a `.parent` co-mention against their parents.
    public var coMentions: [CoMention]

    /// The relationships the **record itself states** between its mentions (slice 45k),
    /// verbatim from `Artifact.mentionRelationships`.
    ///
    /// Carried whole rather than pre-resolved into the co-mentions because resolving
    /// them *is* scoring: which edges bear on this mention, and what a record's silence
    /// about a relation means, are decisions ``Matcher`` owns and can be tested without
    /// an archive. Empty — the common case — leaves every dimension exactly as it was.
    public var mentionRelationships: [MentionRelationship]

    /// The artifact's record-genre axis, or `nil` when unstated.
    public var sourceTier: SourceAuthorityTier?

    /// The artifact's original-vs-derivative axis, or `nil` when unstated.
    public var sourceDerivation: SourceDerivation?

    public init(
        artifactID: ArtifactID,
        localRef: String,
        nameAsRecorded: String,
        nameLanguage: String? = nil,
        nameScript: String? = nil,
        role: PersonRole,
        informationQuality: InformationQuality,
        facts: [RecordedFact] = [],
        coMentions: [CoMention] = [],
        mentionRelationships: [MentionRelationship] = [],
        sourceTier: SourceAuthorityTier? = nil,
        sourceDerivation: SourceDerivation? = nil
    ) {
        self.artifactID = artifactID
        self.localRef = localRef
        self.nameAsRecorded = nameAsRecorded
        self.nameLanguage = nameLanguage
        self.nameScript = nameScript
        self.role = role
        self.informationQuality = informationQuality
        self.facts = facts
        self.coMentions = coMentions
        self.mentionRelationships = mentionRelationships
        self.sourceTier = sourceTier
        self.sourceDerivation = sourceDerivation
    }
}

/// Another person named on the same record, reduced to what the relational
/// dimensions read.
///
/// Deliberately **not** a whole `PersonMention`: the relational dimensions compare
/// names by role and nothing else, and a narrower input makes it obvious that a
/// co-mention's own facts play no part in scoring the mention beside it.
public struct CoMention: Sendable, Equatable {
    /// This co-mention's record-local ref — what a stated `MentionRelationship` names it
    /// by (slice 45k). Undefaulted, because a co-mention that can't be identified is one
    /// no stated edge can ever reach, and defaulting that to "" would quietly opt a
    /// caller out of the record's own statements instead of failing to compile.
    public var localRef: String
    public var nameAsRecorded: String
    public var role: PersonRole
    public var nameScript: String?

    public init(
        localRef: String, nameAsRecorded: String, role: PersonRole, nameScript: String? = nil
    ) {
        self.localRef = localRef
        self.nameAsRecorded = nameAsRecorded
        self.role = role
        self.nameScript = nameScript
    }
}

// MARK: - Output

/// The scorer's output: the four fields an `EvidenceLink` needs to record *why* a
/// mention and a person were judged to be the same.
///
/// It is not itself a record — it has no uid, no provenance, and is never written.
/// Slice 45b returns these transiently and only a human's confirm/reject (45c) turns
/// one into an `EvidenceLink`, per the mini-phase's ephemeral-suggestions decision.
public struct ScoredMatch: Sendable, Equatable {
    /// The decomposed breakdown — **the authoritative signal** (§4.6). Every UI that
    /// shows a suggestion explains it from here, never from `aggregateConfidence`.
    public var breakdown: MatchBreakdown

    /// 0–100, from the source's tier × derivation.
    public var sourceAuthorityWeight: Int

    /// 0–100, from the information quality of the facts that drove the match.
    public var informationQualityWeight: Int

    /// 0–100 roll-up. A convenience for ordering a queue; the breakdown is what a
    /// human reviews.
    public var aggregateConfidence: Int

    public init(
        breakdown: MatchBreakdown,
        sourceAuthorityWeight: Int,
        informationQualityWeight: Int,
        aggregateConfidence: Int
    ) {
        self.breakdown = breakdown
        self.sourceAuthorityWeight = sourceAuthorityWeight
        self.informationQualityWeight = informationQualityWeight
        self.aggregateConfidence = aggregateConfidence
    }
}

/// An evidence link — a concluded connection between a person mention in an artifact
/// and a concluded person identity, with a decomposed confidence breakdown.
///
/// This is the heart of the inference layer. The decomposed `match` breakdown
/// (not an opaque %) is what lets the UI explain *why* a match scored as it did.
///
/// Serialized as `conclusions/links/<UID>.json` inside the archive.
/// Documented in ARCHITECTURE.md §4.4.
///
/// NOTE (uid typing): All uid fields are `String` in Phase 0. Flagged for Opus review.
///
/// NOTE (reviewedBy): The doc shows `"reviewedBy": null` — modeled as `String?`.
/// In a later phase this might reference a user account ID or be a structured type.
/// Flagged for Opus review.
///
/// NOTE (reviewedAt): ISO 8601 timestamp as `String?`, consistent with the overall
/// date-as-string strategy. Flagged for Opus review.

// MARK: - MatchDimension

/// A single scored dimension in the match breakdown.
///
/// Documented in `EvidenceLink.match.*` (ARCHITECTURE.md §4.4).
/// Each dimension has a `kind` (exact, phonetic, within, etc.) and a `score` (0–100).
/// Some dimensions have additional metadata (e.g. `delta` for birth year proximity,
/// `nameAlgo` for the phonetic algorithm used).
///
/// NOTE: Not every dimension in the doc has the same structure — `birthYear` has a
/// `delta` field, name has `nameAlgo` at the match-object level. The `delta` field
/// is modeled on `MatchDimension` as optional; `nameAlgo` is on `MatchBreakdown`.
/// Flagged for Opus review — `nameAlgo` position (dimension vs. breakdown level).
public struct MatchDimension: Codable, Sendable, Equatable {
    /// The quality of the match on this dimension.
    public var kind: MatchKind

    /// Integer score from 0 (no match) to 100 (perfect match).
    ///
    /// **Integers, not a 0–1 `Double`** (changed in slice 44h). The spec promises
    /// reproducible bytes, and `.sortedKeys` delivers key order — but floating-point
    /// *text* is not canonically reproducible without JCS/RFC 8785, so two conforming
    /// writers could serialize the same score differently and an archive would not
    /// round-trip byte-for-byte. Integers sidestep the problem entirely, at no cost in
    /// resolution the matcher can actually justify. Done **now** because the matcher
    /// (slice 45+) is what writes scores at volume and almost none are persisted yet;
    /// after it ships, changing this would mean rescoring every existing link.
    public var score: Int

    /// For `kind == .within`: the numeric delta (e.g. birth year off by N).
    public var delta: Int?

    /// For a dimension whose agreement is **layered** — today only `birthPlace` — how
    /// far down the hierarchy the two sides agreed. `nil` on every other dimension, and
    /// on a *multi-component* exact place match, where the agreement demonstrably
    /// reached the most specific component and there is no depth left to qualify.
    ///
    /// An exact match on a **single** component does carry it, because the depth of that
    /// agreement is not evident from the pair: `unqualified` when nothing can measure it
    /// (slice 45n), `specific` when something outside the pair establishes the value
    /// lies below the top level — the archive's own other place strings today, a
    /// gazetteer eventually (slice 45o). Spec §, `granularity`.
    public var granularity: MatchGranularity?

    public init(
        kind: MatchKind,
        score: Int,
        delta: Int? = nil,
        granularity: MatchGranularity? = nil
    ) {
        self.kind = kind
        self.score = score
        self.delta = delta
        self.granularity = granularity
    }

    enum CodingKeys: String, CodingKey {
        case kind, score, delta, granularity
    }

    /// Decoding is hand-written for one reason: **an archive written before slice 45h
    /// stores `county`/`country` in `kind`**, and `MatchKind` is a closed vocabulary,
    /// so the synthesized decoder would reject those records outright — a load failure
    /// on a value GeneaLogic itself wrote, which is the exact fate the open/closed rule
    /// exists to prevent. They are read as `within` plus the granularity they were
    /// standing in for.
    ///
    /// **The word is kept, only the field it lives in changes.** The retired spellings
    /// move to `granularity` as `.unknown("county")` / `.unknown("country")` rather than
    /// being translated into a structural case, and from there they round-trip verbatim
    /// like any other open-vocabulary value.
    ///
    /// Translating them would be inventing precision. `county` was emitted for **two**
    /// different claims at two different scores — *the town agreed* (80) and *same
    /// province, different town* (55) — so recovering which one a record meant would
    /// take a score heuristic, and that heuristic holds only for values this matcher
    /// wrote. This repo's own golden fixture stores `county` at score 50, which
    /// `PlaceMatching` never emitted, and a hand-written or third-party archive can hold
    /// anything. A stored breakdown is a **verdict at a time** (45c) and is preserved,
    /// not re-derived — so the honest read is "a granularity this version has no
    /// structural name for", which is precisely what an open vocabulary's `.unknown` is.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.score = try container.decode(Int.self, forKey: .score)
        self.delta = try container.decodeIfPresent(Int.self, forKey: .delta)

        let rawKind = try container.decode(String.self, forKey: .kind)
        if Self.retiredPlaceKinds.contains(rawKind) {
            self.kind = .within
            self.granularity = MatchGranularity(parsing: rawKind)
            return
        }

        guard let kind = MatchKind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container,
                debugDescription: "unrecognized match kind \"\(rawKind)\"")
        }
        self.kind = kind
        self.granularity = try container.decodeIfPresent(
            MatchGranularity.self, forKey: .granularity)
    }

    /// `MatchKind` cases retired by slice 45h. Frozen as history — this list never
    /// grows, because a *closed* vocabulary losing a case is exactly the migration that
    /// has to be handled once and then stay handled.
    private static let retiredPlaceKinds: Set<String> = ["county", "country"]
}

// MARK: - MatchBreakdown

/// The full decomposed match breakdown for an evidence link.
///
/// Documented in `EvidenceLink.match` (ARCHITECTURE.md §4.4).
///
/// NOTE (field naming): The doc shows JSON keys `name`, `nameAlgo`, `birthYear`,
/// `birthPlace`, `spouseName`, `parents`, `conflicts`. These are used as-is via CodingKeys.
///
/// NOTE (conflicts): Modeled as `[String]` — the doc shows an empty array `[]`.
/// The content of conflict entries is not specified. A structured `Conflict` type
/// may be needed in a future phase. Flagged for Opus review.
///
/// NOTE (nameAlgo position): `nameAlgo` is a sibling of the dimension objects in the
/// doc's JSON (i.e. at the `match` level, not inside `name`). Modeled accordingly.
public struct MatchBreakdown: Codable, Sendable, Equatable {
    /// Name match dimension.
    public var name: MatchDimension

    /// Algorithm used for phonetic name matching (e.g. `"double-metaphone"`).
    public var nameAlgo: String?

    /// Birth-year proximity dimension.
    public var birthYear: MatchDimension?

    /// Birth-place granularity dimension.
    public var birthPlace: MatchDimension?

    /// Spouse-name match dimension.
    public var spouseName: MatchDimension?

    /// Parent-name match dimension.
    public var parents: MatchDimension?

    /// Conflict indicators (non-empty → strong human-review flag).
    public var conflicts: [String]

    enum CodingKeys: String, CodingKey {
        case name
        case nameAlgo
        case birthYear
        case birthPlace
        case spouseName
        case parents
        case conflicts
    }

    public init(
        name: MatchDimension,
        nameAlgo: String? = nil,
        birthYear: MatchDimension? = nil,
        birthPlace: MatchDimension? = nil,
        spouseName: MatchDimension? = nil,
        parents: MatchDimension? = nil,
        conflicts: [String] = []
    ) {
        self.name = name
        self.nameAlgo = nameAlgo
        self.birthYear = birthYear
        self.birthPlace = birthPlace
        self.spouseName = spouseName
        self.parents = parents
        self.conflicts = conflicts
    }
}

// MARK: - EvidenceLink

/// A concluded evidence→person link.
public struct EvidenceLink: Codable, Sendable, Equatable {
    /// Type-prefixed UUIDv7 identifier, e.g. `"LNK-018f…"`.
    public var uid: EvidenceLinkID

    /// Schema version for migration support.
    public var schemaVersion: String

    /// The artifact containing the person mention.
    public var artifactUid: ArtifactID

    /// The `localRef` of the person mention within that artifact (record-local, not a uid).
    public var personMentionRef: String

    /// The concluded person this mention links to.
    public var personUid: PersonID

    /// Decomposed match breakdown (the authoritative confidence signal).
    public var match: MatchBreakdown

    /// Record-level weight (0–100) derived from the artifact's `sourceAuthorityTier`
    /// and `sourceDerivation` — the two GPS source-authority axes (§4.6).
    public var sourceAuthorityWeight: Int

    /// Per-field weight (0–100) based on information quality — the mention's, or an
    /// individual `RecordedFact`'s when it states its own (§4.6).
    public var informationQualityWeight: Int

    /// Rolled-up aggregate confidence (0–100). The breakdown is authoritative; this is
    /// a convenience. See `MatchDimension.score` for why these are integers.
    public var aggregateConfidence: Int

    /// Human-review state of this link.
    public var reviewStatus: LinkReviewStatus

    /// Identifier of the human reviewer, or `nil` if not yet reviewed.
    public var reviewedBy: String?

    /// ISO 8601 timestamp of review, or `nil`.
    public var reviewedAt: String?

    /// Provenance of this link (typically machine-created).
    public var provenance: Provenance

    public init(
        uid: EvidenceLinkID,
        artifactUid: ArtifactID,
        personMentionRef: String,
        personUid: PersonID,
        match: MatchBreakdown,
        sourceAuthorityWeight: Int,
        informationQualityWeight: Int,
        aggregateConfidence: Int,
        reviewStatus: LinkReviewStatus,
        reviewedBy: String? = nil,
        reviewedAt: String? = nil,
        provenance: Provenance
    ) {
        self.uid = uid
        self.schemaVersion = SchemaVersion.current
        self.artifactUid = artifactUid
        self.personMentionRef = personMentionRef
        self.personUid = personUid
        self.match = match
        self.sourceAuthorityWeight = sourceAuthorityWeight
        self.informationQualityWeight = informationQualityWeight
        self.aggregateConfidence = aggregateConfidence
        self.reviewStatus = reviewStatus
        self.reviewedBy = reviewedBy
        self.reviewedAt = reviewedAt
        self.provenance = provenance
    }

    /// Whether this link is a **rejection tombstone** — a human's recorded "no", not a
    /// citation (slice 45c).
    ///
    /// Named rather than left as `reviewStatus == .humanRejected` at each call site
    /// because it is asked in a dozen places and the mistake it guards against is a
    /// *missing* check, not a wrong one. A named predicate is greppable: `isRejection`
    /// finds every consumer that thought about this, which is how the audit stays done
    /// as new read paths are added.
    public var isRejection: Bool { reviewStatus == .humanRejected }
}

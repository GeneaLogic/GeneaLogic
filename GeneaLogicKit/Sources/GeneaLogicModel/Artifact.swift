/// An evidence artifact — the sidecar record for a single source document.
///
/// Answers "what does this record say?" — nothing about conclusions.
/// Serialized as `artifacts/<slug>/record.json` inside the archive.
///
/// Documented in ARCHITECTURE.md §4.2.
///
/// CodingKeys notes:
/// - `title` maps to `"dc:title"` (Dublin Core) per the architecture doc.
/// - `mediaType` maps to `"mediaType"` (the doc uses `"dc:type"` in the comment
///   but `"mediaType"` as the actual JSON key — the JSON key wins here). See note below.
/// - All other keys use the literal JSON key from the doc's example.
///
/// NOTE (dc:title vs title): The architecture doc §4 says 'Field names map onto
/// Dublin Core and GEDCOM X vocabularies wherever those cover the concept' and
/// the comment in the example shows `// dc:title`. However, the actual JSON key
/// shown in the example is `"title"`, not `"dc:title"`. The CLAUDE.md says
/// 'JSON metadata keys align with Dublin Core / GEDCOM X vocabularies'.
/// DECISION: Using `"title"` as the JSON key (matching the example's actual key,
/// not the comment). The DC alignment is vocabulary/semantic, not literal key name.
/// Flagged for Opus review — if literal `"dc:title"` is desired, CodingKeys must change.
///
/// NOTE (mediaType): Similarly, the comment says `// dc:type` but the key is `"mediaType"`.
/// Using `"mediaType"` as the JSON key. Flagged for Opus review.
///
/// NOTE (uid typing): All `uid` fields are `String` in Phase 0. Flagged for Opus review.
///
/// NOTE (optional vs required): Fields not present in every record (retrieval,
/// transcript, externalIdentifiers) are modeled as optional or with empty-array defaults.
/// `events`, `personsMentioned`, `locations`, `files`, `externalIdentifiers` and
/// `tags` default to empty arrays rather than `nil` (they are arrays in the JSON).
/// Flagged for Opus review.
public struct Artifact: Codable, Sendable, Equatable {
    // MARK: - Properties

    /// Type-prefixed UUIDv7 identifier, e.g. `"ART-018f…"`.
    public var uid: ArtifactID

    /// Schema version for migration support.
    public var schemaVersion: String

    /// Human-readable title of the artifact (Dublin Core `dc:title`).
    public var title: String

    /// The primary media type of the artifact.
    public var mediaType: MediaType

    /// The epistemic authority tier of the source (GPS-aligned) — *what genre of
    /// record is this?*
    ///
    /// **Absent means unstated, never a default genre** — the rule ``sourceDerivation``
    /// below already followed, and which this field violated by being non-optional until
    /// slice 46b. A required field forces every entry point to name a genre, and every
    /// available genre is a *claim*: `genea add` defaulted to `compiled` and the app
    /// stamped it on every import, so documents nobody had characterised were asserting
    /// *"somebody's conclusion, not evidence"* about themselves — and scoring 25, below
    /// the 40 that saying nothing earns. The gap slice 46 filled was real; this is the
    /// mechanism that had been *generating* it.
    ///
    /// Optional, so a record written before 46b decodes unchanged and re-encodes with the
    /// key intact. Nothing is migrated: a stored `compiled` may well be deliberate, and a
    /// sweep cannot tell the two apart.
    public var sourceAuthorityTier: SourceAuthorityTier?

    /// How far this source stands from the event it reports — original / derivative /
    /// authored (GPS), the axis orthogonal to ``sourceAuthorityTier``.
    ///
    /// **Absent means unstated, never "original."** A researcher who hasn't
    /// established whether they are looking at a register page or somebody's index of
    /// it must not have the stronger claim asserted on their behalf — the same rule
    /// the parent-child qualifiers follow (§4.5). Added in slice 44h; optional, so an
    /// older record decodes unchanged.
    public var sourceDerivation: SourceDerivation?

    /// Format description of the original document (e.g. `"digital scan"`, `"original"`).
    public var originalFormat: String?

    /// BCP 47 language tag of the document (Dublin Core `dc:language`).
    public var language: String?

    /// Events recorded in or described by this artifact.
    public var events: [Event]

    /// Persons named or described in this artifact.
    public var personsMentioned: [PersonMention]

    /// Relationships **this document states between the people it names** — the one
    /// thing the evidence layer could not previously say (slice 45k).
    ///
    /// Artifact-level rather than a list on each mention so that one edge is one
    /// record; see ``MentionRelationship`` for that reasoning and for why this is not
    /// the same type as a concluded `Relationship`. Both endpoints are `localRef`s into
    /// this record's own ``personsMentioned``.
    ///
    /// Empty is the honest and common default: most records state no relation at all,
    /// and an edge-less record must go on meaning exactly what it means today.
    ///
    /// Added in slice 45k — see `init(from:)` for the additive, back-compatible decode
    /// (absent key reads as `[]`, so no schema bump).
    public var mentionRelationships: [MentionRelationship]

    /// Places mentioned in this artifact.
    public var locations: [Location]

    /// Optional short inline transcript. Long transcripts are stored as a file with `role: .transcript`.
    public var transcript: String?

    /// Physical files associated with this artifact.
    public var files: [FileEntry]

    /// External identifiers from other repositories (for federation).
    public var externalIdentifiers: [ExternalIdentifier]

    /// Retrieval metadata for externally-sourced records; `nil` for locally-created ones.
    public var retrieval: Retrieval?

    /// Provenance of this record (who created it, when, review state).
    public var provenance: Provenance

    /// Free-form tags for browsing and filtering.
    public var tags: [String]

    /// Free-form notes about this artifact.
    public var notes: String?

    // MARK: - CodingKeys

    // All keys must match the JSON keys from ARCHITECTURE.md §4.2 exactly.
    // See notes above about dc:title / mediaType decisions.
    enum CodingKeys: String, CodingKey {
        case uid
        case schemaVersion
        case title
        case mediaType
        case sourceAuthorityTier
        case sourceDerivation
        case originalFormat
        case language
        case events
        case personsMentioned
        case mentionRelationships
        case locations
        case transcript
        case files
        case externalIdentifiers
        case retrieval
        case provenance
        case tags
        case notes
    }

    // MARK: - Initializer

    public init(
        uid: ArtifactID,
        title: String,
        mediaType: MediaType,
        sourceAuthorityTier: SourceAuthorityTier? = nil,
        sourceDerivation: SourceDerivation? = nil,
        originalFormat: String? = nil,
        language: String? = nil,
        events: [Event] = [],
        personsMentioned: [PersonMention] = [],
        mentionRelationships: [MentionRelationship] = [],
        locations: [Location] = [],
        transcript: String? = nil,
        files: [FileEntry] = [],
        externalIdentifiers: [ExternalIdentifier] = [],
        retrieval: Retrieval? = nil,
        provenance: Provenance,
        tags: [String] = [],
        notes: String? = nil
    ) {
        self.uid = uid
        self.schemaVersion = SchemaVersion.current
        self.title = title
        self.mediaType = mediaType
        self.sourceAuthorityTier = sourceAuthorityTier
        self.sourceDerivation = sourceDerivation
        self.originalFormat = originalFormat
        self.language = language
        self.events = events
        self.personsMentioned = personsMentioned
        self.mentionRelationships = mentionRelationships
        self.locations = locations
        self.transcript = transcript
        self.files = files
        self.externalIdentifiers = externalIdentifiers
        self.retrieval = retrieval
        self.provenance = provenance
        self.tags = tags
        self.notes = notes
    }

    // MARK: - Coding

    // Hand-written **only** so `mentionRelationships` (added slice 45k) decodes as `[]`
    // when absent from an older record — the additive, back-compatible widening
    // `PersonMention.facts` and `Relationship.facts` already got, and the reason this
    // type stops using the synthesized conformance: a synthesized decode requires every
    // non-optional key to be present, so a new array on this record would make every
    // artifact written before today fail to *load*. Every other key decodes exactly as
    // it did (strictly). `encode` always emits the array, matching the model's "always
    // emit array keys" style, so a record rewritten by this version gains an empty
    // `mentionRelationships` — additive, and readable by any version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(ArtifactID.self, forKey: .uid)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        title = try container.decode(String.self, forKey: .title)
        mediaType = try container.decode(MediaType.self, forKey: .mediaType)
        // `decodeIfPresent` since 46b: a record written before the field existed as an
        // optional still carries it, and one written after may legitimately omit it.
        sourceAuthorityTier = try container.decodeIfPresent(
            SourceAuthorityTier.self, forKey: .sourceAuthorityTier)
        sourceDerivation = try container.decodeIfPresent(
            SourceDerivation.self, forKey: .sourceDerivation)
        originalFormat = try container.decodeIfPresent(String.self, forKey: .originalFormat)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        events = try container.decode([Event].self, forKey: .events)
        personsMentioned = try container.decode([PersonMention].self, forKey: .personsMentioned)
        mentionRelationships =
            try container.decodeIfPresent(
                [MentionRelationship].self, forKey: .mentionRelationships) ?? []
        locations = try container.decode([Location].self, forKey: .locations)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        files = try container.decode([FileEntry].self, forKey: .files)
        externalIdentifiers = try container.decode(
            [ExternalIdentifier].self, forKey: .externalIdentifiers)
        retrieval = try container.decodeIfPresent(Retrieval.self, forKey: .retrieval)
        provenance = try container.decode(Provenance.self, forKey: .provenance)
        tags = try container.decode([String].self, forKey: .tags)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(title, forKey: .title)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encodeIfPresent(sourceAuthorityTier, forKey: .sourceAuthorityTier)
        try container.encodeIfPresent(sourceDerivation, forKey: .sourceDerivation)
        try container.encodeIfPresent(originalFormat, forKey: .originalFormat)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(events, forKey: .events)
        try container.encode(personsMentioned, forKey: .personsMentioned)
        try container.encode(mentionRelationships, forKey: .mentionRelationships)
        try container.encode(locations, forKey: .locations)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(files, forKey: .files)
        try container.encode(externalIdentifiers, forKey: .externalIdentifiers)
        try container.encodeIfPresent(retrieval, forKey: .retrieval)
        try container.encode(provenance, forKey: .provenance)
        try container.encode(tags, forKey: .tags)
        try container.encodeIfPresent(notes, forKey: .notes)
    }
}

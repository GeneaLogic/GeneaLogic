// MARK: - RecordedFact

/// Something a **single source document records about a single person named in it** —
/// "this register says he was born in 1892 at Łomża."
///
/// This is the evidence-layer twin of `PersonFact` (§4.3), and the two are
/// deliberately **not** the same type despite their overlapping shape. A
/// `PersonFact` carries `supportedByLinks: [EvidenceLinkID]` — a pointer *into the
/// conclusions layer*. Reusing it here would make an artifact sidecar reference
/// `conclusions/`, inverting §2.3's one-way dependency (conclusions cite evidence,
/// never the reverse) and leaving a field that is meaningless on this side and must
/// stay permanently empty. The cost of a second small type is much lower than the
/// cost of a format that lets evidence point at conclusions.
///
/// (Slice 43 reused `PersonFact` for `Relationship.facts` on the opposite reasoning
/// — a relationship *is* a conclusion, so `supportedByLinks` means exactly what it
/// says there. Same shape, different layer, different answer.)
///
/// Documented in `Artifact.personsMentioned[].facts[]` (ARCHITECTURE.md §4.2, §10.6).
public struct RecordedFact: Codable, Sendable, Equatable {
    /// What kind of fact the document records (GEDCOM X-aligned open vocabulary).
    /// See ``FactType/recordedCases`` for the types that make sense here.
    public var type: FactType

    /// Verbatim EDTF (ISO 8601-2) date **as the document states it**, or `nil` —
    /// frequently partial or approximate (`"1892"`, `"1892~"`). Parsed on demand via
    /// `EDTFDate`; never stored structured, exactly like `Event.date`.
    public var date: String?

    /// Place as the document records it, or `nil`.
    public var place: String?

    /// The fact's **value** as the document records it, when it carries one that isn't a
    /// date or place — an occupation (`"tailor"`), a physical description (`"brown hair,
    /// 5 ft 8 in"`), a religion, and so on. `nil` for the many facts a value doesn't
    /// apply to. This is the evidence-layer twin of `PersonFact.value`; a value-bearing
    /// fact promoted from evidence carries it through. GEDCOM X-aligned (a `Fact` there
    /// carries `type` + `date` + `place` + `value`).
    ///
    /// Added in slice 44i — additive and back-compatible (absent decodes to `nil` via
    /// the synthesized optional decode, so no schema bump).
    public var value: String?

    /// How good this document is as a source **for this particular fact**, when that
    /// differs from the mention's overall quality.
    ///
    /// This is the Genealogical Proof Standard's per-*field* information quality
    /// (§4.6), which the enclosing `PersonMention.informationQuality` can only state
    /// once for the whole person: a death certificate is a strong *primary* source
    /// for the death it records and a weak *secondary* one for the deceased's birth,
    /// so the two facts drawn from it must not carry the same weight. The matcher's
    /// per-field information-quality weight reads this.
    ///
    /// **Absent means "inherit the mention's"** — not "undetermined". A record that
    /// says nothing special about a given fact is simply as good as the mention it
    /// sits on, and forcing a value would fabricate a judgment the researcher hasn't
    /// made. State this only for the **exceptions**; see
    /// `PersonMention.informationQuality` for the default it overrides.
    public var informationQuality: InformationQuality?

    public init(
        type: FactType,
        date: String? = nil,
        place: String? = nil,
        value: String? = nil,
        informationQuality: InformationQuality? = nil
    ) {
        self.type = type
        self.date = date
        self.place = place
        self.value = value
        self.informationQuality = informationQuality
    }

    /// This fact's effective information quality within `mention`: its own when it
    /// states one, otherwise the mention's. The one place the "absent means inherit"
    /// rule above is decoded, so no consumer re-derives it.
    ///
    /// Named `effective…` rather than overloading the property name: a method whose
    /// body reads `informationQuality ?? mention.informationQuality` would resolve
    /// the first term by arity alone, and a later default argument or overload would
    /// silently make it recursive.
    public func effectiveInformationQuality(within mention: PersonMention) -> InformationQuality {
        informationQuality ?? mention.informationQuality
    }
}

// MARK: - PersonMention

/// A person as they are named and described within a single source artifact.
///
/// This is **not** a person identity — it is a "name as it appears in this document."
/// Identity is a conclusion reached by linking mentions to `Person` records via
/// `EvidenceLink`. The `localRef` never escapes the artifact.
///
/// Documented in `Artifact.personsMentioned[]` (ARCHITECTURE.md §4.2).
///
/// NOTE: `attributes` is modeled as `[String: String]` — the doc shows only
/// `{ "ageAsRecorded": "45" }` as an example. A richer typed model is possible
/// but premature; a string dictionary covers the unstructured, record-specific
/// nature of raw attributes. Flagged for Opus review.
public struct PersonMention: Codable, Sendable, Equatable {
    /// Reference unique **within this artifact only**. Never used outside it.
    public var localRef: String

    /// The person's name exactly as it appears in the source record.
    public var nameAsRecorded: String

    /// The person's role in the document (subject, informant, witness, etc.).
    public var role: PersonRole

    /// The **default information quality for this mention's facts** — the value a
    /// ``RecordedFact`` takes when it doesn't state its own.
    ///
    /// Read it as *how close was whoever supplied this information to what the record
    /// is stating about this person* — the informant's proximity, which is a real and
    /// useful judgment. Do **not** read it as "the quality of this person," which is
    /// not a thing: under the GPS, quality is a property of an individual information
    /// item, never of a person-in-a-record. That is why a per-fact override exists.
    ///
    /// In practice: set this to whatever most of the mention's facts are (usually
    /// `.primary` for the record's own subject), then state the **exceptions** on the
    /// facts themselves. A death certificate's informant is `.primary` for the death
    /// and `.secondary` for the deceased's birth and parents, because they are
    /// reporting secondhand family knowledge — so the mention says `.primary` and the
    /// birth fact says `.secondary`, rather than every fact restating a judgment.
    ///
    /// Keeping a default here is what makes "absent means inherit" workable: without
    /// it, every fact would have to carry an explicit quality or fall back to
    /// `.undetermined`, which would silently downgrade facts the researcher was happy
    /// to call primary. `.undetermined` remains the honest value when the proximity
    /// genuinely isn't known.
    public var informationQuality: InformationQuality

    /// What **this document** records about **this person** — their recorded birth,
    /// death, residence, age-at-event, and so on.
    ///
    /// This is what closes open question §10.6. An artifact's `events[]` and
    /// `personsMentioned[]` are flat and unpaired, so on a *multi-person* record — a
    /// census household, a metrical register page, a marriage certificate naming the
    /// couple and both sets of parents, which is this project's norm — there is no
    /// way to say *which* recorded birth is *whose*. Scoping the facts to the mention
    /// says it directly, and it is the GEDCOM X *persona* model (a per-source view of
    /// a person, distinct from the concluded person) rather than an invention.
    ///
    /// Empty is the honest default and stays common: plenty of records name someone
    /// without recording anything else about them (a witness, an informant).
    ///
    /// Added in slice 44h — see `init(from:)` for the additive, back-compatible
    /// decode (absent key reads as `[]`, so no schema bump).
    public var facts: [RecordedFact]

    /// BCP 47 language tag of ``nameAsRecorded`` (e.g. `"ru"`, `"pl"`, `"yi"`), or
    /// `nil` when unstated.
    ///
    /// Distinct from `Artifact.language` (the *document's* language): a Russian-
    /// language register routinely records Polish and Yiddish names, so the document
    /// tag cannot stand in for the name's.
    public var nameLanguage: String?

    /// ISO 15924 script code of ``nameAsRecorded`` (e.g. `"Cyrl"`, `"Latn"`,
    /// `"Hebr"`), or `nil` when unstated.
    ///
    /// Orthogonal to ``nameLanguage``, not redundant with it: a transliterated
    /// Russian name is language `ru`, script `Latn`. Script is what the matcher needs
    /// to choose a phonetic keyer — Double Metaphone is Latin/English phonetics, so
    /// keying "Мотек" with it produces noise rather than a match, and
    /// `MatchBreakdown.nameAlgo` already anticipates there being more than one
    /// algorithm to choose between.
    public var nameScript: String?

    /// Freeform record-specific attributes, e.g. `["ageAsRecorded": "45"]`.
    public var attributes: [String: String]?

    public init(
        localRef: String,
        nameAsRecorded: String,
        role: PersonRole,
        informationQuality: InformationQuality,
        facts: [RecordedFact] = [],
        nameLanguage: String? = nil,
        nameScript: String? = nil,
        attributes: [String: String]? = nil
    ) {
        self.localRef = localRef
        self.nameAsRecorded = nameAsRecorded
        self.role = role
        self.informationQuality = informationQuality
        self.facts = facts
        self.nameLanguage = nameLanguage
        self.nameScript = nameScript
        self.attributes = attributes
    }

    // Custom coding so `facts` (added slice 44h) decodes as `[]` when absent from an
    // older record — an additive, back-compatible widening, the same treatment
    // `Relationship.facts` got in slice 43 (no schema bump; §4.2's superset
    // reasoning). The new optional string fields need no help: an absent optional
    // already decodes to nil. `encode` always emits `facts`, matching the model's
    // "always emit array keys" style, and omits absent optionals.
    private enum CodingKeys: String, CodingKey {
        case localRef, nameAsRecorded, role, informationQuality, facts
        case nameLanguage, nameScript, attributes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        localRef = try container.decode(String.self, forKey: .localRef)
        nameAsRecorded = try container.decode(String.self, forKey: .nameAsRecorded)
        role = try container.decode(PersonRole.self, forKey: .role)
        informationQuality = try container.decode(
            InformationQuality.self, forKey: .informationQuality)
        facts = try container.decodeIfPresent([RecordedFact].self, forKey: .facts) ?? []
        nameLanguage = try container.decodeIfPresent(String.self, forKey: .nameLanguage)
        nameScript = try container.decodeIfPresent(String.self, forKey: .nameScript)
        attributes = try container.decodeIfPresent([String: String].self, forKey: .attributes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(localRef, forKey: .localRef)
        try container.encode(nameAsRecorded, forKey: .nameAsRecorded)
        try container.encode(role, forKey: .role)
        try container.encode(informationQuality, forKey: .informationQuality)
        try container.encode(facts, forKey: .facts)
        try container.encodeIfPresent(nameLanguage, forKey: .nameLanguage)
        try container.encodeIfPresent(nameScript, forKey: .nameScript)
        try container.encodeIfPresent(attributes, forKey: .attributes)
    }

    /// Mints the `localRef` for a new mention being added to `mentions`: the
    /// lowest `p<n>` that no existing mention uses, that no surviving
    /// `EvidenceLink` still claims, and that no surviving `MentionRelationship`
    /// still names.
    ///
    /// A `localRef` is record-local and always assigned, never user-entered — it
    /// is the anchor an `EvidenceLink` points at, so a caller choosing one could
    /// collide with a mention added elsewhere.
    ///
    /// **`claimedBy` has no default, deliberately.** Omitting it would silently
    /// restore the pre-44c behavior, and the compiler would not object — so the
    /// empty case has to be written as an explicit `claimedBy: []` at the call
    /// site rather than being available by omission. Removing a mention
    /// deliberately leaves any link pointing at it dangling (§2.3 — removals
    /// don't cascade). A plain "lowest unused" rule then hands that freed ref to
    /// the *next* mention, and the stale link silently resolves again — to a
    /// completely different person. That turns a visible dangle into an
    /// **invisible wrong conclusion**, which is the worse failure by far: the
    /// citation reads plausibly and is simply false. So refs still claimed by a
    /// link are skipped, while genuinely free refs are still reused rather than
    /// drifting upward forever.
    ///
    /// **`statedIn` is the same trap one layer in** (slice 45k). A record's
    /// `mentionRelationships` name mentions by `localRef` too, and removing a
    /// mention leaves an edge pointing at the freed ref for exactly the same §2.3
    /// reason. Handing that ref to the next mention would make a stranger somebody's
    /// parent — again invisibly, since the edge reads perfectly well. Undefaulted
    /// for the same reason as `claimedBy`: omitting it must not be the quiet path.
    ///
    /// This lives in the model because it is a **format-level rule**, not a UI
    /// one: the Mac app, the `genea` CLI, and any future consumer must mint refs
    /// identically or they will disagree about what a link points at. It was
    /// previously implemented twice, and both copies had the bug above.
    ///
    /// - Parameters:
    ///   - mentions: The record's current mentions.
    ///   - links: Evidence links whose `personMentionRef` must not be reused.
    ///     Passing the links for this artifact is correct; passing a wider set is
    ///     merely conservative (it can only skip more refs, never reuse a claimed
    ///     one).
    ///   - edges: The record's own stated relationships, whose endpoints must not
    ///     be reused. Always the artifact's own `mentionRelationships` — unlike the
    ///     links, these live on the very record being mutated.
    public static func nextLocalRef(
        in mentions: [PersonMention],
        claimedBy links: [EvidenceLink],
        statedIn edges: [MentionRelationship]
    ) -> String {
        var used = Set(mentions.map(\.localRef))
        used.formUnion(links.map(\.personMentionRef))
        for edge in edges {
            used.insert(edge.person1Ref)
            used.insert(edge.person2Ref)
        }
        var n = 1
        while used.contains("p\(n)") { n += 1 }
        return "p\(n)"
    }
}

/// Controlled-vocabulary enumerations for the GeneaLogic archive model.
///
/// Raw values match the documented JSON strings exactly (ARCHITECTURE.md §4).
///
/// # Two flavors of vocabulary
///
/// - **Closed vocabularies** (`InformationQuality`, `CreatedBy`, `FileRole`,
///   `MatchKind`, `ReviewStatus`, `LinkReviewStatus`) are GeneaLogic's own internal
///   domains. They are strict `String`-backed enums: an unrecognized value is a
///   decode error, which is the desired behavior for values we fully own.
///
/// - **Open vocabularies** (`SourceAuthorityTier`, `SourceDerivation`, `MediaType`,
///   `NameType`, `PersonRole`, `RelationshipType`, `ExternalIdentifierScheme`,
///   `FactType`) map onto external
///   or evolving standards (Dublin Core, GEDCOM X, identifier schemes). These
///   conform to `OpenVocabulary`: they carry the documented cases **plus** an
///   `.unknown(String)` case that decodes, preserves, and re-encodes any
///   unrecognized value losslessly. This satisfies the core longevity guarantee
///   (an archive written by a future version still opens, and an older reader never
///   silently drops a value it doesn't recognize) and makes federation harvesting
///   of external vocabularies safe.

// MARK: - OpenVocabulary

/// A string vocabulary that tolerates unrecognized values by preserving them
/// verbatim in an `.unknown(String)` case. Conformers provide `init(parsing:)`,
/// `rawValue`, and `knownCases`; Codable (as a single JSON string) is shared here.
public protocol OpenVocabulary: Codable, Sendable, Hashable {
    /// Parse a raw string into a known case, or `.unknown(raw)` if unrecognized.
    init(parsing raw: String)
    /// The canonical string form (round-trips through `init(parsing:)` for known cases).
    var rawValue: String { get }
    /// All recognized cases (excludes `.unknown`). Replaces `CaseIterable`, which
    /// cannot be synthesized for enums with associated values.
    static var knownCases: [Self] { get }
}

extension OpenVocabulary {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(parsing: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Parses a value arriving from **outside** a record's own field — something a
    /// human typed, or a string being mapped across vocabularies — folding it to a
    /// known case case- and whitespace-insensitively, and otherwise preserving it
    /// (trimmed) as `.unknown`.
    ///
    /// Without this, `"birth"` becomes `.unknown("birth")` sitting *beside* the
    /// known `.birth`: two values that render identically, never compare equal, and
    /// show up as duplicate entries in a picker. That bug has now been reported once
    /// (the 42c fact-type picker) and found twice more in review, so the rule lives
    /// here rather than being re-derived per consumer.
    ///
    /// **This is deliberately NOT what `init(parsing:)` does, and must never
    /// become it.** `init(parsing:)` is the **decode** path: folding case there
    /// would silently rewrite stored values on the next encode (an archive holding
    /// `"birth"` would be re-saved as `"Birth"`), breaking the format's
    /// unknown-preserving round-trip guarantee — a far worse bug than the
    /// duplication this fixes. Decoding stays verbatim; only *input* is normalized.
    public static func parsingLeniently(_ raw: String) -> Self {
        let trimmed = raw.trimmingCharactersInWhitespace()
        // Compare case- and whitespace-insensitively, collapsing **internal** whitespace
        // too: a multi-word human input ("Declaration of Intention", "physical
        // description") folds to a PascalCase known case ("DeclarationOfIntention",
        // "PhysicalDescription") rather than minting an `.unknown` twin that renders
        // identically. Known raw values never contain whitespace, so this only ever
        // helps a match — and the *original* (spaced) text is preserved as `.unknown`
        // when nothing matches, so a genuinely custom multi-word type isn't mangled.
        let collapsed = String(trimmed.lowercased().filter { !$0.isWhitespace })
        if let known = knownCases.first(where: { $0.rawValue.lowercased() == collapsed }) {
            return known
        }
        return Self(parsing: trimmed)
    }

    /// Whether two values name the **same term** for *query* purposes, tolerating the
    /// spelling drift that promoting a case into `knownCases` otherwise strands.
    ///
    /// **This exists because promotion is not behaviour-neutral for search**, which
    /// slice 46 found the hard way. A pre-46 archive stored `"Government"` verbatim as
    /// `.unknown("Government")`; a pre-46 query folded to the same `.unknown` and the
    /// two compared equal. Promoting `government` to a known case moves only the
    /// *query* side — `parsingLeniently` now folds it to `.government` while the stored
    /// value still decodes verbatim, per the decode-stays-verbatim rule above — so an
    /// `==` comparison silently stops finding the record. Reproduced end-to-end in 46:
    /// an *unpromoted* term with identical casing was still found, which is what pins
    /// the promotion as the cause rather than the casing.
    ///
    /// Folding both sides restores it without touching storage. Two `.unknown`s that
    /// differ only in case still do **not** match — that was already true before any
    /// promotion, so widening it here would be a behaviour change rather than a repair.
    public func denotesSameTerm(as other: Self) -> Bool {
        self == other
            || Self.parsingLeniently(rawValue) == Self.parsingLeniently(other.rawValue)
    }
}

// MARK: - Source authority tier (open)

/// The epistemic authority of a source record, per the Genealogical Proof Standard.
/// Documented as `sourceAuthorityTier` in ARCHITECTURE.md §4.2. Open: the doc lists
/// `vital | church | government | census | monument | newspaper | bible | compiled | …`.
///
/// The tier is a **genre convenience**, deliberately coarse. The GPS's real axes are
/// modeled separately — ``SourceDerivation`` (how far from the event) and per-fact
/// `informationQuality` (how the informant knew) — and keeping this list short is what
/// stops the three from re-encoding each other. A draft card's weakness is not its
/// genre but that its birth year is the registrant's recollection, and
/// `informationQuality: .secondary` on that one `RecordedFact` says so better.
///
/// `government` and `monument` were added in slice 46, where the gap was doing real
/// damage: a naturalization certificate, a draft registration and an arrival manifest
/// had nowhere to land but `compiled`, which is not a neutral default — it asserts
/// *"somebody's conclusion, not evidence"*.
///
/// **`government` is read by who created the record, not by the errand it served.** Any
/// record an authority created or required, other than the vital registration that has
/// its own tier: naturalization, draft and service, land, court, and arrival manifests —
/// a passenger list is a filing retained by the receiving authority, which is the test,
/// however commercial the ship. Genres fitting *no* bucket (institutional registers,
/// commercial records, photographs) stay `.unknown`, which scores as **unstated** (40)
/// rather than as `compiled` (25) — so an unbucketed genre is never worse off for being
/// catalogued honestly. A tier per genre is the shape this vocabulary is trying not to
/// have; widening the reading of an existing bucket is not the same as adding one.
public enum SourceAuthorityTier: OpenVocabulary {
    case vital, church, government, census, monument, newspaper, bible, compiled
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "vital": self = .vital
        case "church": self = .church
        case "government": self = .government
        case "census": self = .census
        case "monument": self = .monument
        case "newspaper": self = .newspaper
        case "bible": self = .bible
        case "compiled": self = .compiled
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .vital: "vital"
        case .church: "church"
        case .government: "government"
        case .census: "census"
        case .monument: "monument"
        case .newspaper: "newspaper"
        case .bible: "bible"
        case .compiled: "compiled"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [SourceAuthorityTier] {
        [.vital, .church, .government, .census, .monument, .newspaper, .bible, .compiled]
    }
}

// MARK: - Source derivation (open; GPS original-vs-derivative)

/// How far a source stands from the event it reports — the Genealogical Proof
/// Standard's *original vs. derivative* axis, which is **orthogonal** to
/// `SourceAuthorityTier`.
///
/// The tier answers "what genre of record is this?" (vital, church, census); this
/// answers "am I looking at the record itself, or a copy of a copy?" A parish
/// register page photographed in the archive and a name typed into an online index
/// from that same page are both `church` — and are not remotely equal evidence.
/// §4.6 calls the confidence framework GPS-aligned, but only half of the GPS model
/// was actually present (per-field information quality was; derivation was not), so
/// this completes it and lets the matcher's source-authority multiplier weight on
/// the right axis from the start rather than being retrofitted onto already-scored
/// links.
///
/// Documented as `sourceDerivation` in ARCHITECTURE.md §4.2. Optional: absent means
/// *unstated*, never "original" — see the note on `Artifact.sourceDerivation`.
public enum SourceDerivation: OpenVocabulary {
    /// The record itself, or a faithful image of it (the parish register page).
    case original
    /// A copy, transcription, index entry, or abstract of an original (a FamilySearch
    /// index entry, a typed extract).
    case derivative
    /// A work written *from* sources — a compiled family tree, a published county
    /// history, a genealogy article.
    case authored
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "original": self = .original
        case "derivative": self = .derivative
        case "authored": self = .authored
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .original: "original"
        case .derivative: "derivative"
        case .authored: "authored"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [SourceDerivation] {
        [.original, .derivative, .authored]
    }
}

// MARK: - Media type (open; Dublin Core dc:type)

/// The type of the artifact's primary media (Dublin Core `dc:type`).
/// Documented as `mediaType` in ARCHITECTURE.md §4.2 (doc example: `"image"`). Open.
public enum MediaType: OpenVocabulary {
    case image, text, sound, video, document
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "image": self = .image
        case "text": self = .text
        case "sound": self = .sound
        case "video": self = .video
        case "document": self = .document
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .image: "image"
        case .text: "text"
        case .sound: "sound"
        case .video: "video"
        case .document: "document"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [MediaType] {
        [.image, .text, .sound, .video, .document]
    }
}

// MARK: - Name type (open; GEDCOM X)

/// The type of a person's name record (GEDCOM X-aligned).
/// Documented in `Person.names[].type` (ARCHITECTURE.md §4.3, doc example: `"birth"`). Open.
public enum NameType: OpenVocabulary {
    case birth, married, alsoKnownAs, nickname
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "birth": self = .birth
        case "married": self = .married
        case "also-known-as": self = .alsoKnownAs
        case "nickname": self = .nickname
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .birth: "birth"
        case .married: "married"
        case .alsoKnownAs: "also-known-as"
        case .nickname: "nickname"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [NameType] {
        [.birth, .married, .alsoKnownAs, .nickname]
    }
}

// MARK: - Relationship type (open)

/// The type of a concluded relationship between two persons.
/// Documented in `Relationship.type` (ARCHITECTURE.md §4.5, doc: `parent-child | couple | …`). Open.
public enum RelationshipType: OpenVocabulary {
    case parentChild, couple
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "parent-child": self = .parentChild
        case "couple": self = .couple
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .parentChild: "parent-child"
        case .couple: "couple"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [RelationshipType] {
        [.parentChild, .couple]
    }

    /// Whether the two endpoints carry no ordering meaning, so `(a, b)` and `(b, a)` are
    /// **one** relationship written two ways.
    ///
    /// The single owner of the question, because three layers now ask it about the same
    /// vocabulary: the evidence layer's ``MentionRelationship/statesSameRelationship(as:)``
    /// (one edge is one entry), the conclusions layer's suggested relationships (an
    /// already-asserted `couple` must not be re-offered reversed, slice 45l), and
    /// ``DismissalSubject/isSymmetric`` on the far side of the same pair. Three copies of a
    /// rule about symmetry is where the two halves of a symmetric pair start to disagree.
    ///
    /// An unknown type is read as **directional**: a vocabulary this version has never seen
    /// is one whose symmetry it cannot know, and wrongly assuming symmetry collapses two
    /// distinct statements into one.
    public var isSymmetric: Bool {
        switch self {
        case .couple: true
        case .parentChild, .unknown: false
        }
    }
}

// MARK: - Dismissal subject (open)

/// What a human declined when they dismissed a suggestion — the typed subject of a
/// ``Dismissal`` (slice 45m).
///
/// **The subject is the assertion itself**, not a discriminator with a payload beside it:
/// "these two are not the same person" and "this is not a parent-child edge between them"
/// are the same shape of statement over the same pair, differing only in what was claimed.
/// The relationship spellings are `RelationshipType`'s verbatim, so promoting or declining
/// the same suggestion never means translating between two vocabularies.
///
/// **Open** (spec §7), and the reading that decided it is what an unrecognized value
/// *costs*. Unknown here, a dismissal round-trips verbatim and suppresses nothing: the
/// pair is offered again, which is simply the behaviour before dismissals existed. Closed,
/// an archive a later GeneaLogic wrote would fail to **load** — 44h's failure exactly. And
/// the set is demonstrably not exhaustive: it grew twice (45j's *not the same person*,
/// 45l's *not this relationship*) before it first shipped.
public enum DismissalSubject: OpenVocabulary {
    /// *These two concluded persons are not one person* — 45j's duplicate candidates.
    case samePerson
    /// *This is not a parent-child relationship between them* — 45l's suggested
    /// relationships. Directional: `person1Uid` is the proposed **parent**.
    case parentChild
    /// *These two are not a couple* — 45l's suggested relationships. Symmetric.
    case couple
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "same-person": self = .samePerson
        case "parent-child": self = .parentChild
        case "couple": self = .couple
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .samePerson: "same-person"
        case .parentChild: "parent-child"
        case .couple: "couple"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [DismissalSubject] {
        [.samePerson, .parentChild, .couple]
    }

    /// Whether the two endpoints carry no ordering meaning, so `(a, b)` and `(b, a)` are
    /// **one** dismissal written two ways.
    ///
    /// An unknown subject is read as **directional**, the same conservative answer
    /// `MentionRelationship.statesSameRelationship` gives for an unknown relationship
    /// type: a vocabulary this version has never seen is one whose symmetry it cannot
    /// know, and wrongly assuming symmetry would collapse two distinct dismissals into
    /// one — silently un-declining something a human declined.
    public var isSymmetric: Bool {
        switch self {
        case .samePerson, .couple: true
        case .parentChild, .unknown: false
        }
    }
}

// MARK: - External identifier scheme (open)

/// The scheme for an external identifier (e.g. ARK, DOI, URL) used in federation.
/// Documented in `Artifact.externalIdentifiers[].scheme` (ARCHITECTURE.md §4.2, doc: `"ark"`). Open.
public enum ExternalIdentifierScheme: OpenVocabulary {
    case ark, doi, url
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "ark": self = .ark
        case "doi": self = .doi
        case "url": self = .url
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .ark: "ark"
        case .doi: "doi"
        case .url: "url"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [ExternalIdentifierScheme] {
        [.ark, .doi, .url]
    }
}

// MARK: - Fact type (open; GEDCOM X)

/// A GEDCOM X-aligned fact type for a concluded person (`Person.facts[].type`).
/// Documented in ARCHITECTURE.md §4.3 (doc example: `"Birth"`). Open — GEDCOM X
/// defines a large, evolving vocabulary, so unrecognized types are preserved.
public enum FactType: OpenVocabulary {
    case birth, death, marriage, divorce, annulment, residence, baptism, burial, census
    /// Migration and citizenship events. Promoted from `.unknown` because they are
    /// routine for an immigrant corpus — and because a naturalization record is the
    /// clearest everyday case of per-fact information quality (§4.6): primary for the
    /// naturalization it witnesses, secondary for the birth the applicant reported
    /// from memory decades later.
    case naturalization, immigration, emigration
    /// A **declaration of intention** (US "first papers") — the earlier step in the
    /// naturalization process, distinct from the naturalization itself. Promoted from
    /// `.unknown` because it is routine for an immigrant corpus and is a value-bearing
    /// record (it states occupation, physical description, and more).
    case declarationOfIntention
    /// **Value-bearing person characteristics** — an occupation (value `"tailor"`) or a
    /// physical description (value `"brown hair, 5 ft 8 in"`). Unlike a birth (a
    /// date/place), these carry their information in ``PersonFact/value`` /
    /// ``RecordedFact/value``. GEDCOM X-aligned (`Occupation`, `PhysicalDescription`).
    case occupation, physicalDescription
    /// The **nature of a parent-child relationship** (GEDCOM X's parent-role fact
    /// types). These ride a `parent-child` `Relationship.facts`, qualifying a single
    /// parent→child link — one child can have a biological mother and an adoptive
    /// father, so the qualifier belongs on the edge, not on either person.
    ///
    /// **Absence means *unspecified*, never "biological."** A researcher who has not
    /// established the nature of a parent-child link must not have one asserted on
    /// their behalf; ``biologicalParent`` exists so it can be claimed deliberately.
    case adoptiveParent, biologicalParent, stepParent, fosterParent, guardianParent
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "Birth": self = .birth
        case "Death": self = .death
        case "Marriage": self = .marriage
        case "Divorce": self = .divorce
        case "Annulment": self = .annulment
        case "Residence": self = .residence
        case "Baptism": self = .baptism
        case "Burial": self = .burial
        case "Census": self = .census
        case "Naturalization": self = .naturalization
        case "Immigration": self = .immigration
        case "Emigration": self = .emigration
        case "DeclarationOfIntention": self = .declarationOfIntention
        case "Occupation": self = .occupation
        case "PhysicalDescription": self = .physicalDescription
        case "AdoptiveParent": self = .adoptiveParent
        case "BiologicalParent": self = .biologicalParent
        case "StepParent": self = .stepParent
        case "FosterParent": self = .fosterParent
        case "GuardianParent": self = .guardianParent
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .birth: "Birth"
        case .death: "Death"
        case .marriage: "Marriage"
        case .divorce: "Divorce"
        case .annulment: "Annulment"
        case .residence: "Residence"
        case .baptism: "Baptism"
        case .burial: "Burial"
        case .census: "Census"
        case .naturalization: "Naturalization"
        case .immigration: "Immigration"
        case .emigration: "Emigration"
        case .declarationOfIntention: "DeclarationOfIntention"
        case .occupation: "Occupation"
        case .physicalDescription: "PhysicalDescription"
        case .adoptiveParent: "AdoptiveParent"
        case .biologicalParent: "BiologicalParent"
        case .stepParent: "StepParent"
        case .fosterParent: "FosterParent"
        case .guardianParent: "GuardianParent"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [FactType] {
        [
            .birth, .death, .marriage, .divorce, .annulment, .residence, .baptism, .burial,
            .census, .naturalization, .immigration, .emigration,
            .declarationOfIntention, .occupation, .physicalDescription,
            .adoptiveParent, .biologicalParent, .stepParent, .fosterParent, .guardianParent,
        ]
    }

    /// The GEDCOM X fact types that describe a **couple** relationship rather than a
    /// person — marriage/divorce/annulment ride the couple `Relationship.facts`, not
    /// either spouse (ARCHITECTURE.md §4.5). The relationship fact editor offers these
    /// (plus any `.unknown` value already stored) so a couple isn't offered "Birth".
    public static var coupleCases: [FactType] {
        [.marriage, .divorce, .annulment]
    }

    /// The GEDCOM X fact types that qualify a **parent-child** relationship — the
    /// nature of the link (adoptive, step, foster, guardian, or explicitly biological).
    /// These ride the parent-child `Relationship.facts`, so the relationship editor
    /// offers them and neither the person nor the couple fact editor does.
    public static var parentChildCases: [FactType] {
        [.biologicalParent, .adoptiveParent, .stepParent, .fosterParent, .guardianParent]
    }

    /// The fact types that describe a single **person** rather than a couple or a
    /// parent-child link — every known case except the `coupleCases` and the
    /// `parentChildCases`. The person fact editor offers these, so a person fact is
    /// never offered "Marriage" (a couple `Relationship`) or "AdoptiveParent" (a
    /// parent-child one).
    public static var personCases: [FactType] {
        knownCases.filter { !coupleCases.contains($0) && !parentChildCases.contains($0) }
    }

    /// The fact types a **`RecordedFact`** can carry — what a single document records
    /// about a single person named in it (slice 44h).
    ///
    /// This is `personCases` **plus** the `coupleCases`, and deliberately so: a
    /// marriage register's entry for the groom genuinely records "married, this date,
    /// this place" *about him*, and refusing to record it would push the record's
    /// central fact off the mention it belongs to. (Where the marriage lands as a
    /// **conclusion** is a separate question §4.5 already answers — the couple
    /// `Relationship` — and that separation is exactly why the evidence layer may
    /// state it per-person without creating a second source of truth.)
    ///
    /// The `parentChildCases` are excluded: they qualify the *nature of a concluded
    /// edge* ("adoptive parent of"), which needs two identities to mean anything and
    /// so cannot be an observation about one named person.
    public static var recordedCases: [FactType] {
        knownCases.filter { !parentChildCases.contains($0) }
    }

    /// The known fact types that conventionally carry a **`value`** rather than being a
    /// date/place event — an occupation ("tailor"), a physical description ("brown hair").
    /// GEDCOM X-aligned (`Occupation`, `PhysicalDescription` are its value-bearing types).
    ///
    /// **Advisory, not a constraint.** `value` is permitted on *any* fact type at the
    /// format level; this list only drives a UI hint (which editors show the Value field
    /// by default — see ``isValueBearing``). A birth with a value still round-trips.
    public static var valueBearingCases: [FactType] {
        [.occupation, .physicalDescription]
    }

    /// Whether this type conventionally carries a value — the `valueBearingCases`, plus
    /// **any `.unknown` (custom) type**, since a type this build hasn't heard of might
    /// well be value-bearing and the researcher shouldn't be denied the field. Advisory
    /// (see ``valueBearingCases``): a caller that already has a value should still show
    /// it regardless of this.
    public var isValueBearing: Bool {
        if case .unknown = self { return true }
        return Self.valueBearingCases.contains(self)
    }
}

// MARK: - Person role within a record (open)

/// The role a named person played within the source document.
/// Documented in `personsMentioned[].role` (ARCHITECTURE.md §4.2).
///
/// **Open as of slice 44h** (it was closed, alone among the record-role
/// vocabularies). Two reasons. It was inconsistently closed — `NameType`,
/// `RelationshipType` and `FactType` are all open, and a person's role in a document
/// is no more GeneaLogic's own domain than a name's type is. And closed meant a
/// **load error** on a role a real record carries: metrical registers routinely name
/// a godparent, a midwife, or the declarant, and an archive that recorded one would
/// have failed to open rather than preserving a value it didn't recognize — the exact
/// failure the open-vocabulary rule exists to prevent (§7).
///
/// The six standard roles those registers carry are added as known cases at the same
/// time, so the common ones are no longer `.unknown`. Reads stay back-compatible:
/// every previously-legal value still parses to the same case.
public enum PersonRole: OpenVocabulary {
    case subject, informant, witness, parent, spouse
    /// Roles standard in church/metrical registers, added with the open
    /// reclassification (slice 44h).
    case godparent, sponsor, declarant, registrar, clergy, midwife
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "subject": self = .subject
        case "informant": self = .informant
        case "witness": self = .witness
        case "parent": self = .parent
        case "spouse": self = .spouse
        case "godparent": self = .godparent
        case "sponsor": self = .sponsor
        case "declarant": self = .declarant
        case "registrar": self = .registrar
        case "clergy": self = .clergy
        case "midwife": self = .midwife
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .subject: "subject"
        case .informant: "informant"
        case .witness: "witness"
        case .parent: "parent"
        case .spouse: "spouse"
        case .godparent: "godparent"
        case .sponsor: "sponsor"
        case .declarant: "declarant"
        case .registrar: "registrar"
        case .clergy: "clergy"
        case .midwife: "midwife"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [PersonRole] {
        [
            .subject, .informant, .witness, .parent, .spouse,
            .godparent, .sponsor, .declarant, .registrar, .clergy, .midwife,
        ]
    }
}

// MARK: - Information quality (closed; GPS per-field quality)

/// The quality of the information for a given field or mention, distinguishing
/// primary (recorded at or near the event) from secondary. Closed (GPS vocabulary).
/// Documented in `personsMentioned[].informationQuality` (ARCHITECTURE.md §4.2).
public enum InformationQuality: String, Codable, Sendable, Equatable, CaseIterable {
    case primary
    case secondary
    case undetermined
}

// MARK: - Provenance creator kind (closed)

/// Who or what created an assertion: a human or a machine process.
/// Documented in `provenance.createdBy` (ARCHITECTURE.md §4.2).
public enum CreatedBy: String, Codable, Sendable, Equatable, CaseIterable {
    case human
    case machine
}

// MARK: - Review status: provenance / conclusions (closed)

/// The human-review state of an asserted record or conclusion (artifacts, persons,
/// relationships, provenance). Documented in `provenance.reviewStatus` and
/// `Relationship.reviewStatus` (ARCHITECTURE.md §4.2, §4.5).
///
/// NOTE: This is intentionally distinct from `LinkReviewStatus`. Conclusions are
/// *asserted/verified*; evidence links are *confirmed/rejected*. Splitting them
/// keeps each context's legal values enforced by the type system.
public enum ReviewStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case asserted
    case machineSuggested = "machine-suggested"
    case humanVerified = "human-verified"
}

// MARK: - Review status: evidence links (closed)

/// The human-review state of an evidence→person link.
/// Documented in `EvidenceLink.reviewStatus` (ARCHITECTURE.md §4.4).
public enum LinkReviewStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case machineSuggested = "machine-suggested"
    case humanConfirmed = "human-confirmed"
    case humanRejected = "human-rejected"
}

// MARK: - File role (closed)

/// The role of a file within an artifact.
/// Documented in `files[].role` (ARCHITECTURE.md §4.2).
public enum FileRole: String, Codable, Sendable, Equatable, CaseIterable {
    case preservationMaster = "preservation-master"
    case accessCopy = "access-copy"
    case derivative
    case transcript
}

// MARK: - Match kind (closed; EvidenceLink dimension)

/// The quality of a match on a single dimension within an evidence link.
/// Documented in `EvidenceLink.match.*` (ARCHITECTURE.md §4.4). Closed — these are
/// GeneaLogic's own matcher dimensions.
/// **Closed** (slice 45h): every case describes how *this matcher* reached a verdict,
/// which is GeneaLogic's own domain and is exhaustive in this version (spec §7).
///
/// It formerly also carried `county` and `country`. Those described the world's
/// administrative geography rather than the matcher's reasoning — not GeneaLogic's
/// domain, and not exhaustible (Polish *gmina*/*powiat*/*województwo*, Japanese
/// 都道府県/市/区, Ottoman *vilayet*/*sanjak*/*kaza*). §7's rule is about **domain, not
/// convenience**, so they were misfiled rather than a vocabulary needing to be opened;
/// they now live in the open ``MatchGranularity``. See ``MatchDimension`` for how an
/// archive that stored them is still read.
public enum MatchKind: String, Codable, Sendable, Equatable, CaseIterable {
    case exact
    case phonetic
    case knownVariant = "known-variant"
    case within  // e.g. birth year within N years, or a place agreeing below the top
    case none
}

// MARK: - Match granularity within a hierarchy (open)

/// *How far down a hierarchy* two values agreed, for a dimension whose agreement is
/// layered rather than yes/no. Today that is `birthPlace`.
///
/// **Open, and named structurally rather than administratively.** The place matcher
/// splits a string into components and counts which ones line up; it holds no gazetteer
/// and cannot know whether the third component is a county, an oblast, or a prefecture.
/// Naming its output after Anglo-American administrative tiers claimed knowledge the
/// code does not have, which is the mistake this vocabulary exists to correct. A later
/// gazetteer-backed matcher may legitimately want to say `parish` or `admin2`, and open
/// is what lets it without a format break.
public enum MatchGranularity: OpenVocabulary {
    /// The **most specific** component agreed while coarser ones differ — the border
    /// case, and the whole reason place agreement is not string equality: `Łomża,
    /// Russia` and `Łomża, Poland` are one town under two empires.
    case specific
    /// Agreement runs inward from the coarsest end across more than one component,
    /// without the most specific one agreeing: same province, different town.
    case partial
    /// Only the least specific component agreed. Two people born in Poland.
    case coarse
    /// The values agreed **exactly**, but on a single component, so how far down the
    /// agreement reaches **cannot be measured** (slice 45n).
    ///
    /// `Poland` and `Poland` agree perfectly; so do `Łomża` and `Łomża`. One is two
    /// people from the same country — barely evidence — and the other is two people from
    /// the same town, which is strong. **The matcher holds no gazetteer and cannot tell
    /// them apart**, and before this case existed it resolved the ambiguity in favor of
    /// the strongest reading and scored both 100.
    ///
    /// Reporting the uncertainty is the point: naming it `coarse` instead would resolve
    /// the same ambiguity in favor of the weakest reading, which is the identical mistake
    /// pointing the other way. A gazetteer-backed matcher can replace this with a real
    /// level, which is what open is for.
    case unqualified
    case unknown(String)

    public init(parsing raw: String) {
        switch raw {
        case "specific": self = .specific
        case "partial": self = .partial
        case "coarse": self = .coarse
        case "unqualified": self = .unqualified
        default: self = .unknown(raw)
        }
    }

    public var rawValue: String {
        switch self {
        case .specific: "specific"
        case .partial: "partial"
        case .coarse: "coarse"
        case .unqualified: "unqualified"
        case .unknown(let value): value
        }
    }

    public static var knownCases: [MatchGranularity] {
        [.specific, .partial, .coarse, .unqualified]
    }
}

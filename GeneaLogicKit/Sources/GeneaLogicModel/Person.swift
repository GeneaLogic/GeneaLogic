/// A concluded person — something we have determined exists, based on evidence.
///
/// Modeled on GEDCOM X for forward import/export compatibility.
/// Serialized as `conclusions/persons/<UID>.json` inside the archive.
///
/// Documented in ARCHITECTURE.md §4.3.
///
/// NOTE (uid typing): `uid` is `String` in Phase 0. Flagged for Opus review.
///
/// NOTE (facts.supportedByLinks): The `PersonFact.supportedByLinks` array contains
/// `uid` strings of `EvidenceLink` records. These are cross-record references;
/// they are plain `String` values (not a typed reference) in Phase 0.
/// Flagged for Opus review.
///
/// NOTE (identifierURI): Reserved as `String?` per the doc. The doc says
/// "reserved: a resolvable URI for linked-data federation". Flagged for Opus review.

// MARK: - PersonName

/// A name associated with a concluded person.
/// Documented in `Person.names[]` (ARCHITECTURE.md §4.3).
public struct PersonName: Codable, Sendable, Hashable {
    /// The type of this name (birth, married, alias, etc.).
    public var type: NameType

    /// Given name(s).
    public var given: String?

    /// Surname(s).
    public var surname: String?

    /// Full name string.
    public var full: String?

    /// BCP 47 language tag of this name (e.g. `"ru"`, `"pl"`, `"yi"`), or `nil` when
    /// unstated.
    ///
    /// A person carries several names drawn from several records, and they are
    /// routinely in different languages — the same woman is "Chana" in a Yiddish
    /// record, "Анна" in a Russian one, and "Anna" on a naturalization paper. One tag
    /// per *person* could not say that; the tag belongs on the name.
    public var language: String?

    /// ISO 15924 script code of this name (e.g. `"Cyrl"`, `"Latn"`, `"Hebr"`), or
    /// `nil` when unstated.
    ///
    /// Orthogonal to ``language``: a transliterated Russian name is language `ru`,
    /// script `Latn`. This is what lets the matcher choose a phonetic algorithm
    /// instead of running Latin/English Double Metaphone over Cyrillic and matching
    /// noise (`MatchBreakdown.nameAlgo`). Added in slice 44h.
    public var script: String?

    public init(
        type: NameType,
        given: String? = nil,
        surname: String? = nil,
        full: String? = nil,
        language: String? = nil,
        script: String? = nil
    ) {
        self.type = type
        self.given = given
        self.surname = surname
        self.full = full
        self.language = language
        self.script = script
    }

    /// The text this name resolves to for display: `full` when it carries one,
    /// otherwise given + surname joined; `nil` when the name has no usable text.
    ///
    /// Every consumer prefers `full`, which is why keeping it in step with the
    /// parts matters — see ``hasDerivedFull``.
    ///
    /// The returned text is **trimmed**, so it can differ from what is stored: this
    /// is a display derivation, not a safe write-back source.
    ///
    /// Whitespace-only values count as absent — `full: "   "` is not a name, and
    /// treating it as one would render a blank where a placeholder belongs.
    public var resolvedText: String? {
        if let trimmed = full?.trimmingCharactersInWhitespace(), !trimmed.isEmpty {
            return trimmed
        }
        return Self.derivedFull(given: given, surname: surname)
    }

    /// Whether `full` looks like one *derived* from the parts rather than authored.
    ///
    /// The distinction is load-bearing when editing a name: a derived `full` must be
    /// recomputed when a part changes, or the record contradicts itself and the
    /// rename is invisible to every consumer (all of which prefer `full`). An
    /// authored `full` — "Anna Maria von Meyer" — carries information the parts do
    /// not and must survive a `--surname`-style fix untouched. A `nil` `full` is not
    /// "derived": there is nothing stale to fix, and ``resolvedText`` already falls
    /// back to the parts.
    public var hasDerivedFull: Bool {
        guard let full else { return false }
        return full == Self.derivedFull(given: given, surname: surname)
    }

    /// Builds a name, deriving `full` from the parts when one wasn't authored.
    ///
    /// This is the single definition of "what `full` should be when nobody typed
    /// one", shared by every writer (the engine's `PersonDraft`, the app's person
    /// editor, the CLI's `person add` / `person name add`) so a name created by one
    /// is indistinguishable from a name created by another.
    public static func deriving(
        type: NameType, given: String?, surname: String?, full: String? = nil,
        language: String? = nil, script: String? = nil
    ) -> PersonName {
        PersonName(
            type: type,
            given: given,
            surname: surname,
            full: full ?? derivedFull(given: given, surname: surname),
            language: language,
            script: script
        )
    }

    /// Empty (and whitespace-only) parts are dropped rather than joined, so a blank
    /// `given` can't leave a leading space in `full` — which would also make
    /// ``hasDerivedFull`` miss its own output and treat a derived `full` as authored.
    private static func derivedFull(given: String?, surname: String?) -> String? {
        let joined = [given, surname]
            .compactMap { $0?.trimmingCharactersInWhitespace() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

// MARK: - PersonFact

/// A concluded fact about a person (birth, death, residence, etc.), GEDCOM X-aligned.
/// Documented in `Person.facts[]` (ARCHITECTURE.md §4.3).
///
/// NOTE (type): `type` is a `String` here (e.g. `"Birth"`, `"Death"`), not an enum.
/// GEDCOM X defines a controlled vocabulary for fact types, but the doc does not
/// enumerate all values. Using `String` for forward-compat. Flagged for Opus review.
///
/// NOTE (date/place): Both are `String?` per the pattern used throughout (partial dates,
/// unresolved place strings). See overall date-strategy note in `GeneaLogicJSON.swift`.
public struct PersonFact: Codable, Sendable, Hashable {
    /// GEDCOM X fact type (open vocabulary), e.g. `.birth`, `.death`, `.residence`.
    public var type: FactType

    /// Verbatim EDTF (ISO 8601-2) date string, or `nil`. Frequently partial,
    /// approximate, or ranged (`"1920"`, `"1920~"`, `"1900/1905"`); parsed on demand
    /// via `EDTFDate` for ordering/filtering. See the note in `Event.swift`.
    public var date: String?

    /// Place as recorded or normalized, or `nil`.
    public var place: String?

    /// The fact's **value**, when it carries one that isn't a date or place — an
    /// occupation (`"tailor"`), a physical description (`"brown hair, 5 ft 8 in"`), a
    /// religion, and so on. `nil` for the many facts a value doesn't apply to (a birth
    /// is a date/place, not a value). GEDCOM X-aligned: a `Fact` there carries
    /// `type` + `date` + `place` + `value`, and value-bearing types like `Occupation`
    /// and `PhysicalDescription` are exactly where it's used.
    ///
    /// Added in slice 44i — an additive, back-compatible field (absent decodes to
    /// `nil` via the synthesized optional decode, so no schema bump; §4.2's superset
    /// reasoning, the same treatment `facts[]`/`Relationship.facts` got).
    public var value: String?

    /// Ids of `EvidenceLink` records that support this fact.
    public var supportedByLinks: [EvidenceLinkID]

    public init(
        type: FactType,
        date: String? = nil,
        place: String? = nil,
        value: String? = nil,
        supportedByLinks: [EvidenceLinkID] = []
    ) {
        self.type = type
        self.date = date
        self.place = place
        self.value = value
        self.supportedByLinks = supportedByLinks
    }
}

// MARK: - Person

/// A concluded person identity.
public struct Person: Codable, Sendable, Equatable {
    /// Type-prefixed UUIDv7 identifier, e.g. `"PER-018f…"`.
    public var uid: PersonID

    /// Schema version for migration support.
    public var schemaVersion: String

    /// Names associated with this person.
    public var names: [PersonName]

    /// GEDCOM X-style facts (birth, death, residence, etc.).
    public var facts: [PersonFact]

    /// Reserved for future linked-data federation. Currently always `nil`.
    public var identifierURI: String?

    /// Provenance of this concluded record.
    public var provenance: Provenance

    public init(
        uid: PersonID,
        names: [PersonName] = [],
        facts: [PersonFact] = [],
        identifierURI: String? = nil,
        provenance: Provenance
    ) {
        self.uid = uid
        self.schemaVersion = SchemaVersion.current
        self.names = names
        self.facts = facts
        self.identifierURI = identifierURI
        self.provenance = provenance
    }

    /// The name to show for this person: the first that resolves to usable text,
    /// preferring a `.birth`-typed one; `nil` when the person has no usable name
    /// (which the format permits).
    ///
    /// Note it iterates *all* names for the first resolvable one rather than
    /// trusting `names.first` — a person can carry a birth name with no text and a
    /// perfectly good married name.
    ///
    /// **No presentation policy belongs here** — not name ordering ("Surname,
    /// Given"), not localization. This resolves *which* name to show, and callers
    /// own how it is rendered.
    ///
    /// Callers supply their own placeholder for the `nil` case, because that is a
    /// presentation choice and the consumers legitimately differ: the app says
    /// "Unnamed person", the CLI's `person show` says "(unnamed)", and the CLI's
    /// `person list` prints an **empty column** so a placeholder can't be mistaken
    /// for a real name by `cut -f2`.
    public var displayName: String? {
        let birthPreferred = names.filter { $0.type == .birth } + names
        return birthPreferred.lazy.compactMap(\.resolvedText).first
    }
}

import Testing

@testable import GeneaLogicModel

/// The name-resolution rules shared by the engine, the app and the CLI
/// (`PersonName.resolvedText` / `hasDerivedFull` / `deriving`, and
/// `Person.displayName`).
///
/// These lived in three hand-written copies until slice 44c, and had already
/// drifted: one trimmed whitespace and the others didn't, and one synthesized
/// `full` with a leading space when `given` was blank. Since every consumer
/// *displays* `full` in preference to the parts, a disagreement here shows up as
/// the same person reading differently in the app, the sidebar and `genea person
/// show`.
@Suite struct PersonNameRulesTests {

    private func person(_ names: [PersonName]) -> Person {
        Person(
            uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
            names: names,
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-07-19T00:00:00Z", tool: nil,
                reviewStatus: .asserted))
    }

    // MARK: - resolvedText

    /// `full` wins when present — it's what every consumer displays.
    @Test func resolvedTextPrefersFull() {
        let name = PersonName(type: .birth, given: "Anna", surname: "Meyer", full: "Anna M. Meyer")
        #expect(name.resolvedText == "Anna M. Meyer")
    }

    /// Without a `full`, the parts are joined.
    @Test func resolvedTextFallsBackToParts() {
        #expect(
            PersonName(type: .birth, given: "Anna", surname: "Meyer").resolvedText == "Anna Meyer")
        #expect(PersonName(type: .birth, surname: "Meyer").resolvedText == "Meyer")
        #expect(PersonName(type: .birth, given: "Anna").resolvedText == "Anna")
    }

    /// A name with nothing usable resolves to `nil` rather than an empty string, so
    /// callers can choose their own placeholder.
    @Test func resolvedTextIsNilWhenEmpty() {
        #expect(PersonName(type: .birth).resolvedText == nil)
        #expect(PersonName(type: .birth, given: "", surname: "").resolvedText == nil)
    }

    /// Whitespace-only is not a name. (The app trimmed, the engine and CLI didn't —
    /// this is the drift, resolved toward the stricter reading, since rendering
    /// `"   "` shows a blank where a placeholder belongs.)
    @Test func resolvedTextTreatsWhitespaceOnlyAsAbsent() {
        #expect(PersonName(type: .birth, full: "   ").resolvedText == nil)
        #expect(PersonName(type: .birth, given: " ", surname: "\t").resolvedText == nil)
        // A blank part next to a real one doesn't leave a stray separator.
        #expect(PersonName(type: .birth, given: "  ", surname: "Meyer").resolvedText == "Meyer")
    }

    // MARK: - deriving / hasDerivedFull

    /// `deriving` fills `full` from the parts when none was authored.
    @Test func derivingSynthesizesFullFromParts() {
        let name = PersonName.deriving(type: .birth, given: "Anna", surname: "Meyer")
        #expect(name.full == "Anna Meyer")
        #expect(name.given == "Anna")
        #expect(name.hasDerivedFull)
    }

    /// An authored `full` is kept verbatim and is *not* reported as derived — the
    /// distinction that stops an edit to one part clobbering it.
    @Test func derivingKeepsAnAuthoredFull() {
        let name = PersonName.deriving(
            type: .birth, given: "Anna", surname: "Meyer", full: "Anna Maria von Meyer")
        #expect(name.full == "Anna Maria von Meyer")
        #expect(!name.hasDerivedFull)
    }

    /// A `nil` `full` is not "derived" — there is nothing stale to recompute.
    @Test func nilFullIsNotDerived() {
        #expect(!PersonName(type: .birth, given: "Anna", surname: "Meyer").hasDerivedFull)
    }

    /// A blank part must not produce a leading space, or `hasDerivedFull` would fail
    /// to recognize the value it just produced and treat it as authored.
    @Test func derivedFullRoundTripsThroughHasDerivedFull() {
        for (given, surname) in [("Anna", "Meyer"), ("", "Meyer"), ("Anna", ""), (" ", "Meyer")] {
            let name = PersonName.deriving(type: .birth, given: given, surname: surname)
            #expect(name.hasDerivedFull, "deriving(\(given), \(surname)) must be recognized")
        }
    }

    // MARK: - Person.displayName

    /// A `.birth` name is preferred over other types regardless of order.
    @Test func displayNamePrefersTheBirthName() {
        let subject = person([
            PersonName(type: .married, given: "Anna", surname: "Braun"),
            PersonName(type: .birth, given: "Anna", surname: "Meyer"),
        ])
        #expect(subject.displayName == "Anna Meyer")
    }

    /// Iterating *all* names matters: a birth name with no usable text must not
    /// shadow a perfectly good married name.
    @Test func displayNameSkipsAnEmptyBirthName() {
        let subject = person([
            PersonName(type: .birth),
            PersonName(type: .married, given: "Anna", surname: "Braun"),
        ])
        #expect(subject.displayName == "Anna Braun")
    }

    /// A person with no usable name resolves to `nil`, leaving the placeholder to
    /// the consumer (they differ: "Unnamed person" / "(unnamed)" / an empty column).
    @Test func displayNameIsNilWhenNothingResolves() {
        #expect(person([]).displayName == nil)
        #expect(person([PersonName(type: .birth)]).displayName == nil)
    }
}

/// `OpenVocabulary.parsingLeniently` — the input-normalization rule, and the
/// boundary between it and the decode path.
@Suite struct OpenVocabularyLenientParsingTests {

    /// A known case is matched whatever the casing or surrounding whitespace.
    @Test func foldsCaseAndWhitespaceToKnownCases() {
        #expect(FactType.parsingLeniently("birth") == .birth)
        #expect(FactType.parsingLeniently("BIRTH") == .birth)
        #expect(FactType.parsingLeniently("  Birth  ") == .birth)
        #expect(MediaType.parsingLeniently("Image") == .image)
        #expect(NameType.parsingLeniently("ALSO-KNOWN-AS") == .alsoKnownAs)
    }

    /// A genuinely unrecognized value is preserved — trimmed, so quoting can't mint
    /// `.unknown("  X  ")` beside a later `.unknown("X")`.
    @Test func preservesUnknownValuesTrimmed() {
        #expect(FactType.parsingLeniently("Enumeration") == .unknown("Enumeration"))
        #expect(FactType.parsingLeniently("  Enumeration  ") == .unknown("Enumeration"))
    }

    /// **The boundary this rule exists to respect.** `init(parsing:)` is the decode
    /// path and must stay verbatim: an archive holding `"birth"` decodes as
    /// `.unknown("birth")` and re-encodes as `"birth"`. If the fold ever migrated
    /// into `init(parsing:)`, that stored value would be silently rewritten to
    /// `"Birth"` on the next save — breaking the format's unknown-preserving
    /// round-trip guarantee, which is a worse bug than the duplication the fold
    /// removes.
    @Test func decodePathStaysVerbatim() {
        let decoded = FactType(parsing: "birth")
        #expect(decoded == .unknown("birth"))
        #expect(decoded.rawValue == "birth", "re-encoding must not rewrite the stored value")
        #expect(decoded != FactType.parsingLeniently("birth"))
    }
}

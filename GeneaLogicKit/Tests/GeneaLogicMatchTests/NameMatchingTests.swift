import GeneaLogicModel
import Testing

@testable import GeneaLogicMatch

/// Name normalization and the `name` dimension (slice 45).
@Suite struct NameMatchingTests {

    private func name(
        _ given: String?, _ surname: String?, type: NameType = .birth, script: String? = nil
    ) -> PersonName {
        PersonName.deriving(type: type, given: given, surname: surname, script: script)
    }

    // MARK: - Normalization

    /// Diacritics are stripped, because the same family is spelled both ways on
    /// either side of an ocean.
    @Test(
        arguments: [
            ("Müller", "muller"),
            ("Mueller", "mueller"),
            ("Łomża", "lomza"),
            ("Kraków", "krakow"),
            ("MEYER", "meyer"),
        ])
    func normalizationFoldsCaseAndDiacritics(input: String, expected: String) {
        #expect(NameNormalization.normalize(input) == expected)
    }

    /// Punctuation inside a name is dropped, not turned into a token break — or
    /// "Jean-Marie" would match anyone called Jean.
    @Test func punctuationIsDroppedNotSplit() {
        #expect(NameNormalization.tokens("O'Brien") == ["obrien"])
        #expect(NameNormalization.tokens("Jean-Marie Dupont") == ["jeanmarie", "dupont"])
    }

    /// Precomposed and decomposed spellings of one name normalize identically —
    /// the reason normalization begins with canonical composition.
    @Test func unicodeFormsNormalizeAlike() {
        let precomposed = "Jos\u{00E9}"
        let decomposed = "Jose\u{0301}"
        #expect(NameNormalization.normalize(precomposed) == NameNormalization.normalize(decomposed))
    }

    @Test(arguments: ["", "   ", "!!!"])
    func emptyNormalizationYieldsNoTokens(input: String) {
        #expect(NameNormalization.tokens(input).isEmpty)
    }

    // MARK: - The three bands

    @Test func identicalNamesScoreExact() {
        let (dimension, algorithm) = NameMatching.score(
            recorded: "Marcus Hanner", script: nil, against: [name("Marcus", "Hanner")])
        #expect(dimension.kind == .exact)
        #expect(dimension.score == 100)
        // No keyer ran, so none is claimed.
        #expect(algorithm == nil)
    }

    /// Case and diacritics don't stop an exact match.
    @Test func normalizationReachesExact() {
        let (dimension, _) = NameMatching.score(
            recorded: "MARCUS HANNER", script: nil, against: [name("Marcus", "Hanner")])
        #expect(dimension.kind == .exact)
    }

    /// The corpus pair the keyer was chosen for.
    @Test func phoneticVariantScoresPhonetic() {
        let (dimension, algorithm) = NameMatching.score(
            recorded: "Marcus Hanaur", script: nil, against: [name("Marcus", "Hanner")])
        #expect(dimension.kind == .phonetic)
        #expect(dimension.score >= 60)
        #expect(dimension.score < 100)
        #expect(algorithm == DaitchMokotoff.algorithmName)
    }

    /// The other half of `DaitchMokotoffTests.fayAndFayeKeyApart`: a pair the keyer
    /// misses is still caught, as a graded near miss carrying how far off it was.
    /// This is the case that justifies the edit-distance term existing at all.
    @Test func fayAndFayeMatchDespiteDifferentKeys() {
        #expect(
            DaitchMokotoff.codes(for: "Fay").isDisjoint(with: DaitchMokotoff.codes(for: "Faye")))

        let (dimension, algorithm) = NameMatching.score(
            recorded: "Faye Hanner", script: nil, against: [name("Fay", "Hanner")])
        #expect(dimension.kind == .within)
        #expect(dimension.score >= 85)
        #expect(dimension.delta == 100 - dimension.score)
        // No keyer produced this match, so `nameAlgo` must not claim one did.
        #expect(algorithm == nil)
    }

    /// A clerical slip that changes the phonetic key entirely.
    @Test func clericalSlipIsANearMiss() {
        let (dimension, _) = NameMatching.score(
            recorded: "Sidney Feldbers", script: nil, against: [name("Sidney", "Feldberg")])
        #expect(dimension.kind == .within)
    }

    /// Two unrelated names score zero, not "a little bit".
    @Test func unrelatedNamesScoreNone() {
        let (dimension, _) = NameMatching.score(
            recorded: "Esther Rudnik", script: nil, against: [name("Irving", "Feldberg")])
        #expect(dimension.kind == .none)
        #expect(dimension.score == 0)
    }

    /// An americanization is not a phonetic match, and slice 45 has no variant table —
    /// so this correctly scores as a miss. Pinned so the day a variant table lands,
    /// this test is what changes.
    ///
    /// `Zelig`/`Sidney` is the genuine case: one man, his Yiddish name and the
    /// American one he took, sharing a surname. (This previously read `Szlama`/`Sidney`,
    /// who are father and son — a pair no variant table should ever match.)
    @Test func americanizationIsNotYetMatched() {
        let (dimension, _) = NameMatching.score(
            recorded: "Zelig Feldberg", script: nil, against: [name("Sidney", "Feldberg")])
        #expect(dimension.kind != .exact)
        #expect(dimension.score < 60)
    }

    // MARK: - Multiple names and token handling

    /// Every name a person carries is a candidate — a document records whichever it
    /// knew, and the best one wins.
    @Test func bestOfAllNamesWins() {
        let person = [
            name("Chana", "Kotler", type: .birth),
            name("Lillian", "Kotler", type: .married),
        ]
        let (dimension, _) = NameMatching.score(
            recorded: "Lillian Kotler", script: nil, against: person)
        #expect(dimension.kind == .exact)
    }

    /// Word order is not stable across record traditions, so names compare as token
    /// sets rather than as ordered strings.
    @Test func tokenOrderDoesNotMatter() {
        let (dimension, _) = NameMatching.score(
            recorded: "Hanner Marcus", script: nil, against: [name("Marcus", "Hanner")])
        #expect(dimension.kind == .exact)
    }

    /// A dropped middle name costs something but must not sink the pair — this is the
    /// single most common shape in the corpus.
    @Test func droppedMiddleNameStillMatchesWell() {
        let (dimension, _) = NameMatching.score(
            recorded: "Marcus Isaac Hanner", script: nil, against: [name("Marcus", "Hanner")])
        #expect(dimension.score >= 60)
        #expect(dimension.kind != .none)
    }

    /// One shared given name is not a match between two people — the coverage rule.
    @Test func oneSharedTokenIsNotAMatch() {
        let (dimension, _) = NameMatching.score(
            recorded: "Marcus Hanner", script: nil, against: [name("Marcus", "Feldberg")])
        #expect(dimension.kind == .none)
    }

    // MARK: - Script gating

    /// A Cyrillic name is not keyed with a Latin keyer (44h's whole reason for
    /// `nameScript`): phonetic matching is skipped, and the comparison falls back to
    /// exact/edit-distance, which are script-agnostic.
    @Test func nonLatinScriptSkipsThePhoneticKeyer() {
        let (dimension, algorithm) = NameMatching.score(
            recorded: "Мотек", script: "Cyrl", against: [name("Motek", nil)])
        #expect(algorithm == nil)
        #expect(dimension.kind != .phonetic)
    }

    /// An identical Cyrillic name still matches exactly — skipping the keyer must not
    /// disable matching altogether.
    @Test func nonLatinScriptStillMatchesExactly() {
        let (dimension, _) = NameMatching.score(
            recorded: "Мотек", script: "Cyrl",
            against: [name("Мотек", nil, script: "Cyrl")])
        #expect(dimension.kind == .exact)
    }

    /// An absent script is treated as keyable — almost every name in the corpus is
    /// Latin and untagged, and refusing to key them would disable phonetics entirely.
    @Test func absentScriptIsKeyable() {
        #expect(NameScript.isKeyable(nil))
        #expect(NameScript.isKeyable("Latn"))
        #expect(!NameScript.isKeyable("Cyrl"))
        #expect(!NameScript.isKeyable("Hebr"))
    }

    // MARK: - Degenerate input

    /// A person with no usable name can't be matched, and must not crash.
    @Test func namelessPersonScoresNone() {
        let (dimension, _) = NameMatching.score(
            recorded: "Marcus Hanner", script: nil, against: [])
        #expect(dimension.kind == .none)
        #expect(dimension.score == 0)

        let (blank, _) = NameMatching.score(
            recorded: "", script: nil, against: [name("Marcus", "Hanner")])
        #expect(blank.kind == .none)
    }

    // MARK: - Determinism

    /// A stored score must mean the same thing when it is read back months later.
    @Test func scoringIsDeterministic() {
        let candidates = [name("Marcus", "Hanner"), name("Meir", "Hanner")]
        let first = NameMatching.score(recorded: "Marcus Hanaur", script: nil, against: candidates)
        for _ in 0..<20 {
            let again = NameMatching.score(
                recorded: "Marcus Hanaur", script: nil, against: candidates)
            #expect(again.dimension == first.dimension)
            #expect(again.algorithm == first.algorithm)
        }
    }
}

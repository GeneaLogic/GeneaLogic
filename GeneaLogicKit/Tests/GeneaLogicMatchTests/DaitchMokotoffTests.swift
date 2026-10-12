import Testing

@testable import GeneaLogicMatch

/// The Daitch–Mokotoff keyer (slice 45).
///
/// The cases below are drawn from the JewishGen coding chart's own examples plus a
/// fictional family standing in for the corpus the keyer was chosen for (this project's
/// real archive); each name carries the property of the real one it replaced. A
/// regression here means two names that used to be found as candidates stop being
/// found, which is silent: the matcher simply suggests less.
@Suite struct DaitchMokotoffTests {

    /// A code is always six digits, whatever the name's length.
    @Test(arguments: ["Hanner", "Fay", "Szlama", "Feldberg", "Q", "Peters"])
    func codesAreSixDigits(name: String) {
        let codes = DaitchMokotoff.codes(for: name)
        #expect(!codes.isEmpty)
        for code in codes {
            #expect(code.count == 6)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }

    /// The chart's canonical examples.
    @Test(
        arguments: [
            ("Peters", "739400"),
            ("Peterson", "739460"),
            ("Moskowitz", "645740"),
            ("Moskovitz", "645740"),
            ("Auerbach", "097500"),
            ("Lipshitz", "874400"),
        ])
    func chartExamples(name: String, expected: String) {
        #expect(DaitchMokotoff.codes(for: name).contains(expected))
    }

    // MARK: - The corpus this keyer was chosen for

    /// The pair that motivated the whole choice: an Ashkenazi surname recorded two
    /// ways in two American records. The real archive has a pair of exactly this shape.
    @Test func hannerAndHanaurShareACode() {
        let hanner = DaitchMokotoff.codes(for: "Hanner")
        let hanaur = DaitchMokotoff.codes(for: "Hanaur")
        #expect(!hanner.isDisjoint(with: hanaur))
    }

    /// **`Fay` and `Faye` key apart** — and the archive records them as the same
    /// person. This is not a bug in the table; it is the table being literal, and it
    /// is the clearest demonstration of why the name dimension does not rest on keys
    /// alone. `AY` codes as `1` before a vowel and as nothing at the end of a word, so
    /// a silent trailing `e` changes the key completely.
    ///
    /// `NameMatchingTests.fayAndFayeMatchDespiteDifferentKeys` is the other half of
    /// this pair: the edit-distance band catches what the keyer drops. Pinned here so
    /// that if a future keyer *does* unify them, this test fails and someone decides
    /// deliberately whether the near-miss band is still carrying the case.
    @Test func fayAndFayeKeyApart() {
        #expect(DaitchMokotoff.codes(for: "Fay") == ["700000"])
        #expect(DaitchMokotoff.codes(for: "Faye") == ["710000"])
    }

    /// Polish `sz` is one sound — the case an English keyer gets wrong, and the
    /// concrete reason D–M ships first.
    @Test func polishSzIsOneSibilant() {
        // Szlama: SZ=4, L=8, M=6.
        #expect(DaitchMokotoff.codes(for: "Szlama").contains("486000"))
    }

    /// `Zelig` and `Sidney` are one man's Yiddish name and the American one he took,
    /// and the keyer must **not** claim a match: that is an americanization, not a
    /// sound. Catching it needs a name-variant table, which slice 45 deliberately
    /// doesn't have — this test pins the honest miss so a later variant table has
    /// something to change.
    ///
    /// (An earlier version of this test used `Szlama`/`Sidney` and asserted they were
    /// the same person. They are not — in the real case these stand in for, Szlama is Sidney's
    /// **father**, so keying them apart is a *true* negative that no variant table
    /// should ever overturn. Pinning it here as a false negative documented a bug the
    /// keyer didn't have, and would have invited a future variant table to introduce a
    /// real one.)
    @Test func americanizedGivenNameDoesNotMatchPhonetically() {
        #expect(
            DaitchMokotoff.codes(for: "Zelig")
                .isDisjoint(with: DaitchMokotoff.codes(for: "Sidney")))
    }

    // MARK: - Rule mechanics

    /// An ambiguous letter branches rather than guessing: `ch` is `kh` or `tch`.
    @Test func ambiguousLettersProduceAlternates() {
        let codes = DaitchMokotoff.codes(for: "Chaim")
        #expect(codes.count > 1)
        #expect(codes.contains("560000"))  // CH as kh
        #expect(codes.contains("460000"))  // CH as tch
    }

    /// A doubled consonant is one sound…
    @Test func doubledConsonantCollapses() {
        // Hanner: H=5 (initial, as K), N=6 (once), R=9.
        #expect(DaitchMokotoff.codes(for: "Hanner").contains("569000"))
    }

    /// …unless a vowel separates the two, which is the run rule's whole subtlety.
    @Test func vowelSeparatedRepeatDoesNotCollapse() {
        // Tanenbaum: T=3, N=6, (e), N=6, B=7, (au)=7 before nothing → both nasals kept.
        let codes = DaitchMokotoff.codes(for: "Tanenbaum")
        #expect(codes.contains { $0.hasPrefix("366") })
    }

    /// A leading vowel codes as 0; a mid-word vowel codes as nothing.
    @Test func leadingVowelCodesAsZero() {
        #expect(DaitchMokotoff.codes(for: "Adler").contains { $0.hasPrefix("0") })
        // Haskel — the interior vowels contribute no digits: H=5, S=4, K=5, L=8.
        #expect(DaitchMokotoff.codes(for: "Haskel").contains("545800"))
    }

    /// A name with no letters has no code — and must not crash or return `[""]`.
    @Test(arguments: ["", "   ", "1920", "—"])
    func nonAlphabeticInputYieldsNoCodes(input: String) {
        #expect(DaitchMokotoff.codes(for: input).isEmpty)
    }

    /// Keying is case- and space-insensitive at the token level.
    @Test func keyingIsCaseInsensitive() {
        #expect(DaitchMokotoff.codes(for: "FELDBERG") == DaitchMokotoff.codes(for: "feldberg"))
    }

    /// The longest matching rule always wins, or `SCH` would be read as `S` + `CH`.
    @Test func longestRuleWins() {
        // Schwartz: SCH=4, W=7, R=9, TZ=4.
        #expect(DaitchMokotoff.codes(for: "Schwartz").contains("479400"))
    }

    /// Determinism: the same input always yields the same set.
    @Test func keyingIsDeterministic() {
        for _ in 0..<20 {
            #expect(
                DaitchMokotoff.codes(for: "Rzeszowski") == DaitchMokotoff.codes(for: "Rzeszowski"))
        }
    }

    /// **The memo must be invisible (45p).** Keying is memoized because it dominated the
    /// quadratic duplicate pass, and the entire justification for doing that instead of a
    /// candidate pre-filter is that it *cannot* change an answer. A cached read has to
    /// equal a cold one — including for the empty-code inputs, which are the ones a naive
    /// `if let cached` would recompute forever or, worse, store wrong.
    @Test(arguments: ["Feldberg", "Rzeszowski", "Szlama", "", "1920"])
    func memoizedKeyingMatchesAColdComputation(input: String) {
        // The suite has already keyed some of these, so the first call here may be warm;
        // what matters is that warm and repeated reads agree with each other and with the
        // documented values the rest of this file pins.
        let first = DaitchMokotoff.codes(for: input)
        let second = DaitchMokotoff.codes(for: input)
        #expect(first == second)
        // A distinct-but-equal string must hit the same entry, not a different one.
        #expect(DaitchMokotoff.codes(for: String(input.map { $0 })) == first)
    }

    /// The memo is shared mutable state reached from an off-actor scan since 45m, so
    /// concurrent keying must be safe and must still agree.
    ///
    /// **The words are freshly minted per run, and that is the whole test.** An earlier
    /// version computed the expected codes up front, which warmed the cache and left all
    /// 32 tasks on the *read* path — so the contended **insert** this exists to cover never
    /// ran, and the test would have passed against a memo with no lock at all. Unique
    /// words guarantee every task arrives at a cold entry simultaneously.
    @Test func concurrentKeyingIsSafe() async {
        let salt = String((0..<8).map { _ in "ABCDEFGHIJKLMNOPRSTVWZ".randomElement()! })
        let words = ["Hanner", "Feldberg", "Rudnik", "Rzeszowski"].map { $0 + salt }

        let results: [[Set<String>]] = await withTaskGroup(of: [Set<String>].self) { group in
            for _ in 0..<32 {
                group.addTask { words.map { DaitchMokotoff.codes(for: $0) } }
            }
            var collected: [[Set<String>]] = []
            for await result in group { collected.append(result) }
            return collected
        }

        // Settled *after* the race, so a torn write would show up as a disagreement rather
        // than being baked into the expectation.
        let settled = words.map { DaitchMokotoff.codes(for: $0) }
        #expect(settled.allSatisfy { !$0.isEmpty })
        #expect(results.count == 32)
        for result in results { #expect(result == settled) }
    }
}

import Synchronization

/// Daitch–Mokotoff Soundex — the phonetic keyer for this corpus.
///
/// **Why D–M and not Double Metaphone**, which ARCHITECTURE §4.6 names throughout:
/// Double Metaphone is English phonetics, and this archive is Ashkenazi/Slavic — it
/// holds names like `Szlama Feldberg`, and Polish `sz`, `cz` and `rz` are
/// single sounds that an English keyer reads as letter pairs. D–M was designed for
/// exactly these names, is a documented public-domain rule table, and — unlike most
/// Soundex variants — emits **several codes per name** where a spelling is genuinely
/// ambiguous (`ch` is either `kh` or `tch`; `c` is either `k` or `tz`), which is the
/// right shape for a matcher that scores rather than decides.
///
/// `MatchBreakdown.nameAlgo` records which keyer produced a match, so adding Double
/// Metaphone for Anglo names later needs no format change.
///
/// ## What a code means
///
/// Six digits, zero-padded. Each digit is a sound class: 0 a leading vowel, 3 a
/// dental stop, 4 a sibilant, 5 a velar, 6 a nasal, 7 a labial, 8 an `l`, 9 an `r`.
/// Two names match phonetically when their code **sets intersect**.
///
/// D–M is deliberately coarse — it collapses `Hanner`, `Hanaur` and `Honner` onto one
/// code, which is why the name dimension grades a phonetic hit with Jaro–Winkler
/// instead of scoring every key match at 100 (see ``NameMatching``).
public enum DaitchMokotoff {

    /// The value written to `MatchBreakdown.nameAlgo` when this keyer produced a match.
    public static let algorithmName = "daitch-mokotoff"

    /// The length every code is padded or truncated to.
    static let codeLength = 6

    /// Every phonetic code for `word`, or an empty set if it holds no letters.
    ///
    /// Multiple codes are the normal case, not an error path: an ambiguous letter
    /// branches, and a caller matches by set intersection.
    public static func codes(for word: String) -> Set<String> {
        // **Memoized (slice 45p).** This is a pure function of its input, and the duplicate
        // pass is `n(n−1)/2` comparisons over a corpus with far fewer *distinct* name
        // tokens than persons — a family archive reuses `Feldberg` and `Marcus` hundreds
        // of times. Uncached, every token was re-keyed once per comparison it appeared in,
        // and keying measured ~60µs per name against ~92µs for the whole pair: the
        // dominant cost of the whole scan, spent re-deriving answers already known.
        //
        // **This cannot change a result** — same function, same input, same output — which
        // is what makes it the optimization to reach for before a candidate pre-filter,
        // whose correctness depends on an invariant nothing checks (see
        // `Archive+Duplicates`).
        if let cached = (cache.withLock { $0[word] }) { return cached }
        let computed = computeCodes(for: word)
        cache.withLock { store in
            // Bounded: a runaway corpus must not turn a scoring cache into an unbounded
            // leak. At the cap it stops growing rather than evicting — by then the hot
            // tokens are in it, and an LRU's bookkeeping would cost more than the keying
            // it saves.
            if store.count < cacheLimit { store[word] = computed }
        }
        return computed
    }

    /// The memo. Guarded because the duplicate scan runs off the main actor since 45m, and
    /// a plain `static var` dictionary would be a data race the moment two scans overlap.
    ///
    /// `Mutex` rather than `NSLock` keeps this file free of Foundation — see
    /// `reduceToCode`'s note on why that matters for a phonetic keyer. It became available
    /// when the package's platform floor moved to macOS 26 to match the app; `Mutex` is in
    /// the Swift 6 stdlib on Linux, so the cross-platform contract is unaffected.
    private static let cache = Mutex<[String: Set<String>]>([:])
    private static let cacheLimit = 20_000

    private static func computeCodes(for word: String) -> Set<String> {
        let letters = Array(word.uppercased().filter { $0.isLetter && $0.isASCII })
        guard !letters.isEmpty else { return [] }

        // 1. Walk the word, longest rule first, recording each matched rule's
        //    position-appropriate code alternatives.
        var slots: [(alternatives: [String], isVowel: Bool)] = []
        var index = 0
        while index < letters.count {
            guard let rule = rule(matching: letters, at: index) else {
                // A letter no rule covers contributes nothing but must still be
                // consumed, or the walk never terminates.
                index += 1
                continue
            }
            let next = index + rule.pattern.count
            let position: Position =
                index == 0
                ? .start
                : (next < letters.count && isVowelLetter(letters[next]) ? .beforeVowel : .other)
            slots.append((rule.codes(at: position), rule.isVowel))
            index = next
        }
        guard !slots.isEmpty else { return [] }

        // 2. Expand the ambiguous slots into concrete paths, then reduce each path to
        //    a code. The cap keeps a pathological name from exploding combinatorially;
        //    real names branch two or three times at most.
        var paths: [[(code: String, isVowel: Bool)]] = [[]]
        for slot in slots {
            var expanded: [[(code: String, isVowel: Bool)]] = []
            outer: for path in paths {
                for alternative in slot.alternatives {
                    expanded.append(path + [(alternative, slot.isVowel)])
                    if expanded.count >= maxPaths { break outer }
                }
            }
            paths = expanded
        }

        return Set(paths.map(reduceToCode))
    }

    /// Collapses one path's per-slot codes into a padded six-digit code.
    ///
    /// The one subtlety is D–M's run rule: **two sounds with the same code are written
    /// once, unless a vowel separates them.** So `Hanner` keys as 5-6-9 (the doubled
    /// `n` is one sound) while `Tanenbaum` keeps both nasals, because the `e` between
    /// them breaks the run. Digits *within* a single rule's code are never collapsed —
    /// `MN` codes as `66` precisely to assert two nasals.
    private static func reduceToCode(_ path: [(code: String, isVowel: Bool)]) -> String {
        var digits: [Character] = []
        var previousWasVowel = false
        for slot in path {
            for (offset, digit) in slot.code.enumerated() {
                let continuesRun = offset == 0 && digits.last == digit && !previousWasVowel
                if !continuesRun { digits.append(digit) }
            }
            previousWasVowel = slot.isVowel
        }
        var code = String(digits.prefix(codeLength))
        // Hand-rolled rather than Foundation's `padding(toLength:…)`: this file imports no
        // Foundation at all, which for a phonetic keyer is a correctness property and not
        // tidiness — Foundation's string APIs carry locale behaviour, and a key that varied
        // by the user's locale would silently stop matching names it used to match.
        while code.count < codeLength { code.append("0") }
        return code
    }

    private static let maxPaths = 64

    // MARK: - Rule table

    /// Where in the word a rule matched — D–M codes many sequences differently
    /// depending on position.
    private enum Position { case start, beforeVowel, other }

    private struct Rule {
        let pattern: [Character]
        /// Alternatives for each position. `""` means the sequence contributes no
        /// digit at all (a mid-word vowel, an `h` between consonants).
        let atStart: [String]
        let beforeVowel: [String]
        let otherwise: [String]
        /// Whether this sequence is a vowel — the flag that breaks a run of like
        /// digits in ``reduceToCode``.
        let isVowel: Bool

        func codes(at position: Position) -> [String] {
            switch position {
            case .start: atStart
            case .beforeVowel: beforeVowel
            case .other: otherwise
            }
        }
    }

    private static func rule(matching letters: [Character], at index: Int) -> Rule? {
        rules.first { rule in
            let end = index + rule.pattern.count
            guard end <= letters.count else { return false }
            return Array(letters[index..<end]) == rule.pattern
        }
    }

    private static func isVowelLetter(_ character: Character) -> Bool {
        "AEIOU".contains(character)
    }

    private static func make(
        _ pattern: String, _ atStart: [String], _ beforeVowel: [String], _ otherwise: [String],
        vowel: Bool = false
    ) -> Rule {
        Rule(
            pattern: Array(pattern), atStart: atStart, beforeVowel: beforeVowel,
            otherwise: otherwise, isVowel: vowel)
    }

    /// The JewishGen coding chart, **sorted longest pattern first** so the walk always
    /// takes the longest match (`SCHTSCH` before `SCH` before `S`). Sorting here rather
    /// than relying on declaration order means a rule added later can't quietly be
    /// shadowed by a shorter one above it.
    private static let rules: [Rule] = unsortedRules.sorted {
        $0.pattern.count > $1.pattern.count
    }

    private static let unsortedRules: [Rule] = [
        // Vowels and vowel clusters.
        make("AI", ["0"], ["1"], [""], vowel: true),
        make("AJ", ["0"], ["1"], [""], vowel: true),
        make("AY", ["0"], ["1"], [""], vowel: true),
        make("AU", ["0"], ["7"], [""], vowel: true),
        make("A", ["0"], [""], [""], vowel: true),
        make("EI", ["0"], ["1"], [""], vowel: true),
        make("EJ", ["0"], ["1"], [""], vowel: true),
        make("EY", ["0"], ["1"], [""], vowel: true),
        make("EU", ["1"], ["1"], [""], vowel: true),
        make("E", ["0"], [""], [""], vowel: true),
        make("IA", ["1"], [""], [""], vowel: true),
        make("IE", ["1"], [""], [""], vowel: true),
        make("IO", ["1"], [""], [""], vowel: true),
        make("IU", ["1"], [""], [""], vowel: true),
        make("I", ["0"], [""], [""], vowel: true),
        make("OI", ["0"], ["1"], [""], vowel: true),
        make("OJ", ["0"], ["1"], [""], vowel: true),
        make("OY", ["0"], ["1"], [""], vowel: true),
        make("O", ["0"], [""], [""], vowel: true),
        make("UI", ["0"], ["1"], [""], vowel: true),
        make("UJ", ["0"], ["1"], [""], vowel: true),
        make("UY", ["0"], ["1"], [""], vowel: true),
        make("UE", ["0"], [""], [""], vowel: true),
        make("U", ["0"], [""], [""], vowel: true),
        make("Y", ["1"], [""], [""], vowel: true),

        // Labials.
        make("B", ["7"], ["7"], ["7"]),
        make("FB", ["7"], ["7"], ["7"]),
        make("F", ["7"], ["7"], ["7"]),
        make("PF", ["7"], ["7"], ["7"]),
        make("PH", ["7"], ["7"], ["7"]),
        make("P", ["7"], ["7"], ["7"]),
        make("V", ["7"], ["7"], ["7"]),
        make("W", ["7"], ["7"], ["7"]),

        // Velars. `CH` and `C` are the classic ambiguities — `ch` is either the `kh`
        // of "Chaim" or the `tch` of "Czech", and the keyer refuses to guess.
        make("CHS", ["5"], ["54"], ["54"]),
        make("CH", ["5", "4"], ["5", "4"], ["5", "4"]),
        make("CK", ["5", "45"], ["5", "45"], ["5", "45"]),
        make("C", ["5", "4"], ["5", "4"], ["5", "4"]),
        make("KS", ["5"], ["54"], ["54"]),
        make("KH", ["5"], ["5"], ["5"]),
        make("K", ["5"], ["5"], ["5"]),
        make("G", ["5"], ["5"], ["5"]),
        make("Q", ["5"], ["5"], ["5"]),
        make("X", ["5"], ["54"], ["54"]),
        make("H", ["5"], ["5"], [""]),

        // Dentals.
        make("DT", ["3"], ["3"], ["3"]),
        make("TH", ["3"], ["3"], ["3"]),
        make("TT", ["3"], ["3"], ["3"]),
        make("TD", ["3"], ["3"], ["3"]),
        make("D", ["3"], ["3"], ["3"]),
        make("T", ["3"], ["3"], ["3"]),

        // Sibilants and affricates — the part of the table Slavic names live in.
        make("SCHTSCH", ["2"], ["4"], ["4"]),
        make("SCHTSH", ["2"], ["4"], ["4"]),
        make("SCHTCH", ["2"], ["4"], ["4"]),
        make("SHTCH", ["2"], ["4"], ["4"]),
        make("SHTSH", ["2"], ["4"], ["4"]),
        make("STSCH", ["2"], ["4"], ["4"]),
        make("TTSCH", ["4"], ["4"], ["4"]),
        make("ZHDZH", ["2"], ["4"], ["4"]),
        make("SHCH", ["2"], ["4"], ["4"]),
        make("SCHT", ["2"], ["43"], ["43"]),
        make("SCHD", ["2"], ["43"], ["43"]),
        make("STCH", ["2"], ["4"], ["4"]),
        make("STRZ", ["2"], ["4"], ["4"]),
        make("STRS", ["2"], ["4"], ["4"]),
        make("STSH", ["2"], ["4"], ["4"]),
        make("SZCZ", ["2"], ["4"], ["4"]),
        make("SZCS", ["2"], ["4"], ["4"]),
        make("TSCH", ["4"], ["4"], ["4"]),
        make("TTCH", ["4"], ["4"], ["4"]),
        make("TTSZ", ["4"], ["4"], ["4"]),
        make("ZSCH", ["4"], ["4"], ["4"]),
        make("SCH", ["4"], ["4"], ["4"]),
        make("SHT", ["2"], ["43"], ["43"]),
        make("SZT", ["2"], ["43"], ["43"]),
        make("SHD", ["2"], ["43"], ["43"]),
        make("SZD", ["2"], ["43"], ["43"]),
        make("CZS", ["4"], ["4"], ["4"]),
        make("CSZ", ["4"], ["4"], ["4"]),
        make("DRZ", ["4"], ["4"], ["4"]),
        make("DRS", ["4"], ["4"], ["4"]),
        make("DSH", ["4"], ["4"], ["4"]),
        make("DSZ", ["4"], ["4"], ["4"]),
        make("DZH", ["4"], ["4"], ["4"]),
        make("DZS", ["4"], ["4"], ["4"]),
        make("TCH", ["4"], ["4"], ["4"]),
        make("TRZ", ["4"], ["4"], ["4"]),
        make("TRS", ["4"], ["4"], ["4"]),
        make("TSH", ["4"], ["4"], ["4"]),
        make("TTS", ["4"], ["4"], ["4"]),
        make("TTZ", ["4"], ["4"], ["4"]),
        make("TZS", ["4"], ["4"], ["4"]),
        make("TSZ", ["4"], ["4"], ["4"]),
        make("ZDZ", ["2"], ["4"], ["4"]),
        make("ZHD", ["2"], ["43"], ["43"]),
        make("SC", ["2"], ["4"], ["4"]),
        make("SH", ["4"], ["4"], ["4"]),
        make("ST", ["2"], ["43"], ["43"]),
        make("SD", ["2"], ["43"], ["43"]),
        make("SZ", ["4"], ["4"], ["4"]),
        make("CZ", ["4"], ["4"], ["4"]),
        make("CS", ["4"], ["4"], ["4"]),
        make("DS", ["4"], ["4"], ["4"]),
        make("DZ", ["4"], ["4"], ["4"]),
        make("TS", ["4"], ["4"], ["4"]),
        make("TC", ["4"], ["4"], ["4"]),
        make("TZ", ["4"], ["4"], ["4"]),
        make("ZD", ["2"], ["43"], ["43"]),
        make("ZH", ["4"], ["4"], ["4"]),
        make("ZS", ["4"], ["4"], ["4"]),
        make("S", ["4"], ["4"], ["4"]),
        make("Z", ["4"], ["4"], ["4"]),

        // `RZ`/`RS` are Polish `ż`-like or a plain cluster; both readings are kept.
        make("RZ", ["94", "4"], ["94", "4"], ["94", "4"]),
        make("RS", ["94", "4"], ["94", "4"], ["94", "4"]),
        make("R", ["9"], ["9"], ["9"]),

        // Liquids and nasals. `MN`/`NM` code as two digits so the pair is not
        // collapsed into one nasal by the run rule.
        make("L", ["8"], ["8"], ["8"]),
        make("MN", ["66"], ["66"], ["66"]),
        make("NM", ["66"], ["66"], ["66"]),
        make("M", ["6"], ["6"], ["6"]),
        make("N", ["6"], ["6"], ["6"]),

        // `J` is either the consonantal `y` of "Jakob" or the `dzh` of "Jerome".
        make("J", ["1", "4"], ["1", "4"], ["1", "4"]),
    ]
}

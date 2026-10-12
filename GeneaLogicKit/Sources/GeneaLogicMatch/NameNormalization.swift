import Foundation

/// Unicode-aware name normalization — the first step of every name comparison.
///
/// Historical names arrive spelled every possible way: `"Łomża"` and `"Lomza"`,
/// `"O'Brien"` and `"OBrien"`, `"MEYER"` and `"Meyer"`, a name typed with a combining
/// acute and the same name typed with a precomposed one. None of those differences
/// mean anything to a matcher, and all of them break naïve `==`.
///
/// Foundation is fine here (CLAUDE.md bans only the UI frameworks), and the calls
/// used — canonical composition and `folding` — exist on swift-corelibs-foundation,
/// so this compiles and behaves identically on Linux.
enum NameNormalization {

    /// Normalizes a name fragment for comparison: NFC, case-folded, diacritics
    /// stripped, punctuation reduced to nothing, whitespace collapsed.
    ///
    /// **Diacritics are stripped rather than preserved** because the corpus this
    /// serves is precisely one where the same person's name appears with and without
    /// them — a Polish record's `Łomża` and an American clerk's `Lomza` are the same
    /// place, and `Müller`/`Mueller`/`Muller` the same family. Keeping them would make
    /// the passage of a name through Ellis Island look like a mismatch.
    ///
    /// Note `folding(options: .diacriticInsensitive)` does not decompose every Latin
    /// letter with a stroke — `ł` is a distinct letter, not `l` + a combining mark, so
    /// it survives folding. The stroke table below handles those explicitly; without
    /// it `Łomża` and `Lomza` would still differ in their first character.
    static func normalize(_ text: String) -> String {
        let composed = text.precomposedStringWithCanonicalMapping
        let folded = composed.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil)

        var out = String()
        out.reserveCapacity(folded.count)
        var lastWasSpace = true  // leading whitespace is dropped
        for character in folded {
            let mapped = strokedLatin[character] ?? character
            if mapped.isLetter || mapped.isNumber {
                out.append(mapped)
                lastWasSpace = false
            } else if mapped.isWhitespace {
                // Apostrophes and hyphens are dropped rather than turned into
                // separators: "O'Brien" is one name, and "Jean-Marie" splitting into
                // two tokens would let it match anyone called Jean.
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }

    /// Splits a normalized name into its word tokens.
    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    /// Latin letters whose diacritic is a *stroke* or otherwise survives
    /// `.diacriticInsensitive` folding. Restricted to the letters this corpus
    /// actually turns up (Polish, Scandinavian, German, Croatian).
    private static let strokedLatin: [Character: Character] = [
        "ł": "l", "Ł": "l",
        "đ": "d", "Đ": "d",
        "ø": "o", "Ø": "o",
        "ħ": "h", "Ħ": "h",
        "ŧ": "t", "Ŧ": "t",
    ]
}

// MARK: - Script

/// Whether a name can be keyed by a Latin-script phonetic algorithm.
///
/// Slice 44h added `nameScript` specifically so the matcher could ask this question
/// (its doc comment: keying `"Мотек"` with Latin phonetics "produces noise rather
/// than a match"). Slice 45 ships one keyer — Daitch–Mokotoff, which is Latin — so
/// the only honest answers are *key it* or *don't*.
enum NameScript {

    /// ISO 15924 codes this build has a keyer for.
    ///
    /// An **absent** script is treated as keyable: the overwhelming majority of names
    /// in this corpus are Latin and untagged, and refusing to key them would disable
    /// phonetic matching for almost every record. An explicitly non-Latin tag is
    /// believed, and phonetic matching is skipped for it — the name dimension then
    /// falls back to exact and edit-distance comparison, which are script-agnostic.
    static func isKeyable(_ script: String?) -> Bool {
        guard let script, !script.isEmpty else { return true }
        return script.caseInsensitiveCompare("Latn") == .orderedSame
    }
}

import Foundation
import GeneaLogicModel

/// Primitive generators the record generators are composed from (slice 62,
/// fork c). Everything draws from the `SeededGenerator` it is handed and nothing else
/// — no `UUID()`, no `Date()`, no `SystemRandomNumberGenerator` — which is what makes
/// a generated value a pure function of the seed.
public enum Gen {

    // MARK: - Strings

    /// Strings the format must carry unchanged and a naive encoder, comparator or
    /// filesystem would mangle. Each is legal JSON string content; none is a
    /// *malformed* input (that is slice 63's territory).
    public static let hostileStrings: [String] = [
        "",
        " ",
        "\t\n\r",  // whitespace the encoder must escape
        "\"quoted\" and back\\slash and /solidus",
        "control \u{01} \u{08} \u{0C} \u{1F} chars",
        "\u{0}",  // NUL, which the encoder writes as \u0000
        "line\u{2028}and\u{2029}paragraph separators",
        "é",  // NFC: one scalar
        "e\u{301}",  // NFD: e + combining acute — must NOT be folded to the line above
        "Łomża",
        "Мотек Штернфельд",
        "שלום עולם",  // RTL
        "مرحبا بالعالم",  // RTL with joining forms
        "日本語",
        "👨‍👩‍👧‍👦",  // ZWJ sequence: one grapheme, seven scalars
        "🇵🇱",  // regional-indicator pair
        "a\u{200B}b\u{FEFF}c",  // zero-width space, BOM mid-string
        "null", "true", "false", "0", "-0", "1e10", "NaN",  // JSON-lookalike text
        "{\"key\": [1, 2]}",  // JSON inside a string
        "ffl",  // ligature: NFKC-different, NFC-identical
        String(repeating: "x", count: 4_096),
        String(repeating: "ż", count: 1_024),
    ]

    /// A plain-text word, for the common case.
    public static func word(_ rng: inout SeededGenerator) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let length = Int.random(in: 1...12, using: &rng)
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// A string: usually plain text, sometimes one of `hostileStrings`. The rate is
    /// high on purpose — a record has many string fields and each draw is independent,
    /// so most generated records carry at least one hostile value somewhere.
    public static func string(_ rng: inout SeededGenerator) -> String {
        if Int.random(in: 0..<4, using: &rng) == 0 {
            return hostileStrings.randomElement(using: &rng)!
        }
        let words = Int.random(in: 1...4, using: &rng)
        return (0..<words).map { _ in word(&rng) }.joined(separator: " ")
    }

    // MARK: - Dates

    /// EDTF and plain ISO forms the spec (§3) says a date field may hold. Stored
    /// verbatim, so any string would round-trip; these make the *documented* shapes
    /// present in the corpus rather than leaving them to chance.
    public static let edtfDates: [String] = [
        "1871", "1920-01-15", "1920-01", "1920~", "1920?", "1920%", "1900/1905",
        "../1950", "1950/..", "192X", "18XX", "[1920, 1921]", "{1920, 1921}",
        "-0044", "Y17000", "1920-13",  // the last is malformed EDTF — still just a string
    ]

    public static func date(_ rng: inout SeededGenerator) -> String {
        Bool.random(using: &rng) ? edtfDates.randomElement(using: &rng)! : string(&rng)
    }

    /// A machine timestamp (full ISO 8601), deterministic from the generator.
    public static func timestamp(_ rng: inout SeededGenerator) -> String {
        let year = Int.random(in: 1970...2100, using: &rng)
        let month = Int.random(in: 1...12, using: &rng)
        let day = Int.random(in: 1...28, using: &rng)
        let hour = Int.random(in: 0...23, using: &rng)
        let minute = Int.random(in: 0...59, using: &rng)
        let second = Int.random(in: 0...59, using: &rng)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, hour, minute, second)
    }

    // MARK: - Identifiers and checksums

    /// A type-prefixed UUIDv7-shaped id, e.g. `PER-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70`.
    /// Shaped like the engine's, not minted by it — the model accepts any string.
    public static func recordID<ID: RecordID>(_ rng: inout SeededGenerator, prefix: String)
        -> ID
    {
        let hex = Array("0123456789abcdef")
        func run(_ n: Int) -> String {
            String((0..<n).map { _ in hex.randomElement(using: &rng)! })
        }
        return ID("\(prefix)-\(run(8))-\(run(4))-7\(run(3))-\(run(4))-\(run(12))")
    }

    /// A lowercase hex SHA-256 string (spec §3), not a hash of anything.
    public static func sha256(_ rng: inout SeededGenerator) -> String {
        let hex = Array("0123456789abcdef")
        return String((0..<64).map { _ in hex.randomElement(using: &rng)! })
    }

    // MARK: - Numbers

    /// A byte length: mostly ordinary sizes, sometimes the edges of `Int64`, since the
    /// spec's `byteLength` is an integer with no stated bound.
    public static func byteLength(_ rng: inout SeededGenerator) -> Int64 {
        switch Int.random(in: 0..<8, using: &rng) {
        case 0: return 0
        case 1: return Int64.max
        default: return Int64.random(in: 0...(1 << 40), using: &rng)
        }
    }

    /// A score in the matcher's 0–100 range, occasionally outside it: the format stores
    /// an integer and makes no promise about the range.
    public static func score(_ rng: inout SeededGenerator) -> Int {
        Int.random(in: 0..<10, using: &rng) == 0
            ? Int.random(in: Int.min...Int.max, using: &rng)
            : Int.random(in: 0...100, using: &rng)
    }

    // MARK: - Combinators

    /// `nil` half the time; the spec's optionals must round-trip both ways.
    public static func optional<T>(
        _ rng: inout SeededGenerator, _ make: (inout SeededGenerator) -> T
    ) -> T? {
        Bool.random(using: &rng) ? make(&rng) : nil
    }

    /// An array of 0–`max` elements, weighted toward short.
    public static func array<T>(
        _ rng: inout SeededGenerator, max: Int = 4, _ make: (inout SeededGenerator) -> T
    ) -> [T] {
        let count = Int.random(in: 0...max, using: &rng)
        return (0..<count).map { _ in make(&rng) }
    }

    /// A member of a closed vocabulary.
    public static func closed<T: CaseIterable>(_ rng: inout SeededGenerator) -> T {
        Array(T.allCases).randomElement(using: &rng)!
    }

    /// A member of an open vocabulary: a known case three times in four, otherwise a
    /// value the vocabulary does not know — routed through `init(parsing:)` so the
    /// generated case is exactly what a reader would produce for that string. (Building
    /// `.unknown("vital")` by hand would make a value that cannot round-trip, and that
    /// would be the generator's bug, not the format's.)
    public static func open<T: OpenVocabulary>(_ rng: inout SeededGenerator) -> T {
        if Int.random(in: 0..<4, using: &rng) == 0 {
            return T(parsing: unknownVocabularyTerm(&rng))
        }
        return T.knownCases.randomElement(using: &rng)!
    }

    /// A term no vocabulary lists — including the spellings a lenient reader would map
    /// to a known case, which the strict decoder must preserve verbatim (§7).
    public static func unknownVocabularyTerm(_ rng: inout SeededGenerator) -> String {
        let terms = [
            "Vital", "VITAL", " vital", "vital ", "parent_child", "Parent-Child",
            "gedcomx:Birth", "http://gedcomx.org/Birth", "", "🧬", "tier-9", "x",
        ]
        return Bool.random(using: &rng) ? terms.randomElement(using: &rng)! : string(&rng)
    }
}

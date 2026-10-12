/// Jaro–Winkler string similarity — the graded term behind the name dimension.
///
/// A phonetic key answers "do these sound alike?" with yes or no. That is not enough
/// on its own in both directions: D–M is coarse enough to collapse `Hanner`, `Hanaur`
/// and `Honner` onto one code (so a key hit alone would score three different degrees
/// of agreement identically), and a single transposed letter can change a key
/// completely (`Feldberg`/`Feldbers` key apart, but no researcher would call them
/// unrelated). Edit distance grades what the key can only classify.
///
/// Jaro–Winkler in particular, rather than plain Levenshtein: it boosts strings
/// sharing a prefix, which is the right bias for surnames — endings are what clerks
/// and immigration officers mangle, while the first syllables usually survive.
enum JaroWinkler {

    /// Similarity in `0.0...1.0`. Two empty strings are identical; one empty string
    /// matches nothing.
    static func similarity(_ a: String, _ b: String) -> Double {
        let left = Array(a)
        let right = Array(b)
        if left.isEmpty && right.isEmpty { return 1.0 }
        guard !left.isEmpty && !right.isEmpty else { return 0.0 }
        if left == right { return 1.0 }

        // Jaro: characters count as matching only within a window that scales with
        // the longer string, so distant coincidental repeats don't inflate the score.
        let window = max(max(left.count, right.count) / 2 - 1, 0)
        var leftMatched = [Bool](repeating: false, count: left.count)
        var rightMatched = [Bool](repeating: false, count: right.count)
        var matches = 0

        for i in left.indices {
            let low = max(0, i - window)
            let high = min(i + window, right.count - 1)
            guard low <= high else { continue }
            for j in low...high where !rightMatched[j] && left[i] == right[j] {
                leftMatched[i] = true
                rightMatched[j] = true
                matches += 1
                break
            }
        }
        guard matches > 0 else { return 0.0 }

        // Transpositions: matched characters that arrived in a different order.
        var transpositions = 0
        var k = 0
        for i in left.indices where leftMatched[i] {
            while !rightMatched[k] { k += 1 }
            if left[i] != right[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        let jaro =
            (m / Double(left.count) + m / Double(right.count)
                + (m - Double(transpositions / 2)) / m) / 3.0

        // Winkler's prefix boost, standard parameters: up to 4 leading characters,
        // scaling factor 0.1, applied only to already-similar strings so it can't
        // promote a pair that merely starts the same.
        guard jaro > boostThreshold else { return jaro }
        var prefix = 0
        for (x, y) in zip(left, right) {
            if x != y { break }
            prefix += 1
            if prefix == maxPrefix { break }
        }
        return jaro + Double(prefix) * scalingFactor * (1.0 - jaro)
    }

    private static let boostThreshold = 0.7
    private static let maxPrefix = 4
    private static let scalingFactor = 0.1
}

import GeneaLogicModel

/// The `name` dimension — the heaviest single signal in a match, and the only
/// dimension `MatchBreakdown` requires.
///
/// ## How a kind is chosen, and why the score is separate
///
/// The **kind** says how the match was reached; the **score** says how strongly.
/// Those are genuinely two questions, and collapsing them is what makes a coarse
/// keyer look authoritative:
///
/// - ``MatchKind/exact`` — the normalized names are equal. Score 100.
/// - ``MatchKind/phonetic`` — the D–M code sets intersect. Score graded by
///   Jaro–Winkler, floored, because a phonetic hit is real evidence even when the
///   spellings diverge (`Hanaur`/`Hanner`) but should not read as an exact match.
/// - ``MatchKind/within`` — the keys **differ** but the strings are close enough that
///   the difference reads as a clerk's slip (`Feldberg`/`Feldbers`), which a key
///   comparison alone would throw away entirely. `delta` carries how far off, in
///   points, so the UI can say *how* near a near miss was.
/// - ``MatchKind/none`` — no useful agreement. Score 0.
///
/// The `.within` band is the one non-obvious call here. `MatchKind` is a **closed**
/// vocabulary, so the choice was between reporting a near miss as `.phonetic` (a lie —
/// no keyer matched it), as `.none` with a non-zero score (self-contradictory), or as
/// `.within`, whose existing meaning is "inside a tolerance" and whose `delta` field
/// is already there for exactly this shape of answer. ``MatchKind/knownVariant`` is
/// deliberately never produced: it needs a name-variant table (the `Zelig`/`Sidney`
/// case — one man's Yiddish name and the American one he took), which is out of scope
/// for this slice.
public enum NameMatching {

    /// Scores a recorded name against every name a person carries, returning the best.
    ///
    /// All of a person's names are candidates, not just the birth one: a document
    /// records whatever name it knew, and matching a married or Americanized name is
    /// the normal case rather than an edge one.
    ///
    /// - Returns: the dimension, and the algorithm name to record in
    ///   `MatchBreakdown.nameAlgo` — non-`nil` only when a keyer actually ran and
    ///   produced the match, so the field never claims an algorithm did work it didn't.
    public static func score(
        recorded: String,
        script: String?,
        against names: [PersonName]
    ) -> (dimension: MatchDimension, algorithm: String?) {
        let candidates = names.compactMap(\.resolvedText)
        guard !candidates.isEmpty, !NameNormalization.normalize(recorded).isEmpty else {
            return (MatchDimension(kind: .none, score: 0), nil)
        }

        let keyable = NameScript.isKeyable(script)
        var best = MatchDimension(kind: .none, score: 0)
        var bestAlgorithm: String?

        for candidate in candidates {
            let scored = compare(
                recorded: recorded, candidate: candidate,
                keyable: keyable && NameScript.isKeyable(scriptOf(candidate, in: names)))
            if scored.score > best.score {
                best = scored
                bestAlgorithm = scored.kind == .phonetic ? DaitchMokotoff.algorithmName : nil
            }
        }
        return (best, bestAlgorithm)
    }

    /// Scores every name one person carries against every name another does, returning
    /// the best — the **symmetric** form of the dimension above (slice 45j).
    ///
    /// Both sides are conclusions here, so neither is "the recorded one": a document's
    /// name is compared against a person's list, but two *persons* each hold a list, and
    /// a duplicate is just as likely to be found through her married name on one record
    /// and her birth name on the other. So it is the full cross product, best-of.
    ///
    /// Not symmetric *by construction* — the greedy token pairing inside ``compare`` can
    /// in principle differ by argument order — so callers fix the order rather than hope.
    /// `Archive.duplicateCandidates` scores each pair in canonical uid order for exactly
    /// this reason.
    public static func score(
        _ names: [PersonName],
        against others: [PersonName]
    ) -> (dimension: MatchDimension, algorithm: String?) {
        var best = MatchDimension(kind: .none, score: 0)
        var bestAlgorithm: String?

        for name in names {
            guard let text = name.resolvedText else { continue }
            let (dimension, algorithm) = score(
                recorded: text, script: name.script, against: others)
            if dimension.score > best.score {
                best = dimension
                bestAlgorithm = algorithm
            }
        }
        return (best, bestAlgorithm)
    }

    /// Compares two full-name strings. Public because the relational dimensions
    /// (`spouseName`, `parents`) score names against names the same way, and because
    /// slice 45j's person↔person duplicate detection needs it.
    public static func compare(
        recorded: String,
        candidate: String,
        keyable: Bool = true
    ) -> MatchDimension {
        let recordedTokens = NameNormalization.tokens(recorded)
        let candidateTokens = NameNormalization.tokens(candidate)
        guard !recordedTokens.isEmpty, !candidateTokens.isEmpty else {
            return MatchDimension(kind: .none, score: 0)
        }

        // Sorted, not as written: the same tokens in a different order are the same
        // name. A Russian register writes the surname first and an American census
        // writes it last, and treating that as anything less than exact would demote
        // the most ordinary agreement in the corpus to a near miss.
        if recordedTokens.sorted() == candidateTokens.sorted() {
            return MatchDimension(kind: .exact, score: 100)
        }

        let similarity = tokenSetSimilarity(recordedTokens, candidateTokens)
        let phonetic = keyable && keysIntersect(recordedTokens, candidateTokens)

        if phonetic {
            // Floored well above zero: sounding alike is meaningful evidence on its
            // own, and the edit distance only modulates how much.
            let graded = phoneticFloor + Int((100.0 - Double(phoneticFloor)) * similarity)
            return MatchDimension(kind: .phonetic, score: min(graded, 99))
        }
        if similarity >= nearMissThreshold {
            let score = Scoring.clamped(similarity * 100)
            return MatchDimension(kind: .within, score: score, delta: 100 - score)
        }
        return MatchDimension(kind: .none, score: 0)
    }

    // MARK: - Token comparison

    /// Similarity between two token lists, as a greedy best-pairing mean.
    ///
    /// Names are compared as **token sets, not as ordered strings**, because word
    /// order is not stable across the records this matcher reads: a Russian register
    /// writes surname first, an American census writes it last, and a middle name or
    /// patronymic appears in one record and not the next.
    ///
    /// Unmatched tokens are penalized only as far as they dilute the mean — a dropped
    /// middle name should cost something, but it must not sink a pair whose given and
    /// surname both match, because that is the single most common shape in the corpus.
    private static func tokenSetSimilarity(_ a: [String], _ b: [String]) -> Double {
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        var available = longer
        var total = 0.0

        for token in shorter {
            var bestScore = 0.0
            var bestIndex: Int?
            for (index, other) in available.enumerated() {
                let score = JaroWinkler.similarity(token, other)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            if let bestIndex { available.remove(at: bestIndex) }
            total += bestScore
        }

        // Divide by the longer count so extra tokens dilute rather than being free.
        return total / Double(longer.count)
    }

    /// Whether any token of one name shares a phonetic code with any token of the
    /// other **and** the pairing covers the shorter name.
    ///
    /// Requiring coverage rather than a single shared token is what stops
    /// "Marcus Hanner" from keying against "Marcus Feldberg": one matching given name
    /// is not a phonetic match between two people.
    private static func keysIntersect(_ a: [String], _ b: [String]) -> Bool {
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        var available = longer.map { DaitchMokotoff.codes(for: $0) }

        for token in shorter {
            let codes = DaitchMokotoff.codes(for: token)
            guard !codes.isEmpty else { return false }
            guard let index = available.firstIndex(where: { !$0.isDisjoint(with: codes) })
            else { return false }
            available.remove(at: index)
        }
        return true
    }

    /// The script tag of whichever stored name resolved to `text`, so a Cyrillic
    /// stored name isn't keyed with a Latin keyer either.
    private static func scriptOf(_ text: String, in names: [PersonName]) -> String? {
        names.first { $0.resolvedText == text }?.script
    }

    /// A phonetic hit never scores below this, however far the spellings drift.
    private static let phoneticFloor = 60

    /// How similar two differently-keyed names must be to read as a near miss rather
    /// than as unrelated. Set high on purpose: this band exists for clerical slips,
    /// not for family resemblance.
    private static let nearMissThreshold = 0.88
}

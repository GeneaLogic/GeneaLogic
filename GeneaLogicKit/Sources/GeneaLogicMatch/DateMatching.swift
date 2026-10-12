import GeneaLogicModel

/// The `birthYear` dimension — birth-year proximity with a **century-widening
/// tolerance** (§4.6).
///
/// ## Why the tolerance widens with age
///
/// A birth year in a 1930 census is a number someone wrote down within living memory
/// of the event. A birth year in an 1840 parish record is frequently derived from a
/// stated age, which was itself a guess — ages were rounded, inflated to marry, and
/// deflated to emigrate. Holding an eighteenth-century record to the same two-year
/// tolerance as a modern one would reject correct matches as conflicts, so the
/// tolerance grows by a year per century before 1900.
///
/// A date that is a *range* (`"1890/1895"`) or approximate (`"1892~"`) is read through
/// `EDTFDate` like every other consumer, using its lower bound as the comparison year.
/// The qualification itself is not scored: `1892~` and `1892` compare identically,
/// because a researcher writing "about 1892" is telling you their precision, not a
/// different year.
public enum DateMatching {

    /// Scores two birth years against each other, or returns `nil` when either side
    /// doesn't state one.
    ///
    /// **`nil` means "not assessed", never "assessed and scored 0"** — the same rule
    /// `Archive.link()` follows for the optional dimensions of a manual link. Half the
    /// records in a corpus don't state a birth year, and reporting that absence as a
    /// zero would penalize a person for a silence in the document.
    public static func scoreBirthYear(recorded: Int?, concluded: Int?) -> MatchDimension? {
        guard let recorded, let concluded else { return nil }
        let delta = abs(recorded - concluded)
        if delta == 0 {
            return MatchDimension(kind: .exact, score: 100, delta: 0)
        }
        let allowed = tolerance(forYear: min(recorded, concluded))
        guard delta <= allowed else {
            // Beyond tolerance this is not a weak match, it is a disagreement — the
            // caller turns it into a conflict rather than averaging a low score in.
            return MatchDimension(kind: .none, score: 0, delta: delta)
        }
        // Linear from 100 down to 50 across the tolerance: a one-year slip is still a
        // strong signal, and the edge of the tolerance is still a coin-flip, not a miss.
        let score = Scoring.clamped(100.0 - 50.0 * Double(delta) / Double(allowed))
        return MatchDimension(kind: .within, score: score, delta: delta)
    }

    /// The year difference still read as agreement, for a birth around `year`.
    ///
    /// Two years at 1900 and later, widening by one per century before that, capped —
    /// past a point a wider tolerance stops discriminating between people at all.
    static func tolerance(forYear year: Int) -> Int {
        guard year < modernThreshold else { return baseTolerance }
        let centuries = (modernThreshold - year + 99) / 100
        return min(baseTolerance + centuries, maximumTolerance)
    }

    /// The first comparable year among `dates`, skipping absent and unparseable ones.
    ///
    /// Uses `sortBound` (the lower bound, falling back to the upper) so an open-ended
    /// interval like `"../1895"` still yields a comparable year instead of nothing.
    /// Unparseable free text is skipped rather than failing the whole lookup — the
    /// format permits a date the EDTF subset doesn't cover, and one such value must
    /// not hide a perfectly good date recorded beside it.
    static func firstYear(in dates: [String?]) -> Int? {
        for case let date? in dates {
            if let bound = EDTFDate.parse(date)?.sortBound { return bound.year }
        }
        return nil
    }

    private static let baseTolerance = 2
    private static let maximumTolerance = 6
    private static let modernThreshold = 1900
}

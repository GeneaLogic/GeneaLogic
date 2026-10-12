/// The one place a fractional intermediate becomes a stored score.
///
/// Every score and weight in `EvidenceLink` is an **integer 0–100** (slice 44h — float
/// text is not canonically reproducible without JCS/RFC 8785, which would put the
/// spec's byte-reproducibility promise out of reach for every record the matcher
/// writes). The scorers work in `Double` internally, so exactly one funnel back to
/// `Int` keeps rounding consistent: two callers rounding differently would make the
/// same pair score differently depending on which path reached it.
enum Scoring {

    /// Rounds a 0–100 value to the nearest integer and clamps it into range.
    ///
    /// `.toNearestOrAwayFromZero` is named explicitly rather than left to
    /// `rounded()`'s default so the tie-breaking rule is part of the contract: a score
    /// must be reproducible, and "whatever the default is" is not a reproducible rule.
    static func clamped(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        return min(max(Int(rounded), 0), 100)
    }
}

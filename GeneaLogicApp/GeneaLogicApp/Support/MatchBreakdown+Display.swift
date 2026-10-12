import GeneaLogicModel

/// App-layer rendering of a stored `MatchBreakdown` — the **reasoning** a suggestion is
/// reviewed on (§4.6), and the third register beside the CLI's `MatchFormat` (text) and
/// the on-disk JSON.
///
/// **The breakdown is the UI, not `aggregateConfidence`.** The whole reason the format
/// stores decomposed dimensions rather than a number is that "71%" is unexaminable: a
/// reviewer needs to see *the name matched exactly, the record named the known spouse,
/// the birth year is three years out*. So the aggregate never appears without the rows
/// beneath it.
///
/// Four honesty rules travel with it, deliberately identical to the ones `MatchFormat`
/// holds, so the two surfaces can be diffed against each other:
///
///   1. A `nil` dimension is **not assessed**, never `0`. These documents are silent
///      about most things, and *not assessed* is not *assessed and failed*.
///   2. A **relational** dimension that didn't agree is reported but **not scored**
///      (slice 45g's positive-only rule): a bare `none 0` beside a confidence figure
///      reads as *this is what dragged the score down*, and here it dragged nothing.
///   3. `granularity` renders from its raw value, so a value this build has no case for
///      (`admin2`, or a pre-45h `county` relocated on read) still reaches the reader.
///   4. `conflicts` are their own block, not an averaged-away term.
extension MatchBreakdown {

    /// The five §4.6 dimensions in a fixed order — name first, because it is the only
    /// one every record supplies, then the two fact dimensions, then the two relational
    /// ones. Absent dimensions are **kept**, rendering as *not assessed*: dropping them
    /// would silently turn "the record didn't say" into "we didn't look".
    var displayDimensions: [MatchDimensionDisplay] {
        [
            MatchDimensionDisplay(
                label: "Name", dimension: name, algorithm: nameAlgo),
            MatchDimensionDisplay(
                label: "Birth year", dimension: birthYear, deltaUnit: "years apart"),
            MatchDimensionDisplay(label: "Birth place", dimension: birthPlace),
            MatchDimensionDisplay(
                label: "Spouse name", dimension: spouseName, isRelational: true),
            MatchDimensionDisplay(label: "Parents", dimension: parents, isRelational: true),
        ]
    }

    /// A one-line summary of what actually **agreed**, for a candidate row that hasn't
    /// been expanded: `"Name exact · Spouse name exact · Birth year within, 3 years apart"`.
    ///
    /// Only agreeing dimensions appear. This is a *headline*, and the dimensions that
    /// said nothing (`nil`) or disagreed carry no headline — they are read in the rows
    /// below, where *not assessed* and *not scored* can be spelled out properly instead
    /// of compressed into a fragment. Empty when nothing agreed at all, which is itself
    /// the answer a reviewer needs.
    var agreementLine: String {
        displayDimensions
            .filter { $0.isAssessed && !$0.isUnscored && $0.dimension?.kind != MatchKind.none }
            .map { display in
                [display.label, display.kindLabel?.lowercased(), display.gloss]
                    .compactMap { $0 }
                    .joined(separator: " ")
            }
            .joined(separator: " · ")
    }
}

/// One dimension of a breakdown, ready to draw: the label, whether it was assessed at
/// all, and the score and gloss when it was.
struct MatchDimensionDisplay: Identifiable {
    let label: String
    let dimension: MatchDimension?
    /// What this dimension's `delta` counts. Supplied per dimension because it means
    /// different things: years apart for a birth year, but for a name it is `100 -
    /// score` — the same number twice — so the name row omits it.
    var deltaUnit: String?
    /// The keyer that ran (`nameAlgo`), on the name row only.
    var algorithm: String?
    /// Whether the roll-up reads this dimension **positive-only** (slice 45g).
    var isRelational: Bool = false

    /// The label is unique within a breakdown, so it is the identity — no synthetic id
    /// that would re-create rows on every reload.
    var id: String { label }

    /// Whether the record said anything about this dimension at all.
    var isAssessed: Bool { dimension != nil }

    /// Assessed, stated, and yet contributing nothing — a relational dimension whose
    /// names disagreed. The record *did* name a spouse or a parent, which is a lead
    /// worth reporting, but the disagreement is not evidence against the pair (a maiden
    /// name against a married one is the common case, not the suspicious one).
    var isUnscored: Bool { isRelational && dimension?.kind == MatchKind.none }

    /// The prettified kind, or `nil` when the dimension wasn't assessed.
    ///
    /// Switched exhaustively rather than derived from the raw value: `MatchKind` is a
    /// **closed** vocabulary (spec §7 — it describes how *this* matcher reached a
    /// verdict), so a case added to it should fail to compile here until it is given a
    /// label, which is the opposite of the open-vocabulary treatment `granularity` gets
    /// below.
    var kindLabel: String? {
        // Unwrapped first, then switched exhaustively over the non-optional. Switching
        // `dimension?.kind` directly makes `.none` ambiguous with `Optional.none` — which
        // is the same trap `MatchingTests` documents on the engine side, and here it is a
        // compile error rather than a silently wrong branch.
        guard let kind = dimension?.kind else { return nil }
        return switch kind {
        case .exact: "Exact"
        case .phonetic: "Phonetic"
        case .knownVariant: "Known variant"
        case .within: "Within"
        case .none: "No match"
        }
    }

    var scoreText: String? {
        dimension.map { "\($0.score)" }
    }

    /// The trailing detail: the delta in its unit, the granularity it agreed to, and the
    /// algorithm that produced it — whichever the dimension carries. `nil` when it
    /// carries none.
    var gloss: String? {
        guard let dimension else { return nil }
        var parts: [String] = []
        if let deltaUnit, let delta = dimension.delta {
            parts.append("\(delta) \(deltaUnit)")
        }
        // Rendered from the raw value through the shared open-vocabulary prettifier, so
        // a granularity this build has no case for still reads as a word rather than
        // being dropped or truncated into one that exists (slice 45h).
        if let granularity = dimension.granularity {
            parts.append("to \(prettifiedVocabularyLabel(granularity.rawValue).lowercased())")
        }
        if let algorithm, !algorithm.isEmpty {
            parts.append("via \(prettifiedVocabularyLabel(algorithm))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

import GeneaLogicModel

/// Entity resolution's **other** question: are these two **concluded persons** one
/// human being? (§4.1's entity duplication, §4.6's dimensions, slice 45j.)
///
/// ## Why this is not `Matcher.score`
///
/// ``Matcher`` compares a *mention in a document* with a *concluded person*: one side
/// is evidence, the other is a conclusion, and the two GPS weights measure how much
/// the evidence side is worth. Between two conclusions there is no evidence side.
/// Neither person is a source, so `sourceAuthorityWeight` and `informationQualityWeight`
/// have nothing to weigh — which is why ``DuplicateScore`` carries no weights rather
/// than storing a 0 or a 100 that would be a lie either way.
///
/// So the roll-up loses its source-discount stage and **nothing replaces it**: the
/// corroboration factor carries the load alone, and it bites harder here than it does
/// in the link scorer (see ``uncorroboratedFactor``). The action this feeds is a
/// destructive merge, so a bare name agreement has to sit clearly below one the two
/// records corroborate.
///
/// ## What it does reuse
///
/// The dimension scorers, unchanged — ``NameMatching``, ``DateMatching``,
/// ``PlaceMatching`` — and `MatchBreakdown` itself, whose fields are already the
/// symmetric set (`spouseName` reads partner names against partner names, `parents`
/// parent names against parent names). A second breakdown type would fork every
/// surface that draws one, to express the same five dimensions.
///
/// Pure and deterministic, like ``Matcher``: two views always produce the same
/// integers, on every platform.
public enum DuplicateMatcher {

    /// Scores two concluded persons against each other.
    ///
    /// **Argument order is meaningful for the conflict sentences only** — they say
    /// "the first"/"the second", which is readable because callers fix the order
    /// (`Archive.duplicateCandidates` uses canonical uid order). No dimension depends
    /// on it.
    ///
    /// - Parameter places: As ``Matcher/score(_:against:places:)``, and undefaulted for
    ///   the same reason. Two concluded persons both recording a bare `Rypin` are a
    ///   duplicate the archive can corroborate exactly as a mention-to-person pair is.
    public static func score(
        _ a: PersonMatchView,
        against b: PersonMatchView,
        places: PlaceVocabulary
    ) -> DuplicateScore {
        let (name, algorithm) = NameMatching.score(a.names, against: b.names)

        let birthA = a.facts.first { $0.type == .birth }
        let birthB = b.facts.first { $0.type == .birth }

        let birthYear = DateMatching.scoreBirthYear(
            recorded: DateMatching.firstYear(in: [birthA?.date]),
            concluded: DateMatching.firstYear(in: [birthB?.date]))
        let birthPlace = PlaceMatching.score(
            recorded: birthA?.place, concluded: birthB?.place, places: places)

        // The relational dimensions are a plain cross product here — no vantage-point
        // rule (45g) to apply, because that rule exists to read a *document's* roles
        // relative to its centre and neither side of this comparison is a document.
        // Two records for one woman name the same husband and the same parents.
        let spouseName = relational(a.partnerNames, against: b.partnerNames)
        let parents = relational(a.parentNames, against: b.parentNames)

        let breakdown = MatchBreakdown(
            name: name,
            nameAlgo: algorithm,
            birthYear: birthYear,
            birthPlace: birthPlace,
            spouseName: spouseName,
            parents: parents,
            conflicts: detectConflicts(
                a, b, birthYear: birthYear, birthPlace: birthPlace,
                birthA: birthA, birthB: birthB))

        return DuplicateScore(
            breakdown: breakdown,
            aggregateConfidence: aggregate(breakdown: breakdown))
    }

    /// Best agreement between two name lists, or `nil` when either side is empty.
    ///
    /// `nil` means *not assessed* here exactly as it does everywhere else: a person
    /// with no recorded partner has not failed to match one, and scoring that silence
    /// as a zero would penalize the sparser of two records for being sparse — which,
    /// for duplicate detection, is precisely backwards. A freshly-minted duplicate is
    /// *always* the sparse one.
    private static func relational(
        _ names: [PersonName], against others: [PersonName]
    ) -> MatchDimension? {
        guard !names.isEmpty, !others.isEmpty else { return nil }
        return NameMatching.score(names, against: others).dimension
    }

    // MARK: - Conflicts

    /// Disagreements that must not be averaged away — **the dimension that matters most
    /// on this surface.**
    ///
    /// Two people with the same name are the ordinary state of a family archive: a
    /// grandson carries his grandfather's name, cousins carry their shared
    /// grandmother's. What separates those from a genuine duplicate is a *dated life*,
    /// and the conflict penalty is what keeps them out of a queue whose one action is a
    /// destructive merge. An exact-name pair carrying a birth-year conflict lands at 21,
    /// far below the floor — so the grandfather/grandson case drops out on its own
    /// rather than needing a rule of its own.
    ///
    /// **Death enters here rather than as a dimension.** `MatchBreakdown` has no death
    /// field and adding one is a format change; but a death is where its evidential
    /// value lies anyway — two same-named people with two different recorded deaths are
    /// two people, and that is a conflict sentence, not a score.
    private static func detectConflicts(
        _ a: PersonMatchView,
        _ b: PersonMatchView,
        birthYear: MatchDimension?,
        birthPlace: MatchDimension?,
        birthA: PersonFact?,
        birthB: PersonFact?
    ) -> [String] {
        var conflicts: [String] = []

        let birthYearA = DateMatching.firstYear(in: [birthA?.date])
        let birthYearB = DateMatching.firstYear(in: [birthB?.date])

        // A birth-year gap the era's tolerance can't absorb.
        if let birthYear, birthYear.kind == .none, let delta = birthYear.delta,
            let first = birthYearA, let second = birthYearB
        {
            conflicts.append(
                "birthYear: the first says \(first), the second \(second) "
                    + "— \(delta) years apart, tolerance \(DateMatching.tolerance(forYear: min(first, second)))"
            )
        }

        // Birth places that share nothing, not even a country.
        if let birthPlace, birthPlace.kind == .none,
            let first = birthA?.place, let second = birthB?.place
        {
            conflicts.append(
                "birthPlace: the first says \"\(first)\", the second \"\(second)\" "
                    + "— no shared region")
        }

        // Two recorded deaths that disagree. Read through the same century-widening
        // tolerance as a birth, because a death year is arrived at the same way — from
        // a stated age, a memory, a monument — and the reasons that tolerance widens
        // with age do not care which event it is.
        let deathA = DateMatching.firstYear(in: a.facts.filter { $0.type == .death }.map(\.date))
        let deathB = DateMatching.firstYear(in: b.facts.filter { $0.type == .death }.map(\.date))
        if let first = deathA, let second = deathB {
            let delta = abs(first - second)
            let allowed = DateMatching.tolerance(forYear: min(first, second))
            if delta > allowed {
                conflicts.append(
                    "death: the first says \(first), the second \(second) "
                        + "— \(delta) years apart, tolerance \(allowed)")
            }
        }

        // One dies before the other is born. Not a weak match in either direction.
        if let death = deathA, let birth = birthYearB, death < birth {
            conflicts.append(
                "lifespan: the first's death \(death) precedes the second's birth \(birth)")
        }
        if let death = deathB, let birth = birthYearA, death < birth {
            conflicts.append(
                "lifespan: the second's death \(death) precedes the first's birth \(birth)")
        }

        return conflicts
    }

    // MARK: - Roll-up

    /// Folds the breakdown into one 0–100 sort key — ``Matcher/aggregate`` minus its
    /// second stage.
    ///
    /// Three stages, in this order:
    ///
    /// 1. **A weighted mean over the dimensions that were assessed**, absent ones
    ///    dropped and the remaining weights renormalized. Same weights as the link
    ///    scorer, because the question "how much does a birth place tell you compared
    ///    with a name" has the same answer on both sides of the seam. They are separate
    ///    constants rather than shared ones because they are separate *calibrations*:
    ///    moving one is not a reason to move the other.
    /// 2. ~~A source discount.~~ Neither side is a source. There is nothing to discount,
    ///    and inventing a stand-in would be a number with no referent.
    /// 3. **A corroboration factor**, carrying the load stage 2 shares in the link
    ///    scorer — see ``uncorroboratedFactor``.
    /// 4. **A sharp conflict penalty**, applied last so it cannot be averaged away.
    private static func aggregate(breakdown: MatchBreakdown) -> Int {
        let dimensions: [(MatchDimension?, Double)] = [
            (breakdown.name, nameWeight),
            (breakdown.birthYear, birthYearWeight),
            (breakdown.birthPlace, birthPlaceWeight),
            (scoring(breakdown.spouseName), spouseNameWeight),
            (scoring(breakdown.parents), parentsWeight),
        ]

        var total = 0.0
        var weightSum = 0.0
        for (dimension, weight) in dimensions {
            guard let dimension else { continue }
            total += Double(dimension.score) * weight
            weightSum += weight
        }
        guard weightSum > 0 else { return 0 }
        let base = total / weightSum

        // Only dimensions that actually *agreed* corroborate — the link scorer's rule
        // and its reasoning, unchanged.
        let corroborating = dimensions.dropFirst()
            .compactMap(\.0)
            .filter { $0.score >= corroborationThreshold }
            .count
        let breadth = min(Double(corroborating), fullCorroboration) / fullCorroboration
        let corroborated =
            base * (uncorroboratedFactor + (1.0 - uncorroboratedFactor) * breadth)

        let penalized =
            breakdown.conflicts.isEmpty ? corroborated : corroborated * conflictPenalty
        return Scoring.clamped(penalized)
    }

    /// Relational evidence stays **positive-only** (45g), for the same reason it is on
    /// the link side and one more: two records for one woman routinely name her husband
    /// differently — one from the marriage register, one from a death certificate — and
    /// penalizing that disagreement would suppress exactly the duplicates built from two
    /// different sources, which is how duplicates arise in the first place.
    private static func scoring(_ dimension: MatchDimension?) -> MatchDimension? {
        guard let dimension, Matcher.counts(relational: dimension) else { return nil }
        return dimension
    }

    private static let nameWeight = 0.45
    private static let birthYearWeight = 0.20
    private static let spouseNameWeight = 0.15
    private static let birthPlaceWeight = 0.10
    private static let parentsWeight = 0.10

    /// What an entirely uncorroborated pair — two matching names and nothing else —
    /// retains. **Lower than the link scorer's 0.88, deliberately.**
    ///
    /// Two things differ. The link scorer's uncorroborated case is a *suggestion* whose
    /// worst outcome is a reviewer reading a row; this one's is a merge that rewrites
    /// every link and relationship naming the absorbed person. And the link scorer has a
    /// second brake — the source discount — that this one gave up for want of a source,
    /// so the corroboration factor has to carry both jobs.
    ///
    /// The resulting bands, which are what this number is actually chosen for: an
    /// exact-name-only pair lands at **75**, the same pair with one agreeing dimension at
    /// **83**, with three at **100**; a weak-phonetic-only pair at **45**, below the
    /// floor.
    private static let uncorroboratedFactor = 0.75

    /// How many agreeing non-name dimensions count as fully corroborated (as
    /// ``Matcher``: a birth year, a birth place and a partner is everything this scorer
    /// knows how to read).
    private static let fullCorroboration = 3.0

    /// How well a dimension must score to count as corroborating rather than merely
    /// assessed.
    private static let corroborationThreshold = 60

    /// What a conflict costs. Severe, and more clearly justified here than anywhere: a
    /// conflicted pair at the top of *this* queue is an invitation to destroy a person
    /// record.
    private static let conflictPenalty = 0.4
}

// MARK: - Output

/// How alike two concluded persons are, and **why** — the person↔person counterpart of
/// ``ScoredMatch`` (slice 45j).
///
/// **No GPS weights**, which is the whole reason it is a separate type: those two
/// integers measure a *source*, and neither side of this comparison is one. Carrying
/// them would mean writing a number that means nothing into a field whose name claims
/// it means something.
///
/// Not a record, and — unlike a `ScoredMatch` — nothing turns one into a record. A
/// duplicate is acted on by merging (45f), which stores no breakdown, so this value
/// exists only long enough to be read. (A *declined* pair does get a record; that is
/// slice 45m's, and it is the reason this type is `Equatable`.)
public struct DuplicateScore: Sendable, Equatable {
    /// The decomposed breakdown — **the authoritative signal** (§4.6). Every surface
    /// that offers a merge explains it from here, never from the aggregate.
    public var breakdown: MatchBreakdown

    /// 0–100 roll-up. A convenience for ordering a queue; the breakdown is what a human
    /// reviews before destroying a record.
    public var aggregateConfidence: Int

    public init(breakdown: MatchBreakdown, aggregateConfidence: Int) {
        self.breakdown = breakdown
        self.aggregateConfidence = aggregateConfidence
    }
}

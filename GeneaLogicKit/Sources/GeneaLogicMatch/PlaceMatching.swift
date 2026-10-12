import GeneaLogicModel

/// The `birthPlace` dimension — place agreement at a **granularity** (§4.6), not as a
/// yes/no.
///
/// Places in this format are free text (`Location.asRecorded`, `PersonFact.place`,
/// `RecordedFact.place`), conventionally written most-specific-first: `"Chicago,
/// Illinois, USA"`, `"Łomża, Poland"`. So agreement is measured by how many
/// components line up, from which end.
///
/// ## The border problem, which is the whole reason this isn't string equality
///
/// This corpus is from a part of the world where the town stayed put and the country
/// changed underneath it. The same birthplace is written `"Łomża, Russia"` on one
/// record and `"Łomża, Poland"` on another, and those are the *same place* — the
/// difference is a partition, not a disagreement. So a matching most-specific
/// component is treated as strong agreement even when everything above it differs,
/// while agreement that reaches only the coarsest component ("both in Poland") is
/// treated as the weak signal it is.
///
/// Partial agreement is reported as `kind: .within` — its established meaning, *close
/// enough but not equal* — carrying a ``MatchGranularity`` that says how far down the
/// agreement reached. Before slice 45h the depth was reported as `MatchKind.county` /
/// `.country`, which named administrative tiers this code cannot actually identify: it
/// counts string components and has no gazetteer.
///
/// ## The depth an equality can't state (slice 45n)
///
/// Having no gazetteer bites once more, in the branch that looks safest. Two places
/// recorded as bare `"Poland"` are equal, and so are two recorded as bare `"Łomża"` —
/// one pair shares a country and the other shares a town, and **nothing here can tell
/// which**. Scoring both 100 resolved that ambiguity in favor of the strongest reading
/// and handed a country-level coincidence full corroborating weight; scoring both 30
/// would resolve it in favor of the weakest and demote a real town match. Neither is
/// knowledge this code has, so a single-component equality reports
/// ``MatchGranularity/unqualified`` and a score below the corroboration threshold — the
/// depth is genuinely unmeasurable, and saying so is the answer.
///
/// ### The ladder, and the rung that looks out of order
///
/// ```text
///  30  coarse       only the least specific component agreed
///  50  unqualified  the values are equal, on one component: depth unmeasurable
///  80  specific     the most specific component agreed, coarser ones differed
///               or: the values are equal on one component the archive proves is a town
/// 100  exact        equal, on more than one component
/// ```
///
/// So `Łomża`/`Łomża` (50) scores **below** `Łomża`/`Łomża, Poland` (80), and two records
/// that agree completely rank under a pair where only one of them qualifies the town.
/// That is deliberate, and it follows from what this dimension measures: **not how much
/// of each string agreed, but how far down the two places agreed.** The second pair's
/// `Poland` is evidence — it proves `Łomża` sits below the country level, so the
/// agreement is known to be specific. The first pair offers no such proof about either
/// value. Knowing less about the depth scores lower, which is the ladder working rather
/// than an inversion in it.
///
/// The `specific` rung's second entry is what closes that gap where the archive can:
/// the proof needn't come from the pair being scored, only from somewhere. Note it
/// lands on 80 and **not** on 100 — knowing `Łomża` is a town makes this agreement worth
/// what `Łomża`/`Łomża, Poland` is worth, not more. A one-component equality still says
/// less than a two-component one.
///
/// **The cost 45n accepted, and 45o's answer to it:** an archive that records towns
/// bare — `Łomża`, never `Łomża, Poland` — got no place *corroboration* at all, since 50
/// sits under the roll-up's threshold. That was the honest position for a matcher with
/// no gazetteer, and it stayed the honest position only for as long as there was no
/// other source of the missing knowledge. There usually is one: if the archive writes
/// `Łomża, Poland` **anywhere**, it has itself proved `Łomża` lies below the country
/// level, and a bare-`Łomża` agreement is town-level agreement after all. That evidence
/// arrives as a ``PlaceVocabulary`` — see its documentation for the rule and for the two
/// looser readings of it that the real corpus rules out. Absent one, nothing changes:
/// ``PlaceVocabulary/empty`` reproduces 45n exactly.
public enum PlaceMatching {

    /// Scores two place strings, or returns `nil` when either side doesn't state one
    /// (see ``DateMatching/scoreBirthYear(recorded:concluded:)`` on why absence is not
    /// a zero).
    ///
    /// - Parameter places: What the surrounding archive's other place strings prove
    ///   about depth. Defaults to ``PlaceVocabulary/empty``, which proves nothing — the
    ///   right answer for a caller scoring two strings outside any archive, and the
    ///   reason this parameter can be added without restating every existing call.
    public static func score(
        recorded: String?,
        concluded: String?,
        places: PlaceVocabulary = .empty
    ) -> MatchDimension? {
        guard let recordedComponents = components(recorded),
            let concludedComponents = components(concluded)
        else { return nil }

        if recordedComponents == concludedComponents {
            // Equal, but on a **single component** the depth of that agreement cannot be
            // measured — see `MatchGranularity.unqualified`. `Poland`/`Poland` and
            // `Łomża`/`Łomża` are indistinguishable to a matcher with no gazetteer, and
            // one is barely evidence while the other is strong. Scored below the
            // corroboration threshold on purpose (slice 45n): it still moves the weighted
            // mean, but an agreement of unknown weight must not count as *breadth* of
            // evidence. Uncertainty must never manufacture confidence.
            //
            // `kind` stays `.exact` because the normalized values genuinely are equal;
            // calling it `.within` — "close enough but not equal" — would claim a
            // difference that isn't there.
            if recordedComponents.count == 1 {
                // Unless the archive's own other place strings settle the depth this
                // pair can't (slice 45o). A value some record writes as `Rypin, Poland`
                // is known to lie below the country level, so an agreement on a bare
                // `Rypin` is town-level agreement and scores as one — the same 80 the
                // `.within` town branch gives, since it is the same claim.
                if places.contains(normalized: recordedComponents[0]) {
                    return MatchDimension(kind: .exact, score: townScore, granularity: .specific)
                }
                return MatchDimension(
                    kind: .exact, score: unqualifiedScore, granularity: .unqualified)
            }
            return MatchDimension(kind: .exact, score: 100)
        }

        // The most specific component is the town. If it agrees, the place agrees —
        // whatever the empire above it was called that decade.
        if recordedComponents[0] == concludedComponents[0] {
            return MatchDimension(kind: .within, score: townScore, granularity: .specific)
        }

        // Otherwise count agreement inward from the coarsest end.
        let shared = zip(recordedComponents.reversed(), concludedComponents.reversed())
            .prefix { $0 == $1 }
            .count
        switch shared {
        case 0:
            return MatchDimension(kind: .none, score: 0)
        case 1:
            return MatchDimension(kind: .within, score: countryScore, granularity: .coarse)
        default:
            // Two or more matching from the coarse end without the town agreeing:
            // same province, different town.
            return MatchDimension(kind: .within, score: provinceScore, granularity: .partial)
        }
    }

    /// Splits a place into normalized components, most-specific first. `nil` when the
    /// input holds nothing usable.
    static func components(_ place: String?) -> [String]? {
        guard let place else { return nil }
        let parts = place.split(separator: ",")
            .map { NameNormalization.normalize(String($0)) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }

    /// The town agrees; everything above it may not. Strong, but not exact — the
    /// components genuinely differ and a reviewer should see that.
    private static let townScore = 80
    /// Same province or state, different town.
    private static let provinceScore = 55
    /// Only the country agrees. Two people born in Poland is barely evidence.
    private static let countryScore = 30

    /// Two identical single-component places, whose agreement depth is unmeasurable.
    ///
    /// Between ``countryScore`` and ``townScore``, because it could honestly be either,
    /// and **below the roll-up's corroboration threshold of 60** — which is the number
    /// that actually matters here. A dimension of unknown evidential weight must not be
    /// what promotes a name-only match into a corroborated one.
    private static let unqualifiedScore = 50
}

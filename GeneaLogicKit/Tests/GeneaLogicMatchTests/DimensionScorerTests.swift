import GeneaLogicModel
import Testing

@testable import GeneaLogicMatch

/// The `birthYear` and `birthPlace` dimension scorers, and the two GPS weights
/// (slice 45).
@Suite struct DimensionScorerTests {

    // MARK: - Birth year

    @Test func sameYearIsExact() {
        let dimension = DateMatching.scoreBirthYear(recorded: 1892, concluded: 1892)
        #expect(dimension?.kind == .exact)
        #expect(dimension?.score == 100)
    }

    /// A silent record has not failed the dimension — `nil` means *not assessed*, and
    /// the roll-up drops it rather than averaging a zero in.
    @Test func absentYearIsNotAssessed() {
        #expect(DateMatching.scoreBirthYear(recorded: nil, concluded: 1892) == nil)
        #expect(DateMatching.scoreBirthYear(recorded: 1892, concluded: nil) == nil)
        #expect(DateMatching.scoreBirthYear(recorded: nil, concluded: nil) == nil)
    }

    /// Within tolerance the score degrades but the dimension still reads as agreement,
    /// and `delta` carries how far off for the reviewer.
    @Test func withinToleranceIsGradedAgreement() {
        let dimension = DateMatching.scoreBirthYear(recorded: 1893, concluded: 1892)
        #expect(dimension?.kind == .within)
        #expect(dimension?.delta == 1)
        #expect((dimension?.score ?? 0) > 50)
        #expect((dimension?.score ?? 0) < 100)
    }

    /// Past tolerance this is a disagreement, not a weak match.
    @Test func beyondToleranceScoresZero() {
        let dimension = DateMatching.scoreBirthYear(recorded: 1892, concluded: 1885)
        #expect(dimension?.kind == MatchKind.none)
        #expect(dimension?.score == 0)
        #expect(dimension?.delta == 7)
    }

    /// The century-widening rule: older records were less precise about ages, so a
    /// gap that is a conflict in 1920 is agreement in 1720.
    @Test func toleranceWidensWithAge() {
        #expect(DateMatching.tolerance(forYear: 1950) == 2)
        #expect(DateMatching.tolerance(forYear: 1900) == 2)
        #expect(DateMatching.tolerance(forYear: 1850) == 3)
        #expect(DateMatching.tolerance(forYear: 1750) == 4)
        // Capped — past a point a wider window stops telling people apart.
        #expect(DateMatching.tolerance(forYear: 1200) == 6)
    }

    @Test func toleranceIsAppliedFromTheEarlierYear() {
        // Three years apart in the 1840s is inside that era's tolerance…
        #expect(DateMatching.scoreBirthYear(recorded: 1843, concluded: 1840)?.kind == .within)
        // …but the same gap in the 1940s is not.
        #expect(
            DateMatching.scoreBirthYear(recorded: 1943, concluded: 1940)?.kind == MatchKind.none)
    }

    /// Dates are read through `EDTFDate` like every other consumer, so approximate and
    /// ranged values still yield a comparable year.
    @Test(
        arguments: [
            ("1892", 1892),
            ("1892~", 1892),
            ("1892?", 1892),
            ("1892-05", 1892),
            ("1892-05-14", 1892),
            ("1890/1895", 1890),
            ("../1895", 1895),
        ])
    func edtfDatesYieldAComparableYear(date: String, expected: Int) {
        #expect(DateMatching.firstYear(in: [date]) == expected)
    }

    /// Free text the EDTF subset doesn't cover is skipped rather than failing the
    /// lookup — a good date recorded beside it must still be found.
    @Test func unparseableDateIsSkippedNotFatal() {
        #expect(DateMatching.firstYear(in: ["sometime in the war", "1892"]) == 1892)
        #expect(DateMatching.firstYear(in: [nil, nil]) == nil)
        #expect(DateMatching.firstYear(in: ["circa the famine"]) == nil)
    }

    /// "About 1892" and "1892" are the same year — the qualification states the
    /// researcher's precision, not a different date.
    @Test func qualificationDoesNotChangeTheScore() {
        let plain = DateMatching.firstYear(in: ["1892"])
        let approximate = DateMatching.firstYear(in: ["1892~"])
        #expect(plain == approximate)
    }

    // MARK: - Birth place

    @Test func identicalPlaceIsExact() {
        let dimension = PlaceMatching.score(
            recorded: "Chicago, Illinois, USA", concluded: "Chicago, Illinois, USA")
        #expect(dimension?.kind == .exact)
        #expect(dimension?.score == 100)
    }

    /// Normalization applies to places too, so an accented spelling still matches.
    @Test func placeNormalizationApplies() {
        #expect(
            PlaceMatching.score(recorded: "Łomża, Poland", concluded: "Lomza, Poland")?.kind
                == .exact)
    }

    /// **The border case.** The town stayed put; the empire above it changed. This is
    /// the single most important behavior in this scorer for a Russian-partition
    /// corpus, and string equality gets it exactly wrong.
    /// The three partial-agreement scores are pinned to **exact** integers here, against
    /// this file's usual preference for asserting relationships. Slice 45h moved place
    /// granularity out of `MatchKind` and claimed to change the representation and
    /// nothing else; an exact score is what makes that claim provable rather than
    /// asserted. Retuning these deliberately should update these numbers.
    @Test func sameTownUnderADifferentCountryStillAgrees() {
        let dimension = PlaceMatching.score(recorded: "Łomża, Russia", concluded: "Łomża, Poland")
        #expect(dimension?.kind == .within)
        #expect(dimension?.granularity == .specific)
        #expect(dimension?.score == 80)
    }

    /// Agreement that reaches only the coarsest component is the weak signal it is.
    @Test func sharedCountryOnlyIsWeak() {
        let dimension = PlaceMatching.score(recorded: "Kraków, Poland", concluded: "Łomża, Poland")
        #expect(dimension?.kind == .within)
        #expect(dimension?.granularity == .coarse)
        #expect(dimension?.score == 30)
    }

    /// A place named at different depths still agrees on what both stated.
    @Test func differentDepthsMatchOnWhatIsShared() {
        let dimension = PlaceMatching.score(recorded: "Poland", concluded: "Łomża, Poland")
        #expect(dimension?.granularity == .coarse)
    }

    @Test func sharedProvinceDifferentTown() {
        let dimension = PlaceMatching.score(
            recorded: "Peoria, Illinois, USA", concluded: "Chicago, Illinois, USA")
        #expect(dimension?.kind == .within)
        #expect(dimension?.granularity == .partial)
        #expect(dimension?.score == 55)
    }

    /// A **multi-component** exact match reports no granularity: the agreement
    /// demonstrably reached the most specific component, so there is no depth to qualify.
    ///
    /// Pinned because slice 45n changed the branch beside this one and claimed to leave
    /// this case alone — an assertion is what makes that provable.
    @Test func anExactPlaceMatchHasNoGranularity() {
        let dimension = PlaceMatching.score(
            recorded: "Łomża, Poland", concluded: "Łomża, Poland")
        #expect(dimension?.kind == .exact)
        #expect(dimension?.granularity == nil)
        #expect(dimension?.score == 100)
    }

    /// **Slice 45n.** Two equal *single-component* places agree at a depth that cannot be
    /// measured: `Poland`/`Poland` share a country, `Łomża`/`Łomża` share a town, and a
    /// matcher with no gazetteer cannot tell those apart. It scored 100 — resolving the
    /// ambiguity toward the strongest reading and handing a country-level coincidence
    /// full corroborating weight.
    ///
    /// The `kind` stays `.exact` because the values *are* equal; the uncertainty is
    /// reported where it belongs, in the granularity.
    @Test(arguments: ["Poland", "Łomża", "New York"])
    func anEqualSingleComponentPlaceReportsUnmeasurableDepth(place: String) {
        let dimension = PlaceMatching.score(recorded: place, concluded: place)

        #expect(dimension?.kind == .exact)
        #expect(dimension?.granularity == .unqualified)
        #expect(dimension?.score == 50)
    }

    /// **The whole ladder, pinned as an ordering** — `coarse < unqualified < specific <
    /// exact` — because 45n's most-questioned consequence lives in it and a relationship
    /// nobody asserted is a relationship that drifts.
    ///
    /// The rung that looks out of order is `unqualified` (an equality!) sitting under
    /// `specific` (a partial agreement). It is deliberate: the dimension measures **how
    /// far down** two places agreed, not how much of each string did. `Łomża, Poland`
    /// proves `Łomża` is below the country level; two bare `Łomża`s prove nothing about
    /// either value's depth, and knowing less scores lower.
    @Test func theGranularityLadderIsOrdered() {
        let coarse = PlaceMatching.score(recorded: "Kraków, Poland", concluded: "Łomża, Poland")!
        let unqualified = PlaceMatching.score(recorded: "Poland", concluded: "Poland")!
        let specific = PlaceMatching.score(recorded: "Łomża, Russia", concluded: "Łomża, Poland")!
        let exact = PlaceMatching.score(recorded: "Łomża, Poland", concluded: "Łomża, Poland")!

        #expect(coarse.score < unqualified.score)
        #expect(unqualified.score < specific.score)
        #expect(specific.score < exact.score)
    }

    /// **The number that actually matters**: `unqualified` sits below the roll-up's
    /// corroboration threshold, so an agreement of unknown evidential weight cannot
    /// promote a name-only match into a corroborated one. Everything else about 45n is
    /// presentation; this is the behavior.
    @Test func theUnqualifiedScoreStaysBelowTheCorroborationThreshold() {
        let unqualified = PlaceMatching.score(recorded: "Poland", concluded: "Poland")

        // `Matcher.corroborationThreshold` is private — pinned by value here because this
        // score's whole purpose is to fall on the far side of it.
        #expect(unqualified!.score < 60)
    }

    /// The consequence the 45n review pressed on, asserted rather than left implicit: a
    /// bare-town archive gets **no place corroboration**, and a pair that qualifies its
    /// town outranks one that doesn't. Documented in `PlaceMatching`'s header as the price
    /// of having no gazetteer.
    @Test func aQualifiedTownOutranksTwoBareOnes() {
        let bare = PlaceMatching.score(recorded: "Łomża", concluded: "Łomża")!
        let qualified = PlaceMatching.score(recorded: "Łomża", concluded: "Łomża, Poland")!

        #expect(bare.score < qualified.score)
        #expect(bare.granularity == .unqualified)
        #expect(qualified.granularity == .specific)
    }

    // MARK: - Birth place, with the archive's own vocabulary (slice 45o)

    /// **The slice's behavior.** The same bare-town pair 45n scores at 50 lands at 80
    /// once the archive itself has shown what `Łomża` is — the depth was always there to
    /// be known, just not from these two strings.
    @Test func aProvenTownPromotesAnEqualBarePlace() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Łomża, Poland"])

        let dimension = PlaceMatching.score(
            recorded: "Łomża", concluded: "Łomża", places: vocabulary)

        #expect(dimension?.kind == .exact)
        #expect(dimension?.granularity == .specific)
        #expect(dimension?.score == 80)
    }

    /// **The band it must clear**, and the only reason any of this matters: 80 is on the
    /// far side of the roll-up's corroboration threshold, so a bare-town archive gets
    /// place corroboration where 45n could only give it 50.
    @Test func aPromotedPlaceCorroborates() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Łomża, Poland"])

        let promoted = PlaceMatching.score(
            recorded: "Łomża", concluded: "Łomża", places: vocabulary)!

        #expect(promoted.score >= 60)
    }

    /// **The value that must not move.** A country is the thing this rule is built to
    /// keep out: the vocabulary below knows about two towns and says nothing about
    /// `Poland`, so two bare `Poland`s score exactly what 45n gave them.
    @Test func anUnprovenBarePlaceIsUnchanged() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Rypin, Poland", "Sochaczew, Poland"])

        let dimension = PlaceMatching.score(
            recorded: "Poland", concluded: "Poland", places: vocabulary)

        #expect(dimension?.granularity == .unqualified)
        #expect(dimension?.score == 50)
    }

    /// A promotion is worth what `Łomża` vs `Łomża, Poland` is worth — **not more.**
    /// Knowing the depth of a one-component agreement does not make it say as much as a
    /// two-component one, so the top of the ladder stays where it was.
    @Test func aPromotedPlaceDoesNotReachAMultiComponentExactMatch() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Łomża, Poland"])

        let promoted = PlaceMatching.score(
            recorded: "Łomża", concluded: "Łomża", places: vocabulary)!
        let qualified = PlaceMatching.score(
            recorded: "Łomża", concluded: "Łomża, Poland", places: vocabulary)!
        let exact = PlaceMatching.score(
            recorded: "Łomża, Poland", concluded: "Łomża, Poland", places: vocabulary)!

        #expect(promoted.score == qualified.score)
        #expect(promoted.score < exact.score)
    }

    /// **What the promotion is worth, and the reason a *region* promoting is accepted
    /// rather than fixed.**
    ///
    /// The 45o rule proves a value is not top-level and that some record named it as its
    /// finest level — **not** that it is a town. So an archive writing `Massachusetts,
    /// USA` promotes `Massachusetts`, and two bare `Massachusetts` birth places score 80.
    /// That looks like the overclaim 45n removed until you measure the branch beside it:
    /// a bare region has scored 80 against its own qualified form since **45h**, because
    /// the leading-component branch compares strings and cannot name administrative
    /// tiers either. The promotion therefore lands the both-bare case *on the answer the
    /// scorer already gives*, which is the whole of the argument for accepting it — so it
    /// is pinned here rather than left in a doc comment.
    @Test func aPromotedValueScoresWhatThatValueAlreadyScoredQualified() {
        let vocabulary = PlaceVocabulary(placeStrings: ["Massachusetts, USA"])

        let promoted = PlaceMatching.score(
            recorded: "Massachusetts", concluded: "Massachusetts", places: vocabulary)!
        // No vocabulary: this is the pre-45o `.within` branch, unchanged since 45h.
        let againstItsQualifiedForm = PlaceMatching.score(
            recorded: "Massachusetts", concluded: "Massachusetts, USA")!

        #expect(promoted.score == againstItsQualifiedForm.score)
        #expect(promoted.granularity == againstItsQualifiedForm.granularity)
        #expect(promoted.score == 80)
    }

    /// **The tripwire, at the dimension level.** Every branch except single-component
    /// equality reads the two strings and nothing else, so a vocabulary — however rich —
    /// must not reach them. If this fails, 45o has changed a score it never intended to.
    @Test func aVocabularyDoesNotReachTheOtherBranches() {
        let vocabulary = PlaceVocabulary(placeStrings: [
            "Łomża, Poland", "Kraków, Poland", "Brooklyn, NY, USA", "Rypin, Poland",
        ])
        let pairs = [
            ("Łomża, Poland", "Łomża, Poland"),  // exact
            ("Łomża, Russia", "Łomża, Poland"),  // specific
            ("Kraków, Poland", "Łomża, Poland"),  // coarse
            ("Łomża", "Łomża, Poland"),  // town branch, one side bare
            ("Chicago, Illinois, USA", "Łomża, Poland"),  // none
            ("Poland", "Poland"),  // unqualified, unproven
        ]

        for (recorded, concluded) in pairs {
            #expect(
                PlaceMatching.score(recorded: recorded, concluded: concluded, places: vocabulary)
                    == PlaceMatching.score(recorded: recorded, concluded: concluded))
        }
    }

    @Test func unrelatedPlacesScoreNone() {
        let dimension = PlaceMatching.score(
            recorded: "Chicago, Illinois, USA", concluded: "Łomża, Poland")
        #expect(dimension?.kind == MatchKind.none)
        #expect(dimension?.score == 0)
    }

    @Test(arguments: [nil, "", "   ", ","])
    func unusablePlaceIsNotAssessed(place: String?) {
        #expect(PlaceMatching.score(recorded: place, concluded: "Łomża, Poland") == nil)
    }

    // MARK: - Source authority weight

    /// The two axes are orthogonal and both bite: a photographed register outranks a
    /// typed index of that same register.
    @Test func derivationDiscountsWithinATier() {
        let original = ConfidenceWeights.sourceAuthorityWeight(tier: .church, derivation: .original)
        let derivative = ConfidenceWeights.sourceAuthorityWeight(
            tier: .church, derivation: .derivative)
        let authored = ConfidenceWeights.sourceAuthorityWeight(tier: .church, derivation: .authored)
        #expect(original > derivative)
        #expect(derivative > authored)
    }

    @Test func tierOrdersTheGenres() {
        let vital = ConfidenceWeights.sourceAuthorityWeight(tier: .vital, derivation: .original)
        let census = ConfidenceWeights.sourceAuthorityWeight(tier: .census, derivation: .original)
        let compiled = ConfidenceWeights.sourceAuthorityWeight(
            tier: .compiled, derivation: .original)
        #expect(vital > census)
        #expect(census > compiled)
    }

    /// Slice 46's two genres, pinned by their **neighbours** rather than by their
    /// numbers: a government record registers an application rather than the event it
    /// reports, so it sits under `vital`; a stone is contemporaneous and family-erected,
    /// so it sits between `census` and `bible`. Both must clear `compiled` by a wide
    /// margin — landing there was the bug, since `compiled` asserts *somebody's
    /// conclusion, not evidence* about a document held as an original image.
    @Test func promotedGenresSitWhereTheyWereArgued() {
        func weight(_ tier: SourceAuthorityTier) -> Int {
            ConfidenceWeights.sourceAuthorityWeight(tier: tier, derivation: .original)
        }
        #expect(weight(.vital) > weight(.government))
        #expect(weight(.government) > weight(.census))
        #expect(weight(.census) > weight(.monument))
        #expect(weight(.monument) > weight(.bible))
        #expect(weight(.government) > weight(.compiled))
        #expect(weight(.monument) > weight(.compiled))
    }

    /// A promoted tier must be worth **more than saying nothing**, or the vocabulary
    /// would punish the researcher for cataloguing. This is the assertion that would
    /// have caught the gap in the first place: `compiled` fails it, which is exactly
    /// why it was the wrong place for a naturalization certificate to land.
    ///
    /// Both "said nothing" states are checked. `nil` is the API's, but **no artifact can
    /// reach it** — `Artifact.sourceAuthorityTier` is non-optional and `Archive+Matching`
    /// always supplies it — so the *reachable* one is `.unknown`, a genre this build
    /// hasn't heard of. They share an arm today; asserting only the unreachable one
    /// would leave the real case unpinned if that arm is ever split.
    @Test func promotedGenresBeatAnUnstatedTier() {
        let unstated = [
            ConfidenceWeights.sourceAuthorityWeight(tier: nil, derivation: .original),
            ConfidenceWeights.sourceAuthorityWeight(
                tier: .unknown("shipManifest"), derivation: .original),
        ]
        for tier in [SourceAuthorityTier.government, .monument] {
            let weight = ConfidenceWeights.sourceAuthorityWeight(tier: tier, derivation: .original)
            for baseline in unstated { #expect(weight > baseline) }
        }
    }

    /// **Absent means unstated, never "original".** An unstated derivation must not
    /// receive the full-authority multiplier, or a researcher who simply hasn't said
    /// would have the strongest claim asserted on their behalf.
    @Test func unstatedDerivationIsNotTreatedAsOriginal() {
        let stated = ConfidenceWeights.sourceAuthorityWeight(tier: .vital, derivation: .original)
        let unstated = ConfidenceWeights.sourceAuthorityWeight(tier: .vital, derivation: nil)
        #expect(unstated < stated)
        #expect(
            unstated
                > ConfidenceWeights.sourceAuthorityWeight(tier: .vital, derivation: .derivative))
    }

    /// An unrecognized tier is a value this build hasn't heard of, not an error — the
    /// open-vocabulary contract. It scores as unstated rather than as zero.
    @Test func unknownTierScoresAsUnstated() {
        let unknown = ConfidenceWeights.sourceAuthorityWeight(
            tier: .unknown("shipManifest"), derivation: .original)
        let untiered = ConfidenceWeights.sourceAuthorityWeight(tier: nil, derivation: .original)
        #expect(unknown == untiered)
        #expect(unknown > 0)
    }

    @Test func weightsStayInRange() {
        for tier in SourceAuthorityTier.knownCases + [.unknown("x")] {
            for derivation in SourceDerivation.knownCases + [.unknown("y")] {
                let weight = ConfidenceWeights.sourceAuthorityWeight(
                    tier: tier, derivation: derivation)
                #expect((0...100).contains(weight))
            }
        }
    }

    // MARK: - Information quality weight

    private func mention(
        quality: InformationQuality, facts: [RecordedFact] = []
    ) -> MentionMatchView {
        MentionMatchView(
            artifactID: "ART-018f3c9a-7b2e-7c41-9e3a-000000000001",
            localRef: "p1", nameAsRecorded: "Marcus Hanner", role: .subject,
            informationQuality: quality, facts: facts)
    }

    /// With no facts in play the identification rests on the name, and the mention's
    /// own quality is the honest statement of it.
    @Test func mentionQualityStandsWhenNoFactsWereUsed() {
        let primary = ConfidenceWeights.informationQualityWeight(
            factsUsed: [], within: mention(quality: .primary))
        let secondary = ConfidenceWeights.informationQualityWeight(
            factsUsed: [], within: mention(quality: .secondary))
        #expect(primary > secondary)
    }

    /// A fact's own quality overrides the mention's — the death certificate case:
    /// primary for the death, secondary for the birth it also states.
    @Test func perFactQualityOverridesTheMentionDefault() {
        let birth = RecordedFact(type: .birth, date: "1892", informationQuality: .secondary)
        let weight = ConfidenceWeights.informationQualityWeight(
            factsUsed: [birth], within: mention(quality: .primary))
        let mentionOnly = ConfidenceWeights.informationQualityWeight(
            factsUsed: [], within: mention(quality: .primary))
        #expect(weight < mentionOnly)
    }

    /// A fact that states nothing inherits the mention's quality rather than being
    /// downgraded to undetermined.
    @Test func absentFactQualityInherits() {
        let birth = RecordedFact(type: .birth, date: "1892")
        let inherited = ConfidenceWeights.informationQualityWeight(
            factsUsed: [birth], within: mention(quality: .primary))
        let stated = ConfidenceWeights.informationQualityWeight(
            factsUsed: [RecordedFact(type: .birth, date: "1892", informationQuality: .primary)],
            within: mention(quality: .primary))
        #expect(inherited == stated)
    }

    /// The worst quality among the facts used wins — averaging would let a primary
    /// fact launder a secondary one sitting beside it.
    @Test func worstQualityWinsAcrossFacts() {
        let good = RecordedFact(type: .death, date: "1955", informationQuality: .primary)
        let weak = RecordedFact(type: .birth, date: "1892", informationQuality: .secondary)
        let both = ConfidenceWeights.informationQualityWeight(
            factsUsed: [good, weak], within: mention(quality: .primary))
        let onlyWeak = ConfidenceWeights.informationQualityWeight(
            factsUsed: [weak], within: mention(quality: .primary))
        #expect(both == onlyWeak)
    }

    /// `undetermined` is weaker than `secondary`, not a middle value: not knowing how
    /// close the informant stood might be worse than knowing they were secondhand.
    @Test func undeterminedIsWeakerThanSecondary() {
        let secondary = ConfidenceWeights.informationQualityWeight(
            factsUsed: [], within: mention(quality: .secondary))
        let undetermined = ConfidenceWeights.informationQualityWeight(
            factsUsed: [], within: mention(quality: .undetermined))
        #expect(undetermined < secondary)
    }
}

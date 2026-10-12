import GeneaLogicModel
import Testing

@testable import GeneaLogicMatch

/// The no-vocabulary score, for the suites that predate slice 45o.
///
/// `Matcher.score` takes its ``PlaceVocabulary`` **undefaulted** on purpose, so that a
/// new production call site has to decide what it passes rather than inherit an empty
/// one and quietly disagree with the other entry points. Tests are the case that
/// argument was not written for: every pair below is scored outside any archive, where
/// an empty vocabulary is not a fallback but the correct answer — and stating it once
/// here keeps these assertions readable as what they are, the behavior with nothing
/// proved. Suites that exercise a vocabulary pass one explicitly.
extension Matcher {
    static func score(
        _ mention: MentionMatchView, against person: PersonMatchView
    ) -> ScoredMatch {
        score(mention, against: person, places: .empty)
    }
}

/// End-to-end scoring: the relational dimensions, conflict detection, and the roll-up
/// (slice 45).
///
/// The golden pairs are built from the names in this project's real archive, because
/// a scorer tuned against invented data is tuned against nothing. Since slice 74 the
/// names are a fictional family standing in for those real ones, each chosen to carry
/// the property of the name it replaced, so the pairs still test what they did. They assert
/// *relationships between scores* — this pair outranks that one — far more than exact
/// integers, so that tuning a weight doesn't invalidate the suite while a genuine
/// inversion still fails it.
@Suite struct MatcherTests {

    // MARK: - Fixtures

    private let artifact: ArtifactID = "ART-018f3c9a-7b2e-7c41-9e3a-000000000001"
    private let personID: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000002"

    /// `ref` is `p1` unless a case needs the scored mention to sit somewhere else in the
    /// record — which the stated-edge suites do, since an edge names both of its ends and
    /// a fixture that scores everyone as `p1` cannot tell the bride from the groom.
    private func mention(
        _ nameAsRecorded: String,
        ref: String = "p1",
        role: PersonRole = .subject,
        quality: InformationQuality = .primary,
        facts: [RecordedFact] = [],
        coMentions: [CoMention] = [],
        edges: [MentionRelationship] = [],
        tier: SourceAuthorityTier? = .vital,
        derivation: SourceDerivation? = .original,
        script: String? = nil
    ) -> MentionMatchView {
        MentionMatchView(
            artifactID: artifact, localRef: ref, nameAsRecorded: nameAsRecorded,
            nameScript: script, role: role, informationQuality: quality, facts: facts,
            coMentions: coMentions, mentionRelationships: edges, sourceTier: tier,
            sourceDerivation: derivation)
    }

    private func person(
        _ given: String?, _ surname: String?,
        facts: [PersonFact] = [],
        partners: [String] = [],
        parents: [String] = []
    ) -> PersonMatchView {
        PersonMatchView(
            personID: personID,
            names: [PersonName.deriving(type: .birth, given: given, surname: surname)],
            facts: facts,
            partnerNames: partners.map {
                PersonName.deriving(type: .birth, given: nil, surname: nil, full: $0)
            },
            parentNames: parents.map {
                PersonName.deriving(type: .birth, given: nil, surname: nil, full: $0)
            })
    }

    // MARK: - The shape of the output

    /// A perfect agreement on a primary original vital record is the ceiling.
    @Test func perfectMatchOnAStrongSourceScoresVeryHigh() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner",
                facts: [RecordedFact(type: .birth, date: "1892", place: "Łomża, Poland")]),
            against: person(
                "Marcus", "Hanner",
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")]))

        #expect(scored.breakdown.name.kind == .exact)
        #expect(scored.breakdown.birthYear?.kind == .exact)
        #expect(scored.breakdown.birthPlace?.kind == .exact)
        #expect(scored.breakdown.conflicts.isEmpty)
        #expect(scored.aggregateConfidence >= 90)
    }

    /// Two unrelated people score near the floor.
    @Test func unrelatedPeopleScoreVeryLow() {
        let scored = Matcher.score(
            mention("Esther Rudnik"), against: person("Irving", "Feldberg"))
        #expect(scored.breakdown.name.kind == MatchKind.none)
        #expect(scored.aggregateConfidence <= 10)
    }

    /// A dimension the record is silent about is **absent**, not zero — the roll-up
    /// scores what the document says rather than punishing its silences.
    @Test func silentDimensionsAreAbsentNotZero() {
        let scored = Matcher.score(mention("Marcus Hanner"), against: person("Marcus", "Hanner"))
        #expect(scored.breakdown.birthYear == nil)
        #expect(scored.breakdown.birthPlace == nil)
        #expect(scored.breakdown.spouseName == nil)
        #expect(scored.breakdown.parents == nil)
        // A name-only exact match on a strong source is still a strong suggestion.
        #expect(scored.aggregateConfidence >= 85)
    }

    /// `nameAlgo` is recorded only when a keyer actually produced the match.
    @Test func nameAlgoIsClaimedOnlyWhenAKeyerRan() {
        let exact = Matcher.score(mention("Marcus Hanner"), against: person("Marcus", "Hanner"))
        #expect(exact.breakdown.nameAlgo == nil)

        let phonetic = Matcher.score(mention("Marcus Hanaur"), against: person("Marcus", "Hanner"))
        #expect(phonetic.breakdown.nameAlgo == DaitchMokotoff.algorithmName)
    }

    // MARK: - Relational dimensions

    /// The strongest confirmation that a Marcus Hanner is *your* Marcus Hanner is the
    /// Fay beside him — read off `PersonRole` tags, which is why 44h opened that vocab.
    @Test func spouseCoMentionLiftsTheMatch() {
        let withSpouse = Matcher.score(
            mention(
                "Marcus Hanner",
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Faye Hanner", role: .spouse)
                ]),
            against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))
        let without = Matcher.score(
            mention("Marcus Hanner"), against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))

        #expect(withSpouse.breakdown.spouseName != nil)
        #expect((withSpouse.breakdown.spouseName?.score ?? 0) >= 85)
        #expect(without.breakdown.spouseName == nil)
    }

    @Test func parentCoMentionsFeedTheParentsDimension() {
        let scored = Matcher.score(
            mention(
                "Lillian Kotler",
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Nathan Kotler", role: .parent),
                    CoMention(localRef: "p3", nameAsRecorded: "Tauba Pelc", role: .parent),
                ]),
            against: person("Lillian", "Kotler", parents: ["Nathan Kotler", "Tauba Pelc"]))
        #expect(scored.breakdown.parents?.kind == .exact)
    }

    /// A record that names no spouse, or a person with no known partner, has **not**
    /// failed the dimension — both sides must have something to compare.
    @Test func relationalDimensionsNeedBothSides() {
        let noPartnerKnown = Matcher.score(
            mention(
                "Marcus Hanner",
                coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .spouse)]
            ),
            against: person("Marcus", "Hanner"))
        #expect(noPartnerKnown.breakdown.spouseName == nil)

        let noSpouseNamed = Matcher.score(
            mention("Marcus Hanner"), against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))
        #expect(noSpouseNamed.breakdown.spouseName == nil)
    }

    /// A co-mention in the wrong role doesn't feed the dimension: a witness named
    /// Fay is not a spouse named Fay.
    @Test func coMentionRoleIsRespected() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner",
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .witness)
                ]),
            against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))
        #expect(scored.breakdown.spouseName == nil)
    }

    // MARK: - Vantage point (slice 45g)

    /// The death certificate that surfaced all of this: the deceased is the subject,
    /// his widow is `spouse`, his parents are `parent`. Every role on it is stated
    /// relative to **him**, not to whichever mention is being scored.
    private enum DeathCertificate {
        static let deceased = "Marcus Hanner"
        static let widow = "Gussie Feldberg"  // recorded under her married name
        static let father = "David Hanner"
        static let mother = "Tauba Hanner"

        /// The co-mentions beside whichever mention is being scored.
        static func besides(_ name: String) -> [CoMention] {
            [
                CoMention(localRef: "p2", nameAsRecorded: deceased, role: .subject),
                CoMention(localRef: "p3", nameAsRecorded: widow, role: .spouse),
                CoMention(localRef: "p4", nameAsRecorded: father, role: .parent),
                CoMention(localRef: "p5", nameAsRecorded: mother, role: .parent),
            ].filter { $0.nameAsRecorded != name }
        }
    }

    /// **Failure (1): a missing dimension.** Scoring the widow's own mention found no
    /// co-mention tagged `spouse` — her husband is the `subject` — so `spouseName` went
    /// unassessed even with the marriage recorded. Her role *is* the relation: read
    /// from her end, the subject is her spouse.
    @Test func aSpouseMentionDrawsTheSubjectAsTheirSpouse() {
        let scored = Matcher.score(
            mention(
                DeathCertificate.widow, role: .spouse,
                coMentions: DeathCertificate.besides(DeathCertificate.widow)),
            against: person("Gussie", "Feldberg", partners: [DeathCertificate.deceased]))

        #expect(scored.breakdown.spouseName?.kind == .exact)
        // Her husband's parents stand in no stated relation to her.
        #expect(scored.breakdown.parents == nil)
    }

    /// **Failure (2): a spurious *failing* dimension.** Scoring the deceased's father
    /// compared the *deceased's* widow against the father's own wife and recorded
    /// `spouseName: none 0` — a dimension that should never have existed, and one that
    /// cost him 18 points on a better name match than the deceased's.
    @Test func aParentIsNotComparedAgainstTheSubjectsSpouse() {
        let father = person("David", "Hanner", partners: [DeathCertificate.mother])
        let scored = Matcher.score(
            mention(
                DeathCertificate.father, role: .parent,
                coMentions: DeathCertificate.besides(DeathCertificate.father)),
            against: father)

        // Unstated, so unassessed — not zero. The record says he is the subject's
        // father and nothing whatever about who he was married to.
        #expect(scored.breakdown.spouseName == nil)
        #expect(scored.breakdown.parents == nil)

        // And the widow beside him now costs him exactly nothing.
        let alone = Matcher.score(
            mention(DeathCertificate.father, role: .parent), against: father)
        #expect(scored.aggregateConfidence == alone.aggregateConfidence)
    }

    /// **Failure (3): a regression under correct data.** Recording the true marriage
    /// dropped the deceased 73 → 55, because `spouseName` then compared the recorded
    /// married name against the stored maiden name. A conclusion the researcher got
    /// *right* made the matcher less confident about a *correct* pair.
    ///
    /// Relational evidence is positive-only, so the dimension is reported and not
    /// scored: `Feldberg`/`Haskel` is what a married surname looks like, not what a
    /// wrong match looks like.
    @Test func recordingATrueMarriageNeverLowersACorrectPair() {
        let deceased = mention(
            DeathCertificate.deceased,
            coMentions: DeathCertificate.besides(DeathCertificate.deceased))

        let beforeTheMarriage = Matcher.score(
            deceased, against: person("Marcus", "Hanner"))
        let afterTheMarriage = Matcher.score(
            deceased, against: person("Marcus", "Hanner", partners: ["Gussie Haskel"]))

        #expect(beforeTheMarriage.breakdown.spouseName == nil)
        #expect(afterTheMarriage.breakdown.spouseName?.kind == MatchKind.none)
        #expect(
            afterTheMarriage.aggregateConfidence == beforeTheMarriage.aggregateConfidence,
            "a relational miss is reported, never scored")
    }

    /// The same rule from the other side: a relational dimension that *agrees* still
    /// lifts the match. Positive-only means never penalizing, not never counting.
    @Test func anAgreeingRelationalDimensionStillLifts() {
        let recorded = mention(
            "Marcus Hanner",
            coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .spouse)])
        let agreeing = Matcher.score(
            recorded, against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))
        let missing = Matcher.score(
            recorded, against: person("Marcus", "Hanner", partners: ["Gussie Haskel"]))

        #expect(agreeing.aggregateConfidence > missing.aggregateConfidence)
    }

    /// A record with **no centre at all** — a deed naming two witnesses and a
    /// registrar — relates them to nobody, so there is no vantage point to read any
    /// role from. `subject` is a default, not a guarantee, and neither is a couple.
    @Test func aRecordWithNoCentreStatesNoRelation() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner", role: .witness,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .witness),
                    CoMention(localRef: "p3", nameAsRecorded: "Nathan Kotler", role: .registrar),
                ]),
            against: person(
                "Marcus", "Hanner", partners: ["Fay Hanner"], parents: ["Nathan Kotler"]))

        #expect(scored.breakdown.spouseName == nil)
        #expect(scored.breakdown.parents == nil)
    }

    /// The positive-only rule, pinned where it lives — the CLI's `(not scored)` label
    /// and 45e's inbox both answer to this, and it is the reason a stated-but-
    /// disagreeing relation is safe to read generously above.
    @Test func onlyAnAgreeingRelationalDimensionCounts() {
        #expect(!Matcher.counts(relational: MatchDimension(kind: .none, score: 0)))
        #expect(Matcher.counts(relational: MatchDimension(kind: .exact, score: 100)))
        #expect(Matcher.counts(relational: MatchDimension(kind: .within, score: 90, delta: 10)))
    }

    /// **A marriage register names no subject at all** — it names a couple, both
    /// tagged `spouse`, and it is the strongest relational document in the corpus.
    /// Both marriage records in the real archive are exactly this shape
    /// (`{spouse: 2, parent: 4}` and `{spouse: 2}`), so a rule that insisted on a
    /// `subject` threw away the couple edge on four confirmed-correct links.
    @Test func aCoupleWithNoSubjectIsStillACouple() {
        let scored = Matcher.score(
            mention(
                "Faye Hanner", role: .spouse,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse)
                ]),
            against: person("Fay", "Hanner", partners: ["Irving Feldberg"]))

        #expect(scored.breakdown.spouseName?.kind == .exact)
    }

    /// On that same register the four `parent` mentions are the parents **of the
    /// couple**, and which two belong to which spouse is not stated. Read generously —
    /// best of the four — because since relational evidence is positive-only a wrong
    /// guess costs nothing, while the right one is the record's whole point. The
    /// spurious-hit case is the couple being siblings.
    @Test func theParentsOfACoupleAreReadForEitherSpouse() {
        let scored = Matcher.score(
            mention(
                "Faye Hanner", role: .spouse,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse),
                    CoMention(localRef: "p3", nameAsRecorded: "Sidney Feldberg", role: .parent),
                    CoMention(localRef: "p4", nameAsRecorded: "Gussie Haskel", role: .parent),
                    CoMention(localRef: "p5", nameAsRecorded: "Marcus Hanner", role: .parent),
                    CoMention(localRef: "p6", nameAsRecorded: "Esther Rudnik", role: .parent),
                ]),
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Marcus Hanner", "Esther Rudnik"]))

        #expect(scored.breakdown.parents?.kind == .exact)
        #expect(scored.breakdown.spouseName?.kind == .exact)
    }

    /// A parent on that register is a satellite: their tie is to the couple, as a
    /// *parent of* one of them. Nothing states who they were married to, so the other
    /// spouse on the record must not be read as theirs.
    @Test func aParentOnACoupleRecordDrawsNoSpouse() {
        let scored = Matcher.score(
            mention(
                "Sidney Feldberg", role: .parent,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Faye Hanner", role: .spouse),
                    CoMention(localRef: "p3", nameAsRecorded: "Irving Feldberg", role: .spouse),
                    CoMention(localRef: "p4", nameAsRecorded: "Gussie Haskel", role: .parent),
                ]),
            against: person("Sidney", "Feldberg", partners: ["Gussie Haskel"]))

        #expect(scored.breakdown.spouseName == nil)
        #expect(scored.breakdown.parents == nil)
    }

    /// Several subjects: the satellites are ambiguous between them rather than void.
    /// The corpus's 1950 census carries two, and the same positive-only reasoning
    /// applies — an ambiguous relational read that misses now costs nothing, so
    /// discarding it buys no safety and loses real evidence.
    @Test func severalSubjectsShareTheirSatellites() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner", role: .subject,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Irving Hanner", role: .subject),
                    CoMention(localRef: "p3", nameAsRecorded: "Fay Hanner", role: .spouse),
                ]),
            against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))

        #expect(scored.breakdown.spouseName?.kind == .exact)
        // The co-subject itself states no relation — two people a census lists are
        // not thereby married, siblings, or anything else.
        let coSubjectOnly = Matcher.score(
            mention(
                "Marcus Hanner", role: .subject,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .subject)
                ]),
            against: person("Marcus", "Hanner", partners: ["Fay Hanner"]))
        #expect(coSubjectOnly.breakdown.spouseName == nil)
    }

    /// The corpus's marriage register tags the groom `subject` and the bride `spouse`,
    /// and the couple edge reads correctly from **both** ends.
    @Test func aCoupleEdgeReadsFromEitherEnd() {
        let groom = Matcher.score(
            mention(
                "Marcus Hanner", role: .subject,
                coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Fay Rudnik", role: .spouse)]
            ),
            against: person("Marcus", "Hanner", partners: ["Fay Rudnik"]))
        let bride = Matcher.score(
            mention(
                "Fay Rudnik", role: .spouse,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Marcus Hanner", role: .subject)
                ]),
            against: person("Fay", "Rudnik", partners: ["Marcus Hanner"]))

        #expect(groom.breakdown.spouseName?.kind == .exact)
        #expect(bride.breakdown.spouseName?.kind == .exact)
    }

    // MARK: - Conflicts

    /// §4.6's headline case: the same name and a birth year off by ten is *more*
    /// suspicious than a bare name match, and must not be averaged away.
    @Test func birthYearConflictIsRecordedAndPenalized() {
        let conflicted = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .birth, date: "1892")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1882")]))
        let nameOnly = Matcher.score(
            mention("Marcus Hanner"), against: person("Marcus", "Hanner"))

        #expect(conflicted.breakdown.conflicts.count == 1)
        #expect(conflicted.breakdown.conflicts[0].contains("birthYear"))
        // The conflicted pair scores *below* the pair that says nothing at all.
        #expect(conflicted.aggregateConfidence < nameOnly.aggregateConfidence)
    }

    @Test func birthPlaceConflictIsRecorded() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner",
                facts: [RecordedFact(type: .birth, place: "Chicago, Illinois, USA")]),
            against: person(
                "Marcus", "Hanner", facts: [PersonFact(type: .birth, place: "Łomża, Poland")]))
        #expect(scored.breakdown.conflicts.contains { $0.contains("birthPlace") })
    }

    /// A death before the concluded birth is not a weak match, it is a different
    /// person.
    @Test func impossibleLifespanIsAConflict() {
        let scored = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .death, date: "1880")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1892")]))
        #expect(scored.breakdown.conflicts.contains { $0.contains("lifespan") })
    }

    /// Conflicts are written as sentences a reviewer can act on, carrying both values
    /// and the tolerance that was applied — they are rendered in the review UI.
    @Test func conflictTextNamesBothValues() {
        let scored = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .birth, date: "1892")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1882")]))
        let text = scored.breakdown.conflicts[0]
        #expect(text.contains("1892"))
        #expect(text.contains("1882"))
        #expect(text.contains("10"))
    }

    /// A gap inside the era's tolerance is agreement, not a conflict.
    @Test func withinToleranceIsNotAConflict() {
        let scored = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .birth, date: "1893")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1892")]))
        #expect(scored.breakdown.conflicts.isEmpty)
        #expect(scored.breakdown.birthYear?.kind == .within)
    }

    // MARK: - The GPS discount

    /// The same agreement is worth less from a compiled tree than from a register —
    /// 15 of the 20 artifacts in the real archive are `compiled`, so this is the
    /// common case, not an exotic one.
    @Test func sourceAuthorityDiscountsAnIdenticalMatch() {
        let register = Matcher.score(
            mention("Marcus Hanner", tier: .vital, derivation: .original),
            against: person("Marcus", "Hanner"))
        let compiledTree = Matcher.score(
            mention("Marcus Hanner", tier: .compiled, derivation: .authored),
            against: person("Marcus", "Hanner"))

        #expect(compiledTree.aggregateConfidence < register.aggregateConfidence)
        #expect(compiledTree.sourceAuthorityWeight < register.sourceAuthorityWeight)
        // The breakdown itself is untouched — the source discounts the roll-up, it
        // does not rewrite what the names actually did.
        #expect(compiledTree.breakdown.name == register.breakdown.name)
    }

    /// **A weak source discounts; it never erases.** A perfect four-dimension match on
    /// a compiled tree is still a strong suggestion, because deciding otherwise is a
    /// research judgment the matcher has no business making for the researcher.
    @Test func aWeakSourceCannotZeroAStrongMatch() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner",
                quality: .undetermined,
                facts: [RecordedFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .spouse)
                ],
                tier: .compiled, derivation: .authored),
            against: person(
                "Marcus", "Hanner",
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                partners: ["Fay Hanner"]))
        #expect(scored.aggregateConfidence >= 55)
    }

    /// Information quality moves the roll-up independently of the source tier.
    @Test func informationQualityMovesTheRollUp() {
        let primary = Matcher.score(
            mention("Marcus Hanner", quality: .primary), against: person("Marcus", "Hanner"))
        let secondary = Matcher.score(
            mention("Marcus Hanner", quality: .secondary), against: person("Marcus", "Hanner"))
        #expect(secondary.aggregateConfidence < primary.aggregateConfidence)
    }

    // MARK: - Corroboration

    /// **The reason the roll-up isn't just a weighted mean.** A mean over one perfect
    /// dimension and a mean over four perfect dimensions are both 100, so a bare name
    /// match would tie with one the record confirms three ways over — and the top of a
    /// review queue would stop meaning anything. Independent agreement is what turns a
    /// hypothesis into a conclusion, and the score has to say so.
    @Test func corroborationOutranksABareNameMatch() {
        let corroborated = Matcher.score(
            mention(
                "Marcus Hanner",
                facts: [RecordedFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .spouse)]
            ),
            against: person(
                "Marcus", "Hanner",
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                partners: ["Fay Hanner"]))
        let bare = Matcher.score(mention("Marcus Hanner"), against: person("Marcus", "Hanner"))

        // Both agree perfectly on every dimension they assessed…
        #expect(corroborated.breakdown.name.kind == .exact)
        #expect(bare.breakdown.name.kind == .exact)
        // …and the corroborated one still ranks clearly higher.
        #expect(corroborated.aggregateConfidence > bare.aggregateConfidence + 5)
    }

    /// Only dimensions that **agreed** corroborate. A birth year that was assessed and
    /// disagreed is not breadth of evidence — it is the opposite, and it is already
    /// being counted as a conflict.
    @Test func aDisagreeingDimensionDoesNotCorroborate() {
        let disagreeing = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .birth, date: "1860")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1892")]))
        let silent = Matcher.score(mention("Marcus Hanner"), against: person("Marcus", "Hanner"))
        #expect(disagreeing.aggregateConfidence < silent.aggregateConfidence)
    }

    // MARK: - Golden ordering

    /// The ordering a review queue depends on: better evidence ranks higher. Asserted
    /// as an ordering rather than as five magic numbers, so weight tuning doesn't
    /// churn the suite but an inversion still fails it.
    @Test func strongerEvidenceOutranksWeaker() {
        let exactWithSpouseAndBirth = Matcher.score(
            mention(
                "Marcus Hanner",
                facts: [RecordedFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Fay Hanner", role: .spouse)]
            ),
            against: person(
                "Marcus", "Hanner",
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")],
                partners: ["Fay Hanner"]))
        let exactNameOnly = Matcher.score(
            mention("Marcus Hanner"), against: person("Marcus", "Hanner"))
        let phoneticNameOnly = Matcher.score(
            mention("Marcus Hanaur"), against: person("Marcus", "Hanner"))
        let conflicted = Matcher.score(
            mention("Marcus Hanner", facts: [RecordedFact(type: .birth, date: "1860")]),
            against: person("Marcus", "Hanner", facts: [PersonFact(type: .birth, date: "1892")]))
        let unrelated = Matcher.score(
            mention("Esther Rudnik"), against: person("Irving", "Feldberg"))

        let ranked = [
            exactWithSpouseAndBirth.aggregateConfidence,
            exactNameOnly.aggregateConfidence,
            phoneticNameOnly.aggregateConfidence,
            conflicted.aggregateConfidence,
            unrelated.aggregateConfidence,
        ]
        #expect(ranked == ranked.sorted(by: >))
        #expect(Set(ranked).count == ranked.count, "each rung should be distinguishable")
    }

    // MARK: - Invariants

    /// Every score and weight the matcher emits is a stored `EvidenceLink` field, and
    /// the format says 0–100.
    @Test func everyEmittedValueStaysInRange() {
        let cases = [
            Matcher.score(mention("Marcus Hanner"), against: person("Marcus", "Hanner")),
            Matcher.score(mention("Esther Rudnik"), against: person("Irving", "Feldberg")),
            Matcher.score(mention(""), against: person(nil, nil)),
            Matcher.score(
                mention("Marcus Hanner", tier: .unknown("shipManifest"), derivation: nil),
                against: person("Marcus", "Hanner")),
        ]
        for scored in cases {
            #expect((0...100).contains(scored.aggregateConfidence))
            #expect((0...100).contains(scored.sourceAuthorityWeight))
            #expect((0...100).contains(scored.informationQualityWeight))
            #expect((0...100).contains(scored.breakdown.name.score))
        }
    }

    /// A nameless person and an empty mention must score, not crash.
    @Test func degenerateInputIsSafe() {
        let scored = Matcher.score(mention(""), against: person(nil, nil))
        #expect(scored.aggregateConfidence == 0)
        #expect(scored.breakdown.name.kind == MatchKind.none)
    }

    // MARK: - Stated relationships (slice 45k)

    /// **What the slice is for.** On the marriage register the four parents are read
    /// best-of-four when nothing says whose they are (see
    /// `theParentsOfACoupleAreReadForEitherSpouse`). Once the record *states* the edges,
    /// the bride scores against **her** parents only — and a person whose parents are
    /// the groom's no longer draws a spurious `exact`.
    @Test func statedParentEdgesBeatTheBestOfFourInference() {
        let coMentions = [
            CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse),
            CoMention(localRef: "p3", nameAsRecorded: "Sidney Feldberg", role: .parent),
            CoMention(localRef: "p4", nameAsRecorded: "Gussie Haskel", role: .parent),
            CoMention(localRef: "p5", nameAsRecorded: "Marcus Hanner", role: .parent),
            CoMention(localRef: "p6", nameAsRecorded: "Esther Rudnik", role: .parent),
        ]
        // p1 is the bride; p5/p6 are hers, p3/p4 are the groom's.
        let edges = [
            MentionRelationship(type: .parentChild, person1Ref: "p5", person2Ref: "p1"),
            MentionRelationship(type: .parentChild, person1Ref: "p6", person2Ref: "p1"),
            MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p2"),
            MentionRelationship(type: .parentChild, person1Ref: "p4", person2Ref: "p2"),
        ]
        let bride = mention("Faye Hanner", role: .spouse, coMentions: coMentions, edges: edges)

        // Her own parents still corroborate.
        let hers = Matcher.score(
            bride,
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Marcus Hanner", "Esther Rudnik"]))
        #expect(hers.breakdown.parents?.kind == .exact)

        // A candidate carrying the *groom's* parents is no longer corroborated by them —
        // the record now says those two are not hers. Without the edges this scored
        // `exact` off the same page.
        let confusable = Matcher.score(
            bride,
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Sidney Feldberg", "Gussie Haskel"]))
        #expect(confusable.breakdown.parents?.kind == MatchKind.none)

        let inferred = Matcher.score(
            mention("Faye Hanner", role: .spouse, coMentions: coMentions),
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Sidney Feldberg", "Gussie Haskel"]))
        #expect(
            inferred.breakdown.parents?.kind == .exact,
            "the inference this slice replaces did read the groom's parents as hers")
        #expect(confusable.aggregateConfidence < inferred.aggregateConfidence)
    }

    /// **The invariant the slice must not break.** A record that states no edges scores
    /// *exactly* as it did before — every existing archive is one of those, and a slice
    /// that quietly re-scored the whole corpus while claiming to be additive would be
    /// impossible to tell from a regression.
    @Test func anEdgelessRecordScoresUnchanged() {
        let coMentions = [
            CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse),
            CoMention(localRef: "p3", nameAsRecorded: "Sidney Feldberg", role: .parent),
            CoMention(localRef: "p4", nameAsRecorded: "Gussie Haskel", role: .parent),
        ]
        let candidate = person(
            "Fay", "Hanner", partners: ["Irving Feldberg"],
            parents: ["Sidney Feldberg", "Gussie Haskel"])

        let scored = Matcher.score(
            mention("Faye Hanner", role: .spouse, coMentions: coMentions, edges: []),
            against: candidate)

        #expect(scored.breakdown.parents?.kind == .exact)
        #expect(scored.breakdown.spouseName?.kind == .exact)
        #expect(scored.aggregateConfidence > 0)
    }

    /// The preference is **per relation type**. This record states its parent edges and
    /// says nothing about couples; the spouse dimension must still read off the roles,
    /// or adding information to a record would cost the user a dimension they had.
    @Test func silenceAboutOneRelationDoesNotDenyIt() {
        let scored = Matcher.score(
            mention(
                "Faye Hanner", role: .spouse,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse),
                    CoMention(localRef: "p3", nameAsRecorded: "Marcus Hanner", role: .parent),
                ],
                edges: [
                    MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1")
                ]),
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"], parents: ["Marcus Hanner"]))

        #expect(scored.breakdown.parents?.kind == .exact)
        #expect(scored.breakdown.spouseName?.kind == .exact, "the couple was never denied")
    }

    /// **The half-catalogued record**, and the sharpest case for scoping the preference
    /// to the *mention* rather than the record. The register states the bride's two
    /// parent edges and hasn't reached the groom's yet. A record-scoped rule reads that
    /// as "parenthood is stated here, and the groom is nobody's child" and drops a
    /// dimension he scored a moment earlier — 45k's own review caught this at
    /// `parents .exact → nil`, aggregate 89 → 85.
    ///
    /// Both halves are asserted together, because the rule is only right if it does both
    /// at once: the bride gets the precision the edges bought, the groom keeps the
    /// inference he always had.
    @Test func statingOneSpousesParentsLeavesTheOthersInferenceIntact() {
        // The register: p1 bride, p2 groom, p3/p4 her parents, p5/p6 his.
        let besideTheGroom = [
            CoMention(localRef: "p1", nameAsRecorded: "Faye Hanner", role: .spouse),
            CoMention(localRef: "p3", nameAsRecorded: "Marcus Hanner", role: .parent),
            CoMention(localRef: "p4", nameAsRecorded: "Esther Rudnik", role: .parent),
            CoMention(localRef: "p5", nameAsRecorded: "Sidney Feldberg", role: .parent),
            CoMention(localRef: "p6", nameAsRecorded: "Gussie Haskel", role: .parent),
        ]
        let besideTheBride = [
            CoMention(localRef: "p2", nameAsRecorded: "Irving Feldberg", role: .spouse),
            CoMention(localRef: "p3", nameAsRecorded: "Marcus Hanner", role: .parent),
            CoMention(localRef: "p4", nameAsRecorded: "Esther Rudnik", role: .parent),
            CoMention(localRef: "p5", nameAsRecorded: "Sidney Feldberg", role: .parent),
            CoMention(localRef: "p6", nameAsRecorded: "Gussie Haskel", role: .parent),
        ]
        // Only the bride's parents are stated; the groom's p5/p6 are not — the record
        // half-catalogued.
        let halfStated = [
            MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
            MentionRelationship(type: .parentChild, person1Ref: "p4", person2Ref: "p1"),
        ]
        let theGroomHimself = person(
            "Irving", "Feldberg", partners: ["Faye Hanner"],
            parents: ["Sidney Feldberg", "Gussie Haskel"])

        // The groom has no stated parents, so he still reads the page's four best-of.
        let groom = Matcher.score(
            mention(
                "Irving Feldberg", ref: "p2", role: .spouse, coMentions: besideTheGroom,
                edges: halfStated),
            against: theGroomHimself)
        #expect(groom.breakdown.parents?.kind == .exact)

        let noEdgesAtAll = Matcher.score(
            mention("Irving Feldberg", ref: "p2", role: .spouse, coMentions: besideTheGroom),
            against: theGroomHimself)
        #expect(
            groom.aggregateConfidence == noEdgesAtAll.aggregateConfidence,
            "someone else's stated edges must not move this mention's score at all")

        // The bride, on the same record, does get the precision: a candidate carrying the
        // *groom's* parents no longer corroborates her.
        let brideConfused = Matcher.score(
            mention(
                "Faye Hanner", ref: "p1", role: .spouse, coMentions: besideTheBride,
                edges: halfStated),
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Sidney Feldberg", "Gussie Haskel"]))
        #expect(brideConfused.breakdown.parents?.kind == MatchKind.none)

        // …and her own parents still do.
        let brideCorrect = Matcher.score(
            mention(
                "Faye Hanner", ref: "p1", role: .spouse, coMentions: besideTheBride,
                edges: halfStated),
            against: person(
                "Fay", "Hanner", partners: ["Irving Feldberg"],
                parents: ["Marcus Hanner", "Esther Rudnik"]))
        #expect(brideCorrect.breakdown.parents?.kind == .exact)
    }

    /// The same shape on the spouse axis: a death certificate stating that its two
    /// `parent` mentions are a couple says nothing about the **subject's** marriage, so
    /// his `spouseName` must still be read from the widow beside him.
    @Test func aCoupleEdgeBetweenOthersLeavesThisMentionsSpouseInferred() {
        let coMentions = [
            CoMention(localRef: "p2", nameAsRecorded: "Gussie Feldberg", role: .spouse),
            CoMention(localRef: "p3", nameAsRecorded: "Sidney Feldberg", role: .parent),
            CoMention(localRef: "p4", nameAsRecorded: "Gussie Haskel", role: .parent),
        ]
        let scored = Matcher.score(
            mention(
                "Marcus Hanner", role: .subject, coMentions: coMentions,
                edges: [
                    MentionRelationship(type: .couple, person1Ref: "p3", person2Ref: "p4")
                ]),
            against: person("Marcus", "Hanner", partners: ["Gussie Feldberg"]))

        #expect(scored.breakdown.spouseName?.kind == .exact)
    }

    /// A stated `couple` is symmetric and reads from either end, and it reaches where
    /// the star inference could not: two `parent` mentions married to each other, which
    /// no arrangement of role tags can express.
    @Test func aStatedCoupleReadsFromEitherEndAndBetweenSatellites() {
        let coMentions = [
            CoMention(localRef: "p2", nameAsRecorded: "Gussie Haskel", role: .parent),
            CoMention(localRef: "p3", nameAsRecorded: "Marcus Hanner", role: .subject),
        ]
        let edges = [MentionRelationship(type: .couple, person1Ref: "p2", person2Ref: "p1")]

        let scored = Matcher.score(
            mention("Sidney Feldberg", role: .parent, coMentions: coMentions, edges: edges),
            against: person("Sidney", "Feldberg", partners: ["Gussie Haskel"]))
        #expect(scored.breakdown.spouseName?.kind == .exact)

        // The record's subject is not thereby anyone's spouse.
        let subjectRead = Matcher.score(
            mention("Sidney Feldberg", role: .parent, coMentions: coMentions, edges: edges),
            against: person("Sidney", "Feldberg", partners: ["Marcus Hanner"]))
        #expect(subjectRead.breakdown.spouseName?.kind == MatchKind.none)
    }

    /// The direction is §4.5's, and getting it backwards is a silent wrong answer rather
    /// than an error: an edge in which this mention is the **parent** says something the
    /// scorer has no candidate list to compare against, so it must go unassessed — never
    /// be read as though the child were a parent.
    @Test func anEdgeWhereThisMentionIsTheParentIsUnassessed() {
        let scored = Matcher.score(
            mention(
                "Marcus Hanner", role: .subject,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Sidney Hanner", role: .subject)
                ],
                edges: [
                    MentionRelationship(type: .parentChild, person1Ref: "p1", person2Ref: "p2")
                ]),
            against: person("Marcus", "Hanner", parents: ["Sidney Hanner"]))

        #expect(scored.breakdown.parents == nil, "p1 is the parent on that edge, not the child")
    }

    /// An edge naming a mention that isn't on the record (the §2.3 dangle, which
    /// `findDanglingReferences` reports) must not crash or invent a comparison — it
    /// simply reaches nobody. An unknown relation type is likewise inert to scoring
    /// while still round-tripping on disk.
    @Test func aDanglingOrUnknownEdgeScoresNothing() {
        let scored = Matcher.score(
            mention(
                "Faye Hanner", role: .spouse,
                coMentions: [
                    CoMention(localRef: "p2", nameAsRecorded: "Marcus Hanner", role: .parent)
                ],
                edges: [
                    MentionRelationship(type: .parentChild, person1Ref: "p9", person2Ref: "p1"),
                    MentionRelationship(
                        type: .unknown("employer"), person1Ref: "p2", person2Ref: "p1"),
                ]),
            against: person("Fay", "Hanner", parents: ["Marcus Hanner"]))

        // This mention *does* have a stated parent edge, so the inference is off for it —
        // and the parent that edge names is gone, so nothing corroborates.
        #expect(scored.breakdown.parents == nil)
    }

    /// The whole point of storing a decomposed breakdown is that it still means the
    /// same thing when it is read back.
    @Test func scoringIsDeterministic() {
        let m = mention(
            "Marcus Hanaur",
            facts: [RecordedFact(type: .birth, date: "1892~", place: "Łomża, Russia")],
            coMentions: [CoMention(localRef: "p2", nameAsRecorded: "Faye Hanner", role: .spouse)])
        let p = person(
            "Marcus", "Hanner",
            facts: [PersonFact(type: .birth, date: "1893", place: "Łomża, Poland")],
            partners: ["Fay Hanner"])

        let first = Matcher.score(m, against: p)
        for _ in 0..<25 {
            #expect(Matcher.score(m, against: p) == first)
        }
    }
}

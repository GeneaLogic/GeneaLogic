import GeneaLogicModel
import Testing

@testable import GeneaLogicMatch

/// The person↔person scorer: the symmetric dimensions, conflict detection, and the
/// roll-up that lost its source discount (slice 45j).
///
/// Golden pairs are built from the fictional family that stands in for this project's real archive,
/// for the reason `MatcherTests` gives. Where an exact integer *is* asserted it is one the design
/// argues for by name — the calibration anchors in `Archive.defaultMinimumDuplicateConfidence` and
/// `DuplicateMatcher.uncorroboratedFactor` — because a doc comment that quotes a band the code
/// doesn't produce is worse than no doc comment.
@Suite struct DuplicateMatcherTests {

    // MARK: - Fixtures

    private let first: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000001"
    private let second: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000002"

    private func person(
        _ id: PersonID,
        names: [String],
        facts: [PersonFact] = [],
        partners: [String] = [],
        parents: [String] = []
    ) -> PersonMatchView {
        PersonMatchView(
            personID: id,
            names: names.map {
                PersonName.deriving(type: .birth, given: nil, surname: nil, full: $0)
            },
            facts: facts,
            partnerNames: partners.map {
                PersonName.deriving(type: .birth, given: nil, surname: nil, full: $0)
            },
            parentNames: parents.map {
                PersonName.deriving(type: .birth, given: nil, surname: nil, full: $0)
            })
    }

    /// Scored outside any archive, so nothing is proved about place depth — see the
    /// note on `Matcher.score`'s test shim in `MatcherTests`. The pinned bands below
    /// are the no-vocabulary ones.
    private func score(
        _ a: PersonMatchView, _ b: PersonMatchView, places: PlaceVocabulary = .empty
    ) -> DuplicateScore {
        DuplicateMatcher.score(a, against: b, places: places)
    }

    // MARK: - Dimensions

    /// The name dimension is the **cross product** of both lists, not first against
    /// first: a duplicate is routinely found through a married name on one record and a
    /// birth name on the other.
    @Test func nameMatchesAcrossBothNameLists() {
        let scored = score(
            person(first, names: ["Fay Hanner", "Fay Feldberg"]),
            person(second, names: ["Faye Feldberg"]))

        #expect(scored.breakdown.name.score >= 88)
    }

    /// A dimension either side is silent about is **not assessed**, never zero — and on
    /// this surface that rule matters more than anywhere, because a freshly-minted
    /// duplicate is always the sparse record.
    @Test func silenceIsNotAssessedRatherThanZero() {
        let scored = score(
            person(
                first, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871", place: "Łomża, Poland")],
                partners: ["Tauba Pelc"]),
            person(second, names: ["Szlama Feldberg"]))

        #expect(scored.breakdown.birthYear == nil)
        #expect(scored.breakdown.birthPlace == nil)
        #expect(scored.breakdown.spouseName == nil)
        #expect(scored.breakdown.parents == nil)
        #expect(scored.breakdown.conflicts.isEmpty)
    }

    /// The relational dimensions are a plain cross product here — no vantage-point rule
    /// (45g), because neither side is a document with roles to read.
    @Test func partnersAndParentsCorroborateSymmetrically() {
        let scored = score(
            person(
                first, names: ["Sidney Feldberg"],
                partners: ["Fay Hanner"], parents: ["Szlama Feldberg", "Tauba Pelc"]),
            person(
                second, names: ["Sidney Feldberg"],
                partners: ["Fay Hanner"], parents: ["Tauba Pelc"]))

        #expect(scored.breakdown.spouseName?.kind == .exact)
        #expect(scored.breakdown.parents?.kind == .exact)
    }

    // MARK: - Conflicts

    /// The grandson named for his grandfather: the same name and a birth two
    /// generations apart. **This is the case the surface must not confuse**, and it
    /// drops out on the conflict penalty rather than on any rule about names.
    @Test func sameNameDifferentBirthYearsConflictsAndFallsBelowTheFloor() {
        let scored = score(
            person(
                first, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871")]),
            person(
                second, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1924")]))

        #expect(scored.breakdown.name.kind == .exact)
        #expect(scored.breakdown.conflicts.count == 1)
        // The band the floor's documentation names.
        #expect(scored.aggregateConfidence == 21)
    }

    /// Two same-named people with two different recorded **deaths** are two people —
    /// the roadmap's stated reason conflict detection matters more here than anywhere.
    /// Death is a conflict rather than a dimension: `MatchBreakdown` has no field for it.
    @Test func differentRecordedDeathsConflict() {
        let scored = score(
            person(
                first, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .death, date: "1943")]),
            person(
                second, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .death, date: "1968")]))

        #expect(scored.breakdown.conflicts.count == 1)
        #expect(scored.breakdown.conflicts[0].hasPrefix("death:"))
        #expect(scored.aggregateConfidence < Self.floor)
    }

    /// Two deaths inside the era's tolerance are a rounding difference between two
    /// records, not a disagreement.
    @Test func closeRecordedDeathsDoNotConflict() {
        let scored = score(
            person(
                first, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .death, date: "1943")]),
            person(
                second, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .death, date: "1944")]))

        #expect(scored.breakdown.conflicts.isEmpty)
    }

    /// A death before the other's birth, in **either** direction — the pair is
    /// unordered, so a rule that only looked one way would miss half of them.
    @Test func aDeathBeforeTheOthersBirthConflictsInBothDirections() {
        let dead = person(
            first, names: ["Szlama Feldberg"], facts: [PersonFact(type: .death, date: "1890")])
        let born = person(
            second, names: ["Szlama Feldberg"], facts: [PersonFact(type: .birth, date: "1924")])

        #expect(score(dead, born).breakdown.conflicts.contains { $0.hasPrefix("lifespan:") })
        #expect(score(born, dead).breakdown.conflicts.contains { $0.hasPrefix("lifespan:") })
    }

    /// Birth places that share nothing, not even a country.
    @Test func unrelatedBirthPlacesConflict() {
        let scored = score(
            person(
                first, names: ["Fay Hanner"],
                facts: [PersonFact(type: .birth, place: "Łomża, Poland")]),
            person(
                second, names: ["Fay Hanner"],
                facts: [PersonFact(type: .birth, place: "Chicago, Illinois, USA")]))

        #expect(scored.breakdown.conflicts.contains { $0.hasPrefix("birthPlace:") })
    }

    // MARK: - The roll-up

    /// **The calibration anchors**, asserted as the exact integers the design documents.
    /// These are the bands `defaultMinimumDuplicateConfidence` and
    /// `uncorroboratedFactor` are chosen by; a change that moves one is a change to the
    /// argument for the floor, and should have to say so here.
    @Test func theDocumentedBandsHold() {
        let nameOnly = score(
            person(first, names: ["Szlama Feldberg"]),
            person(second, names: ["Szlama Feldberg"]))
        #expect(nameOnly.aggregateConfidence == 75)

        let plusOne = score(
            person(
                first, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871")]),
            person(
                second, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871")]))
        #expect(plusOne.aggregateConfidence == 83)

        let plusThree = score(
            person(
                first, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871", place: "Łomża, Poland")],
                partners: ["Tauba Pelc"]),
            person(
                second, names: ["Szlama Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871", place: "Łomża, Poland")],
                partners: ["Tauba Pelc"]))
        #expect(plusThree.aggregateConfidence == 100)
    }

    /// **The floor's anchor**: names that agree on nothing at all, corroborated three
    /// ways, land exactly at 50 — admitted, at the bottom of the queue. This is the
    /// `Zelig`/`Sidney` known-variant case the name matcher cannot see (one man's
    /// Yiddish name and the American one he took), and it is the one kind of zero-name
    /// result worth keeping.
    @Test func aFullyCorroboratedNameMismatchLandsExactlyOnTheFloor() {
        let scored = score(
            person(
                first, names: ["Zelig Sternfeld"],
                facts: [PersonFact(type: .birth, date: "1871", place: "Łomża, Poland")],
                partners: ["Tauba Pelc"]),
            person(
                second, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871", place: "Łomża, Poland")],
                partners: ["Tauba Pelc"]))

        #expect(scored.breakdown.name.kind == .none)
        #expect(scored.aggregateConfidence == Self.floor)
    }

    /// A name agreement propped up by one incidental fact does **not** clear the floor —
    /// the same reasoning the link floor was set by, and the reason the anchor above
    /// needs all three dimensions.
    @Test func aNameMismatchWithOneAgreeingFactStaysOut() {
        let scored = score(
            person(
                first, names: ["Zelig Sternfeld"],
                facts: [PersonFact(type: .birth, date: "1871")]),
            person(
                second, names: ["Sidney Feldberg"],
                facts: [PersonFact(type: .birth, date: "1871")]))

        #expect(scored.aggregateConfidence < Self.floor)
    }

    /// Corroboration has to outrank a bare name agreement — the whole job of the factor
    /// that replaced the source discount.
    @Test func corroborationOutranksABareNameAgreement() {
        let bare = score(
            person(first, names: ["Marcus Hanner"]),
            person(second, names: ["Marcus Hanner"]))
        let corroborated = score(
            person(
                first, names: ["Marcus Hanner"],
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")]),
            person(
                second, names: ["Marcus Hanner"],
                facts: [PersonFact(type: .birth, date: "1892", place: "Łomża, Poland")]))

        #expect(corroborated.aggregateConfidence > bare.aggregateConfidence)
    }

    /// Deterministic: the same two views always produce the same integers.
    @Test func scoringIsDeterministic() {
        let a = person(
            first, names: ["Fay Hanner", "Fay Feldberg"],
            facts: [PersonFact(type: .birth, date: "1895")], partners: ["Sidney Feldberg"])
        let b = person(
            second, names: ["Faye Feldberg"],
            facts: [PersonFact(type: .birth, date: "1896")], partners: ["Sidney Feldberg"])

        #expect(score(a, b) == score(a, b))
    }

    /// A person with no names at all scores nothing rather than trapping — an unnamed
    /// person is a normal state (they exist, they're just unnamed).
    @Test func anUnnamedPersonScoresZero() {
        let scored = score(person(first, names: []), person(second, names: []))

        #expect(scored.breakdown.name.kind == .none)
        #expect(scored.aggregateConfidence == 0)
    }

    private static let floor = 50
}

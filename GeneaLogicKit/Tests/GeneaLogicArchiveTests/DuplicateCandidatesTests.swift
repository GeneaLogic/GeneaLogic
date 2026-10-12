import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// `duplicateCandidates` — the pairwise pass over concluded persons (§4.1, §4.6),
/// slice 45j.
///
/// `DuplicateMatcherTests` proves the *scoring*; these prove the **pass** — that each
/// unordered pair is offered once in canonical order, that the projection walks
/// relationships to reach partners and parents, that a merge makes a pair stop being
/// offered, and that nothing is written.
@Suite struct DuplicateCandidatesTests {

    // MARK: - Fixtures

    /// Adds a person with a full name and optional birth fact — the two things this
    /// surface actually compares.
    @discardableResult
    private func addPerson(
        _ name: String, birth: String? = nil, place: String? = nil, in archive: Archive
    ) throws -> Person {
        let person = try archive.addPerson(
            PersonDraft(
                names: [PersonName.deriving(type: .birth, given: nil, surname: nil, full: name)]))
        guard birth != nil || place != nil else { return person }
        return try archive.updatePerson(person.uid) {
            $0.facts.append(PersonFact(type: .birth, date: birth, place: place))
        }
    }

    // MARK: - The pair is found, once

    @Test func findsTwoRecordsForOnePerson() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let a = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        let b = try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        let candidates = archive.duplicateCandidates()

        #expect(candidates.count == 1)
        #expect(Set([candidates[0].person1, candidates[0].person2]) == Set([a.uid, b.uid]))
        #expect(candidates[0].match.breakdown.name.kind == .exact)
    }

    /// **Each unordered pair once, lower uid first.** A pass that offered both
    /// orderings would double every row in the queue, and the conflict sentences say
    /// "the first"/"the second" on the strength of this ordering.
    @Test func eachPairIsOfferedOnceInCanonicalOrder() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        for _ in 0..<3 { try addPerson("Szlama Feldberg", birth: "1871", in: archive) }

        let candidates = archive.duplicateCandidates()

        // Three persons → three unordered pairs, not six and not nine.
        #expect(candidates.count == 3)
        #expect(candidates.allSatisfy { $0.person1.raw < $0.person2.raw })
        let pairs = Set(candidates.map { "\($0.person1.raw)|\($0.person2.raw)" })
        #expect(pairs.count == 3)
    }

    /// Nobody is compared with themselves — the pairing is over *pairs*, and a person
    /// is trivially identical to themselves at 100.
    @Test func aPersonIsNeverPairedWithThemselves() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        #expect(archive.duplicateCandidates().isEmpty)
    }

    @Test func unrelatedPersonsAreNotOffered() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        try addPerson("Fay Hanner", birth: "1895", in: archive)

        #expect(archive.duplicateCandidates().isEmpty)
    }

    // MARK: - The projection

    /// The relational dimensions are reached by **walking relationships** — the same
    /// projection the link direction uses, which is why `MatchCorpus` is shared rather
    /// than re-derived here.
    @Test func partnersAreReachedThroughRelationships() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let wife = try addPerson("Fay Hanner", in: archive)
        let a = try addPerson("Sidney Feldberg", in: archive)
        let b = try addPerson("Sidney Feldberg", in: archive)
        try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: a.uid, person2Uid: wife.uid))
        try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: b.uid, person2Uid: wife.uid))

        let pair = archive.duplicateCandidates()
            .first { Set([$0.person1, $0.person2]) == Set([a.uid, b.uid]) }

        #expect(pair?.match.breakdown.spouseName?.kind == .exact)
    }

    @Test func parentsAreReachedThroughRelationships() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let father = try addPerson("Szlama Feldberg", in: archive)
        let a = try addPerson("Sidney Feldberg", in: archive)
        let b = try addPerson("Sidney Feldberg", in: archive)
        // §4.5's convention: person1 is the parent.
        try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: a.uid))
        try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: b.uid))

        let pair = archive.duplicateCandidates()
            .first { Set([$0.person1, $0.person2]) == Set([a.uid, b.uid]) }

        #expect(pair?.match.breakdown.parents?.kind == .exact)
    }

    // MARK: - The floor and the limit

    @Test func theFloorDropsWeakPairs() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        #expect(archive.duplicateCandidates(minimumConfidence: 101).isEmpty)
        #expect(archive.duplicateCandidates(minimumConfidence: 0).count == 1)
    }

    /// The `Array` precondition `Archive+Matching`'s `ranked` was fixed for: a negative
    /// limit means "no results", never a crash in release.
    @Test func aNonPositiveLimitMeansNoResults() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        #expect(archive.duplicateCandidates(limit: 0).isEmpty)
        #expect(archive.duplicateCandidates(limit: -1).isEmpty)
        #expect(archive.duplicateCandidates(limit: 1).count == 1)
    }

    // MARK: - Ordering

    /// Ranked by confidence, broken deterministically by uid — a queue that reshuffled
    /// between runs would be a bug, and a test could not pin it.
    @Test func orderingIsDeterministicAndRanked() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        // One corroborated pair and one bare-name pair, so the ranking has work to do.
        try addPerson("Szlama Feldberg", birth: "1871", place: "Łomża, Poland", in: archive)
        try addPerson("Szlama Feldberg", birth: "1871", place: "Łomża, Poland", in: archive)
        try addPerson("Fay Hanner", in: archive)
        try addPerson("Fay Hanner", in: archive)

        let first = archive.duplicateCandidates()
        let second = archive.duplicateCandidates()

        #expect(first == second)
        #expect(first.count == 2)
        #expect(
            first[0].match.aggregateConfidence >= first[1].match.aggregateConfidence)
    }

    // MARK: - Merging resolves the pair

    /// The point of the surface: once the duplicate is merged away there is no pair
    /// left to offer. (45m adds the *other* resolution — declining one.)
    @Test func aMergedPairStopsBeingOffered() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let survivor = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        let duplicate = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        #expect(archive.duplicateCandidates().count == 1)

        try archive.mergePersons(duplicate.uid, into: survivor.uid)

        #expect(archive.duplicateCandidates().isEmpty)
    }

    // MARK: - Nothing is written

    /// Candidates are **ephemeral**: no record, no sidecar, no index row. The strongest
    /// available statement of that is that the archive still verifies clean and holds
    /// exactly the conclusions it did before.
    @Test func nothingIsWritten() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        let before = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        #expect(!archive.duplicateCandidates().isEmpty)
        let after = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()

        #expect(before == after)
        #expect(archive.links().isEmpty)
    }

    /// An empty archive has no pairs, and asking is not an error.
    @Test func anEmptyArchiveYieldsNothing() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        #expect(archive.duplicateCandidates().isEmpty)
    }

    // MARK: - The snapshot / score split (45m)

    /// Scoring a snapshot must give **exactly** what the all-in-one call gives. The split
    /// exists so the quadratic half can run without holding `Archive`'s lock (45m's
    /// `/code-review` found the off-main scan still holding it for the whole pass); if the
    /// two paths could disagree, the lane would be showing something the CLI never would.
    @Test func scoringASnapshotMatchesTheDirectCall() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        try addPerson("Szlama Feldberg", birth: "1871", place: "Rypin, Poland", in: archive)
        try addPerson("Szlama Feldberg", birth: "1871", place: "Rypin", in: archive)
        try addPerson("Fay Hanner", birth: "1895", in: archive)

        let input = archive.duplicateScanInput()

        #expect(input.personCount == 3)
        #expect(Archive.duplicateCandidates(in: input) == archive.duplicateCandidates())
        // …including under the parameters the CLI exposes, which the snapshot doesn't bake in.
        #expect(
            Archive.duplicateCandidates(in: input, minimumConfidence: 0, limit: 2)
                == archive.duplicateCandidates(minimumConfidence: 0, limit: 2))
    }

    /// A snapshot is a snapshot: taken before a dismissal, it still scores the pair it
    /// captured. That is the property that makes it safe to carry across a suspension
    /// point — and the reason a decision re-scans rather than re-using one.
    @Test func aSnapshotDoesNotSeeALaterDismissal() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let a = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        let b = try addPerson("Szlama Feldberg", birth: "1871", in: archive)

        let input = archive.duplicateScanInput()
        try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        #expect(Archive.duplicateCandidates(in: input).count == 1)
        #expect(archive.duplicateCandidates().isEmpty)
    }
}

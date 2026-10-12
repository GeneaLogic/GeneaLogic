import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The dismissal record (spec §6.6, slice 45m) — the memory a declined suggestion has
/// nowhere else to live.
///
/// The property that matters most is the one a unit test states least naturally: a
/// dismissal must survive **closing the archive**. Every test that asserts a pair stops
/// being offered therefore reopens rather than reusing the handle, because a session-only
/// dismissal would pass the in-memory version of the same assertion.
@Suite struct DismissalTests {

    // MARK: - Fixtures

    @discardableResult
    private func addPerson(
        _ name: String, birth: String? = nil, in archive: Archive
    ) throws -> Person {
        let person = try archive.addPerson(
            PersonDraft(
                names: [PersonName.deriving(type: .birth, given: nil, surname: nil, full: name)]))
        guard let birth else { return person }
        return try archive.updatePerson(person.uid) {
            $0.facts.append(PersonFact(type: .birth, date: birth))
        }
    }

    /// An archive holding one duplicate pair the matcher finds on its own.
    private func archiveWithADuplicate() throws -> (Archive, URL, Person, Person) {
        let url = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: url)
        let a = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        let b = try addPerson("Szlama Feldberg", birth: "1871", in: archive)
        return (archive, url, a, b)
    }

    // MARK: - The record

    @Test func dismissWritesARecordThatSurvivesReopening() throws {
        let (archive, url, a, b) = try archiveWithADuplicate()

        let dismissal = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)
        #expect(dismissal.uid.raw.hasPrefix("DSM-"))
        #expect(dismissal.provenance.createdBy == .human)

        let reopened = try Archive.open(at: url)
        #expect(reopened.dismissals() == [dismissal])
    }

    /// **The hand-test, as an assertion.** A dismissed pair must not come back at the next
    /// launch — the failure the whole slice exists to prevent.
    @Test func aDismissedPairIsNotOfferedAgainAfterReopening() throws {
        let (archive, url, a, b) = try archiveWithADuplicate()
        #expect(archive.duplicateCandidates().count == 1)

        try archive.dismiss(.samePerson, between: a.uid, and: b.uid)
        #expect(archive.duplicateCandidates().isEmpty)

        let reopened = try Archive.open(at: url)
        #expect(reopened.duplicateCandidates().isEmpty)
    }

    /// Deletion **is** the retraction — there is no third verb (45c).
    @Test func undismissReturnsThePairToTheQueue() throws {
        let (archive, url, a, b) = try archiveWithADuplicate()
        try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        let removed = try archive.undismiss(.samePerson, between: a.uid, and: b.uid)
        #expect(removed.count == 1)
        #expect(archive.dismissals().isEmpty)
        #expect(archive.duplicateCandidates().count == 1)

        let reopened = try Archive.open(at: url)
        #expect(reopened.duplicateCandidates().count == 1)

        // …and restoring the removed record declines it again — the undo path.
        try reopened.restoreDismissal(removed[0])
        #expect(reopened.duplicateCandidates().isEmpty)
    }

    /// Retracting something never declined is the state the caller asked for, not an
    /// error — two windows on one archive reach it routinely.
    @Test func undismissingAPairThatWasNeverDeclinedIsNotAnError() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()
        #expect(try archive.undismiss(.samePerson, between: a.uid, and: b.uid).isEmpty)
    }

    // MARK: - One judgement, one record

    /// Two records for one judgement would leave `undismiss` half-effective.
    @Test func dismissingTwiceReturnsTheSameRecord() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()

        let first = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)
        let second = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        #expect(first == second)
        #expect(archive.dismissals().count == 1)
    }

    /// `same-person` is symmetric, so declining it from the other end is the *same*
    /// judgement. An `==` guard would store it twice — 45k's shipped bug.
    @Test func theReversedPairIsTheSameDismissal() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()

        let first = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)
        let reversed = try archive.dismiss(.samePerson, between: b.uid, and: a.uid)

        #expect(first == reversed)
        #expect(archive.dismissals().count == 1)
        // Stored in canonical order regardless of which way it was asked.
        #expect(first.person1Uid.raw < first.person2Uid.raw)
    }

    /// A directional subject reversed is the **opposite** claim, so it is a second record.
    @Test func aReversedParentChildDismissalIsADifferentClaim() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()

        try archive.dismiss(.parentChild, between: a.uid, and: b.uid)
        try archive.dismiss(.parentChild, between: b.uid, and: a.uid)

        #expect(archive.dismissals().count == 2)
    }

    /// The scoping rule 45l inherits: declining one claim leaves the others open.
    @Test func aDismissalForecloseOnlyItsOwnSubject() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()

        try archive.dismiss(.parentChild, between: a.uid, and: b.uid)

        #expect(!archive.isDismissed(.samePerson, between: a.uid, and: b.uid))
        #expect(archive.isDismissed(.parentChild, between: a.uid, and: b.uid))
        // …so the duplicate lane is untouched by a relationship dismissal.
        #expect(archive.duplicateCandidates().count == 1)
    }

    // MARK: - The stored breakdown

    /// Declining a *strong* candidate is the interesting record (45c), so the reasoning
    /// the user was shown is kept — and it is the candidate's own, not a re-score.
    @Test func dismissingACandidateStoresTheBreakdownItWasShown() throws {
        let (archive, _, _, _) = try archiveWithADuplicate()
        let candidate = try #require(archive.duplicateCandidates().first)

        let dismissal = try archive.dismiss(candidate, dismissedBy: .human("ada"))

        #expect(dismissal.match == candidate.match.breakdown)
        #expect(dismissal.aggregateConfidence == candidate.match.aggregateConfidence)
        #expect(dismissal.dismissedBy == "ada")
    }

    /// A suggestion with no score stores none — 45l's shape. An aggregate with no
    /// breakdown behind it is the opaque percentage §4.6 refuses, so it is dropped too.
    @Test func anUnscoredDismissalStoresNoConfidence() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()

        let dismissal = try archive.dismiss(
            .parentChild, between: a.uid, and: b.uid, aggregateConfidence: 90)

        #expect(dismissal.match == nil)
        #expect(dismissal.aggregateConfidence == nil)
    }

    // MARK: - Validation

    @Test func dismissingAnUnknownPersonThrows() throws {
        let (archive, _, a, _) = try archiveWithADuplicate()

        #expect(throws: ArchiveError.personNotFound("PER-nope")) {
            try archive.dismiss(.samePerson, between: a.uid, and: "PER-nope")
        }
    }

    /// Every subject is a claim *between* two people; a pair that is one person is not
    /// something any lane can propose.
    @Test func dismissingAPersonAgainstThemselvesThrows() throws {
        let (archive, _, a, _) = try archiveWithADuplicate()

        #expect(throws: ArchiveError.cannotDismissPersonAgainstItself(a.uid)) {
            try archive.dismiss(.samePerson, between: a.uid, and: a.uid)
        }
    }

    // MARK: - The merge cascade (45f)

    /// A dismissal about a *third* person follows the absorbed record onto the survivor,
    /// exactly as links and relationships do — otherwise it would dangle, and worse, stop
    /// foreclosing the pair it was written to foreclose.
    @Test func aDismissalNamingTheAbsorbedPersonIsRepointed() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()
        let third = try addPerson("Tauba Pelc", birth: "1875", in: archive)

        try archive.dismiss(.samePerson, between: b.uid, and: third.uid)
        let decision = try archive.mergePersons(b.uid, into: a.uid)

        #expect(decision.rewrittenDismissals.count == 1)
        let repointed = try #require(archive.dismissals().first)
        #expect(repointed.involves(a.uid))
        #expect(!repointed.involves(b.uid))
        #expect(repointed.person1Uid.raw < repointed.person2Uid.raw)

        // …and the revert puts it back naming the absorbed person again.
        try archive.revertMerge(decision)
        #expect(archive.dismissals().first?.involves(b.uid) == true)
    }

    /// **The contradiction.** The user said these two are not one person, then merged
    /// them. The record cannot survive as "X is not X", and deleting it silently would be
    /// the one cascade effect they could not see.
    @Test func mergingADismissedPairDropsAndReportsTheContradiction() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()
        let dismissal = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        let decision = try archive.mergePersons(b.uid, into: a.uid)

        #expect(decision.droppedDismissals == [dismissal])
        #expect(decision.contradictedDismissals == [dismissal])
        #expect(archive.dismissals().isEmpty)

        try archive.revertMerge(decision)
        #expect(archive.dismissals() == [dismissal])
    }

    /// Repointing can restate something already on record — the user declined the same
    /// claim against both duplicates. One judgement, one record; and the collapse is
    /// *not* reported as a contradiction, because nothing was overruled.
    @Test func aRepointedDuplicateDismissalCollapses() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()
        let third = try addPerson("Tauba Pelc", birth: "1875", in: archive)

        try archive.dismiss(.samePerson, between: a.uid, and: third.uid)
        try archive.dismiss(.samePerson, between: b.uid, and: third.uid)

        let decision = try archive.mergePersons(b.uid, into: a.uid)

        #expect(archive.dismissals().count == 1)
        #expect(decision.droppedDismissals.count == 1)
        #expect(decision.contradictedDismissals.isEmpty)

        try archive.revertMerge(decision)
        #expect(archive.dismissals().count == 2)
    }

    // MARK: - Referential integrity

    /// §2.3's no-cascade removal leaves the same residue here as everywhere else, and an
    /// unfindable *no* is worse than a reported one: it still suppresses a suggestion.
    @Test func removingAPersonLeavesAFindableDanglingDismissal() throws {
        let (archive, _, a, b) = try archiveWithADuplicate()
        let dismissal = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        try archive.removePerson(b.uid)

        #expect(
            archive.findDanglingReferences()
                == [.dismissalEndpoint(dismissal: dismissal.uid, missingPerson: b.uid)])
    }

    // MARK: - Back-compat

    /// An archive written before this slice has no `conclusions/dismissals/` at all. It
    /// must open, rebuild, and simply hold no dismissals — the index walk cannot treat a
    /// missing directory as a failure.
    @Test func aPre45mArchiveOpensAndRebuildsWithNoDismissals() throws {
        let (archive, url, a, b) = try archiveWithADuplicate()
        try FileManager.default.removeItem(
            at: url.appendingPathComponent("conclusions/dismissals"))

        let reopened = try Archive.open(at: url)
        try reopened.rebuildIndex()

        #expect(reopened.dismissals().isEmpty)
        #expect(reopened.duplicateCandidates().count == 1)

        // …and dismissing recreates the directory rather than failing on it.
        try reopened.dismiss(.samePerson, between: a.uid, and: b.uid)
        #expect(reopened.duplicateCandidates().isEmpty)
        _ = archive
    }

    /// The index is a rebuildable cache (§5.1) — dismissals included.
    @Test func rebuildingTheIndexRecoversDismissalsFromTheirSidecars() throws {
        let (archive, url, a, b) = try archiveWithADuplicate()
        let dismissal = try archive.dismiss(.samePerson, between: a.uid, and: b.uid)

        try FileManager.default.removeItem(at: url.appendingPathComponent(".index"))
        let reopened = try Archive.open(at: url)

        #expect(reopened.dismissals() == [dismissal])
    }
}

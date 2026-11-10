import Foundation
import GeneaLogicArchive
import GeneaLogicMatch
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp

/// Slice 83 — Review's two keys against a real archive: what each decides, and that a
/// quick second press waits for the first write.
@MainActor
@Suite struct ReviewCommandTests {
    /// A window on Review with one name waiting on two look-alike candidates.
    private func makeReview() async throws -> (model: ArchiveModel, root: URL) {
        let (model, root) = try AppTestSupport.makeModel()
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        await model.act { model.createPerson(given: "Anne", surname: "Roe") }
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject,
            informationQuality: .primary)
        _ = try #require(model.archive).addArtifact(
            ArtifactDraft(title: "Census", mediaType: .image, personsMentioned: [mention]))
        model.activeTab = .review
        model.refreshReviewWorklist()
        return (model, root)
    }

    private func onlyRow(of model: ArchiveModel) throws -> ReviewItem {
        try #require(model.reviewItems.first)
    }

    @Test func acceptConfirmsTheTopCandidateAndUndoBringsTheRowBack() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)
        #expect(row.candidates.count == 2)

        await model.act { model.perform(.acceptSuggestion, on: .review(row.target)) }
        #expect(model.reviewItems.isEmpty)

        await model.undoAndSettle()
        #expect(model.reviewItems.count == 1)
    }

    /// The row stays, so the selection does, and ⌘⌫ moves on to the next candidate.
    @Test func declineRejectsOnlyTheTopCandidate() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)
        let top = try #require(row.candidates.first)

        await model.act { model.perform(.declineSuggestion, on: .review(row.target)) }

        let after = try onlyRow(of: model)
        #expect(after.id == row.id)
        #expect(after.candidates.map(\.id) == row.candidates.dropFirst().map(\.id))
        #expect(!after.candidates.contains { $0.id == top.id })
    }

    /// The write is asynchronous and the row stays until it lands, so the second press
    /// would otherwise confirm the candidate the first just rejected.
    @Test func aSecondPressWaitsForTheFirstWrite() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)

        await model.act {
            model.perform(.declineSuggestion, on: .review(row.target))
            model.perform(.acceptSuggestion, on: .review(row.target))
        }

        #expect(try onlyRow(of: model).candidates.count == 1)
    }

    /// Review's keys wait for Review's own writes, not for any write: an import or a wait
    /// on another process's lock is no reason to refuse a verdict.
    @Test func anUnrelatedWriteDoesNotHoldUpADecision() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)

        await model.act {
            model.createPerson(given: "Marcus", surname: "Hanner")
            #expect(model.hasMutationsInFlight)
            model.perform(.acceptSuggestion, on: .review(row.target))
        }

        #expect(model.reviewItems.isEmpty)
        #expect(model.reviewDecisionsInFlight == 0)
    }

    /// Two records with one name, as a duplicate pair usually is, are told apart.
    @Test func aSameNamedPairIsToldApart() {
        let pair = DuplicateCandidateFixture.item(firstName: "Anna Roe", secondName: "Anna Roe")
        let names = pair.distinguishedNames
        #expect(names.first != names.second)
        #expect(names.first.hasPrefix("“Anna Roe” ("))

        let distinct = DuplicateCandidateFixture.item(firstName: "Anna Roe", secondName: "Ann Roe")
        #expect(distinct.distinguishedNames == ("“Anna Roe”", "“Ann Roe”"))
    }

    /// A command a sheet answers is left for `ReviewCommandHost`, which is there whichever
    /// pane is showing, so a row's context menu can name an unselected row.
    @Test func aSheetCommandIsLeftForTheHost() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)

        model.perform(.somebodyNew, on: .review(row.target))

        let claimed = try #require(model.claimPendingCommand { $0 == .somebodyNew })
        #expect(claimed.subject == .review(row.target))
    }

    @Test func theMenuFollowsTheLiveSelection() async throws {
        let (model, root) = try await makeReview()
        defer { AppTestSupport.remove(root) }
        let row = try onlyRow(of: model)

        model.selectedReviewID = row.id
        #expect(model.commandContext.selectedReview == row.target)

        model.selectedReviewID = "a row since resolved"
        #expect(model.commandContext.selectedReview == nil)
    }
}

/// A duplicates row with chosen names, for what a merge dialog calls the two records.
private enum DuplicateCandidateFixture {
    static func item(firstName: String, secondName: String) -> DuplicateReviewItem {
        let breakdown = MatchBreakdown(
            name: MatchDimension(kind: .exact, score: 100), nameAlgo: "daitch-mokotoff",
            birthYear: MatchDimension(kind: .none, score: 0),
            birthPlace: MatchDimension(kind: .none, score: 0),
            spouseName: MatchDimension(kind: .none, score: 0),
            parents: MatchDimension(kind: .none, score: 0), conflicts: [])
        let first = PersonID("PER-1")
        let second = PersonID("PER-2")
        return DuplicateReviewItem(
            candidate: DuplicateCandidate(
                person1: first, person2: second,
                match: DuplicateScore(breakdown: breakdown, aggregateConfidence: 90)),
            first: PersonSummary(
                uid: first, displayName: firstName, primaryDate: nil, factCount: 2),
            second: PersonSummary(
                uid: second, displayName: secondName, primaryDate: nil, factCount: 0))
    }
}

import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp

/// Slice 84 — the one sidebar's logic, as values: a row's area and selection, where a
/// switch of area scrolls to, the header counts, and Review's row order.
@Suite struct SidebarSelectionTests {
    private let artifact = ArtifactID("ART-a")
    private let person = PersonID("PER-a")
    private let otherPerson = PersonID("PER-b")
    private let review = "name|ART-a|p1"

    private func selection(on area: ArchiveTab) -> SidebarSelection {
        SidebarSelection(area: area, artifact: artifact, person: person, review: review)
    }

    /// The list shows one selected row, the current area's.
    @Test func theSelectedRowIsTheAreas() {
        #expect(selection(on: .artifacts).item == .artifact(artifact))
        #expect(selection(on: .people).item == .person(person))
        #expect(selection(on: .tree).item == .person(person))
        #expect(selection(on: .review).item == .review(review))
        #expect(selection(on: .trash).item == .trash)
    }

    /// Selecting a row sets the area, and leaves the other areas' selections alone.
    @Test func selectingARowSetsItsArea() {
        var state = selection(on: .artifacts)
        state.select(.person(otherPerson))
        #expect(
            state
                == SidebarSelection(
                    area: .people, artifact: artifact, person: otherPerson, review: review))

        state.select(.review("fact|PER-a"))
        #expect(state.area == .review)
        #expect(state.review == "fact|PER-a")
        #expect(state.person == otherPerson)

        state.select(.artifact(ArtifactID("ART-b")))
        #expect(state.area == .artifacts)
        #expect(state.item == .artifact(ArtifactID("ART-b")))

        // The Trash row is its area's only row (slice 86).
        state.select(.trash)
        #expect(state.area == .trash)
        #expect(state.artifact == ArtifactID("ART-b"))
        #expect(state.person == otherPerson)
    }

    /// Picking someone while the tree shows refocuses the tree.
    @Test func aPersonKeepsTheTree() {
        var state = selection(on: .tree)
        state.select(.person(otherPerson))
        #expect(state.area == .tree)
        #expect(state.person == otherPerson)
    }

    /// From another area, a person row returns to the view People was left in.
    @Test func aPersonFromAnotherAreaReturnsToPeoplesView() {
        var state = selection(on: .artifacts)
        state.peopleShowsTree = true
        state.select(.person(otherPerson))
        #expect(state.area == .tree)

        state.area = .review
        state.peopleShowsTree = false
        state.select(.person(person))
        #expect(state.area == .people)

        // On the list, a person stays on the list whatever People was before.
        state.peopleShowsTree = true
        state.select(.person(otherPerson))
        #expect(state.area == .people)
    }

    /// The list deselects when its row leaves it; the area keeps what it comes back to.
    @Test func aDeselectionIsIgnored() {
        for area in ArchiveTab.allCases {
            var state = selection(on: area)
            state.select(nil)
            #expect(state == selection(on: area))
        }
    }

    @Test func eachAreaHasItsSection() {
        #expect(
            ArchiveTab.allCases.map(\.section) == [.artifacts, .people, .people, .review, .trash])
        #expect(SidebarItem.review(review).section == .review)
        #expect(SidebarItem.artifact(artifact).section == .artifacts)
        #expect(SidebarItem.person(person).section == .people)
        #expect(SidebarItem.trash.section == .trash)
    }

    /// Like Review, the Trash row hides while a search is active (slice 86).
    @Test func aSearchHidesReviewAndTheTrash() {
        #expect(SidebarSection.hidden(isSearching: true) == [.review, .trash])
        #expect(SidebarSection.hidden(isSearching: false).isEmpty)
    }
}

@Suite struct SidebarRevealTests {
    private let person = PersonID("PER-a")

    private func reveal(
        _ selection: SidebarSelection, collapsed: Set<SidebarSection> = [],
        hidden: Set<SidebarSection> = [], listed: Bool = true
    ) -> SidebarReveal {
        SidebarReveal(for: selection, collapsed: collapsed, hidden: hidden) { _ in listed }
    }

    @Test func itScrollsToTheSelection() {
        let state = SidebarSelection(area: .people, person: person)
        #expect(reveal(state) == SidebarReveal(expand: nil, target: .item(.person(person))))
    }

    /// Show in Tree lands on People's section: Tree is a view of People.
    @Test func theTreeScrollsToItsFocusInPeople() {
        let state = SidebarSelection(area: .tree, person: person)
        #expect(reveal(state).target == .item(.person(person)))
    }

    @Test func withNoSelectionItScrollsToTheHeader() {
        let state = SidebarSelection(area: .artifacts)
        #expect(reveal(state) == SidebarReveal(expand: nil, target: .header(.artifacts)))
    }

    /// A search can filter the selection out of the list; the header is still there.
    @Test func aSelectionTheListDoesntShowScrollsToTheHeader() {
        let state = SidebarSelection(area: .people, person: person)
        #expect(reveal(state, listed: false).target == .header(.people))
    }

    @Test func aCollapsedSectionIsExpandedFirst() {
        let state = SidebarSelection(area: .review, review: "name|ART-a|p1")
        let result = reveal(state, collapsed: [.review, .people])
        #expect(result == SidebarReveal(expand: .review, target: .item(.review("name|ART-a|p1"))))
        #expect(reveal(SidebarSelection(area: .artifacts), collapsed: [.review]).expand == nil)
    }

    /// The Trash is pinned under the list, always in view, so a jump to it scrolls nothing
    /// (slice 86).
    @Test func theTrashHasNothingToScrollTo() {
        #expect(reveal(SidebarSelection(area: .trash)) == SidebarReveal(expand: nil, target: nil))
    }

    /// Review hides while searching, so there is nothing to scroll to or expand.
    @Test func aHiddenSectionHasNoTarget() {
        let state = SidebarSelection(area: .review, review: "name|ART-a|p1")
        #expect(
            reveal(state, collapsed: [.review], hidden: [.review])
                == SidebarReveal(expand: nil, target: nil))
    }
}

@Suite struct SidebarCountTests {
    @Test func aCountSaysWhatIsShownOfWhat() {
        #expect(SidebarCount.text(shown: 309, of: 309) == "309")
        #expect(SidebarCount.text(shown: 15, of: 309) == "15 of 309")
        #expect(SidebarCount.text(shown: 0, of: 309) == "0 of 309")
        #expect(SidebarCount.text(shown: 0, of: 0) == "0")
    }

    @Test func reviewsCountWaitsForTheDuplicatesScan() {
        #expect(SidebarCount.review(12, isScanning: true) == "12…")
        #expect(SidebarCount.review(12, isScanning: false) == "12")
        #expect(SidebarCount.review(0, isScanning: true) == "0…")
    }
}

/// Review's rows against a real archive: a name waiting, and a linked source's fact.
@MainActor
@Suite struct ReviewSidebarRowTests {
    private func makeArchive() async throws -> (model: ArchiveModel, root: URL) {
        let (model, root) = try AppTestSupport.makeModel()
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        await model.act { model.createPerson(given: "Anne", surname: "Roe") }
        let census = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject,
            informationQuality: .primary,
            facts: [RecordedFact(type: .occupation, value: "tailor")])
        let witness = PersonMention(
            localRef: "p2", nameAsRecorded: "Anne Roe", role: .witness,
            informationQuality: .secondary)
        _ = try #require(model.archive).addArtifact(
            ArtifactDraft(title: "Census", mediaType: .image, personsMentioned: [census, witness]))
        model.refreshReviewWorklist()
        // Linking the census's subject leaves its occupation to record: the facts lane.
        let subject = try #require(model.reviewItems.first { $0.recordedName == "Ann Roe" })
        let top = try #require(subject.candidates.first)
        await model.act { model.confirmSuggestion(top.suggestion) }
        model.refreshReviewWorklist()
        return (model, root)
    }

    private func rows(_ model: ArchiveModel, scanning: Bool) -> [ReviewSidebarRow] {
        ReviewSidebarRow.rows(
            names: model.reviewItems, facts: model.factItems,
            relationships: model.relationshipItems, duplicates: model.duplicateItems,
            isScanningDuplicates: scanning)
    }

    /// The lanes run names, facts, relationships, duplicates: the order Review's keys
    /// walk (`reviewRows`), so the selection moves down the sidebar.
    @Test func theLanesRunInReviewsOrder() async throws {
        let (model, root) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        model.refreshDuplicateCandidates()
        await model.duplicateScanSettled()
        #expect(!model.reviewItems.isEmpty)
        #expect(!model.factItems.isEmpty)

        let rows = model.reviewSidebarRows()
        #expect(rows.compactMap(\.target) == model.reviewRows)

        let lanes = rows.map(Self.lane)
        #expect(lanes == lanes.sorted())
    }

    /// While the first scan runs, the duplicates lane holds its place at the end.
    @Test func theScanHoldsTheDuplicatesPlace() async throws {
        let (model, root) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        let rows = rows(model, scanning: true)
        #expect(rows.last?.id == ReviewSidebarRow.scanningID)
        #expect(rows.last?.target == nil)
        #expect(rows.dropLast().map(\.id) == model.reviewRows.map(\.id))
    }

    @Test func nothingOwedIsNoRows() {
        #expect(
            ReviewSidebarRow.rows(
                names: [], facts: [], relationships: [], duplicates: [],
                isScanningDuplicates: false
            ).isEmpty)
    }

    private static func lane(_ row: ReviewSidebarRow) -> Int {
        switch row {
        case .name: 0
        case .fact: 1
        case .relationship: 2
        case .scanningDuplicates, .duplicate: 3
        }
    }
}

/// The tree runs People's commands, and People doesn't run the tree's.
@Suite struct TreeRunsPeoplesCommandsTests {
    @Test func theTreeRunsPeoplesCommands() {
        #expect(ArchiveTab.tree.runs(.people))
        #expect(!ArchiveTab.people.runs(.tree))
        for tab in ArchiveTab.allCases { #expect(tab.runs(tab)) }
        #expect(!ArchiveTab.tree.runs(.artifacts))
        #expect(ArchiveCommand.delete(on: .tree) == .deletePerson)
    }

    /// The Person menu on the tree acts on the person selected in the sidebar.
    @Test func thePersonMenuWorksOnTheTree() {
        let person = PersonID("PER-a")
        let context = CommandContext(
            hasArchive: true, activeTab: .tree, selectedPerson: person, personCount: 2)
        for command in [
            ArchiveCommand.addName, .addFact, .addRelationship, .mergePerson, .deletePerson,
        ] {
            #expect(context.isAvailable(command), "\(command) on the tree")
        }
    }
}

/// A sidebar row's commands run from any area; the menu bar's stay scoped by area.
@MainActor
@Suite struct SidebarCommandTests {
    private let artifact = ArtifactID("ART-a")
    private let person = PersonID("PER-a")
    private let reviewRow = ReviewTarget(id: "row", lane: .name(hasCandidates: true))

    @Test(arguments: ArchiveTab.allCases)
    func aRowsVerbRunsFromAnyArea(_ area: ArchiveTab) {
        let context = CommandContext(hasArchive: true, activeTab: area, personCount: 2)
        let rows: [(ArchiveCommand, CommandSubject)] = [
            (.deleteArtifact, .artifact(artifact)), (.deletePerson, .person(person)),
            (.mergePerson, .person(person)), (.showInTree, .person(person)),
            (.acceptSuggestion, .review(reviewRow)), (.somebodyNew, .review(reviewRow)),
            (.refreshReview, .archive),
        ]
        for (command, subject) in rows {
            #expect(context.canPerform(command, on: subject, fromSidebar: true))
            // Show in Tree is off on the tree it would show (`canPerform`).
            let onItsArea =
                (command.tab.map(area.runs) ?? true) && !(command == .showInTree && area == .tree)
            #expect(
                context.canPerform(command, on: subject) == onItsArea,
                "\(command) off the sidebar is scoped by area")
        }
    }

    /// The rest of the rule still holds: a sheet up, or a merge with nobody to merge into.
    @Test func fromTheSidebarIsOnlyTheArea() {
        var context = CommandContext(hasArchive: true, activeTab: .review, personCount: 1)
        #expect(!context.canPerform(.mergePerson, on: .person(person), fromSidebar: true))
        context.personCount = 2
        context.isPresentingModal = true
        #expect(!context.canPerform(.deletePerson, on: .person(person), fromSidebar: true))
    }

    /// From another area the sidebar's Move to Trash runs, at once (slice 86); the menu
    /// bar's doesn't.
    @Test func aSidebarMoveToTrashFromReviewRuns() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("src-\(UUID().uuidString)-census.txt")
        try Data("scan".utf8).write(to: source)
        await model.act { model.ingest([source]) }
        let artifact = try #require(model.artifacts.first?.uid)
        model.activeTab = .review

        await model.act { model.perform(.deleteArtifact, on: .artifact(artifact)) }
        #expect(model.artifacts.map(\.uid) == [artifact])

        await model.act {
            model.perform(.deleteArtifact, on: .artifact(artifact), fromSidebar: true)
        }
        #expect(model.pendingCommand == nil)
        #expect(model.artifacts.isEmpty)
        #expect(model.trashCount == 1)
    }

    /// The tree is People too, so a new person stays on it, as its new focus.
    @Test func newPersonFromTheTreeStaysOnTheTree() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = .tree
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        #expect(model.pendingTab == nil)

        model.activeTab = .review
        await model.act { model.createPerson(given: "Ben", surname: "Roe") }
        #expect(model.pendingTab == .people)
    }

    /// Asking for the sheet doesn't move the window: a cancel would lose your place.
    @Test func newPersonWaitsForThePerson() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = .review
        model.perform(.newPerson)
        #expect(model.isCreatingPerson)
        #expect(model.pendingTab == nil)
    }

    /// A merge follows the survivor in People's selection, but leaves the window on the
    /// area it was merged from (Review's duplicates lane).
    @Test func aMergeDoesNotLeaveReview() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        await model.act { model.createPerson(given: "Anne", surname: "Roe") }
        let ids = model.persons.map(\.uid)
        model.activeTab = .review
        model.pendingTab = nil

        await model.act { model.mergePersons(ids[1], into: ids[0]) }

        #expect(model.lastCreatedPerson == ids[0])
        #expect(model.pendingTab == nil)
    }

    /// Review's count shows on every area, so an edit to a person re-scans the duplicates.
    /// An edit is not a create or a merge, which re-scanned before slice 84 too.
    @Test func anEditToAPersonRescansTheDuplicates() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        model.refreshDuplicateCandidates()
        await model.duplicateScanSettled()
        let before = model.duplicateScansStarted
        let id = try #require(model.persons.first?.uid)

        await model.act {
            model.updatePerson(of: id) { $0.facts.append(PersonFact(type: .birth, date: "1888")) }
        }
        await model.duplicateScanSettled()

        #expect(model.duplicateScansStarted > before)
    }

    /// One scan at a time (84's `/code-review`): requests during one run it once more,
    /// rather than each starting a quadratic sweep of its own.
    @Test func scanRequestsDuringAScanRunOnceMore() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        await model.act { model.createPerson(given: "Anne", surname: "Roe") }
        await model.duplicateScanSettled()
        let before = model.duplicateScansStarted

        model.refreshDuplicateCandidates()
        model.refreshDuplicateCandidates()
        model.refreshDuplicateCandidates()
        #expect(model.duplicateScansStarted == before + 1)
        #expect(model.duplicateScanRequested)

        await model.duplicateScanSettled()
        #expect(model.duplicateScansStarted == before + 2)
        #expect(!model.duplicateScanRequested)
        #expect(!model.isScanningDuplicates)
        #expect(model.hasScannedDuplicates)
    }
}

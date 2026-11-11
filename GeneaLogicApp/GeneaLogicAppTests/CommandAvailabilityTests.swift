import Foundation
import GeneaLogicModel
import SwiftUI
import Testing

@testable import GeneaLogicApp

/// Slice 82 — one rule decides whether a command can run, and every surface asks it.
@Suite struct CommandAvailabilityTests {
    private let artifact = ArtifactID("ART-a")
    private let file = FileID("FIL-a")
    private let person = PersonID("PER-a")
    private let reviewRow = ReviewTarget(id: "row", lane: .name(hasCandidates: true))

    /// A window with an archive open, on `tab`, with everything selected.
    private func context(on tab: ArchiveTab, persons: Int = 2) -> CommandContext {
        CommandContext(
            hasArchive: true, activeTab: tab, selectedArtifact: artifact, selectedFile: file,
            selectedPerson: person, personCount: persons, selectedReview: reviewRow,
            treeFocus: person)
    }

    private func available(in context: CommandContext) -> Set<ArchiveCommand> {
        Set(ArchiveCommand.allCases.filter(context.isAvailable))
    }

    private static let creates: Set<ArchiveCommand> = [
        .addArtifact, .newPerson, .verifyIntegrity, .showTrash,
    ]
    private static let tabs = Set(ArchiveTab.allCases.map(ArchiveCommand.showTab))

    @Test func nothingRunsWithNoArchive() {
        #expect(available(in: CommandContext()).isEmpty)
    }

    @Test(arguments: ArchiveTab.allCases)
    func nothingRunsWhileASheetIsUp(_ tab: ArchiveTab) {
        var context = context(on: tab)
        context.isPresentingModal = true
        #expect(available(in: context).isEmpty)
    }

    @Test func eachTabOffersItsOwnVerbs() {
        let artifactVerbs = ArchiveCommand.allCases.filter {
            $0.subjectKind == .artifact || $0.subjectKind == .file
        }
        let personVerbs = ArchiveCommand.allCases.filter {
            $0.subjectKind == .person && $0.tab == .people
        }
        let treeVerbs: Set<ArchiveCommand> = [
            .showInPeople, .moreAncestors, .fewerAncestors, .moreDescendants, .fewerDescendants,
            .chooseFocus,
        ]
        let reviewVerbs: Set<ArchiveCommand> = [
            .acceptSuggestion, .declineSuggestion, .somebodyNew, .refreshReview,
        ]
        let everywhere = Self.creates.union(Self.tabs)

        #expect(
            available(in: context(on: .artifacts))
                == everywhere.union(artifactVerbs).union([.toggleInspector, .find]))
        #expect(available(in: context(on: .people)) == everywhere.union(personVerbs).union([.find]))
        #expect(available(in: context(on: .tree)) == everywhere.union(treeVerbs))
        #expect(available(in: context(on: .review)) == everywhere.union(reviewVerbs))
    }

    @Test func aVerbWaitsForItsSelection() {
        var context = context(on: .artifacts)
        context.selectedFile = nil
        #expect(!context.isAvailable(.deleteFile))
        #expect(context.isAvailable(.deleteArtifact))

        context.selectedArtifact = nil
        #expect(!context.isAvailable(.deleteArtifact))
        #expect(!context.isAvailable(.toggleInspector))
        #expect(context.isAvailable(.addArtifact))

        var people = self.context(on: .people)
        people.selectedPerson = nil
        #expect(!people.isAvailable(.addName))
        #expect(people.isAvailable(.newPerson))
    }

    @Test func mergeNeedsSomebodyElse() {
        #expect(!context(on: .people, persons: 1).isAvailable(.mergePerson))
        #expect(context(on: .people, persons: 2).isAvailable(.mergePerson))
    }

    /// A context menu acts on the row it was opened on, which needn't be the selection,
    /// and a subject of the wrong kind is never accepted.
    @Test func aContextMenuActsOnItsOwnRow() {
        let context = context(on: .people)
        #expect(context.canPerform(.deletePerson, on: .person(PersonID("PER-other"))))
        #expect(!context.canPerform(.deletePerson, on: .artifact(artifact)))
        #expect(!context.canPerform(.deletePerson, on: .archive))
    }

    // MARK: - Review (slice 83)

    /// The spec's lane table, row by row.
    @Test(arguments: [
        (ReviewLane.name(hasCandidates: true), true, true),
        (.name(hasCandidates: false), false, false),
        (.facts, true, false),
        (.relationship, true, true),
        (.duplicate, false, true),
    ])
    func eachLaneHasItsKeys(_ lane: ReviewLane, accepts: Bool, declines: Bool) {
        var context = context(on: .review)
        context.selectedReview = ReviewTarget(id: "row", lane: lane)
        #expect(context.isAvailable(.acceptSuggestion) == accepts)
        #expect(context.isAvailable(.declineSuggestion) == declines)
        #expect(context.isAvailable(.mergeDuplicate) == (lane == .duplicate))
        #expect(context.isAvailable(.somebodyNew) == lane.isName)
    }

    @Test func aCaptionNamesOnlyTheKeysALaneHas() {
        #expect(
            ArchiveCommand.reviewKeyCaption(for: .name(hasCandidates: true))
                == "⌘↩ Confirm · ⌘⌫ Reject")
        #expect(ArchiveCommand.reviewKeyCaption(for: .facts) == "⌘↩ Record")
        #expect(
            ArchiveCommand.reviewKeyCaption(for: .facts, acceptTitle: "Apply…") == "⌘↩ Apply…")
        #expect(ArchiveCommand.reviewKeyCaption(for: .duplicate) == "⌘⌫ Not a Duplicate")
        #expect(
            ArchiveCommand.reviewKeyCaption(for: .relationship)
                == "⌘↩ Record Relationship · ⌘⌫ Not This Relationship")
    }

    @Test func nothingToDecideWithNoRowSelected() {
        var context = context(on: .review)
        context.selectedReview = nil
        #expect(!context.isAvailable(.acceptSuggestion))
        #expect(context.isAvailable(.refreshReview))
    }

    /// A row's context menu acts on that row, whichever is selected.
    @Test func aReviewRowActsOnItself() {
        var context = context(on: .review)
        context.selectedReview = ReviewTarget(id: "other", lane: .duplicate)
        let row = ReviewTarget(id: "row", lane: .facts)
        #expect(context.canPerform(.acceptSuggestion, on: .review(row)))
        #expect(!context.canPerform(.declineSuggestion, on: .review(row)))
    }

    @Test func aHeldKeyDecidesOnce() {
        #expect(ArchiveCommand.acceptSuggestion.ignoresKeyRepeat)
        #expect(ArchiveCommand.declineSuggestion.ignoresKeyRepeat)
        #expect(!ArchiveCommand.refreshReview.ignoresKeyRepeat)
    }

    // MARK: - Where the selection goes (fork 7)

    private let name1 = ReviewTarget(id: "n1", lane: .name(hasCandidates: true))
    private let name2 = ReviewTarget(id: "n2", lane: .name(hasCandidates: true))
    private let facts = ReviewTarget(id: "f", lane: .facts)
    private let duplicate1 = ReviewTarget(id: "d1", lane: .duplicate)
    private let duplicate2 = ReviewTarget(id: "d2", lane: .duplicate)

    @Test func theRowBelowTakesTheSelection() {
        #expect(
            ReviewTarget.rowAfter("n1", before: [name1, name2, facts], after: [name2, facts])
                == "n2")
    }

    @Test func aRowThatLeftTooIsSkipped() {
        #expect(ReviewTarget.rowAfter("n1", before: [name1, name2, facts], after: [facts]) == "f")
    }

    @Test func theSelectionCrossesLanesButNotIntoDuplicates() {
        #expect(ReviewTarget.rowAfter("n2", before: [name2, facts], after: [facts]) == "f")
        #expect(
            ReviewTarget.rowAfter("f", before: [facts, duplicate1], after: [duplicate1]) == nil)
        #expect(
            ReviewTarget.rowAfter(
                "d1", before: [duplicate1, duplicate2], after: [duplicate2]) == "d2")
    }

    @Test func theEndOfTheListGoesNowhere() {
        #expect(ReviewTarget.rowAfter("n2", before: [name1, name2], after: [name1]) == nil)
    }

    @Test func aRowNotOnTheListGoesNowhere() {
        #expect(ReviewTarget.rowAfter("gone", before: [name1], after: [name1]) == nil)
    }

    /// A selection restored at launch waits for its lane, which may not be computed yet.
    @Test func aSelectionWaitingForItsRowStays() {
        #expect(ReviewTarget.selection("d1", before: [], after: [name1]) == "d1")
        #expect(ReviewTarget.selection("d1", before: [name1], after: [name1, duplicate1]) == "d1")
    }

    @Test func onlyARowThatLeftMovesTheSelection() {
        #expect(
            ReviewTarget.selection("n1", before: [name1, name2], after: [name1, name2]) == "n1")
        #expect(ReviewTarget.selection("n1", before: [name1, name2], after: [name2]) == "n2")
        #expect(ReviewTarget.selection(nil, before: [name1], after: []) == nil)
    }

    /// While a decision is being written its row stays, so the two verbs wait for it.
    @Test func theKeysWaitForADecisionBeingWritten() {
        var context = context(on: .review)
        context.isDecidingReview = true
        #expect(!context.isAvailable(.acceptSuggestion))
        #expect(!context.isAvailable(.declineSuggestion))
        #expect(context.isAvailable(.somebodyNew))
    }

    // MARK: - Tree (slice 83)

    @Test func theDepthItemsGreyAtTheEnds() {
        var context = context(on: .tree)
        context.treeDepths = TreeDepths(ancestors: 0, descendants: 8)
        #expect(!context.isAvailable(.fewerAncestors))
        #expect(context.isAvailable(.moreAncestors))
        #expect(!context.isAvailable(.moreDescendants))
        #expect(context.isAvailable(.fewerDescendants))
    }

    @Test func anEmptyTreeHasNoControls() {
        let context = context(on: .tree, persons: 0)
        #expect(!context.isAvailable(.moreAncestors))
        #expect(!context.isAvailable(.chooseFocus))
    }

    @Test func showInEachOtherDependsOnTheTab() {
        #expect(context(on: .people).isAvailable(.showInTree))
        #expect(!context(on: .people).isAvailable(.showInPeople))
        #expect(context(on: .tree).isAvailable(.showInPeople))
        #expect(!context(on: .tree).isAvailable(.showInTree))
    }

    /// Show in People acts on the focus, which the Tree has with nobody selected.
    @Test func showInPeopleFollowsTheFocus() {
        var context = context(on: .tree)
        context.selectedPerson = nil
        let focus = PersonID("PER-focus")
        context.treeFocus = focus
        #expect(context.selectionSubject(for: .showInPeople) == .person(focus))
    }

    /// A card's verb has no menu-bar subject, and a card's own subject is accepted.
    @Test func focusHereActsOnlyOnACard() {
        let context = context(on: .tree)
        #expect(!context.isAvailable(.focusHere))
        #expect(context.canPerform(.focusHere, on: .person(person)))
    }

    // MARK: - File ▸ Delete (slice 83, fork 1)

    @Test func theDeleteItemFollowsTheTab() {
        #expect(ArchiveCommand.delete(on: .artifacts) == .deleteArtifact)
        #expect(ArchiveCommand.delete(on: .people) == .deletePerson)
        #expect(ArchiveCommand.delete(on: .tree) == nil)
        #expect(ArchiveCommand.delete(on: .review) == nil)
    }

    @Test func theInspectorToggleSaysWhatItWillDo() {
        var context = context(on: .artifacts)
        #expect(ArchiveCommand.toggleInspector.title(in: context) == "Hide Inspector")
        context.inspectorVisible = false
        #expect(ArchiveCommand.toggleInspector.title(in: context) == "Show Inspector")
    }

    // MARK: - Running a command

    @MainActor @Test func aCreateSwitchesToItsTab() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = .review

        model.perform(.addArtifact)

        #expect(model.pendingTab == .artifacts)
        #expect(model.isImporterPresented)
    }

    @MainActor @Test func aViewClaimsOnlyTheCommandsItRuns() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = .people

        model.perform(.deletePerson, on: .person(person))

        #expect(model.claimPendingCommand { $0 == .addName } == nil)
        let claimed = try #require(model.claimPendingCommand { $0 == .deletePerson })
        #expect(claimed.command == .deletePerson)
        #expect(claimed.subject == .person(person))
        #expect(model.pendingCommand == nil)
    }

    @MainActor @Test func showInTreeMovesTheFocusAndTheTab() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = .people

        model.perform(.showInTree, on: .person(person))

        #expect(model.pendingTreeFocus == person)
    }

    @MainActor @Test func aDepthItemIsLeftForTheTree() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        model.activeTab = .tree

        model.perform(.moreAncestors)

        #expect(model.claimPendingCommand { $0 == .moreAncestors } != nil)
    }

    /// Each command's own slice of the context (`commandContext(for:)`, read so a view
    /// observes only what its command depends on) decides as the whole context does.
    @MainActor @Test func aCommandsOwnContextAgreesWithTheWindows() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let modal = UUID()

        for tab in ArchiveTab.allCases {
            for selected in [false, true] {
                for isModal in [false, true] {
                    model.activeTab = tab
                    model.selectedArtifact = selected ? artifact : nil
                    model.selectedFile = selected ? file : nil
                    model.selectedPerson = selected ? person : nil
                    model.inspectorVisible = selected
                    model.treeFocus = selected ? person : nil
                    model.selectedReviewID = selected ? "row" : nil
                    model.marksNextMutationAsReviewDecision = false
                    model.setModal(modal, presented: isModal)
                    let whole = model.commandContext
                    for command in ArchiveCommand.allCases {
                        let own = model.commandContext(for: command)
                        #expect(own.isAvailable(command) == whole.isAvailable(command))
                        #expect(
                            own.selectionSubject(for: command)
                                == whole.selectionSubject(for: command))
                        #expect(command.title(in: own) == command.title(in: whole))
                        #expect(own.ownsShortcut(command) == whole.ownsShortcut(command))
                    }
                }
            }
        }
    }

    @MainActor @Test func aCommandWaitsForAnOpenSheet() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let sheet = UUID()

        model.setModal(sheet, presented: true)
        model.perform(.showTab(.people))
        #expect(model.pendingTab == nil)

        model.setModal(sheet, presented: false)
        model.perform(.showTab(.people))
        #expect(model.pendingTab == .people)
    }
}

/// Slice 82 — the shortcut table: standard keys stay standard, nothing takes a key the
/// system or text editing owns, and no key means two things in one tab.
@Suite struct CommandShortcutTests {
    /// The system's keys, and the text-editing ones a field answers (⌘G find next, ⌘J jump
    /// to selection, ⌘B ⌘U ⌘I styles). ⌘E and ⌘T aren't here: 83's fork 6 took them, whose
    /// actions (use selection for find, fonts) mean nothing with no find panel or styled
    /// text.
    ///
    /// Built in typed parts: as one `+` chain it timed out the type checker on CI.
    private static let reserved: [KeyboardShortcut] = {
        let command: [KeyboardShortcut] = "hmqbjgui,a".map(Self.command)
        let others: [KeyboardShortcut] = [
            KeyboardShortcut("`", modifiers: .command),
            KeyboardShortcut(.space, modifiers: .command),
            KeyboardShortcut("d", modifiers: [.command, .option]),
            KeyboardShortcut("h", modifiers: [.command, .option]),
            KeyboardShortcut("q", modifiers: [.command, .control]),
            KeyboardShortcut("f", modifiers: [.command, .control]),
            KeyboardShortcut("s", modifiers: [.command, .control]),
            KeyboardShortcut("/", modifiers: [.command, .shift]),
            KeyboardShortcut(.escape, modifiers: [.command, .option]),
            KeyboardShortcut("z", modifiers: [.command, .shift]),
        ]
        let screenshots: [KeyboardShortcut] = "345".map {
            KeyboardShortcut(KeyEquivalent($0), modifiers: [.command, .shift])
        }
        // The File and Edit menus' own: New Archive, Open, Close, Undo, the clipboard (and
        // Redo, above). ⌘F isn't here: Find… is a command, and ⌘F is its standard key.
        let menus: [KeyboardShortcut] = "nowzxcv".map(Self.command)
        return command + others + screenshots + menus
    }()

    nonisolated private static func command(_ key: Character) -> KeyboardShortcut {
        KeyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    @Test func noCommandTakesAReservedKey() {
        for command in ArchiveCommand.allCases {
            guard let shortcut = command.shortcut else { continue }
            #expect(!Self.reserved.contains(shortcut), "\(command) takes a reserved key")
        }
    }

    @Test(arguments: ArchiveTab.allCases)
    func noKeyMeansTwoThingsInOneTab(_ tab: ArchiveTab) {
        let context = CommandContext(hasArchive: true, activeTab: tab)
        let shortcuts = ArchiveCommand.allCases
            .filter(context.ownsShortcut)
            .compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    /// The agreed keys (82's forks 1 and 3, G2; 83's forks 2 and 6), and Find's standard
    /// one.
    @Test func theTable() {
        #expect(ArchiveCommand.find.shortcut == KeyboardShortcut("f", modifiers: .command))
        #expect(
            ArchiveCommand.addArtifact.shortcut
                == KeyboardShortcut("i", modifiers: [.command, .shift]))
        #expect(
            ArchiveCommand.newPerson.shortcut
                == KeyboardShortcut("n", modifiers: [.command, .shift]))
        #expect(
            ArchiveTab.allCases.map { ArchiveCommand.showTab($0).shortcut }
                == "1234".map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) })
        #expect(
            ArchiveCommand.deleteArtifact.shortcut == KeyboardShortcut(.delete, modifiers: .command)
        )
        #expect(
            ArchiveCommand.deletePerson.shortcut == KeyboardShortcut(.delete, modifiers: .command))
        #expect(
            ArchiveCommand.acceptSuggestion.shortcut
                == KeyboardShortcut(.return, modifiers: .command))
        #expect(
            ArchiveCommand.declineSuggestion.shortcut
                == KeyboardShortcut(.delete, modifiers: .command))
        #expect(
            ArchiveCommand.refreshReview.shortcut == KeyboardShortcut("r", modifiers: .command))
        for (commands, key) in [
            ([ArchiveCommand.addEvent, .addFact], "e"), ([.addPlace], "l"),
            ([.addMention, .addRelationship], "k"), ([.editTranscript], "t"),
        ] as [([ArchiveCommand], KeyEquivalent)] {
            for command in commands {
                #expect(command.shortcut == KeyboardShortcut(key, modifiers: .command))
            }
        }
    }

    /// ⌘⌫ has one owner on every tab that uses it, and File's Delete gives it up on Review.
    @Test func commandDeleteHasOneOwnerPerTab() {
        let delete = KeyboardShortcut(.delete, modifiers: .command)
        for (tab, owner) in [
            (ArchiveTab.artifacts, ArchiveCommand.deleteArtifact), (.people, .deletePerson),
            (.review, .declineSuggestion),
        ] {
            let context = CommandContext(hasArchive: true, activeTab: tab)
            let owners = ArchiveCommand.allCases.filter {
                context.ownsShortcut($0) && $0.shortcut == delete
            }
            #expect(owners == [owner])
        }
    }

    /// A typed ⌘⌫ goes back to a text field on any tab where the key is a command's.
    @Test func typedDeleteGoesBackToAField() {
        for command in [ArchiveCommand.deleteArtifact, .deletePerson, .declineSuggestion] {
            #expect(command.textEditingAction != nil)
        }
    }
}

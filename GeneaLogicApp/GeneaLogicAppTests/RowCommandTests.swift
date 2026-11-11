import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI
import Testing

@testable import GeneaLogicApp

/// Slice 83b — the verbs on rows inside panes: what each row's state offers, the order its
/// context menu shows them in, and that a row's command acts on that row.
@Suite struct RowCommandTests {
    private let artifact = ArtifactID("ART-a")
    private let person = PersonID("PER-a")
    private let other = PersonID("PER-b")
    private let link = EvidenceLinkID("LNK-a")

    private static let rowCommands = ArchiveCommand.allCases.filter(\.subjectKind.isRow)

    private func mention(
        _ link: MentionTarget.Link, namesOthers: Bool = true
    ) -> CommandSubject {
        .mention(
            MentionTarget(
                artifact: artifact, localRef: "p1", index: 0, link: link,
                namesOthers: namesOthers))
    }

    private func suggestedFact(recordable: Bool) -> CommandSubject {
        .factSuggestion(
            FactSuggestionTarget(person: person, id: "s", isDirectlyRecordable: recordable))
    }

    private func source(exists: Bool = true, newName: String? = "Chana") -> CommandSubject {
        .source(
            SourceTarget(
                person: person, link: link, artifact: artifact, artifactExists: exists,
                newName: newName))
    }

    private func relationship(dangling: Bool) -> CommandSubject {
        .relationship(
            RelationshipTarget(
                person: person, relationship: RelationshipID("REL-a"), other: other,
                otherExists: !dangling, roleDescription: "parent"))
    }

    private func context(on tab: ArchiveTab = .artifacts) -> CommandContext {
        CommandContext(hasArchive: true, activeTab: tab)
    }

    /// A pane's rows have no selection, so none of their verbs is a menu-bar item, and
    /// none takes a key.
    @Test(arguments: ArchiveTab.allCases)
    func noRowCommandIsOnTheMenuBar(_ tab: ArchiveTab) {
        let context = CommandContext(
            hasArchive: true, activeTab: tab, selectedArtifact: artifact,
            selectedFile: FileID("FIL-a"), selectedPerson: person, personCount: 2,
            selectedReview: ReviewTarget(id: "row", lane: .name(hasCandidates: true)),
            treeFocus: person)
        for command in Self.rowCommands {
            #expect(!context.isAvailable(command), "\(command) is on the menu bar")
            #expect(context.selectionSubject(for: command) == nil)
            #expect(command.shortcut == nil)
            #expect(command.tab == nil)
        }
    }

    /// A row's verb works on whichever tab draws the row: a suggested fact is on a person
    /// and in Review.
    @Test(arguments: ArchiveTab.allCases)
    func aRowCommandWorksFromAnyTab(_ tab: ArchiveTab) {
        #expect(
            context(on: tab).canPerform(.recordSuggestedFact, on: suggestedFact(recordable: true)))
    }

    @Test func aRowCommandRefusesAnotherRowsSubject() {
        #expect(!context().canPerform(.unlinkMention, on: source()))
        #expect(!context().canPerform(.unlinkSource, on: mention(.linked(link, to: person))))
        #expect(!context().canPerform(.applyMetadata, on: .artifact(artifact)))
    }

    @Test func nothingRunsWithNoArchive() {
        #expect(!CommandContext().canPerform(.resolveMention, on: mention(.none)))
    }

    /// Resolve… without a live link, the jump only with one, and Unlink with any.
    @Test(arguments: [
        (MentionTarget.Link.none, true, false, false),
        (.linked(EvidenceLinkID("LNK-a"), to: PersonID("PER-a")), false, true, true),
        (.stale(EvidenceLinkID("LNK-a")), true, false, true),
    ])
    func aMentionOffersWhatItsLinkAllows(
        _ link: MentionTarget.Link, resolves: Bool, shows: Bool, unlinks: Bool
    ) {
        let subject = mention(link)
        #expect(context().canPerform(.resolveMention, on: subject) == resolves)
        #expect(context().canPerform(.showMentionedPerson, on: subject) == shows)
        #expect(context().canPerform(.unlinkMention, on: subject) == unlinks)
        #expect(context().canPerform(.editMention, on: subject))
        #expect(context().canPerform(.removeMention, on: subject))
    }

    /// A stale link is re-resolved, and the resolve replaces it.
    @Test func aStaleLinkIsReResolved() {
        #expect(ArchiveCommand.resolveMention.title(on: mention(.none)) == "Resolve…")
        #expect(ArchiveCommand.resolveMention.title(on: mention(.stale(link))) == "Re-resolve…")
        #expect(
            ArchiveCommand.resolveMention.paneTitle(on: mention(.stale(link))) == "Re-resolve…")
    }

    @Test func addRelationshipNeedsSomebodyElse() {
        #expect(
            !context().canPerform(.addMentionRelationship, on: mention(.none, namesOthers: false)))
        #expect(context().canPerform(.addMentionRelationship, on: mention(.none)))
    }

    /// A couple fact or an age needs the sheet, so it has no Record, and Edit… becomes
    /// Apply….
    @Test func aSuggestionThatCantBeRecordedAsIsCanOnlyBeApplied() {
        let recordable = suggestedFact(recordable: true)
        #expect(context().canPerform(.recordSuggestedFact, on: recordable))
        #expect(ArchiveCommand.editSuggestedFact.title(on: recordable) == "Edit…")

        let applyOnly = suggestedFact(recordable: false)
        #expect(!context().canPerform(.recordSuggestedFact, on: applyOnly))
        #expect(context().canPerform(.editSuggestedFact, on: applyOnly))
        #expect(ArchiveCommand.editSuggestedFact.title(on: applyOnly) == "Apply…")
        #expect(
            ArchiveCommand.editSuggestedFact.systemImage(on: applyOnly)
                == ArchiveCommand.applyMetadata.systemImage)
    }

    @Test func aSourceOffersWhatItHas() {
        #expect(context().canPerform(.addSourceName, on: source()))
        #expect(!context().canPerform(.addSourceName, on: source(newName: nil)))
        #expect(!context().canPerform(.showSource, on: source(exists: false)))
        #expect(context().canPerform(.unlinkSource, on: source(exists: false)))
    }

    /// A dangling relationship is repaired rather than visited.
    @Test func aDanglingRelationshipIsRepaired() {
        #expect(context().canPerform(.replaceRelative, on: relationship(dangling: true)))
        #expect(!context().canPerform(.showRelative, on: relationship(dangling: true)))
        #expect(!context().canPerform(.replaceRelative, on: relationship(dangling: false)))
        #expect(context().canPerform(.showRelative, on: relationship(dangling: false)))
    }

    /// A candidate's verdict is a Review decision, so it waits for one being written.
    @Test func aCandidateWaitsForADecisionBeingWritten() {
        let card = CommandSubject.candidate(
            CandidateTarget(
                row: ReviewTarget(id: "row", lane: .name(hasCandidates: true)), person: person))
        var context = context(on: .review)
        #expect(context.canPerform(.confirmCandidate, on: card))
        context.isDecidingReview = true
        #expect(!context.canPerform(.confirmCandidate, on: card))
        #expect(!context.canPerform(.rejectCandidate, on: card))
    }

    /// The menu uses the full title; a pane keeps its short one under a heading that
    /// already says what it is.
    @Test func thePaneKeepsItsShortTitles() {
        for (command, menu, pane) in [
            (ArchiveCommand.recordSuggestedRelationship, "Record Relationship", "Record"),
            (.dismissSuggestedRelationship, "Not This Relationship", "Not This"),
            (.recordSuggestedFact, "Record Fact", "Record"),
            (.unlinkMention, "Unlink", "Unlink"),
        ] {
            #expect(command.title == menu)
            #expect(command.paneTitle == pane)
        }
    }

    @Test func onlyRemovesAreDestructive() {
        let destructive = Set(Self.rowCommands.filter(\.isDestructive))
        #expect(destructive == [.removeMention, .removeRelationship])
    }

    /// Every row command is on its row's menu, and on no other row's.
    @Test func eachRowCommandIsOnItsOwnRowsMenu() {
        let subjects: [CommandSubject] = [
            mention(.none),
            .metadataEntry(
                EmbeddedMetadataKey(namespace: "exif", name: "DateTimeOriginal"), in: artifact),
            suggestedFact(recordable: true),
            .relationshipSuggestion(RelationshipSuggestionTarget(id: "r", owner: .person(person))),
            source(), relationship(dangling: false),
            .candidate(CandidateTarget(row: ReviewTarget(id: "row", lane: .facts), person: person)),
        ]
        var seen: [ArchiveCommand] = []
        for subject in subjects {
            for command in subject.rowMenu.joined() {
                #expect(command.subjectKind == subject.kind)
                seen.append(command)
            }
        }
        #expect(seen.sorted { "\($0)" < "\($1)" } == Self.rowCommands.sorted { "\($0)" < "\($1)" })
    }

    // MARK: - Against a window

    /// The menu as a row shows it: in order, what the state lacks left out, and an empty
    /// group dropped with its divider.
    @MainActor @Test func aRowsMenuHidesWhatItsStateLacks() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        #expect(
            model.rowMenu(for: mention(.none))
                == [
                    [.resolveMention, .editMention, .addMentionFact, .addMentionRelationship],
                    [.removeMention],
                ])
        #expect(
            model.rowMenu(for: mention(.linked(link, to: person), namesOthers: false))
                == [
                    [.showMentionedPerson, .editMention, .addMentionFact],
                    [.unlinkMention, .removeMention],
                ])
        #expect(
            model.rowMenu(for: relationship(dangling: true))
                == [[.replaceRelative], [.removeRelationship]])
        #expect(model.rowMenu(for: suggestedFact(recordable: false)) == [[.editSuggestedFact]])
    }

    /// The menu is drawn on a right-click, which a sheet over the window can't take, so it
    /// isn't emptied by one.
    @MainActor @Test func aRowsMenuIsOfferedUnderASheet() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.setModal(UUID(), presented: true)
        #expect(model.rowMenu(for: source()) == [[.showSource, .addSourceName], [.unlinkSource]])
        #expect(!model.canPerform(.unlinkSource, on: source()))
    }

    /// A row command that opens a sheet is left for the pane that drew the row.
    @MainActor @Test func aRowsSheetIsLeftForItsPane() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let subject = mention(.stale(link))

        model.perform(.resolveMention, on: subject)

        #expect(model.claimPendingCommand(where: { _, other in other == source() }) == nil)
        let claimed = try #require(
            model.claimPendingCommand(where: { command, _ in command == .resolveMention }))
        #expect(claimed.subject == subject)
        #expect(model.pendingCommand == nil)
    }

    /// A jump runs in the model, with nothing left pending.
    @MainActor @Test func aJumpRunsInTheModel() throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        model.perform(.showRelative, on: relationship(dangling: false))

        #expect(model.pendingCommand == nil)
        #expect(model.pendingPersonNavigation == other)
    }
}

/// Slice 83b — the row commands that write, against a real archive.
@MainActor
@Suite struct RowCommandWriteTests {
    /// A record naming one person, with one recorded fact, and two look-alikes for them.
    private func makeArchive() async throws -> (model: ArchiveModel, root: URL, row: ReviewItem) {
        let (model, root) = try AppTestSupport.makeModel()
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        await model.act { model.createPerson(given: "Anne", surname: "Roe") }
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject,
            informationQuality: .primary,
            facts: [RecordedFact(type: .occupation, value: "tailor")])
        _ = try #require(model.archive).addArtifact(
            ArtifactDraft(title: "Census", mediaType: .image, personsMentioned: [mention]))
        model.activeTab = .review
        model.refreshReviewWorklist()
        return (model, root, try #require(model.reviewItems.first))
    }

    private func card(_ candidate: ReviewCandidate, on row: ReviewItem) -> CommandSubject {
        .candidate(CandidateTarget(row: row.target, person: candidate.suggestion.personID))
    }

    /// A card's Confirm acts on its own candidate, not the top one the keys would take.
    @Test func aCardConfirmsItsOwnCandidate() async throws {
        let (model, root, row) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        let second = try #require(row.candidates.last)
        #expect(second.id != row.candidates.first?.id)

        await model.act { model.perform(.confirmCandidate, on: card(second, on: row)) }

        #expect(model.reviewItems.isEmpty)
        let links = try #require(model.archive).links()
        #expect(links.map(\.personUid) == [second.suggestion.personID])
    }

    @Test func aCardRejectsItsOwnCandidate() async throws {
        let (model, root, row) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        let top = try #require(row.candidates.first)
        let second = try #require(row.candidates.last)

        await model.act { model.perform(.rejectCandidate, on: card(second, on: row)) }

        let after = try #require(model.reviewItems.first)
        #expect(after.candidates.map(\.id) == [top.id])
    }

    /// Record Fact finds the suggestion the row showed and records it as-recorded.
    @Test func recordFactRecordsTheRowsSuggestion() async throws {
        let (model, root, row) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        let top = try #require(row.candidates.first)
        await model.act { model.confirmSuggestion(top.suggestion) }
        let personID = top.suggestion.personID
        let suggestion = try #require(
            model.linkedEvidence(for: personID, recordedFacts: []).suggestions.first)

        await model.act {
            model.perform(
                .recordSuggestedFact,
                on: .factSuggestion(
                    FactSuggestionTarget(
                        person: personID, id: suggestion.id,
                        isDirectlyRecordable: suggestion.isDirectlyRecordable)))
        }

        let facts = try #require(model.fullPerson(personID)).facts
        #expect(facts.map(\.value) == ["tailor"])
    }

    /// Remove Mention takes the mention out, and ⌘Z puts it back.
    @Test func removeMentionIsUndoable() async throws {
        let (model, root, row) = try await makeArchive()
        defer { AppTestSupport.remove(root) }
        let artifactID = row.mention.artifact
        let subject = CommandSubject.mention(
            MentionTarget(
                artifact: artifactID, localRef: "p1", index: 0, link: .none, namesOthers: false))

        await model.act { model.perform(.removeMention, on: subject) }
        #expect(model.fullArtifact(artifactID)?.personsMentioned.isEmpty == true)

        await model.undoAndSettle()
        #expect(model.fullArtifact(artifactID)?.personsMentioned.map(\.localRef) == ["p1"])
    }
}

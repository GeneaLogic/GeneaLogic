import AppKit
import GeneaLogicModel
import SwiftUI

/// Every command an archive window offers, spelled once (slice 82, G1). The menu bar,
/// context menus and in-pane buttons all draw their title, symbol and shortcut from
/// here, and ask `CommandContext` whether it can run, so the surfaces can't disagree.
///
/// A command names its verb; what it acts on is its `CommandSubject`. The menu bar takes
/// the subject from the window's selection, and a context menu from the row it was opened
/// on.
enum ArchiveCommand: Hashable, CaseIterable {
    // File
    case addArtifact, newPerson, verifyIntegrity, showTrash
    // Edit
    case find
    // View. One case per tab rather than `showTab(ArchiveTab)`, so `allCases` is the
    // compiler's and a new command can't be missed by the tests that sweep it.
    case showArtifacts, showPeople, showTree, showReview, toggleInspector
    // Artifact
    case addEvent, addPlace, addMention, editTranscript, attachFile, deleteArtifact
    // Artifact ▸ Selected File
    case openFileInWindow, openFileInDefaultApp, saveFileCopy, scanFileForMetadata
    case replaceFile, deleteFile
    // Person
    case addName, addFact, addRelationship, showInTree, showInPeople, mergePerson, deletePerson
    // Review (slice 83)
    case acceptSuggestion, declineSuggestion, mergeDuplicate, somebodyNew, refreshReview
    // Tree (slice 83). The four depth items and Choose Focus… are View's; Focus Here is a
    // card's, with no menu-bar subject.
    case focusHere, moreAncestors, fewerAncestors, moreDescendants, fewerDescendants
    case chooseFocus
    // Rows inside panes (slice 83b). No menu-bar item: a pane's rows have no selection
    // for one to act on. Their buttons and context menus draw from here.
    // A mention, in the inspector
    case resolveMention, showMentionedPerson, editMention, addMentionFact
    case addMentionRelationship, unlinkMention, removeMention
    // An embedded-metadata entry
    case applyMetadata
    // A suggested fact, on a person and in Review's facts lane
    case recordSuggestedFact, editSuggestedFact
    // A suggested relationship, in the inspector and on a person
    case recordSuggestedRelationship, dismissSuggestedRelationship
    // A person's source, and a person's relationship
    case showSource, addSourceName, unlinkSource
    case showRelative, replaceRelative, removeRelationship
    // A candidate in Review's names lane
    case confirmCandidate, rejectCandidate

    /// The command that shows `tab` (View ▸ ⌘1–⌘4).
    nonisolated static func showTab(_ tab: ArchiveTab) -> ArchiveCommand {
        switch tab {
        case .artifacts: .showArtifacts
        case .people: .showPeople
        case .tree: .showTree
        case .review: .showReview
        }
    }

    /// The one File ▸ Delete item's command on `tab`, or `nil` on a tab with nothing to
    /// delete (slice 83, fork 1).
    nonisolated static func delete(on tab: ArchiveTab) -> ArchiveCommand? {
        switch tab {
        case .artifacts: .deleteArtifact
        case .people: .deletePerson
        case .tree, .review: nil
        }
    }

    /// File ▸ Delete's title on a tab with nothing to delete, dimmed.
    static let idleDeleteTitle = "Delete…"

    /// The tab this command shows, if it is one of View's tab commands.
    var shownTab: ArchiveTab? {
        switch self {
        case .showArtifacts: .artifacts
        case .showPeople: .people
        case .showTree: .tree
        case .showReview: .review
        default: nil
        }
    }

    /// What a command acts on.
    enum SubjectKind: Hashable {
        case archive, artifact, file, person, review
        /// A row inside a pane, which the menu bar can't name (slice 83b).
        case row(RowKind)

        var isRow: Bool {
            if case .row = self { true } else { false }
        }
    }

    /// Which of a pane's rows a command acts on.
    enum RowKind: Hashable {
        case mention, metadataEntry, factSuggestion, relationshipSuggestion, source
        case relationship, candidate
    }

    var subjectKind: SubjectKind {
        switch self {
        case .addArtifact, .newPerson, .verifyIntegrity, .showTrash, .find, .showArtifacts,
            .showPeople, .showTree, .showReview, .toggleInspector, .refreshReview, .moreAncestors,
            .fewerAncestors, .moreDescendants, .fewerDescendants, .chooseFocus:
            .archive
        case .addEvent, .addPlace, .addMention, .editTranscript, .attachFile, .deleteArtifact:
            .artifact
        case .openFileInWindow, .openFileInDefaultApp, .saveFileCopy, .scanFileForMetadata,
            .replaceFile, .deleteFile:
            .file
        case .addName, .addFact, .addRelationship, .showInTree, .showInPeople, .mergePerson,
            .deletePerson, .focusHere:
            .person
        case .acceptSuggestion, .declineSuggestion, .mergeDuplicate, .somebodyNew:
            .review
        case .resolveMention, .showMentionedPerson, .editMention, .addMentionFact,
            .addMentionRelationship, .unlinkMention, .removeMention:
            .row(.mention)
        case .applyMetadata: .row(.metadataEntry)
        case .recordSuggestedFact, .editSuggestedFact: .row(.factSuggestion)
        case .recordSuggestedRelationship, .dismissSuggestedRelationship:
            .row(.relationshipSuggestion)
        case .showSource, .addSourceName, .unlinkSource: .row(.source)
        case .showRelative, .replaceRelative, .removeRelationship: .row(.relationship)
        case .confirmCandidate, .rejectCandidate: .row(.candidate)
        }
    }

    /// The tab a command belongs to, or `nil` for one that works from any tab. A create
    /// belongs to no tab: it switches to its own first (fork 2), so the result is in view.
    ///
    /// Nor does a row's command (slice 83b): it is drawn only on its row, which is on
    /// screen, and owns no key, so the check (which exists for the menu bar) adds nothing.
    /// A suggested fact's then serve the person pane and Review's lane alike.
    var tab: ArchiveTab? {
        switch self {
        case .toggleInspector: .artifacts
        case .refreshReview: .review
        case .focusHere, .showInPeople, .moreAncestors, .fewerAncestors, .moreDescendants,
            .fewerDescendants, .chooseFocus:
            .tree
        default:
            switch subjectKind {
            case .archive: nil
            case .artifact, .file: .artifacts
            case .person: .people
            case .review: .review
            case .row: nil
            }
        }
    }

    /// The menu-bar title. `toggleInspector`'s depends on the window, so it is asked of
    /// `title(in:)`.
    var title: String {
        switch self {
        case .addArtifact: "Add Artifact…"
        case .newPerson: "New Person…"
        case .verifyIntegrity: "Verify Integrity…"
        case .showTrash: "Show Trash…"
        case .find: "Find…"
        case .showArtifacts, .showPeople, .showTree, .showReview: shownTab?.label ?? ""
        case .toggleInspector: "Hide Inspector"
        case .addEvent: "Add Event…"
        case .addPlace: "Add Place…"
        // "Add Person…" alone read as New Person.
        case .addMention: "Add Person Mentioned…"
        case .editTranscript: "Edit Transcript…"
        case .attachFile: "Attach File…"
        case .deleteArtifact: "Delete Artifact…"
        case .openFileInWindow: "Open in Separate Window"
        case .openFileInDefaultApp: "Open in Default App"
        case .saveFileCopy: "Save a Copy…"
        case .scanFileForMetadata: "Scan for Metadata"
        case .replaceFile: "Replace…"
        case .deleteFile: "Delete File…"
        case .addName: "Add Name…"
        case .addFact: "Add Fact…"
        case .addRelationship: "Add Relationship…"
        case .mergePerson: "Merge Into…"
        case .showInTree: "Show in Tree"
        case .showInPeople: "Show in People"
        case .deletePerson: "Delete Person…"
        // The titles while there is nothing to decide. With a row that has the verb, the
        // menu bar says what the key will do (`title(in:)`), and the panes and context
        // menus say their lane's words.
        case .acceptSuggestion: "Accept Suggestion"
        case .declineSuggestion: "Decline Suggestion"
        case .mergeDuplicate: "Merge People…"
        case .somebodyNew: "This Is Somebody New…"
        case .refreshReview: "Refresh"
        case .focusHere: "Focus Here"
        case .moreAncestors: "Show More Ancestors"
        case .fewerAncestors: "Show Fewer Ancestors"
        case .moreDescendants: "Show More Descendants"
        case .fewerDescendants: "Show Fewer Descendants"
        case .chooseFocus: "Choose Focus…"
        case .resolveMention: "Resolve…"
        case .showMentionedPerson, .showRelative: "Show in People"
        case .editMention: "Edit Mention…"
        case .addMentionFact: "Add Fact…"
        case .addMentionRelationship: "Add Relationship…"
        case .unlinkMention, .unlinkSource: "Unlink"
        case .removeMention: "Remove Mention"
        case .applyMetadata: "Apply…"
        case .recordSuggestedFact: "Record Fact"
        case .editSuggestedFact: "Edit…"
        case .recordSuggestedRelationship: "Record Relationship"
        case .dismissSuggestedRelationship: "Not This Relationship"
        case .showSource: "Show in Artifacts"
        case .addSourceName: "Add as Name…"
        case .replaceRelative: "Replace Person…"
        case .removeRelationship: "Remove Relationship"
        case .confirmCandidate: "Confirm"
        case .rejectCandidate: "Reject"
        }
    }

    func title(in context: CommandContext) -> String {
        switch self {
        case .toggleInspector:
            return context.inspectorVisible ? "Hide Inspector" : "Show Inspector"
        // The two keys write a verdict on a row the sidebar doesn't spell out, so the menu
        // names it before the key is pressed: Confirm Ann Roe ⌘↩, Not a Duplicate ⌘⌫
        // (slice 83b). The HIG keeps the menu's *set* of items stable and asks a title to
        // clarify its target, as Undo Typing does. A lane without the verb leaves the item
        // dimmed under its generic title. A write in flight doesn't change the title, so
        // it doesn't flicker on every decision.
        case .acceptSuggestion, .declineSuggestion:
            guard let target = context.selectedReview,
                self == .acceptSuggestion ? target.lane.canAccept : target.lane.canDecline
            else { return title }
            return Self.reviewRowTitle(of: self, on: target)
        default:
            return title
        }
    }

    /// The title on `subject`, where the row's state changes the verb.
    func title(on subject: CommandSubject) -> String {
        titleOverride(on: subject) ?? title
    }

    /// The verb a row's state puts in place of the usual one, on every surface but the
    /// menu bar: a stale link is re-resolved, and a suggestion that can't be recorded
    /// as-is can only be applied. A Review row says its lane's verb, where the menu bar
    /// keeps the stable "Accept Suggestion" (slice 83b), and a name row says whose.
    /// `nil` where the state changes nothing.
    private func titleOverride(on subject: CommandSubject) -> String? {
        switch (self, subject) {
        case (.acceptSuggestion, .review(let target)), (.declineSuggestion, .review(let target)):
            Self.reviewRowTitle(of: self, on: target)
        case (.resolveMention, .mention(let target)) where target.link.isStale:
            "Re-resolve…"
        case (.editSuggestedFact, .factSuggestion(let target)) where !target.isDirectlyRecordable:
            Self.applyTitle
        default: nil
        }
    }

    /// The title an in-pane button uses under a section heading that already says what
    /// it is about. "Add Person…" under *Persons Mentioned* is unambiguous, and the longer
    /// menu title doesn't fit the inspector at its narrowest; the suggestion rows' short
    /// verbs sit under *Suggested Facts* and *Suggested Relationships*.
    var paneTitle: String {
        switch self {
        case .addMention: "Add Person…"
        case .recordSuggestedFact, .recordSuggestedRelationship: "Record"
        case .dismissSuggestedRelationship: "Not This"
        default: title
        }
    }

    /// `paneTitle`, on `subject`: the state's verb wins, as in `title(on:)`.
    func paneTitle(on subject: CommandSubject) -> String {
        titleOverride(on: subject) ?? paneTitle
    }

    /// The in-pane title while there is nothing yet to act on: the transcript's button
    /// adds one until there is one to edit.
    var emptyPaneTitle: String {
        self == .editTranscript ? "Add Transcript…" : paneTitle
    }

    /// What a Review pane calls this command in `lane`.
    func paneTitle(in lane: ReviewLane) -> String {
        switch (self, lane) {
        case (.acceptSuggestion, .name): "Confirm"
        case (.acceptSuggestion, .facts): "Record"
        case (.acceptSuggestion, .relationship): "Record Relationship"
        case (.declineSuggestion, .name): "Reject"
        case (.declineSuggestion, .relationship): "Not This Relationship"
        case (.declineSuggestion, .duplicate): "Not a Duplicate"
        default: title
        }
    }

    /// What a suggestion that can only be applied offers: its editor, the one way to record
    /// a couple fact or an age. Said once for the row, its menu and Review's caption.
    static let applyTitle = "Apply…"

    /// What a Review row's context menu calls `command`: its lane's word, the editor's on
    /// a facts row whose top suggestion can only be applied, and on a name row the
    /// candidate it would decide.
    private static func reviewRowTitle(
        of command: ArchiveCommand, on target: ReviewTarget
    ) -> String {
        if command == .acceptSuggestion, target.topOpensEditor { return applyTitle }
        let word = command.paneTitle(in: target.lane)
        if target.lane.isName, let name = target.topCandidate {
            return "\(word) \(name)"
        }
        return word
    }

    /// The caption on the row Review's keys act on, naming only the keys `lane` has
    /// (slice 83, fork 3). This, not a prominent button, is what says where ⌘↩ lands:
    /// prominence would say the matcher's top guess is the likely answer.
    ///
    /// `acceptTitle` replaces the lane's word when the top row does something else: a
    /// suggestion that can only be applied opens its editor.
    static func reviewKeyCaption(for lane: ReviewLane, acceptTitle: String? = nil) -> String {
        var parts: [String] = []
        if lane.canAccept, let key = acceptSuggestion.shortcutGlyphs {
            parts.append("\(key) \(acceptTitle ?? acceptSuggestion.paneTitle(in: lane))")
        }
        if lane.canDecline, let key = declineSuggestion.shortcutGlyphs {
            parts.append("\(key) \(declineSuggestion.paneTitle(in: lane))")
        }
        return parts.joined(separator: " · ")
    }

    /// The shortcut as a menu shows it, for the two keys a caption names.
    private var shortcutGlyphs: String? {
        switch shortcut?.key {
        case KeyEquivalent.return: "⌘↩"
        case KeyEquivalent.delete: "⌘⌫"
        default: nil
        }
    }

    var systemImage: String {
        switch self {
        case .addArtifact, .newPerson: "plus"
        case .verifyIntegrity: "checkmark.shield"
        case .showTrash: "trash"
        case .find: "magnifyingglass"
        case .showArtifacts, .showPeople, .showTree, .showReview: "square.grid.2x2"
        case .toggleInspector: "info.circle"
        case .addEvent: "calendar"
        case .addPlace: "mappin.and.ellipse"
        case .addMention: "person.badge.plus"
        case .editTranscript: "text.quote"
        case .attachFile: "paperclip"
        case .deleteArtifact, .deleteFile, .deletePerson: "trash"
        case .openFileInWindow: "macwindow.on.rectangle"
        case .openFileInDefaultApp: "arrow.up.forward.app"
        case .saveFileCopy: "square.and.arrow.down"
        case .scanFileForMetadata: "doc.text.magnifyingglass"
        case .replaceFile: "arrow.triangle.2.circlepath"
        case .addName: "person.badge.plus"
        case .addFact: "calendar.badge.plus"
        case .addRelationship: "person.2.badge.plus"
        case .mergePerson, .mergeDuplicate: "arrow.triangle.merge"
        case .showInTree, .focusHere, .chooseFocus: "target"
        case .showInPeople: "person.2"
        case .acceptSuggestion: "checkmark"
        case .declineSuggestion: "xmark"
        case .somebodyNew: "person.fill.badge.plus"
        case .refreshReview: "arrow.clockwise"
        case .moreAncestors, .moreDescendants: "plus"
        case .fewerAncestors, .fewerDescendants: "minus"
        case .resolveMention: "link"
        case .showMentionedPerson, .showRelative: "person.2"
        case .editMention: "square.and.pencil"
        case .addMentionFact: "calendar.badge.plus"
        case .addMentionRelationship: "person.2.badge.plus"
        case .unlinkMention, .unlinkSource: "xmark.circle"
        case .removeMention, .removeRelationship: "trash"
        case .applyMetadata: "arrow.down.doc"
        case .recordSuggestedFact, .recordSuggestedRelationship: "checkmark.circle"
        case .editSuggestedFact: "square.and.pencil"
        case .dismissSuggestedRelationship, .rejectCandidate: "xmark"
        case .showSource: "doc.text"
        case .addSourceName: "person.text.rectangle"
        case .replaceRelative: "arrow.triangle.2.circlepath"
        case .confirmCandidate: "checkmark"
        }
    }

    /// The symbol on `subject`: a suggestion that can only be applied takes Apply…'s.
    func systemImage(on subject: CommandSubject) -> String {
        if self == .editSuggestedFact, case .factSuggestion(let target) = subject,
            !target.isDirectlyRecordable
        {
            return ArchiveCommand.applyMetadata.systemImage
        }
        return systemImage
    }

    var isDestructive: Bool {
        switch self {
        case .deleteArtifact, .deleteFile, .deletePerson, .removeMention, .removeRelationship:
            true
        default: false
        }
    }

    /// The tooltip a row's button shows, said once for every surface that draws it.
    func help(on subject: CommandSubject) -> String? {
        switch self {
        case .resolveMention:
            if case .mention(let target) = subject, target.link.isStale {
                "Point this citation at a person that still exists"
            } else {
                "Link this mention to a concluded person"
            }
        case .showMentionedPerson, .showRelative: "Show this person on the People tab"
        case .unlinkMention:
            if case .mention(let target) = subject, target.link.isStale {
                "Drop the stale link, leaving the mention unresolved (⌘Z to undo)"
            } else {
                "Remove the link to this person (⌘Z to undo)"
            }
        case .addMentionFact: "Record what this document states about this person"
        case .addMentionRelationship:
            "State how this document relates this person to another it names"
        case .removeMention: "Remove this mention (⌘Z to undo)"
        case .applyMetadata: "Review this value, then record it as an event or place"
        case .recordSuggestedFact: "Record this fact as-recorded (⌘Z to undo)"
        case .editSuggestedFact: "Correct this evidence before recording it"
        case .recordSuggestedRelationship:
            "Add this relationship to your conclusions (⌘Z to undo)"
        case .dismissSuggestedRelationship: "Stop offering this relationship, here and in Review"
        case .showSource: "Show this artifact on the Artifacts tab"
        case .addSourceName: "Add this recorded name to the person"
        case .unlinkSource: "Remove the link to this artifact (⌘Z to undo)"
        case .replaceRelative: "Point this relationship at a person that still exists"
        case .removeRelationship: "Remove this relationship (⌘Z to undo)"
        default: nil
        }
    }

    /// The shortcut table in `docs/slices/82-one-source-for-commands.md`, as changed by
    /// `83-command-coverage.md`.
    /// `CommandShortcutTests` pins that none is reserved and none is shared within a tab.
    var shortcut: KeyboardShortcut? {
        switch self {
        // ⇧⌘I is Photos' Import; ⌘I is left free (fork 1).
        case .addArtifact: KeyboardShortcut("i", modifiers: [.command, .shift])
        // Shift complements ⌘N New Archive, as the HIG suggests.
        case .newPerson: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .find: KeyboardShortcut("f", modifiers: [.command])
        case .showArtifacts, .showPeople, .showTree, .showReview:
            shownTab.map { KeyboardShortcut($0.shortcutKey, modifiers: [.command]) }
        // Finder, Calendar and Pages put the inspector on ⌥⌘I.
        case .toggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        // Finder's Move to Trash, and both deletes go to the archive's trash or undo.
        case .deleteArtifact, .deletePerson: KeyboardShortcut(.delete, modifiers: [.command])
        // One key per role, shared across tabs as ⌘⌫ is (slice 83, fork 6). ⌘E and ⌘T are
        // text-editing keys elsewhere, whose actions mean nothing here: there is no find
        // panel and no styled text.
        case .addEvent, .addFact: KeyboardShortcut("e", modifiers: [.command])
        case .addPlace: KeyboardShortcut("l", modifiers: [.command])
        case .addMention, .addRelationship: KeyboardShortcut("k", modifiers: [.command])
        case .editTranscript: KeyboardShortcut("t", modifiers: [.command])
        // Triage is one hand on two keys. They sit on the menu items, not the panes'
        // buttons: SwiftUI keeps one owner per key, and the menu is what shows it.
        case .acceptSuggestion: KeyboardShortcut(.return, modifiers: [.command])
        case .declineSuggestion: KeyboardShortcut(.delete, modifiers: [.command])
        case .refreshReview: KeyboardShortcut("r", modifiers: [.command])
        default: nil
        }
    }

    /// Whether a held key runs this command once. Every other key undoes or opens
    /// something; these two write a human verdict and move to the next row, so a repeat
    /// would confirm a queue nobody read.
    var ignoresKeyRepeat: Bool {
        self == .acceptSuggestion || self == .declineSuggestion
    }

    /// The text-editing action a command's shortcut also means, sent instead when that
    /// shortcut is typed in a text field. A menu's key equivalent is matched before the
    /// field sees the key, so without this ⌘⌫ in the inspector's Title field would offer
    /// to delete the artifact rather than the line.
    var textEditingAction: Selector? {
        switch self {
        case .deleteArtifact, .deletePerson, .declineSuggestion:
            #selector(NSResponder.deleteToBeginningOfLine(_:))
        default: nil
        }
    }
}

/// What a command acts on: the archive as a whole, an artifact, one of its files, a
/// person, or a row of Review's worklist. (Not `.none`, which an optional subject would read as `nil`.)
enum CommandSubject: Hashable {
    case archive
    case artifact(ArtifactID)
    case file(FileID, in: ArtifactID)
    case person(PersonID)
    case review(ReviewTarget)
    // A pane's rows (slice 83b): each carries the ids its command needs and the state its
    // availability reads, so the rule stays a pure function. See `RowCommands.swift`.
    case mention(MentionTarget)
    case metadataEntry(EmbeddedMetadataKey, in: ArtifactID)
    case factSuggestion(FactSuggestionTarget)
    case relationshipSuggestion(RelationshipSuggestionTarget)
    case source(SourceTarget)
    case relationship(RelationshipTarget)
    case candidate(CandidateTarget)

    var kind: ArchiveCommand.SubjectKind {
        switch self {
        case .archive: .archive
        case .artifact: .artifact
        case .file: .file
        case .person: .person
        case .review: .review
        case .mention: .row(.mention)
        case .metadataEntry: .row(.metadataEntry)
        case .factSuggestion: .row(.factSuggestion)
        case .relationshipSuggestion: .row(.relationshipSuggestion)
        case .source: .row(.source)
        case .relationship: .row(.relationship)
        case .candidate: .row(.candidate)
        }
    }
}

/// How far the Tree draws from its focus, mirrored from `TreeTab`'s `@SceneStorage` so
/// View's depth items can grey at the ends of the range.
struct TreeDepths: Equatable {
    /// The one range the steppers and the menu items share.
    static let range = 0...8

    var ancestors = 3
    var descendants = 3
}

/// What the window looks like to the commands: everything availability depends on, in
/// one value, so availability is a pure function that tests can sweep (slice 82).
struct CommandContext: Equatable {
    var hasArchive = false
    var activeTab: ArchiveTab = .artifacts
    var selectedArtifact: ArtifactID?
    var selectedFile: FileID?
    var selectedPerson: PersonID?
    var personCount = 0
    /// A sheet, dialog, alert or panel is up in the window. Every command waits for it:
    /// one that opened a second sheet would dismiss the first and drop what was typed.
    var isPresentingModal = false
    var inspectorVisible = true
    /// The row selected in Review.
    var selectedReview: ReviewTarget?
    /// The person the Tree is drawn around, while it shows.
    var treeFocus: PersonID?
    var treeDepths = TreeDepths()
    /// A Review decision is still being written. Its row stays until the write lands, so
    /// Review's two verbs wait rather than decide that row a second time.
    var isDecidingReview = false

    /// The subject the menu bar acts on, taken from the selection, or `nil` when there is
    /// nothing selected for the command to act on.
    func selectionSubject(for command: ArchiveCommand) -> CommandSubject? {
        switch command.subjectKind {
        case .archive: .archive
        case .artifact: selectedArtifact.map(CommandSubject.artifact)
        case .file:
            selectedArtifact.flatMap { artifact in
                selectedFile.map { CommandSubject.file($0, in: artifact) }
            }
        case .person:
            switch command {
            // A card's verb: it has no selection to act on.
            case .focusHere: nil
            case .showInPeople: treeFocus.map(CommandSubject.person)
            default: selectedPerson.map(CommandSubject.person)
            }
        case .review: selectedReview.map(CommandSubject.review)
        case .row: nil
        }
    }

    /// Whether `command` can run on `subject` right now. The one rule every surface asks.
    func canPerform(_ command: ArchiveCommand, on subject: CommandSubject) -> Bool {
        guard hasArchive, !isPresentingModal, subject.kind == command.subjectKind else {
            return false
        }
        if let tab = command.tab, tab != activeTab { return false }
        switch command {
        // The inspector belongs to the artifact detail, which shows only with a selection.
        case .toggleInspector: return selectedArtifact != nil
        case .mergePerson: return personCount > 1
        // The two tabs with a search field.
        case .find: return activeTab == .artifacts || activeTab == .people
        case .acceptSuggestion:
            return !isDecidingReview && subject.reviewLane?.canAccept == true
        case .declineSuggestion:
            return !isDecidingReview && subject.reviewLane?.canDecline == true
        case .mergeDuplicate: return subject.reviewLane == .duplicate
        case .somebodyNew: return subject.reviewLane?.isName == true
        // Tree has no controls with nobody in it.
        case .chooseFocus: return personCount > 0
        case .moreAncestors:
            return personCount > 0 && treeDepths.ancestors < TreeDepths.range.upperBound
        case .fewerAncestors:
            return personCount > 0 && treeDepths.ancestors > TreeDepths.range.lowerBound
        case .moreDescendants:
            return personCount > 0 && treeDepths.descendants < TreeDepths.range.upperBound
        case .fewerDescendants:
            return personCount > 0 && treeDepths.descendants > TreeDepths.range.lowerBound
        // A row's verdict is a Review decision like the keys', so it waits as they do.
        case .confirmCandidate, .rejectCandidate, .recordSuggestedFact,
            .recordSuggestedRelationship, .dismissSuggestedRelationship:
            return !isDecidingReview && subject.offers(command)
        default:
            return command.subjectKind.isRow ? subject.offers(command) : true
        }
    }

    /// Whether the menu bar's item for `command` is live.
    func isAvailable(_ command: ArchiveCommand) -> Bool {
        selectionSubject(for: command).map { canPerform(command, on: $0) } ?? false
    }

    /// Whether `command`'s menu item carries its shortcut in this window. Commands of
    /// another tab don't, so two tabs can each use ⌘⌫. This is not only tidiness: SwiftUI
    /// drops a duplicate key from the later menu item, enabled or not (measured), so a
    /// key attached to both would leave Delete Person… with none.
    func ownsShortcut(_ command: ArchiveCommand) -> Bool {
        command.tab == nil || command.tab == activeTab
    }
}

extension CommandSubject {
    fileprivate var reviewLane: ReviewLane? {
        if case .review(let target) = self { target.lane } else { nil }
    }
}

extension ArchiveTab {
    /// ⌘1–⌘4, in the switcher's order, as Finder and Mail number theirs (G2).
    fileprivate var shortcutKey: KeyEquivalent {
        switch self {
        case .artifacts: "1"
        case .people: "2"
        case .tree: "3"
        case .review: "4"
        }
    }
}

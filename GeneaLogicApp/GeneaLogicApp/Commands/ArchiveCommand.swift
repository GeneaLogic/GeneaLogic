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
    enum SubjectKind { case archive, artifact, file, person, review }

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
        }
    }

    /// The tab a command belongs to, or `nil` for one that works from any tab. A create
    /// belongs to no tab: it switches to its own first (fork 2), so the result is in view.
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
        // Stable, whichever lane is selected, as the HIG asks of a menu. The panes keep
        // their lane's words (`paneTitle(in:)`).
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
        }
    }

    func title(in context: CommandContext) -> String {
        if self == .toggleInspector {
            return context.inspectorVisible ? "Hide Inspector" : "Show Inspector"
        }
        return title
    }

    /// The title an in-pane button uses under a section heading that already says what
    /// it adds to. Only the mention differs: "Add Person…" under *Persons Mentioned* is
    /// unambiguous, and the longer menu title doesn't fit the inspector at its narrowest.
    var paneTitle: String {
        self == .addMention ? "Add Person…" : title
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
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteArtifact, .deleteFile, .deletePerson: true
        default: false
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

    var kind: ArchiveCommand.SubjectKind {
        switch self {
        case .archive: .archive
        case .artifact: .artifact
        case .file: .file
        case .person: .person
        case .review: .review
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
        case .acceptSuggestion: return subject.reviewLane?.canAccept == true
        case .declineSuggestion: return subject.reviewLane?.canDecline == true
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
        default: return true
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

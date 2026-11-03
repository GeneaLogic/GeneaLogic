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
    // View
    case showTab(ArchiveTab), toggleInspector
    // Artifact
    case addEvent, addPlace, addMention, editTranscript, attachFile, deleteArtifact
    // Artifact ▸ Selected File
    case openFileInWindow, openFileInDefaultApp, saveFileCopy, scanFileForMetadata
    case replaceFile, deleteFile
    // Person
    case addName, addFact, addRelationship, mergePerson, deletePerson

    static let allCases: [ArchiveCommand] =
        [.addArtifact, .newPerson, .verifyIntegrity, .showTrash, .find]
        + ArchiveTab.allCases.map(ArchiveCommand.showTab) + [.toggleInspector]
        + [.addEvent, .addPlace, .addMention, .editTranscript, .attachFile, .deleteArtifact]
        + [
            .openFileInWindow, .openFileInDefaultApp, .saveFileCopy, .scanFileForMetadata,
            .replaceFile, .deleteFile,
        ]
        + [.addName, .addFact, .addRelationship, .mergePerson, .deletePerson]

    /// What a command acts on.
    enum SubjectKind { case archive, artifact, file, person }

    var subjectKind: SubjectKind {
        switch self {
        case .addArtifact, .newPerson, .verifyIntegrity, .showTrash, .find, .showTab,
            .toggleInspector:
            .archive
        case .addEvent, .addPlace, .addMention, .editTranscript, .attachFile, .deleteArtifact:
            .artifact
        case .openFileInWindow, .openFileInDefaultApp, .saveFileCopy, .scanFileForMetadata,
            .replaceFile, .deleteFile:
            .file
        case .addName, .addFact, .addRelationship, .mergePerson, .deletePerson:
            .person
        }
    }

    /// The tab a command belongs to, or `nil` for one that works from any tab. A create
    /// belongs to no tab: it switches to its own first (fork 2), so the result is in view.
    var tab: ArchiveTab? {
        switch subjectKind {
        case .archive: self == .toggleInspector ? .artifacts : nil
        case .artifact, .file: .artifacts
        case .person: .people
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
        case .showTab(let tab): tab.label
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
        case .deletePerson: "Delete Person…"
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

    var systemImage: String {
        switch self {
        case .addArtifact: "plus"
        case .newPerson: "person.crop.circle.badge.plus"
        case .verifyIntegrity: "checkmark.shield"
        case .showTrash: "trash"
        case .find: "magnifyingglass"
        case .showTab: "square.grid.2x2"
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
        case .mergePerson: "arrow.triangle.merge"
        }
    }

    var isDestructive: Bool {
        switch self {
        case .deleteArtifact, .deleteFile, .deletePerson: true
        default: false
        }
    }

    /// The shortcut table in `docs/slices/82-one-source-for-commands.md`.
    /// `CommandShortcutTests` pins that none is reserved and none is shared within a tab.
    var shortcut: KeyboardShortcut? {
        switch self {
        // ⇧⌘I is Photos' Import; ⌘I is left free (fork 1).
        case .addArtifact: KeyboardShortcut("i", modifiers: [.command, .shift])
        // Provisional, to revisit in the hand-test (fork 3).
        case .newPerson: KeyboardShortcut("n", modifiers: [.command, .shift])
        case .find: KeyboardShortcut("f", modifiers: [.command])
        case .showTab(let tab): KeyboardShortcut(tab.shortcutKey, modifiers: [.command])
        // Finder, Calendar and Pages put the inspector on ⌥⌘I.
        case .toggleInspector: KeyboardShortcut("i", modifiers: [.command, .option])
        // Finder's Move to Trash, and both deletes go to the archive's trash or undo.
        case .deleteArtifact, .deletePerson: KeyboardShortcut(.delete, modifiers: [.command])
        default: nil
        }
    }

    /// The text-editing action a command's shortcut also means, sent instead when that
    /// shortcut is typed in a text field. A menu's key equivalent is matched before the
    /// field sees the key, so without this ⌘⌫ in the inspector's Title field would offer
    /// to delete the artifact rather than the line.
    var textEditingAction: Selector? {
        switch self {
        case .deleteArtifact, .deletePerson: #selector(NSResponder.deleteToBeginningOfLine(_:))
        default: nil
        }
    }
}

/// What a command acts on: the archive as a whole, an artifact, one of its files, or a
/// person. (Not `.none`, which an optional subject would read as `nil`.)
enum CommandSubject: Hashable {
    case archive
    case artifact(ArtifactID)
    case file(FileID, in: ArtifactID)
    case person(PersonID)

    var kind: ArchiveCommand.SubjectKind {
        switch self {
        case .archive: .archive
        case .artifact: .artifact
        case .file: .file
        case .person: .person
        }
    }
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
        case .person: selectedPerson.map(CommandSubject.person)
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
        default: return true
        }
    }

    /// Whether the menu bar's item for `command` is live.
    func isAvailable(_ command: ArchiveCommand) -> Bool {
        selectionSubject(for: command).map { canPerform(command, on: $0) } ?? false
    }

    /// Whether `command`'s menu item carries its shortcut in this window. Commands of
    /// another tab don't, so two tabs can each use ⌘⌫ (as Finder does) with only one
    /// item ever answering it.
    func ownsShortcut(_ command: ArchiveCommand) -> Bool {
        command.tab == nil || command.tab == activeTab
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

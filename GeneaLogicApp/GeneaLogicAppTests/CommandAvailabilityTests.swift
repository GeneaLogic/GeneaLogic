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

    /// A window with an archive open, on `tab`, with everything selected.
    private func context(on tab: ArchiveTab, persons: Int = 2) -> CommandContext {
        CommandContext(
            hasArchive: true, activeTab: tab, selectedArtifact: artifact, selectedFile: file,
            selectedPerson: person, personCount: persons)
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
        let personVerbs = ArchiveCommand.allCases.filter { $0.subjectKind == .person }
        let everywhere = Self.creates.union(Self.tabs)

        #expect(
            available(in: context(on: .artifacts))
                == everywhere.union(artifactVerbs).union([.toggleInspector, .find]))
        #expect(available(in: context(on: .people)) == everywhere.union(personVerbs).union([.find]))
        #expect(available(in: context(on: .tree)) == everywhere)
        #expect(available(in: context(on: .review)) == everywhere)
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
    /// The system's keys, and the text-editing ones a field answers (⌘E use selection
    /// for find, ⌘G find next, ⌘J jump to selection, ⌘T fonts, ⌘B ⌘U ⌘I styles).
    private static let reserved: [KeyboardShortcut] =
        "hmqebjgtui,a".map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) }
        + [
            KeyboardShortcut("`", modifiers: .command),
            KeyboardShortcut(.space, modifiers: .command),
            KeyboardShortcut("d", modifiers: [.command, .option]),
            KeyboardShortcut("h", modifiers: [.command, .option]),
            KeyboardShortcut("q", modifiers: [.command, .control]),
            KeyboardShortcut("f", modifiers: [.command, .control]),
            KeyboardShortcut("s", modifiers: [.command, .control]),
            KeyboardShortcut("/", modifiers: [.command, .shift]),
            KeyboardShortcut(.escape, modifiers: [.command, .option]),
        ] + "345".map { KeyboardShortcut(KeyEquivalent($0), modifiers: [.command, .shift]) }
        // The File and Edit menus' own: New Archive, Open, Close, Undo, Redo, the clipboard.
        // (⌘F isn't here: Find… is a command, and ⌘F is its standard key.)
        + "nowzxcv".map { KeyboardShortcut(KeyEquivalent($0), modifiers: .command) }
        + [KeyboardShortcut("z", modifiers: [.command, .shift])]

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

    /// The agreed keys (forks 1 and 3, G2), and Find's standard one.
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
    }
}

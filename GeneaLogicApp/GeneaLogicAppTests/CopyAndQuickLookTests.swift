import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI
import Testing

@testable import GeneaLogicApp

/// Slice 87 — Copy and Quick Look: what a copied row reads as, when Quick Look can run and
/// what it names, and the copies a file's Copy and the panel are handed.
@Suite struct CopyTextTests {
    private func artifact(_ title: String, date: String?) -> ArtifactSummary {
        ArtifactSummary(
            uid: "ART-a", title: title, slug: "a", mediaType: .image, sourceAuthorityTier: nil,
            primaryDate: date, tags: [], fileCount: 1)
    }

    private func person(_ name: String?, date: String?) -> PersonSummary {
        PersonSummary(uid: "PER-a", displayName: name, primaryDate: date, factCount: 0)
    }

    @Test func aCopyIsTheRowsNameAndDate() {
        #expect(
            artifact("Letter from Karl", date: "1903-05").copyText == "Letter from Karl (May 1903)")
        #expect(person("Anna Lindqvist", date: "1872").copyText == "Anna Lindqvist (1872)")
    }

    @Test func aDatelessRowCopiesItsNameAlone() {
        #expect(artifact("Letter from Karl", date: nil).copyText == "Letter from Karl")
        #expect(artifact("Letter from Karl", date: "  ").copyText == "Letter from Karl")
        #expect(person("Anna Lindqvist", date: nil).copyText == "Anna Lindqvist")
    }

    /// A date EDTF can't read is copied as written, as the row shows it.
    @Test func anUnreadableDateIsCopiedAsWritten() {
        #expect(person("Anna", date: "spring of '72").copyText == "Anna (spring of '72)")
    }

    @Test func aNamelessRowCopiesWhatItsRowSays() {
        #expect(person(nil, date: "1872").copyText == "Unnamed person (1872)")
        #expect(artifact("", date: nil).copyText == "Untitled Artifact")
        #expect(artifact("  ", date: "1903").copyText == "Untitled Artifact (1903)")
    }
}

@Suite struct QuickLookCommandTests {
    private let artifact = ArtifactID("ART-a")
    private let person = PersonID("PER-a")

    private func context(withFiles: Bool, on tab: ArchiveTab = .artifacts) -> CommandContext {
        CommandContext(
            hasArchive: true, activeTab: tab, selectedArtifact: artifact, selectedPerson: person,
            personCount: 1, artifactsWithFiles: withFiles ? [artifact] : [],
            selectedArtifactTitle: "Letter from Karl")
    }

    @Test func quickLookNeedsAFile() {
        #expect(context(withFiles: true).isAvailable(.quickLook))
        #expect(!context(withFiles: false).isAvailable(.quickLook))
    }

    /// A person has no file: on People and the Tree, the item dims.
    @Test(arguments: [ArchiveTab.people, .tree])
    func quickLookDimsForAPerson(_ tab: ArchiveTab) {
        #expect(!context(withFiles: true, on: tab).isAvailable(.quickLook))
    }

    @Test func theMenuItemNamesTheArtifact() {
        #expect(
            ArchiveCommand.quickLook.title(in: context(withFiles: true))
                == "Quick Look “Letter from Karl”")
        // Not while it can't run: the name would be a selection another area left.
        #expect(ArchiveCommand.quickLook.title(in: context(withFiles: false)) == "Quick Look")
        #expect(
            ArchiveCommand.quickLook.title(in: context(withFiles: true, on: .people))
                == "Quick Look")
    }

    /// A row's Quick Look asks about its own artifact, not the selection.
    @Test func aRowsQuickLookAsksAboutItsOwnArtifact() {
        let other = ArtifactID("ART-b")
        var context = context(withFiles: true)
        #expect(!context.canPerform(.quickLook, on: .artifact(other), fromSidebar: true))
        context.artifactsWithFiles.insert(other)
        #expect(context.canPerform(.quickLook, on: .artifact(other), fromSidebar: true))
    }

    /// A blank title is named as the row names it, never `Quick Look “  ”`.
    @Test func aBlankTitleIsNamedAsTheRowNamesIt() {
        var context = context(withFiles: true)
        context.selectedArtifactTitle = "  "
        #expect(ArchiveCommand.quickLook.title(in: context) == "Quick Look")
        #expect(ArtifactTitle.display("  ") == "Untitled Artifact")
    }

    @Test func quickLookIsFindersKey() {
        #expect(ArchiveCommand.quickLook.shortcut == KeyboardShortcut("y", modifiers: .command))
    }
}

@MainActor
@Suite struct CopyAndQuickLookModelTests {
    private func ingest(_ name: String, into model: ArchiveModel, root: URL) async throws {
        let url = root.deletingLastPathComponent()
            .appendingPathComponent("src-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bytes of \(name)".utf8).write(to: url)
        await model.act { model.ingest([url]) }
    }

    /// ⌘C on the sidebar: an artifact or a person copies its line; Review and the Trash
    /// copy nothing, which leaves Edit ▸ Copy dimmed.
    @Test func theSidebarCopiesArtifactsAndPeopleOnly() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        try await ingest("letter.pdf", into: model, root: root)
        let summary = try #require(model.artifacts.first)

        #expect(model.copiedRecords(for: .artifact(summary.uid)).map(\.text) == [summary.copyText])
        #expect(model.copiedRecords(for: .trash).isEmpty)
        #expect(model.copiedRecords(for: nil).isEmpty)
        #expect(model.copiedRecords(for: .artifact("ART-gone")).isEmpty)
    }

    /// The window's own context knows whether its selection has a file, and names it.
    @Test func theWindowKnowsWhetherItsSelectionHasAFile() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        try await ingest("letter.pdf", into: model, root: root)
        let summary = try #require(model.artifacts.first)
        model.activeTab = .artifacts
        model.selectedArtifact = summary.uid

        #expect(model.commandContext.isAvailable(.quickLook))
        #expect(model.commandContext(for: .quickLook).isAvailable(.quickLook))
        #expect(
            ArchiveCommand.quickLook.title(in: model.commandContext)
                == "Quick Look “\(summary.title)”")

        let file = try #require(model.fullArtifact(summary.uid)?.files.first?.uid)
        await model.act { model.detachFile(file, from: summary.uid) }
        #expect(!model.commandContext.isAvailable(.quickLook))
        #expect(!model.canPerform(.quickLook, on: .artifact(summary.uid), fromSidebar: true))
    }

    /// A copied file goes out under its own name, and two of one name don't collide.
    @Test func aCopyKeepsTheUsersNameAndSameNamesStayApart() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        try await ingest("scan.jpg", into: model, root: root)
        try await ingest("scan.jpg", into: model, root: root)
        let files = model.artifacts.compactMap { summary in
            model.fullArtifact(summary.uid)?.files.first.map { (summary.uid, $0) }
        }
        try #require(files.count == 2)

        let copies = try files.map { artifact, entry in
            try #require(
                model.temporaryCopy(of: entry.uid, in: artifact, originalName: entry.originalName))
        }
        #expect(copies.map(\.lastPathComponent) == ["scan.jpg", "scan.jpg"])
        #expect(copies[0] != copies[1])
        #expect(
            try copies.map { try Data(contentsOf: $0) }.allSatisfy {
                $0 == Data("bytes of scan.jpg".utf8)
            })
    }

    /// A row's Quick Look asks about its own artifact: it runs with nothing selected.
    @Test func aRowsQuickLookDoesntNeedTheSelection() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        try await ingest("letter.pdf", into: model, root: root)
        let summary = try #require(model.artifacts.first)
        model.activeTab = .people
        model.selectedArtifact = nil

        #expect(model.canOffer(.quickLook, on: .artifact(summary.uid), fromSidebar: true))
        #expect(!model.commandContext.isAvailable(.quickLook))
    }

    /// A trashed file whose bytes were gone when it was detached has nothing to show.
    @Test func aRecordOnlyTrashedFileCantBeQuickLooked() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        try await ingest("kept.txt", into: model, root: root)
        try await ingest("lost.txt", into: model, root: root)
        let entries = model.artifacts.compactMap { summary in
            model.fullArtifact(summary.uid)?.files.first.map { (summary.uid, $0) }
        }
        let kept = try #require(entries.first { $0.1.originalName == "kept.txt" })
        let lost = try #require(entries.first { $0.1.originalName == "lost.txt" })
        try FileManager.default.removeItem(
            at: try #require(model.fileURL(of: lost.1.uid, in: lost.0)))

        await model.act { model.detachFile(kept.1.uid, from: kept.0) }
        await model.act { model.detachFile(lost.1.uid, from: lost.0) }
        model.reloadTrash(listing: true)

        let hasContent = Dictionary(
            uniqueKeysWithValues: model.trashedFiles.map { ($0.uid, $0.hasContent) })
        #expect(hasContent[kept.1.uid] == true)
        #expect(hasContent[lost.1.uid] == false)
    }
}

/// Slice 87's `/code-review`: asking for what the panel shows closes it; asking for
/// anything else switches it, and Space or ⌘Y inside it closes it.
@Suite struct QuickLookToggleTests {
    private let a = QuickLookPanel.key("ART-a")

    @Test func askingAgainClosesThePanel() {
        #expect(QuickLookPanel.closes(isVisible: true, sameOwner: true, shownKey: a, key: a))
    }

    @Test func askingForSomethingElseSwitchesIt() {
        // Another artifact's row.
        #expect(
            !QuickLookPanel.closes(
                isVisible: true, sameOwner: true, shownKey: a, key: QuickLookPanel.key("ART-b")))
        // Another of the same artifact's files.
        #expect(
            !QuickLookPanel.closes(
                isVisible: true, sameOwner: true, shownKey: a,
                key: QuickLookPanel.key("ART-a", file: "FIL-2")))
        // Another window, or the panel down.
        #expect(!QuickLookPanel.closes(isVisible: true, sameOwner: false, shownKey: a, key: a))
        #expect(!QuickLookPanel.closes(isVisible: false, sameOwner: true, shownKey: a, key: a))
    }

    @Test func spaceAndCommandYCloseItFromInside() {
        #expect(QuickLookPanel.closesPanel(key: " ", modifiers: []))
        #expect(QuickLookPanel.closesPanel(key: "y", modifiers: .command))
        #expect(QuickLookPanel.closesPanel(key: "y", modifiers: [.command, .capsLock]))
        #expect(!QuickLookPanel.closesPanel(key: "y", modifiers: []))
        #expect(!QuickLookPanel.closesPanel(key: " ", modifiers: .command))
        #expect(!QuickLookPanel.closesPanel(key: "y", modifiers: [.command, .shift]))
    }
}

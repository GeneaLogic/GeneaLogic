import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp

/// Slice 86 — a visible trash: the sidebar's count stays live, the two trash-backed
/// deletes run without asking, a person still asks, and Show Trash is a place.
@MainActor
@Suite struct TrashTests {

    /// Two artifacts, each with the file ingest attached.
    private func makeTwo(
        in model: ArchiveModel, root: URL
    ) async throws -> (first: ArtifactID, second: ArtifactID, file: FileID) {
        for name in ["first.txt", "second.txt"] {
            let url = root.deletingLastPathComponent()
                .appendingPathComponent("src-\(UUID().uuidString)-\(name)")
            try Data("scan".utf8).write(to: url)
            await model.act { model.ingest([url]) }
        }
        let ids = model.artifacts.map(\.uid)
        try #require(ids.count == 2)
        let file = try #require(model.fullArtifact(ids[1])?.files.first?.uid)
        return (ids[0], ids[1], file)
    }

    /// The count follows a move to the Trash, an undo and a redo, a restore, Delete
    /// Permanently and Empty Trash: from the cheap count elsewhere, and from the listings
    /// while the Trash shows.
    @Test(arguments: [ArchiveTab.artifacts, .trash])
    func theCountFollowsTheTrash(on area: ArchiveTab) async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let (first, second, file) = try await makeTwo(in: model, root: root)
        model.activeTab = area
        #expect(model.trashCount == 0)

        await model.act { model.deleteArtifact(first) }
        await model.act { model.detachFile(file, from: second) }
        #expect(model.trashCount == 2)

        await model.undoAndSettle()
        #expect(model.trashCount == 1)
        await model.redoAndSettle()
        #expect(model.trashCount == 2)

        await model.act { model.restoreFromTrash(first) }
        #expect(model.trashCount == 1)

        await model.act { model.deleteFileFromTrash(file) }
        #expect(model.trashCount == 0)

        await model.act { model.deleteArtifact(first) }
        #expect(model.trashCount == 1)
        await model.act { model.emptyTrash() }
        #expect(model.trashCount == 0)
    }

    /// The listings are read while the Trash shows, and on the way in.
    @Test func theTrashListsWhatItHolds() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let (first, second, file) = try await makeTwo(in: model, root: root)

        await model.act { model.deleteArtifact(first) }
        await model.act { model.detachFile(file, from: second) }
        model.activeTab = .trash
        #expect(model.trashedArtifacts.map(\.uid) == [first])
        #expect(model.trashedFiles.map(\.uid) == [file])

        let trashed = try #require(model.trashedFiles.first)
        await model.act { model.restoreFile(trashed) }
        #expect(model.trashedFiles.isEmpty)
        #expect(model.trashedArtifacts.map(\.uid) == [first])
    }

    /// Move to Trash runs at once, for an artifact and for a file: nothing is left
    /// waiting for a confirmation.
    @Test func moveToTrashDoesntAsk() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        let (first, second, file) = try await makeTwo(in: model, root: root)
        model.activeTab = .artifacts

        await model.act { model.perform(.deleteArtifact, on: .artifact(first)) }
        #expect(model.pendingCommand == nil)
        #expect(!model.artifacts.contains { $0.uid == first })

        await model.act { model.perform(.deleteFile, on: .file(file, in: second)) }
        #expect(model.pendingCommand == nil)
        #expect(model.fullArtifact(second)?.files.isEmpty == true)
        #expect(model.trashCount == 2)

        #expect(ArchiveCommand.deleteArtifact.title == "Move to Trash")
        #expect(ArchiveCommand.deleteFile.title == "Move to Trash")
    }

    /// A deleted person is undone only in this session (#11), so it still asks.
    @Test func deletePersonStillAsks() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        await model.act { model.createPerson(given: "Ann", surname: "Roe") }
        let person = try #require(model.persons.first?.uid)
        model.activeTab = .people

        model.perform(.deletePerson, on: .person(person))
        #expect(model.claimPendingCommand { $0 == .deletePerson } != nil)
        #expect(model.persons.map(\.uid) == [person])
        #expect(ArchiveCommand.deletePerson.title == "Delete Person…")
    }

    /// Show Trash goes to the Trash area, from any area, and opens nothing.
    @Test(arguments: ArchiveTab.allCases)
    func showTrashSelectsTheTrash(from area: ArchiveTab) throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }
        model.activeTab = area

        model.perform(.showTrash)
        #expect(model.pendingTab == .trash)
        #expect(!model.isPresentingModal)
        #expect(ArchiveCommand.showTrash.title == "Show Trash")
        #expect(ArchiveCommand.showTab(.trash) == .showTrash)
    }

    /// The Trash has no ⌘-number, and the View menu doesn't list it.
    @Test func theTrashHasNoNumber() {
        #expect(!ArchiveTab.numbered.contains(.trash))
        #expect(ArchiveCommand.showTrash.shortcut == nil)
        #expect(ArchiveCommand.delete(on: .trash) == nil)
    }
}

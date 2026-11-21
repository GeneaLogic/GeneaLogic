import Foundation
import Testing

@testable import GeneaLogicApp

/// Slice 85 — an archive reopens as it was left. The window state is kept on this Mac,
/// keyed by the archive's file identity: it follows a move or rename, and a Finder copy,
/// or another archive put at a moved one's old path, starts fresh.
///
/// Over an injected defaults suite and temp folders, so nothing here writes to the
/// developer's own defaults.
@MainActor
@Suite struct WindowStateTests {
    private let root: URL
    private let defaults: UserDefaults
    private let bookmarks: ArchiveBookmarks

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-window-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "genealogic-window-state-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        bookmarks = ArchiveBookmarks(defaults: defaults)
    }

    /// A stand-in archive: the store only needs a package-shaped folder to bookmark.
    private func makeArchive(_ name: String, in folder: String? = nil) throws -> URL {
        var url = root
        if let folder { url.append(path: folder, directoryHint: .isDirectory) }
        url.append(path: "\(name).genea", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appending(path: "manifest.json"))
        return url
    }

    /// A state that differs from the defaults in every field the window restores. Made
    /// once: each `WindowState()` mints its own `id`.
    private let leftState = Self.makeLeftState()

    private static func makeLeftState() -> WindowState {
        var state = WindowState()
        state.tab = ArchiveTab.tree.rawValue
        state.selectedArtifactID = "ART-a"
        state.selectedPersonID = "PER-a"
        state.selectedReviewItemID = "name|ART-a|p1"
        state.peopleShowsTree = true
        state.sidebarHidden = true
        state.sidebarWidth = 412
        state.reviewExpanded = false
        state.artifactsExpanded = false
        state.peopleExpanded = false
        state.treeAncestorDepth = 5
        state.treeDescendantDepth = 1
        state.inspectorShown = false
        state.inspectorWidth = 300
        return state
    }

    // MARK: - The record

    @Test func theRecordRoundTrips() throws {
        let state = leftState
        let decoded = try JSONDecoder().decode(
            WindowState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    /// A field this build doesn't know is ignored, and a missing one takes its default,
    /// so a record from another build restores what it can.
    @Test func aRecordFromAnotherBuildRestoresWhatItCan() throws {
        let json = #"{"tab":"people","inspectorWidth":"wide","somethingNew":1}"#
        let decoded = try JSONDecoder().decode(WindowState.self, from: Data(json.utf8))
        #expect(decoded.tab == "people")
        #expect(decoded.inspectorWidth == Layout.ArchiveWindow.inspectorIdealWidth)
        #expect(decoded.treeAncestorDepth == 3)
    }

    // MARK: - Finding it again

    @Test func aReopenFindsIt() throws {
        let archive = try makeArchive("Family")
        bookmarks.setWindowState(leftState, for: archive)

        #expect(bookmarks.windowState(for: archive) == leftState)
        // The same archive by a differently spelled URL, as Finder delivers it.
        let slashed = URL(fileURLWithPath: archive.path + "/")
        #expect(bookmarks.windowState(for: slashed) == leftState)
    }

    @Test func aNewArchiveHasNone() throws {
        let archive = try makeArchive("Family")
        #expect(bookmarks.windowState(for: archive) == nil)
    }

    /// Moved to another folder, or renamed in place: the state follows.
    @Test(arguments: [("Moved", "elsewhere"), ("Renamed", nil)] as [(String, String?)])
    func aMovedArchiveKeepsIt(name: String, folder: String?) throws {
        let original = try makeArchive("Family")
        bookmarks.setWindowState(leftState, for: original)

        var moved = root
        if let folder {
            moved.append(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        }
        moved.append(path: "\(name).genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(bookmarks.windowState(for: moved) == leftState)
        #expect(bookmarks.windowState(for: original) == nil)
    }

    @Test func aCopyStartsFresh() throws {
        let original = try makeArchive("Family")
        bookmarks.setWindowState(leftState, for: original)

        let copy = root.appending(path: "Family copy.genea", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: original, to: copy)

        #expect(bookmarks.windowState(for: copy) == nil)
        #expect(bookmarks.windowState(for: original) == leftState)
    }

    /// An archive moved away, and another one put at its old path: the newcomer doesn't
    /// inherit the state, and the moved archive still has it where it went.
    @Test func whatTakesAnOldPathDoesNotInheritIt() throws {
        let original = try makeArchive("Family")
        bookmarks.setWindowState(leftState, for: original)

        let moved = root.appending(path: "Moved.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: moved)
        let newcomer = try makeArchive("Family")

        #expect(bookmarks.windowState(for: newcomer) == nil)
        #expect(bookmarks.windowState(for: moved) == leftState)
    }

    /// A vanished archive's bookmark is forgotten by its path; the state goes with it,
    /// at the path it was last seen at, which follows a move.
    @Test func forgettingAnArchiveDropsItsState() throws {
        let archive = try makeArchive("Family")
        bookmarks.setWindowState(leftState, for: archive)
        let frameKey = "NSWindow Frame \(leftState.frameAutosaveName)"
        defaults.set("0 0 800 600 0 0 1440 900 ", forKey: frameKey)

        let moved = root.appending(path: "Moved.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: archive, to: moved)
        #expect(bookmarks.windowState(for: moved) == leftState)

        bookmarks.forget(pathKey: moved.standardizedFileURL.path)

        #expect(bookmarks.windowState(for: moved) == nil)
        #expect(defaults.object(forKey: frameKey) == nil)
    }

    // MARK: - The window's holder

    /// A new archive gets its record at once, so its frame's name survives a close
    /// before anything else changes; from then on every change is written.
    @Test func aWindowWritesThroughOnceLoaded() throws {
        let archive = try makeArchive("Family")

        let window = ArchiveWindowState(url: archive, bookmarks: bookmarks)
        window.values.tab = ArchiveTab.people.rawValue
        #expect(bookmarks.windowState(for: archive) == nil, "nothing is written before load")

        window.load()
        let fresh = try #require(bookmarks.windowState(for: archive))
        #expect(fresh.id == window.values.id)

        window.values.inspectorShown = false
        #expect(bookmarks.windowState(for: archive)?.inspectorShown == false)

        let reopened = ArchiveWindowState(url: archive, bookmarks: bookmarks)
        reopened.load()
        #expect(reopened.values == window.values)
    }
}

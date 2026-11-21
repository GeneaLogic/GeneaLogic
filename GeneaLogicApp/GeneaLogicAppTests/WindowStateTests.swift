import Foundation
import Testing

@testable import GeneaLogicApp

/// Slice 85 — an archive reopens as it was left. The window state is kept on this Mac,
/// keyed by the archive's file identity: it follows a move or rename, and a Finder copy,
/// or another archive put at a moved one's old path, starts fresh.
///
/// Over an injected defaults suite and temp folders, both removed after each test, so
/// nothing here writes to the developer's own defaults or outlives the run.
@MainActor
@Suite final class WindowStateTests {
    private let root: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private let bookmarks: ArchiveBookmarks

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-window-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "genealogic-window-state-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        bookmarks = ArchiveBookmarks(defaults: defaults, windowStatesLimit: 2)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// A stand-in archive: the store only needs a package-shaped folder.
    private func makeArchive(_ name: String, in folder: String? = nil) throws -> URL {
        var url = root
        if let folder { url.append(path: folder, directoryHint: .isDirectory) }
        url.append(path: "\(name).genea", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: url.appending(path: "manifest.json"))
        return url
    }

    private func state(of url: URL) -> WindowState? {
        bookmarks.windowState(forIdentity: ArchiveBookmarks.identity(of: url))
    }

    private func leave(_ url: URL, as state: WindowState) {
        bookmarks.setWindowState(state, forIdentity: ArchiveBookmarks.identity(of: url))
    }

    /// A state that differs from the defaults in every field the window restores. Made
    /// once: each `WindowState()` mints its own `id`.
    private let leftState = WindowStateTests.makeLeftState()

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
        let decoded = try JSONDecoder().decode(
            WindowState.self, from: JSONEncoder().encode(leftState))
        #expect(decoded == leftState)
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
        leave(archive, as: leftState)

        #expect(state(of: archive) == leftState)
        // The same archive by a differently spelled URL, as Finder delivers it.
        #expect(state(of: URL(fileURLWithPath: archive.path + "/")) == leftState)
    }

    @Test func aNewArchiveHasNone() throws {
        #expect(state(of: try makeArchive("Family")) == nil)
    }

    /// Moved to another folder, or renamed in place: the state follows.
    @Test(arguments: [("Moved", "elsewhere"), ("Renamed", nil)] as [(String, String?)])
    func aMovedArchiveKeepsIt(name: String, folder: String?) throws {
        let original = try makeArchive("Family")
        leave(original, as: leftState)

        var moved = root
        if let folder {
            moved.append(path: folder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        }
        moved.append(path: "\(name).genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(state(of: moved) == leftState)
    }

    @Test func aCopyStartsFresh() throws {
        let original = try makeArchive("Family")
        leave(original, as: leftState)

        let copy = root.appending(path: "Family copy.genea", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: original, to: copy)

        #expect(state(of: copy) == nil)
        #expect(state(of: original) == leftState)
    }

    /// An archive moved away, and another one put at its old path: the newcomer doesn't
    /// inherit the state, and the moved archive still has it where it went. (Reached
    /// through the bookmark, as the spec first had it, the newcomer inherited it.)
    @Test func whatTakesAnOldPathDoesNotInheritIt() throws {
        let original = try makeArchive("Family")
        leave(original, as: leftState)

        let moved = root.appending(path: "Moved.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: original, to: moved)
        let newcomer = try makeArchive("Family")

        #expect(state(of: newcomer) == nil)
        #expect(state(of: moved) == leftState)
    }

    /// Remove from Recents, and a bookmark that fails to resolve, both go through
    /// `forget`; neither resets a window. The state is keyed by identity, so whatever
    /// takes the path can't inherit it, and a path can't say which record was whose.
    @Test func forgettingAPathKeepsWindowStates() throws {
        let archive = try makeArchive("Family")
        leave(archive, as: leftState)

        bookmarks.forget(pathKey: archive.standardizedFileURL.path)

        #expect(state(of: archive) == leftState)
    }

    // MARK: - The cap

    /// Past the cap, the least recently *opened* record goes, frame included. A window
    /// that only opens and reads its record counts as opened.
    @Test func theCapKeepsTheMostRecentlyOpened() throws {
        let first = try makeArchive("First")
        let second = try makeArchive("Second")
        let third = try makeArchive("Third")
        leave(first, as: leftState)
        let secondState = WindowState()
        leave(second, as: secondState)
        let secondFrame = "NSWindow Frame \(secondState.frameAutosaveName)"
        defaults.set("0 0 800 600 0 0 1440 900 ", forKey: secondFrame)

        ArchiveWindowState(url: first, bookmarks: bookmarks).load()  // opened, unchanged
        leave(third, as: WindowState())

        #expect(state(of: first) == leftState)
        #expect(state(of: second) == nil)
        #expect(defaults.object(forKey: secondFrame) == nil)
        #expect(state(of: third) != nil)
    }

    // MARK: - The window's holder

    /// A new archive gets its record at once, so its frame's name survives a close
    /// before anything else changes; from then on every change is written.
    @Test func aWindowWritesThroughOnceLoaded() throws {
        let archive = try makeArchive("Family")

        let window = ArchiveWindowState(url: archive, bookmarks: bookmarks)
        window.tab = ArchiveTab.people.rawValue
        #expect(state(of: archive) == nil, "nothing is written before load")

        window.load()
        #expect(state(of: archive) == window.snapshot)

        window.inspectorShown = false
        #expect(state(of: archive)?.inspectorShown == false)

        let reopened = ArchiveWindowState(url: archive, bookmarks: bookmarks)
        reopened.load()
        #expect(reopened.snapshot == window.snapshot)
        #expect(reopened.frameAutosaveName == window.frameAutosaveName)
    }

    /// Renamed while its window is open: the window's URL is fixed, but its writes keep
    /// going to the archive's record, which the renamed archive reopens with.
    @Test func aWindowKeepsWritingThroughARename() throws {
        let archive = try makeArchive("Family")
        let window = ArchiveWindowState(url: archive, bookmarks: bookmarks)
        window.load()

        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: archive, to: renamed)
        window.tab = ArchiveTab.review.rawValue

        #expect(state(of: renamed)?.tab == ArchiveTab.review.rawValue)
    }
}

import Foundation
import Testing

@testable import GeneaLogicApp

/// Stands in for the system's recent documents, so no test writes to the developer's own.
@MainActor
final class RecordingSystemRecents: SystemRecents {
    /// Most recent first, as canonical paths.
    private(set) var paths: [String] = []

    nonisolated init() {}

    func note(_ url: URL) {
        remove(url)
        paths.insert(url.canonicalArchiveURL.path, at: 0)
    }

    func remove(_ url: URL) {
        paths.removeAll { $0 == url.canonicalArchiveURL.path }
    }

    func clear() {
        paths = []
    }
}

/// Slice 85b — the app's recents, and the system's kept in step with them.
@MainActor
@Suite final class RecentsTests {
    private let root: URL
    private let suiteName: String
    private let defaults: UserDefaults
    private let system = RecordingSystemRecents()
    private let bookmarks: ArchiveBookmarks

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-recents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "genealogic-recents-tests-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        bookmarks = ArchiveBookmarks(defaults: defaults, systemRecents: system)
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeArchive(_ name: String) throws -> URL {
        let url = root.appending(path: "\(name).genea", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func path(_ url: URL) -> String { url.standardizedFileURL.path }

    @Test func anOpenIsRecordedHereAndWithTheSystem() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        #expect(bookmarks.recents == [path(two), path(one)])
        #expect(system.paths == bookmarks.recents)

        // Reopened from Open Recent: back to the front of both.
        bookmarks.promote(one)
        #expect(bookmarks.recents == [path(one), path(two)])
        #expect(system.paths == bookmarks.recents)
    }

    @Test func clearMenuEmptiesBothListsAndKeepsTheBookmarks() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        bookmarks.clearRecents()
        #expect(bookmarks.recents.isEmpty)
        #expect(system.paths.isEmpty)
        // What restoration needs to reach the archive again.
        #expect(bookmarks.resolve(one) != nil)
    }

    @Test func aRemovedRecentLeavesBothLists() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        bookmarks.forget(pathKey: path(one))
        #expect(bookmarks.recents == [path(two)])
        #expect(system.paths == [path(two)])
    }

    @Test func aRecentWhoseArchiveIsGoneDropsOut() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        try FileManager.default.removeItem(at: one)
        #expect(bookmarks.resolve(one) == nil)
        #expect(bookmarks.recents == [path(two)])
        #expect(system.paths == [path(two)])
    }
}

/// Slice 85b — which window a launch, an open or a Dock click brings up.
@MainActor
@Suite struct ArchiveOpenCoordinatorTests {
    /// A coordinator over a pretend window list, recording what it opens.
    @MainActor
    private final class Harness {
        var hasWindows = false
        var opened: [URL] = []
        var welcomes = 0
        var welcomesClosed = 0
        let coordinator: ArchiveOpenCoordinator

        init() {
            var windows: () -> Bool = { false }
            coordinator = ArchiveOpenCoordinator(hasWindows: { windows() })
            windows = { [unowned self] in hasWindows }
            coordinator.openArchive = { [unowned self] in opened.append($0) }
            coordinator.openWelcome = { [unowned self] in welcomes += 1 }
            coordinator.closeWelcome = { [unowned self] in welcomesClosed += 1 }
        }
    }

    private let archive = URL(fileURLWithPath: "/a/One.genea", isDirectory: true)

    @Test func aLaunchWithNothingElseShowsWelcome() {
        let harness = Harness()
        harness.coordinator.launchDidFinish()
        #expect(harness.welcomes == 1)
    }

    @Test func aLaunchThatRestoredAWindowDoesNot() {
        let harness = Harness()
        harness.hasWindows = true
        harness.coordinator.launchDidFinish()
        #expect(harness.welcomes == 0)
    }

    /// The archive's window isn't up yet when the launch finishes, so this can't rest on
    /// the window list.
    @Test func aFinderOpenAtLaunchWaitsAndNeverShowsWelcome() {
        let harness = Harness()
        harness.coordinator.open(archive)
        #expect(harness.opened.isEmpty)
        harness.coordinator.launchDidFinish()
        #expect(harness.opened == [archive])
        #expect(harness.welcomes == 0)
    }

    @Test func anOpenWhileRunningIsImmediateAndCanonical() {
        let harness = Harness()
        harness.coordinator.launchDidFinish()
        harness.coordinator.open(URL(fileURLWithPath: "/a/One.genea", isDirectory: false))
        #expect(harness.opened == [archive])
    }

    @Test func anOpenClosesTheWelcomeWindow() {
        let harness = Harness()
        harness.coordinator.launchDidFinish()
        #expect(harness.welcomes == 1)
        #expect(harness.welcomesClosed == 0)
        harness.coordinator.open(archive)
        #expect(harness.welcomesClosed == 1)
    }

    @Test func aDockClickShowsWelcomeOnlyWithNoWindows() {
        let harness = Harness()
        harness.hasWindows = true
        harness.coordinator.launchDidFinish()
        // AppKit's own part: a minimized window comes back.
        #expect(harness.coordinator.reopen())
        #expect(harness.welcomes == 0)

        harness.hasWindows = false
        #expect(!harness.coordinator.reopen())
        #expect(harness.welcomes == 1)
    }

    /// A restored window that never gets its archive closes.
    @Test func anEmptyRestoredWindowGivesWayToWelcome() {
        let harness = Harness()
        harness.hasWindows = true
        harness.coordinator.launchDidFinish()
        harness.hasWindows = false
        harness.coordinator.emptyWindowDidClose()
        #expect(harness.welcomes == 1)
    }
}

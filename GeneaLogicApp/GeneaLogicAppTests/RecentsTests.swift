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
        let path = url.canonicalArchiveURL.path
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
    }

    /// The system's entries follow a moved archive.
    func follow(_ old: URL, to new: URL) {
        paths = paths.map { $0 == old.canonicalArchiveURL.path ? new.canonicalArchiveURL.path : $0 }
    }

    func clear() {
        paths = []
    }
}

/// Slice 85b — the app's recents, and what the system's list is told of them.
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

    /// The system has no way to remove one archive, and clearing and noting the rest again
    /// lost what AppKit couldn't hand back.
    @Test func aRemovedRecentLeavesTheAppsListOnlyAndKeepsItsBookmark() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        bookmarks.removeRecent(one)
        #expect(bookmarks.recents == [path(two)])
        #expect(system.paths == [path(two), path(one)])
        // It may be open, and its window restores through this.
        #expect(bookmarks.resolve(one) != nil)
    }

    @Test func aRecentWhoseArchiveIsGoneDropsOut() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        try FileManager.default.removeItem(at: one)
        #expect(bookmarks.resolve(one) == nil)
        #expect(bookmarks.recents == [path(two)])
    }

    /// The bookmark follows a move or rename, and the reopen follows the bookmark.
    @Test func reopeningAMovedArchiveOpensItWhereItIs() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: one, to: renamed)
        system.follow(one, to: renamed)

        let opened = ArchiveAccessStore.shared.reopenRecent(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(opened) }
        #expect(opened == renamed.canonicalArchiveURL)
        #expect(ArchiveAccessStore.shared.isHolding(renamed))
        #expect(bookmarks.recents == [path(renamed), path(two)])
        #expect(system.paths.first == path(renamed))
        // The bookmark moved with it, so the next reopen and a restore find it.
        #expect(bookmarks.resolve(renamed) != nil)
        #expect(bookmarks.resolve(one) == nil)
    }

    /// A promote is told only of a path that is there.
    @Test func aMissingArchiveIsNotPromoted() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        try FileManager.default.removeItem(at: one)
        bookmarks.promote(one)
        #expect(bookmarks.recents.first == path(two))
        #expect(system.paths.first == path(two))
    }

    /// An archive put at a moved one's old path is the one that opens there: a bookmark
    /// resolves by path first.
    @Test func aNewcomerAtTheOldPathIsWhatOpens() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        try FileManager.default.moveItem(
            at: one, to: root.appending(path: "Renamed.genea", directoryHint: .isDirectory))
        _ = try makeArchive("One")
        let opened = ArchiveAccessStore.shared.reopenRecent(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(opened) }
        #expect(opened == one.canonicalArchiveURL)
        #expect(bookmarks.recents == [path(one)])
    }
}

/// Slice 85b — which window a launch, an open or a Dock click brings up.
@MainActor
@Suite struct ArchiveOpenCoordinatorTests {
    /// A coordinator over a pretend window list, recording what it opens.
    @MainActor
    private final class Harness {
        var hasWindows = false
        var isHidden = false
        var opened: [URL] = []
        var welcomes = 0
        var welcomesClosed = 0
        let coordinator: ArchiveOpenCoordinator

        init() {
            var windows: () -> Bool = { false }
            var hidden: () -> Bool = { false }
            coordinator = ArchiveOpenCoordinator(
                hasWindows: { windows() }, isHidden: { hidden() })
            windows = { [unowned self] in hasWindows }
            hidden = { [unowned self] in isHidden }
            coordinator.openArchive = { [unowned self] in opened.append($0) }
            coordinator.openWelcome = { [unowned self] in welcomes += 1 }
            coordinator.closeWelcome = { [unowned self] in welcomesClosed += 1 }
        }

        func finishLaunch() {
            coordinator.launchDidFinish()
            coordinator.restorationDidFinish()
        }
    }

    private let archive = URL(fileURLWithPath: "/a/One.genea", isDirectory: true)

    @Test func aLaunchWithNothingElseShowsWelcome() {
        let harness = Harness()
        harness.finishLaunch()
        #expect(harness.welcomes == 1)
    }

    @Test func aLaunchThatRestoredAWindowDoesNot() {
        let harness = Harness()
        harness.hasWindows = true
        harness.finishLaunch()
        #expect(harness.welcomes == 0)
    }

    /// The archive's window isn't up yet when the launch finishes, so this can't rest on
    /// the window list.
    @Test func aFinderOpenAtLaunchWaitsAndNeverShowsWelcome() {
        let harness = Harness()
        harness.coordinator.open(archive)
        #expect(harness.opened.isEmpty)
        harness.finishLaunch()
        #expect(harness.opened == [archive])
        #expect(harness.welcomes == 0)
    }

    @Test func anOpenWhileRunningIsImmediateAndCanonical() {
        let harness = Harness()
        harness.finishLaunch()
        harness.coordinator.open(URL(fileURLWithPath: "/a/One.genea", isDirectory: false))
        #expect(harness.opened == [archive])
    }

    @Test func anOpenClosesTheWelcomeWindow() {
        let harness = Harness()
        harness.finishLaunch()
        #expect(harness.welcomes == 1)
        #expect(harness.welcomesClosed == 0)
        harness.coordinator.open(archive)
        #expect(harness.welcomesClosed == 1)
    }

    @Test func aDockClickShowsWelcomeOnlyWithNoWindows() {
        let harness = Harness()
        harness.hasWindows = true
        harness.finishLaunch()
        // AppKit's own part: a minimized window comes back.
        #expect(harness.coordinator.reopen())
        #expect(harness.welcomes == 0)

        harness.hasWindows = false
        #expect(!harness.coordinator.reopen())
        #expect(harness.welcomes == 1)
    }

    /// AppKit may finish restoring after it finishes launching.
    @Test(arguments: [true, false])
    func nothingIsDecidedUntilBothAreDone(launchFirst: Bool) {
        let harness = Harness()
        harness.coordinator.open(archive)
        if launchFirst {
            harness.coordinator.launchDidFinish()
        } else {
            harness.coordinator.restorationDidFinish()
        }
        #expect(harness.opened.isEmpty)
        #expect(harness.welcomes == 0)
        harness.finishLaunch()
        #expect(harness.opened == [archive])
    }

    /// A hidden app's windows say they aren't visible.
    @Test func aHiddenAppIsAskedWhenItIsShown() {
        let harness = Harness()
        harness.isHidden = true
        harness.finishLaunch()
        #expect(harness.coordinator.reopen())
        #expect(harness.welcomes == 0)

        harness.isHidden = false
        harness.hasWindows = true
        harness.coordinator.appDidUnhide()
        #expect(harness.welcomes == 0)

        // Hidden with nothing open: shown, it is the welcome window's turn.
        harness.isHidden = true
        harness.hasWindows = false
        #expect(harness.coordinator.reopen())
        harness.isHidden = false
        harness.coordinator.appDidUnhide()
        #expect(harness.welcomes == 1)
    }

    /// Asked for once, not at every unhide.
    @Test func showingTheAppAloneDoesNotShowWelcome() {
        let harness = Harness()
        harness.hasWindows = true
        harness.finishLaunch()
        harness.hasWindows = false
        harness.coordinator.appDidUnhide()
        #expect(harness.welcomes == 0)
    }

    @Test func aRestoredWindowClosesAPrematureWelcome() {
        let harness = Harness()
        harness.finishLaunch()
        harness.coordinator.archiveWindowDidOpen()
        #expect(harness.welcomesClosed == 1)
    }
}

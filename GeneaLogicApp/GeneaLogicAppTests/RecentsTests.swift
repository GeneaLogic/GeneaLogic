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

/// Slices 85b and 85c — the app's recents, what the system's list is told of them, and
/// where a reopened or restored window finds its archive.
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
        bookmarks.removeRecent(one, isOpen: true)
        #expect(bookmarks.recents == [path(two)])
        #expect(system.paths == [path(two), path(one)])
        // It is open, and its window restores through this.
        #expect(bookmarks.resolve(one) != nil)
    }

    /// One that isn't open keeps no access it isn't listed for.
    @Test func aRemovedRecentThatIsntOpenLosesItsBookmark() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        bookmarks.removeRecent(one, isOpen: false)
        #expect(bookmarks.recents.isEmpty)
        #expect(bookmarks.resolve(one) == nil)
    }

    /// Opening it there would edit an archive that emptying the Trash destroys. It stays
    /// listed, in case it is put back.
    @Test func aRecentInTheTrashIsNotReopenedThere() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        let trash = root.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: one, to: trash.appending(path: "One.genea", directoryHint: .isDirectory))
        let opened = ArchiveAccessStore.shared.reopenRecent(one, bookmarks: bookmarks)
        #expect(opened == one.canonicalArchiveURL)
        #expect(!ArchiveAccessStore.shared.isHolding(opened))
        #expect(bookmarks.recents == [path(one)])
    }

    /// The same folder spelled another way is not a move: the recent keeps its key, so the
    /// archive never gets two window values.
    @Test func anotherSpellingOfTheSameFolderIsNotAMove() throws {
        let one = try makeArchive("One")
        // The firmlinked spelling: a bookmark made from it resolves to the plain one.
        let alias = URL(fileURLWithPath: "/System/Volumes/Data" + one.path, isDirectory: true)
        bookmarks.remember(alias)
        let resolved = try #require(bookmarks.resolve(alias))
        try #require(resolved.standardizedFileURL.path != alias.standardizedFileURL.path)
        let opened = ArchiveAccessStore.shared.reopenRecent(alias, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(opened) }
        #expect(opened == alias.canonicalArchiveURL)
        #expect(bookmarks.recents == [path(alias)])
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

    // MARK: - Restoring a window (slice 85c)

    /// A window restored for a moved or renamed archive opens it where it is, and its
    /// recent keeps its place: relaunching isn't opening.
    @Test func aMovedArchiveRestoresWhereItIs() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: one, to: renamed)
        system.follow(one, to: renamed)

        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(restored.location) }
        #expect(restored.location == renamed.canonicalArchiveURL)
        #expect(restored.tookAccess)
        #expect(ArchiveAccessStore.shared.isHolding(renamed))
        #expect(!ArchiveAccessStore.shared.isHolding(one))
        #expect(bookmarks.recents == [path(two), path(renamed)])
        #expect(system.paths == [path(two), path(renamed)])
        // The next launch restores it there.
        #expect(bookmarks.resolve(renamed) != nil)
    }

    @Test func anUnmovedArchiveRestoresAtItsOwnURL() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(restored.location) }
        #expect(restored.location == one.canonicalArchiveURL)
        #expect(ArchiveAccessStore.shared.isHolding(one))
        #expect(bookmarks.recents == [path(one)])
    }

    /// A bookmark resolves by path first, so an archive put at the old path is the one a
    /// restored window opens.
    @Test func aNewcomerAtTheOldPathIsWhatRestores() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        try FileManager.default.moveItem(
            at: one, to: root.appending(path: "Renamed.genea", directoryHint: .isDirectory))
        _ = try makeArchive("One")
        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(restored.location) }
        #expect(restored.location == one.canonicalArchiveURL)
        #expect(bookmarks.recents == [path(one)])
    }

    /// Opening it there would edit an archive that emptying the Trash destroys. Before 85c,
    /// `load()`'s access check resolved the bookmark straight into the Trash and reported
    /// access; now it only asks whether the window's `restore` took any.
    @Test func anArchiveInTheTrashIsNotRestoredThere() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        let trash = root.appending(path: ".Trash", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: one, to: trash.appending(path: "One.genea", directoryHint: .isDirectory))
        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        #expect(restored.location == one.canonicalArchiveURL)
        #expect(!restored.tookAccess)
        #expect(!ArchiveAccessStore.shared.isHolding(one))
        #expect(bookmarks.recents == [path(one)])
    }

    /// An archive opened in this session already holds access, so a window opened for it
    /// stays at its URL and its bookmark isn't consulted.
    @Test func anArchiveAlreadyHeldIsLeftAlone() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        ArchiveAccessStore.shared.adoptAlreadyReachable(one)
        defer { ArchiveAccessStore.shared.release(one) }
        try FileManager.default.moveItem(
            at: one, to: root.appending(path: "Renamed.genea", directoryHint: .isDirectory))
        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        #expect(restored.location == one.canonicalArchiveURL)
        #expect(!restored.tookAccess)
        #expect(bookmarks.recents == [path(one)])
    }

    /// Launched by double-clicking the renamed archive: its open recorded the new path, with
    /// a fresh bookmark, before the window for the old one was restored. The restore must
    /// not demote it, drop it from a cleared menu, or overwrite its bookmark (85c's
    /// `/code-review`).
    @Test func aRestoreKeepsAnOpenAlreadyRecordedAtTheNewPath() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        bookmarks.clearRecents()
        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: one, to: renamed)
        bookmarks.remember(renamed)
        let fresh = try #require(storedBookmarks()[path(renamed)])

        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(restored.location) }
        #expect(restored.location == renamed.canonicalArchiveURL)
        #expect(bookmarks.recents == [path(renamed)])
        #expect(storedBookmarks()[path(renamed)] == fresh)
        #expect(storedBookmarks()[path(one)] == nil)
    }

    /// The same launch with the old path still listed: it goes, and the new path keeps the
    /// front its open gave it.
    @Test func aRestoreDropsTheOldPathBehindAnOpenAtTheNewOne() throws {
        let one = try makeArchive("One")
        let two = try makeArchive("Two")
        bookmarks.remember(one)
        bookmarks.remember(two)
        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: one, to: renamed)
        bookmarks.remember(renamed)

        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        defer { ArchiveAccessStore.shared.release(restored.location) }
        #expect(bookmarks.recents == [path(renamed), path(two)])
    }

    /// A restore that finds the new path already held (that open again) took nothing, so
    /// its window has nothing to release: the open's window owns the access.
    @Test func aRestoreOntoAHeldPathTakesNothing() throws {
        let one = try makeArchive("One")
        bookmarks.remember(one)
        let renamed = root.appending(path: "Renamed.genea", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: one, to: renamed)
        ArchiveAccessStore.shared.adoptAlreadyReachable(renamed)
        defer { ArchiveAccessStore.shared.release(renamed) }
        let restored = ArchiveAccessStore.shared.restore(one, bookmarks: bookmarks)
        #expect(restored.location == renamed.canonicalArchiveURL)
        #expect(!restored.tookAccess)
    }

    private func storedBookmarks() -> [String: Data] {
        defaults.dictionary(forKey: "archiveBookmarks") as? [String: Data] ?? [:]
    }
}

/// Slice 85b — which window a launch, an open or a Dock click brings up.
@MainActor
@Suite struct ArchiveOpenCoordinatorTests {
    /// A coordinator over a pretend window list, recording what it opens.
    @MainActor
    private final class Harness {
        var hasWindows = false
        var hasMinimizedWindows = false
        var isHidden = false
        /// The restoration deadline, when one was set.
        var deadline: (@MainActor () -> Void)?
        var opened: [URL] = []
        var welcomes = 0
        var welcomesClosed = 0
        let coordinator: ArchiveOpenCoordinator

        init() {
            var windows: () -> Bool = { false }
            var minimized: () -> Bool = { false }
            var hidden: () -> Bool = { false }
            var schedule: (@escaping @MainActor () -> Void) -> Void = { _ in }
            coordinator = ArchiveOpenCoordinator(
                hasWindows: { windows() }, hasMinimizedWindows: { minimized() },
                isHidden: { hidden() }, after: { _, work in schedule(work) })
            windows = { [unowned self] in hasWindows }
            minimized = { [unowned self] in hasMinimizedWindows }
            hidden = { [unowned self] in isHidden }
            schedule = { [unowned self] in deadline = $0 }
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

    /// Before the launch is decided, AppKit's default would be a window with no archive.
    @Test func aDockClickDuringTheLaunchLeavesItToTheLaunch() {
        let harness = Harness()
        #expect(!harness.coordinator.reopen())
        harness.finishLaunch()
        #expect(harness.welcomes == 1)
    }

    /// No restoration notification must not hold opens and the welcome window for ever.
    @Test func theRestorationDeadlineStandsInForAMissingNotification() throws {
        let harness = Harness()
        harness.coordinator.open(archive)
        harness.coordinator.launchDidFinish()
        #expect(harness.opened.isEmpty)
        let deadline = try #require(harness.deadline)
        deadline()
        #expect(harness.opened == [archive])
        // A notification arriving after the deadline changes nothing.
        harness.coordinator.restorationDidFinish()
        #expect(harness.opened == [archive])
    }

    @Test func noDeadlineWhenRestorationCameFirst() {
        let harness = Harness()
        harness.coordinator.restorationDidFinish()
        harness.coordinator.launchDidFinish()
        #expect(harness.deadline == nil)
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
        // Nothing minimized to bring back, and a new window would have no archive.
        #expect(!harness.coordinator.reopen())
        #expect(harness.welcomes == 0)

        harness.isHidden = false
        harness.hasWindows = true
        harness.coordinator.appDidUnhide()
        #expect(harness.welcomes == 0)

        // Hidden with nothing open: shown, it is the welcome window's turn.
        harness.isHidden = true
        harness.hasWindows = false
        #expect(!harness.coordinator.reopen())
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

    /// Hidden with a window minimized: AppKit brings it back.
    @Test func aHiddenAppWithAMinimizedWindowLetsAppKitBringItBack() {
        let harness = Harness()
        harness.hasWindows = true
        harness.hasMinimizedWindows = true
        harness.finishLaunch()
        harness.isHidden = true
        #expect(harness.coordinator.reopen())
    }
}

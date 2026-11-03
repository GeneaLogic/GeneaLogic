import AppKit
import GeneaLogicArchive
import SwiftUI

/// The menu bar. New/Open present AppKit panels and then open a window for the
/// result, so they work with **no window present** (no `ensureWindow` dance — that
/// was slice 3's workaround, now unnecessary). Every archive verb is an
/// `ArchiveCommand` on whichever archive window is key, via `@FocusedValue`, and is
/// spelled there, not here (slice 82).
struct ArchiveCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @FocusedValue(\.archiveModel) private var activeModel
    /// The persisted recents, read here so File ▸ Open Recent updates live as
    /// archives are opened (the store is `@Observable`).
    @State private var bookmarks = ArchiveBookmarks.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Archive…") { newArchive() }
                .keyboardShortcut("n", modifiers: [.command])

            Button("Open Archive…") { openArchive() }
                .keyboardShortcut("o", modifiers: [.command])

            openRecentMenu
        }

        CommandGroup(after: .newItem) {
            Divider()
            item(.addArtifact)
            item(.newPerson)
            Divider()
            item(.verifyIntegrity)
            item(.showTrash)
        }

        // The window has no Find of its own: the Edit menu's Find submenu comes with a
        // text view, and the sidebar's `.searchable` field takes no key (measured).
        CommandGroup(after: .pasteboard) {
            Divider()
            item(.find)
        }

        viewMenuAdditions
        artifactMenu
        personMenu
        helpMenu
    }

    /// The menu-bar item for `command`, on the key window's model.
    private func item(_ command: ArchiveCommand) -> CommandMenuItem {
        CommandMenuItem(command: command, model: activeModel)
    }

    // MARK: - Help menu

    /// Until the user guide exists (#50), Help points at the project page, whose README
    /// is the guide for now, and at the issue templates (slice 81, G8). Not "GeneaLogic
    /// Help": that name promises a guide. The menu's search field is the system's.
    private var helpMenu: some Commands {
        CommandGroup(replacing: .help) {
            Button("GeneaLogic on GitHub") { openURL(ProjectLinks.home) }
            Button("Report an Issue…") { openURL(ProjectLinks.newIssue) }
        }
    }

    // MARK: - View menu (tabs, inspector toggle, sort)

    /// The four tabs on ⌘1–⌘4 (G2) above the standard **View** menu's Show Sidebar, then
    /// the inspector toggle and Sort By after it.
    private var viewMenuAdditions: some Commands {
        Group {
            CommandGroup(before: .sidebar) {
                ForEach(ArchiveTab.allCases) { tab in
                    TabMenuItem(tab: tab, model: activeModel)
                }
                Divider()
            }

            CommandGroup(after: .sidebar) {
                item(.toggleInspector)

                Menu("Sort By") {
                    // Same two pickers as the sidebar Sort menu (shared `SortPickers`).
                    SortPickers(key: sortKeyBinding, ascending: sortAscendingBinding)
                }
                // Sort drives the Artifacts browse list only, so gate it to that tab
                // (the People list sorts independently by name).
                .disabled(!isArtifactsTab)
            }
        }
    }

    // MARK: - Artifact menu

    /// The verbs on the selected artifact (F6, slice 82). Each item is off with no
    /// selection, off the Artifacts tab, and while a sheet is up.
    private var artifactMenu: some Commands {
        CommandMenu("Artifact") {
            item(.addEvent)
            item(.addPlace)
            item(.addMention)
            item(.editTranscript)
            item(.attachFile)

            Menu("Selected File") {
                // AppKit greys a submenu's *title* only when every child is disabled,
                // which each item is, on its own, with no file selected.
                item(.openFileInWindow)
                item(.openFileInDefaultApp)
                item(.saveFileCopy)
                item(.scanFileForMetadata)
                Divider()
                item(.replaceFile)
                item(.deleteFile)
            }

            Divider()
            item(.deleteArtifact)
        }
    }

    // MARK: - Person menu

    /// The verbs on the selected person (slice 82), the People tab's counterpart of the
    /// Artifact menu, as Mail has a menu for each of Message and Mailbox.
    private var personMenu: some Commands {
        CommandMenu("Person") {
            item(.addName)
            item(.addFact)
            item(.addRelationship)
            Divider()
            item(.mergePerson)
            Divider()
            item(.deletePerson)
        }
    }

    /// Whether an Artifacts-tab command that doesn't need a selection (Sort By) should be
    /// enabled: an archive is open **and** that tab is showing.
    private var isArtifactsTab: Bool {
        activeModel?.archive != nil && activeModel?.activeTab == .artifacts
    }

    private var sortKeyBinding: Binding<ArchiveModel.ArtifactSortKey> {
        Binding(get: { activeModel?.sortKey ?? .title }, set: { activeModel?.sortKey = $0 })
    }

    private var sortAscendingBinding: Binding<Bool> {
        Binding(
            get: { activeModel?.sortAscending ?? true }, set: { activeModel?.sortAscending = $0 })
    }

    /// File ▸ Open Recent — the persisted recent archives, plus Clear Menu.
    /// Disabled (showing only a dimmed Clear) when there are none.
    @ViewBuilder
    private var openRecentMenu: some View {
        let recents = bookmarks.recentURLs()
        Menu("Open Recent") {
            ForEach(recents, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { openRecent(url) }
            }
            if !recents.isEmpty {
                Divider()
                Button("Clear Menu") { bookmarks.clearRecents() }
            }
        }
        .disabled(recents.isEmpty)
    }

    /// Reopens a recent archive: re-derives access from its bookmark, then opens a
    /// window for it (the value group de-duplicates, so a recent that's already
    /// open just focuses its window). A bookmark that no longer resolves still
    /// opens a window — which then shows the "can no longer reach this archive"
    /// state — and `resolve` prunes the dead entry from the menu.
    private func openRecent(_ url: URL) {
        // `reopenRecent` re-derives access + bumps Recent (the shared policy); the
        // value group de-dups so a recent that's already open just focuses its window.
        openWindow(value: ArchiveAccessStore.shared.reopenRecent(url))
    }

    /// Create-on-disk, then open a window for the new archive. The window opens
    /// the just-created package itself (uniform with every other open path).
    private func newArchive() {
        guard let location = ArchiveLauncher.newArchiveLocation() else { return }
        do {
            openWindow(value: try ArchiveLauncher.create(at: location))
        } catch {
            presentFailure("Couldn't create the archive.", error)
        }
    }

    private func openArchive() {
        guard let url = ArchiveLauncher.openPanelURL() else { return }
        // Acquire on the original scoped URL; canonicalize only the window value.
        ArchiveAccessStore.shared.acquire(url)
        openWindow(value: url.canonicalArchiveURL)
    }

    /// A `Commands` body isn't a view, so it can't host a SwiftUI `.alert`;
    /// surface the rare create failure with an AppKit alert instead.
    private func presentFailure(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = (error as? ArchiveError)?.description ?? String(describing: error)
        alert.runModal()
    }
}

/// A View-menu tab item: a checkmark on the tab that is showing, and ⌘1–⌘4 (G2).
private struct TabMenuItem: View {
    let tab: ArchiveTab
    let model: ArchiveModel?

    var body: some View {
        let command = ArchiveCommand.showTab(tab)
        let context = model?.commandContext(for: command) ?? CommandContext()
        Toggle(
            command.title,
            isOn: Binding(
                get: { context.hasArchive && context.activeTab == tab },
                set: { _ in
                    if NSApp.keyWindowIsUnderModal {
                        NSSound.beep()
                    } else {
                        model?.perform(command)
                    }
                })
        )
        .keyboardShortcut(command.shortcut)
        .disabled(!context.isAvailable(command))
    }
}

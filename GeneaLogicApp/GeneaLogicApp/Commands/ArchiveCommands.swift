import AppKit
import GeneaLogicArchive
import SwiftUI

/// The File-menu commands. New/Open present AppKit panels and then open a window
/// for the result, so they work with **no window present** (no `ensureWindow`
/// dance — that was slice 3's workaround, now unnecessary). Add Media targets
/// whichever archive window is key, via `@FocusedValue`.
struct ArchiveCommands: Commands {
    @Environment(\.openWindow) private var openWindow
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
            // ⌘I stays Add Artifact; the inspector toggle takes ⌘⌥I in the View menu
            // (Finder/Calendar/Pages precedent). "Add Artifact" (was "Add Media") names
            // it distinctly from attaching files to an existing artifact.
            // Adding an artifact is an Artifacts-tab action — gated to it so it can't
            // silently create + select an artifact on a tab the user isn't looking at.
            Button("Add Artifact…") { activeModel?.beginAddMedia() }
                .keyboardShortcut("i", modifiers: [.command])
                .disabled(!isArtifactsTab)

            Button("Verify Integrity…") { activeModel?.beginVerifyIntegrity() }
                .disabled(activeModel?.archive == nil)

            Button("Show Trash…") { activeModel?.beginShowTrash() }
                .disabled(activeModel?.archive == nil)
        }

        viewMenuAdditions
        artifactMenu
    }

    // MARK: - View menu (inspector toggle + sort)

    /// Adds the inspector toggle and Sort By submenu to the standard **View** menu
    /// (after its Show Sidebar item). Sort binds straight to the focused model's
    /// `sortKey`/`sortAscending`; the inspector toggle is a one-shot intent the
    /// detail view acts on (it owns the inspector's `@SceneStorage` visibility).
    private var viewMenuAdditions: some Commands {
        CommandGroup(after: .sidebar) {
            Button(inspectorLabel) { activeModel?.requestInspectorToggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(!hasArtifactContext)

            Menu("Sort By") {
                // Same two pickers as the sidebar Sort menu (shared `SortPickers`).
                SortPickers(key: sortKeyBinding, ascending: sortAscendingBinding)
            }
            // Sort drives the Artifacts browse list only, so gate it to that tab
            // (the People list sorts independently by name).
            .disabled(!isArtifactsTab)
        }
    }

    // MARK: - Artifact menu

    /// A new top-level **Artifact** menu gathering the artifact-scoped verbs that
    /// previously lived only as in-pane buttons. Each verb is a one-shot intent the
    /// detail view performs against the mirrored selection (Attach and Delete route
    /// through their own model entry points). The whole group disables with no
    /// selection; the Selected File submenu disables with no file selected.
    private var artifactMenu: some Commands {
        CommandMenu("Artifact") {
            Group {
                Button("Add Event…") { activeModel?.requestArtifactCommand(.addEvent) }
                Button("Add Place…") { activeModel?.requestArtifactCommand(.addPlace) }
                Button("Add Person…") { activeModel?.requestArtifactCommand(.addPerson) }
                Button("Edit Transcript…") { activeModel?.requestArtifactCommand(.editTranscript) }
                // Straight to the file importer (like File ▸ Add Artifact…), *not* the
                // Continuity connected-menu path: an AppKit `popUpContextMenu` invoked from
                // a menu-bar command has no anchor view and floats as a disconnected menu.
                // Continuity scanning stays on the in-pane paperclip / toolbar +, where the
                // connected menu anchors correctly.
                Button("Attach File…") {
                    if let id = activeModel?.selectedArtifact { activeModel?.beginAttach(to: id) }
                }
            }
            .disabled(!hasArtifactContext)

            Menu("Selected File") {
                // Disable each item (not just the `Menu`): AppKit grays a submenu's
                // *title* only when all its child items are individually disabled, so a
                // `.disabled` on the `Menu` alone leaves "Selected File" looking active.
                Group {
                    Button("Open in Separate Window") {
                        activeModel?.requestFileCommand(.openSeparateWindow)
                    }
                    Button("Open in Default App") {
                        activeModel?.requestFileCommand(.openInDefaultApp)
                    }
                    Button("Save a Copy…") { activeModel?.requestFileCommand(.saveCopy) }
                    Divider()
                    Button("Replace…") { activeModel?.requestFileCommand(.replace) }
                    Button("Delete File…", role: .destructive) {
                        activeModel?.requestFileCommand(.delete)
                    }
                }
                .disabled(activeModel?.selectedFile == nil || !hasArtifactContext)
            }

            Divider()

            // ⌘⌫ mirrors Finder's Move to Trash — and our delete is trash-backed
            // (slice 20), so it's literally that. The list raises the same confirm
            // its own ⌫ / context-menu delete uses.
            Button("Delete Artifact…", role: .destructive) {
                activeModel?.requestDeleteSelectedArtifact()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(!hasArtifactContext)
        }
    }

    /// Whether an artifact-scoped command should be enabled: an artifact is selected
    /// **and** the Artifacts tab is the one showing (so a stale selection under the
    /// People/Tree tab doesn't leave the Artifact menu live).
    private var hasArtifactContext: Bool {
        activeModel?.selectedArtifact != nil && activeModel?.activeTab == .artifacts
    }

    /// Whether an Artifacts-tab command that doesn't need a selection (Add Artifact,
    /// Sort By) should be enabled: an archive is open **and** that tab is showing.
    private var isArtifactsTab: Bool {
        activeModel?.archive != nil && activeModel?.activeTab == .artifacts
    }

    /// The View-menu toggle's label, reflecting the focused window's inspector state.
    private var inspectorLabel: String {
        (activeModel?.inspectorVisible ?? true) ? "Hide Inspector" : "Show Inspector"
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
        guard let url = ArchiveLauncher.savePanelURL() else { return }
        do {
            _ = try Archive.create(at: url)
            // Create/acquire on the original scoped URL; canonicalize only the window
            // value (canonicalizing before acquire would strip the security scope).
            ArchiveAccessStore.shared.acquire(url)
            openWindow(value: url.canonicalArchiveURL)
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

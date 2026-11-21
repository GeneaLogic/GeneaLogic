import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI
import UniformTypeIdentifiers

/// Hosts one open archive in its window: builds the per-window `ArchiveModel`
/// from the window's URL, publishes it to the File menu via `focusedSceneValue`,
/// releases its security scope on close, and owns the single add-media importer.
struct ArchiveContainerView: View {
    let url: URL
    @State private var model: ArchiveModel
    /// The selected artifact, persisted **per window** via scene storage so it's
    /// restored alongside the window on relaunch (slice 18) — it rides the same
    /// state-restoration machinery as the window itself (slice 12). Stored as the
    /// id's raw string (`@SceneStorage` can't hold `ArtifactID?` directly); empty
    /// means no selection. Bridged to an `ArtifactID?` binding by `selection`.
    @SceneStorage("selectedArtifactID") private var selectedArtifactID: String = ""
    /// The selected person, persisted per window (the People-tab analog of
    /// `selectedArtifactID`) — restored alongside the window on relaunch. Empty
    /// means no selection; bridged to a `PersonID?` binding by `personSelection`.
    @SceneStorage("selectedPersonID") private var selectedPersonID: String = ""
    /// The selected worklist row in the Review section, persisted per window like the
    /// other two selections. Stored as `ReviewItem.ID` (the mention's
    /// `artifact|localRef` address) — a mention has no uid of its own, and the address is
    /// what every write path takes anyway. Empty means no selection.
    @SceneStorage("selectedReviewItemID") private var selectedReviewItemID: String = ""
    /// The active window tab, persisted per window, so a relaunch restores the tab
    /// you were on. Stored as the enum's raw value; bridged by `tab`.
    @SceneStorage("selectedTab") private var selectedTabRaw: String = ArchiveTab.artifacts.rawValue
    /// Whether People was last shown as a tree, per window, so a person row clicked from
    /// another area returns to that view (slice 84). Kept by `tab`'s setter.
    @SceneStorage("peopleShowsTree") private var peopleShowsTree = false
    /// This window's undo manager, handed to the model so its mutations register
    /// undo/redo on the window's own stack (undo is per-archive-window).
    @Environment(\.undoManager) private var undoManager
    /// Dismisses this window when it turns out to be a duplicate of one already
    /// showing this archive (see the `claimWindow` guard in `.task`).
    @Environment(\.dismiss) private var dismiss
    /// This window's identity in the single-window-per-archive registry. A duplicate
    /// window (a belt-and-suspenders case behind `ArchiveOpenCoordinator`, slice 31)
    /// fails to claim the archive's slot and dismisses itself.
    @State private var windowToken = UUID()

    /// An `ArtifactID?` view over the scene-stored raw id, handed down to the list
    /// and detail. The detail resolves it against `model.artifacts` only when
    /// rendering, so a stored id whose artifact is gone (deleted between sessions)
    /// simply falls back to the placeholder.
    private var selection: Binding<ArtifactID?> {
        Binding(
            get: { selectedArtifactID.isEmpty ? nil : ArtifactID(selectedArtifactID) },
            set: { selectedArtifactID = $0?.raw ?? "" }
        )
    }

    /// A `PersonID?` view over the scene-stored raw id, handed to the People tab.
    private var personSelection: Binding<PersonID?> {
        Binding(
            get: { selectedPersonID.isEmpty ? nil : PersonID(selectedPersonID) },
            set: { selectedPersonID = $0?.raw ?? "" }
        )
    }

    /// A `ReviewItem.ID?` view over the scene-stored raw value, handed to the Review
    /// section. Resolved against the worklist only when rendering, so a stored row whose
    /// mention has since been resolved falls back to the placeholder.
    private var reviewSelection: Binding<ReviewItem.ID?> {
        Binding(
            get: { selectedReviewItemID.isEmpty ? nil : selectedReviewItemID },
            set: { selectedReviewItemID = $0 ?? "" }
        )
    }

    /// An `ArchiveTab` view over the scene-stored raw value, driving the tab bar.
    private var tab: Binding<ArchiveTab> {
        Binding(
            get: { ArchiveTab(rawValue: selectedTabRaw) ?? .artifacts },
            set: { tab in
                selectedTabRaw = tab.rawValue
                if tab.section == .people { peopleShowsTree = tab == .tree }
            }
        )
    }

    init(url: URL) {
        self.url = url
        _model = State(initialValue: ArchiveModel(url: url))
    }

    var body: some View {
        @Bindable var model = model
        content(model)
            .frame(
                minWidth: Layout.ArchiveWindow.minWidth, minHeight: Layout.ArchiveWindow.minHeight
            )
            .environment(model)
            .focusedSceneValue(\.archiveModel, model)
            .navigationTitle(url.deletingPathExtension().lastPathComponent)
            .navigationDocument(url)
            .task {
                // Claim the single window slot for this archive. `ArchiveOpenCoordinator`
                // defers a Finder-open past restoration so a restored window is always
                // registered first; this is the safety net — a stray duplicate (always
                // the later, post-restoration one) finds the slot taken and dismisses
                // itself rather than lingering as a second window (slice 31).
                // `claimWindow` is synchronous, so this runs before `load()`.
                guard ArchiveAccessStore.shared.claimWindow(url, token: windowToken) else {
                    dismiss()
                    return
                }
                model.load()

                // Notice another writer (slice 51): poll for an external change
                // for as long as this window lives. Deliberately *inside* this
                // task, after the duplicate-window guard above — a window that
                // dismissed itself has already returned and never starts
                // polling. As a sibling `.task` it would poll regardless, saved
                // only by `model.archive` happening to be nil (review finding).
                //
                // A `.task` rather than a `Timer` so the loop is cancelled with
                // the window; a stray timer keeping a closed window's model
                // alive is the classic form of this bug. The model chooses each
                // delay — see `nextExternalChangePollDelay`.
                while !Task.isCancelled {
                    try? await Task.sleep(for: model.nextExternalChangePollDelay)
                    guard !Task.isCancelled else { break }
                    model.refreshIfChangedExternally()
                }
            }
            .onAppear { model.undoManager = undoManager }
            .onChange(of: undoManager) { _, manager in model.undoManager = manager }
            // Release the access `acquire`d before this window opened — but only if
            // this window actually owned the archive's slot. A dismissed duplicate
            // never owned it, so it must not revoke the surviving window's scope.
            // **Not until the writes have landed** (52's `/code-review`). Mutations
            // run off the main actor now and can be parked on the archive lock for
            // seconds, so revoking the sandbox scope the moment the window closes
            // could pull the ground from under a write already in progress. The
            // model is captured here and outlives the view, so the task completes
            // even though the window is gone.
            .onDisappear {
                if ArchiveAccessStore.shared.resignWindow(url, token: windowToken) {
                    let model = model
                    Task {
                        await model.writesSettled()
                        ArchiveAccessStore.shared.release(url)
                    }
                }
            }
            .alert("Error", isPresented: $model.isShowingError) {
                // A refused scan is kept rather than lost (slice 67); this is the
                // only way back to it.
                let kept = model.keptScans
                if !kept.isEmpty {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(kept)
                    }
                }
                Button("OK") {}
            } message: {
                Text(model.errorMessage)
            }
            // Benign-info channel (metadata-scan results, can't-restore notices, …);
            // the title travels with the message so the heading is never wrong.
            .alert(model.actionInfoTitle, isPresented: $model.isShowingInfo) {
                Button("OK") {}
            } message: {
                Text(model.actionInfo ?? "")
            }
            // The integrity panel (File ▸ Verify Integrity…). The sheet modifier
            // sits *outside* the `.environment(model)` above, so the presented
            // content wouldn't inherit it — inject the model explicitly.
            .sheet(isPresented: $model.isShowingIntegrityReport) {
                IntegrityReportSheet()
                    .environment(model)
            }
            // The trash panel (File ▸ Show Trash…). Same env-injection caution as the
            // integrity sheet — the modifier sits outside `.environment(model)` above.
            .sheet(isPresented: $model.isShowingTrash) {
                TrashSheet()
                    .environment(model)
            }
            // The single shared add-media importer (open-archive is handled at the
            // welcome screen / File menu, never here, so there's only one importer
            // live in this hierarchy). Drag-and-drop is the other ingest path.
            // Shared between Add Media (new artifacts) and Attach File… (attach to
            // the selected artifact); `model.importMode` decides which on completion.
            .fileImporter(
                isPresented: $model.isImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    model.handleImport(urls)
                case .failure(let error):
                    model.actionError = String(describing: error)
                }
            }
    }

    @ViewBuilder
    private func content(_ model: ArchiveModel) -> some View {
        if model.archive != nil {
            OpenArchiveView(
                selection: selection, personSelection: personSelection,
                reviewSelection: reviewSelection, tab: tab, peopleShowsTree: peopleShowsTree)
        } else if let openError = model.openError {
            ContentUnavailableView {
                Label("Couldn't Open Archive", systemImage: "exclamationmark.triangle")
            } description: {
                Text(openError)
            }
        } else {
            ProgressView("Opening…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The open-archive window: **one `NavigationSplitView`, sidebar | item, on every area**
/// (slice 84). The sidebar's sections are Review, Artifacts and People
/// (`ArchiveSidebar`); the area is where the selection is, and the detail shows that
/// area's item. Tree is a view of People, switched by a List | Tree control in the
/// toolbar, the tree taking the detail and the people selection its focus.
///
/// Not a window-level `TabView` (slice 41): a top `TabView` displaces the split view's
/// title, sidebar toggle and search field. The area is mirrored to the model so the
/// menu bar scopes its commands by area.
private struct OpenArchiveView: View {
    @Environment(ArchiveModel.self) private var model
    @Binding var selection: ArtifactID?
    @Binding var personSelection: PersonID?
    @Binding var reviewSelection: ReviewItem.ID?
    @Binding var tab: ArchiveTab
    let peopleShowsTree: Bool
    /// The window's Continuity Camera scanner. Owned here so its receiver lives in
    /// this window's responder chain (hosted zero-size below) and handed to the
    /// model so the toolbar/detail scan actions can reach it.
    @State private var scanner = ContinuityCameraScanner()
    /// Whether the sidebar's search field has focus, for Edit ▸ Find… (slice 82).
    @FocusState private var isSearchFocused: Bool
    /// Whether the sidebar is showing, bound so Edit ▸ Find… can show a hidden one: its
    /// search field can't take focus while it is hidden. Per window, like the toggle.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Per-window, per-session dismissal of the damage banner (slice 56). Not
    /// persisted on purpose: one click must not silence damage that is still
    /// there, so it comes back on the next open. The pinned placeholder rows
    /// stay regardless, which is what makes dismissing it safe at all.
    @State private var isDamageBannerDismissed = false
    /// Bumped for each switch of area the sidebar didn't make (⌘1–⌘4, a jump), so it
    /// brings the area's selection into view. A click in the sidebar needs no reveal.
    @State private var revealRequest = 0

    var body: some View {
        @Bindable var model = model
        content
            // "Another process is writing" (slice 52). A bottom inset rather than
            // an alert or a sheet because it must not interrupt: the window stays
            // usable throughout, and the wait usually ends before this is even
            // shown (`ArchiveModel.waitIndicatorDelay`).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isWaitingOnAnotherProcess {
                    WaitingForAnotherProcessBar()
                }
            }
            // A change still arriving from another machine (slice 61). Between
            // the wait bar and the damage banner on purpose: it belongs with the
            // transient, self-clearing things, and putting it *above* the damage
            // banner leaves 56/57's hand-tested bottom edge where it was.
            //
            // **Not the damage banner, and not its voice.** Reusing
            // `StandingDamageBanner` would say "your data is in trouble" about a
            // sync in progress, which is the exact conflation slice 60 spent
            // three rounds removing.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let incomingChange = model.incomingChange {
                    IncomingChangeBar(
                        change: incomingChange,
                        onVerify: { model.isShowingIntegrityReport = true })
                }
            }
            // Damage the archive already knows about (slice 56), pinned to the
            // window rather than to a tab because it is a statement about the
            // archive rather than about what you are looking at.
            //
            // **At the bottom, and that is not a preference.** A top
            // `safeAreaInset` here displaces the sidebar's `.searchable` field —
            // the Artifacts list silently lost "Search artifacts" while the
            // banner was up, which only showed up next to a healthy window. The
            // bottom edge already carries the wait bar and costs nothing; the
            // in-place signal is the pinned rows, which is where someone looking
            // for a missing record actually looks.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.hasStandingDamage && !isDamageBannerDismissed {
                    StandingDamageBanner(
                        findings: model.standingFindings,
                        otherRecords: model.unreadableOthers,
                        sweep: model.fileDamage,
                        onVerify: { model.isShowingIntegrityReport = true },
                        onDismiss: { isDamageBannerDismissed = true }
                    )
                }
            }
            // A dismissal answers the findings that were on screen when it was
            // clicked, and nothing later (review finding, 56). Without this, damage
            // arriving after a dismissal is silent for the rest of the window's
            // life — and for a relationship or link, which has no placeholder row
            // to fall back on, silent altogether.
            .onChange(of: model.standingFindings) { _, _ in
                isDamageBannerDismissed = false
            }
            // The same rule for 57's findings, which need it more: a missing file
            // has no placeholder row anywhere, so a stale dismissal would hide it
            // completely.
            .onChange(of: model.fileDamage) { _, _ in
                isDamageBannerDismissed = false
            }
            .toolbar {
                // No area switcher (slice 84): the sidebar is the areas. People's two
                // views are one control, shown only on People.
                if tab.section == .people {
                    ToolbarItem(placement: .principal) {
                        Picker("People View", selection: $tab) {
                            Label("List", systemImage: "list.bullet").tag(ArchiveTab.people)
                            Label("Tree", systemImage: ArchiveTab.tree.systemImage)
                                .tag(ArchiveTab.tree)
                        }
                        .pickerStyle(.segmented)
                        .labelStyle(.titleAndIcon)
                        .help("Show the people as a list or as a tree")
                    }
                }
                // Both creates, on every area (slice 84's hand-test): the sidebar shows both
                // collections everywhere, and a create switches to its own area once it lands.
                ToolbarItemGroup {
                    // One connected menu (Add Artifact… + Continuity scan options), shown by
                    // the AppKit receiver — a plain SwiftUI `Menu` can't host the
                    // auto-inserted scan items, so this button pops that menu.
                    CommandToolbarButton(command: .addArtifact) { model.beginAddOrScan() }
                    CommandToolbarButton(command: .newPerson)
                }
            }
            // The scanner's responder-chain receiver, hosted zero-size in the window
            // (scanning is an Artifacts action, but the host is harmless on any tab).
            .background {
                ContinuityCameraHost(scanner: scanner)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
            // Same env-injection caution as the container's sheets: the presented
            // content is a new hierarchy, so inject the model on the sheet explicitly.
            .sheet(isPresented: $model.isCreatingPerson) {
                NewPersonSheet()
                    .environment(model)
            }
            .onAppear {
                model.continuityScanner = scanner
                model.activeTab = tab
                // Seed the menu-bar's artifact-selection mirror (only meaningful on
                // the Artifacts tab), so the Artifact menu is correctly enabled.
                model.selectedArtifact = tab == .artifacts ? selectedArtifact?.uid : nil
                model.selectedPerson = tab.section == .people ? selectedPerson?.uid : nil
                // Review's section is always in the sidebar, so its count is owed from
                // the start (slice 84): the worklist now, and the duplicates scan in the
                // background, the header showing an ellipsis until it lands. From here
                // `refresh()` keeps the worklist current, and a merge or delete re-scans.
                model.refreshReviewWorklist()
                model.refreshDuplicateCandidates()
            }
            .onChange(of: tab) { _, newTab in
                model.activeTab = newTab
                // Re-seed / clear the mirror as the tab changes so the Artifact menu
                // never acts on a stale selection from another section.
                model.selectedArtifact = newTab == .artifacts ? selectedArtifact?.uid : nil
                // People's on the tree too, which runs the Person menu (84's hand-test).
                model.selectedPerson = newTab.section == .people ? selectedPerson?.uid : nil
                model.selectedFile = nil
                // Re-scan the duplicates lane on entering Review, as before slice 84: its
                // scores read records a person's summary doesn't show (a name added), so
                // `refresh()`'s check on the people can't see every change that moves them.
                if newTab == .review { model.refreshDuplicateCandidates() }
            }
            // Mirror the resolved artifact selection down for the menu bar (F6). Key
            // off `selectedArtifact` (not the raw id) so deleting the selection clears
            // the mirror instead of leaving it on a ghost.
            .onChange(of: selectedArtifact?.uid) { _, resolvedID in
                guard tab == .artifacts else { return }
                model.selectedArtifact = resolvedID
                model.selectedFile = nil
            }
            // The same for the Person menu (slice 82).
            .onChange(of: selectedPerson?.uid) { _, resolvedID in
                guard tab.section == .people else { return }
                model.selectedPerson = resolvedID
            }
            // Edit ▸ Find… (slice 82). A hidden sidebar is shown first, and the field
            // focused once the column is back.
            .onChange(of: model.pendingCommand) {
                guard model.claimPendingCommand({ $0 == .find }) != nil else { return }
                if columnVisibility == .detailOnly {
                    columnVisibility = .all
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        isSearchFocused = true
                    }
                } else {
                    isSearchFocused = true
                }
            }
            // View ▸ ⌘1–⌘4, and a create switching to its own area once it lands.
            .onChange(of: model.pendingTab) { _, target in
                if let target {
                    // Going to Review ends a search (84's hand-test): Review's rows aren't
                    // search results, so its section hides while one is on, and the row
                    // the window opens on would be nowhere in the sidebar.
                    if target == .review, !model.searchText.trimmed.isEmpty { model.endSearch() }
                    tab = target
                    model.pendingTab = nil
                    revealRequest += 1
                }
            }
            // Auto-select a freshly-created artifact / person (slice 29 + its People
            // analog): the model publishes a one-shot intent; move the scene-stored
            // selection there and clear it.
            // Revealed too, when its area is showing: a new row can sort off-screen. (A
            // create from another area switches once the record exists, and that switch
            // reveals it.)
            .onChange(of: model.lastCreatedArtifact) { _, created in
                if let created {
                    selection = created
                    model.lastCreatedArtifact = nil
                    if tab == .artifacts { revealRequest += 1 }
                }
            }
            .onChange(of: model.lastCreatedPerson) { _, created in
                if let created {
                    personSelection = created
                    model.lastCreatedPerson = nil
                    if tab.section == .people { revealRequest += 1 }
                }
            }
            // Cross-tab jump from a resolved-mention chip: switch to the People tab and
            // select the linked person (slice 42). Unlike the create intent above, this
            // also moves `tab`.
            .onChange(of: model.pendingPersonNavigation) { _, target in
                if let target {
                    tab = .people
                    personSelection = target
                    model.pendingPersonNavigation = nil
                    revealRequest += 1
                }
            }
            // Show in Tree and Focus Here (slice 83). The focus is the person selection.
            .onChange(of: model.pendingTreeFocus) { _, target in
                if let target {
                    tab = .tree
                    personSelection = target
                    model.pendingTreeFocus = nil
                    revealRequest += 1
                }
            }
            // The mirror jump: a person Sources row → switch to the Artifacts tab and
            // select the citing artifact (slice 42b).
            .onChange(of: model.pendingArtifactNavigation) { _, target in
                if let target {
                    tab = .artifacts
                    selection = target
                    model.pendingArtifactNavigation = nil
                    revealRequest += 1
                }
            }
    }

    private var content: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            ArchiveSidebar(
                selection: sidebarSelection, revealRequest: revealRequest,
                isSearchFocused: $isSearchFocused
            )
            .navigationSplitViewColumnWidth(
                min: Layout.ArchiveWindow.sidebarMinWidth,
                ideal: Layout.ArchiveWindow.sidebarIdealWidth)
        } detail: {
            detail
        }
        .modifier(ReviewCommandHost(selection: $reviewSelection))
        // Drag-in ingest, from any area: a create, so it switches to Artifacts once the
        // artifact exists (`commitIngest`).
        .dropDestination(for: URL.self) { urls, _ in
            model.ingest(urls)
            return true
        }
    }

    /// The area and its three selections as the sidebar's one value.
    private var sidebarSelection: Binding<SidebarSelection> {
        Binding(
            get: {
                SidebarSelection(
                    area: tab, artifact: selection, person: personSelection,
                    review: reviewSelection, peopleShowsTree: peopleShowsTree)
            },
            set: { new in
                if new.area != tab { tab = new.area }
                if new.artifact != selection { selection = new.artifact }
                if new.person != personSelection { personSelection = new.person }
                if new.review != reviewSelection { reviewSelection = new.review }
            })
    }

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .artifacts:
            if let selectedArtifact {
                ArtifactDetailView(artifact: selectedArtifact)
            } else {
                ArtifactDetailPlaceholder()
            }
        case .people:
            if let selectedPerson {
                PersonDetailView(personID: selectedPerson.uid)
            } else {
                PersonDetailPlaceholder()
            }
        case .review:
            reviewDetail
        case .tree:
            // People as a tree: the people selection is its focus, so picking someone in
            // the sidebar refocuses it.
            TreeTab(focus: $personSelection)
                // The Person menu's adds, whose sheets the person's page owns elsewhere.
                .modifier(TreePersonAdds())
        }
    }

    /// Two lanes share one sidebar and one selection, so the pane is chosen by which
    /// worklist claims the selected id (the ids are lane-prefixed — `ReviewSelection`).
    ///
    /// **Each pane is identified by its row** (`.id`), so a new row gets a new pane at the
    /// top of its scroll view. Reused, a pane kept the last row's offset, and the next row
    /// could open scrolled past its header and the top candidate the keys act on.
    @ViewBuilder
    private var reviewDetail: some View {
        if let selectedReviewItem {
            ReviewDetailView(item: selectedReviewItem)
                .id(selectedReviewItem.id)
        } else if let selectedFactItem {
            ReviewFactsDetailView(item: selectedFactItem)
                .id(selectedFactItem.id)
        } else if let selectedRelationshipItem {
            ReviewRelationshipDetailView(item: selectedRelationshipItem)
                .id(selectedRelationshipItem.id)
        } else if let selectedDuplicateItem {
            ReviewDuplicateDetailView(item: selectedDuplicateItem)
                .id(selectedDuplicateItem.id)
        } else {
            ReviewDetailPlaceholder(
                hasWork: !model.reviewItems.isEmpty || !model.factItems.isEmpty
                    || !model.relationshipItems.isEmpty || !model.duplicateItems.isEmpty)
        }
    }

    /// Resolves the selected id against *all* artifacts (not the filtered list), so an
    /// active search narrowing the sidebar doesn't blank the detail pane.
    private var selectedArtifact: ArtifactSummary? {
        guard let selection else { return nil }
        return model.artifacts.first { $0.uid == selection }
    }

    /// Resolves the selected id against the full person list, likewise.
    private var selectedPerson: PersonSummary? {
        guard let personSelection else { return nil }
        return model.persons.first { $0.uid == personSelection }
    }

    /// Resolves the selected worklist row against the current worklist. A row whose
    /// mention has since been resolved (by a confirm here, or by the resolve sheet on the
    /// Artifacts side) simply isn't there any more, so it is never rendered as a decision
    /// still to make. `ReviewCommandHost` usually moves the selection to the next row
    /// first; the placeholder shows at the end of the list, before Possible Duplicates, or
    /// for a selection whose row hasn't been computed yet.
    private var selectedReviewItem: ReviewItem? {
        guard let reviewSelection else { return nil }
        return model.reviewItems.first { $0.id == reviewSelection }
    }

    /// The facts lane's half of the same resolution: a person whose last suggestion has
    /// just been recorded simply isn't in the list any more, so their pane never shows an
    /// empty section.
    private var selectedFactItem: FactReviewItem? {
        guard let reviewSelection else { return nil }
        return model.factItems.first { $0.id == reviewSelection }
    }

    /// The relationships lane's half. An edge that has since been recorded (or declined)
    /// leaves the list, so its pane never offers a conclusion the archive already holds.
    private var selectedRelationshipItem: RelationshipReviewItem? {
        guard let reviewSelection else { return nil }
        return model.relationshipItems.first { $0.id == reviewSelection }
    }

    /// The duplicates lane's half. A pair that has since been merged or dismissed leaves
    /// the list, so its pane never offers a merge of a record that no longer exists.
    private var selectedDuplicateItem: DuplicateReviewItem? {
        guard let reviewSelection else { return nil }
        return model.duplicateItems.first { $0.id == reviewSelection }
    }
}

/// The non-modal strip that appears when a write is waiting on another process
/// (slice 52).
///
/// **Deliberately not a blocking affordance.** The window is fully usable while
/// this is up — the whole point of moving mutations off the main actor is that
/// the wait costs responsiveness nothing. It exists so a multi-second pause
/// reads as "someone else is writing" rather than as the app having lost the
/// edit. If the wait outlasts `ArchiveLock.timeout`, the mutation fails with
/// `archiveBusy` and the ordinary error alert takes over from here.
/// The window-level notice that this archive has damage it already knows about
/// (slice 56) — shown without anyone running Verify Integrity, because everything
/// in it was already recorded in `.index/` and costs nothing to read.
///
/// **It reports only what it can stand behind.** Unreadable records it can count
/// exactly. An interrupted write it can only report as *some* file possibly being
/// behind its recorded hash — naming which one needs the full hash pass, which is
/// why the button offers that rather than pretending to more precision.
private struct StandingDamageBanner: View {
    let findings: Archive.StandingFindings
    /// Unreadable records with no browse list of their own — relationships,
    /// links, dismissals. The artifact and person ones have pinned rows in their
    /// lists, so the banner doesn't re-enumerate them.
    let otherRecords: [UnreadableRecordRow]
    /// What the cheap sweep found, or `nil` — which is the *only* thing a clean
    /// sweep produces (slice 57). Tracked files have no browse list of their own,
    /// so like `otherRecords` above, this banner is the one place they are named.
    /// `StandingDamageWording` adds the vanished records the sweep hasn't seen.
    let sweep: FileDamageSummary?
    let onVerify: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(wording.headline)
                    .font(.callout)
                if let detail = wording.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // **Capped, because a banner is not a list.** Unbounded,
                        // three damaged files wrapped to seven lines in a narrow
                        // window and the banner took a third of it (found by
                        // running the app, slice 57). Two lines still names the
                        // first file or two in full; the hover text below has
                        // every path, and Verify Integrity has the rest.
                        .lineLimit(2)
                        .help(wording.fileDamage?.pathTooltip ?? "")
                }
            }
            Spacer(minLength: 8)
            Button("Verify Integrity…", action: onVerify)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide this until the archive is opened again.")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }

    private var wording: StandingDamageWording {
        StandingDamageWording(findings: findings, otherRecords: otherRecords, sweep: sweep)
    }
}

/// The window's word that a change from another machine is still landing
/// (slice 61).
///
/// **Quiet by construction.** No count, no file names, no octagon, and no
/// dismiss control: it ends by itself, and a dismiss button would imply
/// otherwise. What it can honestly say is that the archive is waiting — so it
/// looks like the wait bar above it, which is the other thing in this window
/// that means "this will resolve on its own".
private struct IncomingChangeBar: View {
    let change: IncomingChange
    let onVerify: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The spinner *is* the claim of progress, so it goes when the claim
            // does; the stalled state gets the Verify panel's own arrival symbol
            // instead, in secondary rather than a warning tint.
            if change == .stalled {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(change.headline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail = change.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if change.offersVerify {
                Button("Verify Integrity…", action: onVerify)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}

private struct WaitingForAnotherProcessBar: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for another process to finish writing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

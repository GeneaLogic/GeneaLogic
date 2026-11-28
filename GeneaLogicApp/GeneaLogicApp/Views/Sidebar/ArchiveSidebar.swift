import AppKit
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The window's one sidebar (slice 84): **Review, Artifacts and People** as collapsible
/// sections of one list, each an area's collection, and the **Trash** pinned below the
/// list (slice 86), always in view: a delete asks nothing, so where it went must not
/// scroll away (86's hand-test). Selecting a row sets the area (`SidebarSelection`); the
/// detail column shows that area's item.
///
/// The Trash is a button drawn as a sidebar row, a Tab stop of its own. The arrow keys
/// don't cross from the main list into it, as they don't reach a Finder sidebar's footer;
/// a click, Tab and Space, or File ▸ Show Trash does.
///
/// **Why one sidebar** ([#39](https://github.com/GeneaLogic/GeneaLogic/issues/39)): the
/// area was a toolbar control and its collection the sidebar, so the switcher read as,
/// and was laid out as, a control on the detail column, and moved with it. A third
/// column of areas left the document 30 pt at the window's minimum width with the
/// inspector open; this keeps what the two-column window had.
///
/// One search field filters Artifacts and People. **Review's section and the Trash row
/// hide while a search is active**, so the results start at the top and nothing
/// unfiltered sits among them: the worklist was never searchable, because filtering work
/// owed hides it, and the trash isn't searched.
struct ArchiveSidebar: View {
    @Environment(ArchiveModel.self) private var model
    @Binding var selection: SidebarSelection
    /// Changed by the window for each switch of area the sidebar didn't make (⌘1–⌘4, a
    /// jump), which brings the area's selection into view (`SidebarReveal`).
    let revealRequest: Int
    var isSearchFocused: FocusState<Bool>.Binding

    /// How this archive's window was left (slice 85), which keeps which sections are
    /// open.
    @Environment(ArchiveWindowState.self) private var windowState

    private var reviewExpanded: Bool {
        get { windowState.reviewExpanded }
        nonmutating set { windowState.reviewExpanded = newValue }
    }

    private var artifactsExpanded: Bool {
        get { windowState.artifactsExpanded }
        nonmutating set { windowState.artifactsExpanded = newValue }
    }

    private var peopleExpanded: Bool {
        get { windowState.peopleExpanded }
        nonmutating set { windowState.peopleExpanded = newValue }
    }

    /// Whether Artifacts is narrowed to the uncatalogued artifacts. Not persisted: it is a
    /// working mode for a cataloguing pass, and a filter that survives a relaunch is one
    /// the user has to remember they left on.
    @State private var uncataloguedOnly = false

    /// The list's own selection, a mirror of `selection.item`. The list drops it when its
    /// row leaves (a search or filter, a collapsed section, Review hiding, a delete), and
    /// `selection` keeps the area's; this puts the highlight back when the row returns.
    /// Bound straight to `selection`, the list's dropped selection never came back:
    /// nothing it reads changed.
    @State private var listSelection: SidebarItem?

    /// Whether the Trash's row has the keyboard focus, which turns its highlight from gray
    /// to the accent, as a list's does.
    @FocusState private var isTrashFocused: Bool

    /// Whether the window is the active one: an inactive window's selections are all gray.
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        // Filtered once per draw: the rows, the header's count, the Filter menu and the
        // reveal all read the same answer.
        let artifacts = ShownArtifacts(
            displayed: model.displayedArtifacts, uncataloguedOnly: uncataloguedOnly)
        let selectedRowShows = selection.item.map { rowShows($0, artifacts: artifacts) } ?? false
        // The Trash, pinned below the list so it stays in view however long the sections
        // run (86's hand-test). Under the list rather than inset into it: an inset drew
        // over the rows, which showed through.
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                list(artifacts)
                    .onChange(of: revealRequest) { reveal(proxy, artifacts: artifacts) }
                    // `List` doesn't follow a selection set from outside, and plenty sets it:
                    // the List | Tree control, a refocus in the tree, Review's keys walking
                    // down the worklist, a record just created. Whatever moved the area or its
                    // selection, the selected row is brought into view, no further than it
                    // has to go — so a row just clicked doesn't move (84's hand-test).
                    .onChange(of: selection.area) { keepSelectionInView(proxy) }
                    .onChange(of: selection.item) { keepSelectionInView(proxy) }
            }
            if !isSearching {
                Divider()
                trashFooter
            }
        }
        // On the sidebar column's root, which keeps it a sidebar field: on a view that
        // isn't the leading column's root it becomes a toolbar field (seen in 84's
        // prototype).
        .searchable(text: searchText, placement: .sidebar, prompt: "Search")
        .searchFocused(isSearchFocused)
        .onChange(of: listSelection) { _, item in
            if let item, item != selection.item { selection.select(item) }
        }
        .onChange(of: selection.item, initial: true) { _, item in
            if listSelection != item { listSelection = item }
        }
        // An open Quick Look panel follows the selection, as Finder's does (slice 87).
        .onChange(of: selection.item) { _, item in
            if case .artifact(let id) = item {
                model.quickLookFollowSelection(id)
            } else {
                model.quickLookFollowSelection(nil)
            }
        }
        // Whatever brought the row back, once it is in the list (84's `/code-review`:
        // restoring on a search alone missed the rest).
        .onChange(of: selectedRowShows) { _, shows in
            guard shows, listSelection == nil, let item = selection.item else { return }
            Task { @MainActor in
                if listSelection == nil, selection.item == item { listSelection = item }
            }
        }
        // **Release the filter, don't just mask it.** When the debt reaches zero the
        // menu stops offering the toggle, which is the only way to turn it off — so the
        // state itself is reset. Left set, it would silently re-collapse the list on the
        // next import, with nothing on screen saying why.
        .onChange(of: artifacts.uncataloguedCount) { _, remaining in
            if remaining == 0 { uncataloguedOnly = false }
        }
    }

    private func list(_ artifacts: ShownArtifacts) -> some View {
        List(selection: $listSelection) {
            if !isSearching {
                Section {
                    if reviewExpanded { reviewRows }
                } header: {
                    header(
                        .review, count: reviewCount,
                        isExpanded: Binding(get: { reviewExpanded }, set: { reviewExpanded = $0 })
                    ) {
                        Button {
                            model.perform(.refreshReview, fromSidebar: true)
                        } label: {
                            Image(systemName: ArchiveCommand.refreshReview.systemImage)
                        }
                        .buttonStyle(.borderless)
                        .help("Re-run the matcher over the archive")
                        .accessibilityLabel("Refresh Review")
                    }
                }
            }
            Section {
                if artifactsExpanded { artifactRows(artifacts) }
            } header: {
                header(
                    .artifacts,
                    count: SidebarCount.text(
                        shown: artifacts.visible.count, of: model.artifacts.count),
                    isExpanded: Binding(get: { artifactsExpanded }, set: { artifactsExpanded = $0 })
                ) {
                    if !model.artifacts.isEmpty {
                        ArtifactFilterMenu(
                            uncataloguedOnly: $uncataloguedOnly,
                            uncataloguedCount: artifacts.uncataloguedCount)
                        SortMenu()
                    }
                }
            }
            Section {
                if peopleExpanded { personRows }
            } header: {
                header(
                    .people,
                    count: SidebarCount.text(
                        shown: model.displayedPersons.count, of: model.persons.count),
                    isExpanded: Binding(get: { peopleExpanded }, set: { peopleExpanded = $0 })
                ) { EmptyView() }
            }
        }
        .listStyle(.sidebar)
        // ⌘C copies the selected row as a line of text (slice 87, fork 2). Scoped to the
        // list's focus, so a text field's Copy is its own.
        .copyable(model.copiedRecords(for: selection.item))
        // Space shows the selected artifact's files in Quick Look, as Finder's does.
        .onKeyPress(.space) {
            guard case .artifact(let id) = selection.item else { return .ignored }
            model.perform(.quickLook, on: .artifact(id), fromSidebar: true)
            return .handled
        }
        // ⌫ does what the context menu does: an artifact moves to the Trash at once
        // (slice 86), a person asks first. On the selected row, so from the tree too.
        .onDeleteCommand {
            switch selection.item {
            case .artifact(let id):
                model.perform(.deleteArtifact, on: .artifact(id), fromSidebar: true)
            case .person(let id):
                model.perform(.deletePerson, on: .person(id), fromSidebar: true)
            case .review, .trash, nil: break
            }
        }
        .modifier(PersonDeleteAndMerge())
    }

    // MARK: - Selection and search

    /// The one field, over both searches: the artifacts' (title, inline transcript and
    /// notes, AND-combined with the tag filter) and the people's.
    private var searchText: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { text in
                model.searchText = text
                model.personSearchText = text
                model.applyFilters()
                model.applyPersonFilter()
            })
    }

    private var isSearching: Bool { !model.searchText.trimmed.isEmpty }

    // MARK: - Review

    private var reviewCount: String {
        SidebarCount.review(model.reviewRows.count, isScanning: model.isScanningDuplicates)
    }

    @ViewBuilder
    private var reviewRows: some View {
        let rows = model.reviewSidebarRows()
        if rows.isEmpty {
            emptyRow("Nothing to review")
        }
        ForEach(rows) { row in
            if let target = row.target {
                ReviewSidebarRowView(row: row)
                    .tag(SidebarItem.review(row.id))
                    .id(SidebarRowID.item(.review(row.id)))
                    .contextMenu { ReviewRowMenu(target: target) }
            } else {
                ReviewSidebarRowView(row: row)
                    .selectionDisabled()
            }
        }
    }

    // MARK: - Artifacts

    private var isFilteringArtifacts: Bool { model.isFiltering || uncataloguedOnly }

    @ViewBuilder
    private func artifactRows(_ shown: ShownArtifacts) -> some View {
        let artifacts = shown.visible
        // A damaged record is not a search result — it has no title to match on, so it
        // can neither match nor fail to match — and a filter that finds nothing must
        // still say so (review finding, 56). The banner still reports them meanwhile.
        if !isFilteringArtifacts {
            unreadableRows(model.unreadableArtifacts)
        }
        if artifacts.isEmpty {
            if isFilteringArtifacts {
                emptyRow("No matches")
            } else if model.unreadableArtifacts.isEmpty {
                // An archive whose only artifact is unreadable must not read as empty.
                emptyRow("No artifacts yet")
            }
        }
        ForEach(artifacts, id: \.uid) { artifact in
            ArtifactRow(summary: artifact)
                .tag(SidebarItem.artifact(artifact.uid))
                .id(SidebarRowID.item(.artifact(artifact.uid)))
                .contextMenu {
                    CommandButton(.quickLook, on: .artifact(artifact.uid), fromSidebar: true)
                    CommandButton(.copyArtifact, on: .artifact(artifact.uid), fromSidebar: true)
                    Divider()
                    CommandButton(.deleteArtifact, on: .artifact(artifact.uid), fromSidebar: true)
                }
        }
    }

    // MARK: - People

    @ViewBuilder
    private var personRows: some View {
        let persons = model.displayedPersons
        if !model.isFilteringPeople {
            unreadableRows(model.unreadablePersons)
        }
        if persons.isEmpty {
            if model.isFilteringPeople {
                emptyRow("No matches")
            } else if model.unreadablePersons.isEmpty {
                emptyRow("No people yet")
            }
        }
        ForEach(persons, id: \.uid) { person in
            PersonRow(summary: person)
                .tag(SidebarItem.person(person.uid))
                .id(SidebarRowID.item(.person(person.uid)))
                .contextMenu {
                    CommandButton(.showInTree, on: .person(person.uid), fromSidebar: true)
                    CommandButton(.mergePerson, on: .person(person.uid), fromSidebar: true)
                    CommandButton(.copyPerson, on: .person(person.uid), fromSidebar: true)
                    Divider()
                    CommandButton(.deletePerson, on: .person(person.uid), fromSidebar: true)
                }
        }
    }

    // MARK: - Trash

    /// The Trash, pinned under the main list: a focusable row drawn as the sidebar's are
    /// (86's hand-test). A one-row list of its own took Tab focus without selecting
    /// anything, and selecting on focus would switch the detail as Tab passed by. A
    /// `Button` was a Tab stop, but never takes focus from a click, so its highlight could
    /// only be the unfocused gray. This takes focus from a click or Tab, as a list does, and
    /// draws the sidebar's own selection (`SidebarSelectionHighlight`): the accent while it
    /// has focus in an active window, gray otherwise. Space and Return open it.
    ///
    /// The count hides at zero, and the icon dims while there is nothing in the can. The
    /// spec kept the icon fixed (fork 2, against `trash.fill`, which reads as decoration);
    /// the hand-test asked for full and empty. A symbol with paper over the rim is #92.
    private var trashFooter: some View {
        let count = model.trashCount
        let isSelected = selection.area == .trash
        let isEmphasized = isSelected && isTrashFocused && appearsActive
        return HStack(spacing: 6) {
            Image(systemName: ArchiveTab.trash.systemImage)
                .foregroundStyle(trashIconStyle(isEmpty: count == 0, emphasized: isEmphasized))
                .frame(width: 20)
            Text(SidebarSection.trash.title)
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(
                        isEmphasized
                            ? AnyShapeStyle(Self.emphasizedText.opacity(0.75))
                            : AnyShapeStyle(.secondary))
            }
        }
        .foregroundStyle(
            isEmphasized ? AnyShapeStyle(Self.emphasizedText) : AnyShapeStyle(.primary)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            if isSelected {
                SidebarSelectionHighlight(isEmphasized: isEmphasized)
                    .clipShape(.rect(cornerRadius: 8, style: .continuous))
            }
        }
        .contentShape(.rect)
        .focusable()
        .focused($isTrashFocused)
        // Selected, the highlight shows the focus, as a list row's does; the ring is for
        // focus on the row while another area shows.
        .focusEffectDisabled(isSelected)
        .onTapGesture { openTrash() }
        .onKeyPress(keys: [.space, .return]) { _ in
            openTrash()
            return .handled
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu { CommandButton(.emptyTrash, on: .archive, fromSidebar: true) }
        // One element, its count in its name (86's hand-test). With the count as a value,
        // VoiceOver read the row as "2 items" and never said "Trash"; named outright, it
        // read the name and dropped the value. Mail's rows say their count the same way.
        // Not a `Button`, so its press is given outright.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.trashAccessibilityLabel(count: count))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { openTrash() }
    }

    /// Selects the Trash and gives its row the focus, as a click in a list does.
    private func openTrash() {
        selection.select(.trash)
        isTrashFocused = true
    }

    /// The can's color: dimmed while empty, in the accent while full, and in the selected
    /// text color (dimmed or not) on the focused highlight, where the accent wouldn't show.
    private func trashIconStyle(isEmpty: Bool, emphasized: Bool) -> AnyShapeStyle {
        switch (emphasized, isEmpty) {
        case (true, true): AnyShapeStyle(Self.emphasizedText.opacity(0.5))
        case (true, false): AnyShapeStyle(Self.emphasizedText)
        case (false, true): AnyShapeStyle(.secondary)
        case (false, false): AnyShapeStyle(.tint)
        }
    }

    /// Text on the focused selection's highlight, as AppKit draws it.
    private static let emphasizedText = Color(nsColor: .alternateSelectedControlTextColor)

    /// What VoiceOver calls the Trash row: "Trash", "Trash, 1 item", "Trash, 3 items".
    static func trashAccessibilityLabel(count: Int) -> String {
        let title = SidebarSection.trash.title
        switch count {
        case 0: return title
        case 1: return "\(title), 1 item"
        default: return "\(title), \(count) items"
        }
    }

    // MARK: - Rows shared by the sections

    /// Damaged-record placeholders (slice 56), pinned at the top of their section and
    /// untaggable, so the selection can never land on one.
    private func unreadableRows(_ rows: [UnreadableRecordRow]) -> some View {
        ForEach(rows) { row in
            UnreadableRecordRowView(
                row: row, root: model.url, plan: model.repairPlans[row.path],
                restore: { accepted in
                    model.repairRecord(atPath: row.path, acceptingInexactRestore: accepted)
                },
                delete: { model.deleteVanishedRecord(atPath: row.path) }
            )
            .selectionDisabled()
        }
    }

    /// A section's word that it has nothing to show, in place of rows.
    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .selectionDisabled()
    }

    /// A section header: its title in plain text, as Finder's and Mail's are, then its
    /// controls, its count and its disclosure button.
    private func header(
        _ section: SidebarSection, count: String, isExpanded: Binding<Bool>,
        @ViewBuilder controls: () -> some View
    ) -> some View {
        SidebarSectionHeader(title: section.title, count: count, isExpanded: isExpanded) {
            controls()
        }
        .id(SidebarRowID.header(section))
    }

    // MARK: - Reveal

    /// The sections the list leaves out right now.
    private var hidden: Set<SidebarSection> { SidebarSection.hidden(isSearching: isSearching) }

    private var collapsed: Set<SidebarSection> {
        var sections: Set<SidebarSection> = []
        if !reviewExpanded { sections.insert(.review) }
        if !artifactsExpanded { sections.insert(.artifacts) }
        if !peopleExpanded { sections.insert(.people) }
        return sections
    }

    /// Whether the section's rows include `item`, collapsed or not. Review's lanes are
    /// asked one by one, which doesn't build the whole worklist (`reviewRows`).
    private func isListed(_ item: SidebarItem, artifacts: ShownArtifacts) -> Bool {
        switch item {
        case .review(let id):
            model.reviewItems.contains { $0.id == id } || model.factItems.contains { $0.id == id }
                || model.relationshipItems.contains { $0.id == id }
                || model.duplicateItems.contains { $0.id == id }
        case .artifact(let id): artifacts.visible.contains { $0.uid == id }
        case .person(let id): model.displayedPersons.contains { $0.uid == id }
        case .trash: true
        }
    }

    /// Whether `item`'s row is on the list right now: listed, in an open section that
    /// isn't hidden.
    private func rowShows(_ item: SidebarItem, artifacts: ShownArtifacts) -> Bool {
        !collapsed.contains(item.section) && !hidden.contains(item.section)
            && isListed(item, artifacts: artifacts)
    }

    /// Scrolls the selected row into view, if its section is showing it.
    private func keepSelectionInView(_ proxy: ScrollViewProxy) {
        guard let item = selection.item, item.section != .trash,
            !collapsed.contains(item.section), !hidden.contains(item.section)
        else { return }
        let target = SidebarRowID.item(item)
        // Twice, for the reason `reveal` gives.
        proxy.scrollTo(target)
        Task { @MainActor in proxy.scrollTo(target) }
    }

    private func reveal(_ proxy: ScrollViewProxy, artifacts: ShownArtifacts) {
        let reveal = SidebarReveal(
            for: selection, collapsed: collapsed, hidden: hidden
        ) { isListed($0, artifacts: artifacts) }
        switch reveal.expand {
        case .review: reviewExpanded = true
        case .artifacts: artifactsExpanded = true
        case .people: peopleExpanded = true
        case .trash, nil: break
        }
        guard let target = reveal.target else { return }
        // Unanimated, and again once the list has laid out: rows below the fold have
        // estimated heights, so a single animated scroll lands short (84's prototype).
        if reveal.expand == nil { proxy.scrollTo(target, anchor: .top) }
        Task { @MainActor in proxy.scrollTo(target, anchor: .top) }
    }
}

/// The Artifacts section's rows after the uncatalogued filter, worked out once per draw.
private struct ShownArtifacts {
    /// The rows the section shows.
    let visible: [ArtifactSummary]
    /// The artifacts with no `sourceAuthorityTier` — uncatalogued, not broken — among the
    /// search's results, so the count is the debt within what the list is showing.
    let uncataloguedCount: Int

    /// The `uncataloguedCount > 0` guard is the same-frame half of releasing the filter:
    /// `onChange` resets the state after this render, and without it the list would
    /// flash empty as the count crossed zero.
    init(displayed: [ArtifactSummary], uncataloguedOnly: Bool) {
        let uncatalogued = displayed.filter { $0.sourceAuthorityTier == nil }
        uncataloguedCount = uncatalogued.count
        visible = uncataloguedOnly && !uncatalogued.isEmpty ? uncatalogued : displayed
    }
}

/// A section header with its own disclosure button, rather than `Section(isExpanded:)`'s
/// (slice 84's hand-test).
///
/// **The system's chevron moved the header's controls.** It appears on hover, and the
/// header made room for it, so Refresh, Filter and Sort slid left just as the pointer
/// reached them. This one keeps its place whether or not it shows, and fades in on
/// hover as the system's does. A click on the title or the count toggles too: everything
/// in the header but its own controls.
private struct SidebarSectionHeader<Controls: View>: View {
    let title: String
    let count: String
    @Binding var isExpanded: Bool
    @ViewBuilder let controls: Controls

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapses the section" : "Expands the section")
            controls
            Button(action: toggle) {
                Text(count)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            // Hidden, not removed: the space stays, so nothing beside it moves.
            .opacity(isHovering || !isExpanded ? 1 : 0)
            .help(isExpanded ? "Hide \(title)" : "Show \(title)")
            .accessibilityLabel(isExpanded ? "Hide \(title)" : "Show \(title)")
        }
        .onHover { isHovering = $0 }
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
    }
}

/// A sidebar row's selection highlight, as AppKit draws it: the `.selection` material,
/// emphasized while the row has focus (86's hand-test). A sidebar's selection is a
/// vibrant material that blends with the translucent sidebar behind it, so a flat fill of
/// the system's selection colors came out a shade off from the list's rows beside it.
private struct SidebarSelectionHighlight: NSViewRepresentable {
    let isEmphasized: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .followsWindowActiveState
        view.isEmphasized = isEmphasized
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.isEmphasized = isEmphasized
    }
}

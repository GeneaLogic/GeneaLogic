import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The window's one sidebar (slice 84): **Review, Artifacts and People** as collapsible
/// sections of one list, each an area's collection. Selecting a row sets the area
/// (`SidebarSelection`); the detail column shows that area's item.
///
/// **Why one sidebar** ([#39](https://github.com/GeneaLogic/GeneaLogic/issues/39)): the
/// area was a toolbar control and its collection the sidebar, so the switcher read as,
/// and was laid out as, a control on the detail column, and moved with it. A third
/// column of areas left the document 30 pt at the window's minimum width with the
/// inspector open; this keeps what the two-column window had.
///
/// One search field filters Artifacts and People. **Review's section hides while a
/// search is active**, so the results start at the top and nothing unfiltered sits
/// among them: the worklist was never searchable, because filtering work owed hides it.
struct ArchiveSidebar: View {
    @Environment(ArchiveModel.self) private var model
    @Binding var selection: SidebarSelection
    /// Changed by the window for each switch of area the sidebar didn't make (⌘1–⌘4, a
    /// jump), which brings the area's selection into view (`SidebarReveal`).
    let revealRequest: Int
    var isSearchFocused: FocusState<Bool>.Binding

    /// Which sections are open, per window like the selections (slice 85 decides where
    /// window state lives, and takes these with it).
    @SceneStorage("sidebarReviewExpanded") private var reviewExpanded = true
    @SceneStorage("sidebarArtifactsExpanded") private var artifactsExpanded = true
    @SceneStorage("sidebarPeopleExpanded") private var peopleExpanded = true

    /// Whether Artifacts is narrowed to the uncatalogued artifacts. Not persisted: it is a
    /// working mode for a cataloguing pass, and a filter that survives a relaunch is one
    /// the user has to remember they left on.
    @State private var uncataloguedOnly = false

    var body: some View {
        ScrollViewReader { proxy in
            list
                .onChange(of: revealRequest) { reveal(proxy) }
                // Review's keys move the selection down a list the pointer isn't on, and
                // `List` doesn't follow a selection set from outside.
                .onChange(of: selection.review) { _, id in
                    guard let id, selection.area == .review, !isSearching else { return }
                    proxy.scrollTo(SidebarRowID.item(.review(id)))
                }
        }
        // **Release the filter, don't just mask it.** When the debt reaches zero the
        // menu stops offering the toggle, which is the only way to turn it off — so the
        // state itself is reset. Left set, it would silently re-collapse the list on the
        // next import, with nothing on screen saying why.
        .onChange(of: uncataloguedCount) { _, remaining in
            if remaining == 0 { uncataloguedOnly = false }
        }
    }

    private var list: some View {
        List(selection: listSelection) {
            if !isSearching {
                Section(isExpanded: $reviewExpanded) {
                    reviewRows
                } header: {
                    header(.review, count: reviewCount) {
                        Button {
                            model.perform(.refreshReview)
                        } label: {
                            Image(systemName: ArchiveCommand.refreshReview.systemImage)
                        }
                        .buttonStyle(.borderless)
                        .help("Re-run the matcher over the archive")
                        .accessibilityLabel("Refresh Review")
                    }
                }
            }
            Section(isExpanded: $artifactsExpanded) {
                artifactRows
            } header: {
                header(
                    .artifacts,
                    count: SidebarCount.text(
                        shown: visibleArtifacts.count, of: model.artifacts.count)
                ) {
                    if !model.artifacts.isEmpty {
                        ArtifactFilterMenu(
                            uncataloguedOnly: $uncataloguedOnly,
                            uncataloguedCount: uncataloguedCount)
                        SortMenu()
                    }
                }
            }
            Section(isExpanded: $peopleExpanded) {
                personRows
            } header: {
                header(
                    .people,
                    count: SidebarCount.text(
                        shown: model.displayedPersons.count, of: model.persons.count)
                ) { EmptyView() }
            }
        }
        .listStyle(.sidebar)
        // On the sidebar column, which keeps it a sidebar field: on a list that isn't the
        // leading column it becomes a toolbar field (seen in 84's prototype).
        .searchable(text: searchText, placement: .sidebar, prompt: "Search")
        .searchFocused(isSearchFocused)
        // ⌫ raises the same confirm as the context menu, not a silent delete.
        .onDeleteCommand {
            switch selection.item {
            case .artifact(let id): model.perform(.deleteArtifact, on: .artifact(id))
            case .person(let id): model.perform(.deletePerson, on: .person(id))
            case .review, nil: break
            }
        }
        .modifier(ArtifactDeleteConfirmation())
        .modifier(PersonDeleteAndMerge())
    }

    // MARK: - Selection and search

    private var listSelection: Binding<SidebarItem?> {
        Binding(get: { selection.item }, set: { selection.select($0) })
    }

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

    private var reviewItems: [ReviewSidebarRow] {
        ReviewSidebarRow.rows(
            names: model.reviewItems, facts: model.factItems,
            relationships: model.relationshipItems, duplicates: model.duplicateItems,
            isScanningDuplicates: model.isScanningDuplicates)
    }

    private var reviewCount: String {
        SidebarCount.review(model.reviewRows.count, isScanning: model.isScanningDuplicates)
    }

    @ViewBuilder
    private var reviewRows: some View {
        let rows = reviewItems
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

    /// The artifacts with no `sourceAuthorityTier` — uncatalogued, not broken — among the
    /// search's results, so the count is the debt within what the list is showing.
    private var uncataloguedCount: Int {
        model.displayedArtifacts.filter { $0.sourceAuthorityTier == nil }.count
    }

    /// The guard is the same-frame half of releasing the filter: `onChange` resets the
    /// state after this render, and without it the list would flash empty as the count
    /// crossed zero.
    private var visibleArtifacts: [ArtifactSummary] {
        guard uncataloguedOnly, uncataloguedCount > 0 else { return model.displayedArtifacts }
        return model.displayedArtifacts.filter { $0.sourceAuthorityTier == nil }
    }

    private var isFilteringArtifacts: Bool { model.isFiltering || uncataloguedOnly }

    @ViewBuilder
    private var artifactRows: some View {
        let artifacts = visibleArtifacts
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
                    CommandButton(.deleteArtifact, on: .artifact(artifact.uid))
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
                    CommandButton(.showInTree, on: .person(person.uid))
                    CommandButton(.mergePerson, on: .person(person.uid))
                    CommandButton(.deletePerson, on: .person(person.uid))
                }
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
    /// controls and its count.
    private func header(
        _ section: SidebarSection, count: String,
        @ViewBuilder controls: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
            Spacer(minLength: 4)
            controls()
            Text(count)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .id(SidebarRowID.header(section))
    }

    // MARK: - Reveal

    private var collapsed: Set<SidebarSection> {
        var sections: Set<SidebarSection> = []
        if !reviewExpanded { sections.insert(.review) }
        if !artifactsExpanded { sections.insert(.artifacts) }
        if !peopleExpanded { sections.insert(.people) }
        return sections
    }

    private func isListed(_ item: SidebarItem) -> Bool {
        switch item {
        case .review(let id): model.reviewRows.contains { $0.id == id }
        case .artifact(let id): visibleArtifacts.contains { $0.uid == id }
        case .person(let id): model.displayedPersons.contains { $0.uid == id }
        }
    }

    private func reveal(_ proxy: ScrollViewProxy) {
        let reveal = SidebarReveal(
            for: selection, collapsed: collapsed, hidden: isSearching ? [.review] : [],
            isListed: isListed)
        switch reveal.expand {
        case .review: reviewExpanded = true
        case .artifacts: artifactsExpanded = true
        case .people: peopleExpanded = true
        case nil: break
        }
        guard let target = reveal.target else { return }
        // Unanimated, and again once the list has laid out: rows below the fold have
        // estimated heights, so a single animated scroll lands short (84's prototype).
        if reveal.expand == nil { proxy.scrollTo(target, anchor: .top) }
        Task { @MainActor in proxy.scrollTo(target, anchor: .top) }
    }
}

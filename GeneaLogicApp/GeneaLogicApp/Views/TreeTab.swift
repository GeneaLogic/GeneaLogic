import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The derived family-tree view (Phase 3, slice 44). The tree is a *projection* of
/// persons + relationships (§2.3) — never stored or edited here — so this tab is
/// read-only navigation: pick a focus person, see their ancestors and descendants,
/// click through to refocus or jump to the People tab.
struct TreeTab: View {
    /// The window's person selection, shared with the People tab: selecting someone
    /// there and switching here shows their tree, and refocusing here carries back.
    @Binding var focus: PersonID?

    @Environment(ArchiveModel.self) private var model

    @SceneStorage("treeAncestorDepth") private var ancestorDepth: Int = 3
    @SceneStorage("treeDescendantDepth") private var descendantDepth: Int = 3

    @State private var render: TreeRender?
    @State private var isPickingFocus = false
    @State private var focusSearch = ""

    /// Everything one rebuild produces, computed once per rebuild rather than per body
    /// evaluation — the person lookup and the geometry are both O(n), and the body
    /// reads them several times.
    private struct TreeRender {
        let layout: TreeLayout
        let geometry: TreeGeometry
        let personsByID: [PersonID: PersonSummary]
        /// Parent-child links that carry an explicit nature (slice 44f).
        let qualifiers: [RelationshipID: FactType]
        /// Whether the focus has *any* relationship in the archive, which is a
        /// different question from whether any relative fits inside the current depth.
        let focusHasRelatives: Bool
    }

    /// The person the tree is actually drawn around: the shared selection when it
    /// still resolves, else the first person, so the tab is never blank just because
    /// nothing happens to be selected.
    private var effectiveFocus: PersonID? {
        if let focus, model.persons.contains(where: { $0.uid == focus }) { return focus }
        return model.persons.first?.uid
    }

    var body: some View {
        Group {
            if model.persons.isEmpty {
                noPeople
            } else if let render {
                if render.layout.nodes.count > 1 {
                    canvas(render)
                } else if render.focusHasRelatives {
                    nothingAtThisDepth
                } else {
                    noRelationships(render)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        // Fill the pane before insetting the bar: `ContentUnavailableView` sizes to its
        // content rather than expanding, so without this the whole group is centred
        // vertically and the controls bar sinks to the middle of the window with it.
        // (The canvas branch masks this — an `NSViewRepresentable` expands on its own.)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .top) { if !model.persons.isEmpty { controls } }
        // Rebuild whenever the focus, the depths, or any conclusion mutation changes.
        .task(id: rebuildKey) { await rebuild() }
    }

    /// Everything the drawing depends on. `mutationVersion` covers relationship and
    /// person edits (including undo), the same trigger the detail panes reload off.
    private var rebuildKey: String {
        "\(effectiveFocus?.raw ?? "")|\(ancestorDepth)|\(descendantDepth)|\(model.mutationVersion)"
    }

    /// Reads the graph on the main actor (`ArchiveModel` is `@MainActor`, so the index
    /// query cannot move), then runs the **pure** projection off it — `TreeProjection`
    /// is a free function over `Sendable` values, so the layout pass need not block the
    /// UI even on a large archive.
    private func rebuild() async {
        guard let subject = effectiveFocus else {
            render = nil
            return
        }
        let relationships = model.allRelationships()
        let persons = model.persons
        let ancestors = ancestorDepth
        let descendants = descendantDepth

        let layout = await Task.detached(priority: .userInitiated) {
            TreeProjection.hourglass(
                focus: subject,
                relationships: relationships,
                ancestorDepth: ancestors,
                descendantDepth: descendants
            )
        }.value

        // `.task(id:)` cancels this task when the key changes, so a superseded rebuild
        // (rapid stepper clicks) must not publish its stale layout.
        guard !Task.isCancelled else { return }

        render = TreeRender(
            layout: layout,
            geometry: TreeGeometry(layout: layout),
            personsByID: Dictionary(
                persons.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first }),
            qualifiers: Dictionary(
                relationships.compactMap { relationship in
                    relationship.facts
                        .first { FactType.parentChildCases.contains($0.type) }
                        .map { (relationship.uid, $0.type) }
                }, uniquingKeysWith: { first, _ in first }),
            focusHasRelatives: relationships.contains { $0.involves(subject) }
        )
    }

    // MARK: - Canvas

    private func canvas(_ render: TreeRender) -> some View {
        ZoomableCanvas(
            contentSize: render.geometry.canvasSize,
            minMagnification: Layout.Tree.minMagnification,
            maxMagnification: Layout.Tree.maxMagnification
        ) {
            TreeContentView(
                layout: render.layout,
                geometry: render.geometry,
                personsByID: render.personsByID,
                qualifiers: render.qualifiers,
                onFocus: { focus = $0 },
                onShowInPeople: { model.navigateToPerson($0) }
            )
            // `NSHostingView` starts a fresh SwiftUI environment rather than inheriting
            // this one, so anything the content reads must be injected here — the same
            // hazard as a `.sheet` attached outside the injection point. The content
            // takes its data as parameters, so this is belt-and-braces for its subviews.
            .environment(model)
        }
    }

    // MARK: - Empty states

    private var noPeople: some View {
        ContentUnavailableView {
            Label("No People Yet", systemImage: "person.2")
        } description: {
            Text(
                "Add people on the People tab — or resolve a person mentioned in a document — and the tree will draw itself from the relationships between them."
            )
        }
    }

    /// The focus *has* relatives, but none of them fit inside the current depths — so
    /// this must not claim there are no relationships to show (which would send the
    /// user off to re-add ones that already exist).
    private var nothingAtThisDepth: some View {
        ContentUnavailableView {
            Label("Nothing at This Depth", systemImage: "arrow.up.arrow.down")
        } description: {
            Text(
                "This person has relatives recorded, but none within the chosen number of generations. Raise Ancestors or Descendants above to bring them into view."
            )
        }
    }

    /// A focus person genuinely unconnected: the projection legitimately returns a
    /// single node, which would otherwise read as a broken canvas.
    private func noRelationships(_ render: TreeRender) -> some View {
        ContentUnavailableView {
            Label("No Relationships Yet", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            let name = render.personsByID[render.layout.focus]?.displayName ?? "This person"
            Text(
                "\(name) has no parents, partners, or children recorded yet. Add a relationship from their page on the People tab."
            )
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 16) {
            focusPicker
            Spacer()
            Stepper("Ancestors: \(ancestorDepth)", value: $ancestorDepth, in: 0...8)
            Stepper("Descendants: \(descendantDepth)", value: $descendantDepth, in: 0...8)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// A searchable popover rather than a flat menu of every person: a real archive
    /// reaches hundreds, where an unsearchable menu is unusable. Reuses the same
    /// `PersonSearchField` + `PersonPickRow` pair (and the same engine-backed
    /// `matchingPersons`) as the resolve-mention and relationship-editor pickers, so
    /// searching for a person works identically everywhere.
    private var focusPicker: some View {
        Button {
            focusSearch = ""
            isPickingFocus = true
        } label: {
            Label(focusName, systemImage: "target")
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("The person the tree is centred on")
        .popover(isPresented: $isPickingFocus, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                PersonSearchField(text: $focusSearch)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.matchingPersons(focusSearch), id: \.uid) { person in
                            PersonPickRow(person: person, actionLabel: "Focus") {
                                focus = person.uid
                                isPickingFocus = false
                            }
                        }
                    }
                }
            }
            .padding(Layout.sheetPadding)
            .frame(width: Layout.Tree.focusPickerWidth, height: Layout.Tree.focusPickerHeight)
        }
    }

    private var focusName: String {
        guard let subject = effectiveFocus else { return "Choose Person" }
        return render?.personsByID[subject]?.displayName
            ?? model.persons.first { $0.uid == subject }?.displayName
            ?? "Unnamed person"
    }
}

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// Sidebar browse list of the open archive's artifacts (or the active filter's
/// results). `isFiltering` only picks the right empty state — a filter (search
/// text and/or selected tags) yielding nothing vs. a genuinely empty archive.
struct ArtifactListView: View {
    @Environment(ArchiveModel.self) private var model
    let artifacts: [ArtifactSummary]
    @Binding var selection: ArtifactID?
    var isFiltering: Bool = false
    var onDelete: (ArtifactID) -> Void = { _ in }

    /// The artifact a right-click "Delete Artifact…", the ⌫ key, or the Artifact ▸
    /// Delete Artifact… menu item is awaiting confirmation for.
    @State private var pendingDelete: ArtifactSummary?

    /// Whether the list is narrowed to the uncatalogued artifacts. Not persisted: it is a
    /// working mode for a cataloguing pass, and a filter that survives a relaunch is one
    /// the user has to remember they left on.
    @State private var showingUncataloguedOnly = false

    var body: some View {
        // The delete-intent observer and confirm dialog live on the always-mounted
        // outer body — *not* on the `List` — so the Artifact ▸ Delete Artifact… / ⌘⌫
        // menu path still works when the filtered list is empty (the `List` unmounts
        // then, but the sidebar and a valid selection can persist).
        listContent
            .onChange(of: model.pendingArtifactDeletion) { _, requested in
                if requested {
                    confirmDeleteSelection()
                    model.pendingArtifactDeletion = false
                }
            }
            // **Release the filter, don't just mask it.** When the debt reaches zero the
            // banner disappears, taking the only control that turns the filter off with
            // it — so the state itself has to be reset. Leaving it set merely *suspended*
            // the filter: the sidebar would silently re-collapse to the filtered set on
            // the next import, with nothing on screen explaining why.
            .onChange(of: uncataloguedCount) { _, remaining in
                if remaining == 0 { showingUncataloguedOnly = false }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.title)”?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { artifact in
                Button("Delete Artifact", role: .destructive) { onDelete(artifact.uid) }
            } message: { artifact in
                Text(deleteMessage(for: artifact))
            }
    }

    /// Placeholders for artifacts whose `record.json` couldn't be read (slice 56).
    private var unreadable: [UnreadableRecordRow] { model.unreadableArtifacts }

    @ViewBuilder
    private var listContent: some View {
        // A damaged record is not a search result — it has no title to match on,
        // so it can neither match nor fail to match — and a filter that finds
        // nothing must still say so (review finding, 56). Hence the filter is
        // asked first, and the placeholders sit out an active search; the banner
        // still reports them, so nothing goes unsaid.
        if isFiltering && artifacts.isEmpty {
            ContentUnavailableView(
                "No Matches", systemImage: "line.3.horizontal.decrease.circle",
                description: Text("No artifacts match the current search and tag filter.")
            )
            // **Fills on purpose.** `ListControlsBar` is attached as a top
            // `safeAreaInset` (see `ArchiveContainerView.sidebar`), and a
            // `ContentUnavailableView` sizes to fit rather than filling — so the
            // bar and the empty state were laid out as one composite and centred
            // together, leaving a band of dead space under the search field.
            // Filling pins the bar back under the search field and centres the
            // empty state in what's left. Pre-dates slice 56; the same shape as
            // the banner-vs-`.searchable` displacement that slice hit.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // An archive whose only artifact is unreadable must not read as an empty
        // archive — that indistinguishability is the whole reason this slice
        // exists, and the empty state is where it would come back.
        else if artifacts.isEmpty && !showsPlaceholders {
            // No bar to displace here — it is hidden while the archive is empty —
            // but filling keeps both empty states laid out the same way.
            ContentUnavailableView(
                "No Artifacts Yet", systemImage: "tray",
                description: Text("This archive doesn't contain any artifacts yet.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Only when there is something to say. A banner that renders "0 owed" is
                // furniture; this one disappears the moment the archive is fully
                // catalogued, which is what makes its presence mean something.
                if uncataloguedCount > 0 {
                    uncataloguedBanner
                    Divider()
                }
                List(selection: $selection) {
                    unreadableRows
                    ForEach(visibleArtifacts, id: \.uid) { artifact in
                        ArtifactRow(summary: artifact)
                            .tag(artifact.uid)
                            .contextMenu {
                                Button(
                                    "Delete Artifact…", systemImage: "trash", role: .destructive
                                ) {
                                    pendingDelete = artifact
                                }
                            }
                    }
                }
                // ⌫ deletes the selected artifact (baseline Mac expectation) — it raises
                // the same confirm as the context menu, not a silent delete.
                .onDeleteCommand { confirmDeleteSelection() }
            }
        }
    }

    /// Whether the damaged rows belong in the list right now.
    ///
    /// **Not while a filter is active** (review finding, 56): a record that failed
    /// to decode has no title to match on, so it can neither match a search nor
    /// fail to match one, and showing it among results would also swallow the
    /// "No Matches" state. It is still reported by the window banner throughout.
    private var showsPlaceholders: Bool { !isFiltering && !unreadable.isEmpty }

    /// The damaged rows, pinned above everything else. Rendered inside the `List`
    /// rather than above it so they scroll and style as list rows, but carrying no
    /// `.tag`, so the `ArtifactID`-typed selection can never land on one.
    @ViewBuilder
    private var unreadableRows: some View {
        if showsPlaceholders {
            Section {
                ForEach(unreadable) { row in
                    UnreadableRecordRowView(
                        row: row, root: model.url, plan: model.repairPlans[row.path],
                        restore: { accepted in
                            model.repairRecord(atPath: row.path, acceptingInexactRestore: accepted)
                        },
                        delete: { model.deleteVanishedRecord(atPath: row.path) })
                }
            }
        }
    }

    /// The artifacts with no `sourceAuthorityTier` — uncatalogued, not broken.
    ///
    /// Counted over the **incoming** list, so it reflects whatever the sidebar is already
    /// showing: with a search or tag filter active it reports the debt *within* those
    /// results rather than an archive-wide number the visible rows can't account for.
    private var uncataloguedCount: Int {
        artifacts.filter { $0.sourceAuthorityTier == nil }.count
    }

    /// The guard is the **same-frame** half of releasing the filter: `onChange` resets the
    /// state, but not until after this render, and without it the list would flash empty
    /// for a frame as the count crossed zero.
    ///
    /// It is deliberately *not* the whole mechanism. Masking here without resetting the
    /// state left the filter **suspended rather than released** — silently re-collapsing
    /// the sidebar on the next import, which is the bug `/code-review` caught and which
    /// the previous version of this comment claimed was already fixed.
    private var visibleArtifacts: [ArtifactSummary] {
        guard showingUncataloguedOnly, uncataloguedCount > 0 else { return artifacts }
        return artifacts.filter { $0.sourceAuthorityTier == nil }
    }

    /// Both a report and a way to act on it: the count states the debt, and the button
    /// narrows the list to exactly those artifacts so it can be worked through.
    private var uncataloguedBanner: some View {
        Button {
            showingUncataloguedOnly.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                Text(
                    uncataloguedCount == 1
                        ? "1 artifact has no source tier"
                        : "\(uncataloguedCount) artifacts have no source tier"
                )
                .lineLimit(1)
                Spacer(minLength: 4)
                Text(showingUncataloguedOnly ? "Show All" : "Show")
                    .foregroundStyle(.tint)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(showingUncataloguedOnly ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        .help("Artifacts whose source has not been characterised yet.")
    }

    /// Raises the delete confirm for the currently selected artifact (⌫ / menu).
    /// Resolves against the full artifact list so an active filter narrowing the
    /// sidebar doesn't lose the target. No-op when nothing is selected.
    private func confirmDeleteSelection() {
        guard let selection, let summary = model.artifacts.first(where: { $0.uid == selection })
        else { return }
        pendingDelete = summary
    }

    private func deleteMessage(for artifact: ArtifactSummary) -> String {
        let files =
            artifact.fileCount == 1
            ? "its 1 attached file" : "its \(artifact.fileCount) attached files"
        let scope = artifact.fileCount == 0 ? "this artifact" : "this artifact and \(files)"
        return "This removes \(scope) from the archive. You can undo it with ⌘Z."
    }
}

/// A single row in the artifact browse list: the title over a meaningful one-line
/// subtitle of genealogically useful facets (primary date, source tier, media type),
/// *not* the internal UID — which is developer addressing a researcher doesn't browse
/// by, and lives de-emphasized in the detail's Identifiers section (UI audit F1).
private struct ArtifactRow: View {
    let summary: ArtifactSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.headline)
                .lineLimit(1)
            subtitle
                .font(.subheadline)
                .lineLimit(1)
        }
    }

    /// Primary date (when known) · source tier · media type — the blanks omitted, so a
    /// dateless artifact reads "compiled · image" rather than carrying an empty slot.
    /// The date is glossed to human-readable EDTF ("about 1920"), falling back to the
    /// raw string when it isn't parseable as a date.
    ///
    /// **An unstated tier fills the tier's own slot rather than trailing the line.** It
    /// first shipped (46b) as a separate caption tacked on the end, which made an
    /// uncatalogued row read `image  no source tier` against a catalogued
    /// `government · image` — different order, different separator, different size, for
    /// what is the *same field* in two states. It now reads `no source tier · image`:
    /// identical structure, and only the colour marks it as work owed.
    ///
    /// Built by concatenating `Text` so one run can carry its own colour — deliberately
    /// **not** styled as an error, since uncatalogued is the normal state of a document
    /// that was just dragged in.
    private var subtitle: Text {
        var pieces: [Text] = []
        if let date = summary.primaryDate, !date.trimmingCharacters(in: .whitespaces).isEmpty {
            let gloss = EDTFDate.parse(date)?.humanDescription ?? date
            pieces.append(Text(gloss).foregroundStyle(.secondary))
        }
        if let tier = summary.sourceAuthorityTier {
            pieces.append(Text(tier.rawValue).foregroundStyle(.secondary))
        } else {
            pieces.append(Text("no source tier").foregroundStyle(.orange))
        }
        pieces.append(Text(summary.mediaType.rawValue).foregroundStyle(.secondary))

        let separator = Text(" · ").foregroundStyle(.secondary)
        return pieces.dropFirst().reduce(pieces[0]) { $0 + separator + $1 }
    }
}

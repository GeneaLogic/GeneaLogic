import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// People-tab browse list of the open archive's concluded persons (or the active
/// search's results). Mirrors `ArtifactListView`: selectable rows, a ⌫ /
/// context-menu delete raising a confirm, and distinct empty states for a genuinely
/// empty archive vs. a search that matched nothing.
struct PersonListView: View {
    @Environment(ArchiveModel.self) private var model
    let persons: [PersonSummary]
    @Binding var selection: PersonID?
    var isFiltering: Bool = false
    var onDelete: (PersonID) -> Void = { _ in }

    /// The person a right-click "Delete Person…" or the ⌫ key is awaiting
    /// confirmation for.
    @State private var pendingDelete: PersonSummary?

    /// The duplicate whose "Merge Into…" picker is up (slice 45f), or `nil`. This is the
    /// person being **absorbed** — the row the user right-clicked is the one they want
    /// gone, and the sheet asks which record to keep.
    @State private var mergeSource: MergeSource?

    /// The chosen pair, awaiting the confirm step. Merge is the one mutation here that
    /// rewrites records the user never named, and unlike a delete it cannot be understood
    /// from the row alone — so the pair is named back before anything is written.
    @State private var pendingMerge: PendingMerge?

    var body: some View {
        // The confirm lives on the always-mounted outer body (not the `List`), so a
        // ⌫ delete still confirms when a search has emptied the list.
        listContent
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.displayName ?? "this person")”?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { person in
                Button("Delete Person", role: .destructive) { onDelete(person.uid) }
            } message: { _ in
                Text(
                    "This removes the person from the archive. Any relationships or "
                        + "evidence links to them are left in place. You can undo it with ⌘Z.")
            }
            .sheet(item: $mergeSource) { source in
                let duplicate = source.person
                PersonPickerSheet(
                    title: "Merge “\(duplicate.displayName ?? "this person")” Into…",
                    prompt: "Pick the record to keep. Everything on this one moves to it.",
                    actionLabel: "Merge",
                    excluding: duplicate.uid,
                    emptyMessage: "There is nobody else to merge into.",
                    accessory: { EmptyView() },
                    footerLeading: { EmptyView() }
                ) { survivor in
                    pendingMerge = PendingMerge(absorbed: duplicate, survivor: survivor)
                    mergeSource = nil
                }
                .environment(model)
            }
            .confirmationDialog(
                pendingMerge.map { merge in
                    "Merge “\(merge.absorbed.displayName ?? "this person")” into "
                        + "“\(name(of: merge.survivor))”?"
                } ?? "",
                isPresented: Binding(
                    get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
                titleVisibility: .visible, presenting: pendingMerge
            ) { merge in
                Button("Merge People") {
                    model.mergePersons(merge.absorbed.uid, into: merge.survivor)
                }
            } message: { _ in
                Text(
                    "Names and facts are combined, and every relationship and evidence link "
                        + "moves to the record you keep. The other record is removed. You can "
                        + "undo it with ⌘Z.")
            }
    }

    /// Identifiable wrapper so a merge request can drive `.sheet(item:)` — the app's
    /// convention for sheet payloads (`NameEditorRequest`, `EndpointReplacement`), and
    /// what keeps `Identifiable` off the engine's `PersonSummary`, which deliberately
    /// carries no display or presentation affordances.
    private struct MergeSource: Identifiable {
        let person: PersonSummary
        var id: String { person.uid.raw }
    }

    /// The pair a confirm step is about — the row that was right-clicked, plus the
    /// survivor picked from the sheet.
    private struct PendingMerge: Identifiable {
        let absorbed: PersonSummary
        let survivor: PersonID
        var id: String { "\(absorbed.uid.raw)-\(survivor.raw)" }
    }

    private func name(of id: PersonID) -> String {
        model.persons.first { $0.uid == id }?.displayName ?? "the other person"
    }

    /// Placeholders for people whose record couldn't be read (slice 56).
    private var unreadable: [UnreadableRecordRow] { model.unreadablePersons }

    @ViewBuilder
    private var listContent: some View {
        // As in the artifacts list: an unreadable person must not make the archive
        // look like it has no people — but a search that matches nothing must
        // still say so, so the filter is asked first (review finding, 56).
        if isFiltering && persons.isEmpty {
            ContentUnavailableView(
                "No Matches", systemImage: "person.crop.circle.badge.questionmark",
                description: Text("No people match the current search."))
        } else if persons.isEmpty && !showsPlaceholders {
            ContentUnavailableView(
                "No People Yet", systemImage: "person.2",
                description: Text("Add a person with the + button to start building the tree."))
        } else {
            List(selection: $selection) {
                unreadableRows
                ForEach(persons, id: \.uid) { person in
                    PersonRow(summary: person)
                        .tag(person.uid)
                        .contextMenu {
                            Button("Merge Into…", systemImage: "arrow.triangle.merge") {
                                mergeSource = MergeSource(person: person)
                            }
                            Button("Delete Person…", systemImage: "trash", role: .destructive) {
                                pendingDelete = person
                            }
                        }
                }
            }
            .onDeleteCommand { confirmDeleteSelection() }
        }
    }

    /// Whether the damaged rows belong in the list right now — not while a search
    /// is active, for the reasons in `ArtifactListView.showsPlaceholders`.
    private var showsPlaceholders: Bool { !isFiltering && !unreadable.isEmpty }

    /// Pinned above the people, untagged so the `PersonID` selection can't land
    /// on one — see `UnreadableRecordRowView`.
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

    /// Raises the delete confirm for the selected person (⌫). Resolves against the
    /// full person list so an active search doesn't lose the target. No-op when
    /// nothing is selected.
    private func confirmDeleteSelection() {
        guard let selection, let summary = model.persons.first(where: { $0.uid == selection })
        else { return }
        pendingDelete = summary
    }
}

/// A single row in the People browse list: the display name over a one-line
/// subtitle of primary date (EDTF-glossed) and fact count.
private struct PersonRow: View {
    let summary: PersonSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.displayName ?? "Unnamed person")
                .font(.headline)
                .lineLimit(1)
            Text(summary.browseSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

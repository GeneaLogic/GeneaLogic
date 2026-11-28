import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// A person's sidebar row: the display name over a one-line subtitle of primary date
/// (EDTF-glossed) and fact count. No symbol (slice 84, fork 4): every row in the section
/// is a person, so one would distinguish nothing.
struct PersonRow: View {
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

/// Delete Person…'s confirm and Merge Into…'s picker and confirm, from ⌫, the Person
/// menu and a row's context menu. On the sidebar as a whole, so they work with the
/// section collapsed or a search showing none of the people. A person still confirms
/// where an artifact no longer does (slice 86): its delete is undone only in this session,
/// until #11 gives conclusions a trash.
struct PersonDeleteAndMerge: ViewModifier {
    @Environment(ArchiveModel.self) private var model

    /// The person awaiting delete confirmation.
    @State private var pendingDelete: PersonSummary?

    /// The duplicate whose "Merge Into…" picker is up (slice 45f), or `nil`. This is the
    /// person being **absorbed** — the row the user right-clicked is the one they want
    /// gone, and the sheet asks which record to keep.
    @State private var mergeSource: MergeSource?

    /// The chosen pair, awaiting the confirm step. Merge is the one mutation here that
    /// rewrites records the user never named, and unlike a delete it cannot be understood
    /// from the row alone — so the pair is named back before anything is written.
    @State private var pendingMerge: PendingMerge?

    func body(content: Content) -> some View {
        content
            .onChange(of: model.pendingCommand) {
                guard
                    let (command, subject) = model.claimPendingCommand({
                        $0 == .deletePerson || $0 == .mergePerson
                    }),
                    case .person(let id) = subject,
                    let person = model.persons.first(where: { $0.uid == id })
                else { return }
                if command == .deletePerson {
                    pendingDelete = person
                } else {
                    mergeSource = MergeSource(person: person)
                }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete “\($0.displayName ?? "this person")”?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible, presenting: pendingDelete
            ) { person in
                Button("Delete Person", role: .destructive) { model.deletePerson(person.uid) }
            } message: { _ in
                Text(
                    "This removes the person from the archive. Any relationships or "
                        + "evidence links to them are left in place. You can undo it with ⌘Z.")
            }
            .reportsModal(pendingDelete != nil)
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
            .reportsModal(mergeSource != nil)
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
                Text(MergeWording.explanation)
            }
            .reportsModal(pendingMerge != nil)
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
}

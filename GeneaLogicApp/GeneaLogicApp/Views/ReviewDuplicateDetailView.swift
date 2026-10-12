// `PersonSummary`/`DuplicateCandidate` are re-exported by `GeneaLogicArchive`; under
// `MemberImportVisibility` that makes them nameable but not their members readable, so the
// defining modules are named here (the same note as `ReviewItem`).
import GeneaLogicArchive
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// The Review section's third detail pane: two concluded persons that may be one person,
/// and the matcher's reasoning for thinking so (slice 45m over 45j's scorer).
///
/// **The only Review pane whose action is destructive.** Confirming a link or recording a
/// fact adds a record; merging rewrites every record naming the absorbed person and deletes
/// their sidecar. So this pane is built to be *read* rather than cleared: the decomposed
/// breakdown and the conflicts come before the buttons, and merging asks which record
/// survives instead of assuming.
///
/// **No source weights**, unlike `ReviewDetailView`'s candidate cards, and that is the
/// honest rendering rather than an omission: those two weights measure a *source*, and
/// neither side of a person↔person comparison is one (45j). Drawing them as `0` or `100`
/// would invent a figure; drawing them greyed would imply the score has a slot it
/// structurally does not.
struct ReviewDuplicateDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let item: DuplicateReviewItem

    /// The chosen direction, awaiting confirmation. A merge cannot be understood from the
    /// row alone and there is no second chance inside it, so the pair is named back — the
    /// same step `PersonListView` puts in front of its own Merge Into….
    @State private var pendingMerge: PendingMerge?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                reasoningSection
                actionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            pendingMerge.map { "Merge “\($0.absorbedName)” into “\($0.survivorName)”?" } ?? "",
            isPresented: Binding(
                get: { pendingMerge != nil }, set: { if !$0 { pendingMerge = nil } }),
            titleVisibility: .visible, presenting: pendingMerge
        ) { merge in
            Button("Merge People") {
                model.mergePersons(merge.absorbed, into: merge.survivor)
            }
        } message: { _ in
            Text(
                "Names and facts are combined, and every relationship and evidence link "
                    + "moves to the record you keep. The other record is removed. You can "
                    + "undo it with ⌘Z.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Possible Duplicate")
                .font(.largeTitle.weight(.semibold))
            Text(
                "These two records may describe one person. Read the reasoning before "
                    + "merging — a merge rewrites every record naming the one you don’t keep."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            // Both people, each reachable. The judgement is made against what is already
            // recorded on their pages, which is a click away rather than transcribed here.
            HStack(alignment: .top, spacing: 16) {
                PersonColumn(summary: item.first, id: item.candidate.person1)
                PersonColumn(summary: item.second, id: item.candidate.person2)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - The reasoning

    private var reasoningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Why These Might Be One Person")
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(item.confidence)")
                        .font(.title3.monospacedDigit())
                    Text("confidence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("A roll-up for ordering the queue. The dimensions below are the evidence.")
            }

            let breakdown = item.candidate.match.breakdown
            let agreement = breakdown.agreementLine
            if !agreement.isEmpty {
                Text(agreement)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MatchBreakdownView(breakdown: breakdown)
        }
    }

    // MARK: - Actions

    /// Merge asks **which record survives**, because the pair is already known and a picker
    /// over every person in the archive would be answering a question this row has already
    /// answered. Both directions are offered plainly: neither record is "the original" —
    /// `uid`s are minted, not derived (§4.1), so creation order says nothing about which is
    /// the better-kept record.
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack(spacing: 8) {
                Button("Keep “\(item.firstName)”…", systemImage: "arrow.triangle.merge") {
                    pendingMerge = PendingMerge(
                        survivor: item.candidate.person1, survivorName: item.firstName,
                        absorbed: item.candidate.person2, absorbedName: item.secondName)
                }
                Button("Keep “\(item.secondName)”…", systemImage: "arrow.triangle.merge") {
                    pendingMerge = PendingMerge(
                        survivor: item.candidate.person2, survivorName: item.secondName,
                        absorbed: item.candidate.person1, absorbedName: item.firstName)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Button("Not a Duplicate", systemImage: "xmark") {
                    model.dismissDuplicate(item)
                }
                Text(
                    "Records that these two are different people, so this pair isn’t "
                        + "offered again — including after you quit. ⌘Z undoes it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A chosen merge direction, awaiting its confirm step. Names are carried rather than
/// re-derived so the dialog says the same thing the button did, even if the archive moves
/// underneath it.
private struct PendingMerge: Identifiable {
    let survivor: PersonID
    let survivorName: String
    let absorbed: PersonID
    let absorbedName: String

    var id: String { "\(survivor.raw)|\(absorbed.raw)" }
}

/// One of the two persons under comparison: name, subtitle, and a jump to their page.
private struct PersonColumn: View {
    @Environment(ArchiveModel.self) private var model
    let summary: PersonSummary?
    let id: PersonID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary?.displayName ?? "Unnamed person")
                .font(.headline)
                .lineLimit(1)
            // A person removed between the scan and now is a normal state (§2.3), and the
            // uid is the honest label for them.
            Text(summary?.browseSubtitle ?? id.raw)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                model.navigateToPerson(id)
            } label: {
                HStack(spacing: 4) {
                    Text("Open in People")
                    Image(systemName: "arrow.up.right")
                        .imageScale(.small)
                }
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show this person on the People tab")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

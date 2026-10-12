// `PersonSummary`/`SuggestedRelationship` are re-exported by `GeneaLogicArchive`; under
// `MemberImportVisibility` that makes them nameable but not their members readable, so the
// defining modules are named here (the same note as `ReviewItem`).
import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// The Review section's fourth detail pane: a relationship the archive's records already
/// state, waiting to be recorded as a conclusion (slice 45l).
///
/// **The pane with no score, and the one where that is not a shortcoming.** Every other
/// Review pane renders a decomposed `MatchBreakdown`, because every other one is asking
/// *are these two the same person?* — a question a matcher answered with a number. This one
/// is asking whether to believe what a document says about who is whose, and both endpoints
/// were already identified by a human. So the reasoning shown here is the citation itself:
/// which records support it, and whether each one **states** the relation or its roles only
/// **imply** it. That distinction is the whole of the evidence, and it is what §4.6's rule
/// (show the reasoning, never a bare figure) amounts to when nothing was measured.
struct ReviewRelationshipDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let item: RelationshipReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                evidenceSection
                actionsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suggested Relationship")
                .font(.largeTitle.weight(.semibold))
            Text(item.claim)
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 16) {
                RelationshipEndpointColumn(
                    role: endpointRoles.first, summary: item.first,
                    id: item.suggestion.person1)
                RelationshipEndpointColumn(
                    role: endpointRoles.second, summary: item.second,
                    id: item.suggestion.person2)
            }
            .padding(.top, 8)
        }
    }

    /// What the two endpoints are being proposed *as*, said explicitly — §4.5 fixes the
    /// direction, and a pane that showed two names side by side without naming which is
    /// which would leave the reader to remember a convention.
    private var endpointRoles: (first: String?, second: String?) {
        switch item.suggestion.type {
        case .parentChild: ("Parent", "Child")
        case .couple: ("Partner", "Partner")
        case .unknown: (nil, nil)
        }
    }

    private var explanation: String {
        item.suggestion.isStated
            ? "A record in this archive states this relationship, and both people on it are "
                + "already resolved. Recording it adds the relationship to your conclusions, "
                + "citing the evidence below."
            : "The roles on the record below place these two in this relationship, though it "
                + "doesn’t state it outright. Recording it adds the relationship to your "
                + "conclusions, citing the evidence."
    }

    // MARK: - The evidence

    /// One row per supporting record. Two documents saying the same thing is one conclusion
    /// with two citations, not two rows — so this is where the second one becomes visible,
    /// and confirming from here cites both.
    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Where This Comes From")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(item.suggestion.evidence.enumerated()), id: \.offset) {
                    index, evidence in
                    EvidenceRow(
                        title: item.sourceTitles.indices.contains(index)
                            ? item.sourceTitles[index] : "Unknown document",
                        basis: evidence.basis,
                        onOpen: { model.navigateToArtifact(evidence.artifact) })
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            // No `.defaultAction`: no other Review pane binds ⏎ to its verb, and a detail
            // pane where Return silently writes a conclusion is not a habit worth teaching
            // in a section whose other lanes include a destructive one.
            Button("Record Relationship", systemImage: "checkmark") {
                model.confirmSuggestedRelationship(item)
            }

            VStack(alignment: .leading, spacing: 4) {
                Button("Not This Relationship", systemImage: "xmark") {
                    model.dismissSuggestedRelationship(item)
                }
                Text(
                    "Records that these documents don’t support this relationship, so it "
                        + "isn’t offered again — including after you quit. It says nothing "
                        + "about any other relationship between them. ⌘Z undoes it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One supporting record: its title, how it supports the claim, and a jump to it.
private struct EvidenceRow: View {
    let title: String
    let basis: RelationshipBasis
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: basis == .stated ? "text.quote" : "sparkles")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: onOpen) {
                    HStack(spacing: 4) {
                        Text(title)
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this document on the Artifacts tab")
                Text(
                    basis == .stated
                        ? "States the relationship outright"
                        : "Implied by the roles it records"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// One endpoint of the proposed relationship: which end it is, who it is, and a jump to
/// their page — the judgement is made against what is already recorded there.
private struct RelationshipEndpointColumn: View {
    @Environment(ArchiveModel.self) private var model
    let role: String?
    let summary: PersonSummary?
    let id: PersonID

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let role {
                Text(role.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(summary?.displayName ?? "Unnamed person")
                .font(.headline)
                .lineLimit(1)
            // A person removed between the sweep and now is a normal state (§2.3), and the
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

import GeneaLogicArchive
// Named to read `DuplicateScore`'s members under `MemberImportVisibility` — see `ReviewItem`.
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// A worklist row's context menu: the verbs of its lane, on that row, which needn't be the
/// selected one. What the rule won't offer on it stays out, rather than dim; the rule is
/// the menu bar's, so the two can't disagree. Each says its lane's word, and on a name row
/// whose (slice 83b), so a row's menu reads complete in its own terms.
struct ReviewRowMenu: View {
    @Environment(ArchiveModel.self) private var model
    let target: ReviewTarget

    var body: some View {
        // A sidebar row, so from any area (slice 84).
        let groups = ReviewTarget.rowMenu.map {
            $0.filter { model.canOffer($0, on: .review(target), fromSidebar: true) }
        }
        .filter { !$0.isEmpty }
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index], id: \.self) {
                CommandButton($0, on: .review(target), fromSidebar: true)
            }
        }
    }
}

/// One row of the sidebar's Review section, drawn by its lane.
struct ReviewSidebarRowView: View {
    let row: ReviewSidebarRow

    var body: some View {
        switch row {
        case .name(let item): ReviewRow(item: item)
        case .fact(let item): FactReviewRow(item: item)
        case .relationship(let item): RelationshipReviewRow(item: item)
        case .duplicate(let item): DuplicateReviewRow(item: item)
        case .scanningDuplicates: DuplicateScanRow()
        }
    }
}

/// One names-lane row, in two lines: the name as recorded, then the document it is from
/// and who it looks like.
///
/// **The document is on the row** since slice 84. The lane was grouped under document
/// headers when Review had a sidebar of its own; in the one sidebar Review is a single
/// section, two levels deep, so the row carries what the header did. The engine still
/// returns document order, so a document's names stay together.
///
/// `person.crop.circle.badge.questionmark` marks the lane as the other three symbols mark
/// theirs: in one section of four lanes, the row shape says which kind of work it is.
private struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SidebarSymbol(name: "person.crop.circle.badge.questionmark")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.recordedName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.artifactTitle)
                        .lineLimit(1)
                        .layoutPriority(-1)
                    Text("·")
                    if let best = item.candidates.first {
                        Text(best.displayName)
                            .lineLimit(1)
                        // The score rides *beside a name*, which is the only context that
                        // makes it mean anything. On its own it would be the opaque "71%"
                        // §4.6 exists to avoid.
                        Text("\(best.confidence)")
                            .monospacedDigit()
                        if item.candidates.count > 1 {
                            Text("+\(item.candidates.count - 1)")
                                .help("\(item.candidates.count - 1) more candidates")
                        }
                    } else {
                        // Not "new person" — see `ReviewItem.noCandidateExplanation`.
                        Text("No candidate")
                        if item.rejectedCount > 0 {
                            Image(systemName: "hand.raised")
                                .help("\(item.rejectedCount) rejected earlier on this mention")
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One person with promotable evidence: their name, and how much of it is waiting.
///
/// The count is the whole subtitle — there is nothing here to be confident *about*. A
/// suggestion isn't a guess about identity (the link was already confirmed by a human);
/// it is a piece of the record this person's page hasn't yet claimed, so the only
/// question the row can answer is how much of it there is.
///
/// **Carries the `sparkles` leading icon** the suggestion rows use in both detail panes,
/// the symbol already meaning *promotable evidence* everywhere else in the app.
private struct FactReviewRow: View {
    let item: FactReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SidebarSymbol(name: "sparkles")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(
                    item.suggestions.count == 1
                        ? "1 fact from linked sources"
                        : "\(item.suggestions.count) facts from linked sources"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One suggested-relationship row: the claim in words, and where it comes from.
///
/// **No figure at all**, unlike every other row in this list, and that is the honest
/// rendering rather than a gap: both endpoints' links were already confirmed by a human, so
/// nothing here was scored. What the subtitle carries instead is the distinction that
/// actually bears on the judgement — whether the record *states* the relationship or its
/// roles merely imply it.
///
/// `point.3.connected.trianglepath.dotted` marks the lane the way `sparkles` and
/// `person.2.fill` mark the other two: a section header scrolls away, and the row shape has
/// to keep saying which kind of work it is. It is the symbol this app already uses for
/// *relationships* — the Tree tab and its empty state — rather than a new one, and a first
/// hand-test is what settled it: the glyph originally chosen doesn't exist, so the rows
/// rendered with an invisible icon holding open an indent nothing filled.
private struct RelationshipReviewRow: View {
    let item: RelationshipReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SidebarSymbol(name: "point.3.connected.trianglepath.dotted")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.claim)
                    .font(.body)
                    .lineLimit(2)
                // Title and basis come from **one** citation (`leadCitation`), never from the
                // archive-wide `isStated` beside an arbitrary title — that pairing named the
                // one document that didn't state it. See `RelationshipReviewItem`.
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard let citation = item.leadCitation else { return "From this archive’s records" }
        return citation.basis == .stated
            ? "Stated by \(citation.title)"
            : "Implied by roles on \(citation.title)"
    }
}

/// One possible-duplicate row: the two names, and how strongly they agree.
///
/// **Both names, never one plus a count.** The other two lanes name the thing to be
/// decided; here the thing to be decided *is* the pair, and a row reading "Szlama Feldberg ·
/// 83" would hide which other record is on the table — the only fact that makes the row
/// actionable at a glance.
///
/// `person.2.fill` marks the lane the way `sparkles` marks the facts lane: a section header
/// scrolls away, and the row shape has to keep saying which kind of work it is.
private struct DuplicateReviewRow: View {
    let item: DuplicateReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SidebarSymbol(name: "person.2.fill")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.firstName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.secondName)
                        .lineLimit(1)
                    // Beside a name, like the names lane's — a bare figure is the opaque
                    // percentage §4.6 exists to avoid.
                    Text("· \(item.confidence)")
                        .monospacedDigit()
                    if !item.candidate.match.breakdown.conflicts.isEmpty {
                        // A conflict is usually how two people who share a name are told
                        // apart, so its presence belongs in the row, not only in the pane.
                        Image(systemName: "exclamationmark.triangle")
                            .help("The records disagree on something — see the details")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The lane's placeholder while the quadratic sweep runs off the main actor.
///
/// It exists because this is the one Review sweep a user can be made to wait for. Without
/// it the section would simply be absent mid-scan, which reads as "no duplicates" — an
/// answer this lane has not yet computed.
private struct DuplicateScanRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Comparing people…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}


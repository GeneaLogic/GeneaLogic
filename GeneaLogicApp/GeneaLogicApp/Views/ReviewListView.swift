import GeneaLogicArchive
// Named to read `DuplicateScore`'s members under `MemberImportVisibility` — see `ReviewItem`.
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// The Review section's sidebar: everything in the archive that is waiting on a human
/// judgement — **unresolved names** grouped by the document they come from (slice 45e),
/// then **suggested facts** grouped by the person they'd be recorded on (slice 45i).
///
/// Names are grouped by artifact because that is how the work is actually done — a newly
/// catalogued record's names are triaged together, with the scan in front of you — and
/// within a group the order is the record's own, so the list reads down the document rather
/// than down a ranking. (The engine returns document order for the same reason; ranking a
/// mention that matched *nothing* is not possible anyway.)
///
/// **One list, no mode switch** (45i fork (a)). The two lanes are different kinds of work
/// and stay legible because they land in different sections with different row shapes — a
/// name under a document title, a person under "Suggested Facts" — not because one of them
/// is hidden behind a segmented control the user has to remember to press. Names come first:
/// they are the unfinished half of cataloguing, and a fact promoted onto the wrong person is
/// harder to notice than one not yet promoted.
///
/// A name row's subtitle is the **best candidate's name**, never a bare percentage, and never
/// a suggestion to create somebody: a mention nothing matched says so plainly and leaves
/// the judgement to the pane.
struct ReviewListView: View {
    @Environment(ArchiveModel.self) private var model
    @Binding var selection: ReviewItem.ID?

    private var isEmpty: Bool {
        model.reviewItems.isEmpty && model.factItems.isEmpty && model.duplicateItems.isEmpty
            && model.relationshipItems.isEmpty && !model.isScanningDuplicates
    }

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if !isEmpty {
                    ReviewControlsBar(
                        names: model.reviewItems.count, people: model.factItems.count,
                        relationships: model.relationshipItems.count,
                        duplicates: model.duplicateItems.count)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isEmpty {
            ContentUnavailableView {
                Label("Nothing to Review", systemImage: "checkmark.circle")
            } description: {
                Text(
                    "Every name in this archive is resolved, every linked source has been "
                        + "read, every relationship your records state is recorded, and no "
                        + "two people look like one. Catalogue a document’s Persons "
                        + "Mentioned and its names will show up here.")
            } actions: {
                Button("Refresh") {
                    model.refreshReviewWorklist()
                    model.refreshDuplicateCandidates()
                }
            }
        } else {
            List(selection: $selection) {
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.items) { item in
                            ReviewRow(item: item)
                                .tag(item.id)
                        }
                    }
                }
                if !model.factItems.isEmpty {
                    Section("Suggested Facts") {
                        ForEach(model.factItems) { item in
                            FactReviewRow(item: item)
                                .tag(item.id)
                        }
                    }
                }
                // After the facts and before the duplicates: promoting an edge is additive
                // and reversible like recording a fact, so it belongs with the cataloguing
                // work rather than beside the one destructive lane.
                if !model.relationshipItems.isEmpty {
                    Section("Suggested Relationships") {
                        ForEach(model.relationshipItems) { item in
                            RelationshipReviewRow(item: item)
                                .tag(item.id)
                        }
                    }
                }
                // Last, and deliberately: the action on the other side of these rows is
                // the most destructive one in the app, so they are the least urgent thing
                // in a section otherwise made of unfinished cataloguing.
                if model.isScanningDuplicates || !model.duplicateItems.isEmpty {
                    Section("Possible Duplicates") {
                        if model.isScanningDuplicates && model.duplicateItems.isEmpty {
                            DuplicateScanRow()
                        }
                        ForEach(model.duplicateItems) { item in
                            DuplicateReviewRow(item: item)
                                .tag(item.id)
                        }
                    }
                }
            }
        }
    }

    /// The worklist cut into per-document sections, **preserving the engine's order** —
    /// the items already arrive artifact by artifact, so this only has to notice where one
    /// document ends and the next begins. Sorting the groups by title would fight the
    /// order deliberately chosen upstream.
    private var groups: [ReviewGroup] {
        var result: [ReviewGroup] = []
        for item in model.reviewItems {
            if let last = result.indices.last, result[last].artifact == item.mention.artifact {
                result[last].items.append(item)
            } else {
                result.append(
                    ReviewGroup(
                        artifact: item.mention.artifact, title: item.artifactTitle, items: [item]))
            }
        }
        return result
    }
}

/// One document's worth of worklist rows.
///
/// **Identified by the artifact's `uid`, never by its title.** Titles are user-supplied
/// strings with nothing enforcing uniqueness — two censuses can share one, and two
/// untitled records certainly do — and duplicate `ForEach` identities are undefined
/// behaviour that drops rows. On the one list whose entire invariant is that an unresolved
/// mention cannot go missing, that failure would be silent and would look exactly like the
/// matcher having nothing to say.
private struct ReviewGroup: Identifiable {
    let artifact: ArtifactID
    let title: String
    var items: [ReviewItem]

    var id: String { artifact.raw }
}

/// One worklist row: the name as recorded, and who it looks like.
private struct ReviewRow: View {
    let item: ReviewItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.recordedName)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 4) {
                if let best = item.candidates.first {
                    Text(best.displayName)
                        .lineLimit(1)
                    // The score rides *beside a name*, which is the only context that
                    // makes it mean anything. On its own it would be the opaque "71%"
                    // §4.6 exists to avoid.
                    Text("· \(best.confidence)")
                        .monospacedDigit()
                    if item.candidates.count > 1 {
                        Text("· +\(item.candidates.count - 1) more")
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
/// **Carries the `sparkles` leading icon** the suggestion rows use in both detail panes.
/// One list holding two kinds of work needs the boundary to be visible at a glance, and a
/// section header alone doesn't do it once the list is long enough to scroll the header
/// away — the row shape itself has to say which lane it belongs to. The names rows stay
/// plain: an icon on both would distinguish nothing, and the icon is the one already
/// meaning *promotable evidence* everywhere else in the app.
private struct FactReviewRow: View {
    let item: FactReviewItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
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
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .foregroundStyle(.secondary)
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
            Image(systemName: "person.2.fill")
                .foregroundStyle(.secondary)
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

/// The count-and-refresh strip pinned under the sidebar's top edge, mirroring the
/// Artifacts section's `ListControlsBar` (UI audit F7/F14).
///
/// **Both counts, not a total.** The list holds two kinds of work, and a single number
/// over them would be a figure with no unit — "17 items" says nothing about what is owed.
/// A lane with nothing in it drops out of the strip rather than reading "0".
private struct ReviewControlsBar: View {
    @Environment(ArchiveModel.self) private var model
    let names: Int
    let people: Int
    let relationships: Int
    let duplicates: Int

    private var summary: String {
        var parts: [String] = []
        if names > 0 {
            parts.append(names == 1 ? "1 unresolved name" : "\(names) unresolved names")
        }
        if people > 0 {
            parts.append(people == 1 ? "1 person with facts" : "\(people) people with facts")
        }
        if relationships > 0 {
            parts.append(
                relationships == 1 ? "1 relationship" : "\(relationships) relationships")
        }
        if duplicates > 0 {
            parts.append(
                duplicates == 1 ? "1 possible duplicate" : "\(duplicates) possible duplicates")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                model.refreshReviewWorklist()
                model.refreshDuplicateCandidates()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-run the matcher over the archive")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

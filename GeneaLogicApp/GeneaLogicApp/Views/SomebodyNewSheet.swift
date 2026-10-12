import GeneaLogicArchive
// Named to read `ScoredMatch`'s members under `MemberImportVisibility` — see `ReviewItem`.
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// The confirm step in front of *this is somebody new* (slice 45e): the closest existing
/// people, **with no confidence floor applied**, shown before a person is minted.
///
/// **An empty candidate list is not evidence that a person is new.** The matcher's one
/// deliberate blind spot is the name it cannot recognize at all — `Zelig` and `Sidney`
/// are the same man in this corpus and score near zero against each other until a variant
/// table exists — so an empty queue is where it is *least* trustworthy, and a one-click
/// "create new" would mint duplicates precisely there. Duplicates are what merge (45f)
/// then has to clean up, so the cheap mitigation is this: show what a zero floor turns up,
/// with its real scores and the reason it fell short, and let the human rule it out.
///
/// The scores here are routinely low by construction — that is the point. A 31 with a name
/// that didn't match is not a suggestion; it is a **prompt to look**, in case the archive
/// already holds this person under a spelling the matcher can't reach.
struct SomebodyNewSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let item: ReviewItem

    /// The below-threshold candidates, **loaded by the host before presenting**.
    ///
    /// Not `@State` filled in `.onAppear`, for a layout reason as much as the one that bit
    /// the resolve-sheet accessory: `.presentationSizing(.fitted)` measures content once at
    /// open and does not regrow (see `Layout.FormSheet`), so a sheet that arrives empty and
    /// fills in afterwards is sized for the wrong content — and the height floor that
    /// compensated for that is what made the empty case a tall box of margins.
    let closest: [SuggestedLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            closestSection
            Divider()
            footer
        }
        .padding(Layout.sheetPadding)
        // **A confirm step, sized like a form, not like a content pane.** With candidates it
        // needs room for a scrolling list; with none its whole content is three short
        // paragraphs, and a 380pt floor turned that into a centred island with huge margins
        // above and below. The floor now applies only to the case that has a list in it.
        .frame(
            minWidth: Layout.FormSheet.minWidth,
            idealWidth: Layout.ContentSheet.idealWidth,
            maxWidth: .infinity,
            minHeight: closest.isEmpty ? nil : Layout.ContentSheet.minHeight,
            idealHeight: closest.isEmpty ? nil : Layout.ContentSheet.idealHeight,
            maxHeight: closest.isEmpty ? nil : .infinity
        )
        .presentationSizing(.fitted)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Create a Person from “\(item.recordedName)”?")
                .font(.headline)
            Text(
                "This mints a new person from the recorded name and links this mention to "
                    + "them. Check the closest existing people first — the matcher can’t "
                    + "recognize a name it has never seen in this form, so a low score "
                    + "isn’t proof this person is new."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var closestSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Closest Existing People")
                .font(.subheadline.weight(.semibold))

            if closest.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // The way back, right where the duplicate would be minted: if the person
                // this list can't show you is the one you rejected, restoring beats
                // creating a second copy of them.
                RestoreRejectedButtons(item: item)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(closest, id: \.personID) { candidate in
                            ClosestRow(
                                candidate: candidate,
                                person: model.persons.first { $0.uid == candidate.personID },
                                onLink: {
                                    // Reached through `confirm`, not `link()`: the matcher
                                    // ran and produced this breakdown, so the record has
                                    // to store it. `link()`'s honest minimum is a claim
                                    // that nothing was computed (45c).
                                    model.confirmSuggestion(candidate)
                                    dismiss()
                                })
                        }
                    }
                }
            }
        }
    }

    /// What an empty "closest" list means — which is **not** always "nobody resembles this
    /// name".
    ///
    /// `suggestLinks` applies the skip rules whatever the floor, so a pair the user rejected
    /// earlier is absent from this list too. Saying nobody resembles the name would then be
    /// flatly false, and false in the worst possible place: the step whose entire job is to
    /// stop a duplicate being minted, about the one person the archive already holds. So a
    /// rejection is named instead — the same distinction
    /// `ReviewItem.noCandidateExplanation(floor:)` draws for the pane behind this sheet, and
    /// the CLI's `noCandidateLine` for the shell.
    private var emptyMessage: String {
        if model.persons.isEmpty {
            return "This archive has no people yet."
        }
        if item.rejectedCount > 0 {
            let rejected =
                item.rejectedCount == 1
                ? "One candidate here was rejected earlier"
                : "\(item.rejectedCount) candidates here were rejected earlier"
            return "\(rejected), and a rejected pair isn’t offered again — so this list can’t "
                + "tell you the archive doesn’t already hold this person. Nobody else "
                + "resembles the name at any score."
        }
        return "No one in this archive resembles this name, at any score. That’s not proof — "
            + "the matcher can’t see a name it has never met in this form."
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                model.createPersonForReviewItem(item)
                dismiss()
            } label: {
                Label("Create Person and Link", systemImage: "person.fill.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            // It *looked* like the default action without being one, so Return did nothing.
            // Prominent styling is a promise about the keyboard as much as the eye.
            .keyboardShortcut(.defaultAction)
            Text("⌘Z undoes both")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            CancelSheetButton()
        }
    }
}

/// One below-threshold candidate: who they are, what they scored, and why they fell short
/// — with the option to link them after all.
private struct ClosestRow: View {
    let candidate: SuggestedLink
    let person: PersonSummary?
    let onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(person?.displayName ?? candidate.personID.raw)
                    .font(.callout.weight(.medium))
                Text("\(candidate.match.aggregateConfidence)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Link Instead", action: onLink)
                    .controlSize(.small)
            }
            // The whole breakdown, not a summary: the reader is being asked to overrule a
            // score, and "name didn't match" is the sentence that decides it.
            MatchBreakdownView(breakdown: candidate.match.breakdown)
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Layout.rowCornerRadius))
    }
}

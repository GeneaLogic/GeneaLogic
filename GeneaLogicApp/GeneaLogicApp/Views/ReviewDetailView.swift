import GeneaLogicArchive
// Named to read `ScoredMatch`'s members under `MemberImportVisibility` — see `ReviewItem`.
import GeneaLogicMatch
import GeneaLogicModel
import SwiftUI

/// The Review section's detail pane: one unresolved mention, what the record states about
/// it, and everyone the matcher thinks it might be — each with its decomposed reasoning
/// and the three triage outcomes (slice 45e).
///
/// **Three outcomes, not two.** Confirm and reject are per candidate; *somebody new* is a
/// judgement about the mention, and it is the outcome the matcher can never propose —
/// which is exactly why it is always available here and never pre-selected. It routes
/// through a confirm step that shows what a zero floor turns up first
/// (`SomebodyNewSheet`), because an empty candidate list is where the matcher is least
/// trustworthy rather than proof of anything.
struct ReviewDetailView: View {
    @Environment(ArchiveModel.self) private var model
    let item: ReviewItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                recordedSection
                candidatesSection
                somebodyNewSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.recordedName)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text(item.recordedMention.role.displayName)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.secondary)
                // Jumping to the document is the point: triage is a judgement about a
                // record, and the record is one click away rather than transcribed here.
                // Styled like the Sources rows' jump — see the note in
                // `ReviewFactsDetailView`; `.link` inside a `.secondary` header is a
                // navigation affordance that looks like a caption.
                Button {
                    model.navigateToArtifact(item.mention.artifact)
                } label: {
                    HStack(spacing: 4) {
                        Text(item.artifactTitle)
                        Image(systemName: "arrow.up.right")
                            .imageScale(.small)
                    }
                    .foregroundStyle(Color.accentColor)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show this artifact on the Artifacts tab")
            }
            .font(.callout)
        }
    }

    // MARK: - What the record states

    /// The mention's own recorded facts (44h) and recorded age — the evidence the fact
    /// dimensions were scored from, shown so a reviewer can check the reasoning against
    /// the source rather than take it on faith.
    @ViewBuilder
    private var recordedSection: some View {
        let facts = item.recordedMention.facts
        // The same freeform attribute the 42c suggestion path reads (`attributes` is the
        // mention's record-specific bag; there is no typed age field).
        let age = item.recordedMention.attributes?["ageAsRecorded"]?.trimmedNonEmpty
        if !facts.isEmpty || age != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("What This Record States")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    if let age {
                        Text("Recorded age: \(age)")
                            .font(.callout)
                    }
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        Text(Self.line(for: fact))
                            .font(.callout)
                    }
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    /// One recorded fact as a line, dates EDTF-glossed as everywhere else in the app.
    private static func line(for fact: RecordedFact) -> String {
        var parts = [fact.type.displayName]
        if let value = fact.value?.trimmedNonEmpty { parts.append("“\(value)”") }
        if let date = fact.date?.trimmedNonEmpty {
            parts.append(EDTFDate.parse(date)?.humanDescription ?? date)
        }
        if let place = fact.place?.trimmedNonEmpty { parts.append(place) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Candidates

    @ViewBuilder
    private var candidatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Who This Might Be")
                .font(.headline)

            if item.candidates.isEmpty {
                Text(item.noCandidateExplanation(floor: Archive.defaultMinimumConfidence))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                RestoreRejectedButtons(item: item)
            } else {
                Text(
                    "Read the reasoning, not the score. Confirming stores exactly these "
                        + "numbers — a match accepted on a weak birth year still says so later."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    ForEach(item.candidates) { candidate in
                        CandidateCard(
                            candidate: candidate,
                            subject: .candidate(
                                CandidateTarget(
                                    row: item.target, person: candidate.suggestion.personID)),
                            keyCaption: candidate.id == item.candidates.first?.id
                                ? ArchiveCommand.reviewKeyCaption(for: item.target.lane) : nil)
                    }
                }
            }
        }
    }

    // MARK: - Somebody new

    /// Always offered, never implied. The action is available whatever the candidates say
    /// — a weak list is as likely to be a new person as an empty one — and it always goes
    /// through the confirm step, which is where the below-threshold candidates are shown.
    private var somebodyNewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            CommandButton(.somebodyNew, on: .review(item.target))
            Text(
                "Creates a person from “\(item.recordedName)” and links this mention to "
                    + "them. You’ll see the closest existing people first."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The way back from a rejection: one button per tombstone on this mention, naming the
/// person it forecloses.
///
/// Shown wherever the "rejected earlier and isn't offered again" wording is, because a
/// statement that a decision is blocking you should carry its own undo. **Per pair, not a
/// bulk "restore all":** each tombstone is an independent verdict (45c), and the point of
/// the sentence is that a *specific* person is being withheld — so the button names them.
///
/// Restoring is uid-addressed deletion of the tombstone, undoable like any unlink, and the
/// candidate reappears in the queue on the refresh that follows.
struct RestoreRejectedButtons: View {
    @Environment(ArchiveModel.self) private var model
    let item: ReviewItem

    var body: some View {
        if !item.rejectedLinks.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(item.rejectedLinks, id: \.uid) { link in
                    Button {
                        model.restoreRejectedPair(link)
                    } label: {
                        Label(
                            "Restore \(name(of: link.personUid))",
                            systemImage: "arrow.uturn.backward")
                    }
                    .help("Bring this candidate back into the queue (⌘Z to undo)")
                }
            }
        }
    }

    /// The rejected person's display name. A tombstone can name a person since deleted
    /// (§2.3 — removals don't cascade), and restoring that pair would put back a candidate
    /// who no longer exists; the uid is the honest label there, and the engine simply won't
    /// suggest a person that isn't in the corpus.
    private func name(of personID: PersonID) -> String {
        model.persons.first { $0.uid == personID }?.displayName ?? personID.raw
    }
}

/// The Review detail's empty state. Two different situations, and they mean opposite
/// things: a worklist with rows means *pick one*, an empty one means the archive has
/// nothing waiting. Covers both lanes since 45i — a name to resolve, or a person whose
/// sources have facts still to record.
struct ReviewDetailPlaceholder: View {
    let hasWork: Bool

    var body: some View {
        if hasWork {
            ContentUnavailableView(
                "Select an Item", systemImage: "tray.full",
                description: Text(
                    "Choose an unresolved name to see who it might be, or a person to "
                        + "record what their sources state."))
        } else {
            ContentUnavailableView(
                "Nothing Waiting", systemImage: "checkmark.circle",
                description: Text(
                    "Nothing is waiting on review. Suggestions are recomputed each time "
                        + "you open this section."))
        }
    }
}

/// One candidate: who they are, what agreed, the full breakdown, and the two verdicts.
private struct CandidateCard: View {
    let candidate: ReviewCandidate
    /// This card's candidate, for its Confirm and Reject (slice 83b).
    let subject: CommandSubject
    /// The keys, on the top candidate only: they act on it, and no other.
    let keyCaption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayName)
                        .font(.headline)
                    Text(candidate.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // The aggregate, labelled as what it is: a sort key. It sits above the
                // rows that justify it, never in place of them.
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(candidate.confidence)")
                        .font(.title3.monospacedDigit())
                    Text("confidence")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .help("A roll-up for ordering the queue. The dimensions below are the evidence.")
            }

            let agreement = candidate.suggestion.match.breakdown.agreementLine
            if !agreement.isEmpty {
                Text(agreement)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            MatchBreakdownView(breakdown: candidate.suggestion.match.breakdown)

            SourceWeightsRow(
                sourceAuthority: candidate.suggestion.match.sourceAuthorityWeight,
                informationQuality: candidate.suggestion.match.informationQualityWeight)

            HStack(spacing: 8) {
                // Neither is prominent (slice 83, fork 3): that says "the likely answer",
                // which is the one thing this card must not claim. The caption says where
                // the keys land. They act on this card's candidate, which on any card but
                // the top is not the one the keys would (slice 83b).
                CommandButton(.confirmCandidate, on: subject)
                CommandButton(.rejectCandidate, on: subject)
                Spacer()
                ReviewKeyCaption(
                    [keyCaption, "⌘Z undoes either"].compactMap(\.self)
                        .joined(separator: " · "))
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .rowCommandMenu(subject)
    }
}

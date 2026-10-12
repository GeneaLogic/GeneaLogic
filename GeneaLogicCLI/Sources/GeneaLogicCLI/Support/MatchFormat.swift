import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// Shared rendering for `genea match …` — the text form of what the app's triage
/// queue will draw (§4.6), and the third register beside `ConclusionsFormat` (the
/// conclusion records) and `ArtifactFormat` (the evidence a document carries).
///
/// **The breakdown is the output, not the aggregate.** `aggregateConfidence` orders
/// a queue and nothing else; every surface that shows a suggestion is supposed to
/// explain it from the decomposed dimensions instead of from an unexaminable
/// percentage. So `suggest` carries the score as a sort key in a column, and
/// `explain` prints the dimensions one per line with their kind, score and gloss —
/// which is the whole reason the format stores a breakdown rather than a number.
enum MatchFormat {

    // MARK: - The pipe register

    /// The stand-in for a column that has no value on this row — a mention nothing
    /// matched has no candidate person and no score.
    ///
    /// **Not an empty column**, which is what the other list commands use for an
    /// absent value (`person list` prints an empty name so `cut -f2` can't mistake
    /// decoration for a name). Here the absent columns are in the *middle* of the
    /// row, and consecutive tabs collapse under a shell `read`'s default `IFS`,
    /// shifting every later field left. A `-` keeps the column count fixed for
    /// `read`, `cut` and `awk` alike, and it can never be mistaken for a `PER-` uid
    /// or a score: `genea match confirm --person -` fails loudly rather than
    /// resolving to something.
    static let absentColumn = "-"

    /// `"ART-…\tp1\tPER-…\t71\tSzlama Feldberg\tSolomon Feldberg"` — one scored pair,
    /// addressable columns first.
    ///
    /// Columns 1–3 are exactly the triple `match explain|confirm|reject|unreject`
    /// take, so a suggestion pipes into a decision without reshaping:
    /// `genea match suggest … | cut -f1-3`. The trailing two are the names, which are
    /// what makes the row readable — they are looked up rather than carried on
    /// `SuggestedLink`, which is deliberately free of display fields that would go
    /// stale the moment either record is edited.
    static func suggestionLine(
        _ suggestion: SuggestedLink, in archive: Archive, recordedName: String?
    ) -> String {
        [
            suggestion.mention.artifact.raw,
            suggestion.mention.localRef,
            suggestion.personID.raw,
            "\(suggestion.match.aggregateConfidence)",
            column(recordedName),
            archive.person(withID: suggestion.personID)
                .map(ConclusionsFormat.displayNameOrPlaceholder) ?? "",
        ].joined(separator: "\t")
    }

    /// A mid-row text column, with `absentColumn` standing in for an empty value.
    ///
    /// `nameAsRecorded` is never `nil` on a real mention, but nothing validates it
    /// against the empty string — `genea mention add --name ""` reaches here — and the
    /// recorded name sits *between* the score and the person, so an empty one collapses
    /// under `read` exactly like the placeholders this file already guards. The rule is
    /// positional, not about which field it is: only a trailing column may be blank.
    private static func column(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return absentColumn }
        return text
    }

    /// The same row for an **unresolved mention nothing scored** — the case that
    /// exists only in the artifact direction, and the one `MentionSuggestions` was
    /// added for.
    ///
    /// Dropping it would fold "this record names nobody", "every name on it is
    /// resolved" and "here is a name the archive has never seen" into one empty
    /// output, and only the third has work attached to it. **It is not evidence that
    /// the person is new** — the matcher's blind spot is the name it cannot recognize
    /// at all — so the row says what actually happened (nothing reached the floor)
    /// rather than proposing anything.
    /// `rejectedCount` is why this takes an argument the engine doesn't supply.
    /// Candidates are dropped for **two** reasons — scoring under the floor, and being
    /// foreclosed by a tombstone — and the result cannot tell them apart. Naming only
    /// the floor would misattribute the second: a user who had rejected the one
    /// candidate would lower `--min-confidence`, see the identical row, and have no way
    /// to learn that the pair they are looking for is one `match unreject` away.
    static func noCandidateLine(
        _ mention: MentionRef, recordedName: String?, minimumConfidence: Int,
        rejectedCount: Int
    ) -> String {
        var reason = "(no candidate scored \(minimumConfidence) or above"
        if rejectedCount > 0 {
            reason += "; \(rejectedCount) rejected on this mention"
        }
        return [
            mention.artifact.raw,
            mention.localRef,
            absentColumn,
            absentColumn,
            column(recordedName),
            reason + ")",
        ].joined(separator: "\t")
    }

    /// `"PER-…\tPER-…\t83\tSzlama Feldberg\tSzlama Feldberg"` — one duplicate candidate
    /// (slice 45j), addressable columns first, like every row above.
    ///
    /// The two uids are in the pair's canonical order (lower uid first), which is
    /// **not** an answer to `person merge`'s question: that command takes the absorbed
    /// record as its argument and the survivor as `--into`, and which is which is a
    /// human judgement about which record is better built, not something a sort order
    /// can decide. So the columns feed a merge, they don't compose into one.
    static func duplicateLine(_ candidate: DuplicateCandidate, in archive: Archive) -> String {
        [
            candidate.person1.raw,
            candidate.person2.raw,
            "\(candidate.match.aggregateConfidence)",
            column(
                archive.person(withID: candidate.person1)
                    .map(ConclusionsFormat.displayNameOrPlaceholder)),
            column(
                archive.person(withID: candidate.person2)
                    .map(ConclusionsFormat.displayNameOrPlaceholder)),
        ].joined(separator: "\t")
    }

    // MARK: - The explain register

    /// One dimension of the breakdown: `"birthYear    within  78  3 years apart"`.
    ///
    /// A `nil` dimension prints `(not assessed)` rather than a zero. The distinction
    /// is the matcher's central honesty rule — the documents this reads are silent
    /// about most things, and *not assessed* is not *assessed and failed*. Rendering
    /// an absent dimension as `0` would tell a reviewer the record disagreed when it
    /// simply didn't say.
    ///
    /// `deltaUnit` is supplied per dimension because `delta` means different things:
    /// years apart for `birthYear`, but for a name it is `100 - score` — the same
    /// number twice — so the name row passes `nil` and prints it once.
    ///
    /// `relational` marks the two dimensions the roll-up reads **positive-only**
    /// (slice 45g). One that didn't agree still prints — the record named a spouse,
    /// and that they disagree is a lead — but it is labelled `(not scored)`, because a
    /// bare `none 0` beside a confidence figure reads as *this is what dragged the
    /// score down*, and here it dragged nothing.
    static func dimensionLine(
        _ label: String, _ dimension: MatchDimension?, deltaUnit: String? = nil,
        algorithm: String? = nil, relational: Bool = false
    ) -> String {
        guard let dimension else { return "  " + pad(label, 12) + "(not assessed)" }

        // The kind is padded too, so the scores line up into a column a reader can
        // scan down. `known-variant` is wider than the pad and overflows it rather
        // than being cut — a truncated `known-var` would name an algorithm that
        // doesn't exist.
        var parts = ["\(dimension.score)"]
        if let deltaUnit, let delta = dimension.delta {
            parts.append("\(delta) \(deltaUnit)")
        }
        // Slice 45h moved place depth out of `kind` into `granularity`, so `within`
        // alone no longer says what agreed. Printed as a gloss rather than a second
        // padded column: only one dimension sets it, and a column empty on four rows
        // out of five is noise. Rendered verbatim, so a value this build doesn't know
        // (`admin2`, or a pre-45h `county` relocated on read) still reaches the reader.
        if let granularity = dimension.granularity {
            parts.append("to \(granularity.rawValue)")
        }
        if let algorithm { parts.append("[\(algorithm)]") }
        // Mirrors `Matcher.counts(relational:)`, which is the rule's home. Read across
        // the module boundary rather than imported, for the same reason `(not
        // assessed)` above is: the CLI renders `GeneaLogicMatch`'s output without
        // depending on it (slice 45d).
        if relational, dimension.kind == .none { parts.append("(not scored)") }
        return "  " + pad(label, 12) + pad(dimension.kind.rawValue, 10)
            + parts.joined(separator: "  ")
    }

    /// Left-aligns `text` in a column at least `width` wide, **never truncating**.
    ///
    /// `String.padding(toLength:withPad:startingAt:)` — the obvious call — silently
    /// *cuts* anything longer than the target, so a column sized for today's values
    /// mangles tomorrow's. Every vocabulary rendered here is one someone will extend.
    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(1, width - text.count))
    }

    /// `"LNK-…  human-confirmed  confidence 71  reviewed by R. Feldberg  2026-07-26…"`
    /// — a verdict already on disk for the pair being explained.
    ///
    /// `explain` deliberately applies no skip rules, so it is the one surface that can
    /// answer "why did this pair stop being offered?" — and the answer is usually a
    /// tombstone. The **stored** confidence is printed beside it because it is not
    /// necessarily today's: a breakdown records what the matcher said when a human
    /// ruled on it, and a divergence from the score above this line is exactly what an
    /// audit is looking for.
    static func verdictLine(_ link: EvidenceLink) -> String {
        var parts = [
            link.uid.raw, link.reviewStatus.rawValue,
            "confidence \(link.aggregateConfidence)",
        ]
        if let reviewer = link.reviewedBy, !reviewer.isEmpty {
            parts.append("reviewed by \(reviewer)")
        }
        if let at = link.reviewedAt, !at.isEmpty { parts.append(at) }
        return parts.joined(separator: "  ")
    }
}

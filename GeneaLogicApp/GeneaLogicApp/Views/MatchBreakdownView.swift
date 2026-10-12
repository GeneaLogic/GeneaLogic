import GeneaLogicModel
import SwiftUI

/// Draws a `MatchBreakdown` as **reasoning** — one row per §4.6 dimension, with its kind,
/// score and gloss — plus any conflicts (slice 45e).
///
/// This is what the format stores a decomposed breakdown *for*. The alternative, an
/// aggregate percentage, cannot be argued with: "71%" gives a reviewer nothing to check,
/// while "the name matched exactly, the record names the known spouse, the birth year is
/// three years out" is a claim they can accept or refute against the document in front of
/// them.
///
/// The honesty rules live in `MatchBreakdown+Display` — *not assessed* rather than zero,
/// a relational disagreement reported but *not scored*, granularity rendered verbatim —
/// so this file is only layout.
struct MatchBreakdownView: View {
    let breakdown: MatchBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Conflicts first, above the rows. A conflict drops confidence sharply rather
            // than being averaged in (§4.6), so it is the finding a reviewer must see, not
            // a footnote under five rows of agreement.
            if !breakdown.conflicts.isEmpty {
                conflicts
            }
            ForEach(breakdown.displayDimensions) { dimension in
                DimensionRow(display: dimension)
            }
        }
    }

    private var conflicts: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(breakdown.conflicts, id: \.self) { conflict in
                Label(conflict, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.bottom, 2)
    }
}

/// The two GPS source weights (§4.6) that scale everything the breakdown says.
///
/// Shown because they are the difference between a name agreement on a vital register and
/// the same agreement on a compiled tree — a reviewer who can't see them can't judge the
/// roll-up. Shared by the three surfaces that draw a breakdown rather than re-written in
/// each; `ViewThatFits` because the artifact inspector is too narrow for one line and split
/// "Source / authority" across two.
struct SourceWeightsRow: View {
    let sourceAuthority: Int
    let informationQuality: Int

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                authority
                quality
            }
            VStack(alignment: .leading, spacing: 1) {
                authority
                quality
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
    }

    private var authority: some View {
        Text("Source authority \(sourceAuthority)").fixedSize()
    }

    private var quality: some View {
        Text("Information quality \(informationQuality)").fixedSize()
    }
}

/// One dimension row: label, kind, score, gloss — or *not assessed*.
///
/// **Has to survive a narrow container.** It is drawn in the Review pane (wide) and in the
/// artifact inspector's mention row (~250pt), and the first attempt hyphenated its way to
/// "Pho-netic" in the latter. The label, kind and score are therefore
/// `fixedSize`-and-never-wrapped — they are the row's meaning, and a broken word costs more
/// than a wrapped tail — while the gloss is the one part allowed to flow onto another line.
private struct DimensionRow: View {
    let display: MatchDimensionDisplay

    var body: some View {
        // One line where it fits, otherwise the gloss drops beneath the verdict. Squeezing
        // the gloss into a leftover column instead is what turned "via Daitch Mokotoff"
        // into "Mokotof / f" in the inspector — and a keyer's name broken across lines
        // names no keyer.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                label
                verdict
                gloss
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    label
                    verdict
                    Spacer(minLength: 0)
                }
                if display.gloss != nil {
                    HStack(spacing: 6) {
                        Spacer().frame(width: Self.labelWidth)
                        gloss
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    /// The label column, sized so every row's verdict starts at the same x.
    private static let labelWidth: CGFloat = 76

    private var label: some View {
        Text(display.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize()
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    /// Kind + score, or *not assessed* — the part that must never wrap or hyphenate.
    @ViewBuilder
    private var verdict: some View {
        if let kindLabel = display.kindLabel, let scoreText = display.scoreText {
            Text(kindLabel)
                .font(.caption.weight(.medium))
                .fixedSize()
            Text(scoreText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
            if display.isUnscored {
                // Slice 45g: relational evidence is positive-only. Without this the row
                // reads "No match · 0" beside a confidence figure, which says *this is
                // what dragged the score down* — and it dragged nothing.
                Text("not scored")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .help(
                        "A stated relation whose names disagree is reported but never "
                            + "counted against the match — a maiden name against a "
                            + "married one is the common case, not the suspicious one.")
            }
        } else {
            // Never `0`: the record didn't say, which is not the same as saying no.
            Text("not assessed")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
                .help("This record states nothing the matcher could compare here.")
        }
    }

    @ViewBuilder
    private var gloss: some View {
        if let gloss = display.gloss {
            Text(gloss)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

# 45o — place specificity from the archive's own places

**45o ✅ — place specificity from the archive's own places.** Shipped, with two
departures from the plan below, both settled before implementation. **The rule is
narrower:** promotion needs the value written as the **leading component** of a
multi-component string, not merely a non-final one — `Brooklyn, NY, USA` makes the
looser rule promote a bare `NY` to town strength, and `87 Sackman Street, Apt 4,
Brooklyn, NY` makes the stricter mirror rule reject `Brooklyn`. **The layer is wider:**
the vocabulary is built from **every place string in the archive** (artifact locations,
event locations, mention facts, person facts, relationship facts) via a new index
`place` projection — schema **v3**, rebuildable cache, still no format change. That
projection is what makes the vocabulary affordable *identically* on every entry point,
which is a correctness requirement rather than an optimization: `matchScore` explains a
row the queue produced, and `confirm(match: nil)` writes a recomputed breakdown.
536 macOS / 533 Linux engine tests (+32), CLI 111 on Linux, app builds. Spec prose
updated in both copies (an exact match may now carry `specific`); `toolIdentifier` →
`genealogic-matcher/4`. **On the real archive this changes no score** — none of its
bare values (`Poland`, `Russia`, `New York`, `NY`) leads a qualified string — so the
hand-test is the tripwire (all 14 confirmed links unchanged) plus a constructed
bare-town case. *Original plan follows.* Raised by
45n's `/code-review`, which pressed on the one consequence 45n accepts rather than
solves: an archive that records towns bare — `Łomża`, never `Łomża, Poland` — gets **no
place corroboration at all**, because `unqualified` sits under the roll-up's threshold
by design. 45n's answer is that a matcher with no gazetteer genuinely cannot tell those
records from bare countries. **This slice gives it the missing knowledge without a
gazetteer:** if *any* place string in the archive writes `Łomża` as a non-final
component, the archive has itself proved `Łomża` lies below the country level, and the
`unqualified` band collapses to `specific` for that value. The real corpus already
supplies exactly this — it holds both `Rypin, Poland` and bare `Poland`.
**Layer:** `GeneaLogicMatch` + the projection seam; **no format change**. The scorer
stays archive-free, so the component index is built on the archive side and handed in
as a value, the way `partnerNames`/`parentNames` already are — a `PlaceVocabulary` in
`MatchViews`, not an `Archive` reference reaching into `PlaceMatching`.
**Forks to settle first:** whether a value seen *both* ways (a town in one string, the
final component in another) resolves as specific or stays unqualified; whether the
vocabulary is built from all places or birth places only; and whether `matchScore`'s
explain path pays to build it (it reads one pair and would need every place in the
archive). **Verification:** the bare-town archive corroborates, a genuinely
country-only archive still does not, and — the tripwire — an archive whose places are
all fully qualified scores **identically to today**.

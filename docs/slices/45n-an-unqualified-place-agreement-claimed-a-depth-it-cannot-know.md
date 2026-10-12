# 45n — an unqualified place agreement claimed a depth it cannot know

**45n ✅ — an unqualified place agreement claimed a depth it cannot know.** Shipped as
specced below, the fork intact. 504 macOS / 501 Linux engine tests (+4); CLI and app
untouched. **The hand-test carried the slice:** all 14 confirmed links in a copy of the
real archive re-measured — three fell 80 → **70** (the three whose only corroboration was
a bare-country place), eleven untouched, all still above the floor, and every affected
mention still ranks its correct person **first** by a wider margin than before (70 vs 7).
45j's minted duplicate went 83 → **68**, still found; the false Sidney/Gussie pair
15 → **7**. **The pinned 45j bands did not move**, which is what proves the change stayed
inside its intent. *Original plan follows.* **Layer:** model + match +
**spec in both copies**. Raised by 45j's hand-test, **scheduled ahead of 45k** on
45h's own reasoning: it changes what gets *written into* new links' `birthPlace`
dimension, and a stored-scoring change gets dearer with every link confirmed.
**Problem:** `PlaceMatching` compares component arrays for equality *before* any
granularity reasoning runs, so two places recorded as bare `"Poland"` score
`exact / 100` — a **perfect** place match, and full corroboration. The file's own
calibration says otherwise three lines down: `coarse` is 30, commented "Two people born
in Poland is barely evidence." That band is only reachable when the strings *differ*.
In the real archive 12 of 12 single-component places are `Poland` ×7, `Russia` ×3,
`New York` ×2 — not one bare town.
**The fork, settled 2026-07-31 before any code: neither existing reading wins, because
both claim knowledge the matcher does not have.** Scoring it 100 asserts the agreement
is maximally specific; scoring it 30 asserts it is minimally specific. The matcher holds
**no gazetteer** and cannot tell a bare country from a bare town — a researcher who
recorded only `"Łomża"` named a town precisely and wrote one component. That is exactly
the error 45h corrected when it pulled `county`/`country` out of `MatchKind`, and
repeating it in the other direction is not a fix.
So: **`kind` stays `.exact`** — the normalized values *are* equal, and reporting that as
`.within` ("close enough but not equal") would be the same lie as reporting a
keyer-missed name as `.phonetic` (slice 45's reasoning) — with a **new open
`MatchGranularity` case, `unqualified`**, saying the depth is unmeasurable, and a score
of **50**. That number is chosen against one line: it sits between `coarse`'s 30 and
`specific`'s 80 and lands deliberately **below the corroboration threshold of 60**.
**Uncertainty must never manufacture confidence** — the same asymmetry that makes
relational evidence positive-only and keeps a conflict out of the mean. The dimension
still moves the weighted mean, so a bare place agreement helps a little; it just stops
counting as breadth of evidence.
**This is the first case of `kind: exact` carrying a granularity**, which the spec
currently forbids in words ("absent on an exact match, where there is no partial depth
to report"). That sentence is the bug restated: an exact agreement on one component has
a depth, and the honest report is that it cannot be measured. Both copies change.
**Scope note:** open-vocabulary and additive, so no schema bump and no migration; an
archive holding a pre-45n breakdown keeps whatever it stored, since a breakdown records
what the matcher said *then* (45c).
**Verification:** dimension tests for the new band and that multi-component equality is
**unchanged** (`Łomża, Poland` twice stays `exact/100`, no granularity); a decode test
that `unqualified` round-trips and that an unknown granularity still does;
`SchemaSpecTests` for both copies. **The pinned calibration bands (75/83/100/21/50)
must not move** — every fixture behind them uses multi-component places, so a change
that shifts one is a change that reached further than this slice intends.
**Hand-test — the 45g lesson, and the reason this slice exists at all:** re-measure all
**14 confirmed links** in a copy of the real archive. Three of them score 80 on
`name exact + birthPlace exact` and nothing else; they should land near 70, stay above
the floor, and **keep ranking their correct person first**. A slice that quietly drops a
confirmed pair out of the queue has reproduced 45g's failure with a different dimension.

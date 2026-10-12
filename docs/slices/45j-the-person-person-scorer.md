# 45j — the person↔person scorer

**45j ✅ — the person↔person scorer.** Shipped as specced below, every sub-decision
intact, including the five calibration bands — which are pinned as tests, since a doc
comment quoting a band the code doesn't produce is worse than no doc comment. 500 macOS
/ 497 Linux engine tests (+26), 111 CLI (+10). No format change; the app is untouched.
**The hand-test's useful half was the minted duplicate**: the real archive surfaces
nothing at the default floor or at 25 (one pair at 15 with `--min-confidence 1`), which
is the specced expectation but only demonstrates precision. Minting a duplicate Sidney
Feldberg put it at **83** — the documented exact-name-plus-one-corroboration band, on
real records — and `person merge` removed it, archive verifying clean.
**One finding, and it is not this slice's code:** that 83's sole corroboration was
`birthPlace exact 100` for two people both recorded as born in **"Poland"**.
`PlaceMatching` awards its `countryScore` of 30 only for *partial* agreement; two
identical single-component strings are `exact`, so country-level agreement reads as a
perfect place match. It affects the link scorer equally and predates this slice, but it
bites harder here because corroboration is also doing the source discount's job.
**Fixed in 45n**, which took this 83 down to 68. *Original plan follows.* **Problem:** merge (45f)
can combine two records for one person, but finding them is still eyeballing the
People list. **Split out of 45f by its fork (a); rescoped 2026-07-31 by its own fork
(below), which moved the app lane to 45m.** **Layer:** `GeneaLogicMatch` +
`GeneaLogicArchive` + CLI; **no format change**.

**The fork settled 2026-07-31, before any code: *not a duplicate* needs a stored
record, and that record is 45m.** The choice was a stored record (a format change) or
session-only dismissal (forgets on relaunch). Session-only loses, and not marginally:
the lane lands in the Review section, a **work-owed** surface with a counting strip and
a "Nothing to Review" empty state, so two genuinely distinct same-named relatives would
hold it permanently non-empty — degrading the whole section, not just their two rows.
45c's reasoning ("a matcher with no memory re-offers the pair forever") applies
verbatim. Settled **on principle, not on how many false pairs the real archive produces**: that
archive is a small subset of the one it will become, and GeneaLogic is not only for its
author's family — a memory design that works because the corpus is eleven curated people
is not a design.

The memory must be a **new symmetric `conclusions/` record**. It cannot be an
`EvidenceLink` (there is no mention to tombstone), and it must not be a `Relationship`
with an open type: *not the same person* is an identity assertion, not a family
relation, and every consumer of `relationships()` — Tree, Relatives, `personView`'s
partner/parent projection — would have to learn to filter it, which is exactly the
misfiling 45h corrected. A `distinctFrom: [PersonID]` field on `Person` stores each edge
twice and lets the halves disagree, the shape 45k's fork (a) already rejected. **That
record is a slice**: spec in both copies, round-trip, index, `findDanglingReferences()`,
plus 45f's merge cascade and `revertMerge`. On top of a new scorer, a new engine entry
point and a new app lane it is two slices' work — so this one stops at the engine and
the CLI, where an on-demand report nags nobody and needs no memory, and **45m** ships
the record with the lane that needs it.

**The scorer is new, not a reuse:** `Matcher.score` is mention→person, and between two
*conclusions* the two GPS weights have nothing to weigh — neither side is a source — so
a person↔person compare needs its own roll-up. Dimensions are the symmetric ones: name
over both `names` lists, `birthYear`, `birthPlace`, partner names, parent names, plus
conflict detection — which matters more here than anywhere, since two people with the
same name and *different* recorded deaths are the case this surface must not confuse.

**Sub-decisions taken while specifying:**
- **A new output type, `DuplicateScore`** — a `MatchBreakdown` plus an aggregate, and
  **no** GPS weights. Reusing `ScoredMatch` would carry two integers that mean nothing
  between two conclusions, and whatever was stored in them (0? 100?) would be a lie.
  `MatchBreakdown` *itself* is reused: its fields are already the symmetric set
  (`spouseName` reads partner-names against partner-names, `parents` likewise), and a
  second breakdown type would fork every surface that draws one.
- **The roll-up drops the source discount and nothing replaces it.** The corroboration
  factor carries the load alone, and it bites **harder** here than in the link scorer
  (uncorroborated retains `0.75`, not `0.88`): the action on offer is a destructive
  merge, so a bare name agreement must sit clearly below one the records corroborate.
- **The floor stays 50, anchored on the blind spot.** Two persons whose names *disagree
  entirely* but whose birth year, birth place and partners all agree land at exactly 50
  — admitted, at the bottom of the queue. That is the `Zelig`/`Sidney` known-variant
  case the name matcher cannot see, and it is the one pair worth keeping a zero-name
  result for. An exact-name-only pair lands at 75, a weak-phonetic-only pair at 45
  (excluded), and an exact-name pair carrying a birth-year *conflict* at 21 — so the
  grandfather/grandson case drops out on its own rather than needing a rule.
- **Death enters as conflicts, not as a dimension.** `MatchBreakdown` has no death
  field and adding one is a format change; a death-year disagreement beyond the same
  century-widening tolerance, and one person's death preceding the other's birth,
  become conflict sentences — which is where their evidential value is anyway.
- **Pairs are unordered and canonicalized by uid**, so each is offered once and nobody
  is compared with themselves.
- **No skip rules, deliberately.** In particular two persons confirmed on *different*
  mentions of the same artifact are **not** skipped: it looks like proof they are
  distinct, but a user who linked a mention to a duplicate without noticing is precisely
  the case this surface exists to catch.

**Contents:** `DuplicateMatcher` in `GeneaLogicMatch`; `NameMatching`'s names×names
best-of; `Archive.duplicateCandidates(minimumConfidence:limit:)`, a pairwise pass
(quadratic, correct at this scale — blocking stays out of the mini-phase) returning
transient ranked pairs; `genea person duplicates` over `MatchFormat`'s existing
breakdown rendering. **Out of scope:** the lane and the *not a duplicate* record
(**45m**); a per-person `duplicateCandidates(for:)` direction (45m's lane may want it
and can add it then); duplicate *artifact* detection; blocking.
**Verification:** unit tests per dimension plus golden pairs from the real corpus;
engine tests that each unordered pair is offered once, that a merged pair stops being
offered, and that ordering is deterministic; CLI tests on macOS **and Linux**.
**Hand-test:** `genea person duplicates` over a copy of the real archive should surface
*few or no* candidates — a detector that finds duplicates in a curated 11-person archive
is miscalibrated — so the honest pass is minting one through 45e's *somebody new*,
watching it appear, and merging it away.

# 45m — the dismissal record + the duplicates lane

**45m ✅ — the dismissal record + the duplicates lane** (spec + model + engine + CLI + app).
Shipped as specced below, all four decisions intact. 582 macOS / 579 Linux engine tests
(+24), 133 CLI (+15), app builds. **Two things the spec did not anticipate**, both
recorded in SLICE-LOG: §7's open-vocabulary *rationale* had to widen (dismissal subject
maps onto no external standard — it is open because an unknown value has a safe reading
and a closed one costs a load failure), and the lane's Merge… does **not** go through
`PersonPickerSheet` after all — the pair is already known, so the pane offers the two
directions and a picker over every person would re-ask a question the row answered.
**A format change**, and the mini-phase's other one. Split from 45j on 2026-07-31 by its
fork, which settled *that* the memory is a stored record; this slice is the record.
**Problem:** 45j's `duplicateCandidates` and 45l's suggested relationships both propose
pairs a human can decline, and neither decline has anywhere to live — no mention, so no
`EvidenceLink` tombstone (45c). Without it both lanes re-offer a declined pair at every
launch, in the one section whose meaning depends on reaching empty.
**Layer:** spec in **both copies** + `GeneaLogicModel` + engine + CLI + app.

**Specced with both consumers in view** (45l fork (b)): the record has to carry *what was
declined*, because "these two are not the same person" and "this record does not make A
B's parent" are different assertions over the same pair of `PersonID`s. One record type
with a typed subject, not two — and not a `Relationship` with an open type, for the
reasons in 45j's fork.
**All three forks settled 2026-08-02, before any code:**
- **The subject vocabulary is open.** The §7 reading that decided it is not "does
  GeneaLogic own this axis" — it does — but **what an unrecognized value costs**. Open,
  an unknown subject round-trips verbatim and suppresses nothing, so the pair is simply
  re-offered: the pre-45m behaviour, not corruption. Closed, an archive a later
  GeneaLogic wrote fails to **load**, which is 44h's failure verbatim. The evidence that
  the set is not exhaustive is that it grew **twice before shipping** — 45j's *not the
  same person* and 45l's *not this relationship*, inside one mini-phase.
- **The breakdown is stored when there is one, and the field is optional.** 45c's reason
  applies unchanged (declining a *strong* candidate is the interesting record, and a
  stored breakdown is a verdict at a time), but 45l's suggestions are derived from a
  stated mention edge plus two confirmed links and carry no score — synthesizing one
  would be a lie in the shape of a number.
- **Deletion alone reverses it; there is no fourth verb here either.** Removing the
  record returns the pair to the queue with no state left over — precisely what
  `unlink()` already is for a rejection tombstone. A dismissal *is* the negative record,
  so a tombstone of a tombstone has nothing to mean. `undismiss` is addressed by **pair +
  subject** (what the lane and the CLI hold), resolving to the record and deleting it.

**Taken while specifying:** the subject is the assertion type itself (`same-person`,
`parent-child`, `couple`, …), one open vocabulary rather than a discriminator plus a
payload — so a future relationship type flows through as `.unknown` with no second
spelling. Symmetry is per subject: `same-person` and `couple` are symmetric and stored in
canonical uid order, `parent-child` is **directional** (§4.5's convention, so the
direction means one thing across both layers) and an unknown subject is read as
directional, the conservative answer `MentionRelationship.statesSameRelationship` already
gives. Declining a `parent-child` suggestion must not foreclose a `couple` one.
**What the record has to reach, whatever its shape:** 45f's merge cascade — a dismissal
naming the absorbed uid is repointed, a dismissal that becomes self-referential is dropped
and **reported** (the user contradicting an earlier judgement, exactly 45f's fork (b)
shape), and `revertMerge` restores both; `findDanglingReferences()`; and the index.
**App side:** 45j's candidates as a **third lane** in the Review section, rendering the
same decomposed breakdown the other lanes do, each row offering **Merge…** (45f, via the
existing `PersonPickerSheet` path) or **Not a duplicate**.
**The lane must not call `duplicateCandidates()` synchronously on the main actor** —
raised by 45j's review. Every other Review sweep is a linear read this archive can't
measure; this one is `n(n−1)/2` scored pairs under `Archive`'s lock, so it wants an
off-main read and a progress affordance rather than the existing `refreshReviewWorklist`
chokepoint. **Settled 2026-08-02: the off-main half lands here** — and it did need an engine
change after all, which `/code-review` caught: scoring inside `withIndex` holds the lock
for the whole quadratic pass, so a background call relocates the freeze instead of
removing it. `duplicateScanInput()` now reads under the lock and
`Archive.duplicateCandidates(in:)` scores a snapshot, pure and lock-free. **45p** keeps what is genuinely
its own slice: the candidate-blocking pre-filter, behind the same API, on 45b's standing
condition that a true superset changes no results.
**Verification:** round-trip test for the new type (the non-negotiable), `SchemaSpecTests`
for both spec copies, decode of a pre-45m archive, engine tests that a dismissed pair
stops being offered and that the merge cascade + revert round-trip through it, CLI on
macOS **and Linux**. **Hand-test:** mint a duplicate, see it in the lane, decline it,
**relaunch** and confirm it stays gone; then mint another, merge it away from the lane,
and ⌘Z.

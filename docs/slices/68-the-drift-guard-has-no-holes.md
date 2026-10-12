# 68 — the drift guard has no holes ✅

Specced 2026-10-04 from the [exit review](workstream-2-exit-review.md).

**Problem.** 58's drift guard has two holes. Every conclusion removal — delete a person,
relationship, link or dismissal, a merge, a supersede — unlinks through `removeAuthoredFile`,
which never checks, and the undo writes back the index's stale copy. And while an interrupted
write is unresolved the guard is off **archive-wide**, across launches, until *Accept Current
Contents*.

**Layer.** Engine only; no format change (`.index/interrupted` is machine-local and outside the
spec).

**Forks (settled 2026-10-04, as recommended):**

- **(a) The unlink chokepoint checks.** `removeAuthoredFile` runs `refuseToOverwriteDriftedRecord`
  as `writeAuthoredJSON` does — structural, covering every conclusion removal. `removeArtifact`
  stays exempt (the folder goes intact to `.trash/`). A refused delete leaves no stale undo.
- **(b) Multi-record mutations check every path before touching any.** (a) alone would make a
  merge refused at its unlink a half-applied cascade — writes landed, then the throw, and
  `withState` would arm the interrupted-write flag on it. `mergePersons`, `revertMerge`,
  `link`/`confirm`/`reject` when superseding, and `undismiss` pre-flight every path they write
  or unlink, in the shape of `refuseToTouchDriftedArtifact`. This also closes the same gap the
  merge's *writes* already had. **As built (`/code-review`):** one `applyCascade(writing:removing:)`
  pre-flights and executes the same two lists, so a step added to a cascade is checked by
  construction; every conclusion write and removal goes through it or its `write`/`remove`.
- **(c) The exemption is the crash's own bytes, by path and hash.** The archive-wide skip
  becomes a `path → sha256` record of what the crash left: from the open that settles it
  (`interruptedWriteResidueLocked`, already per path) or from `authoredWrites` when one of our
  mutations fails part-way. A path is exempt only while its bytes are still exactly those;
  anything that changes it afterwards is guarded again, and our own rewrite makes it match the
  manifest, so no bookkeeping. Persisted in `.index/interrupted`; an empty (pre-68) marker is
  recomputed once on open. Fails closed: if the residue can't be computed, nothing is exempt.
  **Stated residue:** a hand edit already on disk at the crash is indistinguishable from it
  and stays exempt. The flag itself, the banner and verify's classification are unchanged.
  **Revised on `/code-review` (2026-10-04):** inferring the residue from what differs swept in
  every hand edit or delivery on disk at the crash, and a pre-68 marker's recompute swept in
  everything since. The source is now **what we wrote**: `.index/dirty` is a write-ahead
  journal (`sha path` appended before each authored write, the path before each unlink), and
  recovery exempts a journaled path only while it holds those bytes — so the stated residue
  is gone. A pre-68 marker exempts nothing; a later write or removal of ours prunes the path;
  the guard consults exemptions only while the flag is up. **Hand-test** found one more: a
  second crash before the first is accepted journals only its own writes, so recovery keeps
  the persisted exemptions as candidates too.

**Out of scope:** narrowing verify's `.interruptedWrite` classification to the residue (a
reporting change, near 71's straggler wording); a trash for deleted conclusions ([#11](https://github.com/GeneaLogic/GeneaLogic/issues/11)).

**Verified by** `RecordDriftGuardTests`: each removal refuses a same-size hand edit and leaves
it; a merge refused on any one record changes no file and does not read as interrupted; after
a recovered crash its own record stays editable while another record edited later is refused,
as is the crash's record once its bytes move; the exemption survives a reopen, and a legacy
empty marker is recomputed. macOS + Linux. **Hand-test (CLI):** hand-edit a person, then
`genea person remove` and a merge are refused; leave an interrupted write (`kill-test.sh`),
then a later hand edit of another record is refused while the crashed record still edits.

**Shipped 2026-10-04** (merged); **hand-test passed** — the CLI half against real `kill -9`
crashes, the app half refusing a delete and a merge of hand-edited persons. Fork (c) revised
on `/code-review` as noted; the review's other findings fixed on the branch (see SLICE-LOG).

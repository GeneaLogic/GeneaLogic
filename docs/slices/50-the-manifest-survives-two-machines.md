# 50 — the manifest survives two machines ✅

**Problem.** Two machines edit **different** records, both records sync cleanly, and
the archive wedges anyway — because both rewrote `manifest.json` and the provider had
to pick one. Reproduced on `main` 2026-08-28 with `scripts/deliver.sh`, after 60c:

```
=== both machines' edits are on disk and indexed ===
Alice: [0] Alice Baseline  [1] Alice MY-EDIT        ← mine
Bob:   [0] Bob Baseline    [1] Bob OTHER-EDIT       ← delivered

=== genea verify on mine, identically on every later run ===
awaiting-delivery  conclusions/persons/PER-…0402.json
  …wait, then check again — do NOT run `genea rebaseline`, which would discard
  the incoming version

=== and any further edit to that record ===
Error: …is still arriving from another machine, so nothing was written.
```

The surviving manifest names the **pre-edit** hash for a record only *this* machine
edited. That entry moved since the last settling, so 60c reads it as a delivery —
correctly, by its own rule — of a version that exists nowhere and will never arrive.
`manifestDeliveryLooksComplete` is then false for ever: the witness never settles, the
index is never reconciled, 61's bar stays up past its ten-minute escalation, the record
is **frozen against every further edit**, and the engine's advice explicitly forbids
`rebaseline`, the only operation that would clear it. Nothing here is damage and nothing
is arriving; every record is intact. This is the failure the 48–50 placeholder called the
sharpest fact the three slices have to design around, and it happens on *every*
concurrent edit.

**Layer.** Engine (`GeneaLogicArchive`) only. **No format change** — the merge is over
data `manifest.files` already carries and 60c's settled entries already store in
`.index/`; `manifest.files`'s array order is not specified, which is what makes a
canonical ordering free. CLI and app get the improvement through the surfaces they
already have.

**The insight the slice turns on:** `manifest.files` is a **set of independent per-path
facts, not a narrative**, so two divergent manifests can be merged per path — and the
merge decides between hashes that were *authored at write time* by one machine or the
other. **It never mints a hash from disk**, so 49 fork (a)'s laundering rule holds by
construction rather than by care, which is what lets this run without a human (unlike
`rebaseline`, which re-mints and therefore must not).

**Design forks** (settled with the user 2026-08-28, all as recommended):

- **(a) Merge, report, or change the format? ✅ merge.** *Detect-and-report-only* was
  the closest reading of Phase 3.5's "detect the unsafe case and fail loudly", but that
  bar was written about merging **records**; manifest bookkeeping is decidable, and
  reporting alone leaves an ordinary two-machine day needing a manual step. *The
  per-machine or append-only `manifest.files` the placeholder called the leading
  candidate is **not needed**, and is recorded as considered-and-declined rather than
  deferred*: a deterministic merge removes the wedge without touching the format, and
  sharding re-opens 49 fork (c), which rejected splitting the one document preservation
  tooling is supposed to read (§3). It returns only if the merge proves undecidable in
  practice, which the residue below is the evidence to watch.
- **(b) The merge rule** — ✅ settled as written below, but **the rule this bullet
  first specced was wrong, and the engine's existing delivery tests said so within
  minutes.** It read: *the file on disk agrees with our settled entry, so their
  manifest predates our write.* That is equally true of a delivery still **in
  flight**, where the disk holds the old version precisely because the new one has
  not landed — six tests from 60/60b/60c failed on it, and they were right to. The
  two manifests cannot distinguish those cases **from each other**; what separates
  them is a third fact, on neither of them: **that we wrote, and what we wrote
  over.**

  So the merge is a genuine three-way one, over the arriving manifest, 60c's settled
  entries, and a machine-local record of **what our own writes superseded**. For each
  path the arriving manifest names: keep **ours** when its entry is *exactly the entry
  our local write replaced* — proof the sender has not heard about that write — and
  the disk still holds our version; otherwise keep **theirs**.

  The evidence is recorded per path on the mutation that changes it, and it is **every
  version that path has moved on from, not just the one it started at** — the first
  build kept only the first predecessor, and `/code-review` showed that is wrong on the
  *second* round of any exchange: once the other machine adopts our E1 and writes again,
  its manifest legitimately names E1, and a local E1→E2 in the meantime must still read
  as ahead of it. It is dropped, whole, when the sender's manifest names our own entry,
  which is proof it has caught up. It lives in `.index/` — machine-local and expendable:
  it survives `rebuild(walking:)` and is lost only when the database is recreated, after
  which the merge degrades to taking the arriving manifest whole, which is slice 60's
  behaviour and safe.

  **Rows, not a blob** (also `/code-review`). A blob has to be decoded and re-encoded on
  every manifest-changing mutation to add one predecessor — O(everything ever edited)
  under the archive lock, on a path the blob's own justification claimed it never took.
  Rows make the write O(paths this mutation changed) and leave the whole-set read to the
  merge. The opposite trade from `settled_file`, because the access pattern is the
  opposite. **The residue is unbounded growth** on an archive that syncs with nothing
  and so prunes nothing; affordable because it is rows, and a retention rule wants
  evidence this slice does not have.

  The disk check is `st_size` and, for an engine-authored file only, one hash: a
  payload file may be a dataless placeholder and hashing it materializes it (57's
  finding), so payload is answered by size alone. That is the only hashing on the
  path, and it is bounded by the disagreeing entries rather than by the archive.

  **Deliberately narrow, in one more way:** a path the arriving manifest does *not*
  name — our own record, created after that manifest was written — is left alone.
  Restoring it from the settled entries was built and reverted: nothing tells it apart
  from a manifest legitimately rolled back by hand, which is exactly what 49 fork (f)'s
  compatibility test pins (*an absent entry means unverified, never tampered*). The
  next mutation mints it, as it always did.
- **(c) Automatic, on the reconcile path ✅.** Inside the lock, on the open/poll path
  60 already built, replacing "adopt the delivered manifest" with "adopt the merge of
  the delivered manifest and the settled one". Still **never a recompute from the
  index** — that is 60's first review finding and it is untouched. An explicit
  `genea resolve` was the alternative, rejected because the archive stays wedged and the
  record stays frozen until somebody notices, and because (see above) the merge cannot
  launder rot, which is the property that made `rebaseline` need a human.
- **(d) Convergence ✅ canonical order, and don't write when nothing changed.** The
  merged `files` are sorted by path, so both machines compute the *same* set from the
  same pair of manifests and the ping-pong terminates in one round: the second machine's
  merge changes nothing, and it settles without writing. Writing only on a real change
  is what keeps a poll from generating traffic. The witness digests `files` alone, so
  `updatedAt` differing between the two copies costs nothing. **The canonical order came
  free:** `recomputeManifestFiles` already sorts by path on every commit, and the format
  does not specify the array's order at all.

**Out of scope** (each named with its owner):

- **What the merge declines to decide → [50b](50b-a-deletion-of-yours-is-not-a-delivery.md)
  ✅ and 50d.** Two shapes, both left exactly as they are today, so 50 is a strict
  improvement and what follows it is purely additive. **Specced and built 2026-08-29 with
  50's residue as its evidence, and split in two on the way**, because the decidable half
  and the undecidable one share nothing but a symptom. A concurrent *delete* against an
  *edit*, where "they created it and it has not arrived" and "I deleted it and their
  manifest predates the deletion" look alike, turns out to be decidable from (b)'s
  superseded evidence — a mechanism **50b** inherits rather than has to invent. A path
  the arriving manifest does not name at all, per (b)'s last paragraph, is **declined
  there with its reason**, not deferred. And the placeholder's fourth state — *the
  manifest disagrees and nothing is coming*, which is neither damage nor an arrival —
  survives both, because what is left is what no evidence decides: that is **50d**, with
  the way out of it.
- **Conflicted-copy *files* → [50c](50c-a-conflicted-copy-must-not-become-the-record.md) ✅.**
  A Dropbox `(conflicted copy)` or an iCloud duplicate appearing beside a record — the
  placeholder's original reading of 50. It is an unrelated problem (an unexpected file, not a
  disagreeing entry). **Two of the three guesses here were wrong**, and the slice's own
  measurement is why: it is not merely *detection* (the copy was being **loaded**, and written
  back over the real record by the next mutation), and it does **not** borrow `.damaged/` —
  that directory holds bytes a repair had to displace, while here the real file is untouched
  and the copy is the only surviving version of what the other machine wrote.
- **Merging two versions of one record.** Still Phase 4+, and still foreclosed by
  nothing: per-record sidecars and UUIDv7 identity keep it tractable.
- **A provider that ate one machine's edit outright** — both machines edited the same
  record, the provider picked one file and no copy of the loser exists anywhere. Not
  detectable without version history the archive does not keep, and naming it here is
  the honest answer rather than implying the merge covers it.
- **Cross-machine mutual exclusion** — off the table for good; `flock` cannot cross
  kernels (48).

**Verification.**

- Engine: the reproduction above as a test — two archives, edits to different records,
  the loser's manifest delivered → after one reconcile `verifyIntegrity()` is clean, the
  record is editable again, and **both** entries are in the manifest. Each case of (b)'s
  rule directly — including the two that must *not* merge: an entry we never superseded
  (a real delivery) and a file that no longer matches what we settled. The evidence's
  own lifecycle: recorded on a local write, not overwritten by later ones, dropped once
  the sender's manifest proves it has caught up. **The second round as its own
  regression test** — the other machine adopts our version, writes again, and its
  manifest names our *intermediate* one while we have moved past it; with only the first
  predecessor held this wedged exactly as the un-fixed slice did. **Laundering, as its
  own regression test:** a rotted file whose entry neither manifest moved is still reported as damage
  after a merge, and no merged entry is ever a hash minted from disk. Convergence:
  merging twice is a no-op and writes nothing the second time. And both residues,
  asserted as *documented behaviour* rather than left to be discovered.
- **Linux-verified** via `scripts/linux-test.sh` for engine and CLI — this is core.
- **Hand-test:** ✅ `scripts/deliver.sh` grew the case it could not stage — a `race`
  step that edits a record on mine, so the manifest `other` then delivers has never
  heard of it. Stepped end to end 2026-08-28: mid-flight, the record genuinely arriving
  is the **only** one reported `awaiting-delivery` while the raced one settles silently;
  once it lands, verify is clean and the raced record is editable again. Before the
  slice, that same sequence left `awaiting-delivery` on mine's own record on every run
  for ever. **One thing to know while stepping it:** since this slice a plain `open()`
  can rewrite `manifest.json` — adopting now merges — so the document's mtime moves on
  an open that changed nothing else.

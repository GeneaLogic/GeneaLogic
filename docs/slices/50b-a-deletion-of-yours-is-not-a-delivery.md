# 50b — a deletion of yours is not a delivery ✅

**Problem.** Delete a record on one machine while the other machine writes anything at
all, and the archive wedges exactly as it did before 50 — only the shape has moved. The
manifest the provider keeps is the one that still names the record you deleted; that
entry is in neither the settled entries nor on disk, so 60c reads it as a delivery of a
version that will never arrive. Reproduced on `main` 2026-08-29 with `scripts/deliver.sh`
(a delete on mine, an unrelated person added on other, then both steps of the delivery):

```
=== genea verify on mine, identically on every later run ===
awaiting-delivery  conclusions/persons/PER-…9397.json
  …wait, then check again — do NOT run `genea rebaseline`, which would discard
  the incoming version
```

The person `other` really sent lands and settles; the one *this* machine deleted never
does. `manifestDeliveryLooksComplete` is false for ever, the witness never settles, the
index is never reconciled, and 61's bar stays up past its ten-minute escalation. Worse
than 50's wedge in one respect: **every later mutation carries the phantom entry
forward** (`awaitedPaths`, correctly by its own rule), so the manifest permanently
describes a file that cannot exist and the deletion is undone in the bookkeeping. The
engine's advice again forbids `rebaseline`, the only operation that would clear it.

**Layer.** Engine (`GeneaLogicArchive`) only — one rule inside `ManifestMerge`. **No
format change**, no new state, no new vocabulary, no host change: CLI and app get the
improvement through the surfaces they already have.

**The insight the slice turns on:** the evidence 50 built already decides this, and 50's
own out-of-scope bullet said so. `recordWhatThisMutationSuperseded` notes the entry a
*deletion* replaced exactly as it notes an *edit*'s, so *the version they are describing
is one we moved past* is already on file. What 50's rule cannot do with it is the other
half of the sentence: it only ever **substitutes** one entry for another, and a deletion
needs one **dropped**.

**Design forks** (settled with the user 2026-08-29, all as recommended):

- **(a) Drop the entry, don't merely report it ✅.** The alternative — classify the state
  and leave the manifest alone — is 50d's job for the cases that are *undecidable*. This
  one is decidable from evidence both machines authored, on the same argument that let
  50 run without a human: the merge mints nothing, so 49 fork (a)'s laundering rule holds
  by construction. Reporting a decidable fact and asking the user to act on it is the
  manual step 50 fork (a) already declined.
- **(b) The rule — three facts, and all three are load-bearing ✅.** For a path the
  arriving manifest names, drop the entry when **(i)** this machine **recorded removing**
  that path; **(ii)** the arriving entry is one of the versions our own writes superseded
  — they are describing something we have moved past; and **(iii)** nothing is there.
  Without (i), a record we had *edited* whose file was later lost out of band satisfies
  (ii) and (iii), and the merge would quietly withdraw a `missingFile` finding instead of
  letting it be reported. Same three-way shape as 50's keep rule, and the same
  `st_size`-first disk check, which here only ever has to answer *absent*.

  **(i) was first written as an *absence* — "our settled entries do not name the path,
  which only a manifest we committed after deleting produces" — and `/code-review` showed
  that it does not.** `settled_file` moves only when a mutation starts current or a
  delivery settles, so while one is **stuck in flight it lags arbitrarily**: a record
  created *and then edited* in that window is in `superseded_file` and has never been in
  `settled_file`. Lose its file out of band, have an older manifest naming the superseded
  version arrive, and all three facts passed — the entry was dropped and a real loss went
  unreported (reproduced, and the test is now in the suite). So the deletion is recorded
  where it happens, in a `deleted_path` table beside 50's evidence: nothing but a removal
  writes it, and a path authored again — created, restored from `.trash/`, repaired —
  clears it. **Additive, no `schemaVersion` bump** (the argument `meta` already carries):
  an older build never reads it, and a newer build finding it empty simply drops nothing,
  which is slice 50's behaviour. **And it is asked *before* 50's substitution, not
  after** — `settled` may still name a path we deleted, and the substitution would then
  find no file to vouch for, keep theirs, and leave the wedge exactly where it was.

  **A second `/code-review` tightened what the table means, twice.** It was written from
  the manifest diff — *this path left the manifest* — which is a weaker claim than *we
  deleted it*; it is now gated on the mutation's own `authoredRemovals`, widened to cover
  deliberately removed **payload** paths (`removeArtifact`, `detachFile`) so an artifact
  deletion stays armed. *Stated plainly: no route was found where an entry leaves without
  a deliberate removal, so that one is hardening rather than a reproduced defect — but
  `deleted` is what licenses dropping an entry and what fork (f) keys on, so it has to
  mean what it is named.* And a note is now dropped **once the path is back on disk**, not
  only when this machine authors it again: the commonest way a deleted record returns is
  the merge keeping theirs (fork c), which no local write observes, and the note would
  otherwise outlive the deletion for ever.
- **(c) A delete loses to an edit, and that falls out rather than being built ✅.** If the
  other machine *edited* the record instead of merely holding it, its manifest names a
  version we never superseded, (ii) fails, we keep theirs, and the record comes back when
  it lands. That is the safe direction and the conventional one; the deleted sidecar is
  in `.trash/` either way, so nothing is destroyed on either reading.
- **(d) A path the arriving manifest does not name at all — declined, and recorded as
  declined ✅.** Today the entry falls out and the next mutation mints it from disk;
  measured, that is a *window* and not a permanent loss (`verify` reports `OK … 7 files
  tracked` on an archive holding 8 authored files, and the eighth is covered again after
  the next write). Restoring it needs a new *authored since the last settling* evidence
  table, and even with one the case is not clean: our record and a record **the other
  machine deleted** whose file-deletion has not landed yet look identical, so restoring
  would re-wedge on a file that will never arrive — the failure this slice exists to
  remove. 49 fork (f) already governs the residue: an absent entry means *unverified*,
  never *tampered*. Treat as considered-and-declined, not deferred.
- **(f) An artifact is not decided one path at a time ✅** (added by the hand-test,
  2026-08-30). The rule is per path — that is the premise that makes a manifest
  mergeable at all — but the two halves of one artifact are not independent facts.
  Delete an artifact here while the other machine edits it, and (c) brings the *record*
  back while the *payload* entry is still dropped as our deletion: the record then lists
  a preservation master that is on no disk, in no manifest, and reported by nothing, its
  only copy in `.trash/`, which emptying deletes for good. **Measured, and the quiet is
  the defect** — before this slice the same race wedged the archive and reported the file
  outstanding, which is noisy and honest. So a dropped path under an artifact folder
  whose `record.json` *survived* the merge is un-dropped: the entry stands, the file is
  **reported as outstanding**, and the trash copy is still there to restore from. *Which
  finding it is reported as — `awaiting-delivery` today, since the manifest did move — is
  50d's question, not this slice's; what 50b owes is that it is not silent.* One coupling, and
  only where a real invariant makes the paths dependent; `conclusions/**` has no such
  grouping and is untouched. *Rejected alongside it: restoring the payload from `.trash/`
  during the merge — the bytes are right there, but the merge mints nothing and runs
  without a human, and trash is outside every integrity pass, so that would author state
  from unverified bytes. A new finding kind for "a record naming a file nothing tracks"
  is more generally useful and is its own slice.*
- **(e) Keep the deletion evidence; do not prune it ✅.** 50's `pruneSupersededFiles`
  drops a path's predecessors on positive proof the sender holds our current entry. There
  is no equivalent proof for a deleted path — the sender simply stops naming it, and
  absence is not proof, since an older manifest can be delivered at any time by a
  restore or a conflicted copy. So the rows stay. This makes 50's noted residue slightly
  worse and it is stated rather than implied: **a deleted path's predecessors are kept
  for good**, because they are the only thing that can decide a manifest naming that
  version, and one may arrive later. Still rows, still O(paths this mutation changed) to
  write; a retention rule still wants evidence we do not have.

**Out of scope** (each named with its owner):

- **The fourth state, and the way out of it → 50d.** *The manifest disagrees and nothing
  is coming* — the state the 48–50 placeholder asked for. It survives this slice, because
  what remains after (b) is exactly what no evidence can decide: a provider that ate one
  machine's edit outright, a sender that went away mid-delivery, or an index database
  recreated so the superseded rows are gone and the merge degrades to taking the arriving
  manifest whole (safe, and back to 50's wedge until local writes record evidence again).
  Its only evidence is **time without progress**, which is 61's stall heuristic and is a
  hedge rather than a diagnosis — so the way out is **a new explicit verb, path-scoped**
  (`genea abandon-delivery <path>` and an app affordance): withdraw the manifest's
  expectation for one named file that never arrived, and settle. It is recoverable, which
  is what makes it safe to offer where `rebaseline` is not — a file that does land
  afterwards is walked into the index by the next rebuild and re-minted by the next
  mutation. Not `rebaseline` (blunt, re-mints from disk archive-wide, gated behind a
  human for reasons 49 established) and not automatic (a slow link is structurally
  indistinguishable from a stopped one — 61's own rule). **Now specced** —
  [50d](50d-nothing-is-coming-and-the-way-out.md) ✅.
- **Conflicted-copy *files* → [50c](50c-a-conflicted-copy-must-not-become-the-record.md) ✅**:
  an unexpected file beside a record, not a disagreeing entry. It turned out to be a
  *discovery* defect rather than a detection one, and to want no quarantine at all — see
  that section.
- **Propagating a deletion between machines.** Dropping the entry fixes *our*
  bookkeeping; the other machine still holds the sidecar, so its own recompute names it
  and the record reappears there. Deleting the file on the other machine is the sync
  provider's job, and pretending otherwise would be the engine claiming a reach it does
  not have.
- **Merging two versions of one record** (Phase 4+), **a provider that ate an edit
  outright**, and **cross-machine mutual exclusion** — all inherited from 50 unchanged.

**Verified.** 10 new `ManifestDeletionRaceTests`. The reproduction above as a test —
delete on one archive, an unrelated write on the other, the survivor's manifest delivered
→ after one reconcile `verifyIntegrity()` is clean and the deleted path is gone from the
manifest; and **a later mutation does not put it back**, which is the half of the defect
that made the deletion permanently un-makeable. Each of (b)'s three facts as its own
negative case, since each one alone would be a silent withdrawal of a real finding: a
record we edited whose file was deleted out of band is **still** reported (i); an entry we
never superseded — a genuine creation of theirs — is **still** awaited (ii); a path whose
file is present is left alone (iii). Plus (c): their edit of a record we deleted is
adopted and the record returns. And a directory where a record belongs is **not** an
absence, and neither is a **dangling symlink** — *nothing is there* is `lstat` failing
with `ENOENT`, not any `stat` failure, so an `EACCES` on a parent directory cannot license
the drop on exactly the machine that can see least (`/code-review`). Convergence per 50
fork (d): merging twice writes nothing. Confirmed to fail without the fix, four tests
over. **`/code-review` added a fifth**: a record created and edited while a delivery is
stuck, its file then lost out of band, is still reported — the case that took fact (i)
from an absence to a recorded fact. **The hand-test added two more, for (f)**: an
artifact deletion drops record *and* payload and settles, while a payload whose record
came back from the other machine keeps its entry and is reported. **A second
`/code-review` added three more**: a `detachFile` on a living artifact still settles (the
coupling must not fire there), a record that comes back through the merge clears its
deletion note, and a record lost rather than deleted arms nothing. 821 engine
tests on macOS, **818 on Linux** via `scripts/linux-test.sh`, 146 CLI on both.

**Hand-tested** — including **the app half, driven on screen 2026-08-29**: with the
stale build the bar sat at *Receiving a change from another machine…* indefinitely; with
this slice's build the same archive settled on open (`92 tracked, 1 outstanding` →
`91 tracked, 0 outstanding`) and a fresh delete-then-stale-manifest round dropped the
person from the list with **no bar at all** — the reconcile beat the indicator's
two-second delay. The round also re-delivered a manifest naming the *previous* round's
deleted record, which was decided again rather than re-wedging: the evidence outlives one
exchange. **Deleting an artifact was hand-tested separately and is what found fork (f).**

The engine half via `scripts/deliver.sh`, which grew a `delete <uid>` step
beside `race` — the same conflict one case over, removing a person on mine so the manifest
`other` then delivers still names it. Stepped `setup → delete → manifest → record`
2026-08-29: mid-flight the record genuinely arriving is the **only** one reported
`awaiting-delivery` while the deleted one settles silently; once it lands, verify is clean
and stays clean through a later mutation. Before the slice that same sequence left
`awaiting-delivery` on the deleted record on every run for ever, with advice forbidding
the one operation that would clear it.

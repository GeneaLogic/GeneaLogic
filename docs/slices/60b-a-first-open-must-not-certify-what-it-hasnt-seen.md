# 60b — a first open must not certify what it hasn't seen ✅

**Problem.** An index that does not exist yet is built at `open()`, and
`recordWitness` then stamps it current **unconditionally** — its no-witness
exception, added in 60 so that a fault in a pre-60 archive kept reporting as the
damage it is. But "no previous state to differ from" is not the same as "this state
is complete", and when the two come apart the archive **silently loses a record**:

```
=== first open, mid-delivery, no .index yet ===
missing-file  conclusions/persons/PER-…7cc.json
=== now the record lands ===
OK: no integrity issues found (91 files tracked).
=== is the delivered person visible? ===
NOT VISIBLE
```

The witness now describes the manifest on disk, `manifest.json` never changes
again, so nothing re-fires — and `verifyIntegrity()` reports a **healthy** archive
holding a record no query can see. Not a banner that cries wolf: no banner at all,
and no prompt to rebuild. (Reproduced 2026-08-23 while hand-testing 61; each
`genea` run opens fresh, so this is not a stale handle.)

**Reachable today** — any copy, restore, or `rsync` that drops `.index/` — and
[48](48-50-cross-machine-sync.md) makes it the
*normal* case rather than a corner, since a per-machine index means every
cross-machine handoff starts here. **So it lands before 48, and is not part of
it:** a silent-correctness fix buried inside a structural change is harder to
review than either alone, and 61's own out-of-scope rule assigns a signal 60
lacks to a follow-up to 60.

**The root is one boolean doing two jobs.** `recordedWitnessMatchesDisk()` is
false both when the witness *disagrees* with the disk and when there is **no
witness at all**, and every consumer reads that one value:

| Consumer | Wants | Gets today |
| --- | --- | --- |
| `deliveryIsInFlight` → the banner, `verifyIntegrity()`, 61's bar | *disagrees* | also fires on unknown |
| `awaitedPaths` → don't drop manifest entries for files not on disk | *disagrees **or** unknown* | correct, by accident |
| the drift guard's advice (`recordAwaitingDelivery` vs `recordDriftedOnDisk`) | see fork (c) | claims an arrival on unknown |
| `indexWasCurrentAtStart` → may this mutation certify? | *matches* only | correct |
| `noteReconcileOutcome` → did this settle? | *matches* only | correct |

**Layer.** Engine (`GeneaLogicArchive`) only. **No format change** — the `meta`
row already distinguishes absent from present; this is about what the engine
concludes from it. No app change, no CLI change. *Amended in build: fork (c)'s new
`ArchiveError` case is public, since the enum is — the only public surface added,
and one hosts render through `errorDescription` without knowing the case.*

**Design forks** — **(a), (b), (c) and (e) settled as recommended, 2026-08-25;
(d) lifted out to its own slice, see below.**

- **(a) What replaces the boolean?** *Recommend a three-state `WitnessState` —
  `matches` / `disagrees` / `unknown` — computed once where
  `recordedWitnessMatchesDiskLocked()` is now,* and every consumer switching on it
  explicitly. Not a second bool beside the first: two booleans permit a fourth
  state that cannot happen, and the whole defect is a value that could not express
  the case it was asked about.
- **(b) Which grouping does each consumer take? — this is the trap, and it is
  asymmetric.** *Recommend the rule: **unknown fails toward not-claiming and
  toward not-destroying, and those are different directions.*** Where a false
  *arriving* would **mislead** (the banner, the issue kind, 61's bar), unknown
  reads as damage — which is exactly the pre-60 behaviour the exception was
  protecting, now preserved on purpose rather than as a side effect. Where a false
  *not-arriving* would **destroy** (`awaitedPaths`), unknown must keep behaving as
  it does today. **A three-state split that maps only `.disagrees` to "in flight"
  reintroduces 60's manifest-scrubbing data loss through the unknown door** — one
  unrelated mutation deletes the entries for files that have not arrived, from the
  only document that says they are expected. Name it in the code and pin it with
  the regression test 60 already has.
- **(c) What does the drift guard advise under unknown?** *Recommend a third
  message rather than either existing one.* `recordDriftedOnDisk` tells the user
  to accept the current contents, which discards an incoming version;
  `recordAwaitingDelivery` tells them to wait, which is a claim this state cannot
  support. The honest line is that the record differs from what the archive
  recorded and **this index has no history to tell damage from an arrival** —
  check it before accepting either way. One new `ArchiveError` case, no new
  detection.
- **(d) Should the in-flight flag still relabel *every* mismatch?** — ***settled
  2026-08-25: it still does, and the fix is not here.*** It is the one item on this list
  that adds a mechanism rather than retracting a claim the engine had no right to
  make, and a correctness retraction is easier to review on its own. Lifted out
  whole as [60c](60c-a-delivery-in-flight-must-not-speak-for-damage-it-did-not-cause.md),
  which this slice does not block.
- **(e) What does not recording a witness cost?** *Recommend accepting it, with
  the measurement.* A genuinely damaged archive with no index now re-walks on
  **every** open rather than once, because unknown is stale and 60's back-off is
  in-process while every `genea` invocation is fresh. 60 measured a rebuild at
  ~88 µs/artifact (2,000 artifacts → 177 ms), and a permanently damaged archive is
  not the common case. *The escape hatch, if it ever bites:* record the witness
  **plus** a completeness snapshot of the observed file sizes, and re-fire when
  either disagrees — 57's sweep already computes exactly that, so it is an option
  rather than a research problem. Don't build it on speculation.

**Out of scope:**

- **Where the index lives** → 48, which this unblocks and must not be folded into.
- **Any new detection.** Nothing here learns a fact the engine cannot already
  compute; it stops the engine asserting one it never checked.
- **Improving the wording of a fresh-index mid-sync report.** Under (b) it stays
  "missing file" — unchanged behaviour, and no longer permanent once this slice
  makes the state resolve on its own. Softening it is a surface question, and
  belongs with 48, where the case becomes common.
- **Per-entry witness state**, and with it the archive-wide relabelling of every
  mismatch during a delivery → fork (d), lifted out to
  [60c](60c-a-delivery-in-flight-must-not-speak-for-damage-it-did-not-cause.md).
- **Conflict policy** → 50, as ever.

**Verification.**

- Engine: **the scenario above, exactly** — no `.index/`, manifest delivered, open,
  record delivered, and the record is now visible without an explicit
  `rebuildIndex()`. It fails on `main` today.
- **The regression that the naive fix causes:** a fresh-index incomplete open
  followed by one unrelated mutation must leave the un-arrived entry in
  `manifest.json` (60's second-review case, re-run through the unknown door).
- **The exception's original purpose still holds:** damage on an archive with no
  witness reports as damage, not as an arrival — the assertion that stops (b)
  being "solved" by making unknown mean arriving.
- A `.matches` archive is unaffected: our own writes still certify, and an
  unchanged archive still rebuilds zero times across many opens.
- ***Added by `/code-review`:*** **a deletion made while the witness is unsettled
  leaves nothing behind** — the archive still settles afterwards and verify is
  clean on every later open. `awaitedPaths` reads an absent path as *not arrived
  yet*, which is wrong for one that was deliberately removed, and the resulting
  phantom entry is permanent: completeness stays false, so the witness can never
  settle and the entry is re-carried for ever.
- ***Added by `/code-review`:*** **`.unknown` means no witness and nothing wider.**
  An unreadable `manifest.json` on an archive that *does* hold a witness must not
  be told it has no history.
- **Linux-verified** via `scripts/linux-test.sh` for engine and CLI — this is core.

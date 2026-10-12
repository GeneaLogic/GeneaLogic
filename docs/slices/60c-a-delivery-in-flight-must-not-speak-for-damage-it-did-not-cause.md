# 60c — a delivery in flight must not speak for damage it did not cause ✅

**Problem.** The in-flight flag is **archive-wide** — 60 documents that it "says a
delivery is in flight, never which files it covers" — so while one is in flight,
**every** mismatch is relabelled `.awaitingDelivery`, including damage that has
nothing to do with it. Measured 2026-08-24, on a rotted JPEG in a real archive:

```
=== damage alone, no delivery ===
checksum-mismatch   artifacts/…/Lindqvist 1860 Census.jpg  expected=feea… actual=7ec8…
=== same damage, with a delivery now in flight ===
awaiting-delivery   artifacts/…/Lindqvist 1860 Census.jpg  …wait, then check again…
```

So `genea verify` tells the user to **wait for a file that will never arrive**, the
standing damage banner goes quiet for the duration of any delivery, and a dismissal
the user already made is reset when it returns. Found by 61's `/code-review`, which
attributed it to 61; it is 60's, and predates that slice's app work entirely.

**Specced as fork (d) of [60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md),
and lifted out of it 2026-08-25.** Everything else on that list retracts a claim the
engine had no right to make; this one **adds a mechanism**, and mixing the two makes
both harder to review. 60b does not block it and it does not block 60b: 60b narrowed
*when* the flag is true, this narrows *what it may speak for*.

**Layer.** Engine (`GeneaLogicArchive`) only. **No format change** — the per-entry
data lives in `.index/`, which is machine-local, rebuildable, and outside the
manifest, the integrity passes and the spec.

**The root.** Telling *this entry changed* from *this entry rotted* needs the witness
to carry **per-entry** state, where today it is a single digest over all of them. With
the last settled manifest's entries on hand, a mismatch on a path whose entry is
unchanged since that settling is damage; a mismatch on a path whose entry moved (or
that is newly named) is the delivery.

**Design forks** (recommendations, to settle before building) — **all settled as
recommended, 2026-08-28**, with the amendments under (c) and the fourth bullet:

- **(a) What is stored, and where?** *Recommend the settled manifest's entries in
  `.index/` — path, `sha256`, `byteLength` — written by the same call that records
  the witness*, so the two cannot drift apart. `ManifestWitness` keeps the digest as
  its cheap gate; this is what it falls back to when the gate says "look closer".
- ***Added by the hand-test, 2026-08-28:*** **the completeness gate is per-entry
  too.** `manifestDeliveryLooksComplete` asked whether *every* manifest entry was
  at its recorded size, so an archive that was already damaged when a delivery
  landed could never record a witness again: `deliveryIsInFlight` stuck true with
  nothing arriving, 61's bar up permanently, every open re-walking. Pre-dates this
  slice (it reproduces on `main`), but 60c is what makes it decidable — an entry
  unchanged since the last settling is not the delivery's, so it cannot report on
  the delivery's progress.
- **(b) Does the archive-wide flag survive?** *Recommend keeping
  `deliveryIsInFlight` exactly as it is* — 61's bar is a whole-window statement and
  wants the archive-wide answer. What changes is that `verifyIntegrity()` and
  `sweepFileSizes()` stop consulting it per file and ask the per-entry question
  instead.
- **(c) What about an entry with no settled predecessor at all** (`.unknown`, 60b's
  state)? *Recommend it stays damage*, for 60b fork (b)'s reason: no history is not
  evidence of an arrival. ✅ *— and it costs nothing: `.unknown` is already not in
  flight, so nothing is relabelled there at all. Two neighbouring cases were settled
  with it: a path the settled manifest **did not name** is the delivery (or every
  genuinely new record reports as damage while it lands), and an index that holds a
  witness but **no per-entry rows** — one written before this slice, or a
  `manifest.json` that does not currently decode — keeps slice 60's archive-wide
  answer rather than inventing damage from evidence it does not hold. Both fall out
  of the one comparison; neither needed a mechanism.*
- ***Added 2026-08-28, and agreed before building:*** **the drift guard asks the
  per-entry question too.** `refuseToOverwriteDriftedRecord` picked its advice from
  the same archive-wide flag, so any delivery in progress turned every locally
  drifted record into one that was "still arriving" — the identical *wait for a file
  that will never arrive*, one layer over, on evidence the guard already holds
  (`authoredBaseline`'s hash for that path). Fork (b) named only the two report
  paths; this is the third consumer that relabels a finding.

**Out of scope:** any new detection; where the index lives (→ 48); conflict policy
(→ 50); and re-opening 60b's three-state split, which this builds on rather than
revisits.

**Verification.**

- Engine: **the rotted-JPEG case above** — damage that predates a delivery keeps
  reporting as damage while that delivery is in flight, and the file that really is
  arriving still reports `.awaitingDelivery`.
- The standing damage banner keeps speaking during a delivery, and a dismissal
  survives it.
- 60b's assertions all still hold — in particular that `.unknown` reads as damage.
- **Linux-verified** via `scripts/linux-test.sh` for engine and CLI — this is core.

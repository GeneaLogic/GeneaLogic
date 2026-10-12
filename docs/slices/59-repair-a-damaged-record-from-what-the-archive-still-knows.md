# 59 — repair a damaged record from what the archive still knows ✅

**Problem.** 56 made a damaged record visible and deliberately offered no action: with the
uid inside the file that failed to parse, every uid-addressed mutation was unavailable *by
construction*, so Reveal in Finder was the only honest affordance and repairing broken JSON
was a text-editor job. **That reasoning is now wrong in one specific case.** The index holds
a byte-identical copy (see 58), and since 49 the manifest holds that sidecar's `sha256`. So
the app can restore the file *and prove the restoration is exact* — which is a materially
different offer from "regenerate it from a cache and hope".

**Depends on 58 ✅.** Without preservation the copy exists only until the next rebuild, and
`Archive.open` rebuilds on a stale index — so the repair would be available exactly when
nobody has looked yet, and gone by the time they do. **58 shipped with one limit 59 must
not assume away:** the copy lives in `.index/`, so it does *not* survive a missing, corrupt
or schema-stale index (those rebuilds unlink the database). `preservedRecord(atPath:)`
returning `nil` is therefore a normal state, not an error — fork (b) is what covers it.

**Layer.** Engine + app + CLI. **No format change.**

**Design forks:**

- **(a) The checksum is the gate, not a nicety — and what it really guards is version
  skew.** Re-encode the preserved record and compare against the manifest's recorded
  `sha256` for that path. A match means the restoration is provably byte-exact and the UI
  can say so outright. A mismatch means the round-trip was lossy, and the case that produces
  that is **a sidecar written by a newer GeneaLogic carrying fields this version doesn't
  model** — decode drops them, re-encode omits them, the hash diverges. **Recommend**
  offering the one-click restore only on a match, with the mismatch case surfaced as an
  explicit, labelled fallback ("this is the last version GeneaLogic recorded, and it is
  *not* byte-identical to what the manifest expected"), never as the same button.
- **(b) The action belongs on 56's placeholder row, and only when it can be honoured.**
  The row shows a button exactly when a preserved copy exists for it; no copy, no button. A
  row that offers a repair it cannot perform is the lie 56 was careful not to tell.
- **(c) Move the damaged file to `.trash/`, don't overwrite it.** `.trash/` is already a
  reserved top-level dir, outside the manifest and integrity passes. This makes the repair
  reversible and keeps the corrupt bytes for anyone who wants to know what happened —
  which matters most in the case where the "damage" was a hand-edit the user meant.
- **(d) Say whose version this is.** It restores the last version *GeneaLogic wrote*. If
  someone hand-edited the sidecar and that edit was good, restoring discards it. The
  confirmation has to say that, in the register `rebaseline()`'s does.
- **(e) CLI parity** — `genea repair --record <path>`, since `verify`/`reindex` already
  name skipped records and this is the verb that answers them.

**Out of scope:** repairing a **payload** file — there is no second copy of a TIFF anywhere,
and there never will be; conflict policy for two versions of a record (still **50**); and
any attempt to salvage a partially-readable sidecar by parsing around the damage.

**Verification.** Corrupt a sidecar, don't rebuild, restore: the file comes back
byte-identical, its checksum matches the manifest, and the record returns to its list. The
skew case: a preserved copy that re-encodes to a different hash is refused the one-click
path. 722 engine + 146 CLI tests on macOS (719 on Linux), 48 app tests.
**Hand-test:** the full loop from the banner — see the damage, restore it, and watch
the placeholder row become a real one.

**Shipped as specced**, with fork (c) settled to a **new reserved `.damaged/`** rather than
a corner of `.trash/` (decided 2026-08-13, before implementation). `.trash/` is a uid-keyed
namespace — `TrashStore.entries` reads each child's name as an item uid — so anything else
parked there is indistinguishable from a *corrupt trash entry*, safe only by a leniency
meant for those; and `TrashStore.purgeAll` removes the whole directory, so Empty Trash
would destroy quarantined bytes the user never chose to delete and that no listing showed
them. The cost that argued for nesting turned out not to exist: no pass excludes reserved
names by list — they are all scoped positively to `artifacts/`/`conclusions/`/`schema/` — so
the third reserved dir needed no exclusion audit. Spec §2 and CLAUDE.md updated. Disposal is
now by hand (Reveal in Finder); nothing empties `.damaged/`, which is one small JSON per
repair and is written down here rather than solved.

**One fork answered differently once built: the gate is "what is being replaced", not "is
it byte-exact".** Fork (a) reads as an exactness test, and an exactness test refuses the
case with the strongest claim on a repair — a sidecar *deleted* out of band keeps its copy
(58) but loses its manifest entry, because the carry-forward rule has no file to describe.
So the most sympathetic damage got a version-skew warning about an overwrite that cannot
happen. `requiresExplicitAcceptance` asks whether a file is there to lose, which is 58's
own drift-guard rule ("absent is a repair, not a clobber") arriving from the other side.
**And `genea verify` now says *which* damaged records can be restored**, rather than
naming the verb at records that have no copy — fork (b)'s rule is about honesty, not about
the app.

**`/code-review` then found three things a caller had been assumed to do cheaply, safely or
by eye**, all fixed here: `repairPlan(forRecordAt:)` re-reads and decodes the whole manifest,
so asking it per damaged row parsed `manifest.json` per row on the main actor (there is a
plural call now, and both list-holding hosts use it); `genea reindex` printed a repair
command missing its archive argument, so it could not be run as written (now held by a test
that parses every line the CLI suggests); and the Restore button sat inside a combined
accessibility element whose hand-written label never mentioned it, so VoiceOver reached the
restore only through the context menu.

**The hand-test then found `rebaseline()` destroying the proof this slice depends on.** It
re-minted the manifest entry of records the rebuild had just reported unreadable — 49
judged that harmless, and it was, until 59 made that entry the proof a restore is
byte-exact. So accepting an unrelated hand-edit recorded the corrupt file's hash as the
baseline and downgraded a provable one-click repair to the fallback, blaming version skew
that had not happened. Entries for unreadable records are now carried forward, matching
55's rule everywhere else. See [SLICE-LOG](../SLICE-LOG.md).

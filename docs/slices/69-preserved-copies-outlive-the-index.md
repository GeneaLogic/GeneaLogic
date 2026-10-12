# 69 — preserved copies outlive the index ✅

Specced 2026-10-07 from the [exit review](workstream-2-exit-review.md).

**Problem.** 58's preserved copy is sometimes a record's last, and three paths still destroy it
silently: an open unlinks the index over a `quick_check` that merely failed to *run*; crash
recovery discards the copy of every record lost since the last rebuild, not only the one the
died write was removing; and any recreation of the index — a schema bump, a corrupt or newer
file — takes every copy with it. Separately, no write is `fsync`ed, so a power cut can let a
rename reach disk before its data: an empty sidecar, and an index corrupted by the same event.

**Layer.** Engine only; no format change (everything touched is `.index/<machine>/`, or how a
write reaches the disk).

**Forks (settled 2026-10-07, as recommended):**

- **(a) The new-file path moves the old database aside and carries its copies forward.** It
  is the index's only unlink (`openOrRebuildIndex`). The old file is renamed with its hot
  `-journal`; the new index attaches it and stages its `orphaned_record` rows **and its live
  rows** (`uid, json, slug`, the same shape since v1) as preservation candidates before the
  rebuild, which prunes the live ones as it does now — so a record unreadable at the moment of
  a bump keeps its copy too, closing 58's v7 note. The old file is deleted only once every
  carry query has committed; if any fails it is kept, never deleted by the engine. **As
  built (`/code-review`):** it is moved to a *pending* name, `index-replaced-<UTC>.sqlite`,
  which every open carries — so an open that dies or throws after the move is finished by
  the next one — and one that cannot be carried becomes `index-unreadable-<UTC>.sqlite`,
  kept and not retried. A sidecar that cannot follow the move puts the database back. The sync-memory tables are not carried (lost today too).
- **(b) A check that didn't run is not a check that failed.** By SQLite result code, for each
  of the three probes (open, `user_version`, `quick_check`): `CORRUPT`, `NOTADB` or a non-`ok`
  row takes (a); anything else (`IOERR`, `BUSY`, …) fails the open and touches nothing. Taking
  (a) anyway, now that it is non-destructive, was rejected: a new file still strands another
  process's live connection (47), so only evidence should cause one. **Revised on
  `/code-review` (2026-10-07):** throwing on a *persistent* `IOERR`, `READONLY` or `CANTOPEN`
  left the archive unopenable with no way back. Now `BUSY`/`LOCKED` throw (the file is in use,
  the one thing it is certainly not is broken); anything else is retried once and, failing
  twice, replaced — which (a) has made non-destructive.
- **(c) Recovery discards only what the died write unlinked** — the journal's `unlink`
  entries (`journaledRemovals`, beside 68's `journaledWrites`). `removeArtifact` journals its
  `record.json`, since the folder leaves by rename and never passes `removeAuthoredFile`. A
  sentinel with no journal (pre-68, or a failed append) discards nothing: the cut removal
  reads as a loss with a copy, the closed direction.
- **(d) No `fsync`: a barrier before every rename.** `F_BARRIERFSYNC` on the temp file before
  `rename(2)` on Darwin, `fsync` on Linux — in `AtomicIO.write` and `copyFile`. The failure is
  *ordering*, not losing the last write, so no `F_FULLFSYNC` and no directory `fsync`. The
  dirty marker and its journal are flushed too, since the barrier orders only `fsync`ed I/O.
  SQLite stays at its defaults: (a) is what makes a corrupt index survivable. The cost per
  mutation is measured and recorded. **Measured** (medians, M-series SSD): `addPerson`
  2.75 → 3.9 ms, a 5 MB attach 11.8 → ~18 ms. The interrupted-write marker goes through
  `AtomicIO` too (`/code-review`).

**Out of scope:** carrying the sync-memory tables (`settled_file`, `deleted_path`, …) across
a new file; surfacing kept `index-unreadable-*.sqlite` files in verify; the rest of the ladder.

**Verified by** new engine tests: a schema-bump open keeps an existing copy and one for a
record unreadable at the bump; a garbage-paged index keeps the old file aside and opens; an
injected failure at each probe (open, `user_version`, `quick_check`, schema) — once: used
as-is; persistently: replaced with the copy carried; `BUSY`: refused, file untouched; a pending
file left by a died open is carried by the next; a removal
cut at `unlinked` discards its own copy while a record deleted out of band in the same window
keeps its copy and `missingFile` finding, and likewise for a cut artifact removal. macOS +
Linux. (d) is not observable from a test; its measurement is. **Hand-test (CLI):** make a
record unreadable, set `user_version` to 6, and `genea verify` / `genea repair` still restore
it; `kill-test.sh` with an out-of-band delete in the window.

**Shipped 2026-10-08** (merged); **hand-test passed** — the CLI half (a bump over a record
unreadable before and at it, both restored byte-identical; 150 real `kill -9`s mid-`remove`
with an out-of-band loss beside them, the loss keeping its copy in every cut before the manifest
commit and no removal leaving one), the app half restoring a record across a bump. Forks (a) and
(b) revised on `/code-review` as noted; the review's other findings fixed on the branch (see
SLICE-LOG).

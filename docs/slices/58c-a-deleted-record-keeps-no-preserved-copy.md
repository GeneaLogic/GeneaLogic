# 58c — a deleted record keeps no preserved copy ✅

Found while building 58b (2026-10-02); specced 2026-10-03.

**Problem.** A deletion that arrives from another machine takes an artifact's folder away
without this machine's index being told, so the next rebuild treats it like any sidecar that
vanished (58's rule) and keeps the record's last bytes in `orphaned_record`. Nothing prunes
the copy — 58 prunes on the uid being live again, and a deleted record's never is — and
nothing shows it: the app's placeholder rows and `genea verify` list only *unreadable*
records, the delivered manifest has already dropped the entry, and `discardPreservedRecord`
is called by neither host. So the index holds a "restorable" copy of something deliberately
deleted, for good; since 58b it also reserves the folder's name (a new artifact titled the
same gets `-2`). Confirmed in passing: `ManifestABATests`' delivered-deletion case leaves
exactly this row. Harmless today; it accumulates, and a later slice that surfaces preserved
copies would surface these as damage.

Conclusions are the larger half: a person, relationship, link or dismissal is deleted by
unlink, not trashed, so a merge or a removal on the other machine leaves the same copy here.

**Layer.** Engine only — one more prune in `ArchiveIndex.rebuild`. **No format change**, no
index table and **no `user_version` bump** (a bump unlinks the database and every copy with it).

**Forks (settled 2026-10-03, all as recommended):**

- **(a) The evidence is the manifest.** A copy is a deletion when the manifest the rebuild
  was given **no longer names its path** and the walk **found no file there**. On disk a
  Finder delete and a delivered deletion look alike; in the manifest they do not — only a
  commit drops an entry, and a lost file keeps its entry (→ `missingFile`, copy kept). Not
  `.trash/`: conclusions have none, and an emptied trash would make the copy permanent
  again. **This amends 58 fork (c)** ("never silently") with a third drop condition.
  *Residue, accepted:* a record lost out of band just as an older manifest that never named
  it arrives loses its copy — but that manifest already makes the loss unreported (49 fork
  f), so the copy was exactly the invisible row this slice removes.
- **(b) Pruned at the end of every rebuild, over the whole table** — beside 58's uid prune,
  not "never staged": a delivery that lands the file's removal before the manifest has its
  copy staged one rebuild earlier, and must still go when the manifest lands. A file found
  but unreadable is kept whatever the manifest says. Copies already accumulated go at the
  next rebuild. `rebuild` takes the manifest's record paths (all kinds) instead of only the
  artifact incumbents.
- **(c) `rebaseline()` counts as the deletion.** *Accept Current Contents* re-mints from disk,
  so a vanished record's entry goes and its copy follows at the next rebuild. The
  alternative is carrying that entry forward as rebaseline already does for unreadable
  records — but then nothing in either host could ever clear the `missingFile`, and the copy
  it protects is offered by neither host today. **Reversed by the second `/code-review`
  (2026-10-03):** rebaseline is archive-wide, so blessing one unrelated hand edit cost every
  lost record its last copy, unannounced. It now keeps the entry, as for an unreadable
  record; accepting a loss is `discardPreservedRecord`, which 58d puts in front of a user.
- **(d) No new visibility.** After (a) every surviving copy sits under a finding — unreadable,
  or `missingFile` since the manifest still names it. A repair offer on a vanished record's
  `missingFile` line is noted, not built.

**Out of scope:** surfacing or repairing a vanished record (→ 58d); a different record placed in
the folder by hand (58b fork d).

**Verification.** `DeletedRecordCopyTests`: a delivered artifact deletion and a delivered
person deletion leave no copy after reconcile, in both landing orders (file first, manifest
first); a Finder-deleted sidecar the manifest still names keeps its copy and its repair; an
unreadable file the manifest does not name keeps its copy; a copy staged by an older build
goes at the next rebuild; after a delivered artifact deletion a new artifact of the same
title takes the bare slug (58b's `-2` gone); `rebaseline()` then rebuild keeps a vanished
record's copy (fork c, reversed). `ManifestABATests`' delivered-deletion case asserts no row. Linux run.
**Hand-test:** `scripts/deliver.sh` — delete an artifact on `other`, deliver both steps,
`genea add` the same title on `mine` → bare slug.

**Shipped 2026-10-03** (merged); **hand-test passed** in the app — including *Accept Current
Contents* blessing an unrelated edit with a lost record still reported after it. One fold-in
was agreed mid-slice. Fork (a) assumed a lost file keeps
its manifest entry; it did so only until the next write. After a rebuild a vanished sidecar
has no row, and with a settled witness `awaitedPaths` reads that as a deletion — so any
unrelated write dropped the entry and silently withdrew the `missingFile` finding (true on
`main`), and under (a) the next rebuild would have pruned the copy too. Fixed by extending
55's carry-forward rule: a path with a preserved copy keeps the entry it has (carried, never
minted). Every new test fails on the old code but the unreadable-file guard. CLI hand-test
run: a delivered deletion in file-first order leaves `letter`, not `letter-2`; a lost sidecar
stays `missing-file` through a write and a reindex, and `genea repair` restores it
byte-identical. **Noticed, not fixed:**
a `rebaseline()` whose only effect is dropping one entry writes nothing — `commitManifest`
compares against the list the body left, the shape 50d special-cased for abandonment;
unreachable with any other authored record in the archive.

**`/code-review` tightened the fold-in three ways and declined four findings.** A vanished
record is now carried *exactly* like an unreadable one — its artifact payload entries too,
or a lost `record.json` dropped its masters' coverage on the next write — **except while an
interrupted write is unresolved**: a removal cut between unlink and manifest commit leaves
the same state, and must still end in the deletion rather than an `interruptedWrite` only
`rebaseline()` clears (65 already reads an absence under the sentinel as the died write). The
prune keeps a copy its `lstat` cannot answer for — it runs inside the rebuild's transaction,
and an `ENOTDIR` failed the open. `recordPaths(in:)` is now `isEngineAuthored`'s set, and the
nine private `deliver` test helpers are one in `TestSupport`. **Declined, with the residue
recorded:** carrying *every* vanished path (the review's altitude fix) would keep a
hand-renamed folder's old entry for good and undo the interrupted-removal rule — the copy is
the evidence because it exists only while the uid is live nowhere; a loss with no copy (a
recreated index) still loses its entry, as on `main`. A local write inside a delivered
deletion's window does carry the entry out, but it converges whichever manifest the provider
keeps (50b drops it on the deleting machine) — now pinned by a test. A delete that a sync
provider landed over an unheard local edit loses the copy: the manifest never names it again,
so keeping it would be an invisible row, and restoring the entry is 50b fork (d)'s declined
case. And copies `main` left for a lost record whose entry it had already dropped are pruned
on upgrade — the real archive holds no preserved copies at all (checked read-only), and no
build outside this machine exists. 1,022 engine tests on macOS (1,019 Linux), 162 CLI; the
kill rig clean over 150 kills.

**A second `/code-review` found the interrupted-write guard too blunt, and reopened (c).**
Switching the carry off for every record while *any* interrupted write was unresolved let one
died write elsewhere cost a weeks-old loss its entry at the next edit and its copy at the
next rebuild — and the recovery read that carried entry as the died write's residue, keeping
the suspect flag up. Now the **dirty-marker rebuild on open discards only the copies it
staged itself** for files that are gone (the cut removal's), and copies count as *referenced*
in the interrupted-write evidence. `rebaseline()` keeps a lost record's entry (fork c above).
`ENOTDIR` under a folder that became a file is *gone*, not *cannot say*. `TestSupport.deliver`
is strict again; a removal is `deliverRemoval`, by name. 1,024 engine tests on macOS (1,021
Linux), 162 CLI; the kill rig clean.

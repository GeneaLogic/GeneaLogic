# 65 — a write cut in half leaves one of two states ✅

**Problem.** `AtomicIO` makes each *file* atomic; a mutation is several — a sidecar, a
payload copy or a move into `.trash/`, a dozen index statements, the manifest — and the only
thing that says a crash landed between two of them is `.index/dirty`, which turns the next
open into a rebuild and a *suspect* flag. Nothing tests what that rebuild actually produces
at each cut. **Probed before speccing** (each shape built by hand, the marker set, the
archive reopened, or read off the code), five cuts land somewhere that is neither before nor after:
`replaceFile` overwrites a payload in place, so a cut before the sidecar leaves new bytes
under the old hash — `.checksumMismatch`, and **`rebaseline()` does not clear it** (the
sidecar's own hash carries forward), so the user is told a file is corrupt and given no way
to accept it, while the old bytes were staged in `/tmp`; a stash moves the folder *before*
writing `deletion.json`, so a cut between leaves an artifact that is in neither
`artifacts/` nor the trash listing — **invisible**, reported only as a missing record;
`detachFile` moves the file before rewriting the sidecar, so a cut between leaves a record
claiming a file the trash lists — `.missingFile` about bytes ten lines away; `restoreFile`
moves, purges, *then* writes the sidecar, so a cut after the purge leaves the bytes in the
folder and in neither the record nor the trash — only `.unreferencedFile`; and a cut that
changed *nothing* (between the manifest commit and the marker clear) still raises the flag,
which keeps the banner up and 58's drift guard **off** for the session.

**Layer.** Engine and tests. No format change: `.trash/` keeps `deletion.json` + `payload/`
(spec §2 names them and not their order); the test seam is internal. CLI and app untouched
(the app's banner wording already fits; it will simply appear less often).

**Design forks** (all settled with the user, as recommended, after a second-pass review):

- **(a) Cut by snapshot, not by throw — recommend snapshot.** ROADMAP's fork was
  in-process versus killing a `genea`; in-process, the seam must not *throw*, because a
  thrown error runs the engine's own cleanup — `AtomicIO` removes its temp, `withState`'s
  catch clears the sentinel when nothing was authored — which a crash never does, and the
  throw path is already what 47's and 58's tests exercise. The seam is an observer:
  `WriteCheckpoint.reached(_:)`, a `Mutex`-guarded optional hook (nil in production, one
  load per file operation) fired at every on-disk transition — temp written, renamed,
  moved, unlinked, each SQL statement, marker set, before marker clear. The test's hook
  copies the archive tree; each copy is the crash image, and is opened as one. **The copy
  includes `.index/` and any `index.sqlite-journal`:** the dirty-case rebuild is *in place*
  and keeps the tables a walk cannot derive (`settled_file`, `superseded_file`,
  `deleted_path`, `abandoned_path`, `meta` — 50's merge memory), so the index at a cut
  survives into the reopen, and a copy without its hot journal is not a crash image. Out of
  process stays the hand-test.
- **(b) The property.** For every mutation in the catalogue (each public mutating method,
  one representative call, on a small seeded archive): `before` and `after` are observed
  (indexed records with their on-disk bytes and referenced payloads; trash listings); at
  each snapshot, `open` succeeds, the observation equals `before` or `after`, `verifyIntegrity`
  reports nothing but `.interruptedWrite` and `.unreferencedFile`, the suspect flag is set
  **iff** an `.interruptedWrite` finding exists, `rebaseline()` then leaves it clean with the
  observation unchanged, and a second open agrees with the first — including the
  non-derived index tables, which are *not* part of the before/after observation. **The exception is stated,
  not hidden:** `mergePersons`/`revertMerge` write several records and no ordering makes
  that atomic across files; for them the property is the weaker one — every record is its
  before or after version, findings as above — and `mergePersons` already removes the loser
  *last* (45d's ordering), so a cut is a merge the user can finish, never dangling links. A write-ahead journal would close it and
  is a format addition; carried over, not built.
- **(c) The sentinel explains two more shapes — recommend extending 49's rule.** Today a
  mismatch is `.interruptedWrite` only when the file is engine-authored. Under the flag, a
  manifest entry that is *missing* and that the rebuilt index no longer references is the
  same fact (the archive's own view has moved past it: a removal or detach died before its
  manifest), and a *payload* mismatch whose sidecar entry matches the bytes on disk is too
  (the sidecar caught up, the manifest did not). Both today read as damage. A payload the
  index still references and cannot find stays `.missingFile` — the sentinel does not
  explain that, and (d)/(e) are what make it unreachable by a cut.
- **(d) `replaceFile` never overwrites in place — recommend a fresh package path.** §4.2.1
  already makes `path` package-assigned and `originalName` the user's; `attachFile` already
  copies to a fresh name and then writes the sidecar, so a cut leaves either the old state
  plus a stray (reported as `.unreferencedFile`) or the new state. Replace becomes the same
  shape: copy to a free path **derived from the replacement's `originalName`** (sanitize +
  `makeUnique`, exactly as attach), rewrite the sidecar, unlink the old path. This reverses
  a tested promise — `replaceFilePreservesUidAndPathButRefreshesContent` and the doc comment
  say the path is stable; ARCHITECTURE promises only the `uid` — so both are updated, not
  worked around. In-session undo (`revert(.replaced)`) is unchanged in meaning; restoring
  `priorEntry` reassigns its path if another file took it meanwhile.
- **(e) A stash writes `deletion.json` first, and a rebuild reconciles the trash —
  recommend both.** Record-first means a torn stash is always *visible* (a listed entry
  with no payload) rather than an unlisted folder. Then any open that rebuilds also walks
  `.trash/`: an entry whose subject the index still holds live is a stash that died — a
  file entry with a payload is moved back to the record's path; a payload-less one is
  dropped — so the archive lands on the state the sidecars describe, the arbiter the format
  already names. `restoreFromTrash` keeps its move-then-purge order (the move is its commit
  point; an unrun purge is a payload-less-live-subject entry). **`restoreFile` is
  reordered to sidecar, move, purge** — its subject is not live until the sidecar lands, so
  today's order has no cut the rule can see; reordered, every cut reconciles to the after
  state. `TrashStore.purge` removes the payload before `deletion.json`, so a payload with
  no record means only a pre-65 torn stash — recovering those is out of scope (none in the
  real archive).
- **(f) The flag is settled on open, not just raised — recommend yes.** A crash between
  `dirty` and the first write, or between the manifest commit and the clear, diverged
  nothing, yet today leaves the banner up and 58's drift guard *off* until the user runs
  *Accept Current Contents*. On an open that found the sentinel, after the rebuild, compare
  the manifest with what the rebuild saw — engine-authored entries hashed against their
  bytes, entries whose path the index no longer references, referenced paths the manifest
  lacks — and keep the flag only if something differs, **ignoring paths a delivery covers**
  (60c): an arrival in flight differs from the rebuild too, and keeping the flag for it
  would hold 58's guard off for a reason that is not a crash. One pass over the sidecars, only on
  the open after a crash, which already walked them all.
- **(g) Stray temp files stay.** `.record.json.tmp-<uuid>` beside a record is hidden, so
  every walk skips it, and it is the one residue `AtomicIO` already documents. Sweeping it
  would need every writer to hold the archive lock, which `Archive.create` does not. Noted
  in the seam's doc comment, not fixed.

**Out of scope:** a mutation journal (fork b's carry-over); an out-of-process kill test in
CI (47 ran one; it is the hand-test here); `Archive.create` and `upgrade` (not mutations of
an existing archive; create has nothing to cut *into*); `emptyTrash`/`deleteFromTrash` beyond
"opens and reports nothing" — a purge cut in half leaves less trash, which is what it was
for; recovering a pre-65 torn stash (a payload with no `deletion.json`); settling the flag from a *live* handle when another process crashed (60's reconcile
does not see the sentinel; unchanged).

**How it will be verified.** Engine: the property over the whole catalogue, at every
checkpoint, on both platforms — Linux via `scripts/linux-test.sh`, not a formality: the
snapshots are `rename(2)`/`flock` images; the seam has its own test (every write primitive
fires); (c)–(f) each get the direct test the property implies (the shape, hand-built, the
finding named). CLI: `genea` is the out-of-process half — a script that runs `genea add`
in a loop and `kill -9`s it at random offsets; Claude runs it, and every open afterwards
must succeed with findings ⊆ `.interruptedWrite`. **Hand-test:** on a *copy* of the real
archive, run that script, then open in the app: no alert; at most the "may not match"
banner; *Verify* → *Accept Current Contents* clears it; the artifact list is every record
that was there plus whichever of the killed adds landed, and nothing else.

**Shipped as specced**, every fork as settled. The property found one
thing the spec did not name: `open` cleared the sentinel unconditionally, so a second open
lost the flag and called the half-written record corrupt — the marker now stays until
`rebaseline()`. Departures, stated: the trash reconcile runs only on the open that found the
sentinel, not on any rebuild (a sync delivery brings `.trash/` and `artifacts/` in any
order); fork (f) does not count an entry the manifest *lacks* (unverified, not suspect,
which *iff* needs); a delivery-covered path is ignored only while its bytes are the settled
ones; and a verdict superseding another joins merge under the multi-record exception, with
purges checked as "opens and reports nothing". The kill script is `scripts/kill-test.sh`; it
alternates `genea add` with `genea set-meta`, since an add creates only records the manifest
has never heard of and so cannot leave the archive suspect. `/code-review` then replaced
two decisions above: the unresolved verdict is its own `.index/<machine>/interrupted`
marker rather than a `dirty` that stays (every open of a suspect archive was re-walking and
re-hashing), and a purge is one rename to a hidden name and then the delete, rather than
payload-first (which left a hollow `.file` entry that read as a legitimate record-only one)
— so a single purge now meets the full property, and `emptyTrash` the record-wise one. The
trash reconcile also skips any subject a delivery is bringing. **Hand-test passed**
(2026-10-01) on two copies of the real archive: 200 kills of `genea add`/`set-meta` left
every open succeeding with nothing new but `interrupted-write`; the copy whose crashes the
manifest had caught up on opened with no banner, and the copy left with one unresolved
rewrite showed the banner across a reopen until *Accept Current Contents* cleared it for
good, with the artifact list unchanged. 987 engine tests on macOS (984 Linux), 162 CLI, 82
app.

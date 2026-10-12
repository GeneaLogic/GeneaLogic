# 66 — a rebuild agrees with the incremental path ✅

**Problem.** "The index is a rebuildable cache" (§5.1) is an invariant nothing tests. Every
mutation keeps the index current through `upsert`/`remove…`; `rebuild(walking:)` regenerates
it from the sidecars; they are independent code paths that must produce the same rows, and
nothing compares them. A divergence would be silent in a particular way: what a query returns
would depend on whether this machine last *rebuilt* — after a schema bump, a crash, a
delivery, **Rebuild Index** — so a bug reads as a record that appears or changes with no edit.
**Probed before speccing** (2026-10-02): all 34 of 65's catalogue mutations, and 60 random
12-step sequences over 62's generated content (hostile strings, non-UTF-8 transcripts,
merges), rebuild to byte-identical derived rows. So 66 is expected to be a guard rather than
a fix; anything it finds is a defect and is fixed in the slice (55's rule).

**Layer.** Tests, plus a doc comment. **No format change, no index-schema change**, no
production change expected.

**Design forks** (settled 2026-10-02, all as recommended):

- **(a) Every index table is classified, and a tripwire holds the list.** *Derived* — a
  function of the sidecars and payload bytes, compared exactly: `artifact` (with `slug` and
  `search_text`), `person`, `relationship`, `link`, `file`, `place`, `dismissal`,
  `unreadable_record`. *Memory* — what this index has seen rather than what the archive
  holds, never compared against a walk: `meta`, `settled_file`, `superseded_file`,
  `deleted_path`, `abandoned_path`, `contested_file`, `orphaned_record`. **Recommend** the
  test reads `sqlite_master` and fails on any table in neither list or both, so a table added
  later without a decision fails CI rather than drifting out of the comparison — the
  "satisfied by accident" this rung was named for. The same list replaces the prose one in
  `rebuild`'s doc comment.
- **(b) Agree means raw rows, byte-for-byte — and the `json` column is the sidecar.**
  **Recommend** comparing each derived table as a sorted multiset of raw column values
  (`file` and `place` have no key; row order means nothing), not as decoded values: decoded
  equality would hide a re-encoding drift, and 58's preserved copies and 49's checksums both
  rest on the encoder being deterministic. Plus a second assertion: every derived `json`
  equals its sidecar's bytes on disk — 58 states it, nothing checks it at scale.
- **(c) Both rebuilds — recommend yes.** The in-place one (the dirty-marker path, **Rebuild
  Index**) and the fresh-file one (`.index/` gone — a new machine, a schema bump, a garbage
  index). They share the walker but not the starting tables, so a staging bug shows in only
  one. Across the in-place rebuild the memory tables are asserted **unchanged**, except that
  `orphaned_record` loses the rows whose uid is live again (the walker's stated rule) —
  compared around `ArchiveIndex.rebuild` itself, because `rebuildIndex()`'s commit
  legitimately rewrites the witness. Across the fresh one they are gone by construction.
- **(d) Random sequences over the whole mutation surface, damage included — recommend.**
  An iteration seeds 65's small archive and runs 1…N operations, each picking its subject
  from what currently exists (artifacts, files, persons, relationships, links, dismissals,
  trash entries, the token of an earlier replace or merge), with content from 62's
  `Arbitrary` through the update closures and transcript payloads from a hostile byte set
  (empty, non-UTF-8, NUL, BOM). **Two out-of-band operations join them**: *damage* (truncate
  a sidecar, then `rebuildIndex()`) and, after it, `repairRecord`/`discardPreservedRecord`.
  Without them `unreadable_record` is vacuously empty on both sides and repair — the one
  mutation that maintains it incrementally — is never compared; and the damage step's
  rebuild is how a sequence gets a rebuild in the middle. Compared once, at the end; short
  sequences come from other iterations. The failure message prints the seed, the iteration
  and the operation list; a found failure is minimized by hand into a direct test (62b).
- **(e) Budget — recommend a smaller default.** An iteration is an archive, a sequence and
  two rebuilds (~0.1 s measured), so 62's 200 would add ~25 s to every run. Default **50**,
  sequences up to 20 operations; `GENEALOGIC_PROPERTY_ITERATIONS` still overrides, as 63 (d)'s
  archive-level property does.
- **(f) Real history, not just generated history — recommend.** The generator cannot produce
  months of incremental writes from every build since v7. Engine half of the hand-test, run
  by Claude: on a *copy* of the real archive, dump the derived tables from the index the app
  has been maintaining, rebuild fresh, diff. The original is not touched.

**Out of scope:** out-of-band edits other than damage — a hand-edit or a delivery is
*supposed* to differ from the index until 60's reconcile runs, and that is 60's property;
whether the memory tables are *right* (50's and 60's suites); rebuild cost; folding `upsert`
and the walker into one code path (if they agree, the duplication is guarded; if not, the fix
is local).

**How it will be verified.** `swift test` on both platforms — Linux is not a formality:
directory enumeration order and `String(data:encoding:)` both come from
swift-corelibs-foundation there, and the walk order and `search_text` are exactly what they
feed. `SchemaSpecTests` untouched. **No app hand-test**: nothing is user-visible. The engine
half is (f).

**Shipped as specced** (merged 2026-10-02), every fork as settled — there is no app
hand-test, and (f), the engine half, passed. The property found one defect the probe had
not (55's rule, fixed in the slice): 65's record-first reorder of `restoreFile` took the index
upsert with it, ahead of the move back out of the trash, so a restored transcript's
`search_text` was read off an empty path — its words were unsearchable until something
rebuilt the index. The upsert now runs again once the bytes are back (the first stays beside
the record, so a move that throws leaves the index agreeing with what was written —
`/code-review`), and the minimized case is a direct test. One thing the spec did not foresee: at even weights the undo operations landed only a
handful of times a run, since each needs an earlier operation to leave it something; they are
weighted up, a step with nothing to act on re-picks, and the run fails if any operation never
lands at all. `/code-review` then made the property stricter: a refusal must be one the
generator could not have foreseen (anything else fails it, even with the index agreeing),
every pick follows first-seen order rather than uid order so a seed replays its operations,
and an iteration removes what it wrote. It also found a pre-existing defect outside this
slice, recorded as [**58b**](58b-a-new-artifact-must-not-take-an-unreadable-records-folder.md): `addArtifact` makes a slug unique against the index only, so it can reuse
the folder of an unreadable record and displace its preserved copy. A 1,000-iteration soak
found nothing further. **(f) passed** (2026-10-02): on a
copy of the real archive, all 131 derived rows of the app-maintained index matched a fresh
rebuild byte for byte. 1,000 engine tests on macOS (997 Linux), 162 CLI.

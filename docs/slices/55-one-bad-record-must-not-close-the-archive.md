# 55 — one bad record must not close the archive ✅

**Problem.** A single undecodable `record.json` or conclusion file makes the whole
archive **fail to open**. [`ArchiveIndex.rebuild(walking:)`](../../GeneaLogicKit/Sources/GeneaLogicArchive/ArchiveIndex.swift:632)
throws on the first file it cannot decode, and `Archive.open` calls it whenever `.index/`
is missing, unopenable, schema-stale, or dirty — so on a stranger's machine one corrupt
byte in one sidecar loses access to the other 2,999 records, with a decoding error and no
path as the only explanation. That is the wrong failure mode for a document-first archive
whose sidecars are its authority: the engine has no "skip and report the broken record"
path at all. Found while building 49, not fixed there; it is workstream (2)'s first
concrete slice.

**Layer.** Engine only (`ArchiveIndex`, `Archive.open`, `verifyIntegrity`), plus the
`.index/` schema. CLI and app get display. **No format change** — nothing about the
on-disk record format moves, and the manifest is untouched.

**Design forks:**

- **(a) What is skippable, and what still throws?** Per-*record* failures are skipped and
  collected: a decode failure, a truncated or empty file, a read error on that one file.
  Failures of the index itself — SQLite errors from `upsert`, the transaction, the schema
  write — still throw, because a rebuild that cannot store what it did read is not a
  degraded result but no result. **Recommend** that boundary rather than "only
  `DecodingError` is skippable": a permissions or I/O error on one file is the same
  situation from the user's side, and hair-splitting error types here just reopens the bug
  for the next unanticipated failure.
- **(b) Where does the finding surface?** As a new `IntegrityReport.Issue` case —
  `.unreadableRecord(path:)` — carried on the `Archive` the way 47's
  `interruptedWriteOnOpen` already is. **Recommend** this over a new return type from
  `open()`: it needs no API break, and it puts the finding where the user already looks.
  Both hosts switch over `Issue` exhaustively ([VerifyCommand.swift:74](../../GeneaLogicCLI/Sources/GeneaLogicCLI/Commands/VerifyCommand.swift:74),
  [IntegrityReport+Display.swift:11](../../GeneaLogicApp/GeneaLogicApp/Support/IntegrityReport+Display.swift:11)),
  so the new case is a compile-time prompt in both. `rebuildIndex()` returns the same list
  (`@discardableResult`).
- **(c) Does the finding survive an open that didn't rebuild?** Yes — persist the skipped
  paths in a small `.index/` table and bump `ArchiveIndex.schemaVersion` 5 → 6.
  **Recommend** this over keeping it in memory: in-memory means the user sees the problem
  the first time they open and never again, which is precisely the silent data loss this
  phase exists to prevent. The bump is free-by-construction — every existing archive
  rebuilds once on next open, which is exactly when the list gets populated — and the
  index stays a rebuildable cache, since the list is re-derived by every rebuild.
- **(d) Should `verifyIntegrity()` decode every record itself?** No — **recommend**
  reporting what the last rebuild found. The two halves already compose: on a *healthy*
  index, an out-of-band corrupt sidecar is caught by 49's manifest checksum; the case
  where a record is undecodable *and* missing from the index only arises when a rebuild
  ran. Decoding everything on every verify buys the overlap and pays for it twice.
- **(e) No threshold, no refusal.** Even "every record failed" opens and reports. A
  threshold turns "here is what is wrong" back into "refuse, without explaining" — the
  bug being fixed.

**Out of scope:**

- **Quarantining or moving the broken file.** Report only; it stays exactly where it is.
  Relocating a stranger's data on open is the opposite of the bar here, and quarantine is
  **50**'s word — that is where conflict policy decides it.
- **Salvaging a partially valid record** — no lenient decoding, no field-level recovery,
  no `repair()` change (still the stub).
- **The rest of workstream (2)** — property/fuzz round-trips, version skew, partial
  writes, index-rebuild equivalence. This slice fixes the one known unhandled case and
  establishes the skip-and-report path they will all report *through*.

**Verification.**

- Engine: for each of a corrupt artifact `record.json`, a corrupt conclusion, a truncated
  file, an empty file, and well-formed JSON of the wrong shape — `open()` succeeds, every
  *other* record is queryable, and the report names the bad path. Plus: the skipped list
  survives a second `open()` that does no rebuild (fork c); a rebuild after the file is
  fixed clears it; an all-records-corrupt archive still opens (fork e); a SQLite failure
  mid-rebuild still throws and rolls back (fork a's other side).
- `scripts/linux-test.sh` for engine and CLI — core, so Linux is a hard gate. No
  `SchemaSpecTests` involvement: no format change.
- CLI: `genea verify` and `genea reindex` both name skipped records.
- **Hand-test:** on a *copy* of the real archive, corrupt one `record.json`, delete
  `.index/`, open in the app — it opens, the artifact is absent, and the integrity panel
  names the file.

**Shipped as specced** — all five forks, no departures. 664 engine + 141 CLI tests pass on
macOS (661 on Linux — the ImageIO suite is compiled out), 20 app tests on macOS. One
implementation note worth keeping: the finding is read from the index at verify time rather
than carried on `Archive` beside `interruptedWriteOnOpen`, which the spec's fork (b)
suggested — once fork (c) put the list in the index, a second copy of it in memory would
only be a way for the two to disagree.

**Plus one thing the spec did not anticipate, found by `/code-review` and fixed in the
slice.** Slice 49 derives the manifest's coverage from the index, reading "absent from the
index" as "deleted" — which this slice made false. A skipped record therefore lost its
manifest entry *and* its artifact's payload entries on the next mutation, and got a fresh
baseline minted on repair, so **corrupt-then-repair silently laundered a substituted record
past `verify` and around `rebaseline()`**. Both directions reproduced against the built
`genea`, fixed by completing 49's rule (*a record the index cannot see keeps the coverage
the manifest already had*), and regression-tested. It stayed inside the slice: it is a
defect this slice introduced, not new scope.

**Hand-test passed** (2026-08-10). It raised the gap 56 exists to close: a damaged record
doesn't *look* damaged, it looks absent.

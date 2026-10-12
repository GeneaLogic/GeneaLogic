# 63 — hostile bytes must not be a crash ✅

**Problem.** 55 made one undecodable record skippable, proved on five hand-picked shapes.
The claim workstream (2) makes is over *all* bytes: whatever is in a `record.json`, the
engine decodes it or throws — never traps, never hangs — and the archive level skips and
reports every such file. Nothing walks that space. And 55 never covered the two files that
have no per-record skip path: `manifest.json`, and `.index/…/index.sqlite`. Probed before
speccing (2026-09-13): the decoder throws on everything tried (200k-deep nesting, invalid
UTF-8, lone surrogates, oversized numbers); a random-bytes, empty or truncated index is
caught by the header check and rebuilt; but **an index with a valid header and corrupt
pages passes `open` + `userVersion()` and the archive fails to open** — `database disk
image is malformed (SQLite code 11)` from the in-place rebuild. That is the same failure
mode 55 fixed, one file over, and `Archive+Lookup`'s `try?` policy already *assumes* open
has resolved it. A corrupt manifest throws correctly and prints a `DecodingError` dump.

**Layer.** Tests, plus `GeneaLogicTestSupport` (a JSON mutator) and two small engine
changes on the open path (forks e, f) and one bind fix (g). **No format change.** Anything
else the properties find is a defect and is fixed in the slice, 55's rule, with the
minimized input checked in as a fixture.

**Design forks** (settled 2026-09-13):

- **(a) The oracle.** "Decodes or throws" is vacuous in Swift unless it traps, so the
  property is three things: **no trap** (the process survives — loud by construction),
  **bounded time** (a `.timeLimit` trait on each property; a hang fails rather than
  stalling CI), and **a decoded value is a well-formed one** — whatever decodes from
  mutated bytes must satisfy 62's properties (`decode(encode(v)) == v`, byte-stable
  re-encode). Garbage in must never yield a value the format cannot write back.
- **(b) The mutation families and the budget.** Byte-level: truncate, bit-flip (single and
  a burst), invalid UTF-8 inside a string (overlong, lone continuation, truncated
  sequence, encoded surrogate), absurd length (a 1 MiB string; an array of 10k copies of
  an element). Structure-level: drop a key, duplicate a key, replace a value with each
  other JSON kind, `null` for a required value, 100k-deep nesting as a value. Structure
  mutations go through a small **ordered-JSON parser/emitter in `GeneaLogicTestSupport`**
  — `JSONSerialization` can neither hold nor emit a duplicate key. Finite families run
  **exhaustively on the first iteration of each type** (every truncation offset, every key
  dropped, every value re-typed) and sampled under 62's `PropertyRun` budget after, so a
  200-iteration run stays seconds per type. Inputs are 62's generated values, so the
  mutator sees every type and every hostile string.
- **(c) Duplicate keys are pinned.** First-wins, measured on macOS; the property asserts
  the same on Linux (62e's rule: a Linux failure must reproduce on a Mac). No engine
  change — the pin is so a Foundation change is visible.
- **(d) The archive level.** For each record kind, one archive; per iteration, one
  mutated sidecar written in place and `.index/` discarded. `open()` succeeds,
  `verifyIntegrity()` and `rebuildIndex()` complete, and the mutated path is **exactly
  one** of indexed (queryable, equal to what the decoder returns) or reported
  `unreadableRecord` — never both, never neither. A smaller budget than (b): each
  iteration is an open with a rebuild. The same for `manifest.json`: a mutated manifest
  either opens (and `verifyIntegrity()` then *reports* whatever the flipped checksum or
  path implies) or throws `corruptManifest` — never traps.
- **(e) What `open` says about a corrupt manifest.** The mechanism stays — there is no
  skip path, the manifest is the archive's ledger and `archiveUID`, and 49 fork (a) is why
  it is not reconstructed from the sidecars on open. **Recommend** keeping the single
  `corruptManifest` case and fixing its wording: a one-line human reason (*not valid JSON:
  unexpected end of file*; *missing `schemaVersion`*; *`files` has the wrong type*) via a
  `DecodingError` summarizer in the engine, followed by what is still true — the records
  are untouched, and the file can be restored from a backup or another copy of the
  archive. No new case, no host switch changes.
- **(f) A garbage index is unusable, not stale.** **Recommend** `PRAGMA quick_check` in
  `openOrRebuildIndex`, with any result other than `ok` (or an error running it) joining
  the *missing / unopenable / stale* triggers: remove the file, recreate, rebuild. **Cost is
  linear in the index file, ~0.3 ms/MB warm** (measured in-process on the real schema:
  6 MB / 3,000 records → 2 ms; 20 MB with 5 KB transcripts → 5 ms; 200 MB / 30,000
  records → 50 ms; cold adds one read of the file off disk) — it walks every page once,
  against a walk that decodes every sidecar. The alternative — catch `SQLITE_CORRUPT` on the open path and
  retry once from a fresh file — is cheaper on a healthy open and rejected: a corrupt page
  untouched at open surfaces later as a lookup that returns an empty list, which is the
  silent loss this workstream exists to prevent. The dirty-marker case is unchanged: it
  rebuilds in place because the file is *good*, and 47's live-handle argument does not
  apply to a file no handle can use.
- **(g) `bind(String)` truncates at NUL.** `sqlite3_bind_text(…, -1, …)` reads to the first
  NUL; the format stores `\u0000` verbatim (62). A place, file path or uid carrying one is
  indexed cut short — the `file` table feeds 49's manifest recompute, so the manifest would
  record a path that does not exist. Fixed with an explicit byte count and a direct test;
  the (d) property cannot see it because the lookup truncates the same way.

**Out of scope:** version handling (**64**) — a mutated `schemaVersion` that still decodes
is that slice's refusal; a write cut in half (**65**); rebuild-vs-incremental agreement
(**66**); a *reason* on `.unreadableRecord` — it would need an `unreadable_record` column
and an index schema bump, and 56 chose the path alone; lenient decoding, salvage, or
quarantine (55's out-of-scope list stands).

**How it will be verified.** `swift test` on both platforms — Linux matters for (c) and
because swift-foundation is the decoder on both. `SchemaSpecTests` untouched.
Engine half of the hand-test, run by Claude against `genea` on a scratch archive: corrupt
pages in `index.sqlite` → `list` works and the index was recreated; a truncated
`manifest.json` → the (e) wording. **Hand-test (app):** on a *copy* of the real archive,
overwrite the index's pages past the header with random bytes → the archive opens as
normal; truncate `manifest.json` → the open alert reads as (e) says.

**Shipped as specced**, every fork as recommended, plus two defects the properties found
and fixed in the slice (55's rule): a uid differing from its file name **in case only** was
reported on macOS as a duplicate to delete rather than a misnamed record — `fileExists` is
case-insensitive on APFS, the presence test now is not — and the NUL truncation of fork (g)
was on the read side too (`String(cString:)`). The decoder itself passed a 2,000-iteration
soak on both platforms. 941 engine tests on macOS (938 Linux), 158 CLI, 81 app.
`/code-review`: no findings. **Hand-test passed** (2026-09-16) on copies of the real
archive: the corrupt-paged index opened as normal and was recreated; the truncated
manifest refused with fork (e)'s wording.

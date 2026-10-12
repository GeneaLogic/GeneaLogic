# 58 — a rebuild must not destroy what it couldn't read ✅

**Problem.** `ArchiveIndex.rebuild` clears every table and re-inserts from disk, and since
55 a record whose sidecar won't decode is **skipped** — so no row goes back. That row was
not a derived summary: the index stores each record as a full `json` blob, written by the
*same* deterministic encoder as the sidecar itself (`GeneaLogicJSONCoding.encoder`,
`.sortedKeys` — `AtomicIO.writeJSON` and `ArchiveIndex.upsert` share it). **It is a
byte-identical copy of the file, and once the file is corrupt it is the only surviving
one.** A rebuild deletes it.

Two paths lead there, and the second is worse. The Verify Integrity panel offers **Rebuild
Index** as its primary action, helpfully labelled *"Safe — it never changes your data"* —
and 56/57's banner routes a user with damage straight into that panel. But `Archive.open`
*also* rebuilds whenever `.index/` is missing, schema-stale, or dirty, which is precisely
55's scenario: **the copy can be destroyed at open, before the user is ever told anything
is wrong.**

Found while specifying 59, off 57's hand-test (2026-08-11) — the user asked why a damaged
`record.json` couldn't simply be rewritten from index data, which is a better question than
it looks.

**Layer.** Engine, plus one UI string. **No format change** — `.index/` is disposable by
definition and outside the manifest; this changes what a rebuild *keeps in the cache*, not
what an archive contains.

**Design forks:**

- **(a) Preserve, don't warn.** Carry the existing row forward for any record the walk had
  to skip. **Recommend** this over a confirmation on Rebuild Index: a warning asks for a
  judgment at the moment the user has least information, and the row costs kilobytes.
  Identity resolves for both kinds — a skipped `conclusions/<kind>/<uid>.json` names its uid
  in the filename, and a skipped `artifacts/<slug>/record.json` maps through the `artifact`
  table's `slug` column — so neither needs the unreadable file parsed.
- **(b) Preserved rows must be unreachable from every query.** A preserved record is one the
  archive *cannot currently read from disk*; if it surfaced in a browse list, 55 and 56's
  whole story would invert and the user would see a phantom that looks healthy.
  **Recommend a separate table** (`orphaned_record(uid, path, json)`) rather than a
  `quarantined` flag on the live rows — same reasoning as 57's `FileSweepReport` not being
  an `IntegrityReport`: make the wrong thing *unavailable* rather than something every
  future `SELECT` has to remember to exclude.
- **(c) Lifetime.** Dropped when the sidecar reads again (the row is then redundant) or when
  the user explicitly discards it — never silently.
- **(d) The schema bump is the sharp edge.** Adding a table bumps the index's
  `PRAGMA user_version`, and a version mismatch is itself a rebuild trigger — so installing
  this feature runs exactly one rebuild on the old schema, with the old behaviour, before
  the preservation exists. **58 therefore cannot recover anything already lost, and on an
  archive that is damaged at upgrade time it destroys the copy on its way in.** That is not
  fixable from inside the slice; it is a reason to ship it sooner rather than later, and to
  say so plainly in the log.
- **(e) Fix the help text regardless.** *"Safe — it never changes your data"* is true of the
  sidecars and false of the last copy of an unreadable one. It needs correcting whether or
  not (a) lands.
- **(f) The other direction: an edit silently overwrites a drifted sidecar** (raised by
  57's hand-test, 2026-08-11 — "will anything warn me before I overwrite that copy?").
  **Case B needs nothing**: a preserved record has no live row, so it is a placeholder in
  the list and the Inspector cannot open it — (b) protects the copy by construction, and
  that is worth stating so it isn't re-litigated. **Case A is the real one and runs the
  other way.** Before any rebuild, the *live* index row is the only good copy, the record
  looks entirely healthy, and `updateMetadata` reads from the index and blind-writes the
  sidecar without ever reading it (`Archive+Artifacts.swift`). The edit therefore *repairs*
  the file — no record data is lost — but it discards whatever was on disk, with no warning.
  For a hand-edit or an agent's write, that is the §10.4 case arriving through the Inspector.
  **Recommend an exact pre-write check, and note why it can afford to be exact:** an edit
  overwrites **one small file**, so hashing that single sidecar against its manifest entry
  costs microseconds — unlike 57's archive-wide sweep, which is why this catches a
  *same-size* hand-edit that the sweep cannot. **In the engine, not the app**, so an agent
  driving the CLI is covered too — that being the scenario that motivates it. It must reuse
  57's interrupted-write classification, or it will fire on every edit after a died write,
  which is the one case where a mismatched engine-authored file is expected.
  **Scope call to make before building:** this is a mutation-path guard, not index
  preservation, and it could equally be its own slice. It is here because it is the same
  principle — *do not destroy the other copy without saying so* — applied in the other
  direction, and splitting them would spread one story over two logs.
  **Settled 2026-08-12, before implementation: (f) stays in 58**, and its two unanswered
  sub-forks are answered thus.
  **On drift, throw and refuse the write** — `ArchiveError.recordDriftedOnDisk(path:)`.
  Nothing is overwritten, so nothing needs stashing and the slice needs no new UI: the
  escape hatch already exists and is already gated on a human asking in as many words —
  `rebaseline()`, surfaced as *Accept Current Contents…* in the Verify panel and as
  `genea rebaseline`. The error text points there. The two rejected alternatives both
  write first and tell afterwards, which is the thing (f) exists to prevent.
  **Covers every authored record write, at the `writeAuthoredJSON` chokepoint** — so
  artifacts, persons, relationships, links, dismissals and merges are one implementation
  rather than a special case on `updateMetadata`. An agent editing conclusions through the
  CLI is as much the motivating scenario as an artifact edit, and the chokepoint version is
  the *smaller* diff. A path with no manifest entry is a new record and has nothing to
  compare; a path already written earlier in the same mutation mismatches because *we*
  changed it; and the whole check is suppressed while an interrupted write is unresolved,
  which is (f)'s stated requirement to reuse 57's classification.

**Out of scope:** the repair itself (→ **59**), and any write to a sidecar.

**Verification.** Rebuild an archive holding an undecodable sidecar: the record's JSON
survives, appears in **no** browse query, and `standingFindings()` still reports the path as
unreadable. A rebuild after the file is repaired drops the preserved copy. 706 engine +
141 CLI tests on macOS (703 on Linux), 43 app tests.
**Hand-test:** corrupt a sidecar, rebuild the index from the Verify panel, and confirm the
record is still gone from the lists; then hand-edit a *healthy* sidecar and try to edit that
record in the app — the edit is refused and the hand-edit is still on disk, and *Accept
Current Contents…* lets it through.

**Shipped as specced**, with (f)'s two open sub-forks settled before implementation. Two
things worth carrying forward. **Preservation covers fewer rebuilds than the spec implies:**
the copy lives in `.index/`, so it survives the dirty-sentinel rebuild and an explicit
Rebuild Index, but not a missing, corrupt or schema-stale index — `openOrRebuildIndex`
unlinks the database in all three. Fork (d) predicted this for the install-time bump; it is
in fact permanent, and applies to every future schema bump. **And the drift guard's baseline
had to be snapshotted** rather than read from `manifest`, because `withState` holds an
`inout` binding to it — the exclusive-access trap `commitManifest` already documents.

**`/code-review` then found the guard did not survive its own error path** — its refusal
armed the interrupted-write flag it consults, so a retry clobbered the file it had just
protected, and any unrelated failed mutation disarmed it for a session. Fixed by narrowing
both the flag and the sentinel to failures that actually authored a file. Two more fixed
here: preservation pruned against the unreadable list, losing the copy for a sidecar that
had *vanished* (the prune now keys on the uid being live again, which also stops a renamed
folder leaving a phantom); and the staging copy was measured — +1.1 ms per rebuild over 600
records, index high-water 385 KB → 737 KB and stable — and kept.

**The hand-test then found the guard was in the wrong place for file operations:** attaching
a file to a drifted artifact refused the record edit but had already copied the file into the
folder. Attach, replace, detach and restore now refuse *before* touching the folder — a
refused mutation must leave nothing behind. See [SLICE-LOG](../SLICE-LOG.md).

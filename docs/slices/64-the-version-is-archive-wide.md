# 64 — the version is archive-wide ✅

**Problem.** The format writes `schemaVersion` in two places — `manifest.json` and every
record (spec §8) — and the engine reads only the first. Every mutation stamps the record it
touches with `SchemaVersion.current`; `Migration` is keyed off the manifest alone; nothing
ever compares the two. Sync makes them disagree: machine A, on a newer build, upgrades the
archive and edits a record; the provider delivers `record.json` before `manifest.json`;
machine B, on the older build, opens in that window, decodes the record (dropping every field
it doesn't know), edits it, and stamps it back down. **A silent downgrade, reachable today**
by two machines on different builds.

**The decision that shapes the slice** (settled 2026-09-13, before 62 starts, because it is
a format decision): **the version is archive-wide, and there is no forward compatibility.**
Two alternatives were weighed and rejected. *Loaded-but-not-rewritable* per record: the freeze
is a property of a subgraph, not a file — a frozen person doesn't freeze the relationships
that name it or the merge that consumes it — so it either spreads unpredictably or leaks into
half-applied mutations; and under sync the older machine's archive hollows out one record at
a time as the newer machine works. *Unknown-field preservation*: it can write a file into
semantic incoherence, because the dangerous unknown field is one that *constrains* a known
one, and the older build cannot tell which kind it holds. **One rule instead:** a build does
not edit what it cannot fully understand; it says so at the door. Recorded in spec §8 with
its expiry condition — if 1.0 and 1.1 machines are ever meant to *write the same archive
concurrently* (a Phase 4+ federation question), preservation returns, with per-field rules.

**Layer.** Format (spec §8 rewrite, both copies), engine (`Migration`, `Archive.open`, the
rebuild walker, `ArchiveIndex`), CLI (one verb, error wording), app (error wording only).

**Design forks:**

- **(a) Migration is explicit, not automatic — recommend refuse-until-upgraded.** `open` on an
  older archive throws `needsUpgrade(from:to:)`; a new `Archive.upgrade(at:)` runs the
  pipeline; `genea upgrade` exposes it, so the user consents to locking out their other
  machines. *Open read-only without upgrading* was considered: it needs old records read by
  the new model in memory, i.e. migration as a decode transform rather than an on-disk
  rewrite — a different `Migration` architecture. Reconsider when 1.1's shape is known; not
  now. The app gets no upgrade affordance in this slice — with nothing to upgrade to it would
  be dead UI — but must render all three refusals below legibly.
- **(b) The record stamp has one job — recommend keeping it, as a stamp.** Spec §8 says: it
  MUST equal the manifest's version; the engine writes it; a reader uses it for exactly one
  thing, detecting disagreement with the manifest. Its independent justification is
  document-first: a `record.json` lifted out of the archive says what format it is, the same
  reason it carries `uid` rather than trusting its folder. No lazy or per-record migration —
  that would make the mixed state normal.
- **(c) Skew is asymmetric — recommend fail closed upward, report downward.** *Record newer
  than manifest* (the sync window) is evidence the **archive** is newer and this build doesn't
  know it yet: `open` refuses, naming the path and both versions, exactly as if the manifest
  had arrived. *Record older than manifest* (the other window — a straggler edit from the old
  build landing after the upgrade) is what migration is for, and a newer build can absorb it;
  with an empty pipeline there is nothing to absorb it *with*, so today it is skipped and
  reported through 55's path with a distinct reason. Version comparison is `major.minor` as
  integers; an unparsable version compares as newer — fail closed.
- **(d) This is not 55's forbidden refusal.** 55 fork (e) forbids closing the archive over a
  file the engine cannot read. This closes it over a file it reads perfectly, **with the
  reason and the fix in the message**. A hand-edited `"schemaVersion": "9.9"` locks the
  archive, naming the file and the field — a field the spec says the engine owns. Stated as
  the trade rather than hidden.
- **(e) The finding needs a reason — recommend a column, not a second table.**
  `unreadable_record` is path-only; add `reason` and bump `ArchiveIndex.schemaVersion` 7 → 8
  (free-by-construction, as 55's was). **59's Repair must refuse any reason that is not
  damage**: restoring a preserved copy over a record that is merely at another version is the
  data loss this slice exists to prevent, and with a distinct reason the refusal is one
  comparison.
- **(f) The refusal must be testable now — recommend an injectable `steps` chain.** There is
  no 1.1, so `needsUpgrade` cannot be reached through the public API. Give `Migration` an
  internal initializer that takes its `steps`, so a test registers a fake `0.9 → 1.0` step and
  proves: open refuses, `upgrade` runs it, open then succeeds, and `.index/` is rebuilt after.
  57b fork (e)'s rule: a policy nobody can exercise is a claim, not a test.
- **(g) The merge must keep the newer version.** `ManifestMerge` does not touch
  `schemaVersion`, so which side wins is accidental today. The merged result carries the
  newer build's version, never a straggler's — tested against `ManifestMerge` directly.

**Out of scope:** any migration step (the pipeline stays empty); the app's upgrade affordance;
*Export as older format* — the downgrade affordance is by definition lossy and is an export,
not a mode, and cannot be built or tested until there is a second version; the per-record
shape `Step.apply` will need to absorb a straggler (noted in `Migration.swift`, decided when
1.1 exists); unknown-field preservation (decided against, above).

**How it will be verified.** Engine: the three refusals (manifest newer, record newer than
manifest, manifest older without upgrade), each leaving everything outside `.index/` untouched
— `.index/` is machine-local and non-authoritative, so what a refused open leaves there is
never seen by the build that owns the archive; the straggler skipped and reported with its
reason; Repair refusing it; the fake-step upgrade round trip (fork f); the merge keeping the
newer version (fork g); `SchemaSpecTests` for the §8 rewrite in both copies. Linux via
`scripts/linux-test.sh`. CLI: `genea upgrade` on a current archive says so; the refusal
wording on a doctored manifest. **Hand-test:** on a *copy* of the real archive, set the
manifest's version to `"1.1"`, open in the app — the alert names the version and says to
update GeneaLogic, and nothing outside `.index/` changed; then set one record's version
instead — same alert, naming the file.

**Shipped as specced**, every fork as recommended, with two departures stated: fork (e)'s
`reason` column is added by `ALTER TABLE` rather than a `schemaVersion` bump — 58's own note
says a bump unlinks the database and with it every preserved copy, and the column is
additive in both directions — and the door is also on `withState`, so a handle already open
when a newer manifest lands refuses its next write rather than only its next open. The
refusals are `ArchiveError` cases (`archiveNewerThanBuild(path:found:supported:)`,
`needsUpgrade`, `noUpgradePath`, `repairNotForOlderFormat`), so app and CLI render them
without new code. `/code-review` found the record check was comparing against the
*manifest's* stamp where the archive's version is what matters — a straggler manifest
(fork g's own case) then refused the archive's own records on reconcile, and demanded an
upgrade that had already happened on the next open. Fixed by fork (c)'s own evidence rule:
a manifest behind the build costs one pass over the record stamps, and the newest stamp is
the archive's version; the walk compares against the build's. Also from the review: a
refused reconcile now arms 60's back-off, and `StandingFindings` carries each record's
reason so the app's banner and placeholder rows no longer call an intact older-format
record damage. **Hand-test passed** (2026-09-20) on copies of the real archive: the
manifest at `1.1` and one record at `1.1` each refused with the specced alert naming the
file and both versions, and both copies were byte-identical outside `.index/` after
repeated opens; a record at `0.9` opened with the older-format banner and row. The
hand-test found one more: *Accept Current Contents* left the straggler's checksum finding
standing, because `rebaseline()` carried every skipped record's entry forward under 59's
rule for records nothing can read — now only `.undecodable` keeps its entry. 972 engine
tests on macOS (969 Linux), 162 CLI, 82 app.

# 58b — a new artifact must not take an unreadable record's folder ✅

Found by `/code-review` on 66 (2026-10-02), outside that slice; specced 2026-10-02.

**Problem.** `addArtifact` and `restoreFromTrash` make a folder slug unique against the
**index alone** (`index.allSlugs()`), and a folder whose `record.json` the walk skipped (55)
has no row. So a new artifact titled like an unreadable one is given its folder: 58's drift
guard refuses the add (an unrelated write failing over a name), or — where the guard stands
down, as it does for a straggler `rebaseline()` blessed — the new sidecar overwrites the old
one, and the next rebuild's staging (`INSERT OR REPLACE` keyed on path) displaces the old
record's preserved copy with the new record's row. A restore whose original slug is taken
that way fails its `moveItem` instead, and the check was case-sensitive besides. **And 59's
repair writes back to a preserved path**: a sidecar that *vanished* keeps its copy, so a new
artifact in that folder would be carried off to `.damaged/` by an explicit inexact restore.

**Layer.** Engine. **No format change** — slugs are non-authoritative and the spec does not
say how they are assigned.

**Forks (settled 2026-10-02):**

- **(a) "Taken" is the index, the preserved artifact paths, and the disk.** Index slugs and
  the folder of every `orphaned_record` artifact path — even once the folder is gone — compare
  case-fold + NFC; the disk is **probed** for each candidate rather than listed (see
  verification). **Except the copy of the record being restored**: a deletion delivered by
  sync leaves exactly that, and restoring there is the record coming home (found by
  `ManifestABATests`, not foreseen in the spec).
- **(b) Trashed artifacts' original slugs are not taken** — a restore already re-slugs.
- **(c) Exactly two call sites**, `addArtifact` and `restoreFromTrash`; every other
  `Slug.makeUnique` caller names files inside a folder already covered.
- **(d) No defence in the rebuild's staging.** After (a) only a hand-made folder reaches
  that state, and choosing which of two copies keeps one path is its own decision.

**Out of scope:** a different record placed in an orphan's folder by hand (fork d).

**Verification.** `UnreadableFolderSlugTests`: the add either side of `rebaseline()`, the
blessed straggler, the vanished folder (repair restores without touching the new record), a
stray folder with no record, a restore over a damaged folder, over its own preserved copy,
and over a case-variant folder. 66's property: an `addArtifactOverDamage` operation the
coverage check holds the default run to, and a drift refusal from an add or restore no longer
passes. **Measured** (release, 10,000 artifacts): listing `artifacts/` cost +12.5 ms on a
164 ms add (~8%), so the disk is probed instead (+0.16 ms). CLI hand-test: corrupt a sidecar,
`reindex`, `add` the same title — it lands in `-2`, the damaged bytes and the `repair` offer
intact.

**Shipped as specced** (merged 2026-10-02); **hand-test passed** in the app. Every test it adds
fails on the old code, and 66's default run now finds the defect in three iterations (plain
title reuse met a damaged folder twice in 500). Noticed, not fixed: every deletion delivered
by sync leaves a preserved copy no rebuild prunes — named as
[**58c**](58c-a-deleted-record-keeps-no-preserved-copy.md).

**`/code-review` widened "taken" by one source and fixed three edges.** The manifest's
record paths count too: a delivery can land the manifest before the folder, and a folder in
flight is in neither the index nor on disk. The probe is `lstat` (a dangling link read as
free and the write into it failed). A restore onto its own preserved copy drops that copy at
once — left until the next rebuild it kept a repair offer that would have carried the
restored record off to `.damaged/`. And 66's operation reuses the damaged *folder's* slug,
not the record's current title, which `updateMetadata` may have changed. One finding was
declined as already decided: on a case-sensitive volume a hand-made case-variant folder still
does not block a name (the cost of probing over listing, chosen above).

**A second `/code-review` extended the restore's exception to all of a record's own
traces.** A deletion delivered into an open session leaves this machine's index row (by uid)
and manifest entry (matched by the trashed record's checksum) naming the record, and either
re-slugged the restore — the index row had done so since before 58b. The restore now drops
every preserved copy of its uid, not just the one at its landing path. The probe throws on any
error but `ENOENT`: read as free it wrote blind, and read as occupied an unreadable
`artifacts/` would never end the search. A restore tests its preferred slug once rather than
running a full search to discard; the taken set is normalized once; the manifest scan
suffix-filters first. **Measured whole:** an add at 10,000 artifacts is ~165 ms against 162 ms
on `main`. `upsert`-level copy dropping was not taken — the rebuild upserts every record, and
`orphaned_record` has no `uid` index. 1,013 engine tests on macOS (1,010 Linux), 162 CLI.

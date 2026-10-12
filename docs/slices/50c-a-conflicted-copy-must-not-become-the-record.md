# 50c — a conflicted copy must not become the record ✅

**Problem.** A sync provider that cannot merge one file leaves a second copy of it beside
the first: Dropbox writes `X (Ada's conflicted copy 2026-08-29).json`, iCloud writes
`X 2.json`. The 48–50 placeholder read this as *an unexpected file* — a detection problem.
**Measured on a demo archive 2026-08-30, it is worse than that in two of its three
shapes**, because two of the engine's discovery walks are name-blind:

- **`conclusions/<kind>/`** — `loadConclusions` decodes and upserts **every** `*.json` in
  the directory, so the shadow lands in the index under the same uid as the real file.
  Which copy wins is `contentsOfDirectory` order; in the probe the *stale* one did.
  `verifyIntegrity()` said `OK: no integrity issues found`. **The next ordinary mutation
  then wrote the shadow's contents into the canonical sidecar** — `person name add` turned
  `John Smith` into `John Smyth-STALE` on disk, manifest re-minted around it, verify still
  clean. That is silent data loss through the ordinary path, not a stray file.
- **`artifacts/<slug>/` folders** — the same defect one level up. The rebuild reads
  `record.json` in every subdirectory of `artifacts/`, so a duplicated *folder* gives two
  claims on one `ART-…`, an arbitrary winner in `allSlugs()`, and a loser — record and
  payload both — that `findUnreferencedFiles` never even scans, because that sweep
  iterates the slugs the index knows.
- **Inside `artifacts/<slug>/`** — already correct: any extra file, including
  `record (conflicted copy).json`, is reported `.unreferencedFile`. Nothing to do.

So the slice is about the **discovery rules**, not about pattern-matching a provider's
naming. Spec §2 already says only `record.json` and `manifest.json` are discovered by
name — but conclusions are discovered by *scan*, while `authoredPaths` mints
`conclusions/<kind>/<uid>.json` and the manifest expects exactly that. A canonical name
already exists; nothing enforces it.

**Layer.** Engine (`ArchiveIndex.rebuild`/`loadConclusions`, `Archive+Integrity`), CLI
(one new issue kind in `verify` output), app (its row and wording). **Format:** spec §2's
discovery paragraph gains the conclusions naming rule the engine already relies on — a
wording change in both copies, no on-disk change, no new reserved directory (fork b).

**Design forks** (recommendations; to settle before any code):

- **(a) What makes a conclusions file loadable — recommend: its name must be
  `<uid>.json`, and the uid inside it must agree.** Anything else in the directory is not
  loaded and is reported. The alternative — load everything and tie-break duplicates
  (newest `mtime`, longest file) — invents a heuristic where the format already has an
  answer, and still lets a shadow decide what a query returns. **The cost is smaller than
  it looks, and is measured:** a hand-named conclusion file is *already* half-broken today
  — the probe loaded `john-smith-handnamed.json` into the index **and** reported
  `missing-file` on the canonical path in the same breath. This turns that into one
  consistent answer instead of two contradictory ones.
- **(b) What happens to the copy — recommend: report it and touch nothing.** `.damaged/`
  is what the placeholder expected to borrow, and it is the wrong shape here: `.damaged/`
  holds bytes a repair had to *displace* to put something else in their place. Here the
  canonical file is already correct, nothing is being put anywhere, and moving the copy
  would mutate the user's package on a *read* and fight the provider, which will simply
  re-deliver it. It is also the only copy of the other machine's version — the one thing
  worth keeping. So: a finding, and the user resolves it at the source.
- **(c) A new issue kind, or reuse `.unreferencedFile` — recommend new,
  `.conflictingCopy(path:)`.** `.unreferencedFile` means *extra payload nobody claims*,
  and the app labels it `.stray`. This means *a second copy of a record, competing with
  the real one*, and the advice differs: look at it before deleting, because it holds a
  version of your data. Reusing the kind would put that sentence on every stray JPEG.
- **(d) Detect on structure, never on the provider's name — recommend structure.**
  `(conflicted copy` and ` 2.json` are provider-specific, localizable and brittle. *One
  uid, one file* is the archive's own invariant, is provider-independent, and catches a
  plain `cp` too. The provider's naming may be used to *word* the finding, never to find
  it.
- **(e) The duplicated artifact *folder* — which one wins?** Slugs are non-authoritative
  and renaming a folder is legitimate, so the name cannot decide. Two candidates:
  **(i) the folder the manifest already names** — principled (the incumbent entry predates
  the copy), falls back to lexicographic for an artifact that arrived with its copy in the
  same sync, and costs `rebuild` a manifest read it does not do today; **(ii) lexicographic
  first** — no new coupling, stable across machines and enumeration orders, and happens to
  pick the original under both providers' suffixes, but is arbitrary and would say so.
  **Recommend (i)**, because a deterministic *wrong* winner is exactly the shape 50b and
  50d kept refusing. Either way the loser is reported, and the invariant to state is that
  **a conflicted copy can never change what a query returns.**
- **(f) Where it surfaces — recommend `verifyIntegrity()` only.** Detection needs a
  directory walk, which is 56's Tier 2, not the free tier `standingFindings()` serves, and
  under (a)/(e) the *damage* is already prevented rather than merely announced — what is
  left to report is junk to clean up, which is not urgent enough to buy a `readdir` per
  record on every refresh.

**Out of scope** (each with its owner):

- **Merging the two versions of one record** → Phase 4+, unchanged since 50.
- **Deleting the copy for the user.** The provider re-delivers it until the conflict is
  resolved at the source, so the engine would lose that fight — and it would destroy the
  only copy of the other machine's version. Same reach limit 50b and 50d recorded: what
  crosses machines is the provider's ground.
- **Conflicted copies of `manifest.json` at the root.** Nothing discovers it, nothing
  reads it, and `findUnreferencedFiles` already declines the root as "a different question
  entirely". Harmless, and naming it here is cheaper than a sweep for it.
- **Anything inside `.index/`, `.trash/` or `.damaged/`** — reserved, non-authoritative,
  outside every pass by construction (spec §2).
- **A conflicted copy that is a *payload* file** — already `.unreferencedFile`, and 50c
  adds nothing to it.

**How it will be verified.** Engine tests reproducing all three probes above, with **the
laundering path as the load-bearing regression**: shadow present → ordinary mutation → the
canonical sidecar still holds the canonical content, which is the check that fails today.
**Determinism** — the same winner regardless of enumeration order, asserted against both
orders rather than trusting the filesystem's. Each of (a)'s two halves as its own negative
case: a correctly-named file whose inner uid disagrees, and a file that is simply not
`<uid>.json`. Convergence: a second verify reports the same thing and writes nothing.
Linux parity via `scripts/linux-test.sh`; CLI tests for the new kind's output. **Hand-test:**
`make-demo-archive.sh`, then `cp` a conclusion file and an artifact folder to conflicted
names and `genea verify` — the engine half, which Claude can run. The app half is the
user's: the row, its wording, and that the list shows the real record and not the copy.

**Built as specced, all six forks as recommended, with (e)(i) settled by the user.**
Three things the build established that the spec had not:

- **The Linux CLI run failed while the Linux engine run passed**, with `cannot find
  'RecordDiscovery' in scope` — `.build-linux-<package>` had cached the source list, so a
  **new file** in a path-dependency is invisible until that scratch directory is cleared.
  Worth knowing before the next slice adds a file rather than editing one.
- **A test that leaves both files in place can pass on a lucky enumeration.** The invariant
  tests are still worth having, but the load-bearing regressions are the ones with no
  ordering in them: the copy as the *only* candidate (the provider renamed the original —
  before the slice it was adopted, and the next mutation made the substitution permanent),
  and a copy carrying a different uid than its name (before the slice, a whole extra person
  the researcher never created, plus a manifest naming a sidecar that does not exist).
  Confirmed to fail without the fix, nine tests over.
- **The spec was wrong where it mattered**, which the fork about §2's wording had treated as
  an addition rather than a correction: it claimed every file but `record.json` and
  `manifest.json` is referenced by `path` from a `record.json`. Conclusions are discovered by
  *scanning*, and the canonical `<uid>.json` name the engine already writes **and expects**
  was written down nowhere — which is exactly how the walk came to accept anything. The §2
  and §6 headings also stop calling a uid a slug.

**Verified.** 21 `ConflictedCopyTests`, two `CLICommandTests` cases and three
`IntegrityReportSectionTests`; **857 engine tests on macOS, 854 on Linux**, 151 CLI on both,
72 app tests (`sectionsCoverEverySeverity` is what
holds the new severity to a section rather than a blank sheet).

**`/code-review` found four, and two of them were the slice hurting the data it exists to
protect.** Each is now a test:

- **The sole surviving copy of a record was reported as a duplicate, told to delete it.** A
  provider that resolves a conflict by renaming the *original* leaves exactly that, and the
  `.missingFile` companion the tests leaned on is dropped by `recomputeManifestFiles` on the
  next ordinary mutation — after which the deletion advice stands alone over the only copy.
  Split out as **`.misnamedRecord(path:uid:)`**, derived from disk on every verify, grouped
  with `.unreadableRecord` because the archive is not serving that record at all, and stating
  the remedy: rename it to `<uid>.json`. `.conflictingCopy` can now keep its promise that the
  path it names is never the record.
- **The lexicographic fallback was not arbitrary, it favoured the copy.** `' '` (0x20) and
  `'('` (0x28) both sort under the separator `'/'` (0x2F), so on the full path
  `artifacts/portrait 2/…` and `artifacts/portrait (conflicted copy)/…` beat
  `artifacts/portrait/…` **deterministically** — on precisely the archives with no incumbent
  to save them (a manifest written before 49 names no records at all). The record would have
  become the copy and the genuine folder's preservation masters would have lost their
  coverage. Compared at the folder instead, the original is a strict prefix of every name a
  provider derives from it. The fork's claim that lexicographic order "happens to pick the
  original" was backwards, and untested.
- **Verify re-derived the winner instead of asking the index.** That answers *which folder
  would win now*, while the index holds *which folder actually won*, and a copy arriving moves
  no manifest so nothing rebuilds. Where the two diverge the report could name the file the
  archive is serving. It now reads `allSlugs()`, with the rule as the fallback for a uid the
  index has no row for.
- **Dropbox's actual behaviour was still filed under "Stray Files".** The conflict is
  file-level — `artifacts/<slug>/record (conflicted copy).json` — and the scan only read
  `<dir>/record.json`, so the one classification whose wording invites deleting a file unread
  got the copy of a record. Sibling `.json` files that decode as an `Artifact` are now the
  finding they are (and only `.json` is read, so a preservation master is never parsed to
  learn it is not a record); the stray sweep is filtered by what this scan named, so no file
  is described twice.

**The app hand-test added two more, and one of them was a claim with no net under it.**
The misnamed row *stated* a remedy — rename the file — in a panel with no way to reach a file
inside a package bundle, which is 57's rule broken in its plainest form. It now carries
**Reveal in Finder**, which performs nothing on the archive and does not dismiss the sheet,
because the remedy has a second half. That second half was the other finding: after the
rename the row goes (verify walks the disk fresh) while the **record stays invisible until
Rebuild Index**, since renaming a conclusion moves no `manifest.json` and the witness
therefore still matches. That is §5.1 working as written — an out-of-band edit needs a
rebuild — but this slice is the first thing in the product that *tells the user to make one*,
so both surfaces now name the whole remedy: *rename it, then Rebuild Index* (`genea reindex`).
**Building the verb instead was considered and declined here**: the rename is safe and
reversible, but it is a verb with refusals and CLI parity of its own, and 50c settled on
report-and-touch-nothing. **And `sectionsCoverEverySeverity` did not exist** — the sheet's doc
comment has promised it since 60, and `.duplicate` was added trusting it. Written now, with
two siblings, so a severity that renders nowhere fails a test rather than a blank sheet.

**Hand-tested (engine half)** on a `make-demo-archive.sh` archive carrying both shapes at
once — a conflicted copy of a person sidecar and a duplicated artifact folder, each holding
a visibly stale version. `reindex` then `person list` / `list` returned the **originals**;
`verify` named both copies and nothing else; `person name add` left `"surname":"Smith"` in
the canonical sidecar where before the slice it wrote `Smyth-STALE`; both copies were still
on disk with no `.damaged/`; and deleting them returned the archive to `integrity OK`.
**Re-run after the review** over all four of its shapes at once — a renamed original, a
`record (conflicted copy).json` inside a folder, and a duplicated folder — which reported one
`misnamed-record` and two `conflicting-copy` and nothing else, and the rename the misnamed
line names did restore the record. The app half is the user's: the *Conflicting Copies*
section, the misnamed row under *Corruption*, their wording, and that the lists show the
record and not the copy.

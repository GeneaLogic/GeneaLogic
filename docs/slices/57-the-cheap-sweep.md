# 57 — the cheap sweep ✅

**Problem.** A tracked file that was deleted or truncated is invisible until someone runs a
full verify, but neither needs hashing to detect: `manifest.files` records `byteLength`, so
existence and size are a `stat` per entry — milliseconds for a few hundred files, no reads.
This is Tier 2 of the three tiers 56's discussion separated out (free / cheap / hashing).

**Scheduled off 56's hand-test** (2026-08-11), having been specced parked. Corrupting a
sidecar by hand showed nothing until the index was rebuilt — 56 reports what the archive
already knows, and a file edited on disk commits nothing for it to know. Verify Integrity
catches it (49's manifest checksums) but costs a full hash; this is the cheap path to the
same answer, and it is now a case a user hit rather than one we imagined.

**Layer.** Engine + app. **No format change** — and that is a fork's answer, not an
absence: see (a).

**Design forks:**

- **(a) Size and existence only — deliberately not mtime.** The manifest doesn't record
  mtime, and adding it would be both a format change and a false-positive engine: mtime is
  not preserved across copies, restores, or sync providers, so it would report drift on
  archives that are byte-identical. **Recommend** existence + `byteLength`, and say plainly
  in the UI what that does *not* cover.
- **(b) What it can't see is same-size bit rot** — a flipped byte in a TIFF keeps its
  length. So this sweep must never be presented as "your archive is fine"; it can only ever
  say "nothing obviously missing". **Getting that wording right is most of the slice's
  risk** — a cheap check that implies an expensive check's assurance is worse than no check.
  **Settled 2026-08-11, before implementation, and the answer is to say nothing at all:**
  the sweep has **no clean state** — no banner, no panel section, no "✓ 340 files checked".
  It speaks only when it finds something. That removes the over-claiming risk *by
  construction* rather than by careful phrasing, and it adds no new claim, since the absence
  of a banner has never meant "verified". This supersedes the "nothing obviously missing"
  wording proposed above, which is honest but is a sentence a user rounds off to "verified".
  **The findings themselves get no hedging**, which is the inversion worth naming: this
  sweep's *positives* are certain (the manifest says 700319 bytes and `stat` says 4096 — a
  fact, not an inference); only its *negative* is weak. So the rows read plainly, in 56's
  banner voice: "2 files are missing or the wrong size".
  **Settle it in the type before the strings** (56 fork (a)'s precedent — a type that can't
  express a claim it can't support): the call is **`sweepFileSizes()`**, not `quickVerify()`
  — 56 made the *expensive* call visible at the call site, and the symmetric job here is
  making the *limit* visible, so the name states the one field it compares. It returns a
  **`FileSweepReport`**, reusing `IntegrityReport.Issue`'s kinds per (d) but **not** the
  wrapper: `IntegrityReport.isClean` means *verified*, and the next person to touch this
  would render it with the "Archive Is Intact" string that already exists in
  `IntegrityReportSheet`. The sweep's property is **`foundNothingMissing`** — a name that
  sentence cannot be written from.
- **(b2) Which files, named in the banner** (settled with (b); the spec had not said, and
  there is no cheap surface today — the Verify panel is the expensive one). The banner names
  up to three paths and overflows to "…and *n* more", exactly as 56's banner already does
  for records with no list of their own. Files have no list of their own either, so this is
  the same case, and it needs no new surface. **Not** a cheap mode on the Verify panel and
  **not** a row on the owning artifact — both were considered and are larger builds; the
  artifact row also has nowhere to put a file whose artifact is itself unreadable.
- **(c) The blocker fork, to settle before building: cloud placeholder files.** On iCloud
  Drive a not-yet-downloaded file is *dataless* — present in the directory but without its
  bytes locally. If `stat` reports 0 (or anything but the real length), the sweep reports
  every undownloaded preservation master as truncated, on exactly the archives that need
  it most. **Measure this first** (`NSURLUbiquitousItemIsDownloadedKey` /
  `isUbiquitousItem`, and what `stat` actually returns for a dataless file); if the answer
  is bad, the fix is to skip dataless entries and say so, not to hash them. **This decides
  whether the slice is worth building**, which is why it is specced but not scheduled.
  **Measured 2026-08-11 on a real iCloud placeholder** (Desktop & Documents sync, file
  never downloaded): `st_size` is the **true logical length** — 700319 for a 700319-byte
  file — while `st_blocks` is `0`, `st_flags` carries `SF_DATALESS` (`0x40000000`, alongside
  `UF_COMPRESSED|UF_TRACKED`), `fileSize` agrees at 700319, and
  `fileAllocatedSize`/`totalFileAllocatedSize` are `0`. `isUbiquitousItem` is `true`,
  `downloadingStatus` is `NotDownloaded`. Neither `lstat` nor `URL.resourceValues`
  materialized it (still dataless after probing). **So the sweep is safe and the slice is
  worth building**, with one invariant it must not lose: **compare `st_size` only — never
  `st_blocks`, `fileAllocatedSize`, or `totalFileAllocatedSize`**, all of which read `0` on
  a dataless file and would report every undownloaded master as truncated. That is the
  false-positive engine this fork was written to prevent, now reachable only by
  "optimizing" to the allocated size. `UF_COMPRESSED` on the same file is a second reason:
  block counts under-report for local compressed files too. No skip is needed for
  correctness; what a dataless entry does change is the *meaning* of a pass — its size is
  the provider's metadata, not local bytes — which belongs in (b)'s wording.
- **(d) Reports through the existing kinds** — `.missingFile` and `.sizeMismatch`, the same
  cases `verifyIntegrity()` already produces, so no host's switch changes. **Plus
  `.interruptedWrite`, which `/code-review` showed was not optional:** the sweep first
  reported a died-mid-write engine file as a plain `.sizeMismatch`, so on one on-disk state
  the banner said "2 files are not the size the archive recorded" while the panel behind it
  said a change didn't finish. Both calls have everything needed to classify it — the
  sentinel, the path, `isEngineAuthored` — so both now do, identically. The app counts only
  the two cheap kinds into its headline, which leaves 56's hand-tested interrupted-write
  wording in charge of that case.
- **(e) Runs where 56's findings run** — on open and on 51's poll, off the main actor.

**Out of scope, but found by (c)'s measurement and needing its own decision:**
`verifyIntegrity()` hashes every manifest entry (`Checksum.sha256Hex(ofFileAt:)`,
`Archive+Integrity.swift`), and hashing a dataless file **materializes it**. On a synced
archive with un-downloaded masters, Verify Integrity is therefore not merely slow — it is a
whole-archive download, triggered by a menu item that doesn't say so. 57 makes this more
reachable, since its banner's button is "Verify Integrity…". Not fixed here (the fix is a
warning, or a skip-and-say, on the *expensive* path) — **decided and fixed in
[57b](57b-verifying-must-not-download-the-archive.md) ✅**, which took the skip. The good half: that call's existing
size check already goes through `attributesOfItem` → `.size`, i.e. `st_size`, so it is
dataless-correct today and 57 must not regress it.

**Out of scope:** hashing of any kind, and §10.4's mtime/count watermark for *stale reads*
— a related idea at a different price, still parked.

**Verification.** Engine: the sweep finds a deleted, truncated and grown file, and the two
lines that define it are held as tests — same-size rot is invisible here and visible to
`verifyIntegrity()`, and a file deleted on disk is invisible to `standingFindings()` and
visible here. 678 engine + 141 CLI tests on macOS (675 on Linux), 40 app tests.
**Hand-test:** damage some tracked files on disk, open the app — the banner names them
without anyone running anything, and a healthy archive says nothing at all.

**Shipped as specced**, with (b) and (b2) settled before implementation rather than during
it. **One departure, found by running the app:** three full paths wrapped to seven lines in
a narrow window, so the banner names file names, capped at two lines, with the full paths in
its hover text. **Then `/code-review` found four more, all fixed here:** the interrupted-write
classification in (d) above; file names alone rendering two damaged sidecars as
"record.json · record.json" — the "folder is the redundant half" reasoning inverts for the
one reserved name, so those are qualified by folder, as is any name that collides inside a
summary; a cancellation comment that claimed more than `cancel()` can deliver against a
synchronous walk; and a concurrent writer mid-mutation reading as missing files, now
narrowed (not closed) by re-checking that the manifest didn't move under the walk. See
[SLICE-LOG](../SLICE-LOG.md) for the measured numbers and the invariant they establish.

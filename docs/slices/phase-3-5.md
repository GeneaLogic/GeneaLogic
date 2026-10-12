# Phase 3.5 — share-readiness (before Phase 4)

**Goal:** the project is safe to hand to strangers — no data-loss footgun, no
personal data in the repo, and an archive that survives two writers.

The four workstreams are listed under *Immediate next step*; only the first slice is
specced. **Slice numbering continues the Phase 3 ladder** (47+), since these are
slices of the same codebase, not a new phase's worth of design.

# Immediate next step

**Phases 0–3 are complete.** Phase 3 met both its exit criteria: the manual loop
(create a person → resolve a mention → assert relationships → tree renders, surviving
an index rebuild), and the matcher mini-phase (the app suggests links with visible
decomposed reasoning; the user confirms / rejects / merges from a queue). The
per-slice record is the ✅ ladder above and [`SLICE-LOG.md`](../SLICE-LOG.md) — don't
restate it here.

**Next is a share-readiness pass before Phase 4** — [**Phase 3.5**](#phase-35--share-readiness-before-phase-4)
(decided 2026-08-05; the phase still owes itself an exit criterion, and only slice 47
is specced). "Share" means **open-sourcing the project**, not sharing one archive:
the bar is that a stranger's data is safe. Its workstreams, roughly in dependency
order:

1. **Multi-writer / sync** — ARCHITECTURE §10.4 (index staleness on out-of-band
   edits) and §10.5 (cross-process concurrent modification), until now parked for
   "Phase 4+". Two writers on **one machine** — the app open while an agent drives
   the CLI — is a live case today, and un-parks them now. **→ slice 47 ✅ shipped**:
   one machine is safe, §10.5 is resolved for it, and §10.4 is narrowed to
   drift the engine did not cause. **→ slice [49](49-the-manifest-covers-everything-authored.md)
   ✅ shipped**: sidecar and conclusion checksums are in the manifest, so drift the
   engine did *not* cause is now reportable — detection only, by design. **60 ✅, 61 ✅ and
   60b ✅, 60c ✅ and
   [48](48-the-index-is-machine-local.md) ✅ shipped; next
   [**50**](50-the-manifest-survives-two-machines.md) ✅ — where two *machines*
   stop being unsafe, in the order 48's speccing established (2026-08-23), with 60b
   inserted by 61's hand-test and 60c lifted out of 60b as fork (d). 48 gave every
   machine its own `.index/<machine-key>/`, so a sync provider never reconciles a
   database; 50 took the one document two machines really do fight over,
   `manifest.json`, and made it mergeable rather than winner-takes-all. **What is
   left here is [50b](50b-a-deletion-of-yours-is-not-a-delivery.md) ✅** — a deletion of
   yours no longer looks like a delivery that never comes — then
   [**50d**](50d-nothing-is-coming-and-the-way-out.md) ✅ — the state no
   evidence decides now has a way out — and [**50c**](50c-a-conflicted-copy-must-not-become-the-record.md) ✅ —
   a second copy of a record no longer becomes the record. **The correctness ladder is
   complete** — two machines can write, nothing diverges, and no writer clobbers another —
   and the one **cost** defect that was still standing in it closed by
   [**57b**](57b-verifying-must-not-download-the-archive.md) ✅ — verifying no longer
   downloads the archive to do it. **That measurement is done, and the section is
   closed** (2026-09-04): the macOS 26 file-provider sync-control probe, run from inside
   the sandboxed app. **Pause works there** — it fails only from a command-line process —
   and the capability key is unreliable in *both* directions, so nothing may gate on it.
   **Sync controls are not adopted**, decided on the measurement rather than around it:
   Apple's documented shape leaves an archive un-syncing for as long as its window is open
   (and paused indefinitely after a crash), while the narrow version protects a race that
   50 and 60 already resolve. **So workstream (1) is finished** — correctness ladder,
   cost defect, and now the one Darwin-only supplement that might have been owed. See
   § *macOS 26 file-provider sync controls*. **One defect reopened it, now closed:** [**50e**](50e-a-revert-is-not-a-stale-manifest.md)
   ✅ — a delivered revert read as a stale manifest, found by 65.
2. **Schema/format stress testing** — property/fuzz round-trips, truncated and
   corrupt sidecars, partial writes, version skew, index-rebuild equivalence. Best
   read as *input* to (1) rather than a lap after it. **One case is already known and
   unhandled** (found in 49, not fixed there): `ArchiveIndex.rebuild` throws on the
   first sidecar it cannot decode, so a single corrupt `record.json` makes an archive
   whose `.index/` is missing, schema-stale, or dirty **fail to open at all** — the
   engine has no "skip and report the broken record" path. That is the wrong failure
   mode for a stranger's archive, and it was this workstream's first concrete slice —
   **→ [55](55-one-bad-record-must-not-close-the-archive.md) ✅ shipped**: the record is
   skipped and reported, the archive opens. **The rest is now a ladder** —
   [**62–66**](62-66-format-stress-testing.md), planned 2026-09-13 with
   the workstream's own exit criterion: *it either works or it reports.* 62 (property
   round-trips over a hand-rolled generator) and 64 (the version is archive-wide; no forward
   compatibility, explicit upgrade) are specced; 64's format decision was settled first.
   **62 ✅, [63](63-hostile-bytes-must-not-be-a-crash.md) ✅ and
   [64](64-the-version-is-archive-wide.md) ✅ shipped** — 63 found two archive-level
   defects the decoder never had, both fixed in it; 64 closed the silent downgrade two
   machines on different builds could reach, with `genea upgrade` as the explicit way
   forward. **[65](65-a-write-cut-in-half-leaves-one-of-two-states.md) ✅ and
   [66](66-a-rebuild-agrees-with-the-incremental-path.md) ✅ shipped too — the ladder is
   complete.** 66's review found
   [**58b**](58b-a-new-artifact-must-not-take-an-unreadable-records-folder.md), which is
   shipped too; it surfaced
   [**58c**](58c-a-deleted-record-keeps-no-preserved-copy.md), now shipped too, and then
   [**58d**](58d-a-vanished-record-can-be-restored.md) ✅ — which closes the thread 66's
   review opened. **The exit review found twelve more** — see
   [§ *Workstream (2) exit review*](workstream-2-exit-review.md);
   the bugs among them are laddered as **67–71**; [**67**](67-a-scan-survives-its-own-ingest.md) ✅
   (the scan hotfix), [**68**](68-the-drift-guard-has-no-holes.md) ✅ and
   [**69**](69-preserved-copies-outlive-the-index.md) ✅ and
   [**70**](70-a-newer-record-is-refused-before-its-manifest.md) ✅ and
   [**71**](71-three-small-ones.md) ✅ are shipped. **The ladder is complete.**
   **So workstream (2) is finished — its exit criterion is met** (2026-10-09). A
   [confirmation review](workstream-2-confirmation-review.md) over all of
   67–71 found nothing in the engine's recovery paths. Its one data-losing defect was in the
   app (a refused scan's only way back) and is fixed. **One deferral can still break the
   criterion:** [#12](https://github.com/GeneaLogic/GeneaLogic/issues/12). A crash mid-upgrade
   re-runs a migration step, so the contract it asks for must land with the first real step.
   [#10](https://github.com/GeneaLogic/GeneaLogic/issues/10) and [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11) are durability policy for the user's own actions, not inputs. [#13](https://github.com/GeneaLogic/GeneaLogic/issues/13) is wording
   that no archive can reach before 1.1.
3. **Repo hygiene for a public release** — **next** (2026-10-09). There is **no `LICENSE`, `README`, or
   `CONTRIBUTING`**, so the code is legally all-rights-reserved until one exists (the
   license choice also governs whether a bundled CC-BY gazetteer is compatible
   later); and **real family data is scattered through the repo** — fixtures, matcher
   tests, source comments in `Archive+Matching.swift` and
   `Archive+SuggestedRelationships.swift`, and heavily through these docs. Scrubbing
   it is a decision to take **once, before the repo is public**, not after it is
   cloned.
4. **Issue entry + triage**, then the outstanding reviewer-agent recommendations.
5. **A second Mac-likeness pass** — last, because (1)–(4) generate more of it.

**Off 47, and independent of (1)–(5):** [**51**](51-the-app-notices-another-writer.md) ✅ —
the app notices another writer (its hand-test is what found the gap) — and its fork (d),
split out as [**52**](52-mutations-off-the-main-actor.md) ✅ — mutations off the main actor.
52 also re-ordered the engine's locks (a writer waiting on another process no longer parks
readers) and stood up the app's first test target. Neither needed anything from the sync
workstream; **[50](50-the-manifest-survives-two-machines.md) ✅ has now shipped there**,
and [**50d**](50d-nothing-is-coming-and-the-way-out.md) ✅ has now shipped there too —
[**50b**](50b-a-deletion-of-yours-is-not-a-delivery.md) ✅ has now shipped there too, as has
[**50c**](50c-a-conflicted-copy-must-not-become-the-record.md) ✅.

**Also independent of (1)–(5), and both now done:**
[**54**](54-the-linux-floor-moves-to-swift-6-3.md) ✅ — the Linux image is 6.3, matching the
Mac toolchain, and both manifests are `swift-tools-version: 6.3`. That was the gate on
every post-6.1 language feature; nothing adopts one yet, by design. And
[**53**](53-the-app-joins-the-engine-in-swift-6.md) ✅ — the app is in Swift 6 mode with
strict concurrency complete, so all three components are now checked the same way, and
52's off-main mutations are verified rather than assumed. **All of Phase 3.5's
language/build debt is therefore cleared; what remains is the (1)–(5) list itself.
[**55**](55-one-bad-record-must-not-close-the-archive.md) ✅ — workstream (2)'s first
slice, specced and built 2026-08-09 — took the known live bug out of the way, which is
why it came before 48. Its **hand-test then found the gap that 55 could not close from the
engine**: a damaged record doesn't look damaged, it looks absent — specced as
[**56**](56-damage-announces-itself.md) (banner + pinned placeholder rows in the artifacts
and persons lists, over one cheap engine accessor; no new detection, no format change).

[**56**](56-damage-announces-itself.md) ✅ shipped, which closes that thread: damage the
archive already knows about is now on screen without anyone running anything.

[**57**](57-the-cheap-sweep.md) ✅ shipped, which closes the rest of that thread: damage the
archive *doesn't* know about — a file deleted or truncated on disk — is now on screen too,
for one `stat` per manifest entry. Its blocking measurement came back good (a dataless
file `stat`s to its true length), so the sweep needed no special case, and its wording was
settled before any code: **the cheap sweep has no clean state and speaks only when it finds
something.**

**[58](58-a-rebuild-must-not-destroy-what-it-couldnt-read.md) and
[59](59-repair-a-damaged-record-from-what-the-archive-still-knows.md) then closed the damage
arc 55 opened.** 58 stopped a rebuild destroying the last copy of a record it could not
read — a byte-identical one, since the index stores each record as a blob from the same
deterministic encoder as the sidecar — and 59 spends that copy: the app restores the file
from it and proves the restoration exact against 49's manifest checksum, which is why 56
was right to refuse a repair then and right to offer one now. The damaged file is
quarantined in a new reserved `.damaged/`, never overwritten.

**[60](60-the-index-knows-whether-it-is-current.md),
[61](61-a-change-on-its-way-in-should-say-so.md),
[60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md),
[60c](60c-a-delivery-in-flight-must-not-speak-for-damage-it-did-not-cause.md) and
[48](48-the-index-is-machine-local.md) and
[50](50-the-manifest-survives-two-machines.md) and
[50b](50b-a-deletion-of-yours-is-not-a-delivery.md) and
[**50d**](50d-nothing-is-coming-and-the-way-out.md) and
[**50c**](50c-a-conflicted-copy-must-not-become-the-record.md) are done, which **closes the
sync workstream**.** 61 came
out of 60's hand-test — the engine could tell *arriving* from *damaged* but only said so
in a panel nobody opens speculatively — and **61's own hand-test found the bug 60b
fixed**: an archive whose `.index/` did not exist yet got its witness stamped
unconditionally at open, so a delivery that completed afterwards was **never adopted** and
`verifyIntegrity()` called the archive healthy while a record on disk was invisible to
every query. Reachable by any copy or restore that drops `.index/`, and 48 makes it the
normal case rather than a corner — which is why it landed **before** 48 and separately
from it. 60c is that slice's fork (d), lifted out for the same reason one level down: it
adds a mechanism where the rest of 60b retracted a claim. The rest is the
order
the sync workstream turned out to want, settled while speccing 48 on 2026-08-23. 48 was
going to be first, on the roadmap's lean that `.index/` moves out of the package to
Application Support; **that option is not available**, because the sandboxed app and the
unsandboxed CLI resolve different Application Support directories and would stop sharing
47's lockfile and 51's `data_version` — the placeholder's 48 bullet carries the full
finding and the new lean. What survives is that a per-machine index still has to know when
another machine wrote, and **that is a separate mechanism with its own subtle failure
mode** (a manifest witness, and sync's non-atomic delivery), so it is specced as **60** and
lands first. Two consequences worth reading there: 48 is **no longer a format or spec
change** at all, and cross-machine *mutual exclusion* is off the table for good — the flock
cannot extend past one kernel, so 50 is optimistic-and-reconcile, not a bigger lock. **The one un-scoped finding this section carried is now closed**, and is written up under
57's out-of-scope: `verifyIntegrity()` hashes every entry, and hashing a dataless file
materializes it, so Verify Integrity on a synced archive is a whole-archive download from a
menu item that doesn't say so. **Fixed in
[57b](57b-verifying-must-not-download-the-archive.md) ✅**, brought forward because 50c fork (f)
made that call the only surface for conflicted copies — a finding that occurs on exactly the
archives where running it is most expensive.

**Parked, deliberately:** the gazetteer-backed place matcher (45+ section — "not
before Phase 4"; 45o took the concrete pain out); the user-curated name-variant
table (`MatchKind.knownVariant` already exists for it — a matcher *accuracy* upgrade,
not a share-readiness one); ngram blocking below 45p's floor (parked with data).

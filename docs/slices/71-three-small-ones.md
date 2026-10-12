# 71 — three small ones ✅

Specced 2026-10-09 from the [exit review](workstream-2-exit-review.md).

**Problem.** Three things that say the wrong thing, none of which loses data:

- **A blocked path.** A record whose folder was replaced by a plain file is listed as missing (`isGone`
  reads ENOTDIR as gone), so Restore and Delete are both offered. Delete is refused as
  `recordNotMissing`. **Measured: the issue's fix is not enough on its own.** Restore fails
  too, with Foundation's raw "a file with the same name already exists" (Cocoa 516). Delete
  restores the record before it deletes it, so with only the `isGone` swap it would fail the
  same way, just with a different message.
- **Straggler wording.** The banner's "a change also didn't finish, so a record may be out of date" still
  checks `unreadableRecords`. Since 64 that list includes older-format records, which are not
  damage.
- **Dropped parser detail.** `DecodingFailure.summary` drops `context.debugDescription` when there is no
  underlying error. A manifest whose `byteLength` overflows Int64 says only "is not a valid
  value", without the reason.

**Layer.** Engine (the first and third) and app (the second). No format change. One new `ArchiveError` case.

**Forks (recommendations):**

- **(a) Blocked path: the engine checks for a blocked path before anything moves, and refuses with an
  error that names the blocker.** In `restoreLocked`, which both Restore and Delete go through:
  if a folder on the record's path is a file, throw `recordPathBlocked(path:, by:)`. The
  message says to move that file aside and try again. `deleteVanishedRecord` uses `isGone`, as
  the issue says, so it reaches this check instead of `recordNotMissing`. Both actions stay
  offered: the record really is missing, and once the file is moved either one works.
  *Rejected:* carrying the blocker on `RecordRepairPlan` so hosts hide both actions. That
  leaves a missing-record row with nothing to click and no explanation, and it touches both
  hosts for a corner nobody reaches by accident. *Rejected:* deleting without restoring. 58d
  already rejected that because it can't be undone.
- **(b) Straggler wording: gate on `unreadableCount`, and pin the wording with a test.** The banner's
  `headline` and `detail` move out of the private view into a small value, the way 57's
  `FileDamageSummary` did, so `GeneaLogicAppTests` can check an older-format record plus an
  interrupted write. No wording changes. That case now gets the existing "a record may not
  match what the archive recorded for it" line.
- **(c) Parser detail: when Foundation attached no parser detail, use `context.debugDescription`.** It
  gets the same cleanup as the parser's text: control characters replaced, trailing period
  dropped, first letter lowercased. **Narrowed while building (2026-10-09), measured:** on this
  toolchain an overflowing `byteLength` never reaches the keyed case. Both platforms' parsers
  reject it at the root. macOS says why ("number … is not representable in Swift"). Linux
  attaches no underlying error to *any* parse failure, so it says only "not valid JSON". At the
  root, `debugDescription` is always Foundation's "The given data was not valid JSON", so it is
  used only at a key. No manifest field can reach the keyed case today, so the test builds the
  error by hand.

**Out of scope:** [#13](https://github.com/GeneaLogic/GeneaLogic/issues/13) (parked until 1.1); the deferred [#10](https://github.com/GeneaLogic/GeneaLogic/issues/10), [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11) and [#12](https://github.com/GeneaLogic/GeneaLogic/issues/12).

**Verified by:**

- Engine tests for an artifact folder replaced by a file. Restore and Delete both throw
  `recordPathBlocked`, naming the folder, and nothing outside `.index/` changes. After the
  file is moved aside, Delete trashes the record and undo brings it back.
- `CorruptManifestTests`: a keyed reason found only in the context is included in the message;
  an overflowing `byteLength` says "not valid JSON" once, not twice.
- App tests for the banner wording, including older-format records plus an interrupted write.

Runs on macOS and Linux. Linux matters for (c), because the wording comes from Foundation.
**Hand-test (CLI):** on a throwaway archive:

- Replace an artifact's folder with a file and rebuild. `genea repair --record` and `--delete`
  both refuse, naming the file. Move it aside, and `--delete` works.

(c) has no reachable manifest to hand-test, and (b) is the app tests' job.

**Shipped 2026-10-09** (merged); **hand-test passed**. In the CLI and the app, Restore and Delete
each refused, naming the file in the folder's place. Once it was moved aside, both worked.

**Revised on `/code-review`:**

- A dangling symlink in a folder's place is a blocker too.
- The banner's wording merges vanished records itself and counts damage through the new
  `StandingFindings.undecodableRecords`.
- A reason that starts with an acronym keeps its capitals.
- Restore after the blocker moves is tested beside Delete, and the shared
  nothing-changed snapshot now records folders and symlinks.

**The exit review's ladder is complete.** [#10](https://github.com/GeneaLogic/GeneaLogic/issues/10), [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11), [#12](https://github.com/GeneaLogic/GeneaLogic/issues/12) and [#13](https://github.com/GeneaLogic/GeneaLogic/issues/13) stay deferred, as above.

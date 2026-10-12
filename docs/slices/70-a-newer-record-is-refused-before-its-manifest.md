# 70 — a newer record is refused before its manifest ✅

Specced 2026-10-08 from the [exit review](workstream-2-exit-review.md).

**Problem.** 64's door refuses a record newer than this build only when something *walks* it.
With the manifest current and its witness matching, `open` reuses the index, so a newer record
delivered ahead of its manifest is never read. A new one is silently absent. One that replaced a
sidecar is served as the old version, `verifyIntegrity()` reports it as a size and checksum
mismatch, and an edit to it is refused as drift, with advice (*accept the current contents*)
that is itself refused as newer. **Measured: no downgrade.** The drift guard refuses the edit,
and `rebaseline()` rebuilds and meets the door, so the issue's inferred consequence does not
happen. What is wrong is that 64 fork (c) promises *open refuses*, and the archive reports
an intact newer record as damage instead.

**Layer.** Engine, plus the ripple from one signature change; no format change. App and CLI already render `archiveNewerThanBuild` as text. **Settled while building (2026-10-08):** `verifyIntegrity()` becomes `throws` for (b). `genea verify` prints the refusal, and the app's Verify panel gets an error state that shows it.

**Forks (recommendations):**

- **(a) Open looks at what moved, not at everything.** With the manifest current,
  `Migration.check` reads the stamp of each record file that has no manifest entry, or whose
  `st_size` differs from its entry: directory listings plus one `stat` per record, and no
  unchanged file is read. A stamp ahead of the build → `archiveNewerThanBuild` naming the file.
  *Rejected:* reading every stamp on every open. That cost scales with the archive, is paid
  by every `genea` command, and materializes dataless sidecars (the cost 57b removed). *Accepted
  limit:* a newer record exactly the size of its entry passes the open. (b) catches it before
  anything is written over it. **Measured before agreeing it** (warm cache, synthetic
  archives): 4 ms at 3k records, 53 ms at 30k and 168 ms at 90k. That is about 1.4× the
  manifest decode every open already pays, and 0.2 ms on the real archive. The scan **must** be
  `readdir` + `fstatat`. `FileManager.contentsOfDirectory` builds a URL per file and costs 3×
  (177 ms at 30k). Reading every stamp instead would cost 586 ms at 30k.
- **(b) Wherever the engine has already found a record that differs from its entry, it reads the
  stamp before calling that damage:** the drift guard (before its witness switch),
  `verifyIntegrity()` (a size or checksum mismatch on an engine-authored record), and
  `repairRecord` (the file it would quarantine). A stamp ahead → `archiveNewerThanBuild`,
  **thrown**. Verify refuses rather than reporting, as `open` and `rebaseline()` do: an
  archive newer than this build is not this build's to judge. One helper, shared with `Migration`'s stamp reader.
- **(c) Not on `withState`.** A handle that is already open keeps writing until it meets a
  newer record (b) or a newer manifest (64). Running (a)'s scan on every mutation would refuse
  sooner, but it costs a `stat` per record per write. A write to a record whose newer version
  has not arrived races that delivery whether or not a sibling record has landed, so the
  earlier refusal would not stop the race.

**Out of scope:** the cheap sweep (57). Its banner still calls a newer record's size difference
a size mismatch until a reopen, a Verify or an edit turns it into the refusal. `mintEntry`
hashing an indexed record that has no manifest entry is unreachable since 49's first commit.
The rest of the ladder (71) is also out of scope.

**Verified by** engine tests that keep the index, which is the gap; 64's tests discarded it.
These cases are covered:

- A newer record that replaced a sidecar, or a new one with no entry: the open refuses and
  names it, and nothing outside `.index/` changes.
- A same-size stamp swap: the open passes. Then an edit, `verifyIntegrity()` and
  `rebaseline()` each refuse with the version error, not drift, and the file stays
  byte-identical.
- A record that lands under an open handle: the edit refuses the same way.
- A repair whose damaged file was replaced by a newer record: refused.
- A current-version hand edit still opens and is still drift.

Runs on macOS and Linux. **Hand-test (CLI):** on a copy of the real archive with its `.index/`
in place:

- Give one record `"schemaVersion": "1.1"` plus a field. `genea` refuses, naming the record.
- Do a same-size stamp swap instead. `genea verify` and an edit both refuse with the version
  message.

**Shipped 2026-10-09** (merged); **hand-test passed**. In the CLI half, a newer record that
changed size was refused at open, naming it, with nothing outside `.index/` changed. A same-size
one opened, then the edit, Verify and *Accept Current Contents* each refused, leaving it
byte-identical. In the app half, with the window open, the edit, the delete and Verify each
refused with the version message, and the reopen refused, naming the file.

**Revised on `/code-review`:**

- The drift guard reads the stamp when a record has no baseline too.
- `removeArtifact` and `upgrade` check the stamp.
- A manifest from before 49 skips the scan, and dataless files are not read.

A malformed stamp stays *newer* (64's rule). The hand-test's banner finding is [#13](https://github.com/GeneaLogic/GeneaLogic/issues/13), parked until
1.1 (see the ladder).

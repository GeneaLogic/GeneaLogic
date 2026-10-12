# 57b — verifying must not download the archive ✅

**Problem.** `verifyIntegrity()` hashes every `manifest.files` entry, and hashing a dataless
file **materializes it**. On a synced archive with un-downloaded preservation masters, Verify
Integrity is not merely slow — it is a whole-archive download, from a menu item that does not
say so, and the report it produces says nothing about having done it. Recorded as 57's
out-of-scope finding and left for its own decision; **two slices have since made it more
reachable**, which is what brings it forward now: 57 put a button labelled *Verify Integrity…*
on the damage banner, and [50c](50c-a-conflicted-copy-must-not-become-the-record.md) fork (f)
made that call the **only** surface for conflicted copies — a class of finding that occurs on
precisely the synced archives where running it is most expensive. The workstream's correctness
ladder is complete; this is the cost defect left standing in it.

**The archive already knows the answer before it reads a byte.** `byteLength` is in the
manifest for every entry, and `SF_DATALESS` comes from the `stat` 57 already performs
(`FileSweepReport.datalessFileCount`). So "41 files, 3.2 GB are not on this machine" is
computable for free; nothing new has to be measured or stored.

**Layer.** Engine (`Archive+Integrity`), CLI (one flag), app (an action on the report). **No
format change** — every input is already in `manifest.json` or in `stat(2)`.

**Design forks** (recommendations; to settle before any code):

- **(a) Skip or warn — recommend skip.** Verify checks what is here and reports what it did
  not check; downloading is a second, explicit act. *Warn-and-proceed* was considered and is
  worse: it puts the entire cost behind one OK button, and a report that says **Archive Is
  Intact** after pulling 40 GB nobody asked for has earned nothing but the bill. 57's rule —
  a surface must not claim an assurance it did not pay for — cuts the same way here.
- **(b) How the report says it — recommend `notChecked` beside `issues`, and an `isComplete`
  that the intact headline gates on.** 50d's `abandonedPaths` is the shape: not a finding,
  because nothing is wrong. But `isClean` means *no problems found*, which stays true and
  **stops meaning verified** the moment anything is skipped — exactly `FileSweepReport`'s
  problem one tier up, where the answer was a property the false sentence cannot be written
  from. So `isComplete` (`notChecked.isEmpty`), and *Archive Is Intact* renders only on
  `isClean && isComplete`. **That string is the thing this fork exists to protect**; it is the
  one sentence in the app that claims verification.
- **(c) The default — recommend skipping by default** (`includingDatalessFiles: Bool = false`).
  It changes what every existing caller does, in the direction of doing less and claiming
  less, which is the safe direction for a default to move. **On Linux there are no dataless
  files, so behaviour is byte-identical** and the cross-platform contract is untouched — the
  new parameter is inert off Darwin by construction rather than by `#if`.
- **(d) What the cost is stated in — recommend exact bytes, not a file count.** The manifest
  has `byteLength` for every entry, so *"41 files, 3.2 GB"* costs nothing and is the only form
  of the sentence someone can decide from. A bare count is not a decision.
- **(e) Testability — recommend one injectable seam, because CI cannot make a placeholder.**
  57 settled `SF_DATALESS` by measurement and recorded that nothing in CI can produce such a
  file; `nothingLocalIsDataless` is all it could hold. The skip logic must not inherit that
  gap. Put *is this file materialized* behind one internal predicate that tests substitute, so
  skipped / checked / opted-in / Linux-no-op are each a **test** rather than a claim. The
  signal stays what 57 measured; only the question becomes injectable.
- **(f) Where the action lives — recommend on the report, not ahead of it.** A modal before
  the pass has to guess; the pass is what produces the number. Run, report, and offer
  **Download and Check the Rest** beside the skipped list — the same per-item placement rule
  50d fork (e) settled, and it extends 57's tiering by one rung: free, cheap, hashing, and now
  downloading, each entered deliberately.

**Out of scope** (each with its reason):

- **`rebaseline()` — measured, and not affected.** It drops only *authored* entries, and
  payload entries are re-derived from the index's `file` projection rather than re-hashed
  (`payloadEntries`), so it materializes sidecars and **never** a preservation master. Worth
  recording rather than assumed, since the call looks archive-wide and blunt from outside.
- **`repairRecord()`, `sweepFileSizes()`, `standingFindings()`** — one record file, one `stat`
  per entry, and a `SELECT`. None reads payload.
- **Providers that are not iCloud.** `SF_DATALESS` is what 57 measured; whether Dropbox or
  OneDrive placeholders set it on current macOS is **unmeasured, and this slice must not imply
  they do**. The skip degrades in the safe direction — an unrecognised placeholder is hashed,
  which is today's behaviour exactly.
- **Making `.conflictingCopy` reachable from a cheaper tier.** 50c fork (f)'s call stands; this
  slice removes the reason it was uncomfortable rather than reversing it.
- **§10.4's mtime/count watermark for stale reads** — a related idea at a different price,
  parked since 49 and still parked.

**How it will be verified.** Engine tests through the injected seam for every branch: a
dataless entry skipped and listed, a materialized one checked, the opt-in hashing both,
`isComplete` false exactly when something was skipped, and the byte total computed from the
manifest **without touching disk**. **`isClean && !isComplete` must not render as verified** —
an app test, because the string is the risk and no engine test can see it. Linux parity via
`scripts/linux-test.sh`: identical behaviour where no placeholder exists, which is the
property that keeps the contract. CLI tests for the flag and for the report line.
**Hand-test:** the engine half on a genuinely iCloud-hosted archive with an evicted master —
`brctl evict` is the way to produce a real `SF_DATALESS` file, and confirming that is itself
part of the hand-test, since it is the one condition CI cannot stage. The app half is the
user's: the skipped section, its wording, that *Archive Is Intact* does **not** appear, and
the download action.

**Shipped as specced**, every fork taken as recommended. **What the build settled that the
spec left open: the skip is the hash and nothing else.** Presence and size are still checked
on a placeholder — `st_size` is its true length, so a cloud-hosted master whose recorded size
no longer matches is still damage, and the cheap sweep and the expensive one cannot end up
describing one file two ways. **One departure, in the app:** the panel's verify moved off the
main actor. It was a synchronous main-actor hash pass, already a long freeze on a large
archive and an *unbounded* one the moment a button on it can start a transfer. **Accepted and
recorded rather than assumed:** the record-discovery walk still reads sidecars, as
`rebaseline()` does — kilobytes, and a report that could not read the records could say
nothing about them.

**Then `/code-review` found the slice's own claim leaking back in three ways**, all fixed
here: a read that *failed* vanished from the report (a `try?`), leaving it clean **and**
complete over a file nobody had read — so `notChecked` means *unread*, with a `Reason`, and
one layer down an unopenable file was hashing as **empty** and being reported as corruption;
the panel's unread row called a file "present and the right size" directly under a Corruption
row saying otherwise; and the download had no cancellation point anywhere beneath it, so Done
dismissed the sheet while the transfer ran on. It cancels between 1 MiB chunks now, and a
stopped pass names every entry it never reached.

**Left as specced, and worth a second's thought if CI ever depends on it:** a partial pass
does **not** change `genea verify`'s exit code. Skipping is not a fault, and failing on one
would make every synced archive red; the line says PARTIAL instead.

**Hand-tested against a real placeholder (2026-09-01), and staging one took three
attempts** — worth recording, because the third is the only one that works. `brctl` and
`~/Library/Mobile Documents/` are blocked by TCC from Claude's shell, so the user ran it.
**`brctl evict` on a file *inside* a `.genea` crashes** — `BREvictItemAtURL` asks for the
item's ubiquity metadata, gets `nil` (the same `nil` this document already records for
`Probe.genea/manifest.json`), and throws `NSInvalidArgumentException` building an array out
of it. **Per-file eviction inside a package is not available.** In a *non-package* archive
directory each file has its own identity (`isUbiquitousItem == true` per file) and evicts
individually, which is how the test was finally staged: a 512 MB master, evicted, reading
`size=536870912  blocks=0  flags` with `SF_DATALESS` set and `downloading=NotDownloaded` —
57's measurement reproduced inside an archive. `genea verify` then printed `PARTIAL:`, named
the file at 536.9 MB with its reason, and offered the flag; `--download-cloud-files` pulled
it back and printed `OK:`.

**Then the package case was measured, and it is neither of the two answers this slice
expected.** On a package-born `.genea` in iCloud Drive the interior has **no per-file
ubiquity identity at all** — `downloading`/`uploaded`/`uploading` all read `nil`, against
real values for the same files in an ordinary directory — because the **package** is the
ubiquitous item. Eviction happens to the package; any access to a path inside materializes
the whole of it; and the inner files read fully present (`blocks` non-zero, no flags) the
instant they can be seen at all. Confirmed twice over: a directory *renamed* to `.genea`
keeps its old per-file identity and does show dataless files, which is why that shortcut had
to be discarded, and probing the master inside a genuinely package-born archive re-downloaded
the archive on the spot.

**So `SF_DATALESS` never appears inside a `.genea` on iCloud, and this slice's skip cannot
fire there.** What it does cover is an archive kept as an ordinary directory — measured
end-to-end above — and, possibly, providers that place per-file placeholders, still
unmeasured. 57's fork (c) measured a flat file in Desktop & Documents sync and the premise
was carried to packages unchecked; both halves were already in this document and were not
joined up.

**What that leaves standing, and what it opens.** Nothing shipped is wrong: behaviour is
byte-identical where no placeholder exists, the `isComplete` discipline is right whatever
made a file unreadable, and `/code-review`'s three findings were defects on paths that have
nothing to do with iCloud. What it opens is the same defect one level up and much larger —
**an un-downloaded archive downloads in full the moment anything opens it**, before a single
check runs, with no skip available because the filesystem will not show the interior
otherwise. The package *does* report its own downloading status, so that cost is knowable
before `Archive.open` touches it. Specced as **57c** if the call is to build it; not built
here. See [SLICE-LOG](../SLICE-LOG.md).

# 48–50 — cross-machine sync (placeholder, deliberately not specced)

**Not one slice.** Three separable decisions, so a single spec could not be written
in a screenful. *Written as "two of which touch the format" — that held when 49 was
one of the three; the format change lived there and shipped, and 48's turned out not
to exist (see its bullet).* Named here — with the forks that are
already sharp — so they are not rediscovered, in the *parked with data* style the 45+
section uses. **Specced when 47 lands**, since 47 and the stress-test slice supply the
data two of these forks turn on.

**The scoping recommendation that shapes all three:** Phase 3.5's bar is *no silent
data loss*, not *working multi-machine sync*. **Detect the unsafe case and fail
loudly** — that is a fraction of the cost of merging and is what shipping to strangers
with a caution actually requires. Genuine write-write reconciliation can go to Phase
4+ without blocking a public release.

**The rig for all three is `scripts/deliver.sh`** — two copies of one archive
and a delivery you step through by hand, since the in-flight window these slices
live in is not reachable by copying an archive in one go. Read its header before
trusting a result from it: both of its rules exist because breaking them
manufactured a convincing engine bug (a size comparison in 60, a too-eager
restore in 61).

**The conflict is `manifest.json`, and it happens on *every* concurrent edit — even
when no two records conflict.** Found while hand-testing 61 (2026-08-24), and it is
the sharpest fact any of these three has to design around. Every mutation on every
machine rewrites that one file, so a sync provider always has to pick a winner, and
the loser's bookkeeping goes with it. Measured, with the two machines editing
**different** people:

```
### both edits are on disk; only the manifest had to be picked between
PER-…db0e   Gussie OTHER-EDIT
PER-…c510   David MY-EDIT

awaiting-delivery  conclusions/persons/PER-…c510.json  …wait, then check again…
```

Both records are intact and readable — the data is *there* — but the surviving
manifest describes the other machine's version of the record only this machine
edited, so it reports `awaiting-delivery` for a file that **will never arrive**:
`manifestDeliveryLooksComplete` stays false, the witness never settles, the index is
never reconciled, and 61's indicator sits at "receiving a change" until it escalates.
The archive is wedged by a *manifest* disagreement while every *record* agrees.

Three consequences worth carrying into the specs. **A per-machine or append-only
shape for the authored half of `manifest.files` is now the leading candidate** —
a single rewritten document cannot survive concurrent authorship, which is the same
argument that made `.index/` machine-local. **Detect-and-fail-loudly needs a state it
does not have:** *the manifest disagrees and nothing is coming*, which is neither
damage nor an arrival, and which 60's two-way classification cannot express. **That is
50d, and only 50d** — the half of it that turned out to be decidable from evidence went
to [50b](50b-a-deletion-of-yours-is-not-a-delivery.md) instead.
[60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md) built the three-state
`WitnessState` this would extend — but it is a *fourth* answer, not one of those
three, and knowing that nothing is coming is new detection, which 60b deliberately
had none of. And **61's stall escalation is load-bearing after
all**: it is the only surface that says anything at all in this state, and here it is
telling the literal truth.

- **48 — where the index lives.** ✅ **Shipped** as
  [48](48-the-index-is-machine-local.md) — `.index/<machine-key>/`, no format change,
  no migration. The bullet below is the speccing that got it there and is kept for
  the options it closes; the slice section carries what was actually built.
  Gates 47's deferred WAL fork. Options: (a) keep
  `.index/` in the package and mark it sync-excluded; (b) move it out entirely
  (Application Support, keyed by `archiveUID`); (c) keep it but treat it as
  disposable when a conflict is detected. ~~**Leaning (b)**~~ — **(b) is not
  available, established 2026-08-23 before speccing.** The app is sandboxed
  (`GeneaLogicApp.entitlements`), so its `.applicationSupportDirectory` resolves
  inside `~/Library/Containers/<bundle-id>/Data/…` while the
  unsandboxed `genea` resolves `~/Library/Application Support/`. The two would get
  **different directories for one archive**, which means `.index/lock` stops being
  one file and **47's cross-process exclusion silently stops excluding** — worse than
  not having it — and separate databases also kill **51's `PRAGMA data_version`
  poll**, so the app stops noticing the agent's writes. The package is the only
  writable ground both processes share, which is why `.index/` is there. **And (b)
  would not have bought what it was for:** sidecars and `manifest.json` go through
  `AtomicIO`'s rename, so sync never replicates a torn one; `index.sqlite` being
  clobbered is a non-event, since it is rebuildable. The cross-machine loss case is
  two machines mutating `manifest.json` concurrently — that is 50's, not 48's.
  **New lean: a per-machine subdirectory inside the package**, `.index/<machine-key>/`,
  keyed by `volumeUUIDString` with `gethostname()` as the fallback where it is nil
  (both verified to return usable values here, 2026-08-23; volume UUID is preferred
  because it survives a machine rename and a reboot). No two machines then write one
  file, so a sync engine never has to reconcile a database and conflicted copies of
  one cannot arise, and each machine keeps its index warm instead of rebuilding on
  every handoff. **Costs:** the package carries other machines' caches (152 KB for
  the real archive — it scales with record count, not payload size) and they want a sweep.
  **The spec cost this bullet budgeted disappears:** `.index/` stays a reserved
  top-level dir, so §2's statement in both copies is unchanged and 48 is no longer a
  spec change at all.
  **48 now depends on [60](60-the-index-knows-whether-it-is-current.md)** and must not
  be built first: per-machine directories remove the write conflict but say nothing
  about *staleness*, so without 60 every cross-machine handoff leaves the receiving
  machine's index silently stale. **A machine stamp on a shared `index.sqlite` does
  not substitute** — considered and rejected, because its trigger is the arrival of
  the *database*, which is unrelated to whether the sidecars arrived; it detects
  whose index it is, never whether it is current. 60 is needed under either layout,
  which is what stopped it being a differentiator.
  **Mutual exclusion does not extend across machines, and 48 must not pretend it
  does.** `flock(2)` works because one kernel arbitrates every contender; a
  cloud-synced folder is a local directory with a store-and-forward daemon and no
  arbiter at all. A file-based claim protocol has the same hole — two machines each
  write a claim, neither has received the other's, both proceed — and no finite wait
  repairs it, because a machine can be offline for days with a perfectly good local
  filesystem, making "no competing claim" and "an undelivered competing claim"
  indistinguishable. The right primitive at this distance is optimistic — let writes
  happen, detect divergence, reconcile — which is 50.
- **49 — out-of-band change *detection*** (§10.4). ✅ **Shipped** — narrower than this
  bullet first read: it folds sidecar and conclusion checksums into the manifest so
  drift is **reportable**, and stops there. Making stale *reads* self-heal is a
  different mechanism at a different price (the cheap mtime/count watermark), still
  parked — **this bullet used to conflate the two**. The format change lived here, and
  it needed nothing from 48.
- **50 — conflict policy.** Written as *what happens when sync produces two versions
  of a record* (a Dropbox "conflicted copy", an iCloud duplicate), with the v1 answer
  most likely *detect, quarantine, and tell the user* rather than merge. **That is not
  where the live failure turned out to be**, and the reproduction under
  [50](50-the-manifest-survives-two-machines.md) says so: no record ever conflicts, and
  the archive wedges anyway on the manifest. So the number went to the manifest merge,
  conflicted-copy *files* became **50c** ✅, and the fourth state this section asks for is
  **50b** (with the fourth state itself, which no evidence decides, split out as
  **50d**). **Worth recording as an asset, and it is now being spent:** the archive's
  shape is unusually favorable to merging — per-record sidecar files, UUIDv7 identity,
  and no central mutable state except a recomputable manifest and a rebuildable index.
  The same property is what makes the manifest itself mergeable: it is a set of
  independent per-path facts, not a narrative.

**What 47 must not foreclose:** resolve the lockfile and the `.index/dirty` sentinel
through `ArchiveLayout` rather than hardcoding paths, so 48 can relocate both in one
place. Both stay correct under (b) — two processes resolve the same `archiveUID` to
the same lock path — but only if nothing else knows where they are.

## macOS 26 file-provider sync controls — measured, and mostly not usable yet

Verified against the SDK header (`NSFileManager.h`, MacOSX26.5.sdk), not the docs site,
and then **measured against iCloud Drive on macOS 26.6.2 (2026-08-30)** — which is what
turned this section from a fork-shaper into a record of what does not work. Foundation
gained sync control in **macOS 26 / iOS 26**: `pauseSyncForUbiquitousItem(at:)`,
`resumeSyncForUbiquitousItem(at:with:)`,
`uploadLocalVersionOfUbiquitousItem(at:withConflictResolutionPolicy:)` and
`fetchLatestRemoteVersionOfItem(at:)`, with capability discovery via the
`NSURLUbiquitousItemSupportedSyncControlsKey` resource value. `.genea` satisfies the
API's package requirement — slice 3 registered it, and a `.genea` in iCloud reports
`isPackage == true`.

**Pause works from the sandboxed app, and the capability key is wrong in both
directions** (measured 2026-09-04 from a temporary File-menu probe inside the sandboxed
app, on `syncTest.genea` in iCloud Drive; the throwaway code was reverted with the
measurement). From a **plain command-line process**,
`NSURLUbiquitousItemSupportedSyncControlsKey` read **3** — `pauseSync |
failUploadOnConflict` — on the package *and* on a flat file, while
`pauseSyncForUbiquitousItem` failed on both with `NSFeatureUnsupportedError` (3328). From
the **sandboxed app**, on a security scope the user granted through the open panel, the
same key reads **`nil`** on the package and `pauseSyncForUbiquitousItem` **succeeds**;
`resumeSyncForUbiquitousItem(at:with: .preserveLocalChanges)` succeeds after it.

**So the gate any adoption would have rested on is unusable.** It took the *yes* branch
where the call fails, and takes the *no* branch where the call works — a design that
queried it and degraded gracefully would have disabled a working feature on the only
configuration that has it. **Attempt the call and handle the failure; never gate on the
key.** (Whether the `nil` is the sandbox declining to report the resource value or the
provider declining to advertise it is not worth chasing: it cannot be relied on either
way.)

**A third confirmation that the unit is the package.** In-package `manifest.json` read
`isUbiquitousItem=nil` and failed pause with **`NSCocoaErrorDomain 4099`** — *couldn't
communicate with a helper application*, not `NSFeatureUnsupportedError` — i.e. there is no
per-file item for the XPC call to address. Same conclusion as 57b's hand-test reached from
the dataless side.

**Decided 2026-09-04: not adopted. This section is closed with a finding, and the
measurement is why it can be closed confidently rather than left open.** What was
established is that the API is *available*, not that it earns its cost. The shape Apple
documents — "call this when opening an item", i.e. pause for the life of the open document
— is wrong here: an archive window stays open for hours, so a session-long pause means an
archive that **does not sync all day**, and a crash inside that window leaves it paused
indefinitely while the user believes they are backed up. The narrow version (pause around a
*mutation*, which is milliseconds) buys a correspondingly narrow race that
[50](50-the-manifest-survives-two-machines.md)'s manifest merge and
[60](60-the-index-knows-whether-it-is-current.md)'s witness already resolve after the fact —
so it protects almost nothing that is not already handled, at the price of a mandatory
resume-on-launch sweep whose failure mode is a silently un-synced archive. **Neither
version clears that bar.** Reopen this only if a *new* need appears that optimistic
reconcile genuinely cannot serve; the measurement above stands, and the two traps it
records — never gate on the capability key, and the unit is the package — are what a future
reader needs. **What it must not be asked to justify:** sync
controls would not have prevented anything
[50c](50c-a-conflicted-copy-must-not-become-the-record.md) fixed — `failUploadOnConflict` is
package-granular, so it cannot see a per-file conflict, and a copy left by a provider that is
not iCloud is not governed by these APIs at all. *One uid, one file* holds under `cp`; this
would be a Darwin-only supplement to it, never a replacement.

**The unit is the package, not the path.** Files *inside* a package have no independent
ubiquity identity: the package reports `uploaded=true` and `syncControls=3` while
`Probe.genea/manifest.json` reports `nil` for both. Pause, upload and fetch are
therefore package-granular. **This closes the "it may also answer 50 better than we
would" reading this section used to carry**: `fetchLatestRemoteVersionOfItem` cannot say
whether one *named path* is still coming, which is the only question
[50d](50d-nothing-is-coming-and-the-way-out.md) asks. It could still support a
whole-package fetch-rebase-retry loop one day — over the per-path manifest merge 50
already built, which makes 50 that loop's **prerequisite, not its alternative**.

**Per-subdirectory exclusion *is* available, and this section previously said it was
not.** `NSURLUbiquitousItemIsExcludedFromSyncKey` is **read-write since macOS 11.3** and
**works on a subdirectory inside a package** — measured: setting it on
`Probe.genea/.index` wrote the `com.apple.fileprovider.ignore#P` xattr and made that
subtree non-ubiquitous, while the package went on syncing and `manifest.json` beside it
was untouched. The old claim conflated exclusion with *pause*, which is genuinely
package-wide. This does not reopen 48 — `.index/<machine-key>/` shipped and made another
machine's database a non-event — but it is a real optimisation, parked as a candidate
below. **Two traps, if it is ever built:** reading the key back on an in-package item
returns **nil**, not `true` (an excluded item is no longer ubiquitous, so ubiquity keys
stop being reported), while a top-level item reads back `true` — and the write reports
success either way, so a naive set-then-verify concludes it failed. The observable
inside a package is `isUbiquitousItem == false`. And the flag is an xattr on a *path*,
so it must be re-asserted whenever `.index/` is recreated.

**Candidate, unscheduled: exclude `.index/` (and `.trash/`) from sync.** Not correctness
— 48 already made another machine's index harmless — but it retires the carrying costs
48's bullet named: the package hauling other machines' caches, the sweep those want, and
the upload churn of a live SQLite file. Host seam, Darwin-only, and it can **never**
become an invariant, because no other provider is bound by it.

**Two things that still hold if pause ever does start working:**

- **The pause outlives the process.** The header is explicit that sync does *not*
  auto-resume if the app closes or crashes. A crashed GeneaLogic would leave the
  user's archive silently un-synced indefinitely — they believe they have a backup
  and do not. Any adoption **must** include a resume-on-launch sweep. This is the
  same shape as 47's `.index/dirty` sentinel (leave a marker, clean it on next open),
  so the two should share one mechanism rather than inventing a second.
- **Placement: a host-supplied seam, not engine code.** These are Darwin-only
  Foundation APIs, and the core is Foundation-only *and Linux-buildable*. Recommend
  the `MetadataExtractor` pattern (§6.4): the kit declares a small protocol, the Mac
  app supplies the macOS 26 implementation, CLI and Linux supply nothing. Whoever
  holds the archive open owns pause/resume — which composes with 47, since that is
  already whoever holds the lock.

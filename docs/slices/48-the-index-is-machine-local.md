# 48 — the index is machine-local ✅

**Problem.** `.index/` lives inside the package, so a sync provider replicates it
like everything else. Two machines then write the same `index.sqlite`, `lock` and
`dirty`: the provider has to reconcile a live SQLite database it cannot read,
every handoff destroys the receiving machine's warm cache, and conflicted copies
pile up beside it. 60 made the resulting *staleness* detectable; nothing addressed
the collision.

**Layer.** Engine only, and **not a format change** — `.index/` stays a reserved
top-level dir, so both copies of the spec are untouched. `.index/index.sqlite`,
`.index/lock` and `.index/dirty` become `.index/<machine-key>/…`; because 47
resolved all three through `ArchiveLayout`, that is one function. Plus `MachineKey`,
a CLI stderr notice, and the rig.

**The forks, as settled (2026-08-28):**

- **(a) What keys a machine — the boot volume's UUID**, `gethostname()` where it is
  unavailable. The constraint that decides this is not stability but *agreement*:
  the sandboxed app and the unsandboxed `genea` must derive the **same** key, or
  47's `flock(2)` stops excluding and two writers proceed with no arbiter — worse
  than having no lock. That is exactly how Application Support failed as a
  candidate for where `.index/` should live. **Measured before building**: an
  ad-hoc-signed sandboxed bundle and the plain CLI both read `/`'s
  `volumeUUIDString` as the same value, so this derivation does not repeat it. The
  archive's *own* volume was rejected — an archive on a portable drive carried
  between two machines would give both the same key.
- **(b) The key is hashed** — `<derivation>-<16 hex>` over a source-tagged string.
  The value never becomes a path component, which is what removes traversal from
  the override below rather than leaving an allow-list as the only thing in front
  of it; it also keeps a hostname out of a shared archive. **The derivation stays
  in the clear as the prefix** (`vol-`/`host-`/`test-`) because the failure worth
  seeing at a glance is the app resolving one way and the CLI the other.
- **(c) No migration.** A legacy `.index/index.sqlite` is left exactly where it is;
  the machine directory starts empty and the first open rebuilds. The rebuild is
  not a cost the migration would have avoided — an empty directory forces one
  anyway, as a stale `.index/dirty` would have. Deleting the legacy file is a
  one-time manual step for the only archive that has one.
  **What is abandoned with it is the witness, not just the cache** (review
  finding): the first open after upgrading has no settled witness, so it is
  `WitnessState.unknown`, and if that open happens *mid-delivery* the un-arrived
  files report as damage rather than as an arrival. That is
  [60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md)'s deliberate rule
  — no history is not evidence of an arrival — and the same state
  `deliver.sh unsettle` exists to produce; `.unknown` reads as stale, so the next
  open resolves it. Recorded here so it is not rediscovered as a regression:
  the upgrade makes every machine pass through that state exactly once.
- **(d) The sweep is parked.** Another machine's directory is inert bytes (152 KB
  for the real archive, scaling with record count rather than payload size) that no pass
  looks at, and deleting one while that machine is offline costs it a rebuild for
  no gain. A retention policy wants evidence this slice does not have. **The
  evidence to watch for is (d2)'s**: a machine whose key is *unstable* accumulates
  a directory per run rather than holding one, which is a different argument from
  "several machines share an archive" and would justify a sweep on its own.
- **(d2) The fallbacks are announced, and `/etc/machine-id` sits in front of the
  hostname** (both review findings). The residual risk in (a) is not that the
  derivation fails but that it fails *for one process and not the other*: a `vol-`
  key in the CLI and a `host-` key in the app is two lockfiles, and 47's exclusion
  is gone with no symptom until two writes collide. So `MachineKey.derivation` is
  public, the prefix records it on disk, and `genea` says so on stderr whenever it
  lands on the hostname — which on Darwin means the volume UUID was unreadable.
  `/etc/machine-id` was added ahead of the hostname for the same reason the volume
  UUID beats it: it survives a rename. **It does not rescue the container case that
  prompted it, and the measurement says so** — in `swift:6.3` under Apple's
  `container`, `/etc/machine-id` exists but is *empty* and
  `/var/lib/dbus/machine-id` is absent, so a container still lands on a
  fresh-per-run hostname (an empty file reads as absent, so at least it yields no
  garbage key). **Making a missing boot-volume UUID a *hard failure* on Darwin —
  where it should never be nil — was weighed and declined** (recorded here by 50,
  which is the next slice to edit this file): divergence needs `/`'s
  `volumeUUIDString` to read in one process and not another on one machine, which
  was measured working both sandboxed and unsandboxed and confirmed by hand-test on
  the signed app, so a hard failure trades a rare silent degradation for a rare hard
  outage. The realistic divergence risk is a stale `GENEALOGIC_TEST_MACHINE_KEY`
  export — fork (e)'s, and announced. The residue — one abandoned `.index/host-…/` per run — is real but
  currently unreachable: containers here run against throwaway temp archives, never
  a synced one. It becomes reachable when the Phase 4 server runs on Linux against
  a real archive, and it is the strongest argument the parked sweep (d) has. **Still owed: the Mac app has no equivalent notice** — it is the half
  that would be silent in the case that matters, and it wants a surface (the
  Verify panel is the obvious one) rather than a `print`.
- **(e) `GENEALOGIC_TEST_MACHINE_KEY`** — a testing seam, named as one. `deliver.sh`
  stands up two machines as two directories on one real machine, which without it
  derive one key, and the rig drives the real binary so a code-level seam cannot
  reach it. Its danger is not traversal (see (b)) but **silence**: a stale export
  leaves that `genea` on a different lockfile from the app, so the CLI prints a
  note to stderr whenever it is in force. An empty value reads as unset.

**Out of scope.** Cross-machine mutual exclusion — off the table for good, per the
placeholder: `flock` cannot cross kernels, so 50 is optimistic-and-reconcile. Any
sweep (d). Conflict policy (→ 50). And **Phase 4's snapshot server**, whose sketch
still says it serves from "the snapshot's own `.index/index.sqlite`" — a snapshot
now carries whichever machines' directories it was copied with, so that line needs
a decision when Phase 4 is built, not now.

**Verified.** 12 new `MachineLocalIndexTests` — the derivation as a pure function
(`MachineKey.current` is resolved once per process and deliberately cannot be
re-resolved), and on disk the claim that actually matters: another machine's index
directory is inert, untouched by open, mutation and rebuild, and invisible to the
manifest and `verifyIntegrity()`. 779 engine + 146 CLI on macOS, 776 on Linux.
**Two hardcoded paths turned up and were removed** — three tests writing
`.index/dirty` as a literal, and `ArchiveLock` reconstructing the archive root by
climbing two directories up from the lockfile, which quietly began naming `.index/`
as the busy archive. The lock now carries the root instead of deriving it.

**Hand-tested** via `scripts/deliver.sh`, which learned three things it needed: the
other machine runs under its own key, `record` now delivers `.index/` too, and it
**refuses to deliver onto mine's own machine key** — a third rule in the header
beside 60's and 61's. Two real machines cannot share a key, but the rig can
manufacture one, because the header invites you to edit either copy by hand and
only its internal wrapper sets the override; the copy would then land a foreign
index on mine's live database and read exactly like the engine doing it (review
finding, staged and confirmed to fire). And `record` delivers `.index/` because
a provider replicates it like anything in the package, and delivering it is the
only way to show what changed. Stepped end to end: the other machine's whole index
arrived and mine stayed byte-identical, the delivered person became visible, verify
stayed clean, and a local write left the foreign directory untouched. Before this
slice that same delivery landed on the receiver's live database.

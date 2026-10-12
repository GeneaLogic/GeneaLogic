# GeneaLogic — Roadmap

> **Direction only:** where the project is going, in what order, and what each stage
> must achieve. It describes the platform in [ARCHITECTURE.md](ARCHITECTURE.md).
>
> - **Slice specs** live in [`slices/`](slices/), one file per slice. A future slice's
>   spec is written there before it is built; a shipped one stays as the record.
> - **Decisions and gotchas** per slice are in [`SLICE-LOG.md`](SLICE-LOG.md); the
>   invariants are in [`../CLAUDE.md`](../CLAUDE.md).
> - **Status per piece of work** is in [issues](https://github.com/GeneaLogic/GeneaLogic/issues) and
>   [milestones](https://github.com/GeneaLogic/GeneaLogic/milestones). *Now* below says which workstream is current and
>   what it is for.

## How work is tracked

- **Milestones say when; labels say what.** A milestone is a release, named by version:
  `0.1` is the first public build, `0.2`, `0.3`, … are app development, and `1.0` is
  reserved for a format and CLI stability promise. Labels name the layer (`engine`,
  `app`, `cli`, `format`) and the kind (`bug`, `decision`, `feature-request`,
  `enhancement`). `parked` marks a deliberate deferral, and the issue says what un-parks
  it. Issues are not tagged by slice; a slice's PR links the issues it closes.
- **File issues only for concrete work.** Ideas that are not concrete yet stay as bullets
  here, under *Next* or *Parked*.
- **The app version is independent of the archive format version**
  (`genealogic-archive-1.0`). App `1.0` and format `1.0` are different promises.

## Sequencing principle

```
   format spec + model              ← locked first; round-trip tested
        │
   engine (CRUD + index + integrity + sync)
        │
   Mac app: archive → conclusions → matching
        │
   share-readiness (Phase 3.5)      ← now: safe for strangers, public, releasable
        │
   app development, by milestone (0.1, 0.2, … 1.0)
        │
   Vapor publishing (Phase 4)
```

**Lock the archive format and the package contract first**, because they are the most
expensive things to change later and everything else depends on them. The Mac app and
Vapor are both thin front-ends over the package, so neither can get ahead of its
contract. App development comes before Vapor because Vapor has no audience until the
app is worth using.

## How a slice is specified

**Write the whole slice down before building any of it.** A slice ladder entry that
says only "add X" gets designed mid-implementation, which is where scope creep, missed
format questions, and half-answered design forks come from — 43b was reshaped in flight
because the UX question hadn't been settled on paper, and 44i grew a format change once
real data hit it. Both worked out, but only because the fork was put to the user
explicitly rather than decided quietly.

A slice spec is written to **`docs/slices/<n>-<kebab-title>.md`**, linked from its
issue, and agreed before implementation starts. It names:

1. **The problem** — what a user can't do today, in one or two sentences.
2. **The layer** — engine / model / CLI / app, and whether it touches the **format**.
   A format change is its own slice, or at minimum its own explicit sub-decision, and
   it must be settled *first*: it is the most expensive thing to get wrong.
3. **The design forks** — the choices with more than one defensible answer, each with
   a recommendation. **Settle these with the user up front**, not at the point in the
   code where they block progress. (44h's "reuse `PersonFact` or add `RecordedFact`"
   is the model: asked and answered before a line was written.)
4. **What's explicitly out of scope**, and which slice it belongs to instead.
5. **How it will be verified** — which tests, whether it needs Linux verification,
   and what the user should hand-test.

Then implement the whole spec in one pass. Mid-slice questions that the spec already
answers should not be re-litigated; genuinely new ones — a fork the spec missed, or
data that contradicts it — get raised in a sentence and answered before proceeding,
the same rule as §*How work is scoped* in [`../CLAUDE.md`](../CLAUDE.md).

Slice size follows from this: **if the spec can't be written in a screenful, or the
log entry for it won't fit in ~20 lines, it's two slices.**

## Done

| Phase | What it delivered | Record |
| --- | --- | --- |
| 0, 1a, 1b | Format spec and model; the archive engine; the SQLite index and `genea` CLI | [phase-0-1](slices/phase-0-1.md) |
| 2 | The Mac app manages an archive end to end (slices 1–39, UI audit F1–F14) | [phase-2](slices/phase-2.md) |
| 3 | Conclusions, the derived tree (40–44h) and the matcher (45–45p, 46, 46b) | [phase-3](slices/phase-3.md), [matcher](slices/phase-3-matcher.md) |
| 3.5 (1) | Multi-writer and sync: one machine (47, 51, 52), two machines (48–50e, 60–61); language and build debt (53, 54) | [phase-3-5](slices/phase-3-5.md), [48–50](slices/48-50-cross-machine-sync.md) |
| 3.5 (2) | Format stress testing: *it either works or it reports* (55–59, 62–71) | [62–66](slices/62-66-format-stress-testing.md), [exit review](slices/workstream-2-exit-review.md) |

Every shipped slice has its own file in [`slices/`](slices/README.md).

## Now — Phase 3.5: share-readiness

**Goal:** the project is safe to hand to strangers — no data-loss footgun, no personal
data in the repo, and an archive that survives two writers. "Share" means
**open-sourcing the project**, not sharing one archive.

**Exit criterion:** the public repo exists under the GeneaLogic organization with no
family data reachable from any ref; a stranger can build and test it from the README;
and the release pipeline produces a signed, notarized, versioned build.

| # | Workstream | State |
| --- | --- | --- |
| 1 | Multi-writer / sync | ✅ done |
| 2 | Format stress testing | ✅ done (2026-10-09) |
| 3 | Go public — slices 72–76 (with 74b) | ✅ done (2026-10-12) |
| 4 | **Triage** | **now** |
| 5 | Mac-likeness, second pass | |
| 6 | Distribution | |

### Workstream 3 — go public

Worked in this repo on slice branches as usual. The public repo starts from the result.

| Slice | Contents |
| --- | --- |
| [**72**](slices/72-roadmap-is-direction.md) | ROADMAP becomes direction only; shipped specs move to `docs/slices/` |
| [**73**](slices/73-a-stranger-can-build-it-from-the-readme.md) | License, `NOTICE`, trademark policy, README (with a short GeneaLogicKit example and *no API stability promise while `0.x`*), CONTRIBUTING (absorbing `TESTING.md`), housekeeping |
| [**74**](slices/74-the-family-is-fictional.md) | One fictional family; the family-data scrub of code, fixtures, comments and docs onto it, and a guard against it coming back |
| [**74b**](slices/74b-a-stranger-has-something-to-open.md) | One sample archive built from that family: `make-demo-archive.sh`, README screenshots, a first-run sample on the welcome screen |
| [**75**](slices/75-the-app-is-called-genealogic.md) | Identity: `PRODUCT_NAME` `GeneaLogic`; bundle IDs `app.genealogic.GeneaLogic` / `app.genealogic.GeneaLogicTests`; document type `app.genealogic.archive`. Not a format change. Resets the sandbox container (known archives, preferences) once |
| [**76**](slices/76-the-project-is-public.md) | Snapshot into `GeneaLogic/GeneaLogic`; labels and milestones there; the scrubbed open issues re-filed; tracking moves to issues |

**Settled 2026-10-10:**

- **A new repo from a scrubbed snapshot**, not a rewritten history. GitHub keeps old
  commits reachable through closed PRs, so a force-push cannot unpublish them. This repo
  stays private as the full record.
- **Apache-2.0** for the code: permissive, contributions are licensed under it by default
  (§5), and it grants no trademark rights (§6). **The spec is CC-BY-4.0** (settled in 73):
  it is copied into every new archive, and its header carries the attribution. The header
  also says GeneaLogic claims no rights in an archive's contents.
- **Issues are re-filed, not transferred.** GitHub can't move an issue from a private repo
  to a public one. Only the open issues moved, as #1–#13; references to closed ones became
  short inline descriptions in 76.
- **The bundle ID contains a family name**, so 75 is part of the scrub, not separate
  from it.

### Workstream 4 — triage

The open issues, the parked ones, and this ROADMAP's refactors and contributor-docs work,
which are filed as issues first. Every open item ends with a
milestone, or parked with the trigger that un-parks it.

- **GeneaLogicKit can't be a SwiftPM URL dependency** (found in 73). SwiftPM needs the
  manifest at the repository root, and the package is in `GeneaLogicKit/`. A root
  `Package.swift` that points at its sources would fix it. Until then the README says
  to depend on it by local path.
- **A cold build prints ~180 warnings** (found in 73's hand-test). Nearly all come from the
  vendored `sqlite3.c`, which SwiftPM shows for a path dependency and for the package's own
  builds. A wrapper `.c` that silences warnings and includes the amalgamation would quiet
  them without `unsafeFlags`, which a URL dependency refuses. The other one is a deprecated
  `String(cString:)` in `MachineKey.swift`.

### Workstream 5 — Mac-likeness, second pass

Opens with two behavior-preserving splits:

- **`ArchiveModel.swift`** (~4,000 lines; sections in the order slices were built) into
  per-domain files. Separate platform-neutral model logic from macOS-only UI, so an iOS
  target can share it later. The `mutate` and write-queue pattern stays as it is.
- **`ArtifactDetailView.swift`** (~1,900 lines).

Then [#9](https://github.com/GeneaLogic/GeneaLogic/issues/9) (inspector and toolbar layering in macOS 27) and whatever the pass finds.

### Workstream 6 — distribution

**Developer ID, notarization and a DMG, with `genea` inside the app** — one download,
and the app and CLI are always the same version. The Mac App Store stays possible (the
app is already sandboxed), but a sandboxed `genea` cannot open user paths from
Terminal, which breaks the agent-drives-the-CLI case 47 was built for.

- **Versioning.** The version comes from a git tag (`0.1.0`); the build number is the
  commit count on `main`, stamped at build time (it only rises, because merges are
  `--no-ff` on a straight `main`). `genea --version` prints version, build and short
  hash. Today `MARKETING_VERSION = 1.0` and `CURRENT_PROJECT_VERSION = 1` are set by hand.
- **Embedding the CLI** at `GeneaLogic.app/Contents/Helpers/genea`, linked into the PATH
  by an *Install Command Line Tool…* menu item (`/usr/local/bin` needs an admin
  password), or a documented `ln -s`; a Homebrew cask can do it later.
- **Infrastructure:** Apple Developer Program membership, signing secrets in CI,
  notarization, an updater (Sparkle?).
- **Membership is needed before any downloadable build**, not just for the App Store:
  macOS 15+ blocks an un-notarized download without a trip to System Settings. Decide
  individual vs organization enrollment early: as an individual, the developer name
  shown is a person's; showing "GeneaLogic" needs a legal entity and a D-U-N-S number,
  which take weeks.
- **Application Support differs between the sandboxed app and the unsandboxed CLI.**
  That is fine today, because everything they share lives in the package. Future shared
  user-level state (a gazetteer, the name-variant table, a default archive) goes in an
  App Group container.

### Alongside 5 and 6 — contributor docs

Not a gate for going public; filed as issues at triage.

- **DocC catalog**: a Getting Started article, and topic groups that sort `Archive`'s
  public members into core use, integrity, and sync/recovery.
- **Comment convention**: the rule first, then history only if it still explains
  something. Applied to the public API now, and to other files as they are touched.
- **CONTRIBUTING guides**: *adding a record type* (13 files in the archive module plus
  CLI and app for `Dismissal`; the property-test generator in `GeneaLogicTestSupport` is
  the easy one to miss), and *adding a phonetic keyer*.
- **Move reconciliation out of `Archive.open`** (manifest merge, witness, pruning,
  conflicting versions) into its own file, and write ARCHITECTURE's ordered account of
  what happens when an archive opens, with why each step comes where it does.

## Next — app development, by milestone

Opens with **feature planning**: list the features wanted, choose a target milestone for
each (before, at or after `1.0`), and file each as an issue whose slice spec is written
before it is built. It absorbs the former Phase 5 (GEDCOM) and Phase 6's AI enrichment.

**`0.1`'s exit criterion:** *a stranger downloads the DMG, opens or creates an archive,
and `genea` works in Terminal.* Whether GEDCOM import is in `0.1` is decided at feature
planning.

Starting list, with what each depends on:

- **Scale.** GEDCOM import is the first time persons arrive in thousands rather than
  tens. Matcher candidate blocking (45p's floor), the persons list, the tree view and
  rebuild time have not been exercised at that size. A slice before import.
- **GEDCOM import**, then export. A new user's first act is bringing in the tree they
  already have. Imported facts carry provenance marking them imported.
- **`genea --json`.** Agents parse output far more reliably than they read it. It becomes
  a stability surface at `1.0`. Then **an agent skill** for driving `genea` (a
  `SKILL.md` that can live in the repo and ship with the app), which needs the CLI on
  the PATH (workstream 6).
- **AI suggestions from the on-device model** (Foundation Models, available at the
  macOS 26 floor). First use: suggesting artifact properties from what is already known.
  - **Settle the format question first.** `Artifact` carries provenance for the whole
    record, not per field. A suggestion can live outside the record until accepted and
    then be written as an ordinary edit (no format change, but the record forgets a
    machine proposed it), or pending and accepted machine values can be stored per field
    (a format change, its own slice). The provenance rule — human vs machine, review
    status — argues the question is not settled by "no format change" alone.
  - In an Apple-only target behind `#if canImport(FoundationModels)`, never the core.
    The app must work fully without Apple Intelligence. Reuse the review queue
    (`ReviewListView`, `FactSuggestionRow`); record the model and its version in the
    tool identifier.
- **App Intents** (Shortcuts, Siri, Spotlight), after the `ArchiveModel` split. The typed
  ids map onto App Intents entities.
- **The open feature requests** ([#1](https://github.com/GeneaLogic/GeneaLogic/issues/1), [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2), [#5](https://github.com/GeneaLogic/GeneaLogic/issues/5), [#6](https://github.com/GeneaLogic/GeneaLogic/issues/6), [#7](https://github.com/GeneaLogic/GeneaLogic/issues/7)), sized at triage.

## Later

### Phase 4 — Vapor publishing target

**Goal:** publish a snapshot of an archive to the Web, read-mostly.

- Mac-side publish pipeline: **redaction first** (filter living/private records so
  they never leave the device), produce a published bundle, upload.
- Vapor server (reusing GeneaLogicKit on Linux): ingest snapshot, serve from its
  index read-only; rebuild the index if missing.
- Web surface: browse artifacts, view a person with the evidence behind each fact,
  public tree view.

**Exit criteria:** publish a redacted archive from the Mac app and browse it on the
web with no living-person data present.

### Federation and the cross-platform extractor (the rest of former Phase 6)

- **Federation**: OAI-PMH harvesting, IIIF image pulls, a candidate/staging layer for
  unconfirmed external matches; eventually an OAI-PMH provider endpoint and
  URI-resolvable person identifiers.
- **Cross-platform extractor**: a Linux-capable `MetadataExtractor` in
  `GeneaLogicExtract`, only if a non-Apple consumer ever needs to ingest raw files. No
  change to the core API.

### Other platforms

An iOS app once the Mac app is successful — a new target or its own project. Web/WASM,
Android and Windows are possible later; none is near-term. What keeps them possible is
the core contract (Foundation-only, Linux-tested) and a platform-neutral model layer
(workstream 5). Known obstacle: the engine's cross-process lock is POSIX `flock`, which
Windows does not have.

## Parked

Each with what un-parks it.

- **Gazetteer-backed place matcher** — Phase 4 or later; the fork is where the data comes
  from ([matcher phase](slices/phase-3-matcher.md)). 45o took the concrete pain out.
- **User-curated name-variant table** (`MatchKind.knownVariant` already exists) — a
  matcher accuracy upgrade; probably the bigger win than more phonetic keyers.
- **Ngram blocking below 45p's floor** — parked with data; the scale slice may un-park it.
- **Phonetic keyer protocol** — one implementation today, so not built speculatively.
  Filed as a `good first issue` with the design: internal (matcher output is provenance),
  keyed by ISO 15924 script, `Matcher.toolIdentifier` bumped when a keyer is added.
- **USB/network scanner ingest** (`ImageCaptureCore`) — only if wanted.
- **A persisted, cross-relaunch undo journal** — only if wanted; the trash is a narrow
  recovery carve-out, not a general journal.
- **[#10](https://github.com/GeneaLogic/GeneaLogic/issues/10), [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11)** (Replace File loses the prior master after quit; deleted conclusions have
  no cross-session trash) — trash-backed answers that widen `TrashEntry.kind`, a format
  change beside [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2).
- **[#12](https://github.com/GeneaLogic/GeneaLogic/issues/12)** (re-run and backup contract for migration steps) — lands with the first real
  migration step. Until then it is the one deferral that can break workstream 2's exit
  criterion.
- **[#13](https://github.com/GeneaLogic/GeneaLogic/issues/13)** (the size sweep calls a newer record a size mismatch) — until format 1.1
  exists; no archive can reach it before then.

## Cross-cutting, from day one

- **CI on macOS + Linux** (`.github/workflows/ci.yml`): every push and PR to `main`
  builds and tests both packages on a macOS runner and in the `swift:6.3` Linux
  container, plus a `macos-26` job that tests the Mac app. `scripts/linux-test.sh` is the
  local equivalent.
- **Round-trip and migration tests** travel with the format forever.
- **Provenance and review status** on every write.
- **The schema spec is versioned and ships inside each archive**, kept honest by
  `SchemaSpecTests`: its two checked-in copies must stay byte-identical, and every
  persisted record field must be documented in its own spec section.

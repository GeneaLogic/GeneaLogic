# GeneaLogic — working notes for Claude

GeneaLogic is a document-first genealogy DAM. This file is **only** the short list of
invariants and working rules that are easy to violate by accident. Everything else —
design, plan, history — lives in `docs/` and is read on demand.

## Where things are written down

| Question | Read |
| --- | --- |
| How is this designed, and why? | [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) |
| Where is this going, and what's next? | [`docs/ROADMAP.md`](docs/ROADMAP.md) — **direction only**: phases, exit criteria, the order of work, and how a slice is specified |
| What's the status of a piece of work? | [Issues](https://github.com/GeneaLogic/GeneaLogic/issues) and [milestones](https://github.com/GeneaLogic/GeneaLogic/milestones) |
| What did slice N specify? | `docs/slices/<n>-*.md` — one file per slice, written **before** it is built ([index](docs/slices/README.md)) |
| What did slice N decide, and what bit us? | [`docs/SLICE-LOG.md`](docs/SLICE-LOG.md) |
| What does the on-disk format say? | `GeneaLogicKit/schema/genealogic-archive-1.0.md` — **and its byte-identical copy** in `GeneaLogicKit/Sources/GeneaLogicArchive/Resources/` (`SchemaSpecTests` enforces both) |
| What UI debt was triaged? | [`docs/UI-AUDIT.md`](docs/UI-AUDIT.md) (F1–F14, all worked) |

**Read ARCHITECTURE and ROADMAP before making design decisions.** Don't restate status
here — a second copy of "where we are" only ever goes stale.

## Project shape

Monorepo of three components as flat top-level folders (apps reference the package
by local path):

```
GeneaLogicKit/      cross-platform Swift package (the engine) — Package.swift here. No UI, no networking.
GeneaLogicCLI/      headless `genea` CLI (separate package over the engine).
GeneaLogicApp/      SwiftUI Mac app — an Xcode project over the engine.
GeneaLogicServer/   Vapor publishing target (later).
docs/               platform-wide design docs (ARCHITECTURE, ROADMAP, SLICE-LOG, slices/)
```

The package lives in `GeneaLogicKit/`, **not** at the repo root.

## How to build and test each component

```bash
# Engine and CLI (SwiftPM). Note the --package-path: neither is at the repo root.
swift test --package-path GeneaLogicKit
swift test --package-path GeneaLogicCLI

# The cross-platform contract. Apple's `container`, not Docker; same suites on Linux.
scripts/linux-test.sh                       # engine
scripts/linux-test.sh test GeneaLogicCLI    # CLI

# The Mac app (Xcode project, macOS only). `test` also builds; `build` alone
# skips GeneaLogicAppTests. Swap `test` → `build` only for a pure compile check.
xcodebuild -project GeneaLogicApp/GeneaLogicApp.xcodeproj -scheme GeneaLogicApp \
  -derivedDataPath ~/Library/Developer/GeneaLogicApp-DD -destination 'platform=macOS' test
```

**Always pass `-derivedDataPath ~/Library/Developer/GeneaLogicApp-DD` — every time,
including a throwaway compile check.** A bare `xcodebuild` lands in Xcode's default
DerivedData and creates a *second* `.app` with the same bundle id
(`app.genealogic.GeneaLogic`). The two then fight over which is the registered `.genea`
handler, so `open some.genea` can launch a stale build or a second process while you
believe you are testing the fresh one (cost a debugging detour in 43c). If the app
behaves as though your change isn't there, check `ps aux | grep /Contents/MacOS/GeneaLogic` for
more than one distinct path, kill them, `rm -rf ~/Library/Developer/Xcode/DerivedData/GeneaLogicApp-*`,
and rebuild to `-DD`. To *run* the app rather than test it, use the `run-genealogic-app`
skill, which wraps this.

## Non-negotiables (the contract)

- **Core is Foundation-only.** No `AppKit`, `UIKit`, `SwiftUI`, or `Combine` in
  `GeneaLogicModel`/engine modules — they must compile on **Linux** (for Vapor).
  UI frameworks belong in the Mac app only. The one Apple-API target in the
  package is `GeneaLogicExtract` (ImageIO metadata extractor), kept Linux-buildable
  by isolating its platform code behind `#if canImport(ImageIO)`; the core does
  not depend on it. A PostToolUse hook warns if a banned framework leaks into a
  Linux-tested package; CI's Linux job is the hard gate.
- **The floor is macOS 26 / iOS 26 (both packages) and Swift 6.3 (the Linux CI
  image, matching the Mac toolchain since slice 54).** So **don't hand-roll around
  an availability limit without checking the
  floor** — anything gated on macOS 15 or earlier is simply available, and
  `Synchronization.Mutex` in particular is the right way to guard shared mutable
  state (it makes a `Sendable` conformance *checked* instead of `@unchecked`).
  This has now been got wrong more than once, in the same direction each time:
  inventing a lower floor from something in the environment rather than reading
  `Package.swift`. **The test runner's banner is not the floor** — it prints
  `arm64e-apple-macos14.0`, which is swift-testing's own platform, not this
  project's. The real constraint is the *other* direction: an API newer than
  Swift 6.3's Linux runtime breaks the cross-platform contract, so that is the
  thing worth checking, and `scripts/linux-test.sh` is how.
- **Checksums via `swift-crypto`, never `CryptoKit`** (CryptoKit is Apple-only).
- **No dependency on Vapor** anywhere in the package. The server depends on the
  package, never the reverse.
- **`uid` is a type-prefixed UUIDv7** (e.g. `ART-…`, `PER-…`). Minted once at
  creation, never copied. Folder/file names are non-authoritative friendly slugs.
  Modeled as distinct typed wrappers (`ArtifactID`, `PersonID`, …) that serialize
  as plain JSON strings — don't pass bare `String`s where an id type is expected.
- **JSON keys are plain camelCase** (semantic DC/GEDCOM-X alignment, no `dc:`/`gen:`
  prefixes). **Open vocabularies** (source tier, **source derivation**, media type,
  name type, **person role**, relationship type, external-id scheme, fact type,
  **match granularity**) are unknown-preserving enums (`.unknown(String)` round-trips
  verbatim); **closed vocabularies** (information quality, `createdBy`, file role,
  match kind, the two review-status sets) are strict. **The test is domain, not
  convenience.** See spec §7. *Person role was closed until slice 44h; a record
  carrying an unlisted role failed to **load**, which is the failure the open rule
  exists to prevent. Match kind lost `county`/`country` in 45h for the opposite
  reason — an administrative hierarchy is the world's domain, not GeneaLogic's, so
  they were misfiled rather than a closed list needing to grow.*
- **File `path` is package-assigned and collision-free**; the user's name is kept
  in `originalName`. Uniqueness is checked under case-fold + Unicode NFC. Only
  `record.json` (and root `manifest.json`) are reserved by convention; `.index/`,
  `.trash/` and `.damaged/` are reserved **top-level** dirs — all non-authoritative and
  outside the manifest/index/integrity passes. (See §4.2.1 and spec §2.)
- **Two sources of truth, separated:** evidence (sidecars) vs. conclusions
  (`conclusions/`). The tree is a *derived view*, never stored/edited directly.
- **The SQLite index is a rebuildable cache** — never authoritative. All lookups go
  through it (§5.1); mutations are addressed by `uid`.
- **Every record type gets a round-trip test** (encode → decode → assert-equal)
  before it is considered done. Format changes are the most expensive mistake.
- **Provenance on every assertion** (human vs. machine, review status), even
  pre-AI.
- JSON metadata keys align with **Dublin Core / GEDCOM X** vocabularies. **Event/fact
  dates are EDTF** (ISO 8601-2 / LoC — a superset of ISO 8601 that also expresses
  approximate/uncertain/ranged dates; parsed via `EDTFDate`, never stored structured);
  machine timestamps stay full ISO 8601.

## Conventions

- Model types are `struct`, `Codable`, `Sendable`, value semantics.
- Run `swift build` / `swift test` to verify; `swift format` keeps style (a hook
  formats Swift files on edit automatically).
- Commit messages: imperative, scoped. Don't push `main` or merge without being asked.
- **A slice is branched, not committed on `main`**: `slice-<n>-<kebab-title>`.
  Commit the work there as it lands — that commit is the reviewable restore point,
  and review/hand-test fixes go on top as their own commits. At hand-off, push it
  and open a PR whose body says `Closes #N` for each issue it settles; CI runs there.
  On the user's go-ahead, merge with a merge commit titled `Merge slice <n>: <title>`,
  and delete the branch.
- **The user hand-tests before the merge.** Tests, Linux and `/code-review` are the
  pre-check, not the gate — hand off and stop. The engine half of a hand-test is
  `genea` at the command line and Claude can run it; the app half needs the window
  and is the user's.
- **The rigs are in `scripts/`**: `deliver.sh` (two machines, one archive, a
  delivery you step — the sync slices), `make-demo-archive.sh` (the sample archive, a throwaway to
  hand-test against), `render-sample-pages.swift` (the sample's page images; macOS), `linux-test.sh`, `update-sqlite.sh`, `kill-test.sh` (`kill -9` a `genea` mid-write, then
  check every open — slice 65's out-of-process half), `stage-50c-handtest.sh` (the four
  conflicted-copy shapes 50c's app hand-test starts from), `scrub-check.sh` (no real
  family name in the tree; the denylist is private, outside the repo),
  `inspector-edge-repro/` (the SwiftUI bug behind slice 80's inspector workaround; its
  README says when the workaround can go).

## How work is scoped

- **A slice's scope is what its spec in `docs/slices/` says it is.** Make routine judgment calls
  yourself; if the work reveals something the slice should arguably include —
  **especially a format or schema change** — say so in a sentence and get the call
  before building it, rather than quietly widening the slice. Finish the whole
  slice; stop at its edge. (See ROADMAP § *How a slice is specified* — the spec is
  agreed **before** implementation starts, not discovered during it.)
- **`/code-review` is the user's to run, not Claude's.** It is
  `disable-model-invocation`: Claude cannot invoke it, allow-listing `Skill(code-review)`
  does not change that (the flag sits upstream of permissions), and the workflow must not
  be reimplemented by hand instead. **Claude's job is to say when it's worth running** —
  typically once a slice is built and green, in the same breath as handing off for the
  hand-test — and then stop.
- **When the user does run it:** it runs inline at the current effort level. Spawn
  subagents only when asked, and never to double-check work that is already covered by
  tests. Ask a review for **everything it finds** and filter afterward — telling a
  reviewer to be conservative or high-severity-only just makes it report less.
- **Verification is the test suite, CI, and the user's hand-test** — not extra
  self-checking passes. `swift test` on both platforms, `SchemaSpecTests` for spec
  drift, then hand off (see *Conventions* for where that sits in the branch/merge
  loop).

## How the docs are written

- **SLICE-LOG entries are records, not retellings**: the decision, the invariant it
  establishes, the gotcha that cost a round. Under ~20 lines. The diff already shows
  the code; don't narrate it back.
- **Status lives in one place**: issues and milestones. Don't add a second "where we
  are" to this file, to SLICE-LOG, or to a slice spec.
- **A format change means editing the spec in both copies**, in the same slice —
  `SchemaSpecTests` is the tripwire, but nested inline-documented types are by-hand
  discipline.
- Match a document's length to what it needs to say; no filler sections, redundant
  summaries, or boilerplate.

<tone_preference>
Keep prose — chat replies, doc entries, commit messages — reasonably concise.
Lead with the outcome, put supporting detail after it.
</tone_preference>

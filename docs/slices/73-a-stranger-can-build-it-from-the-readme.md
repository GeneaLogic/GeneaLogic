# 73 — A stranger can build it from the README

**Problem.** The repo has no `LICENSE`, `README` or `CONTRIBUTING`, so the code is legally
all-rights-reserved and a newcomer has no front door. `TESTING.md` is a per-slice checklist
that stopped at slice 42.

**Layer.** Docs and repo files. No code or format change. The spec gains a license line in
its header, in both copies; archives created afterwards carry the new bytes, and existing
archives keep theirs under their own manifest checksum, so nothing reads a difference.

**Settled** (ROADMAP, 2026-10-10): Apache-2.0 for the code; a new public repo is created
from a scrubbed snapshot (76).

**Forks** (all four settled 2026-10-10 as recommended):

- **(a) The spec's license.** **CC-BY-4.0** *(recommended)*: the attribution is in the
  spec's own header, so every archive created from now on carries it, and a modified spec must
  say it was changed. CC0 also works and is simpler, but gives up both of those.
  **The header also says what it does *not* cover:** the license applies to the spec
  only. An archive's records and files belong to whoever made them, and GeneaLogic claims
  no rights in them. The spec copy is the only GeneaLogic-authored file in an archive, so
  that is where the sentence travels. README's license section repeats it.
- **(b) Who holds the copyright and the trademark.** **Copyright: "The GeneaLogic
  Authors"** *(recommended)*, the Go/Chromium convention: contributors keep their own
  copyright, and the line never changes. **Trademark:** an unregistered mark needs a named
  owner, so it is the maintainer's.
- **(c) `TESTING.md`'s per-slice checklists (slices 1–42).** **Drop them** *(recommended)*.
  Each slice spec now carries its own hand-test, and this repo stays as the record.
  CONTRIBUTING keeps the durable parts: build and run, a test archive, hand-testing, and
  reporting a bug.
- **(d) Community files.** **`SECURITY.md` now** *(recommended)*: one paragraph, pointing
  at GitHub's private vulnerability reporting. A code of conduct waits until there is a
  community to apply it to. It commits the project to enforcing it, and it needs a contact.

**Decided without a fork** (routine; say if you disagree):

- **Contributions**: Apache-2.0 §5 (inbound = outbound). No CLA, no DCO sign-off.
- **No per-file license headers.** The root `LICENSE` covers the tree; a header on every
  Swift file adds churn and nothing else.
- **README's GeneaLogicKit example is mirrored by a test** (`ReadmeExampleTests`, engine,
  runs on Linux too), so the example can't stop compiling unnoticed. A second test reads
  the README and checks that its code block matches the body the first test runs,
  ignoring whitespace and the two paths.

## What ships

- **`LICENSE`**: the Apache-2.0 text, verbatim.
- **`NOTICE`**: the copyright line (b), the spec's license (a), and the third-party
  components: swift-crypto and swift-argument-parser (Apache-2.0), SQLite (public domain,
  vendored).
- **`TRADEMARKS.md`**: the GeneaLogic name belongs to its owner (b).
  - **Allowed:** referring to the project truthfully; redistributing an *unmodified*
    build; describing other software as reading or writing GeneaLogic archives.
    `genealogic-archive-1.0` is a technical identifier, and any conforming implementation
    may declare it.
  - **Not allowed:** a modified build under the name or icon, a confusingly similar name,
    or implying endorsement. A fork renames, and changes the bundle ID.
- **The spec's header**: the license line (a), in both copies.
- **`README.md`**: what GeneaLogic is (document-first: evidence vs. conclusions); status
  (pre-`0.1`, nothing released, **no API stability promise while `0.x`**, format 1.0); the
  four components; requirements (Swift 6.3; the app needs macOS 26.5 and Xcode 26.5; the engine and CLI also
  build on Linux); build and test; a few lines of `genea`; a short GeneaLogicKit example
  (create an archive, add an artifact, find it); a map of `docs/`; license and trademark
  pointers. Screenshots come in 74.
- **`CONTRIBUTING.md`**: build and test for each component (including Linux via
  `container`, and the `-derivedDataPath` rule); the invariants worth knowing before a PR
  (pointing at CLAUDE.md rather than copying it); how a change is specified (a slice spec
  first, for anything beyond a fix); hand-testing the app; reporting a bug; the
  contribution terms. It explains that `CLAUDE.md` and `.claude/` are the project's
  working notes for Claude Code, and they stay in the repo.
- **`SECURITY.md`** (d).
- **Housekeeping:**
  - `TESTING.md` is removed (c).
  - `spike/FINDINGS.md` moves to `docs/spikes/sqlite-driver.md`, and its citations are
    updated.
  - `scripts/stage-50c-handtest.sh` stays (a first draft removed it), and CLAUDE.md lists
    it with the other rigs: it is the only exact recipe for 50c's four conflicted-copy shapes.
  - `.claude/worktrees/` goes into `.gitignore` (it is only in this clone's
    `.git/info/exclude` today).
  - A feature-request issue template is added beside the bug template.
  - `NSHumanReadableCopyright` is set to the copyright line (b).

**Out of scope.**

- Screenshots and the sample data set (74).
- Family data in anything this slice *doesn't* write (74). Everything it does write uses
  no real names.
- The bundle ID and document type (75).
- GitHub-side settings (enabling private vulnerability reporting, labels) and rewriting
  the private repo's issue links (76).
- Contributor guides and DocC (workstream 4 triage).

**Verification.** `swift test` for the engine and CLI on macOS and Linux
(`ReadmeExampleTests`, and `SchemaSpecTests` for the spec header). `xcodebuild test` for
the app (the copyright key). A script checks that every relative link in `docs/` and in the
new root files resolves. **Hand-test:** clone this repo to a temp directory, follow the
README cold to build and test the engine, and read `LICENSE`, `NOTICE`, `TRADEMARKS.md` and
CONTRIBUTING as a stranger would.

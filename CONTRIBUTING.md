# Contributing

GeneaLogic is early (pre-`0.1`), and contributions are welcome. **For anything bigger than
a fix, open an issue first.** Most of the work is agreeing on the design before any code
is written (see [How a change is made](#how-a-change-is-made)), and an issue is where that
happens.

## Build and test

```bash
swift test --package-path GeneaLogicKit          # the engine
swift test --package-path GeneaLogicCLI          # the CLI
scripts/linux-test.sh                            # the engine on Linux
scripts/linux-test.sh test GeneaLogicCLI         # the CLI on Linux
```

```bash
xcodebuild -project GeneaLogicApp/GeneaLogicApp.xcodeproj -scheme GeneaLogicApp \
  -derivedDataPath ~/Library/Developer/GeneaLogicApp-DD -destination 'platform=macOS' test
```

- **The engine and CLI must build and pass on Linux.** That is the contract the future
  Vapor server depends on. `scripts/linux-test.sh` runs the same suites in the official
  `swift:6.3` image using Apple's [`container`](https://github.com/apple/container) (not
  Docker). CI runs macOS, Linux and the app on every push to `main` and every pull request
  against it.
- **Always pass the same `-derivedDataPath` to `xcodebuild`**, even for a quick compile
  check. A build left in Xcode's default DerivedData is a second app with the same bundle
  ID. The two then compete to handle `.genea` files, so `open some.genea` can launch a
  stale build. If the app acts as though your change isn't there, look for more than one
  copy (`ps aux | grep /Contents/MacOS/GeneaLogic`). Then quit them, delete
  `~/Library/Developer/Xcode/DerivedData/GeneaLogicApp-*`, and rebuild.
- **Don't build the app into `/tmp`.** LaunchServices won't use an app in a temporary
  directory as a document handler, so opening a `.genea` from Finder silently fails.
- **Formatting** is `swift format` with the repo's [`.swift-format`](.swift-format):
  `swift format --in-place <files>`.

## Rules worth knowing before you write code

These are the invariants that are easy to break by accident. [`CLAUDE.md`](CLAUDE.md)
has the full list with the reasons, and [ARCHITECTURE](docs/ARCHITECTURE.md) has the
design behind them.

- **The engine is Foundation-only.** No AppKit, UIKit, SwiftUI, Combine or CryptoKit in
  `GeneaLogicKit` or `GeneaLogicCLI`, because they must compile on Linux. Use
  swift-crypto for checksums. The one exception is `GeneaLogicExtract`, which wraps
  ImageIO behind `#if canImport(ImageIO)` so it builds as an empty module on Linux;
  nothing in the core depends on it.
- **The files are the truth, and the SQLite index is a cache** that can always be rebuilt
  from them. Lookups go through the index, and changes are addressed by `uid`.
- **Evidence and conclusions stay separate.** What a document says is stored in its
  sidecar. What you infer (persons, links, relationships) is stored under `conclusions/`.
  The tree is computed from both and never stored.
- **Ids are typed** (`ArtifactID`, `PersonID`, …): type-prefixed UUIDv7s, minted once.
  Don't pass a bare `String` where an id is expected.
- **Every record type has a round-trip test**, and every assertion carries provenance
  (whether a person or a machine made it, and its review status).
- **A format change edits the spec in both of its copies**, in the same change.
  `SchemaSpecTests` fails if they differ, or if a persisted field is undocumented.
  Changing the format is the most expensive mistake this project can make, so it gets
  its own decision up front.

## How a change is made

- **A bug fix**: an issue, then a pull request with a test that fails without the fix.
- **Anything larger is a *slice*.** Its spec is written as
  `docs/slices/<n>-<kebab-title>.md` and agreed in the issue *before* it is built. The
  spec covers the problem, the layer, the design choices with a recommendation for each,
  what is out of scope, and how the change will be verified. The format is in the
  [roadmap](docs/ROADMAP.md#how-a-slice-is-specified), and
  [`docs/slices/`](docs/slices/README.md) has every past one as an example. After the
  slice is built, a short entry in [`SLICE-LOG.md`](docs/SLICE-LOG.md) records what it
  decided and what caught us out.
- **Commit messages** are imperative and scoped, for example `Slice 70: a newer record
  is refused before its manifest` or `fix: an unread file must not leave a complete
  report (slice 57b, review)`.

## Hand-testing the app

The tests cover the engine and check that the app builds. They do **not** check how the
app behaves: UI wiring, file dialogs, drag and drop, and layout all pass a green build
when they're broken. So any change to the app gets tried by hand, and each slice spec says
what to try.

`scripts/make-demo-archive.sh` builds the sample archive (the one the welcome screen
offers) at `/tmp/GeneaLogic-Demo.genea`, so every hand-test starts from the same state.
Some things only appear when a file is added *through the app*, such as suggestions from a
photo's embedded metadata. The sample's page images are rendered by
`scripts/render-sample-pages.swift`; edit the records in `SampleArchive.swift` to match
when a page changes.

## Reporting a bug

Open an issue: the bug template asks for what is useful. A good report says **what you
did, what you expected, and what happened**, which build you were on (a commit hash or
"current `main`"), and includes a screenshot if the bug is visual. For a crash, attach the
relevant frames from `~/Library/Logs/DiagnosticReports`. Report security problems
privately (see [SECURITY.md](SECURITY.md)).

**Please don't attach a real family archive.** Reproduce the bug on a demo archive if
you can, and remove names and dates you don't want to make public.

## Claude Code

Much of this project is written with [Claude Code](https://claude.com/claude-code).
[`CLAUDE.md`](CLAUDE.md) and [`.claude/`](.claude) are its working notes: the invariants
above, a hook that formats Swift files on edit and warns if Linux-tested code imports an
Apple-only framework, and a skill for running the app. They stay in the repo, and they're
a concise read for people too. However a change was written, the person who submits it is
responsible for it.

## Contribution terms

Contributions are made under the [Apache License 2.0](LICENSE), as its §5 provides:
whatever you submit is licensed on the same terms as the project. There is no CLA and no
sign-off line. You keep the copyright in your work. "The GeneaLogic Authors" in
[NOTICE](NOTICE) means everyone who has contributed, as recorded in the git history.

# 75 — The app is called GeneaLogic

**Problem.** The app's identity still carries the scaffold's choices. The bundle IDs and the
document type are under a reverse-DNS prefix that is a family name, so they are part of 74's
scrub (they are its only remaining text hits). The product is named after the target,
so the menu bar, Dock and Finder say *GeneaLogicApp*.

**Layer.** App only: the Xcode project, `Info.plist`, `UTType+Genea.swift`, and the
docs that name the built `.app`. **No format change**: no archive records its type
identifier, and `.genea` is still the extension. Engine and CLI untouched.

**The new identity** (settled in the ROADMAP): `PRODUCT_NAME` `GeneaLogic`; bundle IDs
`app.genealogic.GeneaLogic` and `app.genealogic.GeneaLogicTests`; document type
`app.genealogic.archive`.

**Forks:**

- **(a) How far the rename goes.** **Only what a user sees** *(recommended)*: the app
  target's `PRODUCT_NAME` becomes `GeneaLogic`, so the bundle is `GeneaLogic.app` with
  executable `GeneaLogic`. The folder, project, target and scheme stay `GeneaLogicApp`,
  the component's name beside `GeneaLogicKit` and `GeneaLogicCLI`, and so do the test
  target and `GeneaLogicApp-DD`. `PRODUCT_MODULE_NAME` is pinned to `GeneaLogicApp`,
  so `@testable import GeneaLogicApp` keeps working. A full rename (folder `GeneaLogic/`,
  scheme `GeneaLogic`) would change every build command in CI, README, CONTRIBUTING and
  CLAUDE.md for no visible gain.
- **(b) The old container.** **No migration** *(recommended)*. The new bundle ID gets a
  new, empty sandbox container: Recent, window state and the 74b sample are gone once.
  Migration can't work: the new app's sandbox can't read the old container, and
  app-scoped bookmarks resolve only for the app that made them. Archives are untouched,
  and re-opening one restores it to Recent. Deleting the old containers
  (named by the old bundle IDs) is left to the user.
- **(c) The old document type.** **Dropped, not imported** *(recommended)*. Declaring the old
  identifier as an imported type would keep the name in the tree.
  Nothing needs it, because Launch Services types a `.genea` by its extension.

**Decided without a fork** (say if you disagree):

- **`TEST_HOST`** points at `GeneaLogic.app/…/GeneaLogic`, and the scheme's
  `BuildableName` becomes `GeneaLogic.app`.
- **An app test pins the type**: `UTType.geneaArchive.identifier` is
  `app.genealogic.archive`, and `UTType(filenameExtension: "genea")` resolves to it. That
  catches `Info.plist` and Swift drifting apart. The stale doc comment on `geneaArchive`
  is updated.
- **The docs that name the `.app`** (CLAUDE.md, CONTRIBUTING, README, the
  `run-genealogic-app` skill) say `GeneaLogic.app` and the new bundle ID. Slice 48–50's
  spec names the old container path. That one line becomes `<bundle-id>`, so
  `scrub-check.sh` is clean before 76.
- **The stale `GeneaLogicApp.app` is removed from `-DD` once.** The rename leaves the
  old build next to the new one, still registered for `.genea` with the old type. That
  is the two-app fight CLAUDE.md warns about. The skill gains the cleanup step
  (`lsregister -u`, then delete).

**Out of scope.**

- The version and build number (workstream 6), signing team, and App Group (later).
- Renaming the folder, project, scheme or module (fork a).
- Deleting the old containers or other leftover builds under the old prefix.

**Verification.** The app test suite on the `-DD` build, including the new type test.
The built `Info.plist` checked with `plutil`: `CFBundleIdentifier`, `CFBundleName`
`GeneaLogic`, and the exported type. Launch Services types a `.genea` as `app.genealogic.archive`
(Spotlight caches the old type until `mds` restarts, which is not the slice’s to fix). `scrub-check.sh` reports no text hits. No Linux run,
since nothing in either package changes. **Hand-test:** the menu bar and Dock say
*GeneaLogic*, and *About GeneaLogic* shows the icon. The welcome screen starts with an
empty Recent. Open an archive and relaunch: it comes back. Double-click a `.genea` in
Finder: the new build opens it, and Get Info says *GeneaLogic Archive*. The sample
button builds a fresh sample.

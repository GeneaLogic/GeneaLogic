# 81 — small ones

Specced 2026-11-02 from the [second UI audit](workstream-5-ui-audit.md):
[#37](https://github.com/GeneaLogic/GeneaLogic/issues/37).

**Problem.** Six things that a Mac user notices and none of which needs a design:

- **G3.** View has no Show/Hide Sidebar (⌃⌘S). The app never adds `SidebarCommands`.
- **G9.** A new archive window opens at 900×450, which is shorter than the Verify Integrity
  and Trash sheets. `WindowGroup(for: URL.self)` sets no default size, and the archive view
  sets no minimum.
- **G17.** The About window shows only the name, version and copyright. It has no line
  saying what the app is, no licence and no credits.
- **G21.** ⌘-clicking the window title shows the archive as `Name.genea`. The title strips
  the extension itself (`ArchiveContainerView`), but the path menu uses the file system's
  display name, and the app never sets the hidden-extension flag on an archive it creates.
- **G22.** Seven call sites use soft-deprecated forms. `overlay(_:alignment:)` is at
  `TranscriptEditorSheet:43`, `PersonPicker:55`, `TreeContentView:251,256` and
  `ArtifactDocumentPane:167` (the audit missed this one). `background(_:alignment:)` is at
  `TreeContentView:248`, and `ScrollView(_:showsIndicators:)` at `ArtifactDocumentPane:96`.
- **G8, its `0.1` part.** Help ▸ GeneaLogic Help is the system's default item. There is no
  help book behind it, so it opens nothing useful.

**Layer.** App only. No format change and no engine change.

## Design forks (recommendations)

1. **Window size (G9). Agreed, to be tuned in the hand-test:** `.defaultSize(width: 1100, height: 720)` on the
   archive `WindowGroup`, and `.frame(minWidth: 800, minHeight: 520)` on
   `ArchiveContainerView`. 800 is the narrowest window that holds the sidebar's 220, the
   inspector's 280 and a usable detail column. The height is the content sheets' ideal
   460 plus the toolbar. The welcome window is in the same group, so it opens at the same
   default too. A welcome window that turns into an archive in place grows to the minimum.
   *Alternative:* `defaultWindowPlacement`, sizing each window from its root view's ideal
   size, so the welcome window stays compact. That is rejected for 81, because whether the
   welcome window is a window of its own is G24, in slice 85's lifecycle decision.
2. **About (G17). Agreed:** a `Credits.rtf` in the app's resources. The standard
   About panel shows it with no code. It sets no text colour, so the panel's own colour is
   used and it reads in dark mode (HTML credits import as black). Its content: one line
   on what GeneaLogic is; the Apache 2.0 licence, linked; the archive format spec under
   CC BY 4.0; a link to the project page; and the third-party code the app links: SQLite,
   SwiftCrypto and Swift ASN.1. Argument Parser is CLI-only and BoringSSL is Linux-only,
   so neither is listed. *Alternative:* replace `.appInfo` and build the credits in code.
   That gives more control, which this doesn't need.
3. **Hidden extension (G21). Agreed: hidden unless the user asks to see it**, as
   `NSDocument` apps do. The save panel works with the type rather than a typed name: it
   sets `allowedContentTypes = [.geneaArchive]` and the name `Untitled`. Modern panels
   (Pages, TextEdit) show no Hide Extension checkbox. `isExtensionHidden` starts out true
   (measured) and turns false only if the user types `.genea` into the name. After
   `Archive.create`, a shared helper sets `hasHiddenExtension` to what the panel says. File ▸ New Archive… and the welcome
   screen's New Archive… both use it, which also merges their two copies of
   create-and-acquire. The sample archive is created with the extension hidden, because
   no panel was shown for it. **Existing archives are not touched:** the flag belongs to
   the user's file, and Finder's Get Info changes it. Archives that `genea create` makes
   keep their extension, as any file made in Terminal does.
4. **Help (G8). Agreed:** replace the `.help` group with two items.
   **GeneaLogic on GitHub** opens `github.com/GeneaLogic/GeneaLogic`, where the README is
   today's guide. **Report an Issue…** opens `…/issues/new/choose`, which offers the bug
   and feature templates. The menu's search field is the system's and stays. The item
   isn't called "GeneaLogic Help", because that name promises a guide, which is
   [#50](https://github.com/GeneaLogic/GeneaLogic/issues/50).

No fork for G3: add `SidebarCommands()`. On Tree, which has no split view, the item is
disabled by the responder chain, as the sidebar button is. G22 is a mechanical swap,
except one (below).

## Out of scope

- The version in About (`1.0 (1)`, set by hand): workstream 6 stamps it.
- Shipping `LICENSE` and `NOTICE` inside the app bundle: workstream 6, with the DMG.
- The user guide: [#50](https://github.com/GeneaLogic/GeneaLogic/issues/50), for `1.0`.
- A compact welcome window, or one that stays reachable: G24, in slice 85.

## Verified by

- `GeneaLogicAppTests`. The create helper is tested on a temporary archive: hidden when
  asked, shown when not. The sample launcher's test also checks the flag.
- `xcodebuild … test`. No engine change, so no Linux run.

**Hand-test (app):**

- View ▸ Hide Sidebar / Show Sidebar and ⌃⌘S work on Artifacts, People and Review, and
  are disabled on Tree.
- A new archive window opens at about 1100×720, and won't shrink below 800×520. Open
  Verify Integrity… and Show Trash… in a window at its minimum size: neither runs off the
  bottom.
- About GeneaLogic shows the credits, readable in light and dark mode, and its links open.
- Create an archive named `Test`: ⌘-clicking the title shows the name alone, and so does
  Finder. Create one named `Test2.genea`: both show the extension. Delete a sample built
  before 81 (`Application Support/Sample` in the app's container), open the sample, and
  ⌘-click its title: the name alone.
- Help ▸ GeneaLogic on GitHub and Report an Issue… open the right pages. The Help menu's
  search field still finds menu items.
- The seven G22 sites look the same as before: the transcript editor's border, the person
  picker's border, tree cards (focus ring, tint) and file chips. The file strip shows no
  scroll bar by default, and does show one with Scroll bars set to Always.

**Revised on `/code-review`:**

- **The file strip now follows the user's scroll-bar setting.** Measured with scroll
  bars set to Always: `showsIndicators: false` behaves as `.never` and shows no scroll
  bar, so the old code overrode the setting. `.hidden` shows the bar under Always or with
  a mouse, and hides it otherwise. Kept `.hidden`: the strip scrolls sideways, which a
  mouse user needs the bar for. The review suggested `.never`, a faithful copy of the
  old behaviour, and that was declined.
- **The hidden-extension flag is best effort.** A volume that refuses it no longer turns
  a create that succeeded into "Couldn't create the archive". It is set explicitly
  because a new package starts with it unset and shows `.genea` (measured).
- `ArchiveLauncher.create(at:)` now also acquires access and returns the window value,
  so the scope rule is written once. `createPackage(at:)` is the part the tests cover.
  The panel's URL always has the extension, so the hand-written append is gone.
- The tests clean up their temporary folders, and pin that showing the extension
  clears a flag that is set.

**From the hand-test:** the About credits got non-breaking spaces in the licence names,
links on the library names, and the project link moved under the synopsis, so the text
fits without scrolling. Sidebar visibility is per window, the same on every tab, as in
Finder, Mail and Xcode.

**Shipped 2026-11-02** (merged); **hand-test passed**.

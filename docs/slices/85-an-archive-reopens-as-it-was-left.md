# 85 — An archive reopens as it was left

Specced 2026-11-21 from the [second UI audit](workstream-5-ui-audit.md) (G10):
[#40](https://github.com/GeneaLogic/GeneaLogic/issues/40). The rest of #40 (G11, G24) and
[#41](https://github.com/GeneaLogic/GeneaLogic/issues/41) (G12) are
[85b](85b-recents-and-the-welcome-window.md).

**Problem.** Close an archive and open it again, and the window starts fresh: first tab,
nothing selected, default size. Its state is `@SceneStorage`, which only a relaunch
restores.

**Layer.** App only. No format change, no engine change.

## How it was decided

- **Not in the archive.** Per-user UI state inside the package (Xcode's `xcuserdata`)
  would sync between machines and sit beside the authored files. The state is this
  Mac's, as the audit said.
- **Neither the HIG nor Apple's document-app guidance** says anything about reopening a
  document as it was left. They cover restoring windows on relaunch only.
- **The key is the archive's file identity** (agreed 2026-11-21). The alternatives were
  the manifest's `archiveUID`, which a Finder copy shares, and the path, which a move or
  rename loses. A file's identity follows a move or rename on a volume and survives
  restarts, and a copy doesn't get it. So a moved archive keeps its state, and a copy
  starts fresh. A cross-volume move or a restore from backup starts fresh too: that is
  the accepted cost.
- **The identity is the volume's UUID and the folder's inode, not a bookmark** (found
  while building). The spec first reached it through the bookmark the app already keeps,
  but a bookmark resolves by **path** first: an archive put at a moved one's old path
  inherited its state, in a test. The kernel's document identifier is no better: APFS
  assigns it lazily, so a fresh folder has none.

## The design

- **One record per known archive, on this Mac**, in `ArchiveBookmarks` (`UserDefaults`,
  the app's container), keyed by identity. **Only a cap drops one:** the 100 most
  recently opened are kept, a read counting as opened. Not the bookmark's lifetime, as
  first written (85's `/code-review`): Remove from Recents would reset the window, a path
  can't say which record was whose, and a bookmark that fails may be on a drive that
  isn't mounted. It holds the tab, the three selections, People-as-tree, the sidebar's
  visibility, width and sections' expansion, the tree's two depths, the inspector's
  visibility and width, and the window's frame.
- **It replaces `@SceneStorage`** (and the sidebar's visibility, plain `@State` before)
  for all of these, one observed property per field, so a view re-renders only for what
  it reads. Relaunch and reopen read one
  place. Relaunch still restores *which* windows were open, as today. A window
  reads its record when it opens the archive, and writes each change as it happens, so a
  crash loses nothing. Two windows never show one archive (slice 31), so two windows
  never write one record.
- **Finding the record for an opened URL** is one lookup by its identity, read once the
  archive has opened (so with its sandbox access; an archive that fails to open gets no
  record), from a fresh `URL` (a `URL` caches resource values, so a long-lived one
  reports a replaced folder's old inode). A volume with no identity falls back to the
  path. **The identity is read once, at open,** and every write goes to it: the window's
  URL is fixed, so an archive renamed while open would otherwise write elsewhere.
- **The frame is in the record**, as `NSWindow.frameDescriptor` (the frame and its
  screen), applied a runloop hop after the window opens and saved when a resize or move
  ends. A first open still gets the default size (slice 81). *Built first on AppKit's
  frame autosave, as this spec said, and fell back as it allowed:* SwiftUI's windows keep
  a frame autosave name of their own, and a name set on them saved nothing (hand-test).
- **Column widths are measured and replayed.** SwiftUI has no binding for a column's
  current width, so the sidebar uses the inspector's mechanism, generalised from
  `RememberedInspectorWidth` into one modifier: measure the column, save once it settles,
  and replay it as the column's `ideal` on open. Its known limit carries over: a width
  SwiftUI imposes, such as a narrower window squeezing the column, is saved as if dragged.
  The sidebar gets a maximum of 480 pt, so a width saved on a large display can't squeeze
  the detail on a laptop.
- **A stored selection that no longer resolves** falls back to the placeholder, as today.

## Out of scope

- System recents, the welcome window, window tabs: [85b](85b-recents-and-the-welcome-window.md).
- Undo across a close: in-session, as before (G13, `0.2`).

## Verification

- **App tests** for the store, over an injected `UserDefaults` suite and plain
  temp folders, so no test writes to the developer's own defaults (the reason for
  `adoptAlreadyReachable`):
  - the record round-trips;
  - a reopen at the same path finds it;
  - a moved or renamed archive finds it and is re-keyed;
  - a copy gets a fresh record, and so does an archive put at a moved one's old path;
  - a forgotten path keeps every record;
  - the cap drops the least recently opened, frame included;
  - a window keeps writing to its record through a rename.
- ARCHITECTURE §7's "session-scoped only" paragraph, stale since restoration shipped, is
  rewritten for the store.
- **Hand-test** (on a throwaway or the sample archive):
  - close an archive on People with a person selected, the inspector narrowed and the
    sidebar widened, then reopen it from Open Recent and from Finder;
  - hide the sidebar, close and reopen;
  - move and rename it in Finder, then reopen it;
  - duplicate it in Finder and open the copy, which starts fresh;
  - quit and relaunch, which restores the same.

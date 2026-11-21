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
- **The key is the archive's file identity** (agreed 2026-11-21), as a bookmark gives it.
  The alternatives were the manifest's `archiveUID`, which a Finder copy shares, and the
  path, which a move or rename loses. The kernel's document identifier, which a bookmark
  resolves through, follows a move or rename on a volume and survives restarts. A copy
  doesn't get it. So a moved archive keeps its state, and a copy starts fresh. A
  cross-volume move or a restore from backup starts fresh too: that is the accepted
  cost.

## The design

- **One record per known archive, on this Mac.** It lives beside the archive's bookmark
  in `ArchiveBookmarks` (in `UserDefaults`, the app's container), and shares its lifetime:
  pruned when the bookmark stops resolving. It holds the tab, the three selections,
  People-as-tree, the sidebar's visibility, width and sections' expansion, the tree's two
  depths, the inspector's visibility and width, and the window's frame.
- **It replaces `@SceneStorage`**, and the sidebar's plain `@State` visibility, for all of these, so relaunch and reopen read one
  place. Relaunch still restores *which* windows were open, as today. A window
  reads its record when it opens the archive, and writes each change as it happens, so a
  crash loses nothing. Two windows never show one archive (slice 31), so two windows
  never write one record.
- **Finding the record for an opened URL.** The entry at that path whose bookmark
  resolves to it is the archive. Otherwise the stored bookmarks are resolved
  (`.withoutUI`, `.withoutMounting`), and one that resolves to the URL is the archive,
  moved. Its entry is re-keyed to the new path. Otherwise the archive is new to this
  Mac, and it gets a fresh record. An entry at the path whose bookmark resolves
  somewhere else belongs to the archive that moved away, not to the one there now.
- **The frame** uses AppKit's frame autosave under a per-record id, so AppKit stores and
  applies it. If SwiftUI's own window sizing fights the autosave, the frame goes in the
  record instead, applied through a window accessor. A first open still gets the
  default size (slice 81).
- **Column widths are measured and replayed.** SwiftUI has no binding for a column's
  current width, so the sidebar uses the inspector's mechanism, generalised from
  `RememberedInspectorWidth` into one modifier: measure the column, save once it settles,
  and replay it as the column's `ideal` on open. Its known limit carries over: a width
  SwiftUI imposes, such as a narrower window squeezing the column, is saved as if dragged.
- **A stored selection that no longer resolves** falls back to the placeholder, as today.

## Out of scope

- System recents, the welcome window, window tabs: [85b](85b-recents-and-the-welcome-window.md).
- Undo across a close: in-session, as before (G13, `0.2`).

## Verification

- **App tests** for the store, over an injected `UserDefaults` suite and plain
  (non-security-scoped) bookmarks in a temp folder, so no test writes to the
  developer's own defaults (the reason for `adoptAlreadyReachable`):
  - the record round-trips;
  - a reopen at the same path finds it;
  - a moved or renamed archive finds it and is re-keyed;
  - a copy gets a fresh record;
  - a pruned bookmark drops its record.
- ARCHITECTURE §7's "session-scoped only" paragraph, stale since restoration shipped, is
  rewritten for the store.
- **Hand-test** (on a throwaway or the sample archive):
  - close an archive on People with a person selected, the inspector narrowed and the
    sidebar widened, then reopen it from Open Recent and from Finder;
  - hide the sidebar, close and reopen;
  - move and rename it in Finder, then reopen it;
  - duplicate it in Finder and open the copy, which starts fresh;
  - quit and relaunch, which restores the same.

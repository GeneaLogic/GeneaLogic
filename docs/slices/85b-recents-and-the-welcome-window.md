# 85b — Recents and the welcome window

Specced 2026-11-21 from the [second UI audit](workstream-5-ui-audit.md) (G11, G24, G12):
the rest of [#40](https://github.com/GeneaLogic/GeneaLogic/issues/40), and
[#41](https://github.com/GeneaLogic/GeneaLogic/issues/41). Builds on
[85](85-an-archive-reopens-as-it-was-left.md).

**Problem.** File ▸ Open Recent is the app's own list (`ArchiveBookmarks.recents`), so the
Dock menu and Apple ▸ Recent Items never list an archive. The welcome window, with its
recents and *Explore a Sample Archive*, can't be reached while any archive is open. And
window tabs are switched off, because AppKit's tab commands crash on the app's windows.

**Layer.** App only. No format change, no engine change.

## Design forks (agreed 2026-11-21)

1. **Recents (G11): spike AppKit's own Open Recent first.** A small
   `NSDocumentController` subclass, installed before launch finishes, routes its opens
   into the app's open path. Every open calls `noteNewRecentDocumentURL`. The spike
   answers three questions:
   - Does that alone put archives in the Dock menu and Apple ▸ Recent Items?
   - Can File ▸ Open Recent be AppKit's own menu, with choosing an item granting the
     sandbox scope?
   - Can the welcome screen's list read the same recents and open them?

   **If the scope comes through,** `ArchiveBookmarks`' recents list goes, and its
   bookmarks stay for restoration and 85's state. **If it doesn't,** the fallback: feed
   the system, and keep the menu and the welcome list on the app's own list.
   **The spike (2026-11-24) was split, and the fallback was chosen.** The scope comes
   through: `recentDocumentURLs` can be read and written after a relaunch. But Open Recent
   can't be AppKit's own menu (SwiftUI discards the items when it rebuilds File), an
   ad-hoc-signed build's list is emptied at every rebuild, and the list can't be observed
   or have one entry removed. No subclass is needed: choosing from the Dock arrives as an
   ordinary open.
2. **Welcome becomes its own `Window` scene (G24)**, single-instance, with Window ▸
   Welcome to GeneaLogic (⇧⌘1, as in Xcode; free in slice 82's table). It may sit beside
   open archives. It shows at launch when nothing is restored or opened, and on a Dock
   click with no windows. It closes when an archive is opened, which gets its own
   window: from it, or any other way (⌘O, Finder, the Dock; widened 2026-11-24 before
   the hand-test). The URL group loses its `nil` state, and with it `RootWindow`'s
   welcome-must-not-coexist dismissal.

## G12, investigated

With the `nil` state gone, retest the tab crash. **Time-boxed to one sitting.** If the
cause is found and the fix is small, turn tabs back on (Show Tab Bar, Merge All Windows).
Otherwise, record what was found in #41, leave tabs off, and #41 gets its own slice or is
parked.

**Found (2026-11-24):** Show Tab Bar, Show All Tabs, Merge All Windows, Show Next Tab,
Move Tab to New Window, closing a tab and the tab bar's + don't crash on macOS 27.2. Nor do
Show Tab Bar, Merge All Windows and + on `main` before this slice, with tabs switched on.
All with the app in the background, Show All Tabs driven from code. So the crash wasn't reproduced, its cause wasn't found, and
macOS 26 (the floor) wasn't available. Turning tabs on also needs an answer for +, which
opens a window with no archive.

**Decided (2026-11-24): tabs stay off, and #41 is parked.** An archive window is complex
enough without a tab bar, and the HIG doesn't call for one: it only names the menu items "in
a tab-based window". Un-parks when people using the app ask for tabs, or the HIG recommends
them for this kind of app.

## Out of scope

- The window state store: [85](85-an-archive-reopens-as-it-was-left.md).
- A redesign of the welcome window's content.

## Verification

- **App tests:**
  - an open records a recent;
  - Clear Menu empties the list but keeps the bookmarks, which restoration needs;
  - a recent whose archive is gone drops out.
- **Hand-test:**
  - archives appear in the Dock menu and Apple ▸ Recent Items, and open from both;
  - ⇧⌘1 with archives open brings up the welcome window, and opening from it closes it;
  - launch with nothing to restore shows the welcome window, a Finder-open at launch
    doesn't flash it, and a Dock click with no windows shows it;
  - if tabs come back: merge two archives into tabs, close one, then quit and relaunch.

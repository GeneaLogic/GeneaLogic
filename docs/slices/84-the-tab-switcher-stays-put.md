# 84 — The tab switcher stays put

Specced 2026-11-16 from the [second UI audit](workstream-5-ui-audit.md) (G4):
[#39](https://github.com/GeneaLogic/GeneaLogic/issues/39).

**Problem.** The Artifacts / People / Tree / Review switcher moves. It is a `.principal`
toolbar item, and in a split view SwiftUI centres that in the detail column's part of
the toolbar. So it sits over the detail on Artifacts, People and Review, jumps to the
window's centre on Tree (a full-width `NavigationStack` with no sidebar), and shifts
left whenever the artifact inspector shows, because the inspector takes its own part of
the toolbar. Hiding the sidebar or dragging its edge moves it too. A control that
switches the whole window should stay in one place.

**Layer.** App only: `OpenArchiveView` (`ArchiveContainerView.swift`) and, depending on
fork 1, `TreeTab`. No format change and no engine change.

## Design forks (agreed 2026-11-16)

1. **Where it sits.** Two places don't depend on the detail column's width:
   - **(a) The window's centre**, whatever the columns do. It looks the way it does now
     on Tree, and Tree keeps its full width. Whether SwiftUI can put an item there in a
     split view is unknown: the toolbar is already attached to the split view, not to a
     column, and `.principal` still goes to the detail. AppKit's toolbar has
     window-centred items (`NSToolbar.centeredItemIdentifiers`), so it may be reachable.
   - **(b) The leading edge of the detail column** (`.navigation`), just right of the
     sidebar. It never moves with the inspector. It moves with the sidebar's edge, as
     Finder's back and forward buttons do, which reads as attached to the column rather
     than as jumping. Tree then needs the same columns (fork 2), or the switcher jumps
     left by the sidebar's width on Tree.

   **Recommended: (a) if the prototype (fork 3) shows it holds still in every case
   under *Verification*, else (b).** (a) changes nothing but the switcher, and keeps
   the look the app already has. (b) is the supported placement and the fallback.

2. **Tree's columns, if (b).** **Recommended: Tree joins the split view, with the
   People list as its sidebar**, whose selection is the focus (it already is the
   shared `personSelection`). That replaces the focus popover with a searchable list,
   keeps the sidebar's width across every tab (today a trip through Tree resets it),
   and the sidebar toggle gives the tree its full width back. The tree's depth
   controls stay where they are. *Alternative:* Tree keeps its full width and the
   switcher moves on Tree only. That is half the bug. Under (a), Tree is left alone.

3. **How the slice runs.** **Recommended: a time-boxed prototype of (a)**, as in 77 and
   80, in a minimal app (split view, sidebar, inspector, a centred picker) and then in
   ours. Try, in order, `.principal` attached outside the split view in other ways
   (on the window's root, on the sidebar column), then the AppKit route. Keep the
   first that holds still and needs no private API or view-hierarchy walking. If none
   does, write that up here and build (b) with fork 2.

## Out of scope

- **The switcher's look** (labels, icons, a menu at narrow widths). Only where it sits.
- **The other toolbar items.** The `+` button and the inspector toggle stay trailing,
  where they already sit still within their columns.
- **Window size and restoration**: 85.

## Verification

No unit test: this is placement, which only shows on screen. `xcodebuild test` stays
green; nothing in the engine changes, so no Linux run. **Hand-test** (yours, on 27, and
on 26 if a machine is handy). In each, the switcher doesn't move:

1. Switch through all four tabs, by click and by ⌘1–⌘4.
2. On Artifacts, hide and show the inspector, and drag its edge.
3. Hide and show the sidebar (⌃⌘S), and drag its edge. Under (b) the switcher follows
   the sidebar's edge, and does the same on every tab.
4. Resize the window, down to its minimum width.
5. Quit and relaunch on each tab (scene restoration).
6. Under (b), Tree: select someone in the sidebar and the tree refocuses; Focus Here and
   Show in Tree move the sidebar's selection; the depth controls still work.

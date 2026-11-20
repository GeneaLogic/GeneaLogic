# 84 — The window's structure

Specced 2026-11-16 from the [second UI audit](workstream-5-ui-audit.md) (G4), as *the tab
switcher stays put*; re-scoped 2026-11-19 when the switcher turned out to be a symptom:
[#39](https://github.com/GeneaLogic/GeneaLogic/issues/39).

**Problem.** The Artifacts / People / Tree / Review switcher moves: between tabs, when the
inspector shows, and when the sidebar hides. Underneath is a structural problem. The
window has three levels: the **area** (Artifacts, People, Tree, Review), the area's
**collection** (the artifact list, the people list, the worklist), and the **item**.
The area is a toolbar control and the collection sits in the sidebar, so the area
switcher reads as, and is laid out as, a control on the detail column.

**Layer.** App only. No format change, no engine change. The slice merges a decision
first (a prototype, as in 77), then the structure it picks.

## What the HIG says

- **Sidebars** let people "navigate between areas of your app or top-level collections of
  content". With more than two levels, "consider using a split view interface that
  includes a content list between the sidebar items and detail view". No more than two
  levels in a sidebar; "group hierarchy with disclosure controls if your app has a lot of
  content."
- **Segmented controls** on macOS: "Use a tab view in the main window area — instead of a
  segmented control — for view switching." One in a toolbar is for "closely related
  choices that affect an object, state, or view", like Calendar's Day/Week/Month.
  Artifacts and Review are different content, not views of one thing.
- **Tab views** are for "closely related areas of content", each pane self-contained.
  Slice 41 rejected a window-level `TabView`: it displaced the split view's toolbar items
  and nested a second sidebar.

## Measured before the re-scope (switcher placement alone)

In a minimal app, 1200 pt wide. `.principal` is AppKit's centred item, centred in the
detail's toolbar section (742 pt with a sidebar, 600 without), so it can't be
window-centred without editing SwiftUI's `NSToolbar`. `.navigation` holds at the
sidebar's edge but moves with it, and Tree would need a sidebar. The trailing end holds
on every tab, but puts the switcher at the far right and the inspector button inside
it. Rejected by the user on look.

## The prototype

On a `spike-84` branch, never merged. The current layout and two candidates, switched
from a temporary View menu item, over the sample archive and a large one:

- **(A) Three columns.** The areas in a sidebar (with counts, and room for Trash later),
  the area's existing list in the content column, the item in the detail, and the
  inspector beside it on Artifacts.
- **(B) One sidebar.** Two columns. The sidebar's sections are the areas, and each
  discloses its items: Artifacts ▸ every artifact, People ▸ every person. Review's
  lanes are already a level of their own, so Review is one row whose detail holds the
  worklist. One search field filters every section.

**Tree in both:** a view of People rather than an area, switched by a List | Tree
control in the toolbar on People, the use the HIG gives a toolbar segmented control.
The tree takes the detail, and its focus is the people selection.

**What to judge:** whether each is easy to find your way around and makes good use of
the space; what happens at the minimum window width, with the inspector shown; how B
copes with hundreds of artifacts and people, its search, and where Artifacts' sort and
filter go; and whether Tree as a People view loses anything.

## Design forks (after the prototype)

1. **A, B, or neither.**
2. **Tree: a People view, or an area of its own.**
3. **What else the sidebar carries**: Trash (86's open question), counts, and in B,
   whether sections remember being collapsed.
4. **Order with 85 and 86**: 85's restored state includes the structure's, and 86's
   trash may land in this sidebar.

## Out of scope

Everything the prototype doesn't need: commands, scene restoration, context menus and
drag and drop work as far as they do, and no tests are written for it.

## Verification

The prototype's is your run-through. The slice's is written once the forks are settled.

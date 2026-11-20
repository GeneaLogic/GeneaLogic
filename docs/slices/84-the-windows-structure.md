# 84 — The window's structure

Specced 2026-11-16 from the [second UI audit](workstream-5-ui-audit.md) (G4), as *the tab
switcher stays put*; re-scoped 2026-11-19 when the switcher turned out to be a symptom:
[#39](https://github.com/GeneaLogic/GeneaLogic/issues/39).

**Problem.** The Artifacts / People / Tree / Review switcher moves: between tabs, when the
inspector shows, and when the sidebar hides. Underneath is a structural problem. The
window has three levels: the **area**, the area's **collection** (the artifact list, the
people list, the worklist), and the **item**. The area is a toolbar control and the
collection sits in the sidebar, so the area switcher reads as, and is laid out as, a
control on the detail column.

**Layer.** App only. No format change, no engine change.

## How it was decided

- **The HIG.** Sidebars are for "areas of your app or top-level collections of content",
  at most two levels deep, with "disclosure controls if your app has a lot of content".
  A toolbar segmented control is for "closely related choices that affect an object,
  state, or view": Artifacts and Review are different content, but List and Tree are two
  views of the same people. Slice 41 already rejected a window-level `TabView`.
- **Placement alone can't fix it** (measured in a minimal app). `.principal` is AppKit's
  centred item, centred in the detail's toolbar section, not the window. `.navigation`
  follows the sidebar's edge. Only the trailing end holds still, which the user rejected
  on look.
- **A prototype** (`spike-84`, never merged) compared (A) three columns, areas | list |
  item, with (B) one sidebar whose sections disclose their items, over the sample and a
  309-artifact, 412-person archive. A doesn't fit: with the inspector open the document
  gets 290 pt at the default width and 30 pt at the minimum. B keeps 160 pt at the
  minimum, as today.

## The structure

One `NavigationSplitView`, two columns, on every area: **sidebar | item**.

- **The sidebar's sections are Review, Artifacts and People**, each with a plain-text
  header carrying its count ("15 of 309" while searching), collapsible from the header.
  Review is first: it is the work owed.
  - **Review** lists its lanes one after another (names, facts, relationships,
    duplicates), each row with its lane's symbol. A name row is two lines: the recorded
    name, then its artifact and best candidate. Review's pane takes the whole detail.
  - **Artifacts** rows carry their media type's symbol. The header carries Filter (tags,
    uncatalogued) and Sort menus. Damaged-record placeholders stay pinned at the top.
  - **People** rows carry no symbol; damaged placeholders as Artifacts.
- **The area is where the selection is.** Selecting a row sets the area; each area keeps
  its own selection. ⌘1–⌘4 and the jumps (Show in People, Show in Tree, a mention's
  person) expand the area's section if collapsed and scroll to its selection, else its
  header. The menu bar's commands still scope by area, unchanged.
- **Tree is a view of People**: a List | Tree control in the toolbar on People, the tree
  taking the detail, the people selection its focus. ⌘3 opens People as a tree. Tree's
  focus popover and Choose Focus… stay.
- **One search field** filters Artifacts and People. Review is not filtered, for the
  reason the worklist was never searchable: filtering work owed hides it. Edit ▸ Find
  focuses it from any area.
- **The duplicates scan runs when the archive opens**, in the background, so Review's
  count is whole from the start; the header shows an ellipsis until it finishes.
- **Collapsed sections are remembered per window**, like the selections. 85 decides
  where window state lives, and takes this with it.
- **No area switcher in the toolbar.** The `+` button follows the area, and the
  inspector toggle stays at the trailing end on Artifacts.

## Design forks (agreed 2026-11-19)

1. **A, B, or neither. Agreed: B.**
2. **Tree. Agreed: a view of People**, not an area.
3. **Review's items. Agreed: one Review section**, lane by lane. *Alternative:* a section
   per lane, six sections in all.
4. **Icons. Agreed:** headers plain text, as in Finder and Mail; symbols on artifact and
   review rows in one tint; none on people. **Thumbnails are
   [84b](84b-artifact-thumbnails.md)**.
5. **Filter and Sort. Agreed: in the Artifacts header**, beside its count. View ▸ Sort
   By stays.
6. **Trash. Agreed: left to [86](workstream-5-ui-audit.md#g7-the-trash-is-easy-to-forget)**,
   which now knows the sidebar is where it can go. The ladder's order is unchanged: 85
   restores what 84 builds.

## Out of scope

- **The trash in the sidebar**: 86. **Thumbnails**: 84b.
- **Where window state lives** (selections, collapsed sections, size): 85.
- **Multiple selection** in the sidebar: G5, `0.2`.

## Verification

- **Unit tests:** the sidebar's selection model (a row → its area and that area's
  selection, and back), as a pure type; the scroll target for an area switch (selection,
  else header, collapsed section expanded); Review's row order across lanes; the count
  wording. The command-availability tests stay green unchanged.
- `xcodebuild test` green; nothing in the engine changes, so no Linux run.
- **Hand-test** (yours), on the sample and on a large archive, light and dark:
  1. Every area by click, by ⌘1–⌘4, and by each jump; the sidebar lands on the right
     section each time, collapsed or not.
  2. The window at its minimum width with the inspector open.
  3. Search: Artifacts and People filter, Review doesn't, the counts say so; ⌘F.
  4. Filter and Sort from the Artifacts header; the uncatalogued filter.
  5. Review: decide by keyboard; the selection moves down the sidebar and stays in view.
     The count is right before Review is first visited.
  6. List | Tree on People; refocus from a tree card and from the sidebar.
  7. Collapse a section, quit, relaunch.
  8. Delete, merge and the other row context menus; drag files onto the window.

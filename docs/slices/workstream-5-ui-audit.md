# Workstream (5) UI audit — findings (2026-10-30)

The second [UI audit](../UI-AUDIT.md), after slice 80, at `b721f03`. Four sources: the
user's notes; a run-through of the sample archive on macOS 27 (`make-demo-archive.sh`,
dark mode); a read of the app's command surface (menus, toolbars, context menus,
dialogs); and Apple's HIG with the
[mac-assed-mac-app](https://github.com/HunterHillegas/mac-assed-mac-app-skill) references.
Candidates carried from the ROADMAP and from the specs of 79, 79b and 80 are folded in.

**Not covered:** VoiceOver and full keyboard access (G18), which need a hand-test.
The idiom read followed Apple's SwiftUI guidance (soft-deprecated APIs, `ForEach`
identity, data flow, localization); a sheet was opened where the run-through reached it,
not every sheet in turn.

Tags as in the first audit — **[HIG]**, **[Idiom]**, **[UX]** — plus **[A11y]**. P1–P3 is
impact. *Bucket* is the consequence rule: **now** (a slice in `0.1`), **batch** (a small
ones slice), **park** (with what un-parks it). Each finding becomes an issue once agreed;
status lives there, not here.

## Findings

| # | Finding | Tags | P | Size | Source |
| --- | --- | --- | --- | --- | --- |
| G1 | The menu bar is not the command map | HIG | P1 | large | notes, code |
| G2 | No View-menu commands or shortcuts for the four tabs | HIG UX | P2 | small | notes |
| G3 | No Show/Hide Sidebar in the View menu | HIG | P2 | trivial | run |
| G4 | The tab switcher moves between tabs and with the inspector | HIG UX | P2 | medium | notes, run |
| G5 | Sidebars select one item at a time | HIG UX | P2 | large | notes |
| G6 | Copy does nothing for a selected artifact or person | HIG | P2 | medium | candidate, code |
| G7 | The archive's trash is easy to forget, so deletes still confirm | HIG UX | P2 | medium | notes, run |
| G8 | No Help content | HIG | P2 | large | notes, candidate |
| G9 | The window opens at 900×450 | HIG | P2 | small | candidate, run |
| G10 | An archive doesn't reopen the way it was left | HIG UX | P2 | medium | candidate |
| G11 | Open Recent is the app's own list, not the system's | HIG | P3 | medium | candidate |
| G12 | Window tabs are switched off because they crash | HIG | P3 | medium | candidate |
| G13 | Undo is the window's, and its names don't follow the action | HIG Idiom | P2 | large | candidate |
| G14 | `.genea` archives have the system's generic document icon | HIG | P3 | small | notes |
| G15 | Toolbar: which frequent commands belong there | HIG UX | P3 | small | notes |
| G16 | No Quick Look on Space | HIG | P3 | small | candidate |
| G17 | The About window is the default one | HIG | P3 | small | candidate |
| G18 | VoiceOver and full keyboard access, unaudited since F6/F11 | A11y | P2 | medium | candidate |
| G19 | An edit that finds nothing to write to is dropped silently | UX | P3 | small | 79b |
| G20 | `IntegrityReportSheet` and `PersonDetailView` are ~1,000 lines each | Idiom | P3 | medium | 79 |
| G21 | The window title's path menu shows the `.genea` extension | HIG | P3 | trivial | candidate |
| G22 | Five soft-deprecated modifier forms | Idiom | P3 | trivial | code |
| G23 | Nothing is localizable: no string catalog, labels passed as `String` | Idiom | P3 | large | code |
| G24 | The welcome window can't be reached while an archive is open | UX | P3 | small | run |

### G1. The menu bar is not the command map

Menus cover File (archive, Add Artifact, Verify, Trash), View (inspector, sort) and an
Artifact menu. Everything else lives only on a button or a context menu: on **People**,
New Person, Merge Into…, Delete Person…, Add Name/Fact/Relationship; on **Tree**, Focus
Here, Show in People and the depth steppers; in **Review**, Confirm, Reject, This Is
Somebody New…, Merge People, Not a Duplicate, Record Relationship, Refresh; on an
artifact, Scan for Metadata, Apply…, Resolve…, and a mention's Add Fact/Add
Relationship. Context menus and the menu bar are written separately, so they drift (the
artifact row's context menu has only Delete), and an item stays live when it can't act
(Edit Transcript… while another sheet is up).

The fix has two halves. **One source for each command** — its title, shortcut,
availability and action — that the menu bar, context menus and toolbar all read, so
they can't disagree and "can't act" is computed once. Then **the structure**: a
**Person** menu beside Artifact (a menu per object, as Mail has Message and Mailbox),
Review verbs in whichever of those their object belongs to or a **Review** menu of their
own, separators between groups, and a shortcut scheme (below). Probably two slices:
the command source with the Artifact and Person menus, then coverage of Tree and Review.

**A shortcut scheme to agree before building it.** Standard keys stay standard (⌘N, ⌘O,
⌘W, ⌘Z, ⌘C/⌘V, ⌘⌫, ⌘F, ⌘,, ⌃⌘S sidebar, ⌥⌘I inspector). ⌘1–⌘4 switch tabs (G2), as in
Finder and Mail. The rest is laid out as one table in the slice spec, checked against
the system's reserved keys. Two things to settle there: ⌘I is Add Artifact today, where
most Mac apps have Get Info; and Review's verbs, used in a fast triage loop, are the
strongest case for short shortcuts.

### G4. The tab switcher moves

It is a `.principal` toolbar item, so it centres in the toolbar region of the column it
belongs to. On Artifacts, People and Review that is the detail column, which the
inspector widens; on Tree, which has no split view, it is the whole window. So it jumps
from the detail's centre to the window's centre on Tree, and shifts again when the
inspector shows. A window-level control should sit still. Whether it moves to a fixed
place (leading, after the sidebar toggle) or Tree keeps a split view so every tab has
the same columns is the slice's fork.

### G5. Multiple selection

Both sidebars bind a single `ArtifactID?`/`PersonID?`. A set means every verb that takes
a selection takes many (delete, merge, tag), the inspector needs a multiple-selection
state, and undo groups a multi-item change as one step (G13). It is also what drag and
drop (#16, `0.2`) builds on. **Settled: `0.2`**, and near the front of it, before #16. It
goes after G13, which decides how a multi-item change undoes.

### G7. The trash is easy to forget

The red-tinted Delete button is the system's own rendering of a destructive button in a
macOS 26+ alert; the code adds no styling, and Cancel holds the keyboard focus. The HIG
point is that a delete that can be undone shouldn't ask: Finder, Notes and Photos move
to a trash without asking. But each of them keeps the trash in view (the Dock's full or
empty can, a Recently Deleted row in the sidebar). The archive's trash is File ▸ Show
Trash…, which is easy to forget is there, so dropping the dialog first would make a
delete feel final. The two cases also differ: a deleted **artifact** goes to the trash
and survives a quit, but a deleted **person** can only be undone in the session that
deleted it ([#11](https://github.com/GeneaLogic/GeneaLogic/issues/11)).

**So the order is:** make the trash visible first, in the sidebar or the toolbar, with
whether it holds anything (the slice's fork). Then drop the confirmation for an
artifact. A person keeps it until #11 gives deleted conclusions a trash. **When it does,
a person is treated the same way as an artifact:** it shows in the same visible trash,
and its confirmation goes too. That belongs in #11's spec.

### G8. Help

Help ▸ GeneaLogic Help is the default item with no help book behind it, so it opens
nothing useful. **Settled:** a user guide as an Apple Help Book (searchable from the Help
menu, opening in Tips on macOS 26+), a prerequisite for `1.0`, and the same guide on the
web at genealogic.app. Neither is needed for `0.1`. Still open: what the Help menu says
in `0.1`, where the default item leads nowhere.

### G9–G12. Window and document lifecycle

One decision covers four findings: where window state lives and what an archive is
keyed by. Today the selections, tab and inspector are `@SceneStorage`, which only a
relaunch restores; closing and reopening an archive starts fresh (G10). Open Recent is
`ArchiveBookmarks` rather than the system's recent documents, so the Dock menu and the
system's recent items don't list archives (G11). Tabs are off because `WindowGroup(for:
URL.self)` windows crash in AppKit's tab machinery (G12). The default size (G9) is the
cheap part, and also why the Verify Integrity and Trash sheets, at their minimum
height, are taller than a new window. **Recommendation:** state on the machine, keyed by the archive's identity,
not in the archive (as the ROADMAP says); settle that first, then G10–G12 are one or
two slices.

### G13. Undo

Undo is per window (`UndoManager` from the environment), with action names set at each
registration. Slice 77 showed the archive can own its undo stack, which fixes slice 52's
grouping problem and lets names come from the command layer. It decides how G5's
multi-item changes undo, so it goes first of those two.

### G14. The document icon

Today Finder draws the system's default: a blank page with the app icon on it and
`GENEA` under it, because `Info.plist` declares no icon for the type. Short of a custom
icon file, the type's `UTTypeIcons` entry can set a background image for the page, a
badge in place of the app icon, and the text in place of `GENEA`. The slice tries those
first, and goes to a custom icon if they can't make it look like an archive.

### G21. The extension in the path menu

⌘-clicking the window title shows the archive's path with `.genea` on it, where other
apps show the name alone. The menu shows the name the file system gives it, and the
extension shows because the archive's hidden-extension flag isn't set. The likely fix is
to set it when the app creates an archive, as a save panel does, which also hides the
extension in Finder. To confirm in the slice.

### G22–G24

**G22.** `overlay(_:alignment:)` in `TranscriptEditorSheet`, `PersonPicker` and
`TreeContentView`, `background(_:alignment:)` in `TreeContentView`, and
`ScrollView(_:showsIndicators:)` in `ArtifactDocumentPane`. Each has a direct replacement
(`overlay(alignment:content:)`, `scrollIndicators(_:)`). Nothing else from the
soft-deprecated list is used, `ForEach` ids are stable (the two `\.offset` lists are the
read-only ones 79b left alone), and there is no `ObservableObject` left.

**G23.** There is no string catalog, and many labels reach SwiftUI as `String` (computed
titles, `Button(inspectorLabel)`), which SwiftUI shows verbatim instead of looking up.
English-only is fine for `0.1`. **Park** until a translation is planned; the un-parking
slice adds the catalog and moves computed labels to `LocalizedStringResource`.

**G24.** By design (`RootWindow`), the welcome window closes when an archive opens and
never coexists with one, so its recents and *Explore a Sample Archive* are out of reach
until every archive is closed. File ▸ Open Recent covers the recents. Xcode keeps its
welcome window in the Window menu (⇧⌘1). Worth the same here once the lifecycle
decision (G9–G12) is made.

## Out of scope

- [#3](https://github.com/GeneaLogic/GeneaLogic/issues/3), [#4](https://github.com/GeneaLogic/GeneaLogic/issues/4) and [#8](https://github.com/GeneaLogic/GeneaLogic/issues/8): `0.1` bugs outside the Mac pass.
- Feature requests: [#1](https://github.com/GeneaLogic/GeneaLogic/issues/1), [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2), [#6](https://github.com/GeneaLogic/GeneaLogic/issues/6), [#16](https://github.com/GeneaLogic/GeneaLogic/issues/16) (`0.2`).
- Anything needing a format change: raised, and goes to `0.3`.
- A Settings window: nothing durable to set yet. [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2)'s auto-delete is the first.
- Performance at scale: the scale slice.

## The ladder (agreed 2026-11-02)

Each is specced in `docs/slices/` before it is built.

| Slice | Findings | Milestone |
| --- | --- | --- |
| **81** — small ones | G3, G9, G17, G21, G22; the Help menu points at the project page and Report an Issue… (G8's `0.1` part) | `0.1` |
| **82** — one source for commands | G1 (the command source, Artifact and Person menus, the shortcut table), G2 | `0.1` |
| **83** — command coverage | G1 (Tree and Review, context menus from the same source), G15 | `0.1` |
| **84** — the tab switcher stays put | G4 | `0.1` |
| **85** — window and document lifecycle | G10, G11, G24; G12 investigated, split off if deep | `0.1` |
| **86** — a visible trash | G7 | `0.1` |
| **87** — copy and Quick Look | G6, G16 | `0.1` |
| **88** — the document icon | G14 | `0.1` |
| **89** — accessibility | G18, from the user's hand-test | `0.1` |

**Why this order.** The small ones are independent and quick. Commands come before the
toolbar and the switcher, because toolbar items read the same command source. The
lifecycle comes before the trash, which may land in a sidebar that settles there.
Accessibility is last, so its hand-test covers the finished menus and toolbar.

**After the Mac pass.** In `0.2`: G13 (the archive's undo stack), then G5 (multiple
selection), then [#16](https://github.com/GeneaLogic/GeneaLogic/issues/16); G19 and G20. Before `1.0`: G8's user guide, as a Help Book and
on genealogic.app. **Parked:** G23, until a translation is planned.

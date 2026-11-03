# 82 — one source for commands

Specced 2026-11-03 from the [second UI audit](workstream-5-ui-audit.md) (G1's first half,
G2): [#38](https://github.com/GeneaLogic/GeneaLogic/issues/38).

**Problem.** Each surface spells its own commands. The Artifact menu, a file row's ⋯ menu
and the artifact list's context menu name the same verbs differently ("Delete File…" and
"Delete"; Scan for Metadata is on the ⋯ menu and not in Selected File). The People tab's
verbs are on buttons and a context menu only, with no menu. A menu item stays live when
it can't act: Artifact ▸ Edit Transcript… with an editor already up does nothing, because
the detail view refuses it silently. And there is no key for the four tabs (G2).

**Layer.** App only. No format change and no engine change.

## The command source

- **`ArchiveCommand`**, one case per command, each carrying its subject where it has one
  (`.deletePerson(PersonID)`, `.addEvent(ArtifactID)`). For each case it gives the title,
  the symbol, the shortcut and whether it is destructive. Nothing else in the app spells
  a command title.
- **Availability is one pure function** over a `CommandContext`: archive open, active tab,
  selected artifact, selected file, selected person, person count, and whether a sheet,
  dialog or panel is up in the window. The menu bar, the context menus and the in-pane
  buttons all ask it. This is what turns off Edit Transcript… while an editor is up.
- **A sheet being up is reported, not guessed.** Each view's sheets, dialogs and
  popovers report themselves (`reportsModal`) and the model counts them, with its own
  flags (importer, Verify, Trash, New Person, alerts). AppKit's view of the key window
  is the backstop (below).
- **Running a command:** commands the model can run itself (Add Artifact…, Show Trash…)
  run there. Commands that open a sheet a view owns go through one `pendingCommand`
  intent, which replaces today's four (`pendingArtifactCommand`, `pendingFileCommand`,
  `pendingArtifactDeletion`, `pendingInspectorToggle`). The owning view runs it and
  clears it, as now.
- **Surfaces in 82:** the menu bar; the artifact and person rows' context menus; the file
  row's ⋯ menu; the Names, Facts and Relationships Add buttons. Each draws a
  `CommandButton(command)`. The ⋯ menu's Role picker isn't a command and stays as it is.

## The menus and the shortcut table

Standard keys stay standard (⌘N ⌘O ⌘W ⌘Z ⇧⌘Z ⌘X ⌘C ⌘V ⌘A ⌘, ⌃⌘S ⌃⌘F). Checked against
the system's reserved keys (⌘H ⌘M ⌘Q ⌘\` ⌘Space ⌥⌘D ⌃⌘Q ⇧⌘3/4/5 ⌘? ⌥⌘Esc) and the
text-editing ones (⌘E ⌘G ⌘J ⌘T ⌘B ⌘U ⌘I): no clash. A test pins it: no two commands share
a key, and none takes a reserved one.

| Menu | Command | Key | Notes |
| --- | --- | --- | --- |
| File | New Archive… · Open Archive… · Open Recent | ⌘N · ⌘O | unchanged |
| File | Add Artifact… | **⇧⌘I** | was ⌘I (fork 1) |
| File | New Person… | **⇧⌘N** | new to the menu (fork 3); key provisional |
| File | Verify Integrity… · Show Trash… | — | unchanged; the trash is 86 |
| Edit | Find | ⌘F | to the sidebar's search field, if `.searchable` doesn't already take it (measured) |
| View | Artifacts · People · Tree · Review | **⌘1–⌘4** | G2; a checkmark on the current tab |
| View | Show/Hide Sidebar · Show/Hide Inspector · Sort By | ⌃⌘S · ⌥⌘I | unchanged |
| Artifact | Add Event… · Add Place… · Add Person Mentioned… | — | "Add Person…" was easily read as New Person |
| Artifact | Edit Transcript… · Attach File… | — | |
| Artifact | Selected File ▸ Open in Separate Window · Open in Default App · Save a Copy… · Scan for Metadata · Replace… · Delete File… | — | Scan joins it |
| Artifact | Delete Artifact… | ⌘⌫ | unchanged |
| **Person** | Add Name… · Add Fact… · Add Relationship… | — | new menu |
| Person | Merge Into… | — | off when there is nobody else |
| Person | Delete Person… | ⌘⌫ | the list's ⌫ stays |
| Review *(83)* | the lane's accept verb (Confirm, Record, Merge People) | **⌘↩** | fork 4; built in 83 |
| Review *(83)* | the lane's decline verb (Reject, Not This, Not a Duplicate) | **⌘⌫** | fork 4; built in 83 |
| Review *(83)* | Refresh | ⌘R | built in 83 |

⌘⌫ has one meaning per tab, as in Finder. Tree's verbs (Focus Here, Show in People, the
depth steppers) get no keys; 83 lists them. Row-level verbs that act on one row of a
pane (a mention's Resolve…, a metadata entry's Apply…) aren't menu-bar commands: there
is no selection for them to act on. 83 gives them context menus from the same source.

## Design forks (recommendations)

1. **⌘I. Agreed:** Add Artifact… moves to ⇧⌘I, Photos' Import, and ⌘I is left
   free. Most Mac apps use ⌘I for Get Info or Italic, and this app has neither, so an
   add on ⌘I is a surprise. *Alternative:* keep ⌘I.
2. **A create command while another tab is showing.** Today Add Artifact… is off outside
   Artifacts, so that it can't add an artifact out of sight. **Agreed:** Add Artifact…
   and New Person… stay on and switch to their tab first, so the result is in view and
   the menu item isn't greyed for a reason the user can't see. Selection verbs (the
   Artifact and Person menus) stay tied to their tab, because the selection on another
   tab isn't on screen. *Alternative:* both creates stay tied to their tab.
3. **Where New Person… lives. Agreed:** File, beside Add Artifact…, because File
   holds the commands that make something new (as Mail's New Message, Contacts' New
   Card). *Alternative:* the top of the Person menu. **⇧⌘N is provisional**, to revisit
   in the hand-test once all the menus are there.
4. **Review's keys**, agreed here and built in 83. **Agreed:** ⌘↩ accepts and ⌘⌫
   declines, whatever the lane. Triage is one hand on two keys, and both are already
   "yes" and "get rid of it" on the Mac. *Alternative:* bare keys with no modifier, as
   Lightroom's P and X. Rejected: SwiftUI menu items with no modifier also fire while
   typing in a text field.

## Out of scope

- Tree and Review menus, their context menus, and the toolbar reading the source (G15):
  83.
- The tab switcher's position: 84. Delete confirmations: 86. Copy: 87.
- Undo names that follow the command (G13) and multiple selection (G5): `0.2`.

## Verified by

- `GeneaLogicAppTests`: a `CommandAvailabilityTests` table (each command against tab,
  selection, file, person count, sheet up); the shortcut test above; the existing
  `UndoRedoTests` still pass with the intents collapsed into one.
- `xcodebuild … test`. No engine change, so no Linux run.

**Hand-test (app):**

- ⌘1–⌘4 switch tabs, and View shows a checkmark on the current one.
- Every Artifact and Person menu item does what its in-pane button does, and is grey
  with no selection, on the wrong tab, and while any sheet or dialog is up (open Add
  Event…, then try Artifact ▸ Edit Transcript…).
- ⇧⌘I adds an artifact from any tab and lands on Artifacts; ⇧⌘N does the same for a
  person; ⌘I does nothing.
- ⌘⌫ deletes (with its confirm) the artifact on Artifacts and the person on People. With
  the cursor in an inspector text field, ⌘⌫ deletes text, not the artifact (to confirm;
  if the menu takes it, the field gets it back).
- The artifact row, person row and file ⋯ menus read the same titles as the menu bar.
- ⌘F reaches the sidebar search on Artifacts and People.

**Settled in the build:**

- **⌘F, measured:** the Edit menu had no Find, and `.searchable` takes no key. Edit ▸
  Find… is a command, on Artifacts and People, focusing the search field
  (`searchFocused`).
- **⌘⌫ in a text field** goes back to the field (`deleteToBeginningOfLine:`) when it was
  typed, not chosen from the menu.
- **One shortcut, one live item.** A command's key is attached only while its tab shows,
  so Delete Artifact… and Delete Person… never both answer ⌘⌫.
- **Add Person… stays the in-pane label** under *Persons Mentioned* (`paneTitle`):
  "Add Person Mentioned…" doesn't fit the inspector at 280 pt, and the heading already
  says it.
- **The in-pane Attach File… keeps its scan options;** the menu bar's goes straight to
  the importer, because the connected menu can't anchor to a menu item (as before).
- The ⋯ menu's verbs now follow the Selected File order, and its Delete File… uses the
  detail's confirm, so there is one.

**Revised on `/code-review`:**

- **The menu bar acts on the selection when chosen**, not when the menu was last drawn.
- **⌘⌫ goes back to a field only when that key was typed into an editable one**: not a
  Return in Help's search, and not a selectable label.
- **A modal nobody reported can't be covered.** A menu command beeps instead of running
  while AppKit has a sheet, panel or modal window on the key window. Reported ones grey
  the items; the Tree's focus popover now reports. One wrapper that presents and reports
  was considered, but needs an overload per presentation form, and the backstop covers
  any form. A Continuity scan's waiting UI is AppKit's: the backstop catches it if it
  is attached to the window, and if not, the scan still arrives through its own
  callback, so an importer opened meanwhile loses nothing (not measured; hand-test).
- **Find… shows a hidden sidebar first** (the split view's visibility is now bound).
- **In-pane affordances ask the rule too** (`CommandAffordance`), and the transcript and
  empty-pane Attach File… take their titles from the source. They are not greyed under a
  sheet, which can't be clicked through anyway.
- **Each view reads only its command's part of the context** (`commandContext(for:)`), so
  selecting a file doesn't redraw every person command. A test pins that it decides as
  the whole context does.
- **The tab commands are one case each**, so `allCases` is the compiler's.
- **CI:** the test's reserved-key list, as one `+` chain, timed out the type checker on
  the runner (not locally). It is built in typed parts.

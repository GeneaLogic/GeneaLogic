# 83 — command coverage

Specced 2026-11-04 from [82](82-one-source-for-commands.md)'s hand-test, and the
[second UI audit](workstream-5-ui-audit.md) (G1's second half, G15):
[#38](https://github.com/GeneaLogic/GeneaLogic/issues/38).

**Problem.** Review's and Tree's commands exist only as buttons and a context menu, so the
menu bar isn't yet the command map, and triage can't be done from the keyboard. Two
deletes share ⌘⌫, so each hides the other's key. The Artifact and Person menus have no
keys of their own. The toolbar and the Review and Tree buttons still spell their own
commands.

**Layer.** App only. No format change and no engine change.

## Review

- **A `ReviewTarget`** in `CommandContext`, mirrored from the window's Review selection as
  `selectedArtifact` is: the row's id and its lane (name, facts, relationship, duplicate),
  and what the lane's top row can take. It is a value, so the availability table stays
  pure.
- **Availability of the two verbs, by lane:**

| Lane | Accept (⌘↩) | Decline (⌘⌫) |
| --- | --- | --- |
| Name, with candidates | Confirm the top candidate | Reject the top candidate |
| Name, no candidate | off | off |
| Facts | Record the top suggestion, or open its editor if it can only be applied (fork 2) | off: the lane has no decline |
| Relationship | Record Relationship | Not This Relationship |
| Duplicate | off | Not a Duplicate |

- **A held key decides once.** Every other key in the app undoes or opens something; these
  two write a human verdict and, with fork 7, move to the next row. So they ignore
  `NSEvent.isARepeat`, and a held ⌘↩ can't confirm a queue. A quick second press is refused
  with a beep until the first write lands, because the row stays until then.
- **`ReviewCommandHost`** sits on the detail column and owns This Is Somebody New…'s sheet,
  the sheet ⌘↩ opens and Merge People…'s dialog. A row's context menu can name an
  unselected row, so a pane can't own them: it may be another row's. It also keeps the
  selection's mirror and moves it on (fork 7).
- **In the pane,** no button is prominent, and the row the keys act on says so in a small
  caption (fork 3): "⌘↩ Confirm · ⌘⌫ Reject · ⌘Z undoes either" on the top candidate. The
  panes keep their lane's words (Confirm, Record, Not a Duplicate), drawn from the source
  as `paneTitle` is.
- **Refresh** is one command for the strip's button, the empty state's button and ⌘R.

## Tree

- **Person menu:** Show in Tree (People, on the selection), Show in People (Tree, on the
  focus). The selection mirror extends to Tree, as the focus already is the window's
  person selection.
- **View menu**, after Sort By and live on Tree only: Show More Ancestors, Show Fewer
  Ancestors, Show More Descendants, Show Fewer Descendants, Choose Focus…. The depths stay
  in `TreeTab`'s `@SceneStorage` and are mirrored, so an item greys at 0 and 8.
- **Cards:** Focus Here and Show in People come from the source. `tab` becomes per-command
  here, because these take a person and belong to Tree.

## The menus and the shortcut table

Changes to 82's table. Everything else stands.

| Menu | Command | Key | Notes |
| --- | --- | --- | --- |
| File | Delete Artifact… / Delete Person… | ⌘⌫ | one item, label follows the tab; "Delete…", dimmed, on Tree and Review (fork 1) |
| Artifact, Person | their delete items | — | removed (fork 1); context menus keep theirs |
| Artifact | Add Event… · Add Place… · Add Person Mentioned… · Edit Transcript… | ⌘E · ⌘L · ⌘K · ⌘T | fork 6 |
| Person | Add Fact… · Add Relationship… | ⌘E · ⌘K | fork 6 |
| Person | Show in Tree · Show in People | — | new |
| View | the four depth items · Choose Focus… | — | new; Tree only |
| **Review** | Accept Suggestion | ⌘↩ | new menu (fork 4) |
| Review | Decline Suggestion | ⌘⌫ | the File item gives up the key here, as it is dim anyway |
| Review | Merge People… | — | fork 8 |
| Review | This Is Somebody New… | — | |
| Review | Refresh | ⌘R | |

⌘↩ and ⌘⌫ sit on the menu items, not on the pane's buttons: SwiftUI keeps one owner per
key, and the menu is what shows it. A shared key has one live item per tab, as 82 built
(`ownsShortcut`).

## Surfaces

- **The toolbar reads the source** (fork 9): the + on Artifacts and People and the
  inspector toggle take their titles and availability from it. The + keeps its scan menu
  by the override `CommandAffordance` already has.
- **Context menus, this slice:**
  - An artifact row: Delete. A person row: Show in Tree, Merge Into…, Delete.
  - A Review row: Accept, Decline, This Is Somebody New…, each on that row, with the same
    availability as the menu bar.
  - A Tree card: Focus Here, Show in People.
  - An add stays off the rows (fork 10): a row's verb can name an unselected row, and the
    detail pane that owns the sheet is another row's. `PersonDetailView` drops such a
    request today.
- **Row-level verbs inside a pane** (a mention's Resolve… and Unlink, a metadata entry's
  Apply…, a suggestion's Record and Edit…): 83b (fork 11).

## Design forks (recommendations)

1. **One Delete item, or one per object.** SwiftUI drops a duplicate key from the later
   item, enabled or not (measured in 82), so a key is attached only while its tab shows,
   and the dimmed item on the other tab shows no ⌘⌫.
   **Agreed:** one item whose label follows the tab, in **File** beside Show Trash…, as
   Finder has Move to Trash (⌘⌫). It keeps ⌘⌫ visible, and suits 86 ("Delete Artifact"
   with no confirm, "Delete Person…" with one) and G5 ("Delete 3 Artifacts"). Delete File…
   stays in Selected File, because a file is nearly always selected and can't drive the
   label. The cost: the File menu deletes an artifact while the Artifact menu deletes a
   file.
   *Alternative:* Edit, as Reminders does. The system's Delete is already there, replacing
   it probably means replacing the whole Cut/Copy/Paste/Delete/Select All group (to
   confirm), and with the cursor in a text field Edit ▸ Delete acts on the selected text.
   *Alternative:* keep two items, as 82 shipped.
2. **What the keys act on.** 82's fork 4 agreed "⌘↩ accepts and ⌘⌫ declines, whatever the
   lane", which missed that most lanes have no single target.
   **Agreed:** the table above. They act on the top row; the duplicates lane has no
   ⌘↩, because two Keep buttons are a choice rather than a yes; and the facts lane has no
   ⌘⌫, because it has no decline. A top suggestion that needs the sheet (a couple fact, an
   age) opens it on ⌘↩, so nothing writes unseen and no row is skipped.
   *Alternative:* ⌘↩ takes the first directly recordable suggestion, skipping those.
3. **Confirm's styling.** A prominent button reads as the default button, Return doesn't
   activate it, and several can be on screen.
   **Agreed:** no prominent button in Review, because prominence says "most likely" (HIG),
   and the matcher can't know that; the pane asks to be read. The top row's caption shows
   the keys instead, and each lane shows only the keys it has. Sheets keep theirs, where
   one action really is the commit.
   *Alternative:* the top candidate's Confirm stays prominent, nudging toward accepting.
4. **A Review menu.** **Agreed:** a small menu of its own, because its verbs act on a
   suggestion, which is neither an artifact nor a person. Stable titles (Accept Suggestion,
   Decline Suggestion), since the HIG says to always show the same items.
   *Alternative:* the verbs go in the Artifact and Person menus.
5. **Tree's commands.** **Agreed:** no Tree menu. Card verbs act on the card that was
   clicked, and Tree has no selection for a menu item to act on, so they stay on the card;
   what has a menu-bar subject (the focus, the depths) goes in View and Person.
6. **Shortcuts for the Artifact and Person menus, and ⇧⌘N.** The HIG asks for custom
   shortcuts on "only the most frequently used" commands. One key per role is shared
   across tabs, as ⌘⌫ is.
   **Agreed, to confirm in the hand-test:** the table above. ⌘E and ⌘T are the
   text-editing keys 82 ruled out and `CommandShortcutTests` reserves (use selection for
   find; fonts). Their actions mean nothing here, with no find panel or styled text, but
   taking them reverses that rule, and the test's list changes. ⇧⌘N stays, and stops being
   provisional: Shift complements ⌘N New Archive, as the HIG suggests.
   *Alternative:* ⌘L and ⌘K only, leaving ⌘E and ⌘T reserved.
7. **After a decision, where the selection goes.** Without this the keys do one row. A decided row leaves the list and the selection falls to "Select an
   Item", so a second ⌘↩ has nothing to act on.
   **Agreed:** the row below takes the selection, however the verb was run, and a row
   that stays (a rejected candidate with others left) keeps it. It never crosses into
   Possible Duplicates, the lane built to be read rather than cleared.
   *Alternative:* it may cross, so the queue reads as one list.
8. **Merge People in the menu bar.** Fork 2 leaves merging on the pane's
   two Keep buttons, so the map has a hole.
   **Agreed:** Review ▸ Merge People… asks which record to keep in one dialog (Keep
   “A”, Keep “B”, Cancel), which is also the confirmation.
   *Alternative:* no menu item. Merging stays a choice made in the pane, and the map
   records why.
9. **The toolbar (G15).** **Agreed:** nothing new earns a place. It
   already has what each tab does most: the + and the inspector. Refresh sits in Review's
   strip, Accept and Decline in the pane, and the trash goes to 86. The slice only moves
   the existing items onto the source.
10. **How much a list row's context menu carries.** Adds need the row's
    detail pane, and right-clicking doesn't select.
    **Agreed:** verbs that don't need the pane, as listed under *Surfaces*.
    *Alternative:* every verb, with the row selected first. It needs an intent that waits
    for the pane to load, as Find…'s hidden sidebar does.
11. **Split the slice.** The spec is over ROADMAP's screenful.
    **Agreed:** the row-level verbs inside panes go to **83b**. They span several
    views, each verb needs its own subject in `CommandSubject`, and nothing in 83 depends
    on them.
    *Alternative:* all in 83.

## Out of scope

- Row-level verbs inside panes: 83b.
- A mention's Restore buttons: rare, and they name a person, so they stay in the pane.
- The tab switcher's position: 84. Delete confirmations and the trash's place: 86. Copy:
  87. Multiple selection and undo names: `0.2`.

## Verified by

- `CommandAvailabilityTests`: the lane table, the Tree items at each bound, Show in Tree
  and Show in People by tab, and a Review row's context menu acting on its own row.
- `CommandShortcutTests`: the new table, with `reserved` revised to match fork 6, and each
  tab's keys still unique.
- Tests for the selection's advance: the next row, the row that stays, the stop at
  Possible Duplicates, and the end of the list.
- `xcodebuild … test`. No engine change, so no Linux run.

**Hand-test (app):**

- On the sample archive, clear a run of names with ⌘↩ and ⌘⌫ alone, then ⌘Z back through
  them. Holding either key decides one row.
- Each lane's keys match the table, the caption names them, and the menu's items grey to
  match. ⌘⌫ deletes in an open sheet's text field, not a row.
- File's Delete reads right on each tab, and shows ⌘⌫ on Artifacts and People.
- The Tree items work and grey at 0 and 8; Show in Tree and Show in People carry the
  person across.
- Review ▸ Merge People… names both records, and either way merges as the pane does.
- The new keys feel right in real use, or fork 6 changes before the merge.

**Settled in the build:**

- **A second press was missed by the spec.** Writes are asynchronous and the row stays
  until one lands, so ⌘⌫ then ⌘↩ in quick succession would confirm the candidate just
  rejected.
- **The selection moves wherever the row went:** the host watches the worklist rather than
  each verb, so a pane's button, a sheet, a merge and another window all move on alike. At
  the end of the list it goes to the placeholder, not back up: rows left above were left on
  purpose.
- **`List` doesn't follow a selection set from outside**, so the worklist scrolls to it.
- **Show in People reads `treeFocus`, not the selection:** with nobody selected the Tree
  still draws someone.
- **A Review row's context menu hides what its lane lacks** rather than dimming it.
- `canOffer` is the rule without the sheet, shared by the in-pane affordances and the
  toolbar.

**Revised on `/code-review`:**

- **Review's keys wait for Review's own write, not for any write.** Refusing while any
  mutation was in flight swallowed a verdict during an import or a wait on another
  process's lock. The command's write is counted (`reviewDecisionsInFlight`), the two
  items are off until it lands, and the menu beeps on a refused press instead of doing
  nothing.
- **Merge People…'s dialog tells a same-named pair apart.** A pair usually shares a name,
  so it read "Keep “Anna Roe”" twice. Each record now carries its subtitle, or its uid
  when that matches too (`distinguishedNames`).
- **Only a row that was there and left moves the selection.** A selection restored at
  launch, before the asynchronous duplicates scan delivers its row, was cleared.
- **A new row gets a new pane** (`.id`), at the top of its scroll view. A reused pane kept
  the last row's offset, and the next could open scrolled past the candidate the keys act
  on.
- A row's context menu asks the rule (`canOffer`) rather than restating the lane table,
  and doesn't resolve the selection it doesn't use. The merge wording is one constant
  (`MergeWording`), the caption one view (`ReviewKeyCaption`).

**From the hand-test:**

- **A fast ⌘⌫ then ⌘↩ decides two candidates, and that is right.** A local write lands in
  milliseconds, well before a second key, so ⌘↩ acts on the candidate the reject brought
  to the top. The guard is for a write that overlaps the press, such as one behind
  another process's lock, which a hand can't produce; `aSecondPressWaitsForTheFirstWrite`
  covers it.
- The sample's names have at most two candidates, so testing the keys and the scroll
  position needed more look-alikes, added with the CLI.

**Shipped 2026-11-11** (merged); **hand-test passed**.

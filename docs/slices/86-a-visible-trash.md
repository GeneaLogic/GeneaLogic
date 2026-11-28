# 86 — A visible trash

Specced 2026-11-26 from the [second UI audit](workstream-5-ui-audit.md) (G7):
[#42](https://github.com/GeneaLogic/GeneaLogic/issues/42), with
[#4](https://github.com/GeneaLogic/GeneaLogic/issues/4) folded in.

**Problem.** The archive's trash is File ▸ Show Trash…, a sheet that is easy to forget.
So deleting an artifact still asks for confirmation, although ⌘Z undoes it and the
trash keeps it across a quit. Finder, Notes and Photos don't ask, but they keep their
trash in view. And a trashed file's entry names the artifact by its title at deletion,
not its current one (#4).

**Layer.** App, plus one engine read (#4). No format change.

## Design forks

1. **The trash is a sidebar row whose detail is the trash** *(agreed 2026-11-26)*. It's a
   Trash row pinned at the sidebar's foot, below People, like Notes' and Mail's
   Recently Deleted. Selecting it shows the trash's Artifacts and Files in the detail
   column, with what the sheet offers today: Restore, Delete Permanently… per row, and
   Empty Trash…. The sheet goes. File ▸ Show Trash… becomes **Show Trash** (no dialog
   follows, so no ellipsis), and it selects the row. Trash is an area like the others
   (`ArchiveTab.trash`), so 85's window state keeps it. It has no ⌘-number: Finder's and
   Notes' trashes have none. Like Review, the row hides while a search is active.
2. **The row shows a count, hidden at zero.** The count is trashed artifacts plus trashed
   files. The icon stays `trash`: a sidebar icon names the place, it doesn't report
   state. *The alternative:* `trash` / `trash.fill`, as the Dock does, which reads as
   decoration in a sidebar. **Recommended: the count.** For the count to stay live, the
   trash listings move into the model and reload with `refresh()`. Today `TrashSheet`
   fetches them itself on appear. Each refresh then also reads `.trash/`: one directory
   listing plus each entry's `deletion.json`. Measure it on a large trash before
   settling.
3. **Every trash-backed delete stops asking.** That means **both** the artifact delete
   and the file detach, since both go to the archive's trash and undo. They become
   **Move to Trash**: Finder's name, and it says where the item goes. ⌘⌫ stays on the
   artifact. Delete Person… keeps its title and confirmation, because a deleted person
   is in-session undo only, until #11 gives conclusions a trash. *The alternative:*
   artifacts only, as #42 is worded. That leaves a file detach asking while a whole
   artifact doesn't. **Recommended: both.**
4. **#4 is fixed at read time in the engine.** `Archive.trashedFiles()` reports the
   artifact's **current** title when the artifact still exists. If the artifact is itself
   in the trash, it uses the trashed artifact's title. Otherwise it uses the title stored
   at deletion. `deletion.json` keeps that stored title as the fallback, so nothing on
   disk changes. *The alternative:* the app swaps the title in. Then the CLI and any
   other reader keep the stale one. **Recommended: the engine.**

## Out of scope

- Auto-deleting after N days: [#2](https://github.com/GeneaLogic/GeneaLogic/issues/2)
  (`0.2`). Its toolbar-button half is answered by the row.
- Deleted persons in the trash: [#11](https://github.com/GeneaLogic/GeneaLogic/issues/11)
  (`0.3`). When it lands, a person shows here too and loses its confirmation (G7).
- Previewing a trashed artifact's contents. Quick Look is
  [87](workstream-5-ui-audit.md) (#43).
- Selecting a restored item. A restore leaves the selection on Trash.

## Verification

- **Engine test** (`swift test`, and Linux for the engine): `trashedFiles()` reports the
  renamed artifact's current title. It falls back to the stored title when the artifact
  is gone, and to the trashed artifact's title when that is in the trash.
- **App tests:**
  - the count follows a move to trash, a restore, an undo, Delete Permanently and
    Empty Trash;
  - Move to Trash runs at once for an artifact and a file, with no pending
    confirmation;
  - Delete Person still confirms;
  - Show Trash selects the Trash area;
  - a window state left on Trash restores to it, and an older build reading that
    state falls back rather than fails.
- **Hand-test:**
  - delete an artifact with ⌘⌫: no dialog, the count appears, and ⌘Z brings the
    artifact back and the count goes;
  - detach a file the same way;
  - restore, Delete Permanently… and Empty Trash… from the Trash detail;
  - rename an artifact after detaching one of its files: the Files entry shows the
    new name (#4);
  - search hides the row; relaunch with Trash selected comes back to Trash;
  - VoiceOver reads the row with its count.

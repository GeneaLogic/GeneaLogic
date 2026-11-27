# 85c — A restored window follows its archive

Specced 2026-11-26 from [#86](https://github.com/GeneaLogic/GeneaLogic/issues/86): the
restore half of what [85b](85b-recents-and-the-welcome-window.md) fixed for Open Recent.

**Problem.** Quit with an archive's window open, move or rename the archive in Finder,
and relaunch. The window comes back saying GeneaLogic can no longer reach the archive,
although its bookmark finds it. `ArchiveModel.load()` holds access to wherever the
bookmark points (`ensureAccess`), then opens the saved path. TextEdit opens the document
where it is now.

**Layer.** App only. No format change, no engine change.

## Design forks

1. **The window's value is rewritten, through the `WindowGroup(for: URL.self)` binding.**
   The window's URL is its identity: the de-duplication key, the window claim, the title
   and the restored value. Writing the binding changes all of them at once, and the next
   launch restores the new path. *The alternative:* open a window at the new URL and close
   this one. That shows two windows for a moment, and it races the coordinator's deferred
   Finder-open. **Recommended: rewrite.**
2. **The move is followed in `ArchiveWindow`, before the container exists.** The window
   resolves its URL first. If the archive moved, it writes the new URL and builds the
   container from that. So the model, the claim, the title and 85's state are all built
   at the new path from the first frame, and `ArchiveModel.url` stays a `let`. *The
   alternative:* follow it in `load()`, and change the model's URL and the claim
   afterwards. That works against `.id(url)`. **Recommended: in the window.**
3. **One resolve, shared with Open Recent.** `ArchiveAccessStore.restore(_:)` does what
   `reopenRecent` does except promote: it skips an archive already held, resolves through
   `resolveRecent`, holds access under the location, and returns the location.
   `reopenRecent` becomes `restore` followed by `promote`. So the rules are 85b's:
   - only a move the bookmark saw, so an archive put at the old path is the one that opens;
   - another spelling of the same folder is not a move;
   - an archive moved to the Trash is not opened there.
4. **A restore doesn't promote.** Relaunching isn't opening, so the moved archive's recent
   takes the old one's place in the list. It doesn't jump to the front. Today
   `resolveRecent` removes the old path and leaves the new one to `promote`; it changes
   to replace the old path where it stands. Open Recent still promotes, so nothing
   changes there.

What stays as it is: an archive the bookmark can't find, or one in the Trash, gives the
window the same "can no longer reach this archive" state as today.

## Out of scope

- An archive moved while its window is open. The engine holds the open folder, and the
  title and the claim keep the old path until it is reopened. File a separate issue if
  the hand-test shows that's wrong.
- A message that says *why* the archive can't be reached (deleted, in the Trash, on a
  volume that isn't mounted).

## Verification

- **App tests** (`RecentsTests`, through `restore` with a test `ArchiveBookmarks`):
  - a moved archive restores where it is, and its access is held under the new path;
  - an unmoved one returns its own URL;
  - a restore keeps the recent's place in the list, and Open Recent still brings it to
    the front;
  - a newcomer at the old path is what restores;
  - an archive in the Trash is not restored there;
  - one already held is left alone.
- **Hand-test:**
  - quit with an archive open, rename it in Finder, and relaunch. It opens, with the new
    name in the title and its tab and selection as left (85);
  - quit again, then relaunch. It restores at the new path;
  - repeat with a move to another folder, and with a move to the Trash, which shows the
    "can't reach" state;
  - with the window restored at its new path, double-click the archive in Finder. The
    same window comes to the front, with no second window.

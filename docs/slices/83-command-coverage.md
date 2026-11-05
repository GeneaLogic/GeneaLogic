# 83 — command coverage

**Draft: not agreed.** Started 2026-11-04 to hold the forks that came out of
[82](82-one-source-for-commands.md)'s hand-test. The full spec is written, and these
forks settled, before 83 is built. From the
[second UI audit](workstream-5-ui-audit.md) (G1's second half, G15):
[#38](https://github.com/GeneaLogic/GeneaLogic/issues/38).

**Scope, from the ladder.** Tree and Review commands, context menus from the same source,
and which frequent commands earn a toolbar item.

## Design forks (recommendations)

1. **One Delete item, or one per object.** Today Artifact ▸ Delete Artifact… and Person ▸
   Delete Person… share ⌘⌫. SwiftUI drops a duplicate key from the later item, enabled or
   not (measured in 82), so a key is attached only while its tab shows, and the dimmed
   item on the other tab shows no ⌘⌫.
   *Recommended:* one item whose label follows the tab, in **File** beside Show Trash…,
   as Finder has Move to Trash (⌘⌫). It keeps ⌘⌫ visible, and it suits 86 ("Delete
   Artifact" with no confirm, "Delete Person…" with one) and G5 ("Delete 3 Artifacts").
   The Artifact and Person menus lose their delete items, and context menus keep theirs.
   Delete File… stays in Selected File, because a file is nearly always selected and
   can't drive the label.
   *Alternative:* Edit, as Reminders does. The system's Delete is already there, and
   replacing it probably means replacing the whole Cut/Copy/Paste/Delete/Select All group
   (to confirm). A specific label also misleads there, because with the cursor in a text
   field Edit ▸ Delete acts on the selected text.
   *Alternative:* keep two items, as 82 shipped.
2. **What ⌘↩ and ⌘⌫ act on in Review.** 82's fork 4 agreed "⌘↩ accepts and ⌘⌫ declines,
   whatever the lane", which missed that not every lane has one target. The names lane
   shows a Confirm for each candidate, the facts lane a Record for each suggestion, and
   the duplicates lane two Keep buttons, which is a choice rather than a yes. Only the
   relationships lane has one.
   *Recommended:* the keys act on the top row, and the duplicates lane has no ⌘↩. A
   decline on Review also competes with fork 1's ⌘⌫: either the Delete item gives up its
   key on Review, or decline takes another key.
3. **Confirm's styling.** A prominent button reads as the default button, but Return
   doesn't activate it, and several can be on screen.
   *Recommended:* only the top candidate's button is prominent, and it carries ⌘↩, as the
   transcript editor's Save does. Depends on fork 2.
4. **A Review menu.** The audit left this open: a menu of its own, or items in Artifact
   and Person.
   *Recommended:* a small Review menu, because its verbs act on a suggestion, which is
   neither an artifact nor a person. Stable titles (Accept Suggestion, Decline Suggestion),
   since the HIG says to always show the same items, plus This Is Somebody New… and
   Refresh (⌘R).
5. **Tree's commands.** *Recommended:* no Tree menu. Card verbs act on the card that was
   clicked, and Tree has no selection for a menu bar item to act on, so they stay in the
   context menu. The depth steppers go in View, and Show in Tree and Show in People in the
   Person menu.
6. **Shortcuts for the Artifact and Person menus, and ⇧⌘N.** The HIG asks for custom
   shortcuts on "only the most frequently used" commands. One key per role can be shared
   across tabs, as ⌘⌫ is. *Starting point, to agree against real use:* ⌘E Add Event… /
   Add Fact…, ⌘L Add Place…, ⌘K Add Person Mentioned… / Add Relationship…, ⌘T Edit
   Transcript…. ⌘E and ⌘T are standard keys, whose actions mean nothing here (no find
   panel, no styled text). ⇧⌘N stays provisional, and is settled in this table. It has
   the HIG on its side: Shift complements a related shortcut, here ⌘N New Archive.

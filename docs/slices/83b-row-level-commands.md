# 83b — row-level commands

Specced 2026-11-11 from [83](83-command-coverage.md)'s fork 11 and the
[second UI audit](workstream-5-ui-audit.md) (G1's last part):
[#38](https://github.com/GeneaLogic/GeneaLogic/issues/38).

**Problem.** The verbs on rows inside the panes (a mention's Resolve… and Unlink, a
metadata entry's Apply…, a suggestion's Record and Edit…) are hand-built buttons that
spell their own titles, and right-clicking one of those rows does nothing. Some have
already drifted: a suggested relationship is "Record" / "Not This" in the inspector and
on a person, and "Record Relationship" / "Not This Relationship" in Review. A non-top
candidate's Confirm takes `acceptSuggestion`'s title but acts on a different subject.

**Layer.** App only. No format change and no engine change.

## The rows and their commands

Every verb on these rows becomes an `ArchiveCommand` with its own `CommandSubject`. The
row's buttons and its new context menu both draw from it (fork 1). The menu bar gets none
of them, because a pane's rows have no selection for a menu item to act on (82).

| Row | Where | Commands (pane title, if it differs) |
| --- | --- | --- |
| A mention | inspector | Resolve… (Re-resolve… on a stale link) · Show in People · Unlink · Edit Mention… · Add Fact… · Add Relationship… · Remove Mention |
| A metadata entry | inspector | Apply… |
| A suggested fact | person, Review facts lane | Record Fact (Record) · Edit… (Apply… when it can't be recorded as-is) |
| A suggested relationship | inspector, person | Record Relationship (Record) · Not This Relationship (Not This) |
| A source | person | Show Artifact · Add as Name · Unlink |
| A relationship | person | Show in People · Replace Person… · Remove Relationship |
| A candidate | Review names lane | Confirm · Reject |

- **Subjects carry ids and the row's state, not the row.** `.mention` has the artifact,
  the `localRef` and the link state (none, linked, stale), and whether anyone else is
  named; a suggested fact has its person, its id and whether it can be recorded as-is. So
  availability stays a pure function, as `ReviewTarget`'s lane made Review's. None of the
  row values is `Hashable`, and the view that runs a command looks its row up by id.
- **Availability follows the row's state**: Resolve… only without a live link, Unlink only
  with one, Add Relationship… only with someone else named, Record Fact only on a fact
  that can be recorded as-is, Add as Name only when it isn't already a name, Replace
  Person… only on a dangling relationship, and the jumps only to a record that exists. A
  candidate waits on a Review write in flight, as the keys do.
- **A row command belongs to no tab.** It is drawn only on its row, which is on screen,
  and it owns no key, so the tab check (which exists for the menu bar) adds nothing. A
  suggested fact's commands then serve the person pane and the Review lane alike.
- **Running:** commands that write (Unlink, Record, Not This, Remove, Confirm) run in the
  model. Those that open a sheet go through `pendingCommand` to the pane that drew the row
  and owns the sheet, routed by the subject's artifact or person as today's verbs are.
- **Not commands:** Why? (a disclosure), the nature menu on a parent-child row (a
  picker, as 82 left the file Role picker), and a mention's Restore buttons (83).

## The context menu

- **Order:** the row's decision (Resolve…, Record, Confirm), then its jump, then its
  edits and adds, then a divider and the destructive verbs (Unlink, Remove, Not This,
  Reject).
- **Hides what the row's state lacks** rather than dimming it, as 83's Review row menu
  does.
- **One list per row**, a function of the subject, which the context menu draws and the
  tests pin. The buttons stay where they are and read the same commands.
- **Titles:** the menu uses the full title. A pane keeps its short one where the heading
  already says what it is and the inspector is narrow (`paneTitle`, as Add Person… under
  *Persons Mentioned*). Review's relationship lane already reads the full titles.

## Design forks (agreed 2026-11-11)

1. **`ArchiveCommand` cases, or verbs local to the row.** **Agreed:** cases, about
   twenty. 82's invariant is that nothing else spells a command title, the sweeps over
   `allCases` then cover them, and three of these rows sit on two or three surfaces,
   which is where the titles drifted.
   *Alternative:* a row-local `RowVerb` (title, symbol, role, action) that the row's
   button and context menu share. Cheaper, and enough for one row, but the same verb on
   two surfaces is spelled twice again.
2. **Rows that only edit and remove** (names, facts, events, places, a mention's recorded
   facts: `AssertionRow`). **Agreed:** out. Both verbs are already on the row (a tap
   and the trash, with ⌘Z behind it), and a context menu would need a subject per store
   for two generic verbs. Raise it again if the hand-test misses it.
   *Alternative:* in, with Edit… and Remove from a subject per store, so every pane row
   answers a right-click.
3. **The candidate cards.** The ladder didn’t name them. **Agreed:** in. Their
   buttons borrow `acceptSuggestion`'s title while acting on their own candidate, which
   is the mismatch this slice exists to remove, and a card is a row of the pane like the
   rest.
   *Alternative:* leave them; only the top card's verbs have a key, and those are 83's.
4. **The jumps in the context menu** (Show in People, Show Artifact). **Agreed:** in.
   A row's menu without the row's main action reads as incomplete, and Finder and Mail put
   Open first.
   *Alternative:* verbs only; the chip and the title link stay the only way across.

## Out of scope

- Keyboard access to pane rows, which have no selection: 89 (Full Keyboard Access).
- `AssertionRow`’s Edit… and Remove (fork 2).
- Undo names that follow the command (G13) and multiple selection (G5): `0.2`.

## Verified by

- `CommandAvailabilityTests`: each row command against its subject's states (a mention
  unlinked, linked and stale; a suggested fact that can and can't be recorded as-is; a
  dangling relationship), and each row's list in order with what its state hides.
- The sweeps already there cover the new cases: a title for each, no shortcut, and none
  available with no archive or under a sheet on the menu bar's rule.
- `xcodebuild … test`. No engine change, so no Linux run.

**Hand-test (app):**

- Right-click each row kind in the table. The menu shows the row's verbs in order, hides
  what the row's state lacks, and each item does what the row's button does.
- A sheet opened from a row's menu opens in that pane (Edit Mention…, Apply…, Edit… on the
  person pane and in Review's facts lane), and ⌘Z undoes each write.
- A stale mention shows Re-resolve…, and a dangling relationship Replace Person…, in both
  places.
- The inspector at its narrowest still fits its rows' buttons.

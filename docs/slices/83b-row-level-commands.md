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
| A source | person | Show in Artifacts · Add as Name… · Unlink |
| A relationship | person | Show in People · Replace Person… · Remove Relationship |
| A candidate | Review names lane | Confirm · Reject |

- **Subjects carry the row's state**, so availability stays a pure function, as
  `ReviewTarget`'s lane made Review's: `.mention` has the link state (none, linked, stale)
  and whether anyone else is named; a suggested fact, whether it can be recorded as-is.
- **Availability follows the row's state**: Resolve… only without a live link, Unlink only
  with one, Add Relationship… only with someone else named, Record Fact only on a fact
  that can be recorded as-is, Add as Name… only when it isn't already a name, Replace
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
4. **The jumps in the context menu** (Show in People, Show in Artifacts). **Agreed:** in.
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

**Settled in the build:**

- **Writes run in the model; sheets go to the pane** that drew the row, which claims a
  row command by its subject (`claimPendingCommand(where:)`).
- **A row's inline verb shows only while its row's state offers it** (`RowCommandButton`),
  as the panes did by hand, so the button and the menu agree by construction.
- **A candidate's verdict counts as a Review decision**, so the keys wait for it.
- **Where the menus sit:** a mention's on its name, statement and resolution, not its
  recorded facts, which are rows of their own; a metadata entry's on its key and Apply…,
  not its value, which is selectable text with its own Copy.
- **Show in Artifacts**, not Show Artifact, to pair with Show in People.

**Revised on `/code-review`:**

- **A subject carries its row's value** (the mention, the suggestion), compared by value
  and hashed by the row's identity, since the values are only `Equatable`. The build
  looked a suggestion up again on each click, which repeated the pane's whole reload on
  the main actor and could miss; and found a mention by `localRef`, which a repeated ref
  makes ambiguous (79b), so Edit Mention… could open another row's.
- **A suggestion's Record and Not This count as Review decisions** wherever the row is.
  Recording Review's top suggestion from its row and pressing ⌘↩ before the write
  landed recorded the fact twice. They dim while one is in flight, and the menu keeps
  the item rather than changing shape.
- **In-pane surfaces don't grey under a sheet**: the candidate cards' buttons asked the
  menu bar's rule, and `canOffer` no longer reads the modal state at all, so a sheet
  opening doesn't redraw every row.
- Review's facts lane opens Edit… in `ReviewCommandHost`, which already hosted that
  sheet, rather than a second copy in the pane. The row kinds are one `.row(RowKind)`
  case, so a switch names them once. Add as Name… opens an editor, so it has an
  ellipsis. A state's verb is one explicit override for both titles.

**From the hand-test:**

- **A file row had no context menu**, only its ⋯ button. The spec's inventory missed it,
  because the ⋯ menu already drew from the source. The row now carries the ⋯ menu's
  contents on a right-click, Role picker included, from one shared view.
- **Review's row menus read as having holes**: Suggested Facts showed only Accept
  Suggestion, Possible Duplicates only Decline Suggestion. The lanes lack those verbs on
  purpose (83's fork 2: a fact suggestion has no recorded decline, which would be a format
  change, and a merge has to say which record survives). What made it jarring was the
  menu bar's generic titles. A row's menu now says its lane's word (Record, Not a
  Duplicate), names the candidate on a name row (Confirm Ann Roe), and puts the decision
  first and the declining verb after a divider. The menu bar keeps its stable titles.
- **The menu bar names what Review's keys will do**, revising 83's fork 4. Its two items
  read Confirm Ann Roe ⌘↩ and Reject Ann Roe ⌘⌫, Record or Apply…, Not a Duplicate, by the
  selected row, and Accept Suggestion and Decline Suggestion, dimmed, where there's
  nothing for the key to decide. Fork 4 cited the HIG's "always show the same set of menu
  items" for fixed wording, but that rule is about the set. The HIG asks a title to
  clarify its target ("Undo Typing"), and the keys write a verdict on a row the sidebar
  doesn't spell out. A write in flight leaves the title as it was.
- **Where this slice departs from the HIG, on purpose:** "an app's menu bar menus list
  all the app's commands, including those in various context menus." A pane's row verbs
  have no menu-bar item (82), because the rows have no selection for one to act on. Each
  has an in-pane button, which meets the same page's "available in the main interface,
  too."

**Shipped 2026-11-12** (merged); **hand-test passed**.

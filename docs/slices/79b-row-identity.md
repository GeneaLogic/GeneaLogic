# 79b — Row identity

**Problem.** The editable lists in the artifact inspector and the person detail are
identified by position (`ForEach(…enumerated(), id: \.offset)`, or a `"person#\(index)"`
id), and their verbs address the element by the index the row was drawn at. Two things
go wrong:

- **State follows the slot, not the row.** Delete a mid-list row and SwiftUI keeps the
  deleted row's view, now showing the next row's content. Whatever state it held goes
  with it. Expand **Why?** on the second of three resolved mentions and delete the first:
  the reasoning now shows under the third. A keyboard user who removes a row with Space
  is left focused on the next row's trash, so a second Space removes that one too.
- **A shifted index writes the wrong element.** Each write's bounds check guards only
  against an index out of range. An index that is still in range but points at a
  different element (another writer, or an undo, since the row was drawn) removes or
  overwrites the wrong row.

**Layer.** App, plus one additive engine change: `Hashable` on five model types (fork 1).
**No format change**: nothing new is stored, and round-trips are untouched.

## The sites

| List | Row identity today | Verbs addressed by index |
| --- | --- | --- |
| Events, Places (`EventsPlacesSection`) | `\.offset` | remove |
| Persons Mentioned (`PersonsMentionedSection` → `PersonMentionRow`) | `\.offset` | remove mention |
| A mention's recorded facts (`MentionRecordedFacts`) | `\.offset` | remove; edit (`RecordedFactEditorSheet`) |
| Names (`PersonDetailView`) | `\.offset` | remove; edit (`PersonEditorSheet`) |
| Facts timeline (`PersonDetailView.factRows`) | `"person#i"`, `"<relationship>#i"` | remove; edit (`FactEditorSheet`, person and couple) |
| Stated relationships in the mention sheet (`PersonMentionEditorSheet`) | `\.offset` | remove (sheet-local, so never stale; identity only) |

## Design forks

1. **What identifies a row with no stored id** (events, places, names, facts, stated
   edges). **Recommended: its value, plus its occurrence among equal values** (the first
   `Event` equal to X is `(X, 0)`, the second `(X, 1)`). It needs no bookkeeping and
   survives every reload, because it is derived from what is shown. It needs `Hashable`
   on `Event`, `Location`, `PersonName`, `PersonFact` and `RecordedFact` (synthesized;
   every field is already `Hashable`). The cost: an edited row is a new row to SwiftUI.
   The view that held keyboard focus is gone when the editor closes, so focus would fall
   back to the start of the pane. That is fixed explicitly (below). **Alternative:
   in-memory ids**, as the ROADMAP line put it: a UUID per element on the loaded copy.
   Every write reloads the record, so the ids have to be carried across each reload by
   matching old elements to new, which is the same value comparison plus state to keep.
   And they cannot address a write, because the write's closure gets a freshly decoded
   record that has no ids.
   **Mentions** use `localRef`, plus the occurrence. The schema calls it record-local,
   but nothing rejects a duplicate, and `ForEach` must never see two equal ids.
2. **How a write finds its element.** **Recommended: the index is a hint, checked against
   the value.** Take the element at the hint if it still equals what the row showed,
   else the first equal element, else do nothing. Mentions match by `localRef` instead of
   by value, so a mention whose facts changed meanwhile can still be removed. Integrity's
   stale-edge repair already works this way (re-identified by its endpoint rather than
   trusted by index). One helper on `Array`, used by every remove and edit above. The edit
   sheets already carry `existing`, which is the value to check. **Alternative: value
   only** (the first equal element). Of two equal rows it can remove the other one, which
   reorders the list for no reason.

## Focus after an edit

*(Added after the forks were agreed: it is fork 1's cost, and the user asked for it in
the slice.)* When an edit is opened from a row with keyboard focus, and changes the
value, focus returns to the row that now shows the written value. That covers names,
recorded facts, person facts and couple facts. A mention keeps its `localRef` through
an edit, so its row survives and needs nothing. The target comes from the **committed**
record: `updateMetadata`, `updatePerson` and `updateRelationship` take an optional
`committed` callback with the record as the write left it. Focus moves once the reload
after the commit has shown the row and the sheet has finished closing, in either order,
because focus set while the sheet is still closing is lost. A mouse-opened edit asks for
nothing, so no focus ring appears that wasn't there.

Judgment calls, not forks: the identity helper and the position helper live in one
`Support/` file, with `index` still on each keyed row for the hint. `FactRow`'s sort
tiebreak becomes store order (source, then index) rather than comparing id strings, which
put `person#10` before `person#2`. A write that finds no match does nothing, as an
out-of-range index does today.

## Out of scope

- **Saying so when an edit finds nothing to write to.** The sheet closes and the edit is
  dropped, as with an out-of-range index today. Rare (another writer touched that row
  while the sheet was open), and surfacing it needs the write to report back: the audit
  (81+).
- **Read-only lists** (Review's recorded facts and relationship evidence, and the
  `#rf<index>` ids of fact suggestions). Nothing in them is addressed by that index, and
  their rows hold no state.
- **Integrity repairs that carry a fact index** (`personFactSupport`,
  `relationshipFactSupport`). The index comes from the engine's report, and the repair
  only removes a link id that dangles wherever it is.

## Verification

- **New app tests** for the helpers: equal values get distinct ids; removing a middle
  element leaves the other rows' ids unchanged; the position helper takes the hint,
  follows a shifted element, and returns `nil` once it's gone; the focus return waits
  for both the reload and the close, in either order, and drops a request whose write
  found nothing. The existing app suite stays green.
- **Engine suite and Linux** (`scripts/linux-test.sh`), because the model types change.
- **Hand-test (the user)** on the sample archive:
  - Expand **Why?** on a middle resolved mention, then remove the mention above it. The
    reasoning stays with its mention.
  - With Full Keyboard Access on, Tab to a middle event's trash and press Space. Focus
    does not land on the next row's trash.
  - Add the same place twice and remove one, then undo. Remove a middle event, place,
    mention, recorded fact, name and person fact, and undo each.
  - Edit a middle name, recorded fact, person fact and couple fact. The edit lands on that
    row, and Edit ▸ Undo names it as before.
  - With Full Keyboard Access on, do those edits from the keyboard (Tab to the row,
    Space, change a field, Return). Focus comes back to the edited row. Opened with the
    mouse, no focus ring appears.
  - In the mention sheet, remove a middle stated relationship.

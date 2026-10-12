# 44g — repairing dangling references

**44g ✅ — repairing dangling references** (user-reported off 44e, scoped after shipping it).
44e made dangles findable; 44g makes them fixable, in three places. **The reported bug:** a
resolved mention whose person was deleted still drew the live "→ person" chip, which navigated
to the People tab and selected nothing. It now reads as a muted **Missing person** badge plus
**Re-resolve…**, which *substitutes* the person (unlink-stale + link-new, one grouped ⌘Z). The
same row also conflated existence with name resolution, so an existing-but-nameless person read
"Unknown person" — the distinction slice 43 drew for relationship rows, unfixed one file over.
**Relationships** gained **Replace Person…** (rewrite the endpoint the missing uid identifies,
so §4.5 survives); the person **Sources** row deliberately gets no substitution, since
repointing a citation at a different document would falsify the evidence (§2.3) — Unlink is the
honest repair there. **The integrity panel** gained per-row **Reveal** + **Remove Stale
Reference**, every case routed through an existing undoable mutation. **Reveal is gated to the
3 of 7 kinds a view actually draws** (`isRevealable`) — a stale `supportedByLinks` citation is
rendered nowhere and a mention-gone link has no row, so revealing them would dismiss the panel
onto a normal-looking page. **Two sheet-isolation findings, both live:** ⌘Z can't reach the
archive window's `UndoManager` while the panel is up (the step is on the stack; the help text
says so), and the model's alert channel is bound behind the sheet, so the panel owns a
sheet-local alert and drains `actionError` into it. Engine: one accessor,
`evidenceLink(withID:)`. **Plus the `PersonPickerSheet` consolidation** (same branch): adding
`ReplacePersonSheet` made four hand-written copies of one sheet, already drifted in action verb
and empty-state rule, so the shell — search state and reload, sizing, the `PersonPickRow` list,
empty state, Cancel footer — moved into one view with two `@ViewBuilder` slots (an accessory
above the search field, a footer-leading action). Each sheet keeps only its wording, its extra
controls and its select handler; −247 lines. `TreeTab`'s focus picker stays as-is: it's a
popover, and already reuses `PersonSearchField`/`PersonPickRow`.

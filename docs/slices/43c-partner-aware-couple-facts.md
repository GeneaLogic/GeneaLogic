# 43c — partner-aware couple facts

**43c ✅ — partner-aware couple facts** (the "Other person…" partner selector, deferred from
43b during testing). Closed the two gaps 43b left: **(a)** the Add-Fact "With" picker listed
only a person's *existing* couple partners (a marriage with a not-yet-partner meant creating the
relationship first); **(b)** a marriage from **Suggested Facts** (the 42c from-evidence path)
recorded as a spouse-less *person* fact. Fixed with one richer selector: the "With" control is a
`Menu` of existing partners **plus "Other person…"**, which opens a new `CouplePartnerPickerSheet`
to pick any existing person **or mint a brand-new spouse inline** (given + surname). The
from-evidence path now offers couple types (a suggested marriage becomes a proper couple fact) and
**lists the source record's other linked people as spouse candidates** ("Named on this record"
section in the "With" menu), defaulting to the one the record marks with the `.spouse` mention role
(else the record's only other person, else the first existing partner). (First cut auto-defaulted
*only* on `others.count == 1` and so never fired for real marriage records, which name the couple
**plus** parents — caught in hand-testing; listing candidates + a role-aware default is the fix, and
role is used only to pick the default, never to filter the menu.) **Open
sub-decision resolved → create-new inline** (chosen over pick-existing-only). Three grouped-undo
model methods (`recordCoupleFact`, `createPersonRelateAndRecord`, plus the plain `updateRelationship`)
route per a `CouplePartnerChoice` — one ⌘Z removes the fact + the relationship (+ the new person) it
created; suggestion dedupe extended to couple facts. App-layer over the landed `updateRelationship` +
`addRelationship`/`link` engine surface — **no format change** (201 macOS / 198 Linux + 6 CLI
unchanged). Every flow live-verified (not-yet-partner, inline create, default-to-partner, symmetric
projection, grouped undo) + the from-evidence candidate menu on the real archive.

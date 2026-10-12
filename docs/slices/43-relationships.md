# 43 — relationships

**43 ✅ — relationships** (assert parent-child / couple, show a person's relatives,
remove). **Format change landed:** the **`facts` array on `Relationship`** (couple
marriage/divorce/annulment), a strict *additive* widening — a pre-43 sidecar with no
`facts` key decodes to `[]`, so **no schema bump**. **Sub-decision resolved: reuse
`PersonFact`** (GEDCOM X's one-`Fact` shape; least new format surface), with `FactType`
gaining `Divorce`/`Annulment` + a `coupleCases` subset. Engine: `updateRelationship`
(couple-fact write path) + `relationship(withID:)`, Linux-verified (201 macOS / 198
Linux + 6 CLI). **Format spec (`genealogic-archive-1.0.md`, shipped inside every archive)
updated in both copies** — §6.4 now documents `facts` + the `person1`=parent convention —
and a standing **`SchemaSpecTests`** guard added (both copies byte-identical; every record
field documented in its own §-section) so a future format change that skips the spec fails
CI. App (People-tab detail): a **Relationships section** with a
**perspective-based** `RelationshipEditorSheet` (pick Parent / Child / Partner *of this
person* — the §4.5 `person1`=parent convention is mapped for you) over the searchable
person list; each relative row shows the role from this person's view (icon + Parent /
Partner / Child), taps through to that person (cross-tab `navigateToPerson`), and
removes undoably (create↔delete + restore↔redelete ping-pong). A dangling relationship
(other person deleted, §2.3 no cascade) reads "Unknown person," nav disabled but remove
live; an existing-but-unnamed relative reads "Unnamed person" and stays navigable
(distinguished by *existence*, not name — a /code-review fix). Shared `PersonPickRow` +
`PersonSearchField` extracted (de-duped from the resolve-mention sheet). /code-review
(8-angle) clean after the fixes; every flow live-verified. **Couple marriage/divorce
*fact editing* is split to slice 43b** (reusing the 41b fact editor via the landed
`updateRelationship` engine path) — the format field is here, the editing UI is next.

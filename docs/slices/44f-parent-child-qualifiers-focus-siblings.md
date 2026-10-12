# 44f — parent-child qualifiers (adoption / step / foster) + focus siblings

**44f ✅ — parent-child qualifiers (adoption / step / foster) + focus siblings.** Shipped as
planned below, with these resolutions. **Absence means *unspecified*, never "biological"** —
a researcher who hasn't established the nature of a link must not have one asserted on their
behalf, so `BiologicalParent` exists to be claimed deliberately and an unqualified link draws
as an ordinary solid line. **Set at both creation and afterwards** (user's call): the Add
Relationship sheet grows a "Nature" picker for Parent/Child, and every parent/child row on the
People tab carries an always-visible nature menu (showing "Unspecified" when unset — both
discoverable and honest), routed through a new undoable `setParentChildQualifier` that
*replaces* rather than appends, since the qualifiers are mutually exclusive answers to one
question. **Tree shows a dashed drop** (user's call) for an explicitly non-biological link and
nothing else, so the drawing never implies a nature the record doesn't claim; the precise
qualifier stays on the People tab. `FactType` gained the five GEDCOM X parent-role cases plus a
`parentChildCases` subset — and `personCases` had to *subtract* it, or the person fact editor
would have offered "AdoptiveParent" as a birth-type fact (a partition test now pins all three
subsets as disjoint and covering). **Siblings:** a `TreeProjection.hourglass(includeSiblings:)`
pass placed last, so siblings take slots to the right of the focus and its partners; they are
**bare nodes** (no partners, no descendants — expanding them is what turns a direct line into a
cousin-fanning chart) and require `ancestorDepth >= 1`, since a sibling is only drawable once
the shared parent has a slot to hang from. **Half-siblings are included**, grouped by whichever
*placed* parents they actually share, so they hang from that one parent rather than implying a
shared other parent. **Two fixes live testing forced:** (1) `.capitalized` rendered
"AdoptiveParent" as **"Adoptiveparent"** — the vocabulary label prettifier now splits camelCase
before title-casing (a latent bug for any camelCase vocab value, not just these); (2) a
half-sibling's single-parent bus **fully contains** the full siblings' bus at the same height,
merging into one line so you couldn't tell which parent a child hung from — precisely what the
half-sibling grouping exists to show. Child-buses are now assigned **lanes** within the row gap
when a generation has more than one. Spec updated in **both** copies (the `facts` row said "a
couple's event", which the parent-child use widens). 251 macOS / 248 Linux + 6 CLI.
*Original plan follows.* **(a) Qualified parenthood:** there
is currently **no way to record an adoption** — `RelationshipType` is `parentChild`/`couple`
with no qualifier field, and `FactType` has no adoptive/step/foster/biological case; a
repo-wide search finds the concept nowhere in the model, docs, or spec. The **standards-aligned
fix needs no format change**: GEDCOM X models these as fact types on the *parent-child*
relationship (`AdoptiveParent`, `BiologicalParent`, `StepParent`, `FosterParent`,
`GuardianParent`), and `Relationship.facts` already exists (slice 43) and already rides
parent-child records — it is simply always empty for them today. So: add the known cases to
the open `FactType` vocab (exactly as 43 added `.divorce`/`.annulment`), write them via the
landed `updateRelationship`, offer them in the relationship editor, and render the qualified
edge (dashed / labeled) off slice 44's `Union.parentEdges`. Additive vocab only — no schema
bump, no new fields. **(b) Focus siblings:** slice 44's ancestor side is the **direct line
only**, so the focus's own siblings are not drawn (they are the parent union's *other*
children). That is the conventional hourglass, but siblings are a common want; it is a small
projection change (render the focus's parent union's remaining children at generation 0)
gated on it not blowing up the width. Both are pure follow-ons — the tree renders correctly
without them.

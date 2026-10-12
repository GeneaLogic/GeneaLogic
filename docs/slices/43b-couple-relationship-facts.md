# 43b — couple relationship facts

**43b ✅ — couple relationship facts** (add/edit/remove a couple's marriage / divorce /
annulment date+place) over the `updateRelationship` engine path landed in 43. **UX
reshaped during testing → a *unified Facts timeline*:** rather than editing couple facts
beside the partner row (discoverable-poorly, and the person's Facts list read as missing
their marriage), a couple's marriage/divorce is now **projected into the person's Facts
section**, date-sorted with their own facts and tagged "· with \<partner\>". Storage is
unchanged — the couple fact still rides `Relationship.facts` (§4.5), this is a read
projection + type-driven routing: the single **Add Fact…** editor writes a person type to
`Person.facts` and a couple type (`FactType.coupleCases`) to a chosen partner's
`Relationship.facts` (with a "With" partner picker; recording a marriage needs the partner
relationship to exist first). Consolidated all fact editing into one `FactEditorSheet`
(person + couple + the 42c from-evidence promotion), added `FactType.personCases` +
`ArchiveModel.updateRelationship` (undoable snapshot-restore); no format/schema change.
/code-review (8-angle) clean bar 4 minor fixes (partner-options caching, a sheet-sizing
cap that clipped the tall from-evidence mode, a stale doc, an optional-partner header).

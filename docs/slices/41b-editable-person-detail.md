# 41b — editable person detail

**41b ✅ — editable person detail.** `PersonDetailView` is now editable: the Names
and Facts sections gain an Add affordance, tap-a-row-to-edit, and a per-row remove,
via a new `PersonEditorSheet` (`.name`/`.fact` mode, add or edit-prefilled — NameType/
FactType pickers over `knownCases`, the EDTF-aware date field on facts). Every change
commits through a new `ArchiveModel.updatePerson(of:actionName:_:)` — the person twin
of `updateMetadata`, undoable via a **snapshot-restore** ping-pong (`registerPersonEdit`),
edits by bounds-checked array index. Altitude/cleanup: `AddAffordanceLabel`, `LabeledField`,
`AssertionRow` (generalized with an optional `onEdit`) extracted to shared `Views/` files;
a shared `EDTFDateGloss`; a shared `OpenVocabulary.pickerOptions(including:)`; name/fact
`displayName` extensions. /code-review (finder agents) fixed one real bug (open-vocab picker
anchored on the live selection dropped an `.unknown` value — now anchored on the record's
original type) + three cleanups. No engine change (193/190 + 6 CLI unchanged); live-verified.

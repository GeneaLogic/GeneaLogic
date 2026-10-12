# 42c — record a person fact *from* linked evidence

**42c ✅ — record a person fact *from* linked evidence** (human-confirmed, **never**
auto): a **Suggested Facts** section in `PersonDetailView` surfaces the linked
artifacts' evidence — each linked artifact's `Event`s (deduped per artifact) and the
resolved mention's `ageAsRecorded` — as rows with an **Apply…**. Apply opens the
`PersonEditorSheet` in a new **`.factFromEvidence(FactSuggestion)`** mode (a read-only
Evidence/Source context header + the §2.3 caveat subtitle; type/date/place **prefilled**
from the evidence — an event's type→`FactType(parsing:)`, its date/place carried over;
a recorded age prefills type `.birth` but an **empty date**, so the human derives the
year rather than the app auto-computing it). Save appends a `PersonFact` with
**`supportedByLinks: [link.uid]`** via the shared undoable `updatePerson` (⌘Z removes
it), and the Facts row now shows a **"cited by N source(s)"** count so the citation is
visible. Deliberately *not* auto-copy (§2.3, the conclusion-layer analog of the
scan-date trap): an artifact's events aren't scoped to a mentioned person, and a
recorded age isn't a birth fact until a human derives + asserts it. Shared assembly:
`loadLinkedEvidence()` builds the Sources **and** Suggested-Facts rows in one pass over
the links (one full-record read per artifact, cached). No engine change (`updatePerson`
already carries `supportedByLinks`); /code-review clean (one applied idiom cleanup — a
stable `FactSuggestion.id`), every flow live-verified (event + age suggestions, apply →
prefilled sheet → cited fact, ⌘Z undo, empty-date age path). Pairs with the
facts/relationships work around slice 43.

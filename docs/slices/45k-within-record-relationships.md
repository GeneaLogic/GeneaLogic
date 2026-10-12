# 45k — within-record relationships

**45k ✅ — within-record relationships** (spec + model + match + CLI + app). **A format
change** — one of the mini-phase's two, with **45m**'s dismissal record (45j's fork
moved that one out of "no slice below changes the schema"; this entry claimed to be the
last format change until then). Raised by 45g, parked as a candidate until
2026-07-30, when the archive produced the case that scheduled it: the Sidney Feldberg
death certificate states his parents, both parents are resolved to person records, and
nothing in `conclusions/` says so (→ **45l**, which is what this unblocks).
**Problem:** `PersonRole` conflates two questions — *who is this record about?* and
*what relation does this person bear to that focus?* — and one tag per mention cannot
answer both. A marriage record is where it breaks: the parties are the record's focus
**and** each other's spouses. 45g's convention (two `spouse` mentions, no `subject`; now
in the spec) carries more than tagging both `subject` would, but leaves the satellite
question unanswerable — *which* of the four parents on a register belongs to *which*
spouse is simply not expressed, and the matcher reads all four best-of because
positive-only makes a wrong guess free. That is a workaround for a missing edge, not an
answer. The fix is what every mature model does: state relationships **between
mentions** explicitly rather than inferring them from per-person roles.
**Layer:** spec in **both copies** + `GeneaLogicModel` + `GeneaLogicMatch` + CLI + the
app's mention editor. The open-vocab and round-trip rules apply, and the roles on disk
today must keep loading and meaning what they mean now.

**Three forks settled 2026-07-30, before any code:**
- **(a) An artifact-level array, not per-mention lists.** `mentionRelationships` on
  `Artifact`: each entry a pair of mention `localRef`s plus an open `RelationshipType`
  — the evidence-layer mirror of `conclusions/`'s `Relationship`, and **not** GEDCOM's
  `FAM`/`HUSB`/`WIFE` shape, so `couple` stays symmetric and same-sex spouses need no
  second spelling. One edge is **one record**: a per-mention `relatedTo` list stores
  every edge twice and lets the two halves disagree, which is a validation-and-repair
  burden the archive would then own forever. Same directional convention as §4.5
  (`parent-child`: ref1 is the parent). Additive decode (`decodeIfPresent` → `[]`), no
  schema bump.
- **(b) `PersonRole` stays, meaning exactly what it means today.** It answers the other
  question — informant, witness, registrar, declarant — and every record on disk uses
  it. The edges are additive; nothing is migrated, and no role changes meaning.
- **(c) The matcher prefers a stated edge and keeps the inference as fallback.**
  `Matcher.relational` drops its `principalRole` star inference **only for records that
  state their edges**; an edge-less record must score exactly as it does today, or the
  slice silently re-scores the whole existing corpus while claiming to be additive.
  *As built (and corrected in `/code-review`), the unit is the **mention**, not the
  record: the inference is dropped only for a mention the edges actually place in the
  relation being scored, so a half-annotated register doesn't cost the un-annotated
  spouse a dimension. 45l's fork (c) inherits this reading.*

**The refs are `localRef`s, so two existing rules have to see them:** `nextLocalRef`
must not reissue a ref an edge names (44c/45c's trap, a third time), and
`findDanglingReferences()` must report an edge whose mention was removed — a dangling
reference is a dangling reference.
**Out of scope:** deriving any conclusion from these edges (**45l**); bulk edge editing
beyond the mention editor. **Verification:** round-trip test for the new type (the
non-negotiable), decode tests that a pre-45k artifact loads with `[]` and that an
`.unknown` type round-trips verbatim, `nextLocalRef` + dangling-sweep tests for a removed
mention, `SchemaSpecTests` for both spec copies, and matcher tests that a stated edge
beats the inference **while an edge-less record scores unchanged**. Linux-verified.
**Hand-test:** state the two parent edges on the Sidney death certificate, confirm
`genea show` and the mention editor round-trip them, and the real archive still opens.

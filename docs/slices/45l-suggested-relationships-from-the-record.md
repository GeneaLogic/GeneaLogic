# 45l — suggested relationships from the record

**45l ✅ — suggested relationships from the record** (engine + app). Shipped with all four
forks intact and fork (a) widened by one surface (below). 609 macOS engine tests (+27),
CLI untouched (133), app builds. **The hand-test is the whole slice in one line:** the
archive proposes exactly two edges — Szlama Feldberg and Tauba Pelc as Sidney's parents,
both off the death certificate's stated edges — and *nothing else* across the other 19
records, because the relationships already on file are subtracted. Both were confirmed on
the real archive and wrote the record fork (d) specifies.
**Two things the hand-test changed**: the person pane gained the third surface, and the
mention editor's wording was rewritten — `[Parent ▾] of this person: [Name ▾]` could be
read as the opposite edge, so it is now a sentence (`This person's [parent ▾] is [Name ▾]`)
and the row labels are possessive (*Their parent: …*), with the phrasing consolidated out
of the two copies that had drifted into. **Two things the spec did
not settle, taken while building:** the inference needs an **ambiguity guard** the matcher
doesn't (see fork (c)), and a suggestion is **one row however many records support it**,
citing all of them — two documents naming the same father are one conclusion with two
citations. One thing only hand-testing found: the lane's chosen SF Symbol doesn't exist,
so the rows rendered with an invisible icon holding open an indent nothing filled.
**`/code-review` then corrected three things**, all recorded in SLICE-LOG: the ambiguity
guard was scoped by **head-count** rather than by *kind* of centre, so a half-catalogued
register (one spouse entered, both fathers entered) attributed every parent to that spouse
— the exact conclusion the guard exists to refuse, from a *less* complete record; the two
single-line surfaces paired the **archive-wide** `isStated` with one particular document's
title, so a suggestion implied by record A and stated by record B told the reader A stated
it; and `confirm` was not idempotent while its sibling `dismiss` deliberately is.
*Original plan follows.* **Problem:** the death
certificate states Sidney's parents, both are resolved to person records, and nothing
proposes the edge — the user re-asserts by hand what the document already says. The
relationship analogue of 42c/45i, which exists for *facts* only.
**Layer:** engine derivation + app; **no format change** — `Relationship.supportedByLinks`
already exists, so a promoted relationship cites the links it came from.
**Scheduled after 45k and 45m**, and it cannot start before 45m's dismissal record
exists — see fork (b).

**Four forks settled 2026-07-30, before any code:**
- **(a) Two surfaces.** A third Review lane (the worklist), **and** an affordance in the
  artifact inspector's Persons Mentioned section — 45e fork (d)'s precedent: the
  cataloguer is standing on the record that states the relationship, and that is where
  the judgement is actually made. A lane alone makes it something you go looking for.
  *As built it is the **fourth** lane — 45m took the third while this one waited on it —
  and the inspector half is a **filter over the same whole-archive derivation**, never a
  per-record scan, so the two surfaces cannot disagree about what is still owed and a row
  confirmed from either cites every record behind it. **A third surface was added after
  hand-testing**, on the user's call: the person pane. It already pairs Facts with
  Suggested Facts, so Relationships standing alone read as "nothing here to promote" —
  false for exactly the person this slice was built for. `suggestedRelationships(for:)` is
  the same filter a third way, and rows there phrase the claim from that person's side
  (*Their parent: Szlama Feldberg*) rather than repeating the page's own title back.*
- **(b) Rejection memory is **45m**'s record, applied here** (45j's fork settled *that*
  it is a stored record and moved the record itself to 45m). Neither a duplicate-person
  pair nor a proposed relationship has an `EvidenceLink` to tombstone, so both need the
  same new answer — one mechanism built once, used by both lanes, rather than two
  mechanisms invented in two slices. This is why 45m's record is specced with **both**
  consumers in view rather than as a duplicates-only tombstone.
- **(c) Stated edges where present, role inference where not** — the same fallback rule
  as 45k's fork (c), so the matcher and this derivation never disagree about what a
  record says. The inference half carries 45g's star rule and is therefore confined to
  records with an unambiguous centre; a marriage register's four parents stay
  unassignable until its edges are stated.
  *As built, "the same rule" is exact for **stated** edges — they are `mentionRelationships`
  read verbatim, with no interpretation to share or drift — and the **centre** is literally
  the matcher's, now `Matcher.principalRole(among:)` with one implementation. What this
  slice adds on top is an **ambiguity guard the matcher must not have**: the matcher's
  relational dimensions are positive-only, so reading four parents best-of costs a wrong
  guess nothing, while writing a conclusion from that same guess asserts the bride's mother
  is the groom's. So the guard is scoped by the **kind** of centre, not by a head-count
  (`/code-review`'s correction — counting principals let a half-catalogued register through
  the single-centre path and gave one spouse every parent on the page): a `spouse` centre
  means a **couple document**, whose parents are unassignable however many parties have
  been entered, and the only edge it yields is the couple itself, once both are named. A
  `subject` centre infers parents and partners, and two subjects is its own ambiguity. The
  per-slot scoping is 45k's verbatim: a stated parent edge silences only the centre's
  **parent** inference, never its partner one.*
- **(d) A promoted relationship is `.humanConfirmed` with `createdBy: .machine`**, citing
  both endpoints' links — 45c's rule that a confirmation records what was computed rather
  than laundering it into a hand-made assertion. *The conclusions-side vocabulary spells
  that `reviewStatus: .humanVerified` (`.humanConfirmed` is `LinkReviewStatus`'s word), over
  `provenance.tool: genealogic-relationships/1` — **its own** identifier, not the matcher's,
  since nothing here is scored and tying it to `genealogic-matcher/N` would make a promoted
  edge indistinguishable from something the scorer produced.*

**The dedupe is the same shape as `SuggestedFacts`':** an edge already asserted is not
re-offered, *in either direction* for a symmetric `couple` (§4.5), and the rule lives in
one place because a second copy is where two surfaces start to disagree silently.
*Symmetry now has one owner across all three layers — `RelationshipType.isSymmetric`, which
`MentionRelationship.statesSameRelationship` reads too and `DismissalSubject.isSymmetric`
agrees with case by case.*
**Out of scope:** the evidence-layer format (**45k**); duplicate detection (**45j**).
**Verification:** engine tests over seeded archives — an edge is suggested once, an
already-asserted one isn't, both directions of a `couple` count as asserted, an edge with
an unresolved endpoint yields nothing, ordering is deterministic. Linux-verified.
**Hand-test:** the Sidney Feldberg death certificate proposes Szlama Feldberg and Tauba
Pelc as his parents; confirming adds them to his record, ⌘Z removes them, and the Tree
tab gains the edges.

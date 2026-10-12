# 44h — matcher-precursor format revision

**44h — matcher-precursor format revision** — **SHIPPED.** All five changes landed, plus
a sixth the plan didn't anticipate. Engine/model + CLI + spec; the app was updated only as
far as compiling and not lying, with the *authoring* UI deferred to **44i** (see below).
292 macOS / 289 Linux engine + 67 CLI, all green.
**(1) §10.6 resolved toward (b), mention-scoped facts — but with a new `RecordedFact`
type, not `PersonFact`.** This reverses the plan's sub-decision, and the reasoning is worth
keeping because it is the *opposite* of slice 43's on the same question. `PersonFact` carries
`supportedByLinks: [EvidenceLinkID]` — a pointer into the conclusions layer. On a
`Relationship` that means exactly what it says (a relationship *is* a conclusion), which is
why 43 reused it. On a **mention** it would make an artifact sidecar reference
`conclusions/`, inverting §2.3's one-way dependency, and leave a field that is meaningless
and must stay permanently empty. A second small type costs far less than a format in which
evidence can cite conclusions. **`RecordedFact` also gained an optional per-fact
`informationQuality`** — not in the plan, but §4.6's per-*field* GPS quality is one of the
three matcher inputs the slice was scoped around, and a mention-wide value cannot express it
(a death certificate is primary for the death it records and secondary for the birth it
mentions). Absent means **inherit the mention's**, never `undetermined` — forcing a value
would fabricate a judgment the researcher never made. `FactType.recordedCases` scopes it:
`personCases` **plus** `coupleCases` (a marriage register's entry for the groom genuinely
records his marriage), minus the `parentChildCases` (a parent-role qualifier describes a
concluded *edge* between two identities, so it cannot be an observation about one person).
**(2) `Artifact.sourceDerivation`** (`original`/`derivative`/`authored`, open vocab,
optional). Absent means *unstated*, never "original" — the same rule the parent-child
qualifiers follow. **(3) Name language/script** on `PersonName` (`language`/`script`) and on
the evidence side (`PersonMention.nameLanguage`/`nameScript`). Both, not "and/or": they are
orthogonal, and a transliterated Russian name is language `ru`, script `Latn` — the script is
what selects a phonetic keyer. **(4) `PersonRole` opened** + the six register roles
(godparent/sponsor/declarant/registrar/clergy/midwife). **(5) Scores as `Int` 0–100.**
**(6) The unplanned one: the score type change silently misreads every existing link.**
A pre-44h link stores `1` (Double `1.0`, meaning *certain*) in all four score fields; as
`Int` that decodes as **1 — i.e. 1%**. The real archive had 12 such links. The plan's own
argument for doing this now ("almost none are persisted yet, only trivial human-link
values") was *also* the thing that made it silently wrong, since those trivial values are
exactly the ones that misread. Options weighed: a `1.0 → 1.1` schema bump driving the (real,
unused) `Migration` scaffold; the same bump with a lazy decode-time rescale; or accepting it.
**Resolved with the user: accept it, no bump** — GeneaLogic is pre-release with a single
user, artifact files are backed up independently, and a version bump before a 1.0 has shipped
buys machinery rather than safety. Worth remembering as the shape of the hazard: *a type
change is only cheap while the values are meaningless, and a constant placeholder is not the
same as no data.*
**Consumer surface.** The CLI can write every new field, so the matcher has seedable data
without app UI: **`genea mention fact add|remove`** (deliberately **not** folded into
`genea fact` — 44b's justification for one fact command was "`PersonFact` is the shape of
both", which does not carry when the type and the *layer* differ; nesting under the evidence
noun matches `person name add|set|remove` exactly), `--source-derivation` on `add`/`set-meta`
(with `--clear-source-derivation`, since a settable optional needs a way back to unstated),
`--name-language`/`--name-script` on `mention add`, `--language`/`--script` on `person add`
and `person name add|set`, and `genea show` nesting a mention's facts under it with the
indices `mention fact remove` takes. `--role` moved off `ExpressibleByArgument` (an open
vocabulary can't be rejected at parse time) onto the lenient case-folding parse. **Engine:**
free-text search and the `dateRange` facet now cover mention-scoped facts — both purely
additive (an artifact that matched before still matches), and without them the facts scoped
to a mention would be the one thing a record says that neither surface can reach.
**Deliberately NOT changed: `earliestDate`/`primaryDate` still derives from `events[]` only.**
That is a *value* change, not an additive one, and it is UI-visible (the app captions it
"earliest event date") — 44i owns it.
**/code-review (8 inline angles) — 9 findings, all fixed.** The load-bearing one was an app
data-loss bug in a file the slice barely touched: `PersonEditorSheet.save()` assigned a
freshly-built `PersonName` over the stored one, silently destroying `language`/`script` on every
name edit. Adding a field is only half the job — the other half is finding every writer that
*replaces* the record instead of mutating it, and those never turn up in a grep for the new
field. Fixed by writing only the fields the sheet owns. Also: CLAUDE.md's own vocabulary contract
was stale (three other copies of the rule were updated, the governing one missed); the
language/script renderers had already drifted apart within this one slice (now one shared
helper); `mention remove` destroyed recorded facts without saying so; two formatter duplications
consolidated; a shadowing method renamed; `--role`'s help list generated from `knownCases`; and a
new `artifact-44h.json` golden fixture covers the post-44h encoding, since `artifact.json` is now
purely a back-compat input. 293 macOS / 290 Linux + 69 CLI.
**44i — the app surface over 44h's fields — SHIPPED** (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)). Scoped as
"UI over landed fields," it grew a deliberate *additive* format revision once real data (a
*Declaration of Intention*) showed the fact model had no home for **value-bearing** facts:
a **`value: String?`** on both `RecordedFact` and `PersonFact` (occupation "tailor", physical
description "brown hair"; synthesized-`Codable` optional, no schema bump), three promoted
`FactType` cases (`declarationOfIntention`/`occupation`/`physicalDescription`), and an advisory
`isValueBearing` classification driving the editors' Value field (value is permitted on any type).
App: the mention-scoped **recorded-fact editor**, a real **mention edit path**
(`PersonMentionEditorSheet`, retiring `AssertionEditorSheet`'s person mode), source-derivation +
name language/script controls, 42c suggestions **rewired to mention facts**, **custom fact types**
("Other…"), **one-click Record** for directly-recordable suggestions, and **"Add as name"** capture
of a recorded name onto a linked person. `primaryDate` **kept events-only** (a mention fact doesn't
pull the artifact date). CLI: `--value`. A latent `parsingLeniently` bug (not internally
whitespace-insensitive, so multi-word promoted types minted `.unknown` twins) fixed in passing.
295 macOS / 292 Linux engine + 70 CLI; /code-review clean. **Deferred to 45+: a cross-person
suggested-facts/links triage inbox** (the matcher's suggested-links queue is its home).
*Original plan follows.* Scoped from an external schema review (the one that
also surfaced EDTF, since implemented). **Rationale:** "format changes are the most expensive
mistake" (§4.2), so the fields the matcher's §4.6 confidence framework consumes should land and
settle *before* 45+ co-evolves format and algorithm. Ground-truthing the review against the code
found its scariest "correctness holes" already fixed (the `localRef` re-binding bug — slice 44c;
dangling-reference detection/repair — 44e/44g) or already parked as §10 open questions (concurrent
writers §10.5, manifest generation counter §10.4, participants §10.6); the genuinely load-bearing,
not-yet-addressed items are the domain fields below, and **only the ones the matcher actually reads
belong in this slice** (the rest ride a later broader domain revision). Each is traced to a matcher
input — the source-authority multiplier, the per-field information-quality weight, or a
`MatchBreakdown` dimension (name / birthYear / birthPlace / spouseName / parents):
- **Resolve §10.6 (event ↔ mention association) toward (b): mention-scoped `PersonMention.facts`.**
  This is the load-bearing one — the matcher's `birthYear`/`birthPlace` dimensions can't be
  attributed to a *mention* on a **multi-person record** (census household, metrical register — the
  project's norm) while `events[]`/`personsMentioned[]` stay flat and unpaired. Giving each mention
  its own `[PersonFact]` ("what this document records about *this* person — their recorded birth,
  age, place") feeds those dimensions directly and makes slice-42c's suggestion scoping **exact**
  (a person's suggested facts come from *their* mention's facts, not the artifact's deduped flat
  events — retiring the 42c-follow-up heuristic). The relational `spouseName`/`parents` dimensions
  ride the existing `PersonRole` tags (find the `spouse`/`parent` co-mentions) rather than explicit
  mention-to-mention links — sufficient for v1, and another reason to open `PersonRole` (below).
  GEDCOM X's shared-`Event`-with-participants shape (option (a)) stays available later for genuinely
  shared events, but per-person recorded facts are person-scoped even in GEDCOM X, so (b) is the
  right primitive here. Additive (`decodeIfPresent` → `[]`), no schema bump.
- **Add a source-derivation axis** (original / derivative / authored — an open vocab, e.g.
  `sourceDerivation` on `Artifact`), distinct from the genre-shaped `sourceAuthorityTier`. §4.6
  calls the tier "GPS-aligned," but GPS's *central* authority distinction is original-vs-derivative,
  and only half the GPS model is currently present (information-quality-per-field is; derivation
  isn't) — so this **completes** the confidence framework the matcher implements, and lets the
  source-authority multiplier weight on the right axis from day one rather than being retrofitted
  (which would re-score every existing link). Additive optional field.
- **Tag name language/script** (BCP-47 `language` and/or ISO 15924 `script` on `PersonName`, and on
  the evidence side for `nameAsRecorded`). Double Metaphone is Latin/English phonetics; keying
  "Мотек" with it is noise, and the matcher can't pick the right phonetic keyer (or transliterate
  first) without knowing a name's script. `MatchBreakdown.nameAlgo` already anticipates multiple
  algorithms; this is what selects one. Materially changes match quality for a Cyrillic/Polish/
  transliterated corpus. Additive optional field.
- **Open `PersonRole`** (reclassify the closed enum to an `OpenVocabulary`; add the standard missing
  roles godparent/sponsor/declarant/registrar/clergy/midwife as known cases). It's inconsistently
  closed while `NameType`/`RelationshipType`/`FactType` are open, and closed means a load error on a
  role your metrical records actually carry. Cleaner role data also sharpens the role-based
  `spouseName`/`parents` dimensions above. Reads stay back-compat (existing values still parse;
  unknown now preserved, not rejected) — a type change, but a widening.
- **Scores as integers 0–100** (change `EvidenceLink`/`MatchBreakdown` `score`/`aggregateConfidence`/
  weights from `Double`). The spec promises "reproducible bytes" (`.sortedKeys` *is* set, so key
  order is delivered) but float text isn't canonically reproducible without JCS/RFC 8785; integers
  sidestep it. **Cheap now, expensive later:** the matcher is what writes scores *at volume*, and
  almost none are persisted yet (only trivial human-link values), so this is the one non-additive
  (type) change that must happen **before** 45+ rather than after.

**Deliberately deferred to a later broader domain revision (they gate *ingest*, not the matcher):**
the **calendar/Julian dual-dating** fix (`dateAsRecorded` verbatim + optional `calendar`, normalized
EDTF = proleptic Gregorian — the standout data-fidelity gap for Russian-partition records) and the
**structured citation locator** (repository + fond/opis/delo + akt + page) both gate *typing in real
records*, so their "before" is "before mass-ingesting the real archive," which may be sooner or later than
the matcher; plus `gender`, `patronymic` name part, and `presumedLiving` (matcher-independent;
needed for GEDCOM export / tree / Phase-4 redaction). Also deferred: the safety/robustness normative
paragraphs (path-safety `..`/symlink, slug case-fold/NFC across *all* slugs, an `fsync` in
`AtomicIO`'s durable-write path, the manifest reconciliation decision table + generation counter per
§10.4, the dual-`reviewStatus`-on-`EvidenceLink` authority rule) — a **spec-hardening** companion
slice, mostly documenting rules the engine already enforces (a natural follow-on to the slice-43
`SchemaSpecTests` guard).
**Format-change discipline:** most of the above is an additive `decodeIfPresent` widening (no
schema bump — the EDTF/`Relationship.facts` pattern); scores-as-int and `PersonRole`-open are the
two type changes, both cheap now precisely because volume hasn't accrued. Per the slice-43 rule,
the spec (`genealogic-archive-1.0.md`, **both** checked-in copies) + `SchemaSpecTests` update with
any field added. Every new record shape gets a round-trip test before it's done (§ non-negotiables).

# GeneaLogic Archive Format — Specification v1.0

> This document defines the on-disk format of a GeneaLogic archive. It is written
> to be readable **without** GeneaLogic software: every record is a plain UTF-8 JSON
> file, and this spec describes their structure precisely. A copy of this document
> travels inside every archive (`schema/genealogic-archive-1.0.md`) so the archive
> remains interpretable indefinitely.
>
> Status: **draft, tracking the Phase 0 model.** Companion to `docs/ARCHITECTURE.md`
> (design rationale) and the `GeneaLogicModel` Swift types (reference implementation).
>
> Copyright 2026 The GeneaLogic Authors. This specification is licensed under the
> Creative Commons Attribution 4.0 International License (CC BY 4.0,
> https://creativecommons.org/licenses/by/4.0/). The license covers this document
> only: the records and files of an archive belong to whoever created them, and
> GeneaLogic claims no rights in them. Implementing this format needs no permission.

## 1. Principles

- **Files are the source of truth.** Media files and their JSON sidecars are
  authoritative. Any database/index is a derived, rebuildable cache.
- **Evidence and conclusions are separate.** Sidecars record *what a document says*;
  the `conclusions/` tree records *what a researcher infers*. The family tree is a
  derived view over both, never a stored, separately-edited structure.
- **An artifact is not a file.** An artifact is an intellectual record; it may have
  zero, one, or many files, or only an external pointer.
- **Open, durable encodings.** UTF-8 JSON for metadata; ISO 8601 (extended) for
  timestamps; SHA-256 (lowercase hex) for checksums; preservation-grade media
  formats (PDF/A, TIFF, FLAC, FFV1/MKV, …).

## 2. Archive layout

An archive is a **directory** (presented as a document package on macOS). Folder and
file *names* are non-authoritative friendly slugs; identity always lives in a record's
`uid` field (§4).

```
<name>.genea/
  manifest.json                      archive identity + integrity manifest (§5)
  artifacts/
    <slug>/
      record.json                    the evidence sidecar (§6.1) — the only convention-named file
      <files…>                       media/transcripts; names recorded in record.json
  conclusions/
    persons/<uid>.json               concluded person (§6.2) — named for its own uid
    links/<uid>.json                 evidence→person link (§6.3)
    relationships/<uid>.json         concluded relationship (§6.4)
    dismissals/<uid>.json            a suggestion a human declined (§6.6)
  schema/
    genealogic-archive-1.0.md        this document
  .index/                            DERIVED cache (rebuildable); not authoritative; may be absent
  .trash/                            recoverable deleted items (rebuildable space); not authoritative; may be absent
    <uid>/                           <uid> is the item's own uid — ART-… for an artifact, FIL-… for a detached file
      payload                        the deleted item's bytes: an artifact folder, or a single file (absent if the bytes were already gone)
      deletion.json                  what was deleted + restore info (kind-discriminated: artifact vs. file)
  .damaged/                          quarantined originals; not authoritative; may be absent
    <uid>-<timestamp>.json           a record file as it was found, set aside by a repair that replaced it
```

Only `record.json` (inside an artifact folder) and `manifest.json` (at the root) are
discovered by name. A conclusion record is discovered by **scanning** its
`conclusions/<kind>/` directory, and its file name MUST be its own `uid` followed by
`.json`; a file there whose name is not the `uid` inside it is not that record and MUST
NOT be loaded as one. Payload files are neither: each is referenced by `path` from a
`record.json`, so it may be named freely and is disambiguated by the writer (§6.1.1).

**One record, one file.** A `uid` is claimed by exactly one file — one
`conclusions/<kind>/<uid>.json`, and one `artifacts/<slug>/` folder per `ART-…`. A second
file claiming a `uid` the archive already has is not a version to choose between: a sync
provider that cannot merge a file leaves a copy beside it (`X (conflicted copy).json`,
`X 2.json`), and duplicating a folder does the same one level up. Such a copy MUST NOT
decide what the archive serves, and an implementation SHOULD report it rather than move
or delete it — it holds a version of the user's data, and the provider will re-deliver it
until the conflict is resolved at its source. Where two artifact folders claim one
`ART-…`, the record is the one whose `record.json` the manifest already names; where the
manifest names neither or both, it is the lexicographically first path, so that two
machines reading the same directory agree on which file is the record.

`.index/`, `.trash/` and `.damaged/` are **reserved** top-level directories. All three are
*non-authoritative* and a tool may ignore or discard them: `.index/` is a rebuildable
projection, `.trash/` holds items the user deleted but can still recover (emptying it is
permanent), and `.damaged/` holds record files an implementation set aside when repairing
them. Because they are siblings of `artifacts/`/`conclusions/`, none participates in the
manifest, the index, or integrity checks — a trashed item is simply absent from the archive
until restored.

**`.damaged/` is kept for people, not for tools.** When an implementation replaces a record
file it could not read — restoring an earlier copy it holds — the bytes it found in place are
moved here first rather than overwritten, because the "damage" may have been an edit someone
meant. Nothing is restored from it automatically and no operation reads it back: it is
evidence, and discarding it loses only the ability to see what went wrong. The `<uid>` names
the record the file belonged to (a file name cannot: every artifact sidecar is
`record.json`); the `<timestamp>` is UTC, so repeated repairs of one record neither collide
nor lose their order.

Their **contents are private to the implementation** and are deliberately not specified
here: nothing inside `.index/` is a record another tool needs to read, which is why — unlike
`.trash/` above — its children are not listed. Discarding `.index/` therefore stays safe
**only while no process has the archive open.** An implementation may keep live state in
there (an open database, a lock, a crash marker), so deleting it underneath a running writer
can cost that writer's in-flight work, in a way deleting a rebuildable *cache* suggests it
cannot. Discard it when the archive is idle; a tool that cannot establish that should leave
it alone and let the owning implementation rebuild it.

## 3. JSON encoding rules

- **Encoding:** UTF-8, no BOM.
- **Object keys:** sorted lexicographically (canonical form), enabling stable diffs
  and reproducible bytes.
- **Keys are plain camelCase.** They *align semantically* with Dublin Core and
  GEDCOM X vocabularies but do **not** use literal namespace prefixes (no `dc:`/`gen:`
  in keys). Mapping to literal DC/XMP happens only at export boundaries.
- **Dates:** strings. **Event/fact dates use EDTF** (Extended Date/Time Format,
  ISO 8601-2 / Library of Congress) — a strict superset of ISO 8601 that also
  expresses approximate, uncertain, and ranged dates: `"1871"`, `"1920-01-15"`,
  `"1920~"` (about), `"1920?"` (uncertain), `"1900/1905"` (a range), `"../1950"`
  (on or before), `"192X"` (a decade). Existing plain-ISO dates remain valid.
  Timestamps (e.g. `createdAt`) are full ISO 8601 (`"2026-02-22T15:04:05Z"`).
  There is no numeric date type.
- **Checksums:** lowercase hex SHA-256 strings.
- **Absent vs. null:** optional fields may be omitted or `null`; both mean "absent".

## 4. Identifiers

- Every record has a `uid`: a **type-prefixed UUIDv7** string — prefix `ART-`/`FIL-`/
  `PER-`/`LNK-`/`REL-` then a UUIDv7, e.g. `"ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70"`.
  (The reference implementation models these as distinct types but they serialize as
  plain JSON strings.)
- `uid` is minted once and never reused for a different record.
- Globally (across archives) a record's identity is the pair
  `(manifest.archiveUID, uid)`. Cross-archive references MUST be namespaced by the
  source archive's UID or a resolvable URI; a bare local `uid` is only meaningful
  within its own archive.
- `personMentionRef` (§6.1) is **not** a uid: it is unique only within one
  `record.json` and names a "name as it appears", not a person identity.

## 5. `manifest.json`

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | string | Archive format version, e.g. `"1.0"`. |
| `archiveUID` | string | Stable identifier for this archive; namespaces all records. |
| `name` | string? | Optional human-readable label. |
| `updatedAt` | string | ISO 8601 timestamp of last manifest write; written whenever `files` changes. |
| `files` | array | Integrity manifest; one entry per file in the archive. |

Each `files[]` entry: `path` (relative to archive root), `sha256` (hex), `byteLength`
(integer). This is the archive-wide, tool-verifiable integrity surface (BagIt-flavored).
Per-file `.sha256` sidecars are **not** used; checksums live here and in each
`record.json` file entry.

**Scope.** `files` covers every file an artifact's `record.json` claims, **every
`artifacts/<slug>/record.json`**, **every `conclusions/**` record**, and the archive's
copy of this specification. It does not cover `manifest.json` itself (it cannot list
itself) or the reserved `.index/`, `.trash/` and `.damaged/` directories (§2).

**`files` is half derived and half authoritative, and a writer must respect the
difference.** An attached file's checksum is authored into its artifact's
`record.json` at attach time, so its manifest entry is a *copy* and may be re-derived
from that record freely. An entry for a `record.json` or a conclusion record has no
second copy anywhere: the manifest is the only statement of what those bytes were.
Therefore:

- **An entry for one of those files may only be written by the writer that writes the
  file.** Recomputing it by re-reading the file destroys the evidence it exists to
  carry: damage would simply be re-measured, recorded as expected, and never
  reported again.
- **An entry that disagrees with the file on disk is a finding, not a repair job.** A
  hand edit and bit rot are byte-identical from here, so a tool must report the
  difference rather than choose an interpretation.
- **Re-recording checksums from disk wholesale is a distinct operation a human asks
  for** — the reference implementation calls it *rebaseline*, and offers it as the way
  to accept a deliberate out-of-band edit. It must never run as part of opening an
  archive or committing an ordinary change.

**Absent means unverified, never tampered.** A manifest that carries no entries for
`record.json`/`conclusions/**` files was written by an implementation that did not
track them (they were out of scope before this rule). A reader must not report those
files as missing or altered; entries appear as the records are next written.

## 6. Record types

### 6.1 Artifact — `artifacts/<slug>/record.json`

Evidence: *what this document says.*

| Field | Type | Notes |
|---|---|---|
| `uid` | string | `ART-…`. |
| `schemaVersion` | string | e.g. `"1.0"`; MUST equal the manifest's (§8). |
| `title` | string | Descriptive title (DC: title). |
| `mediaType` | open vocab | DC type. Known: `image`, `text`, `sound`, `video`, `document`. |
| `sourceAuthorityTier` | open vocab? | GPS authority — a **coarse genre** convenience, not a per-genre taxonomy; the GPS's real axes are `sourceDerivation` and per-fact `informationQuality`. Known: `vital`, `church`, `government`, `census`, `monument` (gravestone or memorial), `newspaper`, `bible`, `compiled`. **`government` is read by who created the record, not by the errand it served**: any record an authority created or required, other than the vital registration that has its own tier — naturalization, draft and service, land, court, and arrival/passenger manifests, which are filings retained by the receiving authority. Genres fitting no bucket (institutional registers, commercial records, photographs) are left to `.unknown`, which scores as *unstated* rather than as `compiled`. **Absent means unstated, never a default genre** — the same rule as `sourceDerivation`. Optional: absent in archives written after this field became optional, and present in every archive written before. |
| `sourceDerivation` | open vocab? | GPS derivation, orthogonal to the tier: how far the source stands from the event. Known: `original`, `derivative`, `authored`. **Absent means unstated, never `original`.** Optional: absent in archives written before this field existed. |
| `originalFormat` | string? | e.g. `"digital scan"`. |
| `language` | string? | BCP 47 tag (DC: language). |
| `events` | array | Each: `type` (string), `date` (string?), `location` (string?). |
| `personsMentioned` | array | See below. |
| `mentionRelationships` | array | Relationships the document states between the people it names. Each: `type` (open vocab, same as §6.4), `person1Ref`, `person2Ref` (`localRef`s). Optional: absent in archives written before this field existed, where it reads as empty. |
| `locations` | array | Each: `asRecorded` (string), `normalized` (string?). |
| `transcript` | string? | Short inline transcript; long ones are a file with `role: "transcript"`. |
| `files` | array | See §6.1.1. |
| `externalIdentifiers` | array | Each: `scheme` (open vocab: `ark`/`doi`/`url`), `value` (string), `repository` (string?). |
| `retrieval` | object? | For externally-sourced records: `source`, `date`, `checksum?`. |
| `provenance` | object | See §6.5. |
| `tags` | array of string | |
| `notes` | string? | |

`personsMentioned[]`: `localRef` (record-local id string), `nameAsRecorded` (string),
`role` (open vocab; known: `subject`/`informant`/`witness`/`parent`/`spouse`/
`godparent`/`sponsor`/`declarant`/`registrar`/`clergy`/`midwife`),
`informationQuality` (closed vocab: `primary`/`secondary`/`undetermined`),
`facts` (array — see below), `nameLanguage` (string?, BCP 47) and `nameScript`
(string?, ISO 15924) describing `nameAsRecorded`, `attributes` (string→string map).
`sourceAuthorityTier` and `informationQuality` live here because they are properties of
the record itself, independent of any conclusion.

`personsMentioned[].role` states a person's role **in the document**, which means it is
read relative to whoever the record is *about* — on a death certificate, `spouse` means
*spouse of the deceased*, not spouse of whichever mention a reader happens to be looking
at. Most records have one such focal person, tagged `subject`. **A record about a couple
has none:** a marriage register names two parties, and both SHOULD be tagged `spouse`
with no `subject` on the record. That is the convention for a couple-centric record, and
it carries more than tagging both `subject` would — two `subject`s assert only that the
record concerns two people (a census page does that), where two `spouse`s assert that
they are a couple. Satellite mentions beside them (`parent`, `witness`) are stated
relative to the pair, and which party a given parent belongs to is **not** expressed by
the roles; consumers MUST NOT assume it — state it as a `mentionRelationships` edge
instead. Roles outside the known vocabulary, and pairings the record does not state,
carry no relation at all — a reader that infers one is inventing it.

`mentionRelationships[]` states a relationship **between two of the people the document
names**, which one `role` tag per mention cannot: a marriage register names two parties
and both sets of parents, and only an edge can say which pair belongs to which spouse.
Each entry: `type` (open vocab — the same vocabulary as the concluded relationship in
§6.4, so the two layers name a relation identically), `person1Ref` and `person2Ref`
(`localRef`s of mentions **on this same artifact**). The direction is §6.4's: for
`parent-child`, `person1Ref` is the **parent**; a `couple` is symmetric and its endpoints
carry no ordering.

One edge is **one entry**. A writer MUST NOT also record the reverse edge, and MUST NOT
mirror edges onto the mentions themselves: storing each edge twice invites the two copies
to disagree and makes every reader a repair tool. Because a `couple` is symmetric, its
reverse pair is the *same* entry — a writer comparing pairs by field equality alone will
miss it, so symmetry has to be part of the comparison. Two `parent-child` entries with
swapped endpoints are **not** duplicates; they are contradictory claims.

This is evidence, not a conclusion: an edge says *this page states these two are father
and son*, and asserts nothing about identity. Promoting one into a `Relationship` (§6.4)
between concluded persons is a separate act.

Consumers SHOULD prefer a stated edge to anything inferred from roles, and MUST NOT read
a record that states *some* edges as denying the relations it says nothing about. This
holds both per type and per person: a record stating four `parent-child` edges and no
`couple` has not denied that its two `spouse` mentions are a couple, and one stating only
the bride's parents has not denied that the groom has parents on the page. A partially
annotated record is the normal state of a record being catalogued, and a consumer that
treats the first stated edge as switching off everything it infers elsewhere makes adding
information destructive. An edge naming a `localRef` that no mention on the record
carries is a **dangling reference**, reported like any other and never silently dropped.

`personsMentioned[].informationQuality` is the **default for this mention's facts** —
the value a `facts[]` entry takes when it states none. It records how close whoever
supplied the information stood to what is being stated about this person; it is *not*
a quality of the person, which under the GPS is not a meaningful claim (quality belongs
to an individual information item). Writers SHOULD set it to whatever most of the
mention's facts are and state only the **exceptions** on the facts themselves.

A `localRef` MUST NOT be reused while any `EvidenceLink` **or `mentionRelationships`
entry** still references it, even after the mention it named is removed (removals do not
cascade). Reassigning a freed ref would silently re-point that surviving reference at a
different person — turning a detectable dangling reference into an undetectable false
conclusion, or into a stranger recorded as somebody's parent.

`personsMentioned[].facts[]` records **what this document says about this person** —
the mechanism that pairs a recorded date or place with *one* of the several people a
census household or metrical register names. Each entry: `type` (open vocab, GEDCOM X
fact type as in §6.2), `date` (string?, EDTF), `place` (string?), `value` (string?, the
fact's value when it carries one that isn't a date or place — an occupation `"tailor"`,
a physical description `"brown hair, 5 ft 8 in"`; value-bearing types such as
`Occupation`/`PhysicalDescription` use it), `informationQuality`
(closed vocab?, per-*field* GPS quality — **absent means "as good as the enclosing
mention"**, never `undetermined`, so an unqualified fact is not silently downgraded).
A death certificate is thus `primary` at the mention and `secondary` on the birth and
parentage its informant reports secondhand; a naturalization certificate is `primary`
for the naturalization it witnesses and `secondary` for the birth date the applicant
supplied from memory. Optional: absent in archives written before this field existed,
where it reads as empty.

This is deliberately **not** the same shape as a person `fact` (§6.2), which also
carries `supportedByLinks`. Evidence records what a document states; only conclusions
cite evidence. A field here pointing into `conclusions/` would reverse that direction.

#### 6.1.1 File entries & naming

Each `files[]` entry: `uid` (`FIL-…`), `path` (package-assigned, collision-free,
relative to the artifact folder), `originalName` (the user's filename — display/export
only, never used to locate), `role` (closed vocab: `preservation-master`/`access-copy`/
`derivative`/`transcript`), `format` (string), `byteLength` (integer), `sha256` (hex).

A writer MUST assign `path` itself (never trusting the incoming basename), guarantee
uniqueness within the artifact folder under **case-folding + Unicode NFC**, sanitize
unsafe characters, and never silently overwrite.

### 6.2 Person — `conclusions/persons/<uid>.json`

A concluded person (GEDCOM X-aligned).

| Field | Type | Notes |
|---|---|---|
| `uid` | string | `PER-…`. |
| `schemaVersion` | string | |
| `names` | array | Each: `type` (open vocab: `birth`/`married`/`also-known-as`/`nickname`), `given?`, `surname?`, `full?`, `language?` (BCP 47), `script?` (ISO 15924). A person's names routinely differ in language and script across the records they come from, so the tags belong on the name rather than the person. |
| `facts` | array | Each: `type` (open vocab, GEDCOM X fact, e.g. `Birth`/`Death`), `date?`, `place?`, `value?` (string — the fact's value when it isn't a date/place, e.g. an occupation or physical description; value-bearing types like `Occupation`/`PhysicalDescription` use it), `supportedByLinks` (array of `LNK-…`). |
| `identifierURI` | string? | Reserved for linked-data federation. |
| `provenance` | object | §6.5. |

### 6.3 Evidence link — `conclusions/links/<uid>.json`

Connects a person mention in an artifact to a concluded person, with a **decomposed**
confidence breakdown (never a single opaque score).

| Field | Type | Notes |
|---|---|---|
| `uid` | string | `LNK-…`. |
| `schemaVersion` | string | |
| `artifactUid` | string | `ART-…`. |
| `personMentionRef` | string | A `localRef` within that artifact. |
| `personUid` | string | `PER-…`. |
| `match` | object | See below. |
| `sourceAuthorityWeight` | integer | 0–100. Derived from the artifact's `sourceAuthorityTier` and `sourceDerivation`. |
| `informationQualityWeight` | integer | 0–100. Per-field information-quality weight. |
| `aggregateConfidence` | integer | 0–100. Roll-up; the breakdown is authoritative. |
| `reviewStatus` | closed vocab | `machine-suggested`/`human-confirmed`/`human-rejected`. |
| `reviewedBy` | string? | |
| `reviewedAt` | string? | ISO 8601. |
| `provenance` | object | §6.5. |

`match`: `name` (a dimension), `nameAlgo` (string?, e.g. `"double-metaphone"`),
`birthYear?`/`birthPlace?`/`spouseName?`/`parents?` (dimensions), `conflicts` (array of
string). A **dimension** is `{ kind, score, delta?, granularity? }` where `kind` is a
closed vocab (`exact`/`phonetic`/`known-variant`/`within`/`none`) describing *how the
comparison was reached*, `score` is an **integer 0–100**, and `delta` is an integer
(e.g. birth-year offset) used with `kind: "within"`. A non-empty `conflicts` is a
human-review flag, not something to average away.

`granularity` is an **open** vocab (known:
`specific`/`partial`/`coarse`/`unqualified`) stating *how far down a hierarchy* two
values agreed, for a dimension whose agreement is layered. Today only `birthPlace` sets
it. The known cases are **structural, not administrative** — `specific` means the most
specific component agreed while coarser ones differed (`Łomża, Russia` and `Łomża,
Poland` are one town under two empires), `coarse` means only the least specific did. It
is open so that a gazetteer-backed implementation can state a real level (`parish`,
`admin2`) without a format change.

It normally accompanies `kind: "within"`, and is absent from a multi-component exact
match, where the agreement demonstrably reached the most specific component. **An exact
match carries it only when the two values hold a *single* component**, where the depth
of the agreement is not evident from the pair itself: `Poland` and `Poland` share a
country, `Łomża` and `Łomża` share a town, and the strings alone do not say which.

Such a match takes one of two granularities (slices 45n, 45o):

- `unqualified` when the depth is unmeasurable — the honest report from an
  implementation with no way to tell those two cases apart. Writers SHOULD score it well
  below a multi-component exact match rather than resolving the ambiguity toward either
  reading.
- `specific` when the implementation has **outside evidence** that the value lies below
  the top level and is itself a finest-level name. Two sources of such evidence are
  anticipated: a gazetteer, and *the archive's own other place strings* — an archive
  that writes `Łomża, Poland` anywhere has demonstrated that `Łomża` is not a country.
  Writers SHOULD then score it as they would a `specific` `within` match, and MUST NOT
  score it above a multi-component exact one: knowing the depth of a one-component
  agreement makes it worth as much as `Łomża` vs `Łomża, Poland`, not more.

Readers MUST NOT infer an administrative level from either. And because the evidence for
`specific` may come from outside the pair, a stored breakdown records what the matcher
could prove **when it was written**: re-scoring the same two records against a larger
archive may legitimately produce a different granularity.

Note the ordering this implies, which is intended: an `unqualified` match SHOULD rank
**below** a `specific` one, so two places recorded as bare `Łomża` score under a pair
where one of them is written `Łomża, Poland` — unless something else has established
what `Łomża` is. The dimension states *how far down* two values agreed, not how much of
each string did, and the second pair's `Poland` demonstrates that `Łomża` lies below the
country level while the first pair, on its own, demonstrates nothing about either
value's depth.

**Retired (slice 45h):** `kind` formerly also admitted `county` and `country`. Those
named administrative tiers rather than the matcher's reasoning — not GeneaLogic's own
domain, and so misfiled in a closed vocabulary per §7. A record still carrying either
MUST be read as `kind: "within"` with the original word preserved in `granularity` as an
unknown value; it MUST NOT be translated into a structural case, because `county` was
written for more than one claim and recovering which would be guesswork. Writers MUST
NOT emit either value in `kind`.

Scores and weights are integers rather than fractions because floating-point *text* is
not canonically reproducible without a scheme such as JCS (RFC 8785), which would
otherwise put the byte-reproducibility rule of §3 out of reach for any record the
matcher writes.

**A pair holds one verdict.** At most one link record may exist for a given
(`artifactUid`, `personMentionRef`, `personUid`) triple. Two would let the archive assert
that a pair is both resolved and foreclosed, with read order deciding which is true; and
because a rejection is addressed by `uid`, a duplicated tombstone survives being deleted
and keeps the pair hidden. A writer recording a verdict replaces any existing one for
that pair, whatever its `reviewStatus`.

**A link record is a human decision.** `reviewStatus` has three legal values, but
GeneaLogic writes only two of them:

- `human-confirmed` — this mention names this person. The `match` breakdown is whatever
  the matcher computed, stored unaltered: a confirmation is a verdict on the pair, not a
  re-scoring of the evidence, so a link confirmed on a birth year three years off still
  says so. When no matcher ran (a mention resolved by hand) the breakdown carries only
  `name` at `exact`/`100` with every optional dimension absent — `null` meaning *not
  assessed*, never *assessed and failed*.
- `human-rejected` — a **tombstone**: this mention is not this person. It stores the
  computed breakdown for the same reason a confirmation does, and it is what gives a
  matcher memory; without it, declining a suggestion would be forgotten and the identical
  pair offered again forever. A rejection forecloses **that pair only** — every other
  candidate for the mention stays open, and the mention itself stays unresolved. Deleting
  the record un-rejects the pair.
- `machine-suggested` — **legal on disk, never written by GeneaLogic.** Suggestions are
  ephemeral: a match is computed, shown, and discarded unless a human decides on it, so
  `conclusions/` holds only conclusions and no read path has to filter unreviewed guesses
  out of the evidence behind a person. A reader encountering this value has met a record
  from another writer and should treat it as an opinion, not a decision — it neither
  resolves the mention nor forecloses the pair.

Consumers presenting a person's evidence, or asking which records mention someone, must
**exclude tombstones**: a link is a citation everywhere it surfaces, and a rejection is
the opposite of one. Integrity passes that audit references between records are the
exception — a tombstone pointing at a deleted artifact dangles like any other link.

### 6.4 Relationship — `conclusions/relationships/<uid>.json`

| Field | Type | Notes |
|---|---|---|
| `uid` | string | `REL-…`. |
| `schemaVersion` | string | |
| `type` | open vocab | `parent-child`/`couple`. |
| `person1Uid` / `person2Uid` | string | `PER-…`. For `parent-child`, `person1Uid` is the **parent** and `person2Uid` the **child**; for `couple` the two are symmetric (no ordering meaning). |
| `facts` | array | Relationship-scoped facts. For a `couple`, the couple's event (`Marriage`/`Divorce`/`Annulment` date+place). For a `parent-child`, the **nature of the link** (`BiologicalParent`/`AdoptiveParent`/`StepParent`/`FosterParent`/`GuardianParent`, optionally date+place) — one child may be biological to one parent and adoptive to another, so the qualifier belongs on the edge rather than on either person. An **absent** qualifier means *unspecified*, never "biological". Same shape as a person `fact` (§6.2). Optional: absent in archives written before this field existed, where it reads as empty. |
| `supportedByLinks` | array | `LNK-…`. |
| `reviewStatus` | closed vocab | Conclusion status: `asserted`/`machine-suggested`/`human-verified`. |
| `provenance` | object | §6.5. |

### 6.5 Provenance (embedded in every record)

| Field | Type | Notes |
|---|---|---|
| `createdBy` | closed vocab | `human`/`machine`. |
| `createdAt` | string | ISO 8601. |
| `tool` | string? | Tool/model id when machine-created. |
| `reviewStatus` | closed vocab | Conclusion status: `asserted`/`machine-suggested`/`human-verified`. |

### 6.6 Dismissal — `conclusions/dismissals/<uid>.json`

A suggestion over two concluded persons that a human **declined**. Suggestions are
computed, never stored, so declining one leaves nothing behind unless it is recorded: the
next sweep recomputes the same score and offers the same pair, forever.

| Field | Type | Notes |
|---|---|---|
| `uid` | string | `DSM-…`. |
| `schemaVersion` | string | |
| `subject` | open vocab | What was declined: `same-person` (these are not one person), `parent-child`, `couple` (this relationship does not hold between them). |
| `person1Uid` / `person2Uid` | string | `PER-…`. For `parent-child`, `person1Uid` is the proposed **parent** — §6.4's direction, unchanged. |
| `match` | object? | The breakdown the user was shown, when the declined suggestion was scored (same shape as §6.3's `match`). Absent for a suggestion that carries no score. |
| `aggregateConfidence` | integer? | 0–100. Present exactly when `match` is. |
| `dismissedBy` | string? | |
| `dismissedAt` | string? | ISO 8601. |
| `provenance` | object | §6.5. |

**Symmetry is per subject.** `same-person` and `couple` carry no ordering meaning, so
`(a, b)` and `(b, a)` are one statement and the pair is written in ascending `uid` order;
`parent-child` is directional, and reversing it states the opposite claim. A subject a
reader does not recognize is treated as **directional** — its symmetry is unknowable, and
assuming symmetry would silently collapse two distinct dismissals into one.

A dismissal is scoped to its subject: declining `parent-child` between two persons leaves
`couple` between them entirely open. It carries **no review status**, because it is itself
the negative record — it is reversed by deleting it, which returns the pair to the queue.

## 7. Controlled vocabularies: closed vs. open

- **Closed** vocabularies are GeneaLogic's own domains and are exhaustive in this
  version: information quality, `createdBy`, file role, match kind, and the two
  review-status sets. An unrecognized value is an error.
  The test is **domain, not convenience**: match kind describes how *this* matcher
  reached a verdict, which GeneaLogic does own. Slice 45h removed `county`/`country`
  from it on exactly that test — an administrative hierarchy is the world's, not
  GeneaLogic's, and closing a vocabulary over it was a category error rather than a
  list that needed extending.
- **Open** vocabularies map onto external/evolving standards (source authority tier,
  source derivation, media type, name type, person role, relationship type,
  external-id scheme, fact type, match granularity, dismissal subject). A reader
  that encounters an unrecognized value MUST preserve it verbatim and round-trip it
  unchanged — it must not fail to load or silently drop the value. This guarantees an
  archive written by a future version remains readable, and supports federation with
  external vocabularies.
- A vocabulary GeneaLogic *does* own is nonetheless open when an unrecognized value has a
  **safe reading** and closing it would cost a load failure. Dismissal subject (§6.6) is
  the case: unknown, it round-trips verbatim and suppresses nothing, so the suggestion is
  simply offered again — the behaviour before dismissals existed. Closed, an archive a
  later version wrote would not open at all. The rule remains domain-first; this is what
  the domain test asks when the domain is one whose *extent* is not yet settled.

## 8. Versioning

`schemaVersion` appears on `manifest.json` and every record, as `major.minor` with both
parts decimal integers (`"1.0"`). **The version is archive-wide.** The manifest's value is
the archive's format version; every record's value MUST equal it. The reference
implementation writes both, and a reader uses the record's stamp for exactly one thing:
detecting disagreement with the manifest. Its independent justification is
document-first — a `record.json` lifted out of its archive still says what format it is,
for the same reason it carries its own `uid` rather than trusting its folder.

**There is no forward compatibility.** A build edits an archive only at the version it
writes; it does not load a newer archive with the fields it does not know dropped, and
it does not preserve unknown fields and write them back. (Preservation can write a file
into semantic incoherence, because the dangerous unknown field is one that *constrains* a
known one, and an older build cannot tell which kind it holds. Loading-but-not-rewriting
per record was rejected too: a freeze is a property of a subgraph, not a file.) The rule
is one sentence — **a build does not edit what it cannot fully understand; it says so at
the door** — and it makes the mixed state an error rather than a mode:

- A manifest newer than the build: the archive is refused, naming the version and the
  build's.
- A record newer than the manifest: also refused, naming the file. It is evidence the
  archive is newer and the manifest recording that has not arrived yet (sync delivers
  files one at a time); the build must not stamp the record back down.
- A record older than the manifest — a *straggler*, an edit made on a machine still on
  the older build and delivered after the upgrade — is what migration is for. Until a
  migration absorbs it, it is skipped and reported, never repaired: it is intact, and
  restoring an earlier copy over it would be a downgrade.
- A manifest older than the build: the archive is refused until it is **upgraded**.

**Migration is explicit, not automatic.** Upgrading rewrites the archive in place
(`1.0 → 1.1 → …`), one version at a time, and stamps the manifest after each step. It is
never done on open, because it is not free for the other machines: every one still on
the older build loses the archive the moment the new version is written. A person
consents to that. An unparsable version compares as *newer* — a stamp a build cannot
read is not one it can vouch for.

*Expiry condition:* if 1.0 and 1.1 builds are ever meant to write the same archive
concurrently — a federation question — preservation returns, with per-field rules for
which unknown fields may be carried and which may not.

Changing the on-disk format is the most expensive mistake, so it is governed by
round-trip and migration tests in the reference implementation.

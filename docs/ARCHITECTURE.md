# GeneaLogic — Architecture

> Status: **living design doc.** Phases 0–3 are implemented and merged to `main` —
> the `GeneaLogicKit` engine, the `.index/index.sqlite` lookup index, the `genea`
> CLI, the `GeneaLogicApp` Mac app (§7), and the `GeneaLogicMatch` scoring core
> (§4.6). This document is the design of record; §10 tracks resolved decisions and
> remaining open questions. **Direction and status are [`ROADMAP.md`](ROADMAP.md)'s
> job, and each slice's spec is in [`slices/`](slices/README.md) — not this file's** —
> including test counts, which go stale here every slice.

## 1. What GeneaLogic is

GeneaLogic is a genealogy-focused digital asset management (DAM) platform built
on one inverted premise: **documents are primary, and the family tree is derived
from them.** Most genealogy software asks you to enter a tree by hand and attach
documents as afterthoughts. GeneaLogic treats the archive of source documents as
the source of truth and computes the tree as a *view* over the evidence those
documents contain. This makes the software honest about what is *proven* versus
*assumed*.

The platform has three components, all sharing one core library:

| # | Component | Role |
|---|-----------|------|
| 1 | **GeneaLogicKit** (Swift package) | Cross-platform engine: create/edit archives, add/remove artifacts and files, edit metadata, maintain the derived index, verify integrity. No UI, no networking. |
| 2 | **GeneaLogic for Mac** (SwiftUI app) | Front-end for archive management, plus family-tree construction and family-history analysis. (iOS/iPadOS later.) |
| 3 | **GeneaLogic Server** (Vapor app) | Publishing target: receives published archive snapshots and serves them read-mostly on the Web. |

Both the Mac app and the Vapor app depend on GeneaLogicKit. The package is the
load-bearing contract; everything else is a front-end over it.

## 2. Guiding principles (settled)

1. **Files-first, index-second.** The archive's files + sidecar metadata are the
   durable source of truth. The SQLite index is a *derived, rebuildable cache* —
   if it is ever lost or corrupted, it is regenerated from the files.
2. **Open formats, designed to outlast the software.** PDF/A, TIFF, FLAC,
   FFV1/MKV for preservation masters; UTF-8 for text; JSON for metadata. EDTF
   (ISO 8601-2) event dates; ISO 8601 timestamps. SHA-256 checksums. The schema is documented publicly so the archive is
   interpretable even if GeneaLogic disappears.
3. **Two sources of truth, cleanly separated:**
   - **Evidence** — *what a record says.* Intrinsic to the document. Lives in the
     per-artifact sidecar.
   - **Conclusions** — *what we infer.* Person identities, evidence→person links,
     confidence breakdowns, human review decisions, manual relationships. Lives in
     a separate conclusions layer.
   These never mix. A death certificate states a death date (evidence); the claim
   that *this* certificate belongs to *your* great-grandfather is a conclusion.
4. **The tree is a derived view, not a stored structure.** "Who are John Smith's
   children?" is answered by querying evidence + conclusions, never by reading a
   separately-maintained tree that could drift out of sync. There is no
   tree-editing surface that bypasses the evidence/conclusions layers.
5. **Artifact ≠ file.** An *artifact* is the intellectual record (a particular
   census entry, a death certificate). It may have zero, one, or many physical
   *files*, or only an external pointer. This is what allows records with no local
   scan and future federation with institutional catalogs.
6. **Provenance on every assertion, from day one.** Every metadata assertion and
   every conclusion records who asserted it (human vs. machine), a confidence
   where applicable, review status, and — for externally-sourced records —
   retrieval source/date/checksum. The AI extraction and inference *features* are
   deferred, but the data model that makes them trustworthy is present from v1.
7. **Edit the archive in place.** The Mac app reads and writes the archive
   directly rather than importing into a separate store and exporting later.
   Durability concerns are handled at the app layer (atomic sidecar writes +
   app-level undo journal), not by introducing a second store. The one real
   argument against in-place editing is multi-writer concurrency — and we **do**
   have it, on one machine: the app open on an archive while an agent drives
   `genea` at the same one. Since slice 47 that case is safe rather than
   assumed-away: every mutation holds an archive-level `flock(2)` on
   `.index/<machine-key>/lock` for its whole duration, so two processes take turns
   (§10.5). Two *machines* against one cloud-synced archive remain unsafe —
   `flock` cannot serialize them, and that is still open.

## 3. The archive on disk

An archive is a **directory** ("package"). On macOS it is presented to the user
as a single document (a package bundle), but internally it is plain files that any
human can browse with `Show Package Contents` or any file manager. It is **edited
in place.**

```
MyFamily.genea/                         (a directory; macOS shows it as one document)
  manifest.json                         format version, archive UUID, integrity manifest
  artifacts/
    ART-00452/                          folder name is a friendly slug (non-authoritative)
      record.json                       evidence sidecar — the ONLY convention-named file here
      census-1920.tif                   a file; name is a sanitized slug, recorded in record.json
      census-1920-transcript.txt        the transcript is just a file with role:"transcript"
  conclusions/
    persons/
      PER-001.json                      a person we have concluded exists (GEDCOM X-aligned)
    relationships/
      REL-0007.json                     a concluded relationship (parent-child, spouse, ...)
    links/
      LNK-1043.json                     an evidence→person link with confidence breakdown
    dismissals/
      DSM-0031.json                     a suggestion a human declined, so it isn't re-offered
  .index/
    <machine-key>/                      one per machine sharing this archive (§48) — never synced onto each other
      index.sqlite                      DERIVED cache — rebuildable, never authoritative
      lock                              flock(2) target — one writer at a time, machine-wide (§10.5)
      dirty                             present only while a mutation is in flight (§10.4)
  .trash/
    <uid>/                              a deleted item (ART-… artifact or FIL-… detached file), recoverable until emptied
      payload                           its bytes: an artifact folder, or a single detached file
      deletion.json                     kind-discriminated restore info (TrashEntry)
  .damaged/
    <uid>-<timestamp>.json              a record file as a repair found it, set aside rather than overwritten (§59)
  schema/
    genealogic-archive-1.0.md           a copy of the schema spec, travels with the archive
```

Rationale:
- **Browsable & durable** — no special tool required to read any single record.
- **Edit-in-place friendly** — changing one artifact rewrites one small JSON file
  atomically; large media files are written once and never rewritten on metadata
  edits.
- **`.index/` is disposable, and machine-local** — it lives inside the package for
  locality but is explicitly a cache. Deleting it is always safe; the engine
  rebuilds it. The lockfile and the dirty sentinel live there for the same
  reason: a lock and a crash marker are exactly as machine-local and throwaway as
  the index they guard, and `.index/` is already outside the manifest, the index
  rebuild, and `verifyIntegrity()`.

  **Since slice 48 each machine gets its own subdirectory**, `.index/<machine-key>/`,
  because the package is synced and a shared `.index/` had two machines writing
  the same three files — leaving a provider to reconcile a live SQLite database,
  destroying the receiver's warm cache on every handoff, and littering conflicted
  copies. The key is a hash of the boot volume's UUID (`gethostname()` where that
  is unavailable), prefixed with the derivation it came from; see `MachineKey` for
  why *that* identifier and not the archive's own volume or Application Support.
  Their paths are resolved through `ArchiveLayout` and nowhere else, which is what
  let 48 relocate all three by editing one function.
- **`.trash/` is recoverable, non-authoritative space** — a deleted artifact (or a
  file detached from an artifact) is *moved* here (not erased) so it survives quit and
  can be restored, until the user empties the trash. Like `.index/`, it's a reserved
  top-level sibling of `artifacts/`, so it sits outside the manifest, the index, and
  integrity checks — a trashed item is simply absent from the archive. (Artifacts:
  slice 20; detached files: slice 21 — both keyed by the item's own uid and
  distinguished by the `TrashEntry.kind` discriminator, so they share one store with no
  format change.)
- **`.damaged/` is quarantine, and deliberately not part of `.trash/`** (slice 59) — when
  a repair restores a record the archive could not read, the file it found in place is
  moved here rather than overwritten, because the "damage" may have been an edit someone
  meant. Nothing restores from it and no operation reads it back: it is evidence for a
  human, which is exactly why it isn't a trash entry. `.trash/` is a **uid-keyed**
  namespace whose children are enumerated as items, so anything else parked there reads
  as a *corrupt* entry; and emptying the trash is permanent, so quarantined bytes would
  be destroyed by an action whose listing never showed them. Third reserved top-level
  sibling, outside the manifest, the index and every integrity pass — which cost no
  exclusion logic, because those passes are scoped positively to `artifacts/` +
  `conclusions/` rather than by a list of names to skip.
- **The schema spec travels with the archive** so it is self-describing decades
  from now.

### Integrity (BagIt-flavored)

`manifest.json` carries the archive format version, the archive's UUID, and a
manifest of every file with its SHA-256 and byte length. The package offers
`verify()` to recompute checksums and report mismatches (bit-rot detection), and
`repair()` hooks for restoring from a known-good copy. This is intentionally close
in spirit to the Library of Congress BagIt spec; we may adopt BagIt's
`manifest-sha256.txt` layout directly if interop with preservation tooling proves
useful.

Checksums live in exactly two places: each file's `files[]` entry in `record.json`
(record-local integrity) and `manifest.json` (the archive-wide, tool-verifiable
surface). There are **no per-file `.sha256` sidecars** — they would triplicate the
checksum and, worse, reserve a `<file>.sha256` name that a user file could collide
with (see §4.2.1). The manifest is the single place external preservation tooling
verifies against.

"Every file" includes the archive's own records — each `record.json` and every
`conclusions/**` file — and for those the manifest is the *only* copy of the
checksum, which makes it partly authoritative rather than wholly derived. See the
*Manifest scope* and *partly authoritative* bullets in §10 for what that forbids
(re-hashing an entry the engine did not just write) and what it costs.

## 4. Data model

All core types are `Codable`, `Sendable` value types in GeneaLogicKit. JSON keys are
**plain camelCase** and align *semantically* with **Dublin Core** and **GEDCOM X**
vocabularies — they do **not** carry literal namespace prefixes (no `dc:`/`gen:` in
keys). Mapping to literal DC/XMP happens only at export boundaries. See the formal
spec in [`GeneaLogicKit/schema/genealogic-archive-1.0.md`](../GeneaLogicKit/schema/genealogic-archive-1.0.md).

**Controlled vocabularies come in two flavors** (spec §7). *Closed* ones are
GeneaLogic's own domains (person role, information quality, `createdBy`, file role,
match kind, the two review-status sets) — strict, an unknown value is an error.
*Open* ones map onto external/evolving standards (source authority tier, media type,
name type, relationship type, external-id scheme, fact type) — modeled as
unknown-preserving enums that round-trip any unrecognized value verbatim, so a future
version's value never fails to load or gets silently dropped.

### 4.1 Identifiers & uniqueness

Two failure modes get conflated under the word "collision," and they have opposite
solutions:

- **ID collision** — two records carry the *same* `uid` but are *different* things.
- **Entity duplication** — two records carry *different* `uid`s but describe the
  *same* real-world person/document.

The identifier design eliminates the first and deliberately leaves the second to
the conclusions/matching layer (§4.3–§4.6). **`uid`s are not a deduplication
mechanism.**

Rules:

1. **`uid` is a type-prefixed UUID, globally unique by construction** — e.g.
   `ART-018f3c…`, `PER-018f3c…`. The prefix keeps the type legible; the UUID makes
   it unique with no coordination between archives. **Use UUIDv7** (time-ordered)
   so ids sort chronologically and listings stay roughly browsable. In the model,
   each record kind has a distinct id type (`ArtifactID`, `PersonID`, `FileID`,
   `EvidenceLinkID`, `RelationshipID`, `ArchiveID`) to prevent cross-type confusion
   at compile time; all serialize as plain JSON strings.
2. **`uid` is minted exactly once, at creation, and never copied.** Duplicating a
   record must mint a new `uid`. (Copy-paste duplication and weak RNGs are the only
   realistic local collision sources — random-UUID *math* collisions are
   negligible: ~2.7×10¹⁸ records for a 50% chance.)
3. **Folder and file names are a convenience, not the identity.** Paths may use a
   friendly slug or short label; the authoritative identity is always the `uid`
   *field* inside the record, never the path. This preserves human-browsability
   without making paths load-bearing.
4. **Cross-archive references are always namespaced** — qualified by the source
   archive's UUID (carried in `manifest.json`) or a full resolvable URI, never a
   bare local `uid`. Globally, a record's identity is effectively
   `(archiveUUID, uid)`. This is why sequential per-archive counters were rejected:
   every archive would mint a `PER-1`, guaranteeing collisions on any merge or
   harvest.
5. **Imported/harvested records stay in the external namespace** — they keep their
   `externalIdentifiers` and pass through the candidate/staging layer (§9) rather
   than being minted as native local records, so "authored here" is never confused
   with "pulled in from elsewhere."
6. **Dedupe-by-`uid` on import.** Seeing a `uid` already present means it is
   genuinely the same record (e.g. re-importing a snapshot) — keep one. This is
   safe precisely because rule 2 guarantees `uid`s are never reused for different
   things.

> `localRef` (used inside `personsMentioned`) is a different kind of id: it is
> unique only *within a single record* and identifies a name-as-it-appears, not a
> person. It never escapes the artifact.

> **A note on the examples below:** for legibility, §4.2–§4.6 and the on-disk layout
> in §3 use short tokens like `ART-00452` / `PER-001`. These stand in for two real
> things: the authoritative `uid` is a type-prefixed UUIDv7 (e.g.
> `ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70`), and the folder/file name is a
> non-authoritative friendly slug. They are shown collapsed here only to keep
> cross-references between records readable.

### 4.2 Artifact (evidence) — `artifacts/<UID>/record.json`

The sidecar answers *what does this record say?* — nothing about conclusions.

```jsonc
{
  "uid": "ART-00452",
  "schemaVersion": "1.0",
  "title": "1920 US Census – Smith Family",          // ~ Dublin Core: title (plain key)
  "mediaType": "image",                                // ~ Dublin Core: type. OPEN vocab (preserves unknown)
  "sourceAuthorityTier": "census",                     // OPTIONAL. OPEN vocab: vital|church|government|census|monument|newspaper|bible|compiled|… Absent = UNSTATED, never a default genre
  "sourceDerivation": "original",                      // OPTIONAL. OPEN vocab: original|derivative|authored (GPS, orthogonal to the tier). Absent = UNSTATED, never "original"
  "originalFormat": "digital scan",
  "language": "en",                                    // ~ Dublin Core: language (BCP 47)

  "events": [
    { "type": "Census", "date": "1920-01-15", "location": "Cook County, Illinois, USA" }
  ],

  "personsMentioned": [
    {
      "localRef": "p1",                                // ref unique WITHIN this record (a "name as it appears")
      "nameAsRecorded": "John Smith",
      "role": "subject",                               // OPEN vocab: subject|informant|witness|parent|spouse|godparent|sponsor|declarant|registrar|clergy|midwife|…
      "informationQuality": "primary",                 // DEFAULT for this mention's facts (primary|secondary|undetermined); the informant's proximity, not a quality of the person
      "nameLanguage": "en",                            // OPTIONAL BCP 47 — of the NAME, not the document
      "nameScript": "Latn",                            // OPTIONAL ISO 15924 — orthogonal to the language
      "facts": [                                       // what THIS record says about THIS person (see §10.6, resolved)
        { "type": "Birth", "date": "1875", "place": "Cook County, Illinois, USA",
          "informationQuality": "secondary" }          // OPTIONAL per-FIELD GPS quality; absent = inherit the mention's. State the EXCEPTIONS only
      ],
      "attributes": { "ageAsRecorded": "45" }
    }
  ],

  "locations": [
    { "asRecorded": "Cook County, Illinois, USA", "normalized": null }
  ],

  "transcript": null,                                   // OPTIONAL short inline transcript; a long one is a file (role:"transcript")

  "files": [
    {
      "uid": "FIL-018f…",                              // type-prefixed UUIDv7; stable target for replace/reference
      "path": "census-1920.tif",                       // PACKAGE-ASSIGNED, collision-free, relative to the artifact folder
      "originalName": "Census Scan (final).tif",       // name as the user supplied it — display/export only, never used to locate
      "role": "preservation-master",                   // preservation-master | access-copy | derivative | transcript
      "format": "TIFF",
      "byteLength": 10485760,
      "sha256": "e3b0c4…"
    }
  ],

  "externalIdentifiers": [                             // for future federation; empty for purely local records
    { "scheme": "ark", "value": "ark:/12345/abcdef", "repository": "Example State Archive" }
  ],

  "retrieval": {                                        // present only for externally-sourced records
    "source": "Cook County Vital Records",
    "date": "2026-02-22",
    "checksum": null
  },

  "provenance": {
    "createdBy": "human",                              // human | machine
    "createdAt": "2026-02-22T15:04:05Z",
    "tool": null,                                       // populated when machine-generated (e.g. OCR/NER model id)
    "reviewStatus": "asserted"                          // asserted | machine-suggested | human-verified
  },

  "tags": ["vital-record", "census", "Illinois"],
  "notes": "Page edge cropped; line 12 partially illegible."
}
```

Key points:
- `sourceAuthorityTier` and per-person `informationQuality` live **here** (in
  evidence) because they are properties of the *record itself*, independent of any
  research question — exactly the boundary the design conversation landed on.
  Both source axes are **optional, and absent means unstated** — never a default good
  value. Slice 46b made the tier follow the rule `sourceDerivation` already did: a
  required field forces every entry point to name a genre, and the genre they named
  was `compiled`, the lowest — so uncharacterised documents were asserting something
  about themselves that nobody had claimed. The app surfaces the resulting count
  rather than filling it in.
- `personsMentioned[].localRef` is a name *as it appears in this document*. It is
  **not** a person identity. Identity is a conclusion (§4.3–§4.4), reached by linking
  these mentions to `Person` records.

#### 4.2.1 File naming & uniqueness

A file's identity and its on-disk name are separated, mirroring the record
`uid`/slug split (§4.1). This is enforced in **GeneaLogicKit**, not the app —
because the CLI and any other consumer write files too, the package must be the one
guard. The app contributes only *intent* (replace vs. keep-both); it never encodes
the rules.

- **`path` is package-assigned; `originalName` is preserved metadata.** `attachFile`
  never trusts the incoming basename for `path`. It derives a sanitized, unique
  stored name and records the user's name in `originalName` (display/export only,
  never used to locate the file). "Two files with the same name" is therefore
  structurally impossible to break the archive — the package disambiguates the
  stored name (`census-1920.tif`, `census-1920-2.tif`) while both `originalName`s
  stay intact.
- **Only `record.json` is reserved by convention** inside an artifact folder
  (plus `manifest.json` at the archive root). *Every other file is referenced by
  `path` from `record.json`*, so it needs no magic name and can be freely
  disambiguated. This is why the transcript is a `files[]` entry with
  `role:"transcript"` rather than a fixed `transcript.txt` — a user file literally
  named `transcript.txt` is then a non-event. (And there are no `<file>.sha256`
  sidecars to collide with either; see §3.)
- **Uniqueness is checked under case-folding + Unicode NFC**, and stored names are
  normalized to NFC. This is mandatory for cross-platform safety: the case-sensitive
  Linux server could otherwise author `Scan.tif` + `scan.tif` in one artifact, which
  would collide when the Mac app opens it on case-insensitive APFS. Likewise NFC/NFD
  accent variants (common in genealogical names) are treated as colliding.
- **Names are sanitized before writing**: path separators, control characters,
  leading dots, and trailing dots/spaces are stripped/replaced; length limits are
  enforced; Windows reserved device names are avoided (in case Windows is ever a
  target). Rejection happens *before* any write, never after.
- **No silent overwrite.** Disambiguation is deterministic (`-2`, `-3`, … or a short
  content hash). Replacing an existing file happens only when the app explicitly
  targets that file by its `uid`.
- **Content de-duplication (optional).** Because every file carries `sha256`,
  `attachFile` can detect byte-identical content already present in the artifact and
  *report* it; the app decides whether to reference the existing file instead of
  storing a duplicate.

### 4.3 Person (conclusion) — `conclusions/persons/<UID>.json`

A person is something we have *concluded* exists. Modeled on GEDCOM X so GEDCOM
import/export later is a mapping, not a redesign.

```jsonc
{
  "uid": "PER-001",
  "schemaVersion": "1.0",
  "names": [
    { "type": "birth", "given": "John", "surname": "Smith", "full": "John Smith" }
  ],
  "facts": [                                            // GEDCOM X "facts": birth, death, residence…
    { "type": "Birth", "date": "1871", "place": "Illinois, USA", "supportedByLinks": ["LNK-1043"] }
  ],
  "identifierURI": null,                                // reserved: a resolvable URI for linked-data federation
  "provenance": { "createdBy": "human", "createdAt": "…", "reviewStatus": "human-verified" }
}
```

**Merging duplicates — the one operation that cascades (slice 45f).** Entity
duplication is left to this layer by design (§4.1), so two records for one human being
are an expected state, not corruption; `mergePersons(_:into:)` is how they become one.
It is the single exception to §2.3's no-cascade removal rule: **every other removal
leaves dangling references on purpose**, because the referenced record is genuinely
gone, but the absorbed person was never a second person, so every link and relationship
naming them is still true and is *repointed* rather than orphaned. The survivor keeps
its own `uid` and `provenance` (same concluded identity) and gains the other record's
names and facts; nothing is minted, and no field records that a merge happened — a
forwarding "sameAs" for the absorbed uid would be a format change, and nothing outside
the archive references a `PersonID` before Phase 4 publishing.

**Names merge on exact equality; facts merge on the claim.** A `PersonFact` is a claim
(`type` + `date` + `place` + `value`) *plus the evidence for it* (`supportedByLinks`),
and the two halves behave differently: the same birth recorded from two records is one
conclusion with two citations, not two facts. This is the ordinary case, not an edge
case — a fact recorded from linked evidence carries the link it came from, so two
duplicate persons built from their own sources always disagree on the citations while
agreeing on everything a reader sees. The claim itself must match exactly: `1881` and
`1881~` remain two facts, because deciding those are the same claim is a judgement about
the evidence, not bookkeeping.

Because the rewrite spans records, it returns a `MergeDecision` carrying the
before-state of everything it touched, and `revertMerge(_:)` restores all of it — the
undo shape every other conclusions mutation gets from a single snapshot. Three
collisions the rewrite can create are decided rather than left to read order: two
verdicts landing on one `(artifact, mention, person)` triple resolve in favor of the
**confirmation** (the merge is the later, more specific judgement than a rejection of
one of the two records); a relationship *between* the merged persons is dropped rather
than left as a self-loop; and duplicate relationship edges collapse, union'ing their
facts. Where two records collide, **the survivor's own is the one kept** — not the older
one: `uid`s are only time-ordered to millisecond resolution (§4.1), so "oldest" is a coin
flip for records created in one pass, and the user already said which person to keep.
A collision the merge *didn't* cause — a duplicate the survivor already had — is left
alone; this operation resolves what it creates and does not adopt what it finds.
Dropped records and any citation they strand are reported, never
silent.

### 4.4 Evidence link (conclusion) — `conclusions/links/<UID>.json`

The heart of the inference layer: it connects a mention in an artifact to a
person, and records the **decomposed** reasoning (never a single opaque %).

```jsonc
{
  "uid": "LNK-1043",
  "schemaVersion": "1.0",
  "artifactUid": "ART-00452",
  "personMentionRef": "p1",                            // the localRef inside that artifact
  "personUid": "PER-001",

  "match": {
    "name":      { "kind": "exact",     "score": 100 },
    "nameAlgo":  "double-metaphone",
    "birthYear": { "kind": "within",    "delta": 3, "score": 60 },
    "birthPlace":{ "kind": "within",    "score": 50, "granularity": "specific" },
    "spouseName":{ "kind": "exact",     "score": 100 },
    "parents":   { "kind": "none",      "score": 0 },        // reported, but not scored — see §4.6
    "conflicts": []                                     // populated → strong human-review flag, not averaged away
  },

  "sourceAuthorityWeight": 60,                          // 0-100, from the artifact's sourceAuthorityTier + sourceDerivation
  "informationQualityWeight": 50,                       // 0-100, per-field, e.g. birth on a death cert is secondary
  "aggregateConfidence": 71,                            // 0-100 roll-up, but the breakdown above is what's authoritative

  // Scores and weights are INTEGERS 0-100, not fractions: float text is not
  // canonically reproducible without JCS/RFC 8785, which would put §3's
  // byte-reproducibility rule out of reach for every record the matcher writes.

  "reviewStatus": "human-confirmed",                   // machine-suggested | human-confirmed | human-rejected
  "reviewedBy": "ada",
  "reviewedAt": "…",
  "provenance": { "createdBy": "machine", "tool": "genealogic-matcher/3", "createdAt": "…" }
}
```

**A link record is a human decision** (settled slice 45c; the example above showed a
persisted `machine-suggested` record, which GeneaLogic does not write). Suggestions are
**ephemeral**: `suggestLinks` computes matches, the queue shows them, and nothing reaches
disk unless a person decides. That is what keeps `conclusions/` meaning conclusions — no
read path has to filter unreviewed machine guesses out of the evidence behind a person,
and a re-run reflects the archive as it is now instead of reconciling against stale
suggestion records.

**A pair holds one verdict.** At most one link exists per (artifact, mention ref, person)
triple: `link`, `confirm` and `reject` each replace any existing one, and report what
they displaced (plus any `supportedByLinks` citation the displacement stranded) in a
`ReviewDecision`, so an undo can restore it. Two records for one pair would make the
archive assert that a pair is both resolved and foreclosed — and since `unlink` is
uid-addressed, a duplicated tombstone survives being un-rejected and keeps the pair
hidden while reporting success.

So of the three legal `reviewStatus` values, GeneaLogic writes two:

- **`human-confirmed`** — with the matcher's real dimension scores, `createdBy: machine`
  (a machine proposed it) and `reviewedBy`/`reviewedAt` set (a human decided it). The
  scores are stored **unaltered**, not rounded up because someone agreed: a confirmation
  is a verdict on the pair, not a re-scoring of the evidence. Discarding the breakdown at
  the moment of confirmation would make a confirmed suggestion indistinguishable from a
  hand-made link, which would defeat the point of §4.6. A mention resolved by hand still
  goes through `link()` and gets the honest minimum (`name` only).
- **`human-rejected`** — a **tombstone**, and the reason the matcher has any memory at
  all. Without a record of "no", ephemeral suggestions mean the identical pair is
  recomputed and re-offered forever. It stores the computed breakdown too: a rejection of
  a *strong* match is where the matcher is wrong in a way worth understanding. A
  rejection forecloses **that pair only** — other candidates for the mention stay open,
  and the mention stays unresolved; only a confirmation resolves one. `unlink` on the
  tombstone un-rejects it.
- **`machine-suggested`** — legal on disk, never written here. From another writer it is
  an opinion, not a decision: it neither resolves the mention nor forecloses the pair.

Every consumer that presents evidence — a person's Sources, "which artifacts mention
this person", a fact's citations — **excludes tombstones**, because a link reads as a
citation everywhere it surfaces. The exceptions are deliberate and few: the dangling-
reference sweep (§ integrity) audits tombstones like any other record, since one pointing
at a deleted artifact is as broken as a confirmation would be, and so does the `localRef`
mint, since a rejection claims a mention's ref exactly as firmly as a confirmation does.

### 4.5 Relationship (conclusion) — `conclusions/relationships/<UID>.json`

```jsonc
{
  "uid": "REL-0007",
  "type": "couple",                                    // parent-child | couple | ...
  "person1Uid": "PER-001",
  "person2Uid": "PER-014",
  "facts": [                                           // added slice 43 (couple events)
    { "type": "Marriage", "date": "1918-06-14", "place": "Chicago, Illinois, USA",
      "supportedByLinks": ["LNK-1043"] }
  ],
  "supportedByLinks": ["LNK-1043", "LNK-1101"],
  "reviewStatus": "human-verified",
  "provenance": { "createdBy": "human", "createdAt": "…" }
}
```

**Endpoint convention (resolved slice 43).** For a `parent-child` relationship,
**`person1Uid` is the parent and `person2Uid` is the child**; for a `couple` the two
endpoints are symmetric. The doc originally left the parent-child ordering
unspecified; the relationships UI needs a fixed convention to render "parent of" /
"child of" from either person's perspective, so this is now the contract (enforced in
`Relationship`'s doc comments and the app's role derivation).

**Multi-person events (marriage, birth) — where the date/place lives.** A
`PersonFact` (§4.3) is deliberately *person-scoped*, so an event involving more than
one person is decomposed rather than modeled as a shared multi-participant object,
following GEDCOM X:

- **Marriage / divorce** is a **fact on the couple `Relationship`**, not on either
  spouse — `person1Uid`/`person2Uid` are the participants and the date/place ride the
  relationship, so there is one source of truth and the participants are unambiguous.
  Slice 43 added the **`facts` array to `Relationship`** for this. **Sub-decision
  resolved: reuse `PersonFact`, not a distinct `RelationshipFact`** — GEDCOM X models
  Person and Relationship facts with one shared `Fact` shape, reusing `PersonFact`
  adds the least new format surface ("format changes are the most expensive mistake")
  and lets the same fact editor serve both, and the `FactType` open vocabulary gained
  `Divorce`/`Annulment` (`Marriage` already existed) plus a `coupleCases` subset the
  relationship fact editor offers. The `facts` field is an **additive, back-compatible
  widening** (a pre-slice-43 sidecar with no `facts` key decodes to `[]`), so **no
  schema-version bump** — the same superset reasoning as EDTF dates (§4.2).
- **Birth** is a **person fact on the child** (date/place) plus **`parent-child`
  relationships** to each parent — the parents are *not* stored on the birth fact;
  "born to X and Y" is *derived* from the relationship graph for the tree (§8), which
  keeps a single source of truth (no parent list on the fact that can drift from the
  relationships).

The *conclusion* layer thus aggregates via the relationship graph, not by widening
`PersonFact`/`Event` to carry participants. The **evidence** layer records the raw
material — a marriage certificate `Artifact` carries several role-tagged
`PersonMention`s plus its `Event`s — but its `events[]`/`personsMentioned[]` are
**flat and unpaired**: `events[]` does not record *which* event is about *which*
mention. Slice 44h closed that gap from the other side — each `PersonMention` now
carries its own **`facts[]`** (`RecordedFact`: type, date, place, optional per-field
information quality), so a multi-person record can say whose recorded birth is
whose. `events[]` remains the right home for what the document records about
*itself* (the enumeration, the ceremony); a fact about one named person belongs on
that person's mention. This was **open question §10.6**, now resolved (see §10) —
the matcher mini-phase (slice 45+) consumes it.

### 4.5.1 Dismissal (conclusion) — `conclusions/dismissals/<UID>.json`

```jsonc
{
  "uid": "DSM-0031",
  "subject": "same-person",                            // same-person | parent-child | couple | …
  "person1Uid": "PER-001",
  "person2Uid": "PER-014",
  "match": { /* the breakdown that was declined — §4.4's shape; absent when unscored */ },
  "aggregateConfidence": 62,
  "dismissedBy": "R. Feldberg",
  "dismissedAt": "2026-08-02T10:00:00Z",
  "provenance": { "createdBy": "human", "createdAt": "…", "reviewStatus": "human-verified" }
}
```

**Why the negative needs a record (slice 45m).** Suggestions are computed and never
stored (§4.6), which is what keeps them from going stale — and it means declining one
leaves nothing behind. The next sweep recomputes the same score and offers the same
pair, forever. A rejected *link* has somewhere to live already (its tombstone, §4.4),
but a duplicate-person pair and a suggested relationship have **no mention to
tombstone**, and both land in the app's Review section — a work-owed surface whose
meaning depends on being able to reach empty.

It is deliberately **not** a `Relationship` with an open type: *not the same person* is
an identity assertion, not a family relation, and every consumer of `relationships()`
(Tree, Relatives, the partner/parent projection) would have to learn to filter it. Nor
a `distinctFrom` array on `Person`, which stores each edge twice and lets the halves
disagree.

**One record type, a typed subject.** The same pair of ids can be proposed two ways, so
the record carries *what* was declined and forecloses only that. `subject` is an **open**
vocabulary (spec §7): unknown, it round-trips and suppresses nothing — the pair is simply
offered again — where a closed one would fail the *load*.

**No status field, and no fourth verb.** A dismissal is reversed by deleting it, exactly
as `unlink` reverses a rejection tombstone; a tombstone over a tombstone would have
nothing to mean. `mergePersons` reaches it like every other record — repointed onto the
survivor, and **dropped-and-reported** when the merge makes it self-referential, which is
the user overruling their own earlier judgement.

### 4.6 Confidence framework (rooted in the GPS)

The link `match` block above is the data form of the **Genealogical Proof
Standard** evidence model the research established:

- **Source authority tier** (record-level multiplier): vital/church/government
  records high, census/monument/newspaper medium, compiled trees low. The tier is
  **deliberately coarse** — a genre convenience over the two axes below, which is why
  slice 46 answered "there is nowhere to put a naturalization certificate" with one
  `government` bucket rather than a tier per genre. A draft card's weakness is not its
  genre but that its birth year is the registrant's recollection, and that is a claim
  about the *fact*, which the next bullet already states better.
- **Information quality** (per *field*, not per record): a death certificate is a
  strong *primary* source for date/place of death but a weak *secondary* source
  for the subject's birth/parentage — so birth fields drawn from it carry reduced
  weight. Since slice 44h this is expressible, in **two levels**:
  `PersonMention.informationQuality` is the mention's **default** (read as *how
  close the informant stood to what is being stated about this person*), and an
  individual `RecordedFact` overrides it. Absence on a fact means *inherit*, never
  `undetermined` — so a researcher states the exceptions rather than re-asserting a
  judgment on every fact, and an unqualified fact is never silently downgraded.
  Note that quality is a property of an information *item*: "the quality of a
  person-in-a-record" is not a meaningful GPS claim, which is precisely why the
  per-fact level is the authoritative one and the mention level is a default.
- **Match dimensions**: name (exact / phonetic via Double Metaphone / known
  variant), birth-year proximity with century-widening tolerance, birth-place
  agreement at a **granularity**, spouse/parent/sibling/child name matches,
  residence at a plausible life stage. A dimension's `kind` says *how the comparison
  was reached* and is closed; a layered dimension also carries an open `granularity`
  saying *how far down* it agreed. Those were one closed vocabulary until slice 45h,
  which is how `county`/`country` — the world's administrative tiers, not
  GeneaLogic's domain — ended up inside it. The known granularities are structural
  (`specific`/`partial`/`coarse`/`unqualified`) because the place matcher counts string
  components and holds no gazetteer: it cannot know whether the third component is a
  county, an oblast, or a prefecture, and naming its output administratively claimed
  knowledge the code does not have. **The same gap reaches the branch that looks safest**
  (slice 45n): two places recorded as bare `"Poland"` are *equal*, and so are two recorded
  as bare `"Łomża"` — one pair shares a country and the other a town, and nothing in the
  matcher can tell which. Scoring both a perfect 100 resolved that toward the strongest
  reading and gave a country-level coincidence full corroborating weight; scoring both 30
  would resolve it toward the weakest and demote a real town match. So a single-component
  equality reports `unqualified` and a score deliberately **below the corroboration
  threshold**: it still moves the weighted mean, but an agreement whose evidential weight
  is unknown must not count as *breadth* of evidence. **Uncertainty must never manufacture
  confidence** — the same asymmetry behind positive-only relational evidence and behind
  keeping conflicts out of the mean.
- **The archive supplies the depth a gazetteer would** (slice 45o). 45n's position holds
  only while nothing else can tell a bare town from a bare country — and usually
  something can, in the archive's own other place strings. A researcher who writes
  `"Rypin, Poland"` anywhere has demonstrated that `Rypin` is not a country, so a bare
  `Rypin` agreement elsewhere is town-level agreement and scores as one. The evidence is
  a value written **as the leading component of a multi-component string**: leading proves
  some record named it as the finest level it knew, and not-alone proves something coarser
  sits above it. Two looser readings were tried against the real corpus and each admits a
  value it shouldn't — *any non-final component* promotes the `NY` in `"Brooklyn, NY,
  USA"`, and *never seen with anything below it* rejects `Brooklyn`, whose only
  disqualification is a street address.
  **What the rule proves, stated exactly, because the corpus flatters it:** that the value
  is not a top-level name and that some record treated it as its finest level — *not* that
  it is a town. An archive writing `"Massachusetts, USA"` promotes `Massachusetts`, and
  only this corpus's habit of writing `"Brooklyn, NY, USA"` rather than `"NY, USA"` keeps
  `NY` out: a property of the data, not of the rule. That costs nothing new — a bare region
  has scored 80 against its own qualified form since **45h**'s leading-component branch, so
  the promotion only makes the both-bare case agree with an answer the scorer already
  gives. Telling a town from a state is knowledge no string rule has, and is what the
  parked gazetteer would buy. This needs no gazetteer and no format change; it
  does need the index's `place` projection (v3), because the vocabulary must be **identical
  on every entry point** — the explain path justifies a row the queue produced, and a
  recomputed confirmation *writes* the score — and gathering it from the records instead
  would mean decoding every artifact in the archive to score a single pair.
- **The relational dimensions read the record as a star around its centre**
  (slice 45g). `PersonRole` states a role *in the document* — on a death certificate
  `spouse` means *spouse of the deceased* — so a co-mention's role is relative to the
  record's **principals**, not to whichever mention is being scored. The principals are
  the mentions tagged `subject`, or, when a record names none — a marriage register
  does not — the mentions tagged `spouse`: a record has a focal person, or a couple.
  Scoring a principal, every role reads directly; scoring a satellite, the only
  relation the document states is that mention's own tie to the principals, its role
  seen from the other end, and every other pairing (parent ↔ spouse, parent ↔ parent)
  is **unstated and goes unassessed**. Inferring the sibling and in-law edges instead
  would invent relationships the record never asserted. A record with no centre at all
  — two witnesses to a deed — states no relation between anyone. Where a record has
  *several* principals the satellites are **ambiguous between them rather than
  unstated** (whose parents are the four named on a marriage register?), and are read
  best-of, which is safe precisely because of the positive-only rule below.
- **Relational evidence is positive-only**: it corroborates, it never penalizes.
  A `spouseName` that disagrees is *reported* — a reviewer wants to know the record
  named a spouse who isn't the known partner — but it does not move the roll-up,
  because a name disagreement between two genuinely-married people is the common case
  (maiden against married, Yiddish against Americanized, one clerk's transcription
  against another's) rather than the suspicious one. This is the standard
  record-linkage asymmetry: a field's *disagreement* weight is governed by how often
  truly-matching pairs disagree on it. The two fact dimensions keep their zeros
  because each justifies itself with a conflict sentence; a relational zero explained
  nothing and dragged the mean silently, to the point that recording a **true**
  marriage could lower a **correct** pair's score.
- **Conflict penalty**: a conflict on one field (same name + parents, birth year
  off by 10) drops confidence sharply and raises a review flag rather than being
  averaged away.
- **Person↔person comparison is a second scorer, not the same one** (slice 45j).
  Everything above compares *evidence* with a *conclusion*; asking whether two
  concluded persons are one human being (§4.1's entity duplication) compares two
  conclusions, and **neither side is a source**. So the two GPS weights have nothing to
  measure and are absent rather than defaulted, and the roll-up loses its source-discount
  stage with nothing replacing it — the corroboration factor carries that load alone, and
  bites harder for it, because the action this feeds is a destructive merge rather than a
  row in a queue. The dimensions are the symmetric ones (name over both `names` lists,
  birth year, birth place, partner names, parent names) scored by the same functions, and
  a **death disagreement is a conflict rather than a dimension** — two same-named people
  with two different recorded deaths are two people, which is a sentence a reviewer acts
  on, not a score. **Conflict detection matters more here than anywhere else**: two people
  sharing a name is the ordinary state of a family archive (a grandson carries his
  grandfather's name), and a dated life is what separates that from a duplicate.

Because the breakdown is **stored decomposed**, the UI can explain *why* a match
scored as it did ("strong name + spouse match, birth year off by 3, place matched
to county") instead of showing an opaque "71%."

## 5. Derived index

`.index/<machine-key>/index.sqlite` is a **document store with projections**,
rebuildable at any time from the sidecars + conclusions. It exists purely for fast query and
cross-referencing. The Mac app and the Vapor app both read the tree/analysis views
from here; **neither treats it as authoritative.** A `rebuildIndex()` operation
walks the package and repopulates it.

SQLite chosen for the reasons in the research: single file, serverless,
Library-of-Congress-endorsed for datasets, readable everywhere.

### 5.0 Shape: blob of record, columns as indexes

Each record type gets one table holding the **whole record as a JSON `BLOB`**,
keyed by `uid`, alongside only those fields some query filters or joins on. The
schema, in full:

| Table | Columns | Indexes |
| --- | --- | --- |
| `artifact` | `uid` PK, `slug`, `json`, `search_text` | — |
| `person` | `uid` PK, `json` | — |
| `relationship` | `uid` PK, `json` | — |
| `link` | `uid` PK, `artifact_uid`, `person_uid`, `json` | `person_uid` |
| `dismissal` | `uid` PK, `person1_uid`, `person2_uid`, `json` | both uids |
| `file` | `sha256`, `artifact_uid`, `path`, `byte_length` | `sha256`, `artifact_uid` |
| `place` | `value`, `record_uid` | `record_uid` |
| `unreadable_record` | `path` PK | — |
| `orphaned_record` | `path` PK, `uid`, `json` | — |

`file` and `place` are pure denormalized projections with no blob of their own —
rebuilt wholesale on every upsert of their owning record, which is the simplest way
to keep them in lockstep without diffing old against new.

`orphaned_record` (slice 58) is the last blob of each record the rebuild had to skip,
kept because a rebuild otherwise deletes the only surviving copy of a sidecar that no
longer parses. **It is a separate table so that it is reachable from no other query**
— a preserved record is one the archive cannot currently read, and surfacing it in a
browse list would show a phantom that looks healthy. A `quarantined` flag on the live
rows would instead have made that correctness a thing every future `SELECT` has to
remember.

**Why blobs rather than a column per field.** The usual reason to normalize is that
the database is the source of truth. Here it is explicitly not — the sidecars are —
and that inverts the calculus:

- **The data already has a canonical serialization.** Shredding records into columns
  means maintaining a second, lossy, schema-coupled representation of something whose
  master copy is already JSON.
- **It halves the migration surface.** A normalized index would make every format
  change *two* migrations kept in lockstep. As it is, a format change is a
  `PRAGMA user_version` bump that triggers a rebuild from the sidecars — and the
  rebuild path must exist anyway, so a schema change costs one rebuild.
- **Records are documents.** An `Artifact` nests `files[]`, events, places and
  mentions; normalizing means five-plus join tables and a multi-join to read one
  record, when the dominant access pattern is "give me this whole record by `uid`"
  for the detail pane and the edit path — one blob fetch, no joins.
- **Round-trip fidelity is load-bearing.** The blob is written by the *same*
  deterministic encoder as the sidecar (`GeneaLogicJSONCoding.encoder`, `.sortedKeys`
  — see `AtomicIO.writeJSON` and `ArchiveIndex.upsert`), so it is byte-identical to
  the file. That makes the index's copy a **verifiable** backup of a damaged sidecar
  rather than an approximation — it can be checked against the manifest's recorded
  `sha256` — which is the property slices 58–59 are specced around.

**The rule, therefore: project a field to a column precisely when a query filters or
joins on it; otherwise leave it in the blob.** `file` gained `path`/`byte_length` in
slice 49 for that reason and no other — so the manifest recompute could be one join
instead of decoding every artifact's JSON on every mutation.

**What it costs, stated so the next person doesn't rediscover it.** You cannot query
inside a blob, so a new filter needs either a new projection column plus a rebuild,
or a scan. Every edit re-encodes the whole record (irrelevant at these sizes). SQL
cannot enforce referential integrity across blobs, which is part of why
`findDanglingReferences()` exists as a sweep rather than a foreign key.

**The known ceiling is free-text search.** `allArtifactsWithSearchText()`, which backs
`artifacts(matching:)`'s free-text predicate, does `SELECT json, search_text FROM
artifact` and decodes *every* artifact, filtering in Swift — O(n) decodes per search.
That is deliberate rather than unfinished: SQLite's
`LIKE` case-folding differs from Swift's, and matching in Swift avoids that semantic
drift. FTS5 is already compiled in (`SQLITE_ENABLE_FTS5`) and unused. This is fine at
hundreds of artifacts and will not be at tens of thousands; the upgrade is an FTS5
index plus a decision about the case-folding difference, and it is the first place
this design will need revisiting.

### 5.1 The index *is* the lookup surface

All read/lookup operations (§6.3) go through the index, never through filesystem
scans. The flow for any edit is: **query the index → obtain a `uid` → call the
mutation API with that `uid`.** Because the model types are value types, queries
return *snapshots*, and every mutation is addressed by `uid` — there are no live
object references to keep coherent.

Two return shapes exist on purpose, so that listing and searching never touch the
**filesystem**:

- **`ArtifactSummary`** (and `PersonSummary`) — a narrow snapshot for lists and
  searches: `uid`, title, slug, media type, source tier, primary date, tags, file
  count.
- **`Artifact`** (and `Person`) — the full record, fetched by `uid` when the whole
  thing is actually needed.

**What the summary saves is I/O, not decoding** — worth being exact about, because
the looser phrasing invites an assumption the schema does not support. Per §5.0 the
index stores whole records as blobs and projects only what a query filters on, so
there are no `title`/`tags` columns to read: `summarize()` builds a summary *from a
fully decoded `Artifact`*, and `allArtifacts()` decodes every row. The saving is
real but narrower than "lightweight" suggests — no sidecar is opened, and callers
hand a small value to the UI instead of retaining every full record. The decode cost
is the same O(n), which is the same ceiling §5.0 records for search.

A predicate type, **`ArtifactQuery`**, expresses index-backed filters (free text
over title/transcript/notes — where "transcript" covers both the inline
`Artifact.transcript` and the text of a `role:"transcript"` file, the latter
projected into the index's `artifact.search_text` column at index time — plus tags,
source tier, date range, person mention, …).

**Consistency contract:** queries reflect the last *committed* state. Mutations
update the index as part of the write, so a query immediately after a mutation sees
it. If an archive is edited out-of-band (e.g. a sidecar is hand-edited, or files are
added on another machine), `rebuildIndex()` must run before queries reflect the
change. The index is a cache; the sidecars + conclusions remain authoritative.
Since slice 49 that edit also shows up in `verifyIntegrity()` as a checksum mismatch
— the manifest recorded the bytes the engine last wrote, and cannot tell a
deliberate edit from bit rot — so the full blessed sequence is `rebuildIndex()` then
`rebaseline()`, which is what `rebaseline()` does in one call.

**A record the rebuild cannot read is skipped, never fatal (slice 55).** Anything
that goes wrong reading or decoding one sidecar — a truncated write, a broken
hand-edit, a record from a newer GeneaLogic — leaves that record out of the index
and is reported as `IntegrityReport.Issue.unreadableRecord`; the rest of the archive
indexes and opens normally. The list is re-derived by every rebuild and stored in
`.index/`, so it survives an `open()` that walks nothing and the index stays a pure
cache. What still throws is the index failing to *store* what it read: a rebuild
that cannot record its results is no result, and rolls back. This is the one place
where "the sidecars are authoritative" has to be said as "…and each of them
independently" — one bad record must not cost access to the others.

**A skipped record keeps its manifest coverage** — its own entry, and for an artifact
every entry under its folder — carried forward rather than re-derived. Slice 49's
manifest recompute names the archive's authored files *from the index*, which reads
"absent from the index" as "deleted"; a record that is present but unreadable is
neither, and dropping its entry would both remove its payload files from the
integrity surface and let a repair mint a fresh baseline, turning corrupt-then-repair
into a way to substitute a record's contents without `verifyIntegrity()` reporting it.
**The two mechanisms are coupled: §5.1's skip rule is only safe because §3's
carry-forward rule covers it.**

## 6. GeneaLogicKit — package design

### 6.1 Cross-platform constraints (this is the contract)

The package **must compile and run on Linux** (for Vapor) as well as Apple
platforms. Therefore:

- **Foundation only** in the core. No `AppKit`, `UIKit`, `SwiftUI`, or `Combine`
  in the model/engine modules. UI frameworks belong in the Mac app, not the
  package.
- **Checksums via `swift-crypto`** (Apple's cross-platform SHA-256), *not*
  `CryptoKit` (Apple-only).
- **SQLite via a vendored amalgamation** (first-party `CSQLite` C target, the raw
  SQLite C API) — decided by the Phase 1b spike (see §10 Resolved / `docs/spikes/sqlite-driver.md`);
  it's the only option that builds on the stock Linux harness and pins one SQLite
  version everywhere. The package must not leak the choice into its public API.
- **No dependency on Vapor** anywhere in the package. The server depends on the
  package, never the reverse.

### 6.2 Module layout (as built)

```
GeneaLogicKit/             (one Swift package)
  Sources/
    GeneaLogicModel/    Codable Sendable value types (Artifact, Person, Link, …). Foundation only.
    GeneaLogicArchive/  Open/create/save; atomic sidecar I/O; manifest & integrity (verify);
                        the SQLite derived index (`ArchiveIndex` on CSQLite — NOT a separate
                        module) behind the §5.1 lookup surface.
    CSQLite/            Vendored SQLite amalgamation (C target) backing the index.
    GeneaLogicExtract/  Embedded-metadata extraction (EXIF/IPTC/GPS). Apple/ImageIO behind
                        `#if canImport(ImageIO)`; separate target, core does NOT depend on it.
    GeneaLogicMatch/    (Phase 3, not built) entity-resolution & confidence scoring. Pure fns.
    GeneaLogicSample/   The sample archive (slice 74b): an invented family written through the
                        public API, with committed page images. Used by the app and `genea sample`.
  Tests/                round-trip, integrity, lookup, SQLite-index, extractor, … suites.

GeneaLogicCLI/          Separate top-level package: the `genea` CLI over the engine
                        (swift-argument-parser). NOT a target inside GeneaLogicKit.
GeneaLogicApp/          Separate Xcode project: the SwiftUI Mac app (Phase 2).
```

> Originally the index and CLI were sketched as their own targets *inside* the
> package; as built, the index lives in `GeneaLogicArchive` (it's an implementation
> detail behind the lookup API) and the CLI is its own top-level package.

### 6.3 Public API sketch

```swift
// Open / create. An archive is a directory URL; edits happen in place.
let archive = try Archive.open(at: url)
let fresh   = try Archive.create(at: url)

// Look up existing records (index-backed; see §5.1). This is how you get a `uid`
// in a later session to feed into the mutation APIs below.
let art: Artifact? = try archive.artifact(withID: uid)              // full record by uid, or nil
for s in try archive.artifacts() { print(s.uid, s.title) }          // enumerate -> [ArtifactSummary], streamed/paged
let hits = try archive.artifacts(matching: ArtifactQuery(           // search -> [ArtifactSummary]
    text: "census", tags: ["Illinois"], sourceTier: .census, dateRange: 1918...1922
), limit: 50, offset: 0)
let byPerson   = try archive.artifacts(mentioning: personUID)
let byExternal = try archive.artifact(withExternalIdentifier: ExternalIdentifier(scheme: .ark, value: "ark:/12345/abcdef"))
let bySlug     = try archive.artifact(atPath: "artifacts/ART-00452")    // the "I see this folder in Finder" case
let dupes      = try archive.artifacts(containingFileWithSHA256: hash) // also powers content de-dup (§4.2.1)
// Persons have the parallel surface: archive.person(withID:), archive.persons(matching:).

// Artifacts & files. (Mutations are always addressed by uid — typically one from a lookup above.)
let a = try archive.addArtifact(.init(title: "1920 US Census – Smith", tier: .census))
let f = try archive.attachFile(copyingFrom: localURL, to: a.uid, role: .preservationMaster)
//   ^ assigns a collision-free `path`, preserves `originalName`, computes sha256;
//     returns the FileEntry (incl. its file `uid`). See §4.2.1.
try archive.replaceFile(f.uid, in: a.uid, copyingFrom: newURL)           // explicit, targeted; never silent
try archive.updateMetadata(of: a.uid) { $0.tags.append("Illinois") }     // atomic sidecar rewrite
try archive.removeArtifact(a.uid)

// Embedded metadata (optional; see §6.4). Extraction is injected, never auto-applied
// to genealogical fields — the result is stored as a machine-provenance suggestion.
let extractor = ImageIOExtractor()                                        // from GeneaLogicExtract (Apple build)
try archive.attachFile(copyingFrom: localURL, to: a.uid, role: .preservationMaster, extractor: extractor)

// Conclusions.
let p = try archive.addPerson(.init(given: "John", surname: "Smith"))
try archive.link(MentionRef(artifact: a.uid, localRef: "p1"), to: p.uid, reviewedBy: .human)

// Two records, one person (§4.3). The only cascading mutation: links and relationships
// naming `dupe.uid` are repointed at `p.uid` rather than left dangling, and the decision
// carries the before-state of every record it touched.
let decision = try archive.mergePersons(dupe.uid, into: p.uid)
try archive.revertMerge(decision)                               // undo, however many records moved

// Derived index & integrity.
try archive.rebuildIndex()
let report = try archive.verifyIntegrity()                                // checksum mismatches, missing files
// Files that aren't downloaded to this machine are *not* read — hashing a cloud placeholder
// materializes it (slice 57b). They land in `report.notChecked`, and `report.isComplete` is
// what a "this archive is verified" claim has to gate on; pass `includingDatalessFiles: true`
// to download and hash them anyway.
try archive.rebaseline()                                        // "the disk is right" — after a deliberate hand edit

// Matching (suggests, never commits). A method on the archive, not a free function
// over it: the dependency runs Archive → Match → Model, so the scoring core stays
// archive-free and Linux/Vapor-reusable. The SQLite index stays private either way.
let suggestions = archive.suggestLinks(for: p.uid)              // -> [SuggestedLink], ranked
let inbound     = archive.suggestLinks(forArtifact: a.uid)      // -> [MentionSuggestions]
let worklist    = archive.suggestLinks()                        // -> [MentionSuggestions], whole archive
let why         = archive.matchScore(of: mentionRef, against: p.uid)  // explain one pair
let dupes       = archive.duplicateCandidates()                 // -> [DuplicateCandidate], ranked
//   ^ The OTHER question (§4.1's entity duplication, slice 45j): are two *conclusions*
//     one person? A second scorer, because neither side is a source — DuplicateScore
//     carries a breakdown and no GPS weights, since there is nothing for them to weigh.
//     Each unordered pair once, lower uid first; also transient, also never written.
//   ^ SuggestedLink is transient — pair + breakdown + weights, no uid, never written.
//     The artifact direction is grouped per unresolved mention, and a mention with an
//     EMPTY candidate list is still reported: a flat list of scored pairs cannot tell
//     "nobody matched this name" apart from "already resolved", and the first is the
//     somebody-new case (§4.4). The no-argument form is the same grouped shape over the
//     WHOLE archive — the app's triage worklist — in document order rather than
//     confidence order, since a mention nothing scored has no confidence to sort on.
//     It builds the conclusions corpus once; a caller looping the artifact direction
//     rebuilds and re-projects all of it per artifact for the same answer.
let edges       = archive.suggestedRelationships()              // -> [SuggestedRelationship]
let onRecord    = archive.suggestedRelationships(forArtifact: a.uid)  // the same answer, filtered
let aboutPerson = archive.suggestedRelationships(for: p.uid)          // …and filtered a third way
//   ^ The THIRD question (slice 45l): what do the records already SAY about who is
//     whose that conclusions/ doesn't hold? A stated `mentionRelationships` edge (§6.1)
//     is read verbatim; otherwise 45g's star rule infers one — but only from a `subject`
//     centre, and only when that centre is a single person. A `spouse` centre is a couple
//     document, whose parents belong to one of its parties without saying which, so it
//     yields the couple edge alone and its parents stay unassignable until stated.
//     Both endpoints must be resolved by a confirmed link, and the pair must not already
//     be asserted or dismissed (§6.6); confirm is idempotent, as dismiss is.
//     It carries NO confidence: nothing here was scored, so the reasoning shown is the
//     citation itself — which record, and stated vs. inferred. Transient like the rest.
try archive.confirm(edges[0])   // -> Relationship, human-verified over createdBy: .machine
try archive.dismiss(edges[0])   // -> Dismissal, subject parent-child/couple, no breakdown

// The human decides; only this writes (§4.4). All three return a ReviewDecision:
// the link written, what it displaced, and any citation the displacement stranded.
try archive.confirm(mentionRef, as: p.uid, match: why)
try archive.reject(suggestions[0])                              // a tombstone; unlink() undoes it
```

> **API conventions.** Public APIs follow the
> [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/):
> imperative verbs for mutating calls (`addArtifact`, `attachFile`), nouns for
> non-mutating accessors (`artifact(withID:)`, `artifacts(mentioning:)`),
> prepositional argument labels, default-valued parameters last, and named value
> types over bare tuples (`MentionRef`, not `(ArtifactID, String)`). Throwing engine
> methods carry `- Parameters:`/`- Returns:`/`- Throws:` doc markup. `schemaVersion`
> is engine-owned, not an initializer parameter. The derived index is never exposed.

### 6.4 Embedded metadata extraction (EXIF / IPTC / XMP)

When a file is added, it often carries embedded metadata (a photo's EXIF, IPTC, or
XMP block). GeneaLogic can capture this, but the design splits the work along a
hard line: **extraction** lives in the package behind a seam; **interpretation**
lives in the app and is human-confirmed.

**The governing rule — embedded metadata is a *suggestion*, never an auto-applied
genealogical fact.** It is *capture* metadata, which for a genealogy archive is
frequently the wrong thing to trust. Canonical trap: scanning an 1920 census today
produces a TIFF whose EXIF `DateTimeOriginal` is the **scan date (this year)**, not
the document's 1920 date; EXIF GPS, if present, is the scanner's location, not the
event's. Auto-applying these to `events[].date`/`locations[]` would silently
corrupt the archive — the exact failure the "proven vs. assumed" philosophy exists
to prevent. So extracted values are always written with `provenance.createdBy:
"machine"` and `reviewStatus: "machine-suggested"`.

**Layering:**

- **Extraction → package seam (shipped: `GeneaLogicExtract` / ImageIO).**
  Extraction is a pure, deterministic, testable operation that a headless CLI
  `attach` also wants — so the *contract* belongs in the package. But the natural
  Apple tool (ImageIO / `CGImageSource`) is Apple-only, and the core must stay
  Foundation-only for Linux. Resolution:
  - The core defines a neutral `EmbeddedMetadata` value type (namespaced
    key-values: `exif:*`, `iptc:*`, `gps:*`, …) and a `MetadataExtractor` protocol —
    **dependency-free**.
  - `attachFile(...)` takes an optional injected `MetadataExtractor` (or
    pre-extracted `EmbeddedMetadata`); the package owns *where the result lands and
    with what provenance*, and unit-tests that plumbing identically for CLI and app.
  - The concrete extractor ships in a **separate target, `GeneaLogicExtract`, that
    the core does not depend on** — built in Phase 2: `ImageIOMetadataExtractor`
    reads EXIF/IPTC/GPS on Apple platforms (images; AVFoundation/video later),
    deterministically sorted, with its ImageIO code behind `#if canImport(ImageIO)`
    so the target builds empty on Linux. `MetadataExtractors.makeDefault()` picks
    the platform extractor (`nil` on Linux). A Linux conformer (libexif / ExifTool /
    pure-Swift) can be added later with no change to the core or its public API.
- **Interpretation → app, human-confirmed, permanently.** Deciding *which*
  genealogical field an embedded value maps to is policy and UX, not a deterministic
  transform — and it's where the scan-date trap bites. It belongs in the app's
  ingest review step. Conservative defaults: capture dates may populate
  technical/administrative fields (e.g. `xmp:CreateDate`), **never** the genealogical
  `events[].date`, unless the user explicitly applies them. *Phase 2 so far surfaces
  captured metadata strictly read-only ("Embedded Metadata (Suggestions)"); the
  explicit, human-confirmed apply step lands with the metadata editor.*

Note: Vapor receives already-processed snapshots and does not ingest raw files, so
extraction is not currently a *shared* need — another reason to keep the engine in
an optional target rather than the core.

### 6.5 Format versioning & migration

`manifest.json` and every record carry `schemaVersion`, and **the version is
archive-wide** (spec §8, slice 64): a record's stamp must equal the manifest's, and a
build edits an archive only at the version it writes. There is no forward
compatibility — a newer manifest, or a single newer record, is refused at the door
rather than decoded with unknown fields dropped and written back down. A record that
arrives before its manifest is found without reading the archive (slice 70). `open` reads
the stamps only of records that have no manifest entry or no longer match their entry's
size. The drift guard, Verify and Repair read the stamp of any record that differs from
its entry before calling it damage. The package
owns a migration pipeline (`v1 → v1.1 → …`), but it is **explicit, not run on open**:
`Archive.upgrade(at:)` / `genea upgrade` runs it, because upgrading locks out every
machine still on the older build and a person consents to that. Changing the on-disk
format is the most expensive thing to get wrong, so round-trip and migration tests
exist from the first commit.

## 7. GeneaLogic for Mac

A SwiftUI app that opens a `.genea` package and edits it in place via
GeneaLogicKit.

> **Phase-2 hosting decision — `WindowGroup`, not `DocumentGroup` (for now).**
> The intent above is a "document-based app," but `DocumentGroup`'s model
> (read a snapshot into memory → SwiftUI writes a `FileWrapper` back on save)
> fights the engine, which is the sole writer and persists *immediately* and
> atomically (`rename(2)`) while maintaining `.index/index.sqlite`. Two writers
> to one package is a corruption risk. The clean reconciliation — a **read-only
> `DocumentGroup` viewer** (`ReadableDocument`) plus engine-owned out-of-band
> writes coordinated via the document's `NSFileCoordinator` — exists only in the
> **SDK-27 / macOS-27** document API, which won't run on the current macOS 26
> toolchain. So Phase 2 uses a plain **`WindowGroup`** with an app-driven flow:
> opening uses SwiftUI `.fileImporter` (filtered to the registered `.genea`
> package type), creating uses `NSSavePanel` (no SwiftUI idiom for picking a
> not-yet-existing destination the engine then populates); the engine owns every
> write and the app patches its in-memory `[ArtifactSummary]` list from each
> mutation's return value (no full reload). **Revisit the `ReadableDocument`
> viewer once the deployment target can move to macOS 27** — it would add native
> recents/restore at the cost of per-mutation coordinated-write bookkeeping.
>
> **Window model → multi-archive, one archive per window (slice 4, as built).**
> Slices 1–3 used a single app-wide model (one archive at a time). Slice 4 moved to
> a **single value-based `WindowGroup(for: URL.self)`** whose bound value drives the
> window: `nil` is the welcome screen, a non-`nil` URL is that archive. Each archive
> window owns a **per-window `ArchiveModel`** (`.id(url)`-keyed), not one shared
> model. The group *deduplicates by value*, so `openWindow(value:)` for an
> already-open archive focuses its window instead of spawning a second — which also
> retires the old "Finder double-click opens a second window" limitation.
>
> Three wrinkles drove the as-built shape:
> - **Security scope across the value boundary.** `openWindow(value:)` *serializes*
>   the URL, and the deserialized copy can't `startAccessingSecurityScopedResource()`
>   on its own. An **`ArchiveAccessStore`** (a `@MainActor` singleton) acquires the
>   scope while we still hold the original picker URL — *before* `openWindow` — and
>   retains it, so the sandbox extension stays active process-wide until the window
>   closes. Idempotent `acquire` + release-on-close stays balanced under value dedup.
> - **Finder-open spawns a transient welcome window.** SwiftUI delivers each
>   external `onOpenURL` to a *freshly spawned* window (starting at `nil`), so a
>   welcome window already on screen is left behind. `onOpenURL` therefore always
>   routes through `openWindow(value:)` (preserving dedup), and a welcome window
>   dismisses itself once any archive is open (`hasOpenArchive` + `initial: true`),
>   guarded by `url == nil` so the window *becoming* an archive is spared. Opening
>   from the welcome screen's own buttons instead writes the window's `url` binding,
>   transforming it in place.
> - **File-menu commands** target the key window's `ArchiveModel` via
>   `@FocusedValue`; New/Open present AppKit panels (window-independent) and then
>   `openWindow(value:)`, so they work with no window open (retiring slice-3's
>   `ensureWindow` workaround for *Open* doing nothing with no window open). Hence the open-panel split: the welcome
>   screen uses SwiftUI `.fileImporter` (a view can host it; stays drivable), the
>   File menu uses `NSOpenPanel` (a `Commands` body can't host one).
>
> Session-scoped only (`restorationBehavior(.disabled)`): a bare `URL` window-value
> doesn't carry sandbox access, so windows aren't restored across relaunch — a fresh
> launch shows a single welcome window. Bookmark-backed restoration is a later
> follow-on.

**Shipped so far (Phase 2, slices 1–10):** open/create + browse a `.genea`;
drag-in / Add Media ingest via `GeneaLogicExtract` with read-only embedded-metadata
suggestions (§6.4, scan-date trap); `.genea` registered as a package document type
(Finder open + package-aware open panel); multi-archive windows (one archive per
window, value-deduplicated, with a security-scope bridge across `openWindow`); the
metadata editor (explicit Edit/Done mode, one `updateMetadata` write) + the
human-confirmed apply step that promotes an embedded-metadata suggestion into an
Event/Location only after the human picks the field and corrects the value (§6.4);
attach-to-existing + file roles; sidebar search via `artifacts(matching:)`; and the
transcript editor — a dedicated `TextEditor` sheet for the inline `transcript`, plus
indexing `role:"transcript"` *file* text (the `artifact.search_text` index column,
§5.1) so search covers file transcripts; **undo/redo + detach/replace file** (the
app-layer-durability bullet below); and **undoable artifact deletion** (sidebar
Delete Artifact… → confirm; the engine stages the whole folder so `removeArtifact`/
`restoreArtifact` round-trip). Still to come: people/tree, explainable confidence.

- **Archive management**: ingest media (assign UID, compute checksum, create
  sidecar), browse/search artifacts, edit metadata, manage transcripts, attach
  preservation masters + access copies.
- **People & tree**: review machine-suggested links, confirm/reject/merge person
  identities, and view the derived tree. The tree view is read-computed from
  evidence + conclusions; relationship edits go through the conclusions layer, not
  a free-floating tree editor.
- **Explainable confidence**: surface the decomposed `match` breakdown so the user
  makes informed confirm/reject calls.
- **App-layer durability** (slices 9–10, shipped): atomic writes are structural —
  every sidecar/manifest/media write goes through `AtomicIO` (write-temp-then-
  `rename(2)`, crash-safe; since slice 69 the temp is flushed with `F_BARRIERFSYNC`
  / `fsync` before the rename, so a power cut cannot land the rename ahead of its
  data — ordering, not durability of the last write). On top of that, **in-session, per-window `UndoManager`
  undo/redo** for every destructive in-place op: metadata/transcript/apply register a
  whole-record-**snapshot** restore (undo/redo are ordinary `updateMetadata` writes,
  so the engine stays the sole writer); file ops use the engine's **reversible**
  `detachFile`/`replaceFile` (each returns a `FileChange` after staging the bytes it
  would destroy into a temp dir *outside* the package) and `revert(_:) -> FileChange`,
  which applies the inverse faithfully (re-adds the exact `FileEntry` — `uid` stable —
  or restores prior content) and returns the opposite change; **artifact deletion**
  works the same way one level up — `removeArtifact(_:) -> ArtifactDeletion` stages the
  whole folder, `restoreArtifact(_:)` brings it back (uid faithful, conclusions left
  untouched per §2.3, which is what makes it reversible). Undo is **in-session only** —
  staged bytes live in a temp dir, not the package, so they don't outlive the host's
  undo history; a persisted cross-relaunch journal (and a soft-delete/tombstone Trash,
  and putting `Add Media` ingest on the stack) are possible later follow-ons.
- **iOS/iPadOS**: not v1, but the Foundation-only package keeps the door open. The
  package-as-directory model needs care under iOS sandboxing (document picker /
  app container), noted as a future concern.

## 8. GeneaLogic Server (Vapor) — publishing target

The Mac app is the editor and source of truth. **Publishing is a snapshot upload**,
not live sync — no multi-writer, no conflict resolution (matching "mostly a
publishing target").

- **Publish pipeline (Mac → server)**: the app produces a published snapshot of an
  archive — a zipped `.genea` (or a filtered subset) — and uploads it. The server
  stores it and serves from the snapshot's own `.index/index.sqlite` (read-only),
  rebuilding the index if absent. Because the package runs on Linux, the server
  reuses the exact same read/query code.
- **Privacy / redaction is a first-class step.** Publishing genealogy data has
  strong norms against exposing living individuals. The publish pipeline filters
  living persons and records flagged private *before* upload, so private data never
  leaves the Mac. Redaction policy is configured Mac-side.
- **Web surface (read-mostly)**: browse artifacts, view a published person and the
  evidence behind each fact, and a public tree view. Querying / record extraction
  by visitors is a later capability.
- **Not in scope for v1**: collaborative editing, accounts that write back to
  archives, federation endpoints.

## 9. Future / stretch (designed-for, not built yet)

The model deliberately leaves doors open so these don't require retrofits:

- **GEDCOM & GEDCOM X import/export** — the person/relationship model is already
  GEDCOM X-aligned. (Targeted shortly after the core, see roadmap.)
- **AI-assisted enrichment** — OCR/transcript generation, named-entity extraction,
  relationship inference. Every assertion already carries human-vs-machine
  provenance, confidence, and review status, so machine output stays clearly
  flagged and reviewable.
- **Federation / external publishing** — `externalIdentifiers`, `retrieval`
  provenance, artifact-vs-file separation, and a reserved person `identifierURI`
  are all present so OAI-PMH harvesting, IIIF image pulls, a candidate/staging
  layer for unconfirmed external matches, and (eventually) an OAI-PMH *provider*
  endpoint can be added without schema upheaval.
  - **Identifier namespacing makes this safe (see §4.1).** Because every `uid` is a
    globally-unique type-prefixed UUIDv7, and every cross-archive reference is
    qualified by the source archive's UUID (effectively `(archiveUUID, uid)`),
    merging or harvesting archives never produces an **ID collision** — references
    stay valid with no rewriting. The hard federated problem is the *opposite* one,
    **entity duplication** (two archives mint different `uid`s for the same real
    person); that is by-design the job of the matching/candidate layer, not the
    identifier scheme. Sequential per-archive counters would have made collisions
    certain on merge, which is why they were rejected.

## 10. Open questions

### Still open (later phases)

2. **Published-snapshot format** (Phase 4) — zipped `.genea` as-is vs. a
   purpose-built, already-redacted publish bundle. Leaning toward a redacted bundle
   so private data is removed at the source.
3. **BagIt conformance** — adopt the literal BagIt manifest layout, or stay
   "BagIt-flavored" with our own `manifest.json`?
4. **Index staleness / out-of-band-edit detection.** The `.index/index.sqlite`
   cache (Phase 1b) is kept in lockstep by every engine mutation, and `open()`
   auto-rebuilds it when the file is **missing, unopenable, corrupt past the
   header (`PRAGMA quick_check`, slice 63), or schema-version stale** — but it
   does **not** detect *content* drift. A healthy-but-stale index
   (a hand-edited `record.json`, sidecars added on another machine, a git
   merge/cloud sync) serves stale reads until `rebuildIndex()` is called
   explicitly; `verifyIntegrity()` catches payload-file drift via `manifest.json`
   (checksum/size/unreferenced) but is **blind to sidecar metadata edits** (sidecars
   are deliberately outside the manifest). A real gap once archives are synced,
   merged, or hand-edited. Options, increasing cost: (a) a cheap **mtime/count
   watermark** in the index `meta` table, stat-compared on `open()`; (b) a
   monotonic **generation marker** the engine bumps per write; (c) fold sidecar
   checksums into the manifest so `verifyIntegrity()` reports metadata drift as an
   integrity issue (ties into question 3). Revisit when sync/federation lands
   (Phase 4+).

   **Narrowed by slice 47, not closed.** `.index/<machine-key>/dirty` now catches drift *this
   engine caused* — a mutation that wrote the sidecar and then died or failed
   before the index write leaves the sentinel, and the next `open()` rebuilds. It
   is deliberately blind to everything the engine did not start: a hand-edited
   `record.json` or a sidecar arriving from cloud sync leaves no marker and still
   serves stale reads. That is what options (a)–(c) are still for, and (b)/(c)
   are format changes.

   **Option (c) shipped (slice 49)** — *the manifest covers everything authored*.
   `manifest.files` now carries every `record.json` and every `conclusions/**`
   record, minted at write time and **carried forward rather than re-derived**, so a
   recompute cannot launder corruption; `verifyIntegrity()` reports a hand edit, a
   sync delivery, and bit rot alike (it cannot tell them apart, and does not guess),
   and `rebaseline()` is how a human says the disk is right. When the archive was
   opened with an unresolved `.index/<machine-key>/dirty` sentinel, a mismatch on an authored file
   is reported as `.interruptedWrite` instead — suspect rather than corrupt.

   **Stale *reads* remain open.** Detection is not self-healing: a hand-edited
   sidecar still serves stale query results until `rebuildIndex()`. That wants
   option (a)'s cheap watermark — **claimed by slice 60**, which found that
   it needs no format change after all: since (c) shipped, `manifest.files` already
   changes whenever anything the index derives from changes, so the watermark is a
   digest of data the format has and only the index records which state it was built
   from. That also **supersedes option (b)** rather than deferring it: a counter
   needs a new field, and two machines bumping independently reach the same value
   from different states, so it discriminates less than a content digest.
5. **Concurrent modification across processes.** Sibling to question 4, but for
   changes that *do* reach the index: a second GeneaLogicKit process commits to
   the same `.index/index.sqlite` while a first `Archive` handle is open.

   **Resolved for one machine (slice 47).** Every mutation now runs under an
   archive-level advisory `flock(2)` on `.index/<machine-key>/lock`, held for the whole
   mutation, so two processes take turns rather than interleaving; a blocked
   writer waits up to 5s and then throws `ArchiveError.archiveBusy` naming the
   holder's pid, rather than hanging. Every SQLite connection sets a matching
   `busy_timeout`, so the old "concurrent index write throws `SQLITE_BUSY`
   immediately" failure is gone. The in-memory `Manifest` — the datum this
   question singled out — is re-read from disk at the start of each mutation,
   closing the lost-update on `name` (`files` already self-corrected via
   `recomputeManifestFiles`), **and** on the read path `verifyIntegrity()` uses,
   whose staleness was otherwise unbounded rather than bounded by one mutation.

   **Readers deliberately take no lock**, so the pre-existing read coherence
   still carries them: the index is a **read-through** connection (each lookup is
   a fresh autocommit `SELECT`, no long-lived read txn), so reads already reflect
   another process's *committed* changes. The accepted consequence: a read
   concurrent with a mutation may observe the pre-mutation state — stale, never
   torn, and bounded by that mutation's duration. Making the app *notice* another
   writer's changes without a manual refresh is an app-layer concern, not an
   engine one (slice 51).

   **Readers take no *archive* lock, but they do take the process-local one —
   which is why the ordering of the two matters (slice 52).** 47 had a mutation
   take `Archive.lock` and *then* wait on the flock, so a writer blocked on
   another process held the lock readers need for the whole wait: a measured
   `artifacts()` cost **1.82s** where the paragraph above promises "bounded by
   that mutation's duration". The wait now happens **outside** `Archive.lock` (a
   separate `writerLock` admits one in-process writer, keeping the non-re-entrant
   flock safe), so the bound is the mutation *body* — 0.5ms in the same
   measurement — and it is what makes the app's off-main-actor mutations actually
   buy responsiveness rather than relocate the freeze to the next read.

   **Still open: two machines, and mutual exclusion is not the remedy.** `flock(2)`
   works because one kernel arbitrates every contender; a cloud-synced folder is a
   local directory with a store-and-forward daemon and no arbiter, so two Macs both
   take "the" lock and proceed. Nor can it be rebuilt in userspace over that
   channel: two machines each write a claim, neither has received the other's, both
   proceed — and no finite wait repairs it, because a machine can be offline for
   days with a healthy local filesystem, which makes "no competing claim" and "an
   undelivered competing claim" indistinguishable. The primitive at this distance is
   optimistic — let writes happen, detect divergence, reconcile — and the archive is
   shaped for it: per-record sidecars, UUIDv7 identity, and no central mutable state
   except a recomputable manifest and a rebuildable index, so two machines editing
   different records do not collide at all. `manifest.json` is the one collision
   point, and slice 49's carry-forward entries make it mergeable fact by fact. See
   Phase 3.5 slices 60, 48 and 50 ([specs](slices/README.md)).

### Resolved

- **Evidence-layer event ↔ person-mention association** (was open question §10.6)
  — **resolved toward (b), mention-scoped facts** (slice 44h). Each
  `PersonMention` carries its own `facts[]`: what *this* document records about
  *this* person. An artifact's `events[]` and `personsMentioned[]` stay flat and
  unpaired, which is fine when a record names one person and useless when it names
  six — and a census household, a metrical register page, or a marriage
  certificate naming the couple plus both sets of parents is this project's norm,
  so "which recorded birth is whose" had no representation at all. Option (a), a
  top-level GEDCOM X `Event` with participant `roles`, stays available later for
  genuinely shared events; per-*person* recorded facts are person-scoped even in
  GEDCOM X (the *persona* model), so (b) is the right primitive here and it makes
  slice 42c's suggestion scoping exact rather than heuristic.
  **Sub-decision resolved the other way from slice 43's:** these use a **new
  `RecordedFact` type, not `PersonFact`**. Slice 43 reused `PersonFact` for
  `Relationship.facts` because a relationship *is* a conclusion, so that type's
  `supportedByLinks` means exactly what it says there. On a mention it would not:
  it points into `conclusions/`, and an evidence sidecar referencing a conclusion
  inverts §2.3's one-way dependency. A second small type costs less than a format
  in which evidence can cite conclusions. `RecordedFact` also carries an optional
  per-fact `informationQuality`, which is the GPS's per-*field* quality (§4.6) that
  a single mention-wide value cannot express — a death certificate is primary for
  the death it records and secondary for the birth it mentions.

- **SQLite driver** — **vendor the SQLite amalgamation** as a first-party `CSQLite`
  C target (one `sqlite3.c`, our own module map, flags `SQLITE_ENABLE_FTS5` /
  `THREADSAFE=1` / `DQS=0`). Decided by the Phase 1b spike (`docs/spikes/sqlite-driver.md`):
  the stock Swift Linux image ships SQLite's runtime `.so` but **not** `sqlite3.h`
  (true of `swift:6.1`, where the spike ran, and still of `swift:6.3`), so both
  system-`libsqlite3` **and** GRDB (whose C shim `#include`s that header) fail to
  build on `scripts/linux-test.sh` unmodified — only the amalgamation builds on the
  stock harness. It also pins **one** SQLite version across macOS/Linux/server
  (system + GRDB already drift, 3.51 vs 3.45) and gives us compile-flag control,
  with zero external Swift dependency. Cost: ~8.7 MB vendored `sqlite3.c` we bump for
  security fixes. The lookup API (§5.1, §6.3) stays final — the `.index/index.sqlite`
  backing replaces the in-memory `ArchiveIndex` with no public-signature change.
  (Phase 1b.)
- **Conclusions granularity** — one file per person/link/relationship (clean diffs,
  durability). Implemented in Phase 1a.
- **Per-file `.sha256` sidecars** — **dropped** (checksums live in `record.json` +
  `manifest.json`; §3, §4.2.1).
- **Content de-duplication default** — `attachFile` **always stores** the new file
  and **reports** byte-identical siblings via `AttachedFile.duplicatesOf`; it never
  silently skips the copy. (Phase 1a.)
- **Manifest scope** — `manifest.files` lists **artifact payload files, every
  `artifacts/<slug>/record.json`, every `conclusions/**` record, and the schema
  spec**; not `manifest.json` itself, nor `.index/`/`.trash/`/`.damaged/`. *Revised in slice 49
  (Phase 3.5) — Phase 1a scoped it to payload + spec on the grounds that the rest was
  "re-derivable". It isn't: a transcription, a mention, a fact, the whole conclusion
  layer can be re-derived from nothing, while a preservation master is the one thing
  here with a physical original and a backup behind it. The old scope caught rot in
  the most reproducible data and missed it in the least.*
- **The manifest is partly authoritative, not wholly derived** — a payload entry is a
  copy of the checksum `record.json` authored at attach time and is re-derived every
  commit; an entry for a `record.json` or conclusion record is the **only** record of
  those bytes, so it is minted when the file is written and thereafter **carried
  forward verbatim, never re-hashed**. Re-deriving it would launder corruption: rot
  gets re-measured, written down as expected, and never reported again. Accepting a
  deliberate out-of-band edit is therefore an explicit `rebaseline()`, never
  automatic. (Slice 49.)
- **`manifest.updatedAt` semantics** — bumped whenever `files` changes, which since
  slice 49 includes every conclusions write. *Phase 1a had it the other way (a
  conclusions write touched nothing the manifest described); once those records are in
  `files`, the same rule points the other way.* A mutation that changes no tracked
  file — an index rebuild, a trash purge — still writes no manifest.
- **`removeArtifact` cascade** — does **not** rewrite conclusions to clean up links
  referencing a removed artifact (that would cross the evidence/conclusions
  separation, §2.3); surfacing dangling references is integrity's job. (Phase 1a.)
- **`repair()`** — an honest throwing stub for now; a real repair needs a
  safe-vs-destructive taxonomy + user-consent flows (Phase 2+). (Phase 1a.)
- **Manual `link()` representation** — a human confirmation is recorded as
  `reviewStatus: .humanConfirmed` with an honest-minimum `MatchBreakdown` (name
  dimension `.exact`/`1.0`, every computed dimension `nil` = "not assessed",
  `aggregateConfidence: 1.0`) — never forged machine-style scores. Phase 6 (the
  matcher) may revisit once real machine-scored links exist. (Phase 1a.)

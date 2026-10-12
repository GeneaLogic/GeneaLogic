# GeneaLogicCLI

`genea` is the headless command-line front-end for a [GeneaLogic](../docs/ARCHITECTURE.md)
archive — a thin layer over `GeneaLogicArchive` (the engine, in `../GeneaLogicKit`)
built with [swift-argument-parser](https://github.com/apple/swift-argument-parser).

Build/run:

```sh
swift build --package-path GeneaLogicCLI
swift run --package-path GeneaLogicCLI genea --help
```

## Output conventions

- Normal results go to **stdout**; errors go to **stderr** with a non-zero exit.
- **List commands** print one record per line, tab-separated, with no header, so
  they pipe: `genea find <archive> "census" | cut -f1`, `genea person list … | cut -f1`.
- **`show` is the human register** — sections, indices and date glosses. Script
  against the list commands, read `show` yourself.
- `verify` exits non-zero if the integrity report is not clean (see below) — the
  one place a successful engine call still produces a non-zero exit, by design.

## Command layout

The commands come in two eras. The original verbs (`create`, `add`, `attach`,
`set-meta`, `set-role`, `replace-file`, `remove`, `detach`, `list`, `find`,
`lookup`, `show`, `verify`, `reindex`) are **artifact**-scoped by convention —
they predate there being anything else to address, and the read/file verbs stay
flat with them. The Phase-3 conclusions surface groups under nouns (`person …`,
`relationship …`, `fact …`, `trash …`, `match …`), leaving flat only the verbs that
join two records: `relate`/`unrelate` and `link`/`unlink`. The artifact-scoped
evidence sub-records get their own nouns too — `mention …`, `event …`, `place …`,
each taking the artifact positionally.

Two layers run through all of it, and the commands keep them apart
([ARCHITECTURE §2.3](../docs/ARCHITECTURE.md)):

- **Evidence** — what a document says. `mention add` records "the name as it
  appears here"; that is never an identity. `mention fact add` records what the
  document says *about that person*, so a multi-person record can say whose birth
  year 1892 is.
- **Conclusions** — what you have determined. `person add` concludes a person;
  `relate` concludes a relationship. `fact add` asserts a fact — a different
  command from `mention fact add`, because a conclusion is a different thing from
  what a source states.
- `link` is the bridge between them, and only a human asserts it. `match …`
  proposes where that bridge might go and explains its reasoning, but never
  crosses it on its own: a suggestion becomes a record only through `match
  confirm` or `match reject`.

Removals never cascade. Deleting a person leaves the relationships and links that
named it dangling rather than rewriting other records. **Each command reports what
it left behind**, at the moment it happens, and `genea verify` sweeps for the
survivors afterward — its **Dangling references** section is informational (it
never changes the exit code; only file-integrity problems do). Dangling endpoints
also render as `(deleted person)` / `(deleted artifact)` in `person show`, keeping
the uid visible so the stale record stays removable.

## Commands

### `genea create <path> [--name <name>]`

Create a new, empty archive at `<path>` (the directory is created if absent).

```sh
genea create ./MyArchive --name "Smith Family Research"
```

### `genea sample <path>`

Create the sample archive at `<path>`, which must not exist yet: an invented family's
nine documents, each with a page image, and twelve people. Most of the evidence is
linked; eleven names are not (the whole 1920 census among them), so `genea match
suggest` has something to propose, and `genea person duplicates` finds one pair. The app's welcome screen builds the same
archive.

```sh
genea sample ./Sample.genea
```

### `genea add <archive> --title <title> [--media-type <m>] [--source-tier <s>] [--source-derivation <d>] [--tag <tag> ...] [--notes <n>]`

Add a new artifact and print its minted `uid` (`ART-…`) on stdout — capture it
for later commands.

`--media-type` and `--source-tier` are open vocabularies (Dublin Core / GPS):
known values (`image`, `text`, `sound`, `video`, `document` /
`vital`, `church`, `census`, `newspaper`, `bible`, `compiled`) map to their enum
case; any other string round-trips as `.unknown(String)`.

`--source-derivation` (`original`, `derivative`, `authored`) is the GPS axis
**orthogonal** to the tier: a parish register page and an online index typed from
it are both `church`, and are not equal evidence. Omit it when you don't know —
absent means *unstated*, never `original`.

```sh
ART_UID=$(genea add ./MyArchive --title "1920 Census of Cook County" \
    --media-type image --source-tier census --tag genealogy --tag illinois \
    --notes "Smith family household")
```

### `genea attach <archive> --artifact <uid> --file <path> [--role <role>]`

Copy a local file into the artifact's folder, mint a file `uid` (`FIL-…`), and
print `<file-uid>\t<assigned-path>`. `--role` is one of `preservation-master`
(default), `access-copy`, `derivative`, `transcript`.

If the file's content is byte-identical to one already attached to the same
artifact, a non-fatal note is printed to stderr (the new file is still stored).

```sh
genea attach ./MyArchive --artifact "$ART_UID" --file ./scans/census.tif \
    --role preservation-master
```

### `genea set-meta <archive> --artifact <uid> [--title <t>] [--notes <n>] [--tag <tag> ...] [--clear-tags] [--media-type <m>] [--source-tier <s>] [--source-derivation <d>] [--clear-source-derivation] [--transcript <t>] [--language <l>] [--original-format <f>] [--external-id <scheme=value> ...] [--clear-external-ids] [--retrieval-source <s> --retrieval-date <d> [--retrieval-checksum <c>]] [--clear-retrieval]`

Update an artifact's descriptive metadata. Only the flags you pass are applied —
everything else is left as-is. `--tag` and `--external-id` (both repeatable)
**replace** their whole list; `--clear-tags` / `--clear-external-ids` empty it.
`--external-id` takes `scheme=value` (an unrecognized scheme round-trips).
`--retrieval-source` and `--retrieval-date` must be passed together;
`--clear-retrieval` removes the retrieval object.

```sh
genea set-meta ./MyArchive --artifact "$ART_UID" --title "1920 Census (revised)" \
    --tag vital-records --language en --external-id "ark=12345/abc"
```

### `genea set-role <archive> --artifact <uid> --file <FIL-uid> --role <role>` / `genea replace-file <archive> --artifact <uid> --file <FIL-uid> --with <path>`

Correct a file's role after the fact (it defaults to `preservation-master` at
attach time), or overwrite its content from a local file. `replace-file` is the
only sanctioned way to change a file's bytes — the file keeps its uid and role;
the content, size and checksum change, and the bytes move to a fresh package path
named after the replacement (the old path is removed, never overwritten in place).

```sh
genea set-role ./MyArchive --artifact "$ART_UID" --file "$FIL_UID" --role access-copy
genea replace-file ./MyArchive --artifact "$ART_UID" --file "$FIL_UID" --with ./scans/census-v2.tif
```

### `genea verify <archive>`

Run `verifyIntegrity()` **and** the reference sweep (`findDanglingReferences()`).
Prints each file-integrity issue as `<kind>\t<path>[\t<details>]`, then — if any —
a **Dangling references** section (conclusions pointing at removed records). It
**exits non-zero only on file-integrity problems**; dangling references are the
expected §2.3 no-cascade residue and are reported informationally. When everything
checks out it prints `OK: no integrity issues found (N files tracked).`

**Read the count.** It is how you tell "checked everything, all good" from "there
was nothing to check": an archive last written by a build older than sidecar
checksums carries no manifest entries for its records, and verifies clean because
absent means *unverified*, not *tampered*. If N looks far too small, run
`genea rebaseline` (or simply write to the archive — entries fill in on the next
mutation either way).

```sh
genea verify ./MyArchive || echo "archive has file-integrity problems"
```

### `genea reindex <archive>`

Rebuild `.index/index.sqlite` from the on-disk sidecars + conclusions
(`rebuildIndex()`) — the out-of-band-edit recovery path.

```sh
genea reindex ./MyArchive
```

### `genea rebaseline <archive>`

Accept the archive as it stands: rebuild the index, then re-record every checksum
the manifest is the sole authority for (`rebaseline()`). Since the manifest covers
each `record.json` and every `conclusions/**` record, editing one by hand shows up
in `verify` as a `checksum-mismatch` — the engine cannot tell your edit from bit rot
and will not guess. This is how you say it was you.

It does **not** hide damage to an attached file: a media file's checksum is authored
in its artifact's `record.json`, and this rewrites no records.

```sh
genea rebaseline ./MyArchive
```

### `genea list <archive>`

List every artifact as `<uid>\t<title>`, one per line.

```sh
genea list ./MyArchive
```

### `genea find <archive> [<query>] [--tag <t> ...] [--source-tier <s>] [--from-year <y>] [--to-year <y>] [--mentioning <name>]`

Find artifacts by free text and/or structured facets, all **AND-combined**, same
`<uid>\t<title>` format as `list`. `<query>` is a case-insensitive substring over
title/transcript/notes and the evidence fields; the facets add an exact whole-tag
match, a source-tier filter, an event-date-overlap year range (either bound
optional), and a name-as-recorded substring. At least one criterion is required.

```sh
genea find ./MyArchive "census" | cut -f1
genea find ./MyArchive --tag illinois --source-tier census --from-year 1900 --to-year 1930
```

### `genea show <archive> <artifact-uid>`

The human register for one artifact — its descriptive fields, events and places
(with the indices `event remove` / `place remove` take), persons mentioned, files
(with their `FIL-` uids), transcript, and any external identifiers / retrieval
metadata. The artifact analog of `person show`.

### `genea lookup <archive> (--at-path <p> | --external-id <scheme=value> | --sha256 <hash> | --mentions <PER-uid>)`

Resolve artifacts by an **exact** key (one mode per call): a folder/file path, an
external identifier, a file content SHA-256 (the dedup check), or a concluded
person the artifact cites (following the evidence links — the conclusions-aware
complement to `find --mentioning`). Emits the same `<uid>\t<title>` lines.

```sh
genea lookup ./MyArchive --sha256 "$(shasum -a 256 ./scans/census.tif | cut -d' ' -f1)"
genea lookup ./MyArchive --mentions "$ANNA"
```

### `genea remove <archive> <artifact-uid>` / `genea detach <archive> --artifact <uid> --file <uid>`

Move an artifact (or one of its files) to the archive's own `.trash/`. **Not a
destruction** — the bytes stay in the package and come back with
`genea trash restore`. Links citing a trashed artifact dangle until it's restored.

```sh
genea remove ./MyArchive "$ART_UID"
genea detach ./MyArchive --artifact "$ART_UID" --file "$FIL_UID"
```

## Evidence: who a document names

### `genea mention add <archive> <artifact-uid> --name <as recorded> [--role <r>] [--quality <q>] [--age <a>] [--name-language <l>] [--name-script <s>]`

Record a person named in an artifact, **exactly as the document writes it**, and
print the minted `localRef` (`p1`, `p2`, …) — the anchor `genea link` takes. The
ref is assigned, never supplied.

`--role` is an **open** vocabulary — known values are `subject` (default),
`informant`, `witness`, `parent`, `spouse`, `godparent`, `sponsor`, `declarant`,
`registrar`, `clergy`, `midwife`, and anything else round-trips verbatim, because
a register naming a role we haven't enumerated must be recordable rather than
rejected. `--quality` (`primary`, `secondary`, `undetermined` — the default) is
closed: an unrecognized value is rejected, not preserved.

`--quality` sets the **default for this mention's facts**, not a quality of the
person — under the GPS, quality belongs to an individual information item, so "how
good is this person" isn't a meaningful claim. Read it as *how close whoever
supplied the information stood to what the record states about them*. Set it to
whatever most of the mention's facts are, then state the **exceptions** with
`mention fact add --quality`: a death certificate's informant is `primary` for the
death and `secondary` for the birth and parents they report secondhand, so the
mention says `primary` and only the birth fact says `secondary`.

`--name-language` (BCP 47) and `--name-script` (ISO 15924) describe **the name**,
not the document: a Russian-language register routinely records Polish and Yiddish
names. They are orthogonal — a transliterated Russian name is language `ru`,
script `Latn` — and the script is what lets a matcher pick a phonetic algorithm
rather than keying Cyrillic with Latin phonetics.

```sh
REF=$(genea mention add ./MyArchive "$ART_UID" \
    --name "Anna Meyer" --role subject --quality primary --age 28)
```

### `genea mention list <archive> <artifact-uid>` / `genea mention remove <archive> <artifact-uid> --ref <p1>`

List an artifact's mentions as `<localRef>\t<name>\t<role>`, or remove one.
Removing a mention leaves any link pointing at it dangling; the command says so.

### `genea mention fact add <archive> <artifact-uid> --ref <p1> --type <t> [--date <d>] [--place <p>] [--quality <q>]` / `genea mention fact remove <archive> <artifact-uid> --ref <p1> --index <n>`

Record what a document says **about one of the people it names** — the mechanism
that makes a multi-person record legible. A census household or a metrical
register names several people, and `events` alone can only attach a recorded
birth year to the *document*; this attaches it to whichever person it is about.
`add` prints the minted index, which `remove` takes; `genea show` nests them under
their mention.

`--date` takes EDTF or the same shorthand `fact add` does. `--quality` sets the
GPS information quality **for that one fact** — omit it to inherit the mention's
(never `undetermined`, so an unqualified fact is not silently downgraded). This is
what lets a death certificate be primary for the death it records and secondary for
the birth it mentions, or a naturalization certificate be primary for the
naturalization it witnesses and secondary for the birth date the applicant supplied
from memory decades later.

This is **not** `genea fact add`. That command records a *conclusion*; this
records what a source states. The two stay separate commands because they write
different types in different layers — evidence never points into `conclusions/`.

```sh
genea mention fact add ./MyArchive "$ART" --ref "$REF" \
    --type Birth --date "abt 1892" --place "Łomża"
```

### `genea event add <archive> <artifact-uid> --type <t> [--date <d>] [--location <l>]` / `genea event remove <archive> <artifact-uid> --index <n>`

Record what a document says happened — a census enumeration, a recorded birth —
**as evidence**, not a concluded fact. `--date` takes EDTF or the same shorthand
`fact add` does (`abt 1920`, `June 1920`, `1940s`) and stores canonical EDTF.
`add` prints the minted index; `remove` takes the index `genea show` prints.

```sh
genea event add ./MyArchive "$ART" --type Census --date "June 1920" --location "Cook County"
```

### `genea place add <archive> <artifact-uid> --as-recorded <s> [--normalized <n>]` / `genea place remove <archive> <artifact-uid> --index <n>`

Record a place named in the document (`asRecorded`, plus an optional `normalized`
form), index-addressed like `event`.

## Conclusions: people, relationships, facts

### `genea person add <archive> [--given <g>] [--surname <s>] [--full <f>] [--name-type <t>] [--language <l>] [--script <s>]`

Conclude a new person and print the minted `PER-…` uid. At least one name part is
required.

```sh
ANNA=$(genea person add ./MyArchive --given Anna --surname Meyer)
```

### `genea person list <archive> [--match <query>]`

List concluded persons as `<uid>\t<display name>`. `--match` searches **every**
name a person carries (and fact places), not just the displayed one. A person
with no name recorded prints an empty second column.

### `genea person show <archive> <uid>`

The whole graph around one person: names, facts, relationships phrased from their
side, and the artifacts citing them. Each row carries the uid or index the
mutating commands take, so this is how a script discovers ids.

```
PER-019f…	Anna Meyer
Names:
  [0] Anna Meyer (birth)
Facts:
  [0] Birth  1892~ (about 1892)  Chicago
Relationships:
  REL-019f…  partner  PER-019f… Otto Meyer
      [0] Marriage  1912-06 (June 1912)
  REL-019f…  child  PER-019f… Ella Meyer
Sources:
  LNK-019f…  ART-019f…  1920 Census of Cook County  as recorded: "Anna Meyer"
```

### `genea person name add|set|remove <archive> <uid> …`

Manage the person's names — `add` appends (a married name, alias or nickname),
`set` edits one in place (`--index`, default the first; only the flags you pass
change), `remove` drops one by index.

`--language` (BCP 47) and `--script` (ISO 15924) tag an individual name, on both
`person add` and `person name add|set`. They belong on the name rather than the
person because a person's names come from different records: the same woman is
"Chana" in a Yiddish record, "Анна" in a Russian one, and "Anna" on a
naturalization paper.

```sh
genea person name add ./MyArchive "$ANNA" --surname Braun --name-type married
genea person name set ./MyArchive "$ANNA" --given Anna-Maria
genea person name add ./MyArchive "$ANNA" --given Анна --surname Штернфельд \
    --name-type also-known-as --language ru --script Cyrl
```

### `genea person remove <archive> <uid>`

Remove a concluded person. Relationships and links naming them are **left
dangling** (no cascade) and the command reports how many.

### `genea person duplicates <archive> [--min-confidence <n>] [--limit <n>] [--explain]`

Find pairs of concluded persons that may be one person, ranked, each unordered
pair once: `<uid>\t<uid>\t<confidence>\t<name>\t<name>`. `--explain` prints the
decomposed breakdown instead — **without** the two GPS source weights, since
neither side of a person↔person comparison is a source.

It suggests and never commits; there is deliberately no `--merge-above`.

### `genea person merge <archive> <absorbed> --into <survivor>`

Merge two records for one human being. **The one command that cascades:** every
record naming the absorbed person is repointed rather than orphaned, and the
report names everything it touched — what moved, what was dropped, what a drop
left dangling. `--into` is a flag rather than a second positional because the two
arguments are not interchangeable and there is no undo here.

### `genea person dismiss|undismiss <archive> <a> <b> [--subject <s>]`

Record — or retract — a human's *no* about a suggestion over two persons.
`--subject` is `same-person` (the default, 45j's duplicates), `parent-child` or
`couple`; declining one claim leaves the others open, and for `parent-child` the
first uid is the proposed parent.

Without this, `person duplicates` re-offers a declined pair forever. **Deletion is
the retraction:** `undismiss` removes the record and the pair returns to the queue,
so there is no third verb. Retracting something never declined prints nothing and
exits cleanly.

```sh
genea person dismiss ./MyArchive "$SIDNEY" "$ZELIG"
genea person duplicates ./MyArchive          # the pair is gone, and stays gone
genea person undismiss ./MyArchive "$SIDNEY" "$ZELIG"
```

### `genea person dismissals <archive> [--person <uid>]`

List what has been declined: `<DSM-uid>\t<subject>\t<uid>\t<uid>\t<confidence>`.
The confidence column is empty for a subject the matcher does not score. This is
the only surface that makes a dismissal visible — it otherwise works by making
something *not* appear.

### `genea relate <archive> (--parent <uid> --child <uid> | --partner <uid> --partner <uid>) [--nature <t>]`

Assert a relationship and print its `REL-…` uid. The flags name roles, so you
never have to remember which endpoint is stored first.

`--nature` records what kind of parent-child link this is —
`BiologicalParent`, `AdoptiveParent`, `StepParent`, `FosterParent`,
`GuardianParent`. **Omitting it means unspecified, not biological.**

```sh
genea relate ./MyArchive --partner "$ANNA" --partner "$OTTO"
genea relate ./MyArchive --parent "$ANNA" --child "$ELLA" --nature AdoptiveParent
```

### `genea unrelate <archive> <relationship-uid>`

Remove a relationship. The two persons are untouched.

### `genea relationship list <archive>`

List every relationship as `<uid>\t<type>\t<person1>\t<person2>`, one per line —
the flat, whole-graph view (`person show` only shows one person's relatives). Per
the §4.5 convention, for a `parent-child` relationship `person1` is the parent.

```sh
genea relationship list ./MyArchive | cut -f1
```

### `genea fact add <archive> (--person <uid> | --relationship <uid>) --type <t> [--date <d>] [--place <p>]`

Record a fact. A fact about **one** person (birth, death, residence) goes on the
person; a fact about **two** (marriage, divorce, annulment) goes on their
relationship, so it isn't duplicated onto each spouse. A known type has to match
its target; an unrecognized one is stored verbatim.

`--date` accepts EDTF or plain genealogist shorthand — `abt 1920`, `before 1950`,
`June 1920`, `1940s` — and stores canonical EDTF (`1920~`, `../1950`, `1920-06`,
`194X`). Anything it can't parse is kept as free text rather than rejected.

```sh
genea fact add ./MyArchive --person "$ANNA" --type Birth --date "abt 1892" --place Chicago
genea fact add ./MyArchive --relationship "$REL" --type Marriage --date "June 1912"
```

### `genea fact remove <archive> (--person <uid> | --relationship <uid>) --index <n>`

Remove a fact by the index `person show` prints.

### `genea link <archive> --artifact <uid> --mention <localRef> --person <uid> [--reviewed-by <name>]`

Resolve a mention to a concluded person — the evidence→conclusion bridge — and
print the minted `LNK-…` uid.

```sh
genea link ./MyArchive --artifact "$ART_UID" --mention "$REF" \
    --person "$ANNA" --reviewed-by "R. Feldberg"
```

### `genea unlink <archive> <link-uid>`

Remove the link only. The mention stays on the artifact (the document still
records that name) and the person stays concluded.

## Matching: `genea match …`

Entity resolution — which mentions name which concluded persons
([ARCHITECTURE §4.6](../docs/ARCHITECTURE.md)). **The matcher suggests and never
commits:** `suggest` and `explain` compute and print, and nothing is written until
`confirm` or `reject` records a human's verdict. There is deliberately no batch
auto-confirm above a threshold.

`--min-confidence` defaults to 50 — a calibrated default, not a policy. The right
floor depends on the archive, and finding it is what this command family is for.

### `genea match suggest <archive> (--person <PER-uid> | --artifact <ART-uid>) [--min-confidence <n>] [--limit <n>]`

Both directions of the same question. From a person: *what else in the archive is
about her?* From an artifact: *who on this record is already in the tree?* Both
print the same six columns:

```
<ART-uid>	<localRef>	<PER-uid>	<confidence>	<name as recorded>	<person>
```

Columns 1–3 are exactly the triple the other `match` verbs take, so a suggestion
pipes into a decision unchanged:

```sh
genea match suggest ./MyArchive --artifact "$ART" | cut -f1-3
```

`--limit` caps candidates **per mention** for `--artifact` (a global cap would
starve later mentions) and the whole result for `--person`. It must be at least 1:
asking for at most zero suggestions is refused rather than obeyed, because an empty
candidate list is how this command reports *a mention the archive has nobody for*,
and `--limit 0` would print that row for a mention with a perfect candidate.

The artifact direction also prints a row for **an unresolved mention nothing
matched**, with `-` in the person and confidence columns:

```
ART-…	p3	-	-	Chaja Rozenblum	(no candidate scored 50 or above)
```

That row is the point of the grouping. Without it, "this record names nobody",
"every name on it is resolved" and "here is a name the archive has never seen"
would be one empty output — and only the third has work attached. **It is not
evidence that the person is new:** the matcher's blind spot is the name it cannot
recognize at all (an americanization, an unlisted variant), so an empty list is
where it is *least* trustworthy. Check with `--min-confidence 0` before concluding
anything. When a rejection is what emptied the list, the row says so, since
lowering the floor will never bring that pair back.

The `-` placeholders are not empty columns: consecutive tabs collapse under a
shell `read`'s default `IFS`, and these absences are mid-row. The same applies to
the recorded-name column when a mention carries an empty name — the rule is
positional, so only a *trailing* column is ever left blank.

### `genea match explain <archive> --artifact <uid> --mention <ref> --person <uid>`

The decomposed breakdown for one pair — **the reasoning, which is the point.**
`suggest` answers "what should I look at?" and hides pairs that are resolved,
rejected or weak; this answers "why did *these two* score the way they did?", which
is worth asking about exactly those hidden pairs. No threshold, no skip rules.

```
ART-…  p1  "Marcus Hanner"  1912 Marriage Register
PER-…  Marcus Hanner
Confidence: 80
Dimensions:
  name        exact     100
  birthYear   within    67  2 years apart
  birthPlace  exact     100
  spouseName  within    89
  parents     (not assessed)
Weights:
  source authority     40
  information quality  100
Conflicts:
  (none)
Recorded verdict:
  (none)
```

`(not assessed)` is not a zero. The documents this reads are silent about most
things, and *not assessed* is not *assessed and failed*. **Recorded verdict** shows
any link already on disk for the pair — usually the answer to "why did this stop
being offered?" — with the confidence stored *at the time*, which a confirmed link
can be audited against.

### `genea match confirm|reject <archive> --artifact <uid> --mention <ref> --person <uid> [--reviewed-by <name>]`

Record a human's verdict, printing the minted `LNK-…` uid.

`confirm` is **not** the same as `genea link`, and the difference is what gets
stored: `link` is for a mention you resolved unaided and writes the honest minimum
a breakdown can express, while this stores the matcher's *real* dimension scores —
not rounded up to 100 because you agreed. A confirmation is a verdict on the pair,
not a re-scoring of the evidence.

`reject` writes a **tombstone**: an evidence link with `human-rejected`, and the
computed breakdown, because a rejection of a *strong* match is where the matcher is
wrong in a way worth understanding. It has to be a record — suggestions are
ephemeral, so without it the next run would offer the identical pair forever. It is
scoped to the **pair**: every other candidate stays open and the mention stays
unresolved.

A pair holds one verdict, so either verb replaces whatever was there and reports
what it displaced (and any citation the removal stranded).

```sh
genea match suggest ./MyArchive --person "$MARCUS" | head -1 | cut -f1-3 |
    while IFS=$'\t' read -r art ref per; do
        genea match explain ./MyArchive --artifact "$art" --mention "$ref" --person "$per"
    done
```

### `genea match unreject <archive> --artifact <uid> --mention <ref> --person <uid>`

Remove the rejection, returning the pair to the queue. Un-rejecting *is* deleting
the tombstone, and `genea unlink` already does that — but it takes a uid, and nobody
holds the uid of a record they only know as "the pair I said no to". This resolves
the pair to that record. It clears **every** tombstone on the pair, and refuses to
touch a confirmation (use `genea unlink`, which the error names).

## `genea trash list|restore|remove|empty <archive>`

The archive's own `.trash/`, holding deleted artifacts and detached files until
you say otherwise. `list` prints `<kind>\t<uid>\t<name>\t<deleted-at>`;
`restore <uid>` puts one back (dispatching on the `ART-`/`FIL-` prefix);
`remove <uid>` and `empty` **destroy bytes irreversibly**.

```sh
genea trash list ./MyArchive
genea trash restore ./MyArchive "$ART_UID"
```

## End-to-end example

Seeding a small family from scratch — an artifact, the people it names, and the
conclusions drawn from it:

```sh
genea create ./MyArchive --name "Smith Family Research"

# Evidence: the document, what it records, and who it names.
ART=$(genea add ./MyArchive --title "1920 Census of Cook County" \
    --media-type image --source-tier census --source-derivation original)
genea attach ./MyArchive --artifact "$ART" --file ./scans/census.tif
genea event add ./MyArchive "$ART" --type Census --date "1920" --location "Cook County"
genea place add ./MyArchive "$ART" --as-recorded "Cook Co., Ill."
REF=$(genea mention add ./MyArchive "$ART" --name "Anna Meyer" \
    --role subject --quality primary --age 28)
# What the record says about *her*, not just about the document.
genea mention fact add ./MyArchive "$ART" --ref "$REF" \
    --type Birth --date "abt 1892" --place Chicago

# Conclusions: the people, and what we determined about them.
ANNA=$(genea person add ./MyArchive --given Anna --surname Meyer)
OTTO=$(genea person add ./MyArchive --given Otto --surname Meyer)
ELLA=$(genea person add ./MyArchive --given Ella --surname Meyer)
genea fact add ./MyArchive --person "$ANNA" --type Birth --date "abt 1892" --place Chicago
REL=$(genea relate ./MyArchive --partner "$ANNA" --partner "$OTTO")
genea fact add ./MyArchive --relationship "$REL" --type Marriage --date "June 1912"
genea relate ./MyArchive --parent "$ANNA" --child "$ELLA"

# The bridge, and the result.
genea link ./MyArchive --artifact "$ART" --mention "$REF" --person "$ANNA"

# Or let the matcher propose it, read its reasoning, and rule on it yourself.
genea match suggest ./MyArchive --artifact "$ART"
genea match explain ./MyArchive --artifact "$ART" --mention "$REF" --person "$ANNA"
genea match confirm ./MyArchive --artifact "$ART" --mention "$REF" --person "$ANNA"

genea show ./MyArchive "$ART"          # the document register
genea person show ./MyArchive "$ANNA"  # the person register
genea find ./MyArchive --source-tier census --from-year 1919 --to-year 1921
genea verify ./MyArchive
```

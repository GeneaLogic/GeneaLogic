# 44d — CLI evidence-layer parity + read surface

**44d ✅ — CLI evidence-layer parity + read surface.** Shipped as planned below (all seven
parts + the `verify` sweep), pure `GeneaLogicCLI/`, no engine/format/schema change. New commands:
**`event add|remove` / `place add|remove`** (the load-bearing part — a document's dates/places are
now writable headlessly, so a script can seed a family *from documents*; EDTF shorthand on event
dates via `EDTFDate.normalizingShorthand`, index-addressed removes), **`show`** (the artifact
register, the analog of `person show`), **`set-role` / `replace-file`** (flat file verbs over
`setFileRole`/`replaceFile`), **`lookup`** (the four exact point lookups — `--at-path` /
`--external-id` / `--sha256` / `--mentions` — one command, mutually-exclusive modes), and
**`relationship list`** (the flat whole-graph view). Extended: **`set-meta`** gains `--language`,
`--original-format`, `--external-id scheme=value` (+`--clear-external-ids`) and
`--retrieval-source`/`-date`/`-checksum` (+`--clear-retrieval`; source+date required together);
**`find`** exposes the whole `ArtifactQuery` (`--tag`/`--source-tier`/`--from-year`/`--to-year`/
`--mentioning`, AND-combined with an optional free-text query); and **`verify`** now also runs
`findDanglingReferences()` and prints a **Dangling references** section — **informational only**
(a resolved design fork: file-integrity issues alone drive the non-zero exit, since dangling refs
are the expected §2.3 residue the removal commands already nudge you to clean up). **Three design
forks settled with the user:** flat `set-role`/`replace-file` (not a `file` noun); one `lookup`
command (not facets on `find`); and the informational-verify choice above. **/code-review (self,
on the working diff) found one real defect:** `find --from-year 2000 --to-year 1900` **fatal-errored
the process** — a reversed pair traps `(lower)...(upper)` (`ClosedRange requires lowerBound <=
upperBound`, SIGTRAP), a raw Swift trap rather than a usage error; now a clean `CLIUserError`, with
the one-sided `Int.min`/`Int.max` bounds confirmed safe against `overlaps(years:)` (pure
comparisons, no arithmetic). Regression-tested. New `EvidenceCommandTests` suite (15 tests) →
**45 → 60 CLI tests**, all green; engine suite untouched (193 macOS / 190 Linux). README rewritten
around the new surface with the end-to-end example verified to run verbatim; the shared
`CLIUserError.outOfRange` gained a `see:` parameter so the artifact-side edits point at `genea show`.
Out of scope (unchanged): the `restore*`/`revert` undo primitives (need an in-process token a
one-shot CLI can't hold — `trash` is the durable door), `repair()` (throwing stub), and
`fileURL(of:in:)` (in-process preview accessor). *Original plan, for reference:*

**44d (original plan) — CLI evidence-layer parity + read surface** (the follow-on 44b's own audit
turned up; scoped after shipping it, not before). 44b brought the *conclusions* surface over, so a script
can now seed people, relationships, facts and links — but the **evidence** side is still
partial, and the read surface is thinner than the engine's. What's missing, in priority order:
1. **`Artifact.events` / `locations` are unwritable** — the CLI **cannot record a date or place
   on a document**, the headless equivalent of the app's Events & Places section (slice 16).
   This is the load-bearing one: it's the gap between "seed a family" and "seed a family *from
   documents*", so it caps the fixture-seeding payoff 44b was partly built for. Shape: an
   `event add|remove` / `place add|remove` family under the artifact, index-addressed like `fact remove`,
   with the same `EDTFDate.normalizingShorthand` date handling `fact add` uses.
2. **No artifact `show`** — the analog of `person show`. `list`/`find` print only
   `<uid>\t<title>`, so a document's events, locations, mentions, files, transcript and
   descriptive fields have no headless view. Should render the same sectioned, index-carrying
   register `person show` does (the indices `event remove`/`fact remove` take).
3. **`setFileRole` + `replaceFile` unexposed** — a file's role can't be corrected (the whole
   point of slice 32) and its content can't be swapped.
4. **`set-meta` misses `language`, `originalFormat`, `externalIdentifiers`, `retrieval`** —
   descriptive fields the app edits. Cheap to add to the existing "apply what was passed" body.
5. **`find` exposes only `ArtifactQuery.text`** — the `tags`/`sourceTier`/`dateRange`/
   `mentioning` facets, i.e. the entire structured half of §5.1, have no flags. The engine
   already ANDs them with free text (the app's slice-13 tag filter rides this).
6. **Four point lookups unexposed**: `artifact(atPath:)`, `artifact(withExternalIdentifier:)`,
   `artifacts(containingFileWithSHA256:)` (the dedup check), `artifacts(mentioning:)`.
7. **No `relationship list`** — `relationships()` (the whole graph) is reachable only per-person
   through `person show`; a tree-shaped consumer wants the flat list.
**Deliberately still out of scope, and why:** the `restoreArtifact`/`restorePerson`/
`restoreRelationship`/`restoreLink`/`revert` undo primitives take a token returned by a prior
call *in the same process*, which a one-shot CLI invocation cannot hold — the `trash` commands
are the durable door onto the same store, and that's the right split. `repair()` stays
unsurfaced (a throwing stub, unsurfaced in the app too), and `fileURL(of:in:)` is an in-process
accessor for the app's preview, not a CLI concern. Expected to be app-free **and** engine-free
like 44b — pure `GeneaLogicCLI/`, over the settled API.

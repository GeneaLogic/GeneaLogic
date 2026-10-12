# 44e — `findDanglingReferences()` + dangling-reference surfacing

**44e ✅ — `findDanglingReferences()` + dangling-reference surfacing.** Shipped as planned
below, with these resolutions. **Kept a separate engine call from `verifyIntegrity()`, not a
new `IntegrityReport.Issue` case** — that report answers "is the BagIt payload exactly what
`manifest.json` says", is scoped to files, and explicitly does *not* audit `conclusions/`;
this one resolves pointers and costs no hashing. Structurally, too: every `Issue` case carries
a `path`, which the app's grouping/tint/identity all key off, and a dangling reference has
none. Two sweeps, one panel. **Seven finding kinds**, each naming the surviving *holder*
first (the record a human would edit) and the missing target second — the three
`EvidenceLink` pointers (`artifactUid`, `personUid`, `personMentionRef`), the two
`Relationship` endpoints, and the three `supportedByLinks` citations (person fact,
relationship, relationship fact). A **missing artifact suppresses the mention finding** for
the same link — otherwise one broken link double-counts. **Order is contract** (links →
relationships → persons, uid-ascending within each, field order within a record): the
underlying `SELECT`s carry no `ORDER BY`, so without a test pinning the whole array, dropping
the sorts breaks nothing any test sees — /code-review proved exactly that by deleting all
three and watching the suite stay green. 9 tests, Linux-verified (281 macOS / 278 Linux, 45
CLI unchanged). **/code-review** also caught the sweep reporting a *clean* archive when a
record kind failed to decode (an all-or-nothing `guard let … else { return [] }`) — the one
failure mode where the panel would affirmatively claim every conclusion resolves while never
having read them; now degraded **per kind**. Not surfaced in the CLI — `verify` still checks
files only, which is 44d's gap to close.

**44e (as planned) — `findDanglingReferences()` + dangling-reference surfacing** (split out of 44,
where the ROADMAP originally bundled it). It's an **engine** addition plus **integrity-panel**
surfacing — a different concern from rendering a tree, with its own test surface, so bundling
the two made one slice wearing two coats. Covers the dangles the §2.3 no-cascade removals
deliberately leave behind: a `Relationship`/`EvidenceLink` pointing at a removed `Person`, a
link whose artifact or `personMentionRef` is gone. The app already handles these gracefully at
the point of display ("Unknown person" / "Unknown artifact", slices 42b/43); this slice makes
them **findable in one pass** rather than only stumbled upon, wired into the existing
Verify Integrity sheet (slice 11) beside Corruption / Stray Files.

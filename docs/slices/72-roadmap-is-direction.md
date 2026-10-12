# 72 — ROADMAP is direction

**Problem.** ROADMAP was 7,200 lines: direction, status and every shipped slice's spec in
one file. A newcomer can't find where the project is going, and the family-data scrub
(74) would have to work through history that is about to move anyway.

**Layer.** Docs only. No code or format change; code comments that cite "ROADMAP slice
N" are re-pointed.

**Decisions** (settled 2026-10-09/10, from the planning handoff and the review of it):

- **ROADMAP holds direction only**: how work is tracked, the sequencing principle, how a
  slice is specified, what is done (one table), *Now* (Phase 3.5's remaining workstreams
  and the decisions already taken), *Next* (app development by milestone), *Later*,
  *Parked*.
- **Shipped specs move verbatim** to one file per slice in `docs/slices/`. Phases 0–2
  move as one file per phase, since their slices were short bullets. The only changes are
  mechanical: headings promoted, bullet indentation removed, relative links re-based, and
  links between slices pointed at the new files.
- **Future specs are written in `docs/slices/` before building**, and linked from their
  issue once the public repo exists.
- **Status stays in ROADMAP's *Now* until slice 76.** Labels and milestones are created
  in the public repo, because milestones don't survive an issue transfer.
- **Phase numbers 4–6 keep their meaning** so the many comments citing them still
  resolve: Phase 4 is still Vapor; GEDCOM (5) and AI enrichment (6) are folded into app
  development, and the ROADMAP says so.

**Out of scope.** Rewriting the moved specs (they read as written at the time); the
comment convention (contributor docs, later); creating issues or milestones (76).

**Verification.** Every non-blank line of the old ROADMAP from Phase 0 onward appears in
`docs/slices/`, and every relative link and anchor in `docs/` resolves (both checked by
script). `SchemaSpecTests` is unaffected (the spec isn't touched). Hand-test: read the
new ROADMAP cold, and follow a few links from it into `docs/slices/`.

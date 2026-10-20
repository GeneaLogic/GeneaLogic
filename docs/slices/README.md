# Slice specs

One file per slice: **`<n>-<kebab-title>.md`**, where `<n>` is the slice number
(`45p`, `58b`, …). A spec is written here and agreed **before** the slice is built (see
[ROADMAP § *How a slice is specified*](../ROADMAP.md#how-a-slice-is-specified)), and stays
afterwards as the record of what was decided. [`SLICE-LOG.md`](../SLICE-LOG.md) is the
short version: the decision, the invariant, the gotcha.

Everything up to slice 71 was moved here verbatim from ROADMAP in slice 72. Three things
to know when reading them:

- **They read as written at the time.** "Next", "now" and "below" refer to the old
  ROADMAP. Line numbers in code links (`Archive.swift:499`) have drifted.
- **The people, towns and addresses are fictional** (since slice 74). Where a spec
  measures "the real archive", the measurement is real; the names are stand-ins, each
  carrying the property of the real name it replaced.
- **Phases 0–2 have no per-slice files.** Their slices were short bullets, so each phase
  moved as one file. Slices 40–45p were bullets too, but long enough to split.

## Index

| Phase | Files |
| --- | --- |
| 0, 1a, 1b | [phase-0-1](phase-0-1.md) |
| 2 (slices 1–39) | [phase-2](phase-2.md) |
| 3 — conclusions and tree | [phase-3](phase-3.md) (approach), then [40](40-engine.md), [41](41-section-switcher-restructure-people-browse-create-delete.md), [41b](41b-editable-person-detail.md), [42](42-resolve-a-mention-person.md), [42b](42b-person-sources-section.md), [42c](42c-record-a-person-fact-from-linked-evidence.md), [43](43-relationships.md), [43b](43b-couple-relationship-facts.md), [43c](43c-partner-aware-couple-facts.md), [44](44-derived-tree-tab.md), [44b](44b-cli-conclusions-parity.md), [44c](44c-the-localref-re-binding-bug-the-shared-rule-consolidation-behind-it.md), [44d](44d-cli-evidence-layer-parity-read-surface.md), [44e](44e-finddanglingreferences-dangling-reference-surfacing.md), [44f](44f-parent-child-qualifiers-focus-siblings.md), [44g](44g-repairing-dangling-references.md), [44h](44h-matcher-precursor-format-revision.md) |
| 3 — the matcher | [phase-3-matcher](phase-3-matcher.md) (approach), then [45](45-the-scoring-core.md), [45b](45b-candidate-generation-suggestlinks.md), [45c](45c-the-review-lifecycle.md), [45d](45d-genea-match.md), [45e](45e-the-app-triage-inbox.md), [45f](45f-mergepersons.md), [45g](45g-the-relational-dimensions-read-personrole-from-the-wrong-vantage-point.md), [45h](45h-county-country-were-never-match-kinds.md), [45i](45i-the-cross-person-suggested-facts-lane.md), [45j](45j-the-person-person-scorer.md), [45k](45k-within-record-relationships.md), [45l](45l-suggested-relationships-from-the-record.md), [45m](45m-the-dismissal-record-the-duplicates-lane.md), [45n](45n-an-unqualified-place-agreement-claimed-a-depth-it-cannot-know.md), [45o](45o-place-specificity-from-the-archives-own-places.md), [45p](45p-the-quadratic-duplicate-pass-made-cheap.md), [46](46-the-source-tier-vocabulary-gap.md), [46b](46b-sourceauthoritytier-asserts-a-tier-nobody-chose.md) |
| 3.5 — overview | [phase-3-5](phase-3-5.md) (the goal, and the workstream narrative as it stood at the end of workstream 2) |
| 3.5 (1) — one machine | [47](47-cross-process-write-safety.md), [51](51-the-app-notices-another-writer.md), [52](52-mutations-off-the-main-actor.md), [53](53-the-app-joins-the-engine-in-swift-6.md), [54](54-the-linux-floor-moves-to-swift-6-3.md) |
| 3.5 (1) — two machines | [48–50 placeholder](48-50-cross-machine-sync.md), [49](49-the-manifest-covers-everything-authored.md), [60](60-the-index-knows-whether-it-is-current.md), [61](61-a-change-on-its-way-in-should-say-so.md), [60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md), [60c](60c-a-delivery-in-flight-must-not-speak-for-damage-it-did-not-cause.md), [48](48-the-index-is-machine-local.md), [50](50-the-manifest-survives-two-machines.md), [50b](50b-a-deletion-of-yours-is-not-a-delivery.md), [50d](50d-nothing-is-coming-and-the-way-out.md), [50c](50c-a-conflicted-copy-must-not-become-the-record.md), [50e](50e-a-revert-is-not-a-stale-manifest.md) |
| 3.5 (2) — damage | [55](55-one-bad-record-must-not-close-the-archive.md), [56](56-damage-announces-itself.md), [57](57-the-cheap-sweep.md), [57b](57b-verifying-must-not-download-the-archive.md), [58](58-a-rebuild-must-not-destroy-what-it-couldnt-read.md), [58b](58b-a-new-artifact-must-not-take-an-unreadable-records-folder.md), [58c](58c-a-deleted-record-keeps-no-preserved-copy.md), [58d](58d-a-vanished-record-can-be-restored.md), [59](59-repair-a-damaged-record-from-what-the-archive-still-knows.md) |
| 3.5 (2) — stress testing | [62–66 overview](62-66-format-stress-testing.md), [62](62-a-record-survives-any-value-the-format-allows.md), [63](63-hostile-bytes-must-not-be-a-crash.md), [64](64-the-version-is-archive-wide.md), [65](65-a-write-cut-in-half-leaves-one-of-two-states.md), [66](66-a-rebuild-agrees-with-the-incremental-path.md) |
| 3.5 (2) — exit review | [findings](workstream-2-exit-review.md), [67](67-a-scan-survives-its-own-ingest.md), [68](68-the-drift-guard-has-no-holes.md), [69](69-preserved-copies-outlive-the-index.md), [70](70-a-newer-record-is-refused-before-its-manifest.md), [71](71-three-small-ones.md), [confirmation review](workstream-2-confirmation-review.md) |
| 3.5 (3) — go public | [72](72-roadmap-is-direction.md), [73](73-a-stranger-can-build-it-from-the-readme.md), [74](74-the-family-is-fictional.md), [74b](74b-a-stranger-has-something-to-open.md), [75](75-the-app-is-called-genealogic.md), [76](76-the-project-is-public.md) |
| 3.5 (5) — Mac-likeness | [77](77-does-documentgroup-fit-the-engine.md), [78](78-split-archivemodel-by-domain.md), [79](79-split-artifactdetailview.md) |

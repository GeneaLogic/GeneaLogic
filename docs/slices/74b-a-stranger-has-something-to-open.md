# 74b — A stranger has something to open

**Problem.** Someone who builds GeneaLogic opens it to an empty welcome screen. The demo
script makes three Smith artifacts and a one-pixel photo: no people, no tree, nothing to
review, so none of what the README describes can be seen. The README has no
screenshots, and there is nothing in the tree to take them from.

**Layer.** A new sample builder in the engine package, a `genea sample` command, and a
welcome-screen button in the app. No format change: the sample is an ordinary archive
written through the public API.

**The sample.** One archive about 74's cast, built so every tab has something in it:

- **About eight documents, each with a page image**: Meir *Hanaur*'s 1906 ship manifest
  from Rypin; the 1910 marriage of Marcus Hanner and Fay Feldberg; the 1915 state census
  and the 1920 federal census (the household as *Honner*); a 1925 family portrait whose
  file carries EXIF; Marcus's 1927 naturalization; a Sternfeld record in Cyrillic from
  Korostyshev; a gravestone carrying his Hebrew name.
- **About ten people over three generations**, with parent–child and couple
  relationships and their facts, so the Tree tab draws a family.
- **Some of it left undone on purpose**: mentions not yet linked, so Review has match
  suggestions with explanations, and one pair of people who are probably the same man, so
  the duplicates lane has an entry.

**Forks** (all four settled 2026-10-10 as recommended):

- **(a) Where the sample is defined.** **One Swift builder, `SampleArchive.build(at:)`, in
  a new `GeneaLogicSample` library in GeneaLogicKit** *(recommended)*. The app calls it
  from the welcome screen; `genea sample <path>` calls it from the CLI; the script calls
  `genea sample`; a test builds it. The alternative is a pre-built `.genea` copied out of
  the app bundle, which freezes uids and timestamps and must be regenerated, by a
  second definition, whenever the format moves.
- **(b) The page images.** **Rendered once from text by a committed macOS script
  (`scripts/render-sample-pages.swift`) and committed as the library's resources**
  *(recommended)*: typed pages that look like the document they stand for, each with a
  footer saying it is a fictional sample. Under 1 MB together. The engine stays
  Foundation-only, because it only copies bytes. No real scans, even public-domain ones:
  a real record names real people.
- **(c) Where the app puts it.** **In the app's container (Application Support), opened
  if it is already there** *(recommended)*. One click, nothing written to the user's
  folders, and it lands in Recent like any archive, where *Show in Finder* finds it. A
  save panel is the alternative: more explicit, but a dialog between a stranger and a
  first look. Starting over is deleting it in Finder; a *Reset Sample* is out of scope.
- **(d) When the welcome screen offers it.** **Always**, as a quieter third button below
  *Open* and *New* *(recommended)*, not only while Recent is empty. The welcome screen
  only appears with no archive open, so it is never in the way.

**Decided without a fork** (say if you disagree):

- **The README gets three window screenshots** of the sample: a document with its page
  and mentions, the tree, and a review suggestion with its breakdown. Light mode, window
  only (no menu bar, so 75's rename doesn't date them), each under ~300 KB, in
  `docs/images/`. Claude captures them from the `-DD` build; the user approves them in the
  hand-test.
- **`make-demo-archive.sh` keeps its name and default path** and becomes
  `genea sample` plus `verify` and `list`. `stage-50c-handtest.sh` depends on the Smith
  titles, so it builds its own two artifacts instead.
- **The README's "Try it"** says `genea sample` or the welcome button, not the script.

**Out of scope.**

- A *Reset Sample* command, a Help-menu entry, and onboarding beyond the button.
- The bundle ID, `PRODUCT_NAME` and container reset (75); a sample made before 75 is lost
  with the container, which is fine for a sample.
- Localizing the sample's content.

**Verification.** `SampleArchiveTests` builds the sample and checks: `verify` is clean;
the counts of documents, files, people and relationships; at least one pending match
suggestion and one duplicate candidate; every image present with its checksum. It runs
on Linux too (resources via `Bundle.module`). A CLI test runs `genea sample`.
`scrub-check.sh` passes against the denylist (the sample is new names-bearing content).
**Hand-test:** from a welcome screen, click the sample button: the archive opens, and
Archive, People, Tree and Review each show content. Close it and click again: the same
archive reopens, with any edit you made. Read the README with its screenshots.

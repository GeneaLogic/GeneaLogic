# 74 — The family is fictional

**Problem.** Real family data runs through the repo: the names, relationships and towns of
real people in test fixtures, matcher tests, source comments, the CLI README and the
docs, plus two street addresses and the real archive's name. The public repo (76) starts
from a snapshot of this one, so whatever is in the tree then is public for good.

**Layer.** Tests, comments, docs and scripts. No engine behavior change and no format
change. The bundle ID and document type carry a family name too; they are 75.

**Forks** (all four settled 2026-10-10 as recommended):

- **(a) Split the ROADMAP entry.** It lists two jobs: the scrub, and a sample archive
  (`make-demo-archive.sh`, README screenshots, a first-run sample). **Split them**
  *(recommended)*: **74** defines the fictional cast and scrubs the tree onto it; **74b**
  builds one sample archive from the same cast, for the script, the screenshots and the
  app's welcome screen. The scrub is ~1,800 mechanical edits; the sample is a feature with
  app UI. Together they don't fit a screenful.
- **(b) What counts as family data.** **Every real person's given name and surname, the
  small towns they came from, every street address, and the archive's name**
  *(recommended)*. A surname alone would leave the relationships, towns and dates as a
  fingerprint. Big cities stay (Brooklyn, New York, Chicago); dates stay (a year
  identifies nobody once the names are gone). The maintainer's name stays where it is
  deliberate (`TRADEMARKS.md`, the git author).
- **(c) The history docs** (`SLICE-LOG.md`, `docs/slices/`, ARCHITECTURE). **Rewrite them
  with the same mapping as the tests** *(recommended)*, so a doc that cites a test still
  matches it. Leaving them out of the snapshot would lose the record of why the code is
  the way it is, which is the point of keeping them.
- **(d) A guard against the names coming back.** **A denylist kept outside the tree, and
  `scripts/scrub-check.sh <list>`** *(recommended)*. The script is public, the list is
  not: a list of real names in the repo is the leak, and a hashed one falls to a surname
  dictionary. The script checks tracked file contents and paths, whole words,
  case-insensitively, after NFC and diacritic folding. It runs at the end of this slice
  and again in 76 before the snapshot. CI can't run it (no list), so it is a pre-snapshot
  gate, not a regression test.

**The cast.** One fictional family, Polish-Jewish immigrants to Brooklyn, because the
matcher's tests need that linguistic territory: Daitch–Mokotoff, Polish `sz`,
americanized given names, Cyrillic and Hebrew script. Each real name is replaced by one
that **carries the same property**, so each test keeps asserting what it did:

| Fictional | Property it carries |
| --- | --- |
| **Hanner** · *Hanaur* · *Honner* · *Hannerr* | One surname written three ways by three clerks; all share a D–M code (an initial `H` codes like `K`). *Hannerr* is a typo |
| **Harnauk** | A variant that keys apart from Hanner on its own |
| **Haskel** | Interior vowels contribute no digits (`545800`) |
| **Adler** | A leading vowel codes as `0` |
| **Feldberg** · *Feldbers* | The second family; a one-letter typo |
| **Sternfeld** · **Штернфельд** | The third family; a Cyrillic record |
| **Marcus** · *Marcs* · *Markus* · **Meir** · **Мотек** | One man: his American name, a typo, a German spelling that keys with it, his Hebrew name, a Cyrillic diminutive. All start with `M`, so `M. Hanner` still abbreviates him. (Not `Max`: as a variable, `max` shadows Swift's `max()`) |
| **Szlama** → *Solomon* | Polish `sz` as one sibilant; americanized |
| **Zelig** → *Sidney* | One man's Yiddish name and his American one, which must **not** key together |
| **Fay** · **Faye** | One person written both ways; they key apart (`AY` before a vowel) |
| **Rypin**, **Kutno** (*Kutnie*, "in Kutno"), **Sochaczew** (Poland), **Korostyshev** (Russia) | The towns, ASCII-exact so folding behaves as before; Brooklyn, New York and Charleston stay. Neither of *Kutno* and *Kutnie* contains the other, so a search test can tell which field matched |

Every other real name gets a fictional one by the same rule: same role, same property,
nothing borrowed from the real archive. The real-to-fictional mapping lives only in the
denylist's folder, never in the tree.

**Decided without a fork** (say if you disagree):

- **Numeric pins are re-derived, not just updated.** Where a test pins a score or a code
  and the new name moves it, the new value is checked against the property the test
  states before it is pinned.
- **The real-corpus tests become cast tests.** `PlaceVocabularyTests` pins every place
  string of the real archive, including the two street addresses; it is rebuilt on the
  cast's places, same shape.
- **The real archive is "the maintainer's archive"** in docs, and the path warning in
  `.claude/skills/run-genealogic-app` moves to an untracked `CLAUDE.local.md`. Home-dir
  paths (`/Users/…`) become `~`.
- **Xcode's `Created by …` file headers are removed** (66 files). 73 settled on no
  per-file headers, and the copyright holder is *The GeneaLogic Authors*.

**Out of scope.**

- The sample archive, `make-demo-archive.sh`, screenshots and the welcome screen (74b).
- The bundle ID, document type and container reset (75).
- The private repo's issue links and closed-issue references (76).
- This repo's git history: it stays private as the full record (settled 2026-10-10).

**Verification.** `swift test` for the engine and CLI on macOS and Linux;
`xcodebuild test` for the app. `scripts/scrub-check.sh` passes against the denylist
except for the bundle ID and document type (and one doc citing the container path),
which are 75's; and it fails when a real name is planted in a test file. The link check from 73 still
passes. **Hand-test:** read the diff of one matcher test file and one SLICE-LOG entry
and check that the story still reads true; run `scrub-check.sh` yourself against the
list.

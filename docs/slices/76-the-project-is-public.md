# 76 — The project is public

**Problem.** The project lives in a private repo whose history, issues and attachments
still carry real family data. Its open issues and status can't be seen by anyone else. Its
docs and comments cite issue numbers that will mean nothing, or the wrong thing, in a
public repo.

**Layer.** No code behavior changes. This repo's docs and comments get their issue
references rewritten. GitHub gets a new repo, labels, milestones and issues. **No format
change.**

**GitHub can't transfer these issues.** It does not move an issue from a private repo to a
public one, or between owners. So the open issues are **re-filed**, which is also how
they get scrubbed. The ROADMAP's "transfer" is corrected to "re-file".

**Forks** (settled 2026-10-12):

- **(a) Screenshots.** #18's screenshot shows the real archive, so it is re-filed as text
  only; its steps reproduce it. #24's two screenshots show a throwaway test archive. Its
  issue is filed as text, and the user drags the images in.
- **(b) Commit identity.** The snapshot commit and those after it use
  `rafi@genealogic.app`, verified on the GitHub account. It is set as `user.email` in the
  new clone only. Today's address is in every commit object, and the public repo would
  have published it.
- **(c) The checkout.** This checkout moves to `~/Code/GeneaLogic-private`, and the
  public repo is cloned to `~/Code/GeneaLogic`. Paths, scripts and Claude's memory keep
  working. Untracked files (`CLAUDE.local.md`, `.claude/settings.local.json`) are copied
  across. One repo with both histories would leave the private commits one push away from
  the public remote.
- **(d) How slices land.** As a PR with a merge commit (GitHub's equivalent of
  `--no-ff`). The PR body says `Closes #N`, CI runs on it, and the user hand-tests before
  merging. CLAUDE.md's branch-and-merge rule says so.

**Decided without a fork** (say if you disagree):

- **The order.** This avoids rewriting the tree a second time.
  1. Create `GeneaLogic/GeneaLogic` **private** and empty.
  2. Labels and milestones.
  3. Re-file the 13 open issues in their old order, so they become #1–#13 (table below).
  4. Rewrite the tree's references, then merge this slice into the private repo.
  5. Commit the snapshot (`git archive` of `main`) as the new repo's only commit, and
     push it. CI must go green.
  6. The user looks the repo over and flips it to **public**, then enables private
     vulnerability reporting (SECURITY.md already points at it).
  7. Close the old issues, each with a link to its new one, and archive the private repo.
- **Labels.** Layer: `engine`, `app`, `cli`, `format`. Kind: `bug`, `decision`,
  `feature-request`, `enhancement`. Plus **`parked`**, so the parked status the ROADMAP
  keeps today is visible on the issue. The un-park trigger goes in the issue body. GitHub's
  defaults stay (`good first issue`, `help wanted`, …). The SQLite workflow creates
  `sqlite-update` itself.
- **Milestones.** `0.1` and `1.0` now, each with its criterion from the ROADMAP. The
  others come at feature planning. Assigning milestones is workstream 4's job, not this
  slice's.
- **Re-filed bodies** keep the text. Code links point at the new repo, and cross-references
  use the new numbers. A footer reads *Re-filed from the private development repo
  (was #N, opened <date>).*

| Old | New | Labels |
| --- | --- | --- |
| 16 | 1 | feature-request, app |
| 17 | 2 | feature-request, app |
| 18 | 3 | bug, app |
| 19 | 4 | bug, app |
| 20 | 5 | feature-request, app, format |
| 21 | 6 | feature-request, app |
| 22 | 7 | feature-request, app, format |
| 23 | 8 | bug, engine |
| 24 | 9 | bug, app |
| 35 | 10 | decision, engine, format, parked |
| 36 | 11 | decision, engine, format, parked |
| 40 | 12 | decision, engine, format, parked |
| 41 | 13 | bug, engine, parked |

- **References in the tree.** There are about 150, in about 35 files.
  - **Open issues** become links to the new number.
  - **Closed issues** (#1–#15, #29–#34, #37–#39) and **PRs #25–#28 and #42** become a
    short inline description, or a link to the slice that fixed them. Most docs already
    have the description next to the number, so only the number goes.
  - The exit review's findings table swaps its issue column for the fixing slice.
  - No URL into the private repo remains. Its owner's handle joins the private denylist,
    so `scrub-check.sh` keeps it out.
- **Status moves.** ROADMAP's header, *Now* and *Parked* stop being the status. Workstream
  3 is marked done, and parked items link their issues. CLAUDE.md's two "until the public
  repo exists" lines become present tense.

**Out of scope.**

- Assigning milestones and filing the ROADMAP's refactors as issues (workstream 4).
- The root `Package.swift` and the cold-build warnings (workstream 4, already in ROADMAP).
- Branch protection and required checks. A ruleset that blocks force-push and deletion on
  `main` is cheap, but it waits until there is a second writer.
- Moving the local checkout (c). It is the user's last step, after this session.

**Verification.** `swift test` for both packages, `scripts/linux-test.sh`, and the app
tests, since the changes in code are comment-only. `scrub-check.sh` reports 0 hits.
Outside this spec, which records the mapping, a grep finds no issue number above #13. CI is green
on the new repo's first push. **Hand-test** (while the repo is still private): read the
13 issues and the README on GitHub, attach #24's screenshots, then flip it to public.

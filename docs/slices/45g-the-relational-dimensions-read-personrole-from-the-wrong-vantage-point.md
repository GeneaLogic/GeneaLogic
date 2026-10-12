# 45g — the relational dimensions read `PersonRole` from the wrong vantage point

**45g ✅ — the relational dimensions read `PersonRole` from the wrong vantage point**
(engine). Shipped with **fork (b) revised against the corpus** (below); forks (a) and
(c) as specced; no format change, no archive change, `Matcher.toolIdentifier` bumped
to `/2` (full writeup in [`SLICE-LOG.md`](../SLICE-LOG.md)). **The spec gained a
`personsMentioned[].role` semantics paragraph in both copies** — no field changed, but
the vocabulary had no documented meaning at all, which is why fork (b) could be settled
on a guess about how the corpus was tagged: a role is read relative to the record's
focus, a couple-centric record carries two `spouse`s and no `subject`, and a consumer
MUST NOT infer which party an unattributed satellite belongs to.
**Fork (b) was decided on a false premise.** It reads "no subject, or several → no
relation stated", justified by a parenthetical claim that the corpus marriage register
tags the groom `subject`. It does not: **neither marriage record in the archive has a
`subject` at all** — they are `{spouse: 2, parent: 4}` and `{spouse: 2}`. Implemented
literally, the guard dropped the couple edge on the archive's strongest relational
documents, costing four **confirmed-correct** links 4–9 points each (91→82, 92→85,
89→85, 89→85) — the slice's own failure mode, on the other record genre. Caught by
`/code-review` running the CLI over a copy of the real archive; the suites were green.
**The fix generalizes the centre from "the subject" to "the record's principals":**
the mentions tagged `subject`, or — a marriage register names none — the mentions
tagged `spouse`. A record has a focal person, or a couple. Scoring a principal reads
the co-mention roles directly; scoring a satellite inverts its own role onto the
principals. Two `subject`s no longer void the record either: their satellites are
**ambiguous between them, not unstated**, and since relational evidence is
positive-only an ambiguous read that misses now costs nothing, so discarding it buys
no safety and loses real evidence. Same reasoning licenses reading a marriage
register's four `parent` mentions for *either* spouse. Measured on the real archive:
**all 14 confirmed links back to their pre-slice scores, and the death certificate's
two parent mentions 55 → 74 and 56 → 74**, which is what the slice was for.
**`MentionMatchView` needed nothing new**: the focal
`role` plus the co-mentions' roles already expressed the vantage point, so the change
is confined to `Matcher`. **The spec's one gap, settled before building:** failures
(1) and (2) fall out of the star model, but **(3) does not** — the deceased *is* the
subject, so the widow's couple edge is genuinely stated from either vantage, and the
73 → 55 drop came from `spouseName` going `nil` → `0` when a recorded married name
didn't key to a stored maiden name. Any star model keeps that edge, and a zero always
drags a weighted mean. Settled by making **relational evidence positive-only: reported,
never scored.** A `spouseName` that disagrees still appears in the breakdown — a
reviewer wants the lead — but it does not move the roll-up, because a name
disagreement between two genuinely-married people is the *common* case, not the
suspicious one. That is the standard record-linkage asymmetry (Fellegi–Sunter): a
field's disagreement weight is governed by how often truly-matching pairs disagree on
it. The two fact dimensions keep their zeros because each justifies itself with a
conflict sentence a reviewer can act on; a relational zero explained nothing and
dragged the mean silently. **One line past the specced layer:** `match explain` marks
a non-scoring relational dimension `(not scored)`, since "show the 0" misleads next to
a confidence figure if nothing says the 0 did nothing. The rule is *mirrored* in the
CLI, not imported, keeping 45d's no-`GeneaLogicMatch`-dependency bet. 426 → 437 engine
tests, 96 → 97 CLI. *Original plan follows.*
**Letter is creation order; schedule it before 45e**, the 44b→44c
precedent — the inbox draws these scores *as the reasoning a user acts on*, so a
spurious `spouseName: none 0` would read as evidence against a correct match.
**Problem:** `PersonRole` states a person's role **in the document** — on a death
certificate `spouse` means *spouse of the deceased* — but `Matcher.relational` reads
every co-mention's role as though it were relative to **the mention being scored**.
That is correct only when scoring the subject, and wrong for every other mention on
the record. Found by 45d's tuning pass against the real archive; three failures
observed on one death certificate (subject + widow + two parents):
**(1) a missing dimension** — scoring the widow's own mention finds no co-mention
tagged `spouse`, because her husband is the `subject`, so `spouseName` goes
unassessed even with the marriage recorded in conclusions;
**(2) a spurious *failing* dimension** — scoring the deceased's father compares the
*deceased's* wife against the father's wife and records `spouseName: none 0`; his
name matched **better** than the deceased's (phonetic 96 vs 86) and he scored 18
points **lower** (55 vs 73), penalized by a dimension that should never have existed;
**(3) a regression under correct data** — recording the true marriage dropped the
deceased from 73 → 55, because `spouseName` then compared the recorded married name
against the stored maiden name. Recording a *true conclusion* made the matcher less
confident about a *correct* pair, which inverts the entire corroboration design and
is the reason this outranks the other two.
**Layer:** `GeneaLogicMatch` only (`Matcher.relational`, and whatever `MentionMatchView`
must carry to make the vantage point expressible). **No format change and no archive
change** — the roles on disk are already right; they are being *interpreted* wrongly.
It does move scores, so **`Matcher.toolIdentifier` bumps** per its own rule. No
migration: stored breakdowns keep their values by design (45c).
**Design forks.** **(a) What does a co-mention's role mean relative to a non-subject
mention? → read the record as a *star around the subject*, not a graph.** All roles
are relative to one focal person, so when scoring the subject today's behavior is
correct; when scoring a non-subject mention, the only relation the document states is
to the **subject** — a `spouse` mention ↔ subject is a couple edge, a `parent` mention
↔ subject is a parent-child edge — and every other pairing (parent ↔ spouse, parent ↔
parent) is **unstated and must score `nil`, not 0.** The alternative, inferring
sibling and in-law edges between non-subject mentions, invents relationships the
record never asserted. **(b) No subject, or several? → both mean "no relation
stated".** `PersonRole` is open and `subject` is a default rather than a guarantee: a
record naming two witnesses relates them to nobody, and if several mentions are tagged
`subject` there is no focal person to be relative *to*. Guard, don't assume. (~~The
corpus is consistent with this — its marriage register tags the groom `subject` and
the bride `spouse`.~~ **False, and the reason fork (b) was revised on implementation:
neither marriage record in the corpus has a `subject` at all — they are
`{spouse: 2, parent: 4}` and `{spouse: 2}`. See the shipped preamble.**) **(c) Should
this also make the relational comparison tolerant of
a married surname? → no.** That is the name-variant question, and conflating the two
would make it impossible to tell which change moved which score.
**Out of scope:** `keysIntersect`'s coverage rule and the 0.88 near-miss threshold —
the married-surname miss is real but is a *name-matching* slice, and 45d's data shows
the data-model answer already works (recording the widow's married name took her
0 → 85 and lifted her husband 73 → 79); the variant table; re-scoring stored links.
**Verification:** a test per observed failure, built from the death-certificate shape
— the widow gains `spouseName`; the father's becomes `nil` rather than `0`; and
**adding a true marriage must never lower a correct pair's score**, which is failure
(3) pinned as a regression test. Plus the no-subject and multi-subject guards.
Engine-only, Linux-verified. **Hand-test:** re-run `genea match suggest` over the two
artifacts built out for 45d's hand-test and confirm the parent mentions score higher
than before, with nothing new appearing above the floor.

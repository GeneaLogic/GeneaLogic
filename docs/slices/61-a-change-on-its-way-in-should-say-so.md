# 61 — a change on its way in should say so ✅

**Problem.** Slice 60 can tell *a change is still arriving from another machine* from
*this file is damaged*, and says so in the Verify panel — but **only if you go and
look**. The damage banner is silent for it deliberately (57's rule: the cheap sweep
speaks only when it finds something, and an arrival is not a finding), and Verify
Integrity is a menu item nobody opens speculatively. So a synced archive part-way
through receiving a large record shows the user *nothing*, while every edit to the
arriving record is refused with an error that arrives out of nowhere. That is the one
state where the app knows something useful and keeps it to itself.

**It is also invisible for a second reason, found while hand-testing 60**: the sweep
that would notice rides `refresh()`, which runs on 51's poll only when the change token
moved or a reconcile rebuilt. A delivery sitting in flight moves neither, so even the
data behind the panel can be a poll or more stale. Both halves are this slice.

**Layer.** App only (`GeneaLogicApp`). **No engine change and no format change** — 60
already exposes everything needed (`.awaitingDelivery`, and the classification behind
it). *If that turns out false, the slice is mis-specced; say so rather than growing an
engine change into it.*

***Settled during implementation, 2026-08-23:*** *this held, with the single read-only
accessor fork (e) allowed for — `Archive.deliveryIsInFlight` became `public`. It is used
for more than (e), though: it is the indicator's **whole** signal, in preference to the
`.awaitingDelivery` paths this bullet assumed. The reason is that the witness advances
only on a settling reconcile, so it means* the change has not been taken in yet *rather
than* the files have not landed yet *— and a bar keyed to the files would withdraw its
own announcement up to a back-off before the record appeared in the list. The cost is the
same fact seen from the other side, and shows in the hand-test:* **the bar stays up for
up to 30 s after the last byte lands**, *which is 60's back-off, not this slice's.*

**Design forks** (recommendations, to settle before building) — **all settled as
recommended, 2026-08-23**, with the amendments noted under (e) and (f):

- **(a) What is it?** *Recommend a distinct, quiet indicator — **not** the damage
  banner.* Reusing `StandingDamageBanner` would put an arrival in the voice and tint
  built for "your data is in trouble", which is the exact conflation 60 spent three
  rounds removing. Recommend a single unobtrusive line in the window's existing banner
  slot, in a neutral/informational treatment, reading like *"Receiving a change from
  another machine…"* — no count, no file names, no octagon.
- **(b) Does it name files?** *Recommend no.* 56 and 57 name files because those
  findings are durable and actionable. This one is transient and the only action is
  waiting; a list of paths that disappears by itself is noise. The Verify panel keeps
  the detail for anyone who wants it.
- **(c) Is it dismissable?** *Recommend no — it clears itself.* The damage banner is
  dismissable because damage persists until someone acts; this ends on its own, and a
  dismiss control implies otherwise. **Consequence to accept:** a delivery that never
  completes (an interrupted sync, a machine that went away) leaves it up indefinitely.
  Recommend that as correct — the archive genuinely *is* waiting — but see (e).
- **(d) When does it appear?** *Recommend after a short delay (~2 s), not
  immediately.* Most deliveries land between polls, and an indicator that flickers on
  every small sync trains the user to ignore it. A delay costs nothing: the state it
  reports is already invisible today.
- **(e) The stuck case.** ✅ *Ten minutes, hedged.* **The engine's back-off stamp turned
  out to be the wrong source**, which this bullet assumed it was: it keys on
  `manifest.json`, so a multi-file delivery landing one file at a time under *one*
  manifest never moves it — precisely the case the threshold most needs to get right.
  Progress is instead the sweep's outstanding-path set changing, which is app-side and is
  what gives (f) its second purpose. The wording accuses nothing and offers Verify
  Integrity, because a large file over a slow link is structurally indistinguishable from
  a stalled one (providers stage a download elsewhere and swap it in, so an in-flight file
  is simply *absent* throughout). *Original recommendation:* *a second, later threshold* — after some minutes
  in flight on an unchanging manifest, the wording escalates to say the change has
  stopped arriving and name Verify Integrity, since at that point it is closer to a
  fault than to progress. **The engine already has the fact this needs** (60's back-off
  keys on the manifest stamp precisely to know when a delivery is not progressing), but
  it does not currently expose it — **this is the one place the slice may need a
  read-only engine accessor**, which is a fork to settle, not to discover.
- **(f) Fixing the refresh trigger.** ✅ *Done, and in two places.* The poll publishes
  the in-flight state on **every** tick (from the reconcile task, off the main actor, where
  the same fact has just been computed) rather than only when something rebuilt — that is
  what actually removes the staleness. The sweep also rides the poll while in flight, now
  for (e)'s progress signal rather than for the indicator itself. *Original recommendation:
  the poll call the sweep when the archive is in flight*, rather than only when something
  committed.

**Out of scope:**

- **Any engine change to detection.** 60 owns that; if this slice wants a new signal,
  that is evidence 60 was under-specced and belongs in a follow-up to *it*.
- **Conflict resolution.** A delivery that arrives and disagrees is 50's.
- **Progress reporting** (bytes, percentages). The engine knows which files are
  outstanding, not how far along any of them is; the file provider does, and asking it
  is Darwin-only and per-provider — the same seam the 48–50 placeholder parks.
- **Any indicator for the CLI.** `genea` opens fresh each time and its `verify`
  already prints `awaiting-delivery`.

**Verification.**

- App tests: the indicator appears for an in-flight delivery and **not** for damage;
  it clears itself when the delivery completes; the damage banner and this one are
  never both claiming the same file. The delay in (d) is a parameter the tests set to
  zero, following `reconcileBackoffBounds`' precedent.
- **Hand-test:** `scripts/deliver.sh manifest` with the app open — the indicator
  appears without anyone running anything, and `scripts/deliver.sh record` clears
  it. *(The rig was a scratch file when this was written; it is committed now, and
  carries the two rules it has broken a hand-test by getting wrong.)*
  **✅ Driven 2026-08-23 against a copy of the real archive**, both states plus the Verify panel
  behind the escalation. **It found a silent data-visibility bug, deliberately not patched
  here — specced as [60b](60b-a-first-open-must-not-certify-what-it-hasnt-seen.md):** a
  machine with no `.index/` yet has no settled witness, so 60 records whatever is on disk
  as its baseline (its documented exception) — and when the rest of the delivery lands,
  `manifest.json` never changes again, so nothing re-fires and the delivered record stays
  invisible to every query while `verifyIntegrity()` reports the archive **healthy**. That
  is detection, which 61's own out-of-scope list assigns to a follow-up to 60 rather than
  to this slice.

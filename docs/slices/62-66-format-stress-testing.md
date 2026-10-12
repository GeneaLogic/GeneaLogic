# 62–66 — format stress testing (workstream 2's ladder)

**The exit criterion this workstream sets for itself:** *no input — well-formed, hostile,
or half-written — makes the engine crash, hang, or silently lose data; it either works or
it reports.* 55–59 built the reporting path; these slices walk the input space to find what
still does not route through it. Planned 2026-09-13; **62 and 64 are specced below**, and the
format decision 64 carries was settled first, before 62 starts — the same rule as 48's.

Build order **62 → 63 → 64 → 65 → 66**: 62 first because 66 reuses its generator, 63 second
because it finishes the arc 55 opened. **62, 63, 64, 65 and 66 have shipped**; 63's sharp fork — a
corrupt manifest has no skip path, so what `open` says is a wording decision — held, and
probing found a second one: a corrupt index that passes the header check. 65's sharp fork (in-process fault injection over killing a
`genea`) held, refined to a snapshot seam rather than a throwing one, and probing found five
cuts that land in neither state. 66, the last rung, completes the ladder.

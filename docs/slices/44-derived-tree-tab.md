# 44 — derived Tree tab (hourglass)

**44 — derived Tree tab (hourglass).** The Tree tab (a `ContentUnavailableView`
placeholder since slice 41) becomes the real **derived** view (§2.3 — read-computed
from persons + relationships, never stored or edited). **Shape: hourglass** — ancestors
*and* descendants from one focus person, the Gramps/Ancestry default. **Two commits,
one slice:** the kit projection (Linux-verified) lands first, then the app render.
**Renderer decision — native SwiftUI, not SVG-in-a-web-view** (an SVG/WKWebView cut was
considered and declined). The reasoning worth keeping: **SVG doesn't lay out graphs — the
layout pass is the same ~200 lines of pure Swift either way**, so a web view buys only the
drawing, while costing every interaction re-implemented in JS + bridged over
`WKScriptMessageHandler` (node tap → `navigateToPerson`, context menu, hover, selection —
all already native), plus the loss of the F6/F11 focus + VoiceOver work,
`hoverRowBackground`, and dark mode via `.foregroundStyle`; and reaching for d3/dagre to get
*real* layout would vendor JS into a sandboxed app — a second supply-chain surface like the
SQLite amalgamation, for a graph of a few dozen people. `ImageRenderer` gives PNG **and PDF**
export off the same SwiftUI view, which is the actual "shareable tree" use case answered
without WebKit. **SVG's right home is the server:** the kit emits the projection, the app
maps it to points natively, and **Phase 4 (Vapor) maps the *same* projection to SVG**
server-side for published HTML trees — one shared derived-tree projection, two renderers.
**Commit 1 — `TreeProjection` (`GeneaLogicModel`, Foundation-only, Linux-tested).** Pure
structure, **no pixels** (font metrics are inherently UI — that's the seam): input is just
`[Relationship]` + a focus `PersonID` + depth limits; output is node ids in generation/order
slots — `hourglass(focus:relationships:ancestorDepth:descendantDepth:) -> TreeLayout` with
`Node { person, generation, order, isFocus }`, `Union { partners, relationship, children,
parentEdges }`, and `RepeatedPerson` cross-edges. (**No `Edge` type as originally sketched** —
edges turned out fully derivable from `unions` plus node positions: the couple bar spans the
partners, drop lines go to the children. Only the repeat cross-edge isn't derivable, so that
is the one thing carried explicitly.) Generation 0 = focus, ancestors negative, descendants
positive. **The layout is *not* the sketched Reingold–Tilford contour pass** — it is a
depth-first walk **in draw order** plus a per-generation cursor that only ever advances, which
buys the two guarantees that matter for far less code: no two nodes in a generation overlap
(the cursor is a hard floor), and subtrees occupy disjoint horizontal ranges (DFS places one
subtree entirely before the next), so sibling lines cannot interleave. Centering is a
*preference* layered on top that yields to the cursor. **Deliberately not claimed: that no two
edges ever cross** — `place` no-ops for someone already placed, so a partner who married in
from a distant branch keeps their original slot and stretches the couple bar; partner
arrangement keeps the common one-or-two-spouse cases adjacent, not the rest. **Three
real derivations — the reason this is kit code with tests, not inline view code:**
(1) **union inference** — the format stores parent→child and couple as *separate*
`Relationship`s and **never records which marriage a child belongs to**, so a child's union
is derived by intersecting its parents against the couple relationships (children whose
parents form no known couple hang off a single-parent union); this is precisely what a
server-side renderer would otherwise reimplement; (2) **pedigree collapse** — cousin marriage
puts one person on two ancestral paths; render the person **once** (first visit wins) and emit
the second arrival as a cross-edge, rather than duplicating nodes; (3) **cycle guard** —
hand-entered data can assert A→B→A, so a visited set is mandatory or the recursion never
returns. Tests (Linux): generation assignment, depth clamping, union inference, multiple
marriages, pedigree-collapse dedup, cycle termination, focus-with-no-relatives.
**`Union.parentEdges` — a seam added up front for adoption/step-parents.** A union groups
co-parents, but the *nature* of parenthood is a property of a single parent→child edge (one
child can have a biological mother and an adoptive father), so each `Union` also carries
`ParentEdge { parent, child, relationship }` — one per asserted `parent-child` record. The
format has **no** way to express adoption today (`RelationshipType` is `parentChild`/`couple`
only, with no qualifier field, and `FactType` has no adoptive/step/foster case), but GEDCOM X
models it as a **fact on the parent-child relationship**, which `Relationship.facts` (added
slice 43 for couple marriage/divorce) can already carry with **no format change** — so the
work is a vocab addition plus an editor, not a schema bump. Surfacing the relationship id in
the projection is what will let a renderer read those facts and style the edge (dashed for an
adoption). Added **now** rather than later specifically because reshaping `Union` after the
commit-2 renderer is built on it is the expensive order; nothing writes such facts yet.
**Commit 2 — the `TreeTab` render (app).** Focus person = the scene-stored
`selectedPersonID` (so a People-tab selection carries into the Tree), falling back to the
first person; a node context menu gets **Focus Here** + **Show in People** (the existing
`navigateToPerson` cross-tab intent). Nodes are **real SwiftUI views** — display name +
EDTF-glossed `primaryDate` via the shared `browseSubtitle`/`humanDescription`,
`hoverRowBackground`, context menu, tap-to-refocus — at a fixed size, so generation→y and
order→x is a trivial pixel pass; connectors are one **`Canvas`** behind the nodes in the same
coordinate space, drawn as orthogonal elbows (couple bar, sibling drop), not curves. Depth
steppers (generations up / down, default 3/3) in the toolbar; empty states for no-persons,
no-focus, and focus-with-no-relatives. **The technical risk to expect:** do **not** nest a
SwiftUI `ScrollView` inside the slice-30 magnifying `NSScrollView` — two scrollers fight; the
tree content should be hosted in an `NSHostingView` inside a **single** magnifying
`NSScrollView` owning *both* scrolling and zoom (a variation on the slice-30
`ZoomableImageView` pattern, not a copy). **Deliberately out of scope: per-fact evidence
drill-down** — `PersonDetailView` already has Sources (42b) and "cited by N source(s)" (42c),
so the tree's job is to *get you there* via the person jump; rebuilding fact drill-down inside
a tree node duplicates a solved surface. **No format/schema/index change** and no engine
mutation — `relationships()` + `persons()` (slice 40) already expose the whole graph; the only
kit addition is the pure additive `TreeProjection` type + its tests.
**What commit 2 actually shipped, and the two things live testing changed.** As planned:
`TreeGeometry` (the *only* slot→point conversion, keeping the projection font-metric free),
`ZoomableCanvas` (one magnifying `NSScrollView` hosting an `NSHostingView` — the predicted
risk, handled by giving the document view the drawing's *intrinsic* size and **no**
autoresizing, unlike slice 30's fit-to-window image variant, and by injecting
`.environment(model)` into the hosted content since `NSHostingView` starts a **fresh**
environment), `TreeContentView` (connectors in one `Canvas` behind real SwiftUI cards),
focus picker + depth steppers (`@SceneStorage`), and the shared `personSelection` binding so
People↔Tree carry the same person both ways. Then **two defects only the running app
revealed**, both fixed: **(1)** the couple bar was drawn centre-to-centre and the focus card's
fill was `accentColor.opacity(0.14)` — *translucent* — so the connector visibly ran **through**
the card; fixed by drawing the bar edge-to-edge in the *gap* between cards **and** giving every
card an opaque base under its tint. **(2) The one worth remembering:** a grandchild was
stranded far to the left, under an unrelated uncle instead of under its own parents — because
children are laid out *before* the parent claims its slot, so when the per-generation cursor
pushed the parent right (past an earlier sibling's subtree), the child subtree stayed behind.
This is **not** pathological data; it is an ordinary family, and the tree simply read as wrong.
Fixed **in the kit** by re-centring: `layoutDescendants` captures the node/union ranges its
child recursion fills and shifts that whole subtree right by the delta between the block centre
and the children's centre, advancing the affected generations' cursors so later siblings stay
clear. The shift is provably always rightward (`preferred` puts the block centre at or right of
the children's centre, and `claim` only moves it further right), into space the subtree already
owns — so it cannot collide. Both fixes carry regression tests verified to fail against the old
behaviour. **Live-verified** on a seeded four-generation archive with a remarriage, a childless
couple and a grandchild: full hourglass, disjoint paternal/maternal lines, focus between both
spouses, each marriage's children under the right spouse, EDTF gloss (`1852~` → "about 1852"),
card-tap refocus, depth steppers, context-menu → People jump, and the shared selection carrying
back. **Fixture friction, exactly as the 44b entry predicted:** the CLI still has no conclusions
commands, so the test archive had to be seeded through a throwaway Swift test.

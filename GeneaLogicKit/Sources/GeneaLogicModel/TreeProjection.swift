/// The derived family-tree projection (ARCHITECTURE.md §2.3 — the tree is a *view*
/// computed from persons + relationships, never stored or edited directly).
///
/// This type answers "what goes where", in **abstract slots, not pixels**: it emits
/// each person's generation and within-generation ordering, plus the derived
/// *unions* (a co-parent pair and the children they produced). Mapping slots to
/// points needs font metrics and node sizes, which are inherently UI concerns, so
/// that pass belongs to the renderer. Keeping the structure here means it is pure,
/// Foundation-only, Linux-testable without a UI, and shared: the Mac app maps it to
/// a SwiftUI canvas, and a future publishing server maps the *same* projection to
/// SVG.
///
/// ## Why a projection is needed at all
///
/// The archive format stores `parent-child` and `couple` as **separate**
/// `Relationship` records and never records *which* marriage a child belongs to.
/// A renderable tree needs that grouping, so ``TreeProjection`` derives it (see
/// ``TreeLayout/Union``) by intersecting each child's parent set against the couple
/// relationships.
///
/// ## Layout guarantees
///
/// The algorithm is deliberately simpler than a full Reingold–Tilford contour pass.
/// It combines a depth-first walk **in draw order** with a per-generation cursor
/// that only ever advances, which yields two guarantees:
///
/// - **No two nodes in the same generation overlap** — the cursor is a hard floor.
/// - **Subtrees occupy disjoint horizontal ranges**: a depth-first walk places every
///   node of one subtree before any node of the next, and the cursor never rewinds,
///   so two sibling lines cannot interleave in any generation.
///
/// Centering a person over their children (or over a couple bar) is applied as a
/// *preference* on top of those guarantees — it yields to the cursor when a wide
/// subtree would otherwise be overlapped.
///
/// **What is deliberately not claimed: that no two edges ever cross.** The disjoint
/// -range argument covers nodes reached by the walk, but ``place(_:generation:order:)``
/// no-ops for someone already placed, so a union's partners are not guaranteed
/// adjacent — a person who married into the tree from a distant branch keeps their
/// original slot and stretches the couple bar across it. Partner placement is
/// arranged to keep the common cases (one or two spouses) adjacent; a third spouse,
/// or a partner already placed elsewhere, is not. The result is tidy for ordinary
/// data and merely un-pretty — never wrong, since no node is ever lost or
/// double-placed — for pathological data.
public enum TreeProjection {

    /// Builds an **hourglass** layout: ancestors above the focus person and
    /// descendants below, the shape genealogy software conventionally defaults to.
    ///
    /// The ancestor side is the **direct line only** (each person's parents, and
    /// their parents) — it deliberately does not fan out into aunts, uncles, and
    /// cousins, which would explode the width for little value. The descendant side
    /// shows *all* descendants together with the partners they had children by.
    ///
    /// - Parameters:
    ///   - focus: The person the hourglass is centered on. A focus with no
    ///     relationships yields a single-node layout (never an empty one).
    ///   - relationships: Every relationship in the archive. Records whose type is
    ///     neither `.parentChild` nor `.couple` are ignored; the array's order is
    ///     preserved as the tie-break for sibling and partner ordering, so a
    ///     uid-ordered input (as the engine's accessors return) gives a stable,
    ///     reproducible layout.
    ///   - ancestorDepth: How many generations above the focus to include. `0`
    ///     omits the ancestor half. Negative values are treated as `0`.
    ///   - descendantDepth: How many generations of *children* below the focus to
    ///     include. `0` omits the descendant half. Negative values are treated as
    ///     `0`. Partners are not gated by this: a spouse shares their partner's
    ///     generation, so the deepest generation still shows the spouses of the
    ///     people in it.
    ///   - includeSiblings: Whether to place the focus's **own** siblings beside them
    ///     (slice 44f). They are drawn as bare nodes — no partners, no descendants —
    ///     because expanding them is what turns a direct ancestral line into a
    ///     cousin-fanning full-family chart. Requires `ancestorDepth >= 1`: a sibling
    ///     is only knowable through a shared parent, and is only drawable once that
    ///     parent has a slot to hang the line from.
    public static func hourglass(
        focus: PersonID,
        relationships: [Relationship],
        ancestorDepth: Int = 3,
        descendantDepth: Int = 3,
        includeSiblings: Bool = true
    ) -> TreeLayout {
        let graph = Graph(relationships: relationships)
        var builder = Builder(graph: graph, focus: focus)
        builder.run(
            ancestorDepth: max(0, ancestorDepth),
            descendantDepth: max(0, descendantDepth),
            includeSiblings: includeSiblings
        )
        return builder.finish()
    }
}

// MARK: - TreeLayout

/// The output of ``TreeProjection/hourglass(focus:relationships:ancestorDepth:descendantDepth:)``
/// — persons placed in generation/slot coordinates, plus the derived unions that
/// connect them.
///
/// Coordinates are in **node slots**: `order` advances by 1 per node width, and
/// `generation` by 1 per row. A renderer multiplies them by its own node size and
/// gutter. `order` is normalized so the leftmost node sits at `0`.
public struct TreeLayout: Equatable, Sendable {

    /// One person, placed.
    public struct Node: Equatable, Sendable, Identifiable {
        /// The person this node stands for.
        public let person: PersonID
        /// Rows relative to the focus: `0` is the focus, negative is toward
        /// ancestors, positive toward descendants.
        public let generation: Int
        /// Horizontal position in node slots, normalized so the layout starts at `0`.
        public let order: Double
        /// Whether this is the person the hourglass is centered on.
        public let isFocus: Bool

        public var id: PersonID { person }
    }

    /// A stable identifier for a ``Union``, derived from its partners so it is
    /// reproducible across rebuilds (a union is not itself a stored record).
    public struct UnionID: Hashable, Sendable, CustomStringConvertible {
        public let raw: String
        public init(_ raw: String) { self.raw = raw }
        public var description: String { raw }
    }

    /// One asserted parent→child link inside a ``Union``, carrying the stored
    /// `parent-child` `Relationship` it came from.
    ///
    /// A union groups co-parents, but the *nature* of parenthood is a property of a
    /// single parent→child edge — one child can have a biological mother and an
    /// adoptive father. GEDCOM X models that as a fact on the parent-child
    /// relationship (`AdoptiveParent`, `StepParent`, `FosterParent`, …), which
    /// `Relationship.facts` (added slice 43 for couple marriage/divorce) can already
    /// carry with no format change. Surfacing the relationship id here is what lets a
    /// renderer read those facts and style the edge — dashed for an adoption, say —
    /// rather than drawing every parent line identically.
    ///
    /// Nothing writes such facts yet; this is the seam that keeps adding them a
    /// purely additive change.
    public struct ParentEdge: Equatable, Sendable {
        public let parent: PersonID
        public let child: PersonID
        /// The stored `parent-child` record; its `facts` qualify the edge.
        public let relationship: RelationshipID
    }

    /// A derived co-parent grouping: the partners and the children they share.
    ///
    /// This is the piece the stored format cannot express directly — `parent-child`
    /// and `couple` are separate records, so "these two people had these children
    /// together" is inferred here by grouping each child by its full parent set.
    ///
    /// A union may have:
    /// - one partner (a child with a single recorded parent),
    /// - two partners with no ``relationship`` (co-parents whose couple relationship
    ///   was never asserted),
    /// - two partners and no ``children`` (a childless couple — still rendered, so a
    ///   spouse appears),
    /// - or, for unusual data, more than two partners (e.g. birth *and* adoptive
    ///   parents recorded on one child); such a set is kept whole rather than split,
    ///   since guessing which pair is "the" couple would be fiction.
    public struct Union: Equatable, Sendable, Identifiable {
        public let id: UnionID
        /// The co-parents, in placement order (left to right).
        public let partners: [PersonID]
        /// The asserted `couple` relationship joining the partners, when one exists.
        /// `nil` for a single parent, or for co-parents with no asserted couple.
        public let relationship: RelationshipID?
        /// The children attributed to this union, in placement order. May be empty
        /// for a childless couple.
        public let children: [PersonID]
        /// The individual parent→child links behind ``children``, one per asserted
        /// `parent-child` record. A child with two parents in this union contributes
        /// two edges; a renderer that only draws one line per child can ignore this
        /// and use ``children``.
        public let parentEdges: [ParentEdge]
        /// The generation the *partners* sit in; children are at `generation + 1`.
        public let generation: Int
        /// The midpoint of the partners' slots — where a renderer hangs the drop
        /// line to the children.
        public let order: Double
    }

    /// A second arrival at a person already placed elsewhere in the layout —
    /// pedigree collapse (cousin marriage puts one ancestor on two lines), or a
    /// cycle in hand-entered data.
    ///
    /// The person is placed **once** (first visit wins); each later arrival is
    /// reported here so a renderer can draw a cross-edge to the existing node
    /// rather than duplicating it.
    public struct RepeatedPerson: Equatable, Sendable {
        /// The already-placed person.
        public let person: PersonID
        /// The node the repeat edge arrives from.
        public let via: PersonID
    }

    /// The person the layout is centered on.
    public let focus: PersonID
    /// Every placed person. Contains at least the focus.
    public let nodes: [Node]
    /// The derived unions connecting the placed persons.
    public let unions: [Union]
    /// Repeat arrivals (pedigree collapse / cycles), for cross-edge rendering.
    public let repeats: [RepeatedPerson]

    /// Position lookup, built once at construction.
    ///
    /// A renderer resolves a position per union partner and per parent edge, so a
    /// linear scan here would make drawing quadratic in the number of people. Derived
    /// entirely from ``nodes``, so it cannot disagree with them.
    private let index: [PersonID: Node]

    init(focus: PersonID, nodes: [Node], unions: [Union], repeats: [RepeatedPerson]) {
        self.focus = focus
        self.nodes = nodes
        self.unions = unions
        self.repeats = repeats
        self.index = Dictionary(
            nodes.map { ($0.person, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Looks up a placed person in constant time.
    public func node(for person: PersonID) -> Node? {
        index[person]
    }

    /// The inclusive range of generations present, or `nil` if the layout is empty
    /// (which ``TreeProjection`` never produces — it always places the focus).
    public var generationRange: ClosedRange<Int>? {
        guard let low = nodes.map(\.generation).min(),
            let high = nodes.map(\.generation).max()
        else { return nil }
        return low...high
    }
}

// MARK: - Graph

/// The adjacency view of the relationship records, built once per projection.
///
/// Ordering is taken from the input array (uid-ordered from the engine) rather than
/// re-sorted, so sibling and partner order is stable across rebuilds.
private struct Graph {
    /// Parents of each child (`person1` is the parent, `person2` the child — the
    /// §4.5 convention).
    private(set) var parents: [PersonID: [PersonID]] = [:]
    /// Children of each parent.
    private(set) var children: [PersonID: [PersonID]] = [:]
    /// Asserted couple relationships, keyed by each partner.
    private(set) var couples: [PersonID: [(partner: PersonID, relationship: RelationshipID)]] = [:]
    /// The `parent-child` record behind each parent→child link, so a renderer can
    /// reach its facts (adoption, step-parenthood, …). First record wins when the
    /// same pair is asserted twice.
    private var parentChildLinks: [ParentChildPair: RelationshipID] = [:]

    struct ParentChildPair: Hashable {
        let parent: PersonID
        let child: PersonID
    }

    init(relationships: [Relationship]) {
        for relationship in relationships {
            switch relationship.type {
            case .parentChild:
                // The §4.5 endpoint convention is decoded by `Relationship.parent` /
                // `.child`, never by reaching for `person1Uid` here.
                guard let parent = relationship.parent, let child = relationship.child,
                    // Guard against a self-parent assertion, which would otherwise
                    // make a person its own ancestor.
                    parent != child
                else { continue }
                Graph.appendUnique(child, to: &children, key: parent)
                Graph.appendUnique(parent, to: &parents, key: child)
                let pair = ParentChildPair(parent: parent, child: child)
                if parentChildLinks[pair] == nil { parentChildLinks[pair] = relationship.uid }
            case .couple:
                let a = relationship.person1Uid
                let b = relationship.person2Uid
                guard a != b else { continue }
                Graph.appendCouple(partner: b, relationship: relationship.uid, to: &couples, key: a)
                Graph.appendCouple(partner: a, relationship: relationship.uid, to: &couples, key: b)
            case .unknown:
                // An unrecognized relationship type has no defined tree semantics;
                // it round-trips in the record but contributes no edges here.
                continue
            }
        }
    }

    /// The couple relationship joining exactly this pair, if one is asserted.
    func coupleRelationship(between a: PersonID, and b: PersonID) -> RelationshipID? {
        couples[a]?.first { $0.partner == b }?.relationship
    }

    /// The `parent-child` record asserting this link, if any.
    func parentChildRelationship(parent: PersonID, child: PersonID) -> RelationshipID? {
        parentChildLinks[ParentChildPair(parent: parent, child: child)]
    }

    /// Every asserted parent→child link from `parents` down to `children`, in the
    /// order the parents and children were placed.
    func parentEdges(parents: [PersonID], children: [PersonID]) -> [TreeLayout.ParentEdge] {
        children.flatMap { child in
            parents.compactMap { parent in
                parentChildRelationship(parent: parent, child: child).map {
                    TreeLayout.ParentEdge(parent: parent, child: child, relationship: $0)
                }
            }
        }
    }

    private static func appendUnique(
        _ value: PersonID,
        to table: inout [PersonID: [PersonID]],
        key: PersonID
    ) {
        var existing = table[key] ?? []
        guard !existing.contains(value) else { return }
        existing.append(value)
        table[key] = existing
    }

    private static func appendCouple(
        partner: PersonID,
        relationship: RelationshipID,
        to table: inout [PersonID: [(partner: PersonID, relationship: RelationshipID)]],
        key: PersonID
    ) {
        var existing = table[key] ?? []
        guard !existing.contains(where: { $0.partner == partner }) else { return }
        existing.append((partner: partner, relationship: relationship))
        table[key] = existing
    }
}

// MARK: - Builder

/// The mutable state of one layout run.
///
/// The two halves of the hourglass are laid out separately — descendants first (so
/// the focus is centered over its own family), then ancestors above it — sharing one
/// `placed` set (so pedigree collapse across the two halves is caught) and one
/// per-generation cursor table (so nothing overlaps).
private struct Builder {
    let graph: Graph
    let focus: PersonID

    private var placed: [PersonID: TreeLayout.Node] = [:]
    /// Placement order, kept so the output is deterministic (dictionaries are not).
    private var order: [PersonID] = []
    private var unions: [TreeLayout.Union] = []
    private var repeats: [TreeLayout.RepeatedPerson] = []
    /// The next free slot in each generation; only ever advances.
    private var nextFree: [Int: Double] = [:]

    init(graph: Graph, focus: PersonID) {
        self.graph = graph
        self.focus = focus
    }

    mutating func run(ancestorDepth: Int, descendantDepth: Int, includeSiblings: Bool) {
        // The focus is the first person placed, so it always gets a real slot.
        let focusOrder =
            layoutDescendants(of: focus, generation: 0, remaining: descendantDepth) ?? 0
        layoutAncestors(of: focus, childOrder: focusOrder, generation: 0, remaining: ancestorDepth)
        if includeSiblings, ancestorDepth > 0 {
            layoutSiblings()
        }
    }

    // MARK: Siblings

    /// Places the focus's siblings beside them, hanging from the parents already
    /// placed by the ancestor pass.
    ///
    /// Runs **last**, so siblings take slots to the right of the focus and its
    /// partners rather than displacing them. Deliberately narrow:
    ///
    /// - Only the *focus's* siblings. Doing this at every ancestor would fan the
    ///   direct line out into aunts, uncles, and cousins — a different chart.
    /// - Siblings are bare nodes: no partners, no descendants (see above).
    /// - **Half-siblings are included**, grouped by whichever placed parents they
    ///   actually share, so a half-sibling hangs from that one parent and the drawing
    ///   does not imply a shared other parent it has no evidence for.
    private mutating func layoutSiblings() {
        let parents = (graph.parents[focus] ?? []).filter { placed[$0] != nil }
        guard !parents.isEmpty else { return }

        // Group the siblings by the set of *placed* parents each one shares with the
        // focus — that set is what the sibling's line will hang from.
        var groups: [(id: TreeLayout.UnionID, partners: [PersonID], children: [PersonID])] = []
        var index: [TreeLayout.UnionID: Int] = [:]
        for parent in parents {
            for sibling in graph.children[parent] ?? []
            where sibling != focus && placed[sibling] == nil {
                let shared = parents.filter { (graph.parents[sibling] ?? []).contains($0) }
                guard !shared.isEmpty else { continue }
                let id = ChildGroup.identifier(for: shared)
                if let existing = index[id] {
                    if !groups[existing].children.contains(sibling) {
                        groups[existing].children.append(sibling)
                    }
                } else {
                    index[id] = groups.count
                    groups.append((id: id, partners: shared, children: [sibling]))
                }
            }
        }
        guard !groups.isEmpty else { return }

        for group in groups {
            for sibling in group.children {
                let slot = claim(generation: 0, preferred: nextFree[0] ?? 0, width: 1)
                place(sibling, generation: 0, order: slot)
            }
            // Fold into the parents' existing union when there is one (a full sibling
            // shares the focus's parent union); a half-sibling's parent subset has no
            // union yet, so it gets its own.
            let edges = graph.parentEdges(parents: group.partners, children: group.children)
            if let existing = unions.firstIndex(where: { $0.id == group.id && $0.generation == -1 })
            {
                let union = unions[existing]
                unions[existing] = TreeLayout.Union(
                    id: union.id,
                    partners: union.partners,
                    relationship: union.relationship,
                    children: union.children + group.children,
                    parentEdges: union.parentEdges + edges,
                    generation: union.generation,
                    order: union.order
                )
            } else {
                let slots = group.partners.compactMap { placed[$0]?.order }
                guard let low = slots.min(), let high = slots.max() else { continue }
                unions.append(
                    TreeLayout.Union(
                        id: group.id,
                        partners: group.partners,
                        relationship: coupleRelationship(among: group.partners),
                        children: group.children,
                        parentEdges: edges,
                        generation: -1,
                        order: (low + high) / 2
                    )
                )
            }
        }
    }

    /// Normalizes slots to start at zero and emits the immutable layout.
    func finish() -> TreeLayout {
        let nodes = order.compactMap { placed[$0] }
        let shift = nodes.map(\.order).min() ?? 0
        guard shift != 0 else {
            return TreeLayout(focus: focus, nodes: nodes, unions: unions, repeats: repeats)
        }
        return TreeLayout(
            focus: focus,
            nodes: nodes.map {
                TreeLayout.Node(
                    person: $0.person,
                    generation: $0.generation,
                    order: $0.order - shift,
                    isFocus: $0.isFocus
                )
            },
            unions: unions.map {
                TreeLayout.Union(
                    id: $0.id,
                    partners: $0.partners,
                    relationship: $0.relationship,
                    children: $0.children,
                    parentEdges: $0.parentEdges,
                    generation: $0.generation,
                    order: $0.order - shift
                )
            },
            repeats: repeats
        )
    }

    // MARK: Descendants

    /// Places `person` and everything below them, returning the slot `person` landed
    /// in — or `nil` if they were already placed, in which case no new slot was
    /// allocated and the caller has nothing to center over. Children are laid out
    /// first so the parent block can be centered over them.
    ///
    /// **Cycle termination is a two-part mechanism**, and removing either half
    /// reintroduces infinite recursion: the placeholder written below marks this
    /// person as *in progress* before recursing, and the caller checks `placed`
    /// before descending. The placeholder's slot is deliberately meaningless — the
    /// real one is only known once the children are down — which is why re-entry
    /// returns `nil` here rather than that provisional value.
    @discardableResult
    private mutating func layoutDescendants(
        of person: PersonID,
        generation: Int,
        remaining: Int
    ) -> Double? {
        guard placed[person] == nil else { return nil }
        placed[person] = TreeLayout.Node(
            person: person,
            generation: generation,
            order: 0,
            isFocus: person == focus
        )
        order.append(person)

        // Partners sit in the person's *own* generation, so they are gathered even at
        // the depth boundary — `remaining` gates descending into children, nothing
        // else. (Asking for one generation of descendants should show your children
        // *and* their spouses, not force you to pull in grandchildren to see them.)
        let groups = childGroups(of: person)
        var partners: [PersonID] = []
        var childOrders: [Double] = []
        var placedGroups: [(group: ChildGroup, children: [PersonID])] = []
        // Everything the child recursion places lands at the end of these two arrays,
        // which is what lets the whole subtree be shifted as a unit below. Partners are
        // placed *after* the loop, so they fall outside the captured range.
        let subtreeNodeStart = order.count
        let subtreeUnionStart = unions.count

        for group in groups {
            var groupChildren: [PersonID] = []
            if remaining > 0 {
                for child in group.children {
                    if let existing = placed[child] {
                        // Already placed — as a sibling's partner, say. If it landed in
                        // the generation directly below, it is still genuinely this
                        // person's child, so keep the edge: unlike a repeated *partner*,
                        // a child's slot never moves the couple bar, which is derived
                        // from `partners` alone. Any other generation is a
                        // cross-generation arrival for the renderer to draw specially.
                        if existing.generation == generation + 1 {
                            groupChildren.append(child)
                        } else {
                            repeats.append(TreeLayout.RepeatedPerson(person: child, via: person))
                        }
                        continue
                    }
                    if let slot = layoutDescendants(
                        of: child, generation: generation + 1, remaining: remaining - 1)
                    {
                        childOrders.append(slot)
                    }
                    groupChildren.append(child)
                }
            }
            for partner in group.partners where partner != person && !partners.contains(partner) {
                partners.append(partner)
            }
            placedGroups.append((group: group, children: groupChildren))
        }

        // The head block is the person plus the partners drawn beside them. With two
        // or more partners the first is placed to the *left*, so both of the two most
        // common unions keep their partners adjacent to the person; stacking every
        // partner to the right would put a later union's midpoint on top of an earlier
        // spouse, and its children would appear to descend from the wrong one. A third
        // or further partner is still non-adjacent — only repeating the person's node
        // (which this projection deliberately does not do) can fix that.
        let leftPartners = partners.count >= 2 ? Array(partners.prefix(1)) : []
        let rightPartners = partners.count >= 2 ? Array(partners.dropFirst()) : partners
        let blockWidth = Double(1 + partners.count)
        let preferred: Double
        if let low = childOrders.min(), let high = childOrders.max() {
            preferred = (low + high) / 2 - (blockWidth - 1) / 2
        } else {
            preferred = nextFree[generation] ?? 0
        }
        let blockStart = claim(generation: generation, preferred: preferred, width: blockWidth)
        let personOrder = blockStart + Double(leftPartners.count)

        // Re-centre the children under the block. `claim` may have pushed the block to
        // the right of where the children were provisionally laid out — an earlier
        // sibling's subtree having already advanced this generation's cursor — which
        // would otherwise strand a subtree far to the left of the parent it hangs from
        // (visibly wrong for ordinary families, not just pathological data). The shift
        // is always rightward, into space this subtree already owns, so it cannot
        // collide with anything: `preferred` puts the block centre at or right of the
        // children's centre, and `claim` only ever moves it further right.
        if let low = childOrders.min(), let high = childOrders.max() {
            let delta = (blockStart + (blockWidth - 1) / 2) - (low + high) / 2
            if delta > 0 {
                shiftSubtree(
                    nodes: subtreeNodeStart..<order.count,
                    unions: subtreeUnionStart..<unions.count,
                    by: delta
                )
            }
        }

        placed[person] = TreeLayout.Node(
            person: person,
            generation: generation,
            order: personOrder,
            isFocus: person == focus
        )
        for (offset, partner) in leftPartners.enumerated() {
            place(partner, generation: generation, order: blockStart + Double(offset))
        }
        for (offset, partner) in rightPartners.enumerated() {
            place(partner, generation: generation, order: personOrder + Double(offset + 1))
        }

        for entry in placedGroups {
            let members = entry.group.partners
            let slots = members.compactMap { placed[$0]?.order }
            let midpoint =
                slots.isEmpty ? personOrder : (slots.min()! + slots.max()!) / 2
            unions.append(
                TreeLayout.Union(
                    id: entry.group.id,
                    partners: members,
                    relationship: entry.group.relationship,
                    children: entry.children,
                    parentEdges: graph.parentEdges(parents: members, children: entry.children),
                    generation: generation,
                    order: midpoint
                )
            )
        }

        return personOrder
    }

    /// A person's children, grouped by the full set of parents they share — the
    /// derivation the stored format cannot express (see ``TreeLayout/Union``).
    /// Childless couples are included so a spouse is still drawn.
    private func childGroups(of person: PersonID) -> [ChildGroup] {
        var groups: [ChildGroup] = []
        var index: [TreeLayout.UnionID: Int] = [:]

        for child in graph.children[person] ?? [] {
            let members = parentSet(of: child, including: person)
            let id = ChildGroup.identifier(for: members)
            if let existing = index[id] {
                groups[existing].children.append(child)
            } else {
                index[id] = groups.count
                groups.append(
                    ChildGroup(
                        id: id,
                        partners: members,
                        relationship: coupleRelationship(among: members),
                        children: [child]
                    )
                )
            }
        }

        // A couple with no recorded children still earns a union, so the partner is
        // placed and the couple bar can be drawn.
        for couple in graph.couples[person] ?? [] {
            let members = [person, couple.partner]
            let id = ChildGroup.identifier(for: members)
            guard index[id] == nil else { continue }
            index[id] = groups.count
            groups.append(
                ChildGroup(
                    id: id,
                    partners: members,
                    relationship: couple.relationship,
                    children: []
                )
            )
        }

        return groups
    }

    /// The child's parents with `person` placed first, so the union's partner order
    /// is stable regardless of which parent the walk arrived from.
    private func parentSet(of child: PersonID, including person: PersonID) -> [PersonID] {
        var members = [person]
        for parent in graph.parents[child] ?? [] where parent != person {
            members.append(parent)
        }
        return members
    }

    private func coupleRelationship(among members: [PersonID]) -> RelationshipID? {
        guard members.count == 2 else { return nil }
        return graph.coupleRelationship(between: members[0], and: members[1])
    }

    // MARK: Ancestors

    /// Places the direct ancestral line above `person`, centering each parent block
    /// over the child it belongs to.
    private mutating func layoutAncestors(
        of person: PersonID,
        childOrder: Double,
        generation: Int,
        remaining: Int
    ) {
        guard remaining > 0 else { return }
        let parentGeneration = generation - 1

        var fresh: [PersonID] = []
        for parent in graph.parents[person] ?? [] {
            if placed[parent] != nil {
                repeats.append(TreeLayout.RepeatedPerson(person: parent, via: person))
                continue
            }
            fresh.append(parent)
        }
        guard !fresh.isEmpty else { return }

        let blockWidth = Double(fresh.count)
        let preferred = childOrder - (blockWidth - 1) / 2
        let start = claim(generation: parentGeneration, preferred: preferred, width: blockWidth)

        // Reserve every parent's slot before recursing, so the couple bar is centered
        // on the pair rather than on whichever parent was walked first.
        for (offset, parent) in fresh.enumerated() {
            place(parent, generation: parentGeneration, order: start + Double(offset))
        }

        // Every freshly placed parent belongs to a union, or it would be drawn with
        // no edge down to its child. Note `fresh` — not the full parent set: a parent
        // already placed elsewhere (pedigree collapse) keeps its original slot, and
        // reaches this child through `repeats` as a cross-edge instead, so folding it
        // in here would drag the couple bar's midpoint across the layout.
        let slots = fresh.compactMap { placed[$0]?.order }
        if let low = slots.min(), let high = slots.max() {
            unions.append(
                TreeLayout.Union(
                    id: ChildGroup.identifier(for: fresh),
                    partners: fresh,
                    relationship: coupleRelationship(among: fresh),
                    children: [person],
                    parentEdges: graph.parentEdges(parents: fresh, children: [person]),
                    generation: parentGeneration,
                    order: (low + high) / 2
                )
            )
        }

        // Depth-first, left to right: a parent's whole ancestry is placed before the
        // next parent's, which is what keeps the two lines from crossing.
        for parent in fresh {
            layoutAncestors(
                of: parent,
                childOrder: placed[parent]?.order ?? start,
                generation: parentGeneration,
                remaining: remaining - 1
            )
        }
    }

    // MARK: Placement primitives

    /// Takes `width` slots in `generation`, at `preferred` if that is free and to the
    /// right of everything already there otherwise. Returns the leftmost slot taken.
    private mutating func claim(generation: Int, preferred: Double, width: Double) -> Double {
        let start = max(preferred, nextFree[generation] ?? preferred)
        nextFree[generation] = start + width
        return start
    }

    /// Moves an already-placed subtree right by `delta`, keeping its unions with it
    /// and advancing each affected generation's cursor so later siblings still land
    /// clear of it.
    private mutating func shiftSubtree(
        nodes nodeRange: Range<Int>,
        unions unionRange: Range<Int>,
        by delta: Double
    ) {
        for index in nodeRange {
            guard let node = placed[order[index]] else { continue }
            let moved = TreeLayout.Node(
                person: node.person,
                generation: node.generation,
                order: node.order + delta,
                isFocus: node.isFocus
            )
            placed[node.person] = moved
            nextFree[node.generation] = max(nextFree[node.generation] ?? 0, moved.order + 1)
        }
        for index in unionRange {
            let union = unions[index]
            unions[index] = TreeLayout.Union(
                id: union.id,
                partners: union.partners,
                relationship: union.relationship,
                children: union.children,
                parentEdges: union.parentEdges,
                generation: union.generation,
                order: union.order + delta
            )
        }
    }

    private mutating func place(_ person: PersonID, generation: Int, order slot: Double) {
        guard placed[person] == nil else { return }
        placed[person] = TreeLayout.Node(
            person: person,
            generation: generation,
            order: slot,
            isFocus: person == focus
        )
        order.append(person)
    }
}

/// A co-parent grouping under construction, before its children have slots.
private struct ChildGroup {
    let id: TreeLayout.UnionID
    let partners: [PersonID]
    let relationship: RelationshipID?
    var children: [PersonID]

    /// Order-independent, so the same co-parents always key the same union no matter
    /// which of them the walk reached first.
    static func identifier(for partners: [PersonID]) -> TreeLayout.UnionID {
        TreeLayout.UnionID(partners.map(\.raw).sorted().joined(separator: "+"))
    }
}

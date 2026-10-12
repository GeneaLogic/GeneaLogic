import GeneaLogicModel
import Testing

/// Layout coverage for `TreeProjection.hourglass` — generation assignment, the
/// derived unions the stored format cannot express, depth clamping, and the two
/// data hazards the walk has to survive (pedigree collapse and cycles).
struct TreeProjectionTests {

    // MARK: - Fixture helpers

    /// A readable stand-in for a person uid. The projection only ever compares and
    /// sorts these, so a short name keeps the expectations legible.
    private func person(_ name: String) -> PersonID { PersonID("PER-\(name)") }

    private func parentChild(_ parent: String, _ child: String, uid: String = "REL-pc")
        -> Relationship
    {
        relationship(uid: uid, type: .parentChild, parent, child)
    }

    private func couple(_ a: String, _ b: String, uid: String = "REL-cp") -> Relationship {
        relationship(uid: uid, type: .couple, a, b)
    }

    private func relationship(
        uid: String,
        type: RelationshipType,
        _ first: String,
        _ second: String
    ) -> Relationship {
        Relationship(
            uid: RelationshipID("\(uid)-\(first)-\(second)"),
            type: type,
            person1Uid: person(first),
            person2Uid: person(second),
            reviewStatus: .asserted,
            provenance: Provenance(
                createdBy: .human,
                createdAt: "2026-07-19T00:00:00Z",
                reviewStatus: .asserted
            )
        )
    }

    /// The generation a person landed in, or `nil` if they were not placed.
    private func generation(of name: String, in layout: TreeLayout) -> Int? {
        layout.node(for: person(name))?.generation
    }

    private func placed(_ layout: TreeLayout) -> Set<PersonID> {
        Set(layout.nodes.map(\.person))
    }

    // MARK: - Generation assignment

    @Test func focusAloneIsPlacedAtGenerationZero() {
        let layout = TreeProjection.hourglass(focus: person("me"), relationships: [])

        #expect(layout.nodes.count == 1)
        #expect(layout.nodes.first?.person == person("me"))
        #expect(layout.nodes.first?.generation == 0)
        #expect(layout.nodes.first?.isFocus == true)
        #expect(layout.unions.isEmpty)
    }

    @Test func ancestorsAreNegativeAndDescendantsPositive() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("grandpa", "dad"),
                parentChild("dad", "me"),
                parentChild("me", "kid"),
                parentChild("kid", "grandkid"),
            ]
        )

        #expect(generation(of: "grandpa", in: layout) == -2)
        #expect(generation(of: "dad", in: layout) == -1)
        #expect(generation(of: "me", in: layout) == 0)
        #expect(generation(of: "kid", in: layout) == 1)
        #expect(generation(of: "grandkid", in: layout) == 2)
        #expect(layout.generationRange == -2...2)
    }

    @Test func onlyTheFocusIsMarkedAsFocus() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me"), parentChild("me", "kid")]
        )

        #expect(layout.nodes.filter(\.isFocus).map(\.person) == [person("me")])
    }

    // MARK: - Depth clamping

    @Test func depthLimitsCutBothHalves() {
        let relationships = [
            parentChild("greatgrandpa", "grandpa"),
            parentChild("grandpa", "dad"),
            parentChild("dad", "me"),
            parentChild("me", "kid"),
            parentChild("kid", "grandkid"),
        ]

        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: relationships,
            ancestorDepth: 1,
            descendantDepth: 1
        )

        #expect(placed(layout) == [person("dad"), person("me"), person("kid")])
    }

    @Test func zeroDepthYieldsTheFocusAlone() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me"), parentChild("me", "kid")],
            ancestorDepth: 0,
            descendantDepth: 0
        )

        #expect(placed(layout) == [person("me")])
    }

    @Test func negativeDepthIsTreatedAsZero() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me")],
            ancestorDepth: -5,
            descendantDepth: -5
        )

        #expect(placed(layout) == [person("me")])
    }

    // MARK: - Union derivation

    @Test func childrenOfOneCoupleFormASingleUnion() {
        let layout = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "kidA"),
                parentChild("mum", "kidA"),
                parentChild("dad", "kidB"),
                parentChild("mum", "kidB"),
            ]
        )

        let unions = layout.unions.filter { $0.children.isEmpty == false }
        #expect(unions.count == 1)
        #expect(unions.first.map { Set($0.partners) } == [person("dad"), person("mum")])
        #expect(unions.first.map { Set($0.children) } == [person("kidA"), person("kidB")])
        // The asserted couple record is carried through, so a renderer can drill into it.
        #expect(unions.first?.relationship == RelationshipID("REL-cp-dad-mum"))
    }

    @Test func childrenOfDifferentPartnersSplitIntoSeparateUnions() {
        let layout = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [
                couple("dad", "first"),
                parentChild("dad", "kidA"),
                parentChild("first", "kidA"),
                couple("dad", "second"),
                parentChild("dad", "kidB"),
                parentChild("second", "kidB"),
            ]
        )

        let withChildren = layout.unions.filter { !$0.children.isEmpty }
        #expect(withChildren.count == 2)
        #expect(withChildren.map(\.children) == [[person("kidA")], [person("kidB")]])
        // Both spouses are placed beside the focus, in the focus's generation.
        #expect(generation(of: "first", in: layout) == 0)
        #expect(generation(of: "second", in: layout) == 0)
    }

    @Test func coParentsWithoutAnAssertedCoupleStillFormAUnion() {
        let layout = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [
                parentChild("dad", "kid"),
                parentChild("mum", "kid"),
            ]
        )

        let union = layout.unions.first { !$0.children.isEmpty }
        #expect(union.map { Set($0.partners) } == [person("dad"), person("mum")])
        // No `couple` record was asserted, so there is nothing to cite.
        #expect(union?.relationship == nil)
    }

    @Test func childlessCoupleStillYieldsAUnionSoTheSpouseIsPlaced() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [couple("me", "spouse")]
        )

        #expect(placed(layout) == [person("me"), person("spouse")])
        let union = try? #require(layout.unions.first)
        #expect(union?.children.isEmpty == true)
        #expect(union.map { Set($0.partners) } == [person("me"), person("spouse")])
    }

    @Test func aUnionIsKeyedIndependentlyOfWhichParentIsReachedFirst() {
        let viaDad = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [parentChild("dad", "kid"), parentChild("mum", "kid")]
        )
        let viaMum = TreeProjection.hourglass(
            focus: person("mum"),
            relationships: [parentChild("dad", "kid"), parentChild("mum", "kid")]
        )

        #expect(viaDad.unions.first?.id == viaMum.unions.first?.id)
    }

    @Test func moreThanTwoRecordedParentsAreKeptAsOneUnion() {
        // e.g. birth *and* adoptive parents recorded on one child — splitting the set
        // would mean guessing which pair is "the" couple.
        let layout = TreeProjection.hourglass(
            focus: person("birthMum"),
            relationships: [
                parentChild("birthMum", "kid"),
                parentChild("adoptiveMum", "kid"),
                parentChild("adoptiveDad", "kid"),
            ]
        )

        let union = layout.unions.first { !$0.children.isEmpty }
        #expect(union?.partners.count == 3)
        #expect(union?.children == [person("kid")])
    }

    @Test func parentsUnionCarriesTheChildOnTheAncestorSide() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "me"),
                parentChild("mum", "me"),
            ]
        )

        let union = try? #require(layout.unions.first)
        #expect(union?.generation == -1)
        #expect(union?.children == [person("me")])
        #expect(union?.relationship == RelationshipID("REL-cp-dad-mum"))
    }

    // MARK: - Relationship endpoint accessors

    @Test func parentAndChildDecodeTheSection45Convention() {
        let record = parentChild("mum", "kid")
        #expect(record.parent == person("mum"))
        #expect(record.child == person("kid"))
    }

    @Test func parentAndChildAreNilForNonParentRelationships() {
        // A couple has no parent/child roles, and neither does an unrecognized type —
        // reading `person1Uid` as "the parent" regardless is exactly the bug these
        // accessors exist to prevent.
        #expect(couple("a", "b").parent == nil)
        #expect(couple("a", "b").child == nil)
        let odd = relationship(uid: "REL-x", type: .unknown("godparent"), "g", "kid")
        #expect(odd.parent == nil)
        #expect(odd.child == nil)
    }

    @Test func otherReturnsTheOppositeEndpointOrNil() {
        let record = couple("a", "b")
        #expect(record.other(from: person("a")) == person("b"))
        #expect(record.other(from: person("b")) == person("a"))
        #expect(record.other(from: person("stranger")) == nil)
        #expect(record.involves(person("a")))
        #expect(!record.involves(person("stranger")))
    }

    @Test func otherIsTypeAgnostic() {
        // Works on a parent-child record too, without implying either role.
        let record = parentChild("mum", "kid")
        #expect(record.other(from: person("kid")) == person("mum"))
        #expect(record.other(from: person("mum")) == person("kid"))
    }

    // MARK: - Partner placement

    @Test func eachMarriagesDropPointSitsBetweenItsOwnPartners() {
        // Stacking every partner to the right of the person puts the second union's
        // midpoint exactly on the first spouse's slot, so the second marriage's
        // children appear to descend from the first spouse.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("me", "first"),
                parentChild("me", "kidA"), parentChild("first", "kidA"),
                couple("me", "second"),
                parentChild("me", "kidB"), parentChild("second", "kidB"),
            ],
            ancestorDepth: 0
        )

        for union in layout.unions where union.partners.count == 2 {
            let slots = union.partners.compactMap { layout.node(for: $0)?.order }
            #expect(slots.count == 2)
            guard slots.count == 2 else { continue }
            // Adjacent partners: the drop point falls in the gap between them, never
            // on top of a third person's slot.
            #expect(
                abs(slots[0] - slots[1]) == 1,
                "union \(union.partners.map(\.raw)) partners are not adjacent: \(slots)"
            )
            // The drop point must not land on another person standing in the partners'
            // own row — that is the symptom of a union straddling a third node. (It
            // *should* line up with its children one row below.)
            let sameRow = Set(
                layout.nodes.filter { $0.generation == union.generation }.map(\.order)
            )
            #expect(
                !sameRow.contains(union.order),
                "union \(union.partners.map(\.raw)) drops at \(union.order), on a same-row node"
            )
        }
    }

    @Test func aLoneSpouseSitsBesideThePerson() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [couple("me", "spouse")]
        )

        let me = layout.node(for: person("me"))?.order
        let spouse = layout.node(for: person("spouse"))?.order
        #expect(me != nil && spouse != nil)
        if let me, let spouse { #expect(abs(me - spouse) == 1) }
    }

    // MARK: - Depth gating

    @Test func theDeepestGenerationStillShowsItsSpouses() {
        // A spouse shares their partner's generation, so asking for one generation of
        // children should not require pulling in grandchildren to see who they married.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kid"),
                couple("kid", "kidspouse"),
            ],
            ancestorDepth: 0,
            descendantDepth: 1
        )

        #expect(placed(layout) == [person("me"), person("kid"), person("kidspouse")])
        #expect(generation(of: "kidspouse", in: layout) == 1)
    }

    @Test func theDepthCutStillStopsChildren() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kid"),
                couple("kid", "kidspouse"),
                parentChild("kid", "grandkid"), parentChild("kidspouse", "grandkid"),
            ],
            ancestorDepth: 0,
            descendantDepth: 1
        )

        #expect(layout.node(for: person("grandkid")) == nil)
        // The union is still emitted for the couple bar, but reports no children,
        // so no edge points at a person who was never placed.
        let union = try? #require(layout.unions.first { $0.partners.count == 2 })
        #expect(union?.children.isEmpty == true)
        #expect(union?.parentEdges.isEmpty == true)
    }

    @Test func everyUnionChildAndPartnerIsActuallyPlaced() {
        // A union must never reference someone with no node — a renderer would draw an
        // edge into empty space.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kid"), couple("kid", "kidspouse"),
                parentChild("kid", "grandkid"), parentChild("kidspouse", "grandkid"),
            ],
            ancestorDepth: 0,
            descendantDepth: 1
        )

        let people = placed(layout)
        for union in layout.unions {
            for member in union.partners + union.children {
                #expect(people.contains(member), "\(member) is referenced but not placed")
            }
            for edge in union.parentEdges {
                #expect(people.contains(edge.parent) && people.contains(edge.child))
            }
        }
    }

    // MARK: - Siblings (slice 44f)

    @Test func siblingsSitBesideTheFocusInItsOwnGeneration() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("dad", "sis"), parentChild("mum", "sis"),
            ],
            descendantDepth: 0
        )

        #expect(generation(of: "sis", in: layout) == 0)
        // The sibling joins the focus's own parent union rather than making a new one.
        let parentUnion = try? #require(layout.unions.first { $0.generation == -1 })
        #expect(parentUnion.map { Set($0.children) } == [person("me"), person("sis")])
        #expect(parentUnion?.parentEdges.count == 4)
    }

    @Test func aHalfSiblingHangsOnlyFromTheSharedParent() {
        // The other parent isn't in the layout, so the half-sibling must not be folded
        // into the focus's parent union — that would draw a line implying a shared
        // mother the data explicitly contradicts.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("dad", "half"), parentChild("otherMum", "half"),
            ],
            descendantDepth: 0
        )

        #expect(generation(of: "half", in: layout) == 0)
        let fullUnion = layout.unions.first { Set($0.partners) == [person("dad"), person("mum")] }
        #expect(fullUnion?.children == [person("me")], "half-sibling folded into the wrong union")

        let halfUnion = layout.unions.first { $0.partners == [person("dad")] }
        #expect(halfUnion?.children == [person("half")])
        // And the unplaced other parent is never referenced by a drawn union.
        #expect(!layout.unions.flatMap(\.partners).contains(person("otherMum")))
    }

    @Test func siblingsAreBareNodesWithNoFamilyOfTheirOwn() {
        // Expanding a sibling's partners and children is what turns a direct line into
        // a cousin-fanning chart, so it is deliberately not done.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"),
                parentChild("dad", "sis"),
                couple("sis", "sisSpouse"),
                parentChild("sis", "niece"),
            ],
            descendantDepth: 3
        )

        #expect(layout.node(for: person("sis")) != nil)
        #expect(layout.node(for: person("sisSpouse")) == nil)
        #expect(layout.node(for: person("niece")) == nil)
    }

    @Test func siblingsCanBeTurnedOff() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me"), parentChild("dad", "sis")],
            descendantDepth: 0,
            includeSiblings: false
        )

        #expect(layout.node(for: person("sis")) == nil)
    }

    @Test func siblingsNeedAPlacedParentToHangFrom() {
        // With no ancestor generations drawn there is nothing to attach a sibling to,
        // so none are placed even though the graph knows about them.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me"), parentChild("dad", "sis")],
            ancestorDepth: 0,
            descendantDepth: 0
        )

        #expect(placed(layout) == [person("me")])
    }

    @Test func siblingsDoNotOverlapTheFocusOrItsPartners() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"), parentChild("dad", "sisA"), parentChild("dad", "sisB"),
                couple("me", "spouse"),
            ],
            descendantDepth: 1
        )

        let row = layout.nodes.filter { $0.generation == 0 }.map(\.order)
        #expect(Set(row).count == row.count, "generation 0 has overlapping slots: \(row.sorted())")
        #expect(row.count == 4)
    }

    // MARK: - Parent edges

    @Test func parentEdgesCarryTheStoredParentChildRecord() {
        // The seam that lets a renderer qualify an edge (adoptive, step, foster) from
        // the relationship's own facts, rather than drawing every parent line alike.
        let layout = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "kid"),
                parentChild("mum", "kid"),
            ]
        )

        let union = try? #require(layout.unions.first { !$0.children.isEmpty })
        // One edge per asserted parent→child record — two parents, two edges.
        #expect(union?.parentEdges.count == 2)
        #expect(
            union.map { Set($0.parentEdges.map(\.relationship)) }
                == [RelationshipID("REL-pc-dad-kid"), RelationshipID("REL-pc-mum-kid")]
        )
        #expect(union?.parentEdges.allSatisfy { $0.child == person("kid") } == true)
    }

    @Test func ancestorSideAlsoCarriesParentEdges() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("dad", "me"), parentChild("mum", "me")],
            descendantDepth: 0
        )

        let union = try? #require(layout.unions.first)
        #expect(union?.parentEdges.count == 2)
        #expect(union?.parentEdges.allSatisfy { $0.child == person("me") } == true)
        #expect(
            union.map { Set($0.parentEdges.map(\.parent)) } == [person("dad"), person("mum")]
        )
    }

    @Test func parentEdgesSurviveSlotNormalization() {
        // `finish()` rebuilds every union to shift slots to zero; the edges have to
        // ride through that rebuild.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("me", "kid"),
            ]
        )

        #expect(layout.nodes.map(\.order).min() == 0)
        #expect(layout.unions.allSatisfy { $0.children.isEmpty || !$0.parentEdges.isEmpty })
    }

    @Test func aChildlessCoupleHasNoParentEdges() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [couple("me", "spouse")]
        )

        #expect(layout.unions.first?.parentEdges.isEmpty == true)
    }

    // MARK: - Layout invariants

    @Test func noTwoNodesShareASlotInAGeneration() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("granddadP", "dad"), parentChild("grandmaP", "dad"),
                parentChild("granddadM", "mum"), parentChild("grandmaM", "mum"),
                couple("me", "spouse"),
                parentChild("me", "kidA"), parentChild("spouse", "kidA"),
                parentChild("me", "kidB"), parentChild("spouse", "kidB"),
            ]
        )

        let byGeneration = Dictionary(grouping: layout.nodes, by: \.generation)
        for (generation, nodes) in byGeneration {
            let slots = nodes.map(\.order)
            #expect(
                Set(slots).count == slots.count,
                "generation \(generation) has overlapping slots: \(slots.sorted())"
            )
        }
    }

    @Test func ancestralLinesStayInDisjointRanges() {
        // The no-crossing guarantee: a depth-first walk places all of one parent's
        // ancestry before any of the other's, so the two lines never interleave.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("granddadP", "dad"), parentChild("grandmaP", "dad"),
                parentChild("granddadM", "mum"), parentChild("grandmaM", "mum"),
                parentChild("greatP", "granddadP"),
                parentChild("greatM", "granddadM"),
            ],
            ancestorDepth: 3,
            descendantDepth: 0
        )

        let paternal = ["dad", "granddadP", "grandmaP", "greatP"]
        let maternal = ["mum", "granddadM", "grandmaM", "greatM"]
        let paternalMax = paternal.compactMap { layout.node(for: person($0))?.order }.max()
        let maternalMin = maternal.compactMap { layout.node(for: person($0))?.order }.min()

        #expect(paternalMax != nil)
        #expect(maternalMin != nil)
        if let paternalMax, let maternalMin {
            #expect(paternalMax < maternalMin, "paternal and maternal lines interleave")
        }
    }

    @Test func siblingSubtreesStayInDisjointRanges() {
        // The same guarantee on the descendant side: one child's whole subtree is
        // placed before the next child's.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kidA"), parentChild("me", "kidB"),
                parentChild("kidA", "grandkidA1"), parentChild("kidA", "grandkidA2"),
                parentChild("kidB", "grandkidB1"),
            ],
            ancestorDepth: 0,
            descendantDepth: 3
        )

        let branchA = ["kidA", "grandkidA1", "grandkidA2"]
        let branchB = ["kidB", "grandkidB1"]
        let maxA = branchA.compactMap { layout.node(for: person($0))?.order }.max()
        let minB = branchB.compactMap { layout.node(for: person($0))?.order }.min()

        #expect(maxA != nil)
        #expect(minB != nil)
        if let maxA, let minB {
            #expect(maxA < minB, "sibling subtrees interleave")
        }
    }

    @Test func aSubtreeStaysUnderTheParentItHangsFrom() {
        // The second child's own descendants must not be stranded to the left: the
        // second child's slot is pushed right by the first child's subtree, and its
        // grandchildren have to travel with it.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kidA"),
                parentChild("me", "kidB"),
                parentChild("kidB", "grandkid"),
            ],
            ancestorDepth: 0,
            descendantDepth: 3
        )

        let kidB = layout.node(for: person("kidB"))?.order
        let grandkid = layout.node(for: person("grandkid"))?.order
        #expect(kidB != nil && grandkid != nil)
        if let kidB, let grandkid {
            #expect(
                grandkid == kidB,
                "an only child should sit directly under its parent (parent \(kidB), child \(grandkid))"
            )
        }
    }

    @Test func aRecentredSubtreeStillCannotOverlapASibling() {
        // The shift moves a subtree rightward; the generation cursors must follow it,
        // or a later sibling's subtree lands on top of the one just moved.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "kidA"),
                parentChild("me", "kidB"), parentChild("kidB", "b1"), parentChild("kidB", "b2"),
                parentChild("me", "kidC"), parentChild("kidC", "c1"), parentChild("kidC", "c2"),
            ],
            ancestorDepth: 0,
            descendantDepth: 3
        )

        let byGeneration = Dictionary(grouping: layout.nodes, by: \.generation)
        for (generation, nodes) in byGeneration {
            let slots = nodes.map(\.order).sorted()
            #expect(
                Set(slots).count == slots.count,
                "generation \(generation) has overlapping slots after a shift: \(slots)"
            )
        }
        // And the two grandchild pairs stay in disjoint ranges.
        let bs = ["b1", "b2"].compactMap { layout.node(for: person($0))?.order }
        let cs = ["c1", "c2"].compactMap { layout.node(for: person($0))?.order }
        #expect(bs.max() != nil && cs.min() != nil)
        if let bMax = bs.max(), let cMin = cs.min() { #expect(bMax < cMin) }
    }

    @Test func slotsAreNormalizedToStartAtZero() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("me", "kid"),
            ]
        )

        #expect(layout.nodes.map(\.order).min() == 0)
    }

    @Test func aParentPairIsCenteredOverItsChild() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                couple("dad", "mum"),
                parentChild("dad", "me"),
                parentChild("mum", "me"),
            ],
            descendantDepth: 0
        )

        let me = try? #require(layout.node(for: person("me")))
        let dad = try? #require(layout.node(for: person("dad")))
        let mum = try? #require(layout.node(for: person("mum")))
        guard let me, let dad, let mum else { return }

        #expect((dad.order + mum.order) / 2 == me.order)
        // The union's drop point sits on the same midpoint.
        #expect(layout.unions.first?.order == me.order)
    }

    @Test func layoutIsDeterministicAcrossRuns() {
        let relationships = [
            couple("dad", "mum"),
            parentChild("dad", "me"), parentChild("mum", "me"),
            parentChild("me", "kidA"), parentChild("me", "kidB"),
        ]

        let first = TreeProjection.hourglass(focus: person("me"), relationships: relationships)
        let second = TreeProjection.hourglass(focus: person("me"), relationships: relationships)

        #expect(first == second)
    }

    // MARK: - Data hazards

    @Test func pedigreeCollapsePlacesTheSharedAncestorOnce() {
        // Cousin marriage: both of the focus's parents descend from one ancestor, so
        // the walk arrives at "shared" twice.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"),
                parentChild("mum", "me"),
                parentChild("shared", "dad"),
                parentChild("shared", "mum"),
            ]
        )

        let sharedNodes = layout.nodes.filter { $0.person == person("shared") }
        #expect(sharedNodes.count == 1)
        // The second arrival is reported as a cross-edge instead of a duplicate node.
        #expect(layout.repeats.count == 1)
        #expect(layout.repeats.first?.person == person("shared"))
        #expect(layout.repeats.first?.via == person("mum"))
    }

    @Test func everyPlacedAncestorIsConnectedToAChild() {
        // The mixed case: "shared" is a grandparent on both sides, so by the time the
        // walk reaches mum's parents it is already placed and only "grandmaM" is
        // fresh. That lone fresh parent still needs a union, or it renders floating
        // with no edge down to mum.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("dad", "me"), parentChild("mum", "me"),
                parentChild("shared", "dad"),
                parentChild("shared", "mum"), parentChild("grandmaM", "mum"),
            ]
        )

        #expect(layout.node(for: person("grandmaM")) != nil)
        let connected = Set(layout.unions.flatMap(\.partners))
        for node in layout.nodes where node.generation < 0 {
            #expect(
                connected.contains(node.person),
                "\(node.person) is placed but belongs to no union"
            )
        }
    }

    @Test func aChildAlreadyPlacedAsASiblingsPartnerKeepsItsParentEdge() {
        // The descendant-side twin of `everyPlacedAncestorIsConnectedToAChild`: two of
        // the focus's children marry each other, so the second is reached first as the
        // first one's partner. It is still the focus's child and must keep that edge,
        // or it renders unparented.
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                parentChild("me", "sonA"),
                parentChild("me", "sonB"),
                couple("sonA", "sonB"),
            ],
            ancestorDepth: 0
        )

        let parentUnion = try? #require(layout.unions.first { $0.partners == [person("me")] })
        #expect(parentUnion.map { Set($0.children) } == [person("sonA"), person("sonB")])
        #expect(parentUnion?.parentEdges.count == 2)
        // Both children sit one generation below, so neither is a cross-generation
        // arrival needing a repeat edge.
        #expect(generation(of: "sonB", in: layout) == 1)
        #expect(layout.repeats.isEmpty)
    }

    @Test func aChildArrivingFromAnotherGenerationIsReportedAsARepeat() {
        // The complement: when the already-placed child is *not* one generation below,
        // the edge would span generations, so it stays a cross-edge rather than being
        // folded into `children`.
        let layout = TreeProjection.hourglass(
            focus: person("a"),
            relationships: [
                parentChild("a", "b"),
                parentChild("b", "c"),
                parentChild("c", "a"),
            ],
            ancestorDepth: 0,
            descendantDepth: 10
        )

        #expect(placed(layout) == [person("a"), person("b"), person("c")])
        #expect(layout.repeats.contains { $0.person == person("a") && $0.via == person("c") })
        for union in layout.unions {
            #expect(!union.children.contains(person("a")), "cycle edge folded into children")
        }
    }

    @Test func anAncestorCycleTerminates() {
        // Hand-entered data can assert a loop; the walk must stop rather than recurse
        // forever.
        let layout = TreeProjection.hourglass(
            focus: person("a"),
            relationships: [
                parentChild("a", "b"),
                parentChild("b", "c"),
                parentChild("c", "a"),
            ],
            ancestorDepth: 10,
            descendantDepth: 10
        )

        #expect(placed(layout) == [person("a"), person("b"), person("c")])
        #expect(layout.repeats.isEmpty == false)
    }

    @Test func aSelfParentAssertionIsIgnored() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [parentChild("me", "me")]
        )

        #expect(placed(layout) == [person("me")])
        #expect(layout.unions.isEmpty)
    }

    @Test func unknownRelationshipTypesContributeNoEdges() {
        let layout = TreeProjection.hourglass(
            focus: person("me"),
            relationships: [
                relationship(uid: "REL-x", type: .unknown("godparent"), "godparent", "me")
            ]
        )

        #expect(placed(layout) == [person("me")])
    }

    @Test func duplicateRelationshipRecordsDoNotDuplicateAChild() {
        let layout = TreeProjection.hourglass(
            focus: person("dad"),
            relationships: [
                parentChild("dad", "kid", uid: "REL-first"),
                parentChild("dad", "kid", uid: "REL-second"),
            ]
        )

        #expect(layout.nodes.filter { $0.person == person("kid") }.count == 1)
        #expect(layout.unions.first?.children == [person("kid")])
    }
}

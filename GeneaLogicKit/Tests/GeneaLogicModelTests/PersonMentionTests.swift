import Testing

@testable import GeneaLogicModel

/// `PersonMention.nextLocalRef(in:claimedBy:statedIn:)` — the format-level rule for
/// minting a mention's record-local anchor.
///
/// This rule lives in the model (rather than in each consumer) because the Mac
/// app, the `genea` CLI and any future consumer must mint refs *identically* or
/// they disagree about what an `EvidenceLink` points at. Slice 44c moved it here
/// after both hand-written copies turned out to share the bug the last test in
/// this suite pins.
@Suite struct PersonMentionTests {

    private func mention(_ ref: String, _ name: String = "Anna Meyer") -> PersonMention {
        PersonMention(
            localRef: ref, nameAsRecorded: name, role: .subject, informationQuality: .primary)
    }

    private func link(claiming ref: String) -> EvidenceLink {
        EvidenceLink(
            uid: "LNK-018f3c9a-7b2e-7c41-9e3a-000000000043",
            artifactUid: "ART-018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70",
            personMentionRef: ref,
            personUid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
            match: MatchBreakdown(
                name: MatchDimension(kind: .exact, score: 100), conflicts: []),
            sourceAuthorityWeight: 100,
            informationQualityWeight: 100,
            aggregateConfidence: 100,
            reviewStatus: .humanConfirmed,
            reviewedBy: nil,
            reviewedAt: nil,
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-07-19T00:00:00Z", tool: nil,
                reviewStatus: .asserted)
        )
    }

    /// The first mention on a record is `p1`, and refs then ascend.
    @Test func mintsSequentialRefs() {
        #expect(PersonMention.nextLocalRef(in: [], claimedBy: [], statedIn: []) == "p1")
        #expect(
            PersonMention.nextLocalRef(in: [mention("p1")], claimedBy: [], statedIn: []) == "p2")
        #expect(
            PersonMention.nextLocalRef(
                in: [mention("p1"), mention("p2")], claimedBy: [], statedIn: []) == "p3")
    }

    /// A gap left by a removed mention is reused, so refs don't drift upward
    /// forever on a record that's been edited a lot.
    @Test func reusesAFreedRef() {
        #expect(
            PersonMention.nextLocalRef(in: [mention("p2")], claimedBy: [], statedIn: []) == "p1")
        #expect(
            PersonMention.nextLocalRef(
                in: [mention("p1"), mention("p3")], claimedBy: [], statedIn: []) == "p2")
    }

    /// Refs don't have to be contiguous or ordered for the mint to be correct.
    @Test func handlesUnorderedAndNonContiguousRefs() {
        let mentions = [mention("p3"), mention("p1"), mention("p7")]
        #expect(PersonMention.nextLocalRef(in: mentions, claimedBy: [], statedIn: []) == "p2")
    }

    /// A ref an unrelated string occupies is simply not a `p<n>` and is ignored.
    @Test func ignoresRefsThatArentTheMintedShape() {
        #expect(
            PersonMention.nextLocalRef(in: [mention("witness-a")], claimedBy: [], statedIn: [])
                == "p1")
    }

    /// **The regression this suite exists for** (slice 44c).
    ///
    /// Removing a mention leaves any link pointing at it dangling (§2.3, no
    /// cascade). If the mint then reuses that freed ref, the stale link resolves
    /// again — to a *different person*. A visible dangle silently becomes an
    /// invisible wrong conclusion.
    ///
    /// Both previous copies of this rule (app and CLI) reused the ref, and both
    /// had test coverage: one test proved reuse, another proved links survive a
    /// mention removal. Nothing composed the two, which is exactly why the bug
    /// lived — so this test composes them.
    @Test func doesNotReuseARefAStillLivingLinkClaims() {
        // p1's mention was removed; its link survives, still naming "p1".
        let remaining: [PersonMention] = []
        let survivingLinks = [link(claiming: "p1")]

        let minted = PersonMention.nextLocalRef(
            in: remaining, claimedBy: survivingLinks, statedIn: [])

        #expect(minted != "p1", "reusing p1 would re-bind the stale link to the new mention")
        #expect(minted == "p2")
    }

    /// The claim check composes with ordinary occupancy: a ref is free only when
    /// *neither* a mention nor a link holds it.
    @Test func skipsRefsHeldByEitherAMentionOrALink() {
        let mentions = [mention("p2")]
        let links = [link(claiming: "p1")]

        #expect(PersonMention.nextLocalRef(in: mentions, claimedBy: links, statedIn: []) == "p3")
    }

    /// Passing links from beyond this artifact is safe — over-conservative, never
    /// wrong — so a caller that hands over a wider set can't reintroduce the bug.
    @Test func extraLinksOnlyEverSkipMoreRefs() {
        let minted = PersonMention.nextLocalRef(
            in: [], claimedBy: [link(claiming: "p1"), link(claiming: "p2")], statedIn: [])
        #expect(minted == "p3")
    }

    /// **The same regression one layer in** (slice 45k): a stated relationship names
    /// mentions by `localRef` as firmly as a link does, and removing a mention strands
    /// the edge rather than cascading. Reusing the freed ref would silently make the
    /// next person somebody's parent — the invisible wrong conclusion again, this time
    /// inside the record itself.
    @Test func doesNotReuseARefAStatedRelationshipNames() {
        // The child (p2) survives; the parent's mention (p1) was removed, and the edge
        // the record stated still names it.
        let remaining = [mention("p2")]
        let edges = [MentionRelationship(type: .parentChild, person1Ref: "p1", person2Ref: "p2")]

        let minted = PersonMention.nextLocalRef(in: remaining, claimedBy: [], statedIn: edges)

        #expect(minted != "p1", "reusing p1 would make the new mention p2's parent")
        #expect(minted == "p3")
    }

    /// Both endpoints of an edge claim their ref, whichever end went missing, and an
    /// edge of an unrecognized type claims them just the same — the ref is occupied by
    /// whatever the record says, not by what this version can interpret.
    @Test func bothEndpointsOfAnEdgeClaimTheirRef() {
        let unknown = MentionRelationship(
            type: .unknown("employer"), person1Ref: "p1", person2Ref: "p2")
        #expect(PersonMention.nextLocalRef(in: [], claimedBy: [], statedIn: [unknown]) == "p3")
    }
}

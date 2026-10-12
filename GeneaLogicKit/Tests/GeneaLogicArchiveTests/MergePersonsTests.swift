import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Merging two concluded persons that describe one human being — slice 45f.
///
/// The cascade is the slice, so most of these tests are about what merge does to
/// *other* records: §2.3's no-cascade rule is suspended here, which means every
/// collision the rewrite can create needs a decided answer and a test that pins it.
/// The last suite is the one that makes the whole thing safe — a revert has to put back
/// every record the cascade touched, or the app's ⌘Z is a lie.
@Suite struct MergePersonsTests {

    // MARK: - Fixtures

    private func mention(_ localRef: String, _ nameAsRecorded: String) -> PersonMention {
        PersonMention(
            localRef: localRef,
            nameAsRecorded: nameAsRecorded,
            role: .subject,
            informationQuality: .primary)
    }

    /// Two persons for the same man, catalogued twice — the situation a merge fixes.
    private func duplicates() throws -> (archive: Archive, survivor: Person, absorbed: Person) {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let survivor = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let absorbed = try archive.addPerson(.sample(given: "Meir", surname: "Hanner"))
        return (archive, survivor, absorbed)
    }

    // MARK: - The person record

    /// Names and facts are union'd rather than replaced: the absorbed record's evidence
    /// is the reason the merge is worth doing.
    @Test func mergeUnionsNamesAndFacts() throws {
        let (archive, survivor, absorbed) = try duplicates()
        try archive.updatePerson(absorbed.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1881")]
        }
        try archive.updatePerson(survivor.uid) {
            $0.facts = [PersonFact(type: .death, date: "1954")]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.survivor.uid == survivor.uid)
        #expect(decision.survivor.names.count == 2)
        #expect(decision.survivor.names.first?.given == "Marcus")
        #expect(decision.survivor.facts.map(\.type) == [.death, .birth])
        #expect(archive.person(withID: absorbed.uid) == nil)
    }

    /// Exact duplicates collapse; anything that differs in any field survives as two
    /// assertions. A merge is not the place to decide that `1881` and `1881~` are the
    /// same claim.
    @Test func mergeDropsOnlyExactDuplicates() throws {
        let (archive, survivor, absorbed) = try duplicates()
        try archive.updatePerson(survivor.uid) {
            $0.names = [PersonName.deriving(type: .birth, given: "Marcus", surname: "Hanner")]
            $0.facts = [PersonFact(type: .birth, date: "1881")]
        }
        try archive.updatePerson(absorbed.uid) {
            $0.names = [PersonName.deriving(type: .birth, given: "Marcus", surname: "Hanner")]
            $0.facts = [PersonFact(type: .birth, date: "1881~")]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.survivor.names.count == 1)
        #expect(decision.survivor.facts.map(\.date) == ["1881", "1881~"])
    }

    /// The same claim recorded from two different records is **one conclusion with two
    /// citations**, not two facts. This is the normal shape in a real archive rather than
    /// an edge case: 42c's *record a fact from linked evidence* stamps each fact with the
    /// link it came from, so two duplicate persons built from their own sources always
    /// disagree on `supportedByLinks` while agreeing on everything a reader can see.
    /// Exact-equality union left two identical-looking rows behind (found in hand-testing).
    @Test func facesTheSameClaimFromTwoSourcesAsOneFact() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [
                mention("p1", "Marcus Hanner"), mention("p2", "Meir Hanner"),
            ]))
        let first = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"), to: survivor.uid
        ).link
        let second = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p2"), to: absorbed.uid
        ).link
        try archive.updatePerson(survivor.uid) {
            $0.facts = [
                PersonFact(
                    type: .birth, date: "1881", place: "Łomża", supportedByLinks: [first.uid])
            ]
        }
        try archive.updatePerson(absorbed.uid) {
            $0.facts = [
                PersonFact(
                    type: .birth, date: "1881", place: "Łomża", supportedByLinks: [second.uid]),
                // A different claim, so it stays a second fact however alike it looks.
                PersonFact(
                    type: .birth, date: "1881~", place: "Łomża", supportedByLinks: [second.uid]),
            ]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.survivor.facts.count == 2)
        #expect(decision.survivor.facts[0].supportedByLinks == [first.uid, second.uid])
        #expect(decision.survivor.facts[1].date == "1881~")
    }

    /// The survivor keeps its own identity — uid and provenance — because it *is* the
    /// same concluded person. Only `identifierURI` falls back to the absorbed record's,
    /// since an empty field is not a competing claim.
    @Test func survivorKeepsItsIdentity() throws {
        let (archive, survivor, absorbed) = try duplicates()
        try archive.updatePerson(absorbed.uid) { $0.identifierURI = "https://example.org/p/2" }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.survivor.uid == survivor.uid)
        #expect(decision.survivor.provenance == survivor.provenance)
        #expect(decision.survivor.identifierURI == "https://example.org/p/2")
    }

    // MARK: - Guards

    @Test func mergingAPersonIntoItselfThrows() throws {
        let (archive, survivor, _) = try duplicates()
        #expect(throws: ArchiveError.cannotMergePersonIntoItself(survivor.uid)) {
            try archive.mergePersons(survivor.uid, into: survivor.uid)
        }
    }

    @Test func mergingAMissingPersonThrows() throws {
        let (archive, survivor, absorbed) = try duplicates()
        try archive.removePerson(absorbed.uid)
        #expect(throws: ArchiveError.personNotFound(absorbed.uid)) {
            try archive.mergePersons(absorbed.uid, into: survivor.uid)
        }
    }

    // MARK: - Links

    /// The cascade proper: a link naming the absorbed person now names the survivor,
    /// and nothing is left pointing at a record that no longer exists.
    @Test func mergeRelinksEvidenceLinks() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Meir Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let link = try archive.link(ref, to: absorbed.uid).link

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.evidenceLink(withID: link.uid)?.personUid == survivor.uid)
        #expect(decision.relinkedLinks.map(\.uid) == [link.uid])
        #expect(archive.links(for: survivor.uid).count == 1)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// A tombstone is a record on disk, not a citation (45c's rule read the other way):
    /// left naming the absorbed uid it would dangle, and would stop foreclosing the pair
    /// it was written to foreclose.
    @Test func mergeRelinksRejectionTombstones() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Chaim Weiss")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let tombstone = try archive.reject(ref, as: absorbed.uid).link

        try archive.mergePersons(absorbed.uid, into: survivor.uid)

        let moved = try #require(archive.evidenceLink(withID: tombstone.uid))
        #expect(moved.personUid == survivor.uid)
        #expect(moved.isRejection)
        // Still hidden from every citation surface, still foreclosing the pair.
        #expect(archive.links(for: survivor.uid).isEmpty)
        #expect(archive.links(for: survivor.uid, includeRejected: true).count == 1)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// The verdict clash: a confirmation on one person and a rejection on the other, for
    /// the same mention. The merge asserts the two are one person, which is the later and
    /// more specific judgement — so the confirmation stands and the tombstone is dropped
    /// *and reported*, never silently.
    @Test func aConfirmationBeatsATombstoneOnTheSameTriple() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let confirmed = try archive.link(ref, to: survivor.uid).link
        let tombstone = try archive.reject(ref, as: absorbed.uid).link

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.evidenceLink(withID: confirmed.uid)?.personUid == survivor.uid)
        #expect(archive.evidenceLink(withID: tombstone.uid) == nil)
        #expect(decision.droppedLinks.map(\.uid) == [tombstone.uid])
        #expect(archive.links(for: survivor.uid, includeRejected: true).count == 1)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// Two confirmations of the same mention say the identical thing, so they collapse to
    /// the **survivor's** record — and a fact citing the dropped one is **repointed**, not
    /// stranded. The citation is still true; destroying it would be the merge damaging
    /// something the user never touched.
    ///
    /// The absorbed person's link is written first, so a uid tie-break would keep the
    /// wrong one about half the time (non-monotonic `UUIDv7`, same as the relationship
    /// tests below).
    @Test func duplicateConfirmationsCollapseAndCitationsFollow() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let duplicate = try archive.link(ref, to: absorbed.uid).link
        let kept = try archive.link(ref, to: survivor.uid).link
        try archive.updatePerson(absorbed.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1881", supportedByLinks: [duplicate.uid])]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.droppedLinks.map(\.uid) == [duplicate.uid])
        #expect(decision.survivor.facts.first?.supportedByLinks == [kept.uid])
        #expect(decision.strandedCitations.isEmpty)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// A dropped *tombstone* is a different claim from the confirmation that displaced
    /// it, so a citation of it is reported rather than quietly re-aimed — repointing
    /// would turn a recorded "no" into evidence.
    @Test func aStrandedCitationIsReportedRatherThanRepointed() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        try archive.link(ref, to: survivor.uid)
        let tombstone = try archive.reject(ref, as: absorbed.uid).link
        try archive.updatePerson(survivor.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1881", supportedByLinks: [tombstone.uid])]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(
            decision.strandedCitations == [
                .personFactSupport(person: survivor.uid, factIndex: 0, missingLink: tombstone.uid)
            ])
    }

    // MARK: - Relationships

    @Test func mergeRepointsRelationshipEndpoints() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let child = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        let edge = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: absorbed.uid, person2Uid: child.uid))

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.relationship(withID: edge.uid)?.person1Uid == survivor.uid)
        #expect(decision.rewrittenRelationships.map(\.uid) == [edge.uid])
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// A relationship *between* the two merged persons becomes a person married to
    /// themselves — meaningless, and something the tree projection would have to draw.
    @Test func mergeDropsTheSelfLoopItCreates() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let edge = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: survivor.uid, person2Uid: absorbed.uid))

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.relationship(withID: edge.uid) == nil)
        #expect(decision.droppedRelationships.map(\.uid) == [edge.uid])
        #expect(archive.relationships(of: survivor.uid).isEmpty)
    }

    /// Both duplicates being children of the same father is one fact recorded twice. The
    /// **survivor's** edge is the one kept, and it **absorbs the other's facts** — a date
    /// filed on one of two duplicate edges is an accident of which record the user was
    /// looking at, not a reason to lose it.
    ///
    /// The absorbed person's edge is created **first** here on purpose: an "oldest wins"
    /// tie-break would keep that one, and it would be right about half the time anyway,
    /// because this archive's `UUIDv7` is deliberately non-monotonic within a millisecond
    /// and two records minted in one pass sort by their random bits. Which of the user's
    /// records survives must not be a coin flip.
    @Test func duplicateRelationshipsCollapseOntoTheSurvivorsEdge() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let father = try archive.addPerson(.sample(given: "Szlama", surname: "Hanner"))
        let duplicate = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: absorbed.uid))
        let kept = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: survivor.uid))
        try archive.updateRelationship(duplicate.uid) {
            $0.facts = [PersonFact(type: .adoptiveParent, date: "1889")]
        }

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.relationship(withID: duplicate.uid) == nil)
        #expect(decision.droppedRelationships.map(\.uid) == [duplicate.uid])
        let surviving = try #require(archive.relationship(withID: kept.uid))
        #expect(surviving.facts.map(\.date) == ["1889"])
        #expect(archive.relationships(of: survivor.uid).count == 1)
    }

    /// `couple` endpoints are symmetric (§4.5), so the same marriage recorded from each
    /// duplicate's side is one edge however the two records ordered it. Parent-child
    /// reversed is a *different* claim and must not collapse — the asymmetry is the test.
    @Test func coupleEdgesCollapseUnorderedAndParentChildDoesNot() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let wife = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        // Absorbed's edge first again, for the reason in the test above.
        let reversed = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: wife.uid, person2Uid: absorbed.uid))
        let kept = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: survivor.uid, person2Uid: wife.uid))
        let parentOfWife = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: absorbed.uid, person2Uid: wife.uid))
        let childOfWife = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: wife.uid, person2Uid: survivor.uid))

        try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.relationship(withID: kept.uid) != nil)
        #expect(archive.relationship(withID: reversed.uid) == nil)
        #expect(archive.relationship(withID: parentOfWife.uid) != nil)
        #expect(archive.relationship(withID: childOfWife.uid) != nil)
        #expect(archive.relationships(of: survivor.uid).count == 3)
    }

    /// **A merge cleans up only what it caused.** A duplicate edge among the survivor's
    /// *own* relationships predates this operation, and deleting it here would remove a
    /// record for reasons the user never asked about, inside an undo step labelled
    /// "merge".
    @Test func mergeLeavesADuplicateEdgeItDidNotCreateAlone() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let father = try archive.addPerson(.sample(given: "Szlama", surname: "Hanner"))
        let first = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: survivor.uid))
        let preExistingDuplicate = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: survivor.uid))
        // …and one the merge *does* create, so the pass is exercised rather than skipped.
        let absorbedEdge = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: absorbed.uid))

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.droppedRelationships.map(\.uid) == [absorbedEdge.uid])
        #expect(archive.relationship(withID: first.uid) != nil)
        #expect(archive.relationship(withID: preExistingDuplicate.uid) != nil)
    }

    /// The same rule for links, and the fixture is the point: `link()` **supersedes the
    /// pair itself** (45c), so an archive with two of the survivor's verdicts on one
    /// triple cannot be built by calling it twice — the anomaly has to be restored back
    /// onto disk the way a concurrent writer would leave it. Without that, this test
    /// passes vacuously and the merge is never handed the collision it must not adopt
    /// (which is exactly how the defect below survived its first review).
    ///
    /// What the merge *may* resolve is the collision across the two persons: the absorbed
    /// person's verdict loses to the survivor's and is dropped; the survivor's own
    /// duplicate is none of its business.
    @Test func mergeLeavesADuplicateVerdictItDidNotCreateAlone() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let ownLink = try archive.link(ref, to: survivor.uid).link
        let strayDuplicate = try archive.link(ref, to: survivor.uid).link
        // `link()` removed `ownLink` when it wrote `strayDuplicate`; put it back, which is
        // the state a second writer racing this one would leave.
        try archive.restoreLink(ownLink)
        let absorbedLink = try archive.link(ref, to: absorbed.uid).link
        // The fixture asserts itself: without this, a change to `link()`'s supersession
        // would quietly turn this back into a test of nothing.
        #expect(archive.links(for: survivor.uid, includeRejected: true).count == 2)

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.droppedLinks.map(\.uid) == [absorbedLink.uid])
        #expect(archive.evidenceLink(withID: ownLink.uid) != nil)
        #expect(archive.evidenceLink(withID: strayDuplicate.uid) != nil)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// The mirror image, and the one the fix above could have broken: when the absorbed
    /// person's verdict is the one that *wins* (a confirmation over the survivor's
    /// tombstone), everything still naming the absorbed record has to be repointed —
    /// including a duplicate of its own that the "don't adopt what you find" rule spares.
    /// A link left naming a person who no longer exists is the dangle this whole operation
    /// exists to prevent.
    @Test func everySurvivingLinkIsRepointedEvenWhenTheAbsorbedSideWins() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        try archive.reject(ref, as: survivor.uid)
        let winner = try archive.confirm(ref, as: absorbed.uid).link
        let absorbedDuplicate = try archive.link(ref, to: absorbed.uid).link
        try archive.restoreLink(winner)
        #expect(archive.links(for: absorbed.uid, includeRejected: true).count == 2)

        try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.evidenceLink(withID: winner.uid)?.personUid == survivor.uid)
        #expect(archive.evidenceLink(withID: absorbedDuplicate.uid)?.personUid == survivor.uid)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    /// A record the merge touched **only to follow a citation** onto a combined link is not
    /// a record it moved — and it can belong to two people with no part in the merge. Both
    /// front ends say "repointed onto ⟨survivor⟩", so the two sets are kept apart on the
    /// decision rather than each caller filtering (differently).
    @Test func aCitationFollowingRewriteIsNotReportedAsARepoint() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")
        let kept = try archive.link(ref, to: survivor.uid).link
        let collapsed = try archive.link(ref, to: absorbed.uid).link
        // Two bystanders, whose marriage happens to cite the link that is about to be
        // combined away.
        let first = try archive.addPerson(.sample(given: "David", surname: "Kotler"))
        let second = try archive.addPerson(.sample(given: "Lillian", surname: "Kotler"))
        let bystanders = try archive.addRelationship(
            RelationshipDraft(
                type: .couple, person1Uid: first.uid, person2Uid: second.uid,
                supportedByLinks: [collapsed.uid]))

        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(decision.rewrittenRelationships.map(\.uid) == [bystanders.uid])
        #expect(decision.repointedRelationships.isEmpty)
        #expect(decision.citationFollowingRewrites == 1)
        #expect(archive.relationship(withID: bystanders.uid)?.supportedByLinks == [kept.uid])
        #expect(archive.findDanglingReferences().isEmpty)
    }

    // MARK: - The sweep

    /// The property that makes the cascade worth having: after a merge over an archive
    /// wired every way at once, nothing points at anything missing.
    @Test func nothingDanglesAfterAMergeAcrossEveryRecordKind() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Meir Hanner"), mention("p2", "Fay Hanner")]))
        let wife = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        let link = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"), to: absorbed.uid
        ).link
        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p2"), to: wife.uid)
        try archive.addRelationship(
            RelationshipDraft(
                type: .couple, person1Uid: absorbed.uid, person2Uid: wife.uid,
                supportedByLinks: [link.uid]))
        try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: survivor.uid, person2Uid: absorbed.uid))
        try archive.updatePerson(absorbed.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1881", supportedByLinks: [link.uid])]
        }

        try archive.mergePersons(absorbed.uid, into: survivor.uid)

        #expect(archive.findDanglingReferences().isEmpty)
        #expect(archive.person(withID: absorbed.uid) == nil)
        #expect(archive.links(for: survivor.uid).map(\.uid) == [link.uid])
    }

    /// The index is a cache (§5.1), so a merge that wrote the sidecars but left the index
    /// disagreeing would look right until the next rebuild — and then quietly undo
    /// itself.
    @Test func aRebuiltIndexAgreesWithTheMergedSidecars() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Meir Hanner")]))
        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: absorbed.uid)

        try archive.mergePersons(absorbed.uid, into: survivor.uid)
        try archive.rebuildIndex()

        #expect(archive.persons().map(\.uid) == [survivor.uid])
        #expect(archive.links(for: survivor.uid).count == 1)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    // MARK: - Revert

    /// The one that makes ⌘Z honest. Every record the cascade touched — repointed,
    /// collapsed, dropped or union'd — comes back exactly as it was, because the merge
    /// minted nothing and the decision carries the before-state of all of it.
    @Test func revertRestoresEveryTouchedRecord() throws {
        let (archive, survivor, absorbed) = try duplicates()
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "M. Hanner"), mention("p2", "Meir Hanner")]))
        let father = try archive.addPerson(.sample(given: "Szlama", surname: "Hanner"))
        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: survivor.uid)
        try archive.reject(MentionRef(artifact: artifact.uid, localRef: "p1"), as: absorbed.uid)
        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p2"), to: absorbed.uid)
        try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: survivor.uid))
        try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: father.uid, person2Uid: absorbed.uid))
        try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: survivor.uid, person2Uid: absorbed.uid))
        try archive.updatePerson(survivor.uid) {
            $0.facts = [PersonFact(type: .death, date: "1954")]
        }
        try archive.updatePerson(absorbed.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1881")]
        }

        let before = try Snapshot(of: archive)
        let decision = try archive.mergePersons(absorbed.uid, into: survivor.uid)
        #expect(try Snapshot(of: archive) != before)

        try archive.revertMerge(decision)

        #expect(try Snapshot(of: archive) == before)
        // …and from the files alone, not just the index that was written alongside them.
        try archive.rebuildIndex()
        #expect(try Snapshot(of: archive) == before)
    }

    @Test func aMergeWithNothingToCascadeStillRevertsCleanly() throws {
        let (archive, survivor, absorbed) = try duplicates()

        let before = try Snapshot(of: archive)
        try archive.revertMerge(try archive.mergePersons(absorbed.uid, into: survivor.uid))

        #expect(try Snapshot(of: archive) == before)
    }

    /// Every conclusion record in the archive, compared as values — the whole point being
    /// that a revert is judged on *all* of it, not on the handful of fields a test
    /// remembered to check.
    private struct Snapshot: Equatable {
        var persons: [Person]
        var relationships: [Relationship]
        var links: [EvidenceLink]

        init(of archive: Archive) throws {
            persons = archive.persons().compactMap { archive.person(withID: $0.uid) }
                .sorted { $0.uid.raw < $1.uid.raw }
            relationships = archive.relationships().sorted { $0.uid.raw < $1.uid.raw }
            links = archive.persons()
                .flatMap { archive.links(for: $0.uid, includeRejected: true) }
                .sorted { $0.uid.raw < $1.uid.raw }
        }
    }
}

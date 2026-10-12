import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Candidate generation and `suggestLinks` (ARCHITECTURE.md §4.6, §6.3) — slice 45b.
///
/// Slice 45's own tests prove the *scoring*; these prove the **projection and the skip
/// rules**, which is everything that can only go wrong once real records are involved:
/// that a person's partners and parents are found by walking relationships, that a
/// record's other mentions arrive as co-mentions, that a human's decisions are
/// honored, and that nothing is written.
@Suite struct MatchingTests {

    // MARK: - Fixtures

    /// A mention with the fields these tests actually vary; everything else is the
    /// dull default, so a test's fixture reads as the one thing it is about.
    private func mention(
        _ localRef: String,
        _ nameAsRecorded: String,
        role: PersonRole = .subject,
        quality: InformationQuality = .primary,
        facts: [RecordedFact] = []
    ) -> PersonMention {
        PersonMention(
            localRef: localRef,
            nameAsRecorded: nameAsRecorded,
            role: role,
            informationQuality: quality,
            facts: facts)
    }

    /// Writes a `.humanRejected` tombstone straight to `conclusions/links/` and
    /// rebuilds the index from it.
    ///
    /// 45c owns the reject *entry point*; 45b only has to honor a tombstone that
    /// exists. Hand-writing the sidecar is therefore not a workaround — it is the
    /// stronger test, because it proves the skip rule reads what is on disk rather
    /// than some state a `reject()` call left behind in memory.
    private func writeRejection(
        of mention: MentionRef,
        as personID: PersonID,
        in archive: Archive,
        at root: URL
    ) throws {
        let link = EvidenceLink(
            uid: EvidenceLinkID("LNK-\(UUID().uuidString.lowercased())"),
            artifactUid: mention.artifact,
            personMentionRef: mention.localRef,
            personUid: personID,
            match: MatchBreakdown(name: MatchDimension(kind: .none, score: 0)),
            sourceAuthorityWeight: 0,
            informationQualityWeight: 0,
            aggregateConfidence: 0,
            reviewStatus: .humanRejected,
            provenance: Provenance(
                createdBy: .human,
                createdAt: "2026-07-25T00:00:00Z",
                reviewStatus: .humanVerified))

        let url = root.appendingPathComponent("conclusions/links/\(link.uid.raw).json")
        try GeneaLogicJSON.encoder.encode(link).write(to: url)
        try archive.rebuildIndex()
    }

    // MARK: - The suggestion is found, in both directions

    @Test func suggestsAMentionThatNamesThePerson() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        let suggestions = archive.suggestLinks(for: person.uid)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.mention == MentionRef(artifact: artifact.uid, localRef: "p1"))
        #expect(suggestions.first?.personID == person.uid)
        #expect(suggestions.first?.match.breakdown.name.kind == .exact)
    }

    @Test func suggestsAPersonForAnArtifactsMention() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addPerson(.sample(given: "Berek", surname: "Sternfeld"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        let grouped = archive.suggestLinks(forArtifact: artifact.uid)

        #expect(grouped.count == 1)
        #expect(grouped.first?.mention == MentionRef(artifact: artifact.uid, localRef: "p1"))
        #expect(grouped.first?.candidates.count == 1)
        #expect(grouped.first?.candidates.first?.personID == person.uid)
    }

    /// The decision that replaced a phonetic-key gate with brute force, pinned.
    ///
    /// `Fay`/`Faye` key *apart* under Daitch–Mokotoff — slice 45 pinned that as an
    /// honest failure of the keyer — and they stand in for one woman written both ways in
    /// the real archive.
    /// A key-blocked candidate generator would never have scored this pair at all, so
    /// the `.within` band it lands in would have been unreachable from an archive
    /// however well the scorer handled it.
    @Test func findsANearMissTheKeyerAloneWouldHaveDropped() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        _ = try archive.addArtifact(.sample(personsMentioned: [mention("p1", "Faye Hanner")]))

        let suggestions = archive.suggestLinks(for: person.uid)

        #expect(suggestions.count == 1)
        #expect(suggestions.first?.match.breakdown.name.kind == .within)
        // And it clears the shipped default, not merely some threshold: a suggestion
        // the user never sees is the same as one that was never made.
        #expect(
            (suggestions.first?.match.aggregateConfidence ?? 0)
                >= Archive.defaultMinimumConfidence)
    }

    @Test func doesNotSuggestAnUnrelatedPerson() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(.sample(personsMentioned: [mention("p1", "Sidney Feldberg")]))

        #expect(archive.suggestLinks(for: person.uid).isEmpty)
    }

    // MARK: - Projection: the relational dimensions

    /// The projection's real work: `spouseName` can only score if the person's
    /// partners were found by walking `couple` relationships *and* the record's other
    /// mentions arrived as co-mentions. Either half missing and the dimension is
    /// silently `nil` — a match that looks merely unremarkable rather than broken,
    /// which is why this is asserted rather than assumed.
    @Test func projectsPartnersAndCoMentionsIntoTheSpouseDimension() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let fay = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: marcus.uid, person2Uid: fay.uid))

        _ = try archive.addArtifact(
            .sample(
                title: "Marriage register",
                sourceAuthorityTier: .vital,
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Fay Hanner", role: .spouse),
                ]))

        let suggestion = archive.suggestLinks(for: marcus.uid).first { $0.mention.localRef == "p1" }

        #expect(suggestion?.match.breakdown.spouseName?.kind == .exact)
    }

    @Test func projectsParentsFromTheChildSideOnly() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let parent = try archive.addPerson(.sample(given: "Berek", surname: "Sternfeld"))
        let child = try archive.addPerson(.sample(given: "Hinda", surname: "Sternfeld"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: parent.uid, person2Uid: child.uid))

        _ = try archive.addArtifact(
            .sample(
                title: "Birth register",
                sourceAuthorityTier: .church,
                personsMentioned: [
                    mention("p1", "Hinda Sternfeld"),
                    mention("p2", "Berek Sternfeld", role: .parent),
                ]))

        let asChild = archive.suggestLinks(for: child.uid).first { $0.mention.localRef == "p1" }
        #expect(asChild?.match.breakdown.parents?.kind == .exact)

        // The parent is on the same record, and §4.5's convention says a `parent-child`
        // relationship gives them a child, not a parent. Reading the endpoints
        // symmetrically would hand Berek his own daughter as a parent and score it.
        let asParent = archive.suggestLinks(for: parent.uid).first { $0.mention.localRef == "p2" }
        #expect(asParent?.match.breakdown.parents == nil)
    }

    /// Slice 45k end-to-end: the record's stated edges have to survive the projection
    /// into a `MentionMatchView`, or the matcher's new rule is unreachable from the one
    /// path the app and CLI actually take.
    ///
    /// The register names two spouses' worth of parents. Without edges either spouse's
    /// mention reads all of them best-of (deliberately — a positive-only miss costs
    /// nothing); with them, only the stated pair corroborates.
    ///
    /// Scored through `matchScore(of:against:)` rather than `suggestLinks`, so the
    /// assertions are about the **breakdown** and not about whether a pair happened to
    /// clear the queue's minimum confidence. The discriminating case is a *confusable*
    /// candidate — a "Fay Hanner" whose parents are the groom's — which corroborates
    /// before the edges and must stop once the record says whose parents are whose.
    @Test func projectsStatedEdgesIntoTheParentsDimension() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        func fayHanner(parentedBy parentName: (given: String, surname: String)) throws -> PersonID {
            let fay = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
            let parent = try archive.addPerson(
                .sample(given: parentName.given, surname: parentName.surname))
            _ = try archive.addRelationship(
                RelationshipDraft(type: .parentChild, person1Uid: parent.uid, person2Uid: fay.uid))
            return fay.uid
        }

        // Two candidates for the bride's mention: one with her father, one with his.
        let correct = try fayHanner(parentedBy: ("Marcus", "Hanner"))
        let confusable = try fayHanner(parentedBy: ("Sidney", "Feldberg"))

        let artifact = try archive.addArtifact(
            .sample(
                title: "Marriage register",
                sourceAuthorityTier: .vital,
                personsMentioned: [
                    mention("p1", "Fay Hanner", role: .spouse),
                    mention("p2", "Irving Feldberg", role: .spouse),
                    mention("p3", "Marcus Hanner", role: .parent),
                    mention("p4", "Sidney Feldberg", role: .parent),
                ]))
        let brideMention = MentionRef(artifact: artifact.uid, localRef: "p1")

        // Before the edges: all four parents are read for either spouse, so *both*
        // candidates corroborate — the ambiguity this slice exists to remove.
        #expect(
            archive.matchScore(of: brideMention, against: correct)?.breakdown.parents?.kind
                == .exact)
        #expect(
            archive.matchScore(of: brideMention, against: confusable)?.breakdown.parents?.kind
                == .exact)

        // The record now says p3 is p1's parent and p4 is p2's.
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
                MentionRelationship(type: .parentChild, person1Ref: "p4", person2Ref: "p2"),
            ]
        }

        #expect(
            archive.matchScore(of: brideMention, against: correct)?.breakdown.parents?.kind
                == .exact)
        #expect(
            archive.matchScore(of: brideMention, against: confusable)?.breakdown.parents?.kind
                == MatchKind.none,
            "the groom's parents must stop corroborating the bride once the record says so")
    }

    /// §2.3: removals don't cascade, so a relationship pointing at a person who is
    /// gone is a normal state — not a reason to fail, and not a reason to score a
    /// phantom partner.
    @Test func toleratesARelationshipWhoseOtherEndpointIsGone() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let fay = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: marcus.uid, person2Uid: fay.uid))
        _ = try archive.removePerson(fay.uid)

        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Fay Hanner", role: .spouse),
                ]))

        let suggestion = archive.suggestLinks(for: marcus.uid).first { $0.mention.localRef == "p1" }

        #expect(suggestion != nil)
        #expect(suggestion?.match.breakdown.spouseName == nil)
    }

    // MARK: - Skip rules

    @Test func doesNotResuggestAnAlreadyLinkedMention() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")

        #expect(archive.suggestLinks(for: person.uid).count == 1)

        try archive.link(ref, to: person.uid)

        #expect(archive.suggestLinks(for: person.uid).isEmpty)
        #expect(archive.suggestLinks(forArtifact: artifact.uid).isEmpty)
    }

    /// A mention confirmed as somebody else is *resolved*, not available. Suggesting
    /// it again for a second person would be asserting that two concluded persons are
    /// the same — a duplicate-person claim, which is 45f's question and not one the
    /// evidence queue should be quietly making.
    @Test func doesNotSuggestAMentionResolvedToADifferentPerson() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let otherMarcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: marcus.uid)

        #expect(archive.suggestLinks(for: otherMarcus.uid).isEmpty)
    }

    @Test func doesNotResuggestARejectedPair() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let otherMarcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")

        #expect(archive.suggestLinks(forArtifact: artifact.uid).first?.candidates.count == 2)

        try writeRejection(of: ref, as: marcus.uid, in: archive, at: root)

        // The tombstone forecloses **that pair only** — the mention is still unresolved
        // (so it is still reported), and the other candidate is still a live question.
        let remaining = archive.suggestLinks(forArtifact: artifact.uid)
        #expect(remaining.count == 1)
        #expect(remaining.first?.candidates.count == 1)
        #expect(remaining.first?.candidates.first?.personID == otherMarcus.uid)
        #expect(archive.suggestLinks(for: marcus.uid).isEmpty)
    }

    // MARK: - The archive-wide worklist (45e)

    /// The direction the app's triage inbox reads: every unresolved mention in the
    /// archive, whether or not anything matched it.
    ///
    /// The zero-candidate mention is the assertion that matters. It is the *somebody
    /// new* case, it is the only work in this fixture that isn't already answered, and
    /// a flat or confidence-ordered result could not carry it at all.
    @Test func listsEveryUnresolvedMentionInTheArchive() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let deed = try archive.addArtifact(
            .sample(
                title: "Deed",
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    // Nobody in the archive is this person.
                    mention("p2", "Zelig Sternfeld"),
                ]))
        let census = try archive.addArtifact(
            .sample(title: "Census", personsMentioned: [mention("p1", "Marcus Hanner")]))

        let worklist = archive.suggestLinks()

        #expect(worklist.count == 3)
        #expect(worklist.map(\.mention.localRef) == ["p1", "p2", "p1"])
        #expect(Set(worklist.map(\.mention.artifact)) == Set([deed.uid, census.uid]))

        let unmatched = try #require(worklist.first { $0.mention.localRef == "p2" })
        #expect(unmatched.candidates.isEmpty)
        for matched in worklist.filter({ $0.mention.localRef == "p1" }) {
            #expect(matched.candidates.map(\.personID) == [marcus.uid])
        }
    }

    /// Document order, and the same order twice.
    ///
    /// `allArtifacts()` carries no `ORDER BY`, so the entry point sorts by `uid` itself
    /// — a queue that reshuffled between launches for no visible reason would be a bug,
    /// and SQLite promises nothing about unordered rows. Within an artifact the order is
    /// the record's own, which is the order the document in front of the reader is in.
    @Test func worklistIsInDocumentOrderAndStable() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        _ = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        // Two artifacts, minted in this order, each naming its mentions out of
        // alphabetical order — so neither the artifact nor the mention sequence below
        // could be produced by sorting names or refs.
        let first = try archive.addArtifact(
            .sample(
                title: "Zebra deed",
                personsMentioned: [mention("p2", "Marcus Hanner"), mention("p1", "Berek Hanner")]))
        let second = try archive.addArtifact(
            .sample(title: "Alpha census", personsMentioned: [mention("p1", "Marcus Hanner")]))

        let worklist = archive.suggestLinks(minimumConfidence: 0)

        #expect(
            worklist.map(\.mention)
                == [
                    MentionRef(artifact: first.uid, localRef: "p2"),
                    MentionRef(artifact: first.uid, localRef: "p1"),
                    MentionRef(artifact: second.uid, localRef: "p1"),
                ])
        #expect(
            archive.suggestLinks(minimumConfidence: 0).map(\.mention) == worklist.map(\.mention))
    }

    /// The worklist honors the same two skip rules as the other directions: a resolved
    /// mention leaves it entirely, a rejected pair leaves only that candidate behind.
    ///
    /// The second half is the distinction 45d's tuning pass found the CLI getting wrong:
    /// a mention whose *only* candidate is rejected still belongs in the queue, with an
    /// empty candidate list — it is unresolved, and something is owed on it.
    @Test func worklistHonorsResolutionsAndRejections() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Marcus Hanner"),
                ]))

        #expect(archive.suggestLinks().count == 2)

        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: marcus.uid)
        try writeRejection(
            of: MentionRef(artifact: artifact.uid, localRef: "p2"), as: marcus.uid, in: archive,
            at: root)

        let worklist = archive.suggestLinks()
        #expect(worklist.map(\.mention.localRef) == ["p2"])
        #expect(worklist.first?.candidates.isEmpty == true)
    }

    /// `limit` is per **mention**, not per archive — the artifact direction's meaning,
    /// since this is the same grouped shape. A whole-queue cap would silently truncate
    /// the worklist and hide mentions the user is responsible for.
    @Test func worklistLimitIsPerMention() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        _ = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Marcus Hanner"),
                ]))

        let capped = archive.suggestLinks(limit: 1)
        #expect(capped.count == 2)
        #expect(capped.allSatisfy { $0.candidates.count == 1 })
        #expect(archive.suggestLinks().allSatisfy { $0.candidates.count == 2 })
    }

    /// The archive-wide direction agrees with the per-artifact one for the same record.
    /// It projects the person views once for the whole run rather than once per
    /// artifact, and that is supposed to change the cost, not the answer.
    @Test func worklistAgreesWithThePerArtifactDirection() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let fay = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: marcus.uid, person2Uid: fay.uid))
        let artifact = try archive.addArtifact(
            .sample(
                sourceAuthorityTier: .vital,
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Fay Hanner", role: .spouse),
                ]))

        #expect(archive.suggestLinks() == archive.suggestLinks(forArtifact: artifact.uid))
        // Relational dimensions included: the shared projection is the part that could
        // have gone wrong, and a `nil` spouseName here would look merely unremarkable.
        #expect(
            archive.suggestLinks().first?.candidates.first?.match.breakdown.spouseName?.kind
                == .exact)
    }

    @Test func worklistIsEmptyWhenNothingIsUnresolved() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        #expect(archive.suggestLinks().isEmpty)

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))
        try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: person.uid)

        #expect(archive.suggestLinks().isEmpty)
        // An artifact naming nobody contributes nothing either — there is no mention to
        // be unresolved.
        _ = try archive.addArtifact(.sample(title: "Photograph", personsMentioned: []))
        #expect(archive.suggestLinks().isEmpty)
    }

    // MARK: - Ranking, thresholds, limits

    @Test func ranksByConfidenceAndBreaksTiesDeterministically() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        // Same artifact, three mentions: an exact name, a near miss, and a phonetic
        // hit — a spread wide enough that the order is a real claim about scoring.
        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Markus Hanaur"),
                    mention("p2", "Marcus Hanner"),
                    mention("p3", "Marcus Hannerr"),
                ]))

        let suggestions = archive.suggestLinks(for: person.uid)
        let scores = suggestions.map(\.match.aggregateConfidence)

        #expect(scores == scores.sorted(by: >))
        #expect(suggestions.first?.mention.localRef == "p2")
        // Stable across runs: the same archive, asked twice, answers identically.
        #expect(archive.suggestLinks(for: person.uid).map(\.mention) == suggestions.map(\.mention))
    }

    /// Ties are the case an unstable sort actually reorders, so they get their own
    /// test rather than riding on the spread above: two identical names on the same
    /// record score identically by construction.
    @Test func breaksAnExactTieByLocalRef() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p2", "Marcus Hanner"),
                    mention("p1", "Marcus Hanner"),
                ]))

        let suggestions = archive.suggestLinks(for: person.uid)

        #expect(suggestions.count == 2)
        #expect(
            suggestions[0].match.aggregateConfidence == suggestions[1].match.aggregateConfidence)
        #expect(suggestions.map(\.mention.localRef) == ["p1", "p2"])
    }

    @Test func honorsMinimumConfidenceAndLimit() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Marcus Hannerr"),
                ]))

        #expect(archive.suggestLinks(for: person.uid, limit: 1).count == 1)
        #expect(archive.suggestLinks(for: person.uid, minimumConfidence: 101).isEmpty)
        #expect(archive.suggestLinks(for: person.uid, minimumConfidence: 0).count == 2)
    }

    /// A non-positive `limit` returns nothing instead of trapping.
    ///
    /// The negative case used to hit `Array`'s "subrange start is negative"
    /// precondition — which fires in release builds too, so a CLI flag or a bad slider
    /// binding could crash the app on a read-only query. A query has no business
    /// killing the process over its own arguments.
    @Test func toleratesANonPositiveLimit() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(.sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        #expect(archive.suggestLinks(for: person.uid, limit: 0).isEmpty)
        #expect(archive.suggestLinks(for: person.uid, limit: -1).isEmpty)
        #expect(archive.suggestLinks(forArtifact: ArtifactID("ART-x"), limit: -5).isEmpty)
        // And the ordinary path is unaffected.
        #expect(archive.suggestLinks(for: person.uid, limit: 10).count == 1)
    }

    /// A relationship whose two endpoints are the same person must not make them their
    /// own spouse or their own parent.
    ///
    /// A data error rather than a normal state, but a reachable one — the dangling-
    /// reference suite already covers self-relationships — and the failure would be
    /// silent rather than loud: the person's own names would land in `partnerNames`,
    /// so any co-mention sharing their surname would read as a plausible spouse
    /// agreement and corroborate the match. On this corpus, where one record routinely
    /// names several people who share a surname, that is the common shape, not a
    /// contrived one.
    @Test func aSelfRelationshipDoesNotMakeAPersonTheirOwnRelative() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Sidney", surname: "Feldberg"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: person.uid, person2Uid: person.uid))
        _ = try archive.addRelationship(
            RelationshipDraft(
                type: .parentChild, person1Uid: person.uid, person2Uid: person.uid))

        // A second Feldberg on the record, tagged as the spouse — the co-mention that
        // would pair against the person's own names if the self-edge were followed.
        _ = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg"),
                    mention("p2", "Sidney Feldberg", role: .spouse),
                ]))

        let suggestion = archive.suggestLinks(for: person.uid).first { $0.mention.localRef == "p1" }

        #expect(suggestion != nil)
        #expect(suggestion?.match.breakdown.spouseName == nil)
        #expect(suggestion?.match.breakdown.parents == nil)
    }

    // MARK: - Ephemerality

    /// The mini-phase's governing decision, made testable: suggesting is a read.
    @Test func suggestingWritesNothing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(.sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        #expect(!archive.suggestLinks(for: person.uid).isEmpty)

        let links = root.appendingPathComponent("conclusions/links")
        let contents = try FileManager.default.contentsOfDirectory(atPath: links.path)
        #expect(contents.isEmpty)
        #expect(archive.links(for: person.uid).isEmpty)
    }

    // MARK: - The explain path

    @Test func matchScoreIgnoresThresholdsAndSkipRules() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Sidney Feldberg")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")

        // Scores far below the queue's floor, and is still explainable.
        let unrelated = archive.matchScore(of: ref, against: person.uid)
        // Spelled `MatchKind.none`, not `.none`: against an optional, a bare `.none`
        // resolves to `Optional.none` and the expectation quietly becomes "did this
        // return nil?" — which is the opposite of what this test is claiming.
        #expect(unrelated?.breakdown.name.kind == MatchKind.none)
        #expect(archive.suggestLinks(for: person.uid).isEmpty)

        // And a rejected pair stays explainable — "why was this rejected?" is a
        // question about exactly the pairs the queue hides.
        try writeRejection(of: ref, as: person.uid, in: archive, at: root)
        #expect(archive.matchScore(of: ref, against: person.uid) != nil)
    }

    /// The two paths read different record sets — `forSuggestion` loads the links the
    /// skip rules need, `forScoring` doesn't, and neither loads an artifact it wasn't
    /// handed. This pins that the narrowing changed what it *costs* to answer, not what
    /// the answer is: the same pair scores identically however it is reached, relational
    /// dimensions included.
    @Test func matchScoreAgreesWithTheSuggestionForTheSamePair() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let fay = try archive.addPerson(.sample(given: "Fay", surname: "Hanner"))
        let father = try archive.addPerson(.sample(given: "Berek", surname: "Hanner"))
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: marcus.uid, person2Uid: fay.uid))
        _ = try archive.addRelationship(
            RelationshipDraft(
                type: .parentChild, person1Uid: father.uid, person2Uid: marcus.uid))

        _ = try archive.addArtifact(
            .sample(
                sourceAuthorityTier: .vital,
                personsMentioned: [
                    mention("p1", "Marcus Hanner"),
                    mention("p2", "Fay Hanner", role: .spouse),
                    mention("p3", "Berek Hanner", role: .parent),
                ]))

        let suggestion = try #require(
            archive.suggestLinks(for: marcus.uid).first { $0.mention.localRef == "p1" })
        #expect(suggestion.match.breakdown.spouseName != nil)
        #expect(suggestion.match.breakdown.parents != nil)

        #expect(archive.matchScore(of: suggestion.mention, against: marcus.uid) == suggestion.match)
    }

    @Test func matchScoreIsNilForRecordsThatDontExist() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))

        #expect(
            archive.matchScore(
                of: MentionRef(artifact: artifact.uid, localRef: "p9"), against: person.uid) == nil)
        #expect(
            archive.matchScore(
                of: MentionRef(artifact: ArtifactID("ART-nope"), localRef: "p1"),
                against: person.uid) == nil)
        #expect(
            archive.matchScore(
                of: MentionRef(artifact: artifact.uid, localRef: "p1"),
                against: PersonID("PER-nope")) == nil)
    }

    // MARK: - Empty and missing

    @Test func returnsEmptyForRecordsThatDontExist() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        #expect(archive.suggestLinks(for: PersonID("PER-nope")).isEmpty)
        #expect(archive.suggestLinks(forArtifact: ArtifactID("ART-nope")).isEmpty)
    }

    @Test func returnsEmptyWhenTheArchiveHasNothingToMatch() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        _ = try archive.addArtifact(.sample(personsMentioned: []))

        #expect(archive.suggestLinks(for: person.uid).isEmpty)
    }
}

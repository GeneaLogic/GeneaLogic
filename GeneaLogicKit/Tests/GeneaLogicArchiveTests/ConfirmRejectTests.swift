import Foundation
import GeneaLogicArchive
import GeneaLogicMatch
import GeneaLogicModel
import Testing

/// The review lifecycle — confirm, reject, and the audit that keeps a rejection from
/// resurfacing as evidence (ARCHITECTURE.md §4.4) — slice 45c.
///
/// Two halves, and the second is the one that matters. Writing a tombstone is a dozen
/// lines; making it *invisible everywhere a link reads as a citation* is a property of
/// the whole read surface, and the failure mode is silent — a rejected pair quietly
/// listed as a source. So there is a test per consumer, deliberately repetitive, because
/// each one is a separate chance to have missed a filter.
@Suite struct ConfirmRejectTests {

    // MARK: - Fixtures

    private func mention(
        _ localRef: String,
        _ nameAsRecorded: String,
        facts: [RecordedFact] = []
    ) -> PersonMention {
        PersonMention(
            localRef: localRef,
            nameAsRecorded: nameAsRecorded,
            role: .subject,
            informationQuality: .primary,
            facts: facts)
    }

    /// One person, one artifact naming them, and the `MentionRef` between the two —
    /// the setup nearly every test below opens with.
    private func pair(
        given: String = "Marcus",
        surname: String = "Hanner",
        recorded: String = "Marcus Hanner"
    ) throws -> (archive: Archive, person: Person, artifact: Artifact, mention: MentionRef) {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let person = try archive.addPerson(.sample(given: given, surname: surname))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", recorded)]))
        return (
            archive, person, artifact,
            MentionRef(artifact: artifact.uid, localRef: "p1")
        )
    }

    // MARK: - Confirm stores the real reasoning

    /// The point of confirming through this path rather than `link()`: the breakdown
    /// survives. A confirmed suggestion that stored `link()`'s honest minimum would be
    /// indistinguishable from a hand-made link, which is the decomposed-reasoning
    /// design (§4.6) discarded at the one moment it becomes permanent.
    @Test func confirmStoresTheComputedBreakdown() throws {
        let (archive, person, _, ref) = try pair()

        let computed = try #require(archive.matchScore(of: ref, against: person.uid))
        let decision = try archive.confirm(ref, as: person.uid, match: computed)

        #expect(decision.link.reviewStatus == .humanConfirmed)
        #expect(decision.link.match == computed.breakdown)
        #expect(decision.link.aggregateConfidence == computed.aggregateConfidence)
        #expect(decision.link.sourceAuthorityWeight == computed.sourceAuthorityWeight)
        #expect(decision.link.informationQualityWeight == computed.informationQualityWeight)

        // A machine proposed it, a human decided it — both halves recorded.
        #expect(decision.link.provenance.createdBy == .machine)
        #expect(decision.link.provenance.tool == Matcher.toolIdentifier)
        #expect(decision.link.reviewedAt != nil)
    }

    /// A confirmation is a verdict on the pair, not a re-scoring of the evidence. A
    /// weak match a human accepts anyway must keep saying it was weak — rounding it to
    /// 100 because someone agreed would erase exactly the record worth keeping.
    @Test func confirmDoesNotInflateAWeakScore() throws {
        let (archive, person, _, ref) = try pair(
            given: "Marcus", surname: "Hanner", recorded: "Faye Sternfeld")

        let computed = try #require(archive.matchScore(of: ref, against: person.uid))
        #expect(computed.aggregateConfidence < 50)

        let decision = try archive.confirm(ref, as: person.uid, match: computed)
        #expect(decision.link.aggregateConfidence == computed.aggregateConfidence)
    }

    /// The CLI's shape: a caller holding only the pair gets the same record as one that
    /// scored it first.
    @Test func confirmScoresThePairWhenGivenNoMatch() throws {
        let (archive, person, _, ref) = try pair()

        let computed = try #require(archive.matchScore(of: ref, against: person.uid))
        let decision = try archive.confirm(ref, as: person.uid)

        #expect(decision.link.match == computed.breakdown)
        #expect(decision.link.aggregateConfidence == computed.aggregateConfidence)
    }

    @Test func confirmValidatesItsEndpoints() throws {
        let (archive, person, artifact, ref) = try pair()

        #expect(throws: ArchiveError.self) {
            try archive.confirm(
                MentionRef(artifact: ArtifactID("ART-nope"), localRef: "p1"), as: person.uid)
        }
        #expect(throws: ArchiveError.self) {
            try archive.confirm(ref, as: PersonID("PER-nope"))
        }
        #expect(throws: ArchiveError.self) {
            try archive.confirm(
                MentionRef(artifact: artifact.uid, localRef: "p99"), as: person.uid)
        }
    }

    // MARK: - Reject: the matcher's memory

    /// Without a tombstone, suggestions being ephemeral means declining one is
    /// forgotten and the identical pair is recomputed and re-offered forever.
    @Test func rejectStopsThePairBeingSuggestedAgain() throws {
        let (archive, person, artifact, ref) = try pair()

        #expect(archive.suggestLinks(for: person.uid).count == 1)

        let decision = try archive.reject(ref, as: person.uid)
        #expect(decision.link.reviewStatus == .humanRejected)

        #expect(archive.suggestLinks(for: person.uid).isEmpty)

        // The mention itself is *not* resolved — only a confirmation does that — so it
        // is still reported for triage, now with nobody left to suggest.
        let grouped = archive.suggestLinks(forArtifact: artifact.uid)
        #expect(grouped.count == 1)
        #expect(grouped.first?.candidates.isEmpty == true)
    }

    /// Rejecting is scoped to the pair. Saying "this deed's Marcus is not *this* Marcus"
    /// must leave every other candidate a live question.
    @Test func rejectForeclosesOnlyThatPair() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let otherMarcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))
        let ref = MentionRef(artifact: artifact.uid, localRef: "p1")

        try archive.reject(ref, as: marcus.uid)

        let grouped = archive.suggestLinks(forArtifact: artifact.uid)
        #expect(grouped.count == 1)
        #expect(grouped.first?.candidates.count == 1)
        #expect(grouped.first?.candidates.first?.personID == otherMarcus.uid)
    }

    /// A rejection of a *strong* match is the interesting one — it is where the matcher
    /// is wrong in a way worth understanding later — so the score is stored, not zeroed.
    @Test func rejectStoresTheComputedBreakdown() throws {
        let (archive, person, _, ref) = try pair()

        let computed = try #require(archive.matchScore(of: ref, against: person.uid))
        #expect(computed.aggregateConfidence > 50)

        let decision = try archive.reject(ref, as: person.uid)
        #expect(decision.link.match == computed.breakdown)
        #expect(decision.link.aggregateConfidence == computed.aggregateConfidence)
    }

    /// Un-rejecting is `unlink`, not a fourth verb: a tombstone *is* an `EvidenceLink`,
    /// so deleting it returns the pair to the queue.
    @Test func unlinkingATombstoneUnrejectsThePair() throws {
        let (archive, person, _, ref) = try pair()

        let decision = try archive.reject(ref, as: person.uid)
        #expect(archive.suggestLinks(for: person.uid).isEmpty)

        try archive.unlink(decision.link.uid)
        #expect(archive.suggestLinks(for: person.uid).count == 1)
    }

    /// The record has to survive a round trip through disk like every other record type
    /// (§ non-negotiables), tombstone or not.
    @Test func aTombstoneRoundTripsThroughDiskAndAnIndexRebuild() throws {
        let (archive, person, _, ref) = try pair()

        let written = try archive.reject(ref, as: person.uid, reviewedBy: .human("ada")).link
        try archive.rebuildIndex()

        let reloaded = try #require(archive.evidenceLink(withID: written.uid))
        #expect(reloaded == written)
        #expect(reloaded.reviewStatus == .humanRejected)
        #expect(reloaded.reviewedBy == "ada")
    }

    // MARK: - A decision supersedes a differently-decided one

    @Test func confirmingClearsAnEarlierRejectionOfTheSamePair() throws {
        let (archive, person, _, ref) = try pair()

        let rejection = try archive.reject(ref, as: person.uid).link
        let decision = try archive.confirm(ref, as: person.uid)

        #expect(decision.superseded.map(\.uid) == [rejection.uid])
        #expect(archive.evidenceLink(withID: rejection.uid) == nil)
        // And the survivor is the confirmation, not a contradictory pair of records.
        #expect(
            archive.links(for: person.uid, includeRejected: true).map(\.uid) == [
                decision.link.uid
            ])
    }

    @Test func rejectingClearsAnEarlierConfirmationOfTheSamePair() throws {
        let (archive, person, _, ref) = try pair()

        let confirmation = try archive.confirm(ref, as: person.uid).link
        let decision = try archive.reject(ref, as: person.uid)

        #expect(decision.superseded.map(\.uid) == [confirmation.uid])
        #expect(
            archive.links(for: person.uid, includeRejected: true).map(\.uid) == [
                decision.link.uid
            ])
        // The mention is unresolved again, so it returns to triage.
        #expect(archive.suggestLinks(for: person.uid).isEmpty)  // the pair is foreclosed…
        #expect(archive.links(for: person.uid).isEmpty)  // …and cites nothing.
    }

    /// The superseded records come back with the decision so the app's undo can restore
    /// them — an undo that only removed what was added would leave the archive missing
    /// whatever the decision cleared.
    @Test func supersededLinksAreReturnedSoAnUndoCanRestoreThem() throws {
        let (archive, person, _, ref) = try pair()

        let rejection = try archive.reject(ref, as: person.uid).link
        let decision = try archive.confirm(ref, as: person.uid)

        // Undo, the way `ArchiveModel` would: drop what was written, put back what went.
        try archive.unlink(decision.link.uid)
        for superseded in decision.superseded { try archive.restoreLink(superseded) }

        #expect(archive.evidenceLink(withID: rejection.uid) == rejection)
        #expect(archive.suggestLinks(for: person.uid).isEmpty)
    }

    /// **A pair holds one verdict, whatever the status.** An earlier version of this
    /// slice let same-status duplicates stand, on the reasoning that a repeat is
    /// redundant rather than contradictory. True of confirmations; false of rejections —
    /// each tombstone forecloses the pair independently, so removing one via the
    /// uid-addressed `unlink` would report success and change nothing the user can see.
    /// A `unreject` that silently does nothing is the trap this pins shut.
    @Test func rejectingTwiceLeavesOneTombstoneThatUnrejectingClears() throws {
        let (archive, person, _, ref) = try pair()

        let first = try archive.reject(ref, as: person.uid)
        let second = try archive.reject(ref, as: person.uid)

        #expect(second.superseded.map(\.uid) == [first.link.uid])
        #expect(archive.links(for: person.uid, includeRejected: true).count == 1)

        // One unreject is enough, because there is only ever one to remove.
        try archive.unlink(second.link.uid)
        #expect(archive.suggestLinks(for: person.uid).count == 1)
    }

    @Test func confirmingTwiceLeavesOneLink() throws {
        let (archive, person, _, ref) = try pair()

        let first = try archive.confirm(ref, as: person.uid)
        let second = try archive.confirm(ref, as: person.uid)

        #expect(second.superseded.map(\.uid) == [first.link.uid])
        #expect(archive.links(for: person.uid).map(\.uid) == [second.link.uid])
    }

    /// `link()` obeys the same rule. It is reachable from the inspector's resolve sheet
    /// and from `genea link`, so a pair rejected in the queue and then resolved by hand
    /// would otherwise keep both records — and unlinking the confirmation would leave
    /// the invisible tombstone foreclosing the pair for good.
    @Test func manualLinkAlsoSupersedesATombstone() throws {
        let (archive, person, _, ref) = try pair()

        let rejection = try archive.reject(ref, as: person.uid)
        let decision = try archive.link(ref, to: person.uid)

        #expect(decision.superseded.map(\.uid) == [rejection.link.uid])

        // And undoing the manual link returns the pair to the queue rather than
        // stranding it behind a tombstone nothing can see.
        try archive.unlink(decision.link.uid)
        #expect(archive.suggestLinks(for: person.uid).count == 1)
    }

    /// Superseding a link that a fact cited strands the citation, and the caller is told
    /// at the moment it happens — the convention every other removal path follows.
    @Test func supersessionReportsTheCitationsItStrands() throws {
        let (archive, person, _, ref) = try pair()

        let confirmation = try archive.confirm(ref, as: person.uid).link
        try archive.updatePerson(person.uid) { person in
            person.facts = [
                PersonFact(type: .birth, date: "1871", supportedByLinks: [confirmation.uid])
            ]
        }
        #expect(archive.findDanglingReferences().isEmpty)

        let decision = try archive.reject(ref, as: person.uid)

        #expect(
            decision.strandedCitations == [
                .personFactSupport(
                    person: person.uid, factIndex: 0, missingLink: confirmation.uid)
            ])
        // And the sweep agrees, so the two reports can't drift apart.
        #expect(archive.findDanglingReferences() == decision.strandedCitations)
    }

    /// The ordinary path pays for none of that: nothing displaced, nothing to scan.
    @Test func anUncontestedWriteReportsNoDisplacement() throws {
        let (archive, person, _, ref) = try pair()

        let decision = try archive.confirm(ref, as: person.uid)
        #expect(decision.superseded.isEmpty)
        #expect(decision.strandedCitations.isEmpty)
    }

    // MARK: - The audit: a rejection is invisible to every citation surface

    @Test func aRejectionIsNotAPersonsSource() throws {
        let (archive, person, _, ref) = try pair()

        try archive.reject(ref, as: person.uid)

        #expect(archive.links(for: person.uid).isEmpty)
        #expect(archive.links(for: person.uid, includeRejected: true).count == 1)
    }

    @Test func aRejectionIsNotAnArtifactsResolvedMention() throws {
        let (archive, person, artifact, ref) = try pair()

        try archive.reject(ref, as: person.uid)

        #expect(archive.links(forArtifact: artifact.uid).isEmpty)
        #expect(archive.links(forArtifact: artifact.uid, includeRejected: true).count == 1)
    }

    /// The one that would read most wrongly: a record the user said does *not* name
    /// this person, answering the question "what mentions this person?"
    @Test func aRejectionDoesNotMakeAnArtifactMentionThePerson() throws {
        let (archive, person, _, ref) = try pair()

        try archive.reject(ref, as: person.uid)
        #expect(archive.artifacts(mentioning: person.uid).isEmpty)

        // And confirming the same pair does put it back.
        try archive.confirm(ref, as: person.uid)
        #expect(archive.artifacts(mentioning: person.uid).count == 1)
    }

    /// The archive-wide accessor (slice 45i) is a *third* citation surface, so it gets the
    /// same audit as the two filtered ones: a tombstone must not ride out on it. It exists
    /// only to spare a whole-corpus consumer from decoding the link table once per person,
    /// which is no reason to make it the one reader that resurrects rejections.
    @Test func theArchiveWideAccessorHidesRejectionsToo() throws {
        let (archive, person, _, ref) = try pair()
        let other = try archive.addPerson(.sample(given: "Szlama", surname: "Feldberg"))
        let second = try archive.addArtifact(.sample(personsMentioned: [mention("p1", "Szlama")]))
        let secondRef = MentionRef(artifact: second.uid, localRef: "p1")

        try archive.confirm(secondRef, as: other.uid)
        try archive.reject(ref, as: person.uid)

        let cited = archive.links()
        #expect(cited.count == 1)
        #expect(cited.first?.personUid == other.uid)
        #expect(archive.links(includeRejected: true).count == 2)
    }

    /// It must agree with the per-person view it replaces — that equivalence is the
    /// whole licence for a cross-person sweep to call this once instead of `links(for:)`
    /// per person, and its order must be stable for the same reason the siblings' is.
    @Test func theArchiveWideAccessorAgreesWithThePerPersonOne() throws {
        let (archive, person, _, ref) = try pair()
        let other = try archive.addPerson(.sample(given: "Szlama", surname: "Feldberg"))
        let second = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama"), mention("p2", "Marcus Hanner")]))

        try archive.confirm(ref, as: person.uid)
        try archive.confirm(MentionRef(artifact: second.uid, localRef: "p1"), as: other.uid)
        try archive.confirm(MentionRef(artifact: second.uid, localRef: "p2"), as: person.uid)

        let all = archive.links()
        #expect(all.count == 3)
        #expect(all.map(\.uid.raw) == all.map(\.uid.raw).sorted())
        for subject in [person.uid, other.uid] {
            #expect(all.filter { $0.personUid == subject } == archive.links(for: subject))
        }
    }

    /// `evidenceLink(withID:)` is deliberately *not* filtered — refusing to return a
    /// record whose uid the caller already holds would read as corruption, and
    /// un-rejecting needs to read the thing it is about to delete.
    @Test func aTombstoneIsStillReadableByItsOwnID() throws {
        let (archive, person, _, ref) = try pair()

        let decision = try archive.reject(ref, as: person.uid)
        #expect(archive.evidenceLink(withID: decision.link.uid) != nil)
    }

    /// The deliberate exception (fork settled with the user): the integrity sweep audits
    /// tombstones like any other record. Excluding them would create a class of garbage
    /// invisible to every query *and* to the sweep whose job is finding what queries
    /// hide.
    @Test func theDanglingSweepStillSeesTombstones() throws {
        let (archive, person, _, ref) = try pair()

        let decision = try archive.reject(ref, as: person.uid)
        #expect(archive.findDanglingReferences().isEmpty)

        _ = try archive.removePerson(person.uid)

        let dangling = archive.findDanglingReferences()
        #expect(
            dangling.contains(
                .linkPerson(link: decision.link.uid, missingPerson: person.uid)))
    }

    // MARK: - The unresolved-mention shape

    /// The case a flat list of scored pairs cannot express, and the reason the artifact
    /// direction is grouped: a name the archive has never seen scores against nobody, so
    /// it used to vanish from the results entirely — indistinguishable from a record
    /// with no mentions and from one whose mentions are all resolved.
    @Test func aMentionThatMatchedNothingIsStillReported() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        _ = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Berek Sternfeld")]))

        let grouped = archive.suggestLinks(forArtifact: artifact.uid)

        #expect(grouped.count == 1)
        #expect(grouped.first?.mention == MentionRef(artifact: artifact.uid, localRef: "p1"))
        #expect(grouped.first?.candidates.isEmpty == true)
    }

    /// The three situations the grouped shape has to keep apart.
    @Test func theThreeEmptyCasesAreDistinguishable() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let person = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))

        // 1. A record naming nobody: no entries at all.
        let bare = try archive.addArtifact(.sample(personsMentioned: []))
        #expect(archive.suggestLinks(forArtifact: bare.uid).isEmpty)

        // 2. Every mention resolved: also no entries — there is nothing to triage.
        let resolved = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Marcus Hanner")]))
        try archive.confirm(
            MentionRef(artifact: resolved.uid, localRef: "p1"), as: person.uid)
        #expect(archive.suggestLinks(forArtifact: resolved.uid).isEmpty)

        // 3. An unresolved mention nothing matched: one entry, no candidates. The
        //    somebody-new case, and the only one of the three with work attached.
        let unknown = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Berek Sternfeld")]))
        let grouped = archive.suggestLinks(forArtifact: unknown.uid)
        #expect(grouped.count == 1)
        #expect(grouped.first?.candidates.isEmpty == true)
    }

    /// An empty candidate list is not evidence that the person is new — the matcher's
    /// blind spot is precisely the name it cannot recognize. A caller offering "create
    /// new" is expected to show what a zero floor turns up beside it, so a zero floor
    /// has to actually turn something up.
    @Test func aZeroFloorRevealsWhatTheDefaultThresholdHid() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let person = try archive.addPerson(.sample(given: "Sidney", surname: "Feldberg"))
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Zelig Feldberg")]))

        let atDefault = archive.suggestLinks(forArtifact: artifact.uid)
        #expect(atDefault.first?.candidates.isEmpty == true)

        let atZero = archive.suggestLinks(forArtifact: artifact.uid, minimumConfidence: 0)
        #expect(atZero.first?.candidates.first?.personID == person.uid)
    }

    /// The limit applies per mention now, not across the artifact — a queue that showed
    /// three candidates for the first name and none for the rest would be useless.
    @Test func theLimitIsPerMention() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        for _ in 0..<3 {
            _ = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        }
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [
                mention("p1", "Marcus Hanner"), mention("p2", "Marcus Hanner"),
            ]))

        let grouped = archive.suggestLinks(forArtifact: artifact.uid, limit: 2)

        #expect(grouped.count == 2)
        #expect(grouped.allSatisfy { $0.candidates.count == 2 })
    }

    // MARK: - Suggestions stay ephemeral

    /// The mini-phase's founding rule, pinned where it could most easily erode: asking
    /// for suggestions must not write one.
    @Test func suggestingWritesNothing() throws {
        let (archive, person, artifact, _) = try pair()

        _ = archive.suggestLinks(for: person.uid)
        _ = archive.suggestLinks(forArtifact: artifact.uid)

        #expect(archive.links(for: person.uid, includeRejected: true).isEmpty)
    }
}

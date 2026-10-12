import Foundation
import GeneaLogicArchive
import GeneaLogicMatch
import GeneaLogicModel
import Testing

/// What the `place` projection changes about scoring — slice 45o, end to end.
///
/// `PlaceVocabularyTests` proves the rule and `PlaceProjectionTests` the plumbing;
/// these prove the thing the slice was written for: that a bare-town archive gains the
/// corroboration 45n could not give it, that a bare *country* still does not, and — the
/// tripwire — that an archive whose places are all fully qualified scores exactly as it
/// did before any of this existed.
///
/// Everything here goes through the public surface, because "the score a user sees
/// changes" is the claim, and reaching into the vocabulary to assert it would prove
/// something weaker.
@Suite struct PlaceVocabularyProjectionTests {

    // MARK: - Fixtures

    @discardableResult
    private func addPerson(
        _ name: String, birthPlace: String? = nil, in archive: Archive
    ) throws -> Person {
        let person = try archive.addPerson(
            PersonDraft(
                names: [PersonName.deriving(type: .birth, given: nil, surname: nil, full: name)]))
        guard let birthPlace else { return person }
        return try archive.updatePerson(person.uid) {
            $0.facts.append(PersonFact(type: .birth, place: birthPlace))
        }
    }

    private func mention(
        _ localRef: String, _ name: String, birthPlace: String? = nil
    ) -> PersonMention {
        PersonMention(
            localRef: localRef,
            nameAsRecorded: name,
            role: .subject,
            informationQuality: .primary,
            facts: birthPlace.map { [RecordedFact(type: .birth, place: $0)] } ?? [])
    }

    /// The score of the one suggestion these single-pair archives produce.
    private func onlySuggestion(in archive: Archive, for person: PersonID) throws -> ScoredMatch {
        try #require(archive.suggestLinks(for: person, minimumConfidence: 0).first?.match)
    }

    // MARK: - What the vocabulary buys

    /// **The slice, end to end.** A mention and a person both recording a bare `Rypin`
    /// agree at an unmeasurable depth — until some *other* record in the archive writes
    /// `Rypin, Poland`, at which point the same two records corroborate. Nothing about
    /// the pair changed; what changed is what the archive can prove about the word.
    @Test func aBareTownCorroboratesOnceTheArchiveQualifiesItElsewhere() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try addPerson("Szlama Feldberg", birthPlace: "Rypin", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Rypin")]))

        let before = try onlySuggestion(in: archive, for: person.uid)
        #expect(before.breakdown.birthPlace?.granularity == .unqualified)
        #expect(before.breakdown.birthPlace?.score == 50)

        // An unrelated person who happens to write the town out in full.
        try addPerson("Fay Hanner", birthPlace: "Rypin, Poland", in: archive)

        let after = try onlySuggestion(in: archive, for: person.uid)
        #expect(after.breakdown.birthPlace?.granularity == .specific)
        #expect(after.breakdown.birthPlace?.score == 80)
        #expect(after.aggregateConfidence > before.aggregateConfidence)
    }

    /// The evidence may come from any record type — here a *document's* transcription,
    /// proving a town for a pair of *conclusions*. This is the half of the corpus a
    /// conclusions-only vocabulary would have thrown away.
    @Test func aDocumentsPlaceStringProvesATownForConcludedPersons() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        try addPerson("Szlama Feldberg", birthPlace: "Sochaczew", in: archive)
        try addPerson("Szlama Feldberg", birthPlace: "Sochaczew", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Fay Hanner", birthPlace: "Sochaczew, Poland")]
            ))

        let candidate = try #require(archive.duplicateCandidates(minimumConfidence: 0).first)

        #expect(candidate.match.breakdown.birthPlace?.granularity == .specific)
    }

    // MARK: - What it must not touch

    /// **The tripwire.** An archive whose places are all fully qualified scores
    /// identically to the same comparison made with nothing proved. If this fails, 45o
    /// has reached a branch it has no business in.
    @Test func aFullyQualifiedArchiveScoresAsItAlwaysDid() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try addPerson("Szlama Feldberg", birthPlace: "Rypin, Poland", in: archive)
        try archive.addArtifact(
            .sample(
                personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Rypin, Russia")]))

        let scored = try onlySuggestion(in: archive, for: person.uid)

        // The pre-45o answer for this pair: no vocabulary, same two strings.
        #expect(
            scored.breakdown.birthPlace
                == PlaceMatching.score(recorded: "Rypin, Russia", concluded: "Rypin, Poland"))
    }

    /// The real archive's own shape in miniature — bare countries beside qualified
    /// towns. `Poland` must not be promoted by the towns sitting on top of it, which is
    /// the failure that would hand every `Poland`/`Poland` coincidence the full
    /// corroborating weight slice 45n removed.
    @Test func bareCountriesAreNotPromotedByTheTownsAboveThem() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        try addPerson("Fay Hanner", birthPlace: "Rypin, Poland", in: archive)
        let person = try addPerson("Szlama Feldberg", birthPlace: "Poland", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Poland")]))

        let scored = try onlySuggestion(in: archive, for: person.uid)

        #expect(scored.breakdown.birthPlace?.granularity == .unqualified)
        #expect(scored.breakdown.birthPlace?.score == 50)
    }

    // MARK: - The same answer everywhere

    /// **The explain path must agree with the queue.** `matchScore` builds its own
    /// corpus, and it deliberately reads one artifact where the queue reads all of them
    /// — so a vocabulary gathered from the records rather than from the index would
    /// diverge exactly here, and report a different number than the row it explains.
    @Test func theExplainPathScoresAPairAsTheQueueDid() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try addPerson("Szlama Feldberg", birthPlace: "Rypin", in: archive)
        try addPerson("Fay Hanner", birthPlace: "Rypin, Poland", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Rypin")]))

        let suggestion = try #require(
            archive.suggestLinks(for: person.uid, minimumConfidence: 0).first)
        let explained = archive.matchScore(of: suggestion.mention, against: person.uid)

        #expect(explained == suggestion.match)
        #expect(explained?.breakdown.birthPlace?.granularity == .specific)
    }

    /// And a confirmation stores that same number. `confirm(match: nil)` recomputes, so
    /// a corpus built differently there would write a breakdown the user never saw.
    @Test func aRecomputedConfirmationStoresTheScoreTheQueueShowed() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try addPerson("Szlama Feldberg", birthPlace: "Rypin", in: archive)
        try addPerson("Fay Hanner", birthPlace: "Rypin, Poland", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Rypin")]))

        let suggestion = try #require(
            archive.suggestLinks(for: person.uid, minimumConfidence: 0).first)
        let decision = try archive.confirm(suggestion.mention, as: person.uid)

        #expect(decision.link.match.birthPlace == suggestion.match.breakdown.birthPlace)
        #expect(decision.link.aggregateConfidence == suggestion.match.aggregateConfidence)
    }

    /// A rebuild regenerates the projection, so the score survives one unchanged — the
    /// index is a cache, and a cache that changes an answer is not one.
    @Test func aRebuildDoesNotChangeTheScore() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())

        let person = try addPerson("Szlama Feldberg", birthPlace: "Rypin", in: archive)
        try addPerson("Fay Hanner", birthPlace: "Rypin, Poland", in: archive)
        try archive.addArtifact(
            .sample(personsMentioned: [mention("p1", "Szlama Feldberg", birthPlace: "Rypin")]))

        let before = try onlySuggestion(in: archive, for: person.uid)
        try archive.rebuildIndex()
        let after = try onlySuggestion(in: archive, for: person.uid)

        #expect(before == after)
        #expect(after.breakdown.birthPlace?.granularity == .specific)
    }
}

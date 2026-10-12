import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicArchive

/// The index's `place` table — slice 45o's projection, at its own layer.
///
/// The matcher can only prove a bare `Rypin` is a town if the archive's *other* place
/// strings reach it, so a field this projection misses is evidence the matcher silently
/// doesn't have. These tests are at the index rather than through `Archive` because
/// that is where the omission would live.
@Suite struct PlaceProjectionTests {

    // MARK: - Extraction

    /// Every place-bearing field of an artifact: its own locations, the places its
    /// events name, and the places recorded against each person it mentions.
    @Test func anArtifactContributesLocationsEventsAndMentionFacts() {
        let artifact = Artifact(
            uid: "ART-018f3c9a-7b2e-7c41-9e3a-000000000001",
            title: "Marriage register",
            mediaType: .image,
            sourceAuthorityTier: .vital,
            events: [Event(type: "marriage", location: "Sochaczew, Poland")],
            personsMentioned: [
                PersonMention(
                    localRef: "p1",
                    nameAsRecorded: "Szlama Feldberg",
                    role: .spouse,
                    informationQuality: .primary,
                    facts: [RecordedFact(type: .birth, place: "Rypin, Poland")])
            ],
            locations: [Location(asRecorded: "Brooklyn, NY")],
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-01T00:00:00Z", reviewStatus: .asserted))

        #expect(
            Set(ArchiveIndex.places(in: artifact))
                == ["Sochaczew, Poland", "Rypin, Poland", "Brooklyn, NY"])
    }

    /// A person contributes every fact's place, not only a birth's — a death or a
    /// residence proves a town just as well.
    @Test func aPersonContributesEveryFactsPlace() {
        var person = Person(
            uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000002",
            names: [],
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-01T00:00:00Z", reviewStatus: .asserted))
        person.facts = [
            PersonFact(type: .birth, place: "Rypin, Poland"),
            PersonFact(type: .death, place: "Brooklyn, NY, USA"),
            PersonFact(type: .occupation, value: "tailor"),
        ]

        #expect(Set(ArchiveIndex.places(in: person)) == ["Rypin, Poland", "Brooklyn, NY, USA"])
    }

    /// A marriage place is a statement about how this archive names places, and nothing
    /// else reads it.
    @Test func aRelationshipContributesItsFactsPlaces() {
        var relationship = Relationship(
            uid: "REL-018f3c9a-7b2e-7c41-9e3a-000000000003",
            type: .couple,
            person1Uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000001",
            person2Uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000002",
            reviewStatus: .asserted,
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-01T00:00:00Z", reviewStatus: .asserted))
        relationship.facts = [PersonFact(type: .marriage, place: "Sochaczew, Poland")]

        #expect(ArchiveIndex.places(in: relationship) == ["Sochaczew, Poland"])
    }

    /// An empty string is not a place. It would survive as a vocabulary entry that
    /// matches nothing, which is harmless but dishonest about what the archive holds.
    @Test func emptyPlacesAreNotProjected() {
        var person = Person(
            uid: "PER-018f3c9a-7b2e-7c41-9e3a-000000000002",
            names: [],
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-01T00:00:00Z", reviewStatus: .asserted))
        person.facts = [PersonFact(type: .birth, place: ""), PersonFact(type: .death)]

        #expect(ArchiveIndex.places(in: person).isEmpty)
    }

    // MARK: - Storage

    private func makeIndex() throws -> ArchiveIndex {
        let url = TestSupport.makeTempDirectory().appendingPathComponent("index.sqlite")
        return try ArchiveIndex.open(at: url)
    }

    private func person(
        _ uid: PersonID, place: String?
    ) -> Person {
        var person = Person(
            uid: uid, names: [],
            provenance: Provenance(
                createdBy: .human, createdAt: "2026-08-01T00:00:00Z", reviewStatus: .asserted))
        if let place { person.facts = [PersonFact(type: .birth, place: place)] }
        return person
    }

    @Test func upsertStoresPlacesAndRemoveTakesThemAway() throws {
        let index = try makeIndex()
        let uid: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000002"

        try index.upsert(person(uid, place: "Rypin, Poland"))
        #expect(try index.allPlaceStrings() == ["Rypin, Poland"])

        try index.removePerson(uid)
        #expect(try index.allPlaceStrings().isEmpty)
    }

    /// Replaced wholesale, not accumulated — an edited birth place must not leave the
    /// old one behind as permanent evidence.
    @Test func upsertReplacesARecordsPlaces() throws {
        let index = try makeIndex()
        let uid: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000002"

        try index.upsert(person(uid, place: "Rypin, Poland"))
        try index.upsert(person(uid, place: "Sochaczew, Poland"))

        #expect(try index.allPlaceStrings() == ["Sochaczew, Poland"])
    }

    /// One record's places are its own: removing it must not disturb another's.
    @Test func removingOneRecordLeavesTheOthersPlaces() throws {
        let index = try makeIndex()
        let first: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000001"
        let second: PersonID = "PER-018f3c9a-7b2e-7c41-9e3a-000000000002"

        try index.upsert(person(first, place: "Rypin, Poland"))
        try index.upsert(person(second, place: "Sochaczew, Poland"))
        try index.removePerson(first)

        #expect(try index.allPlaceStrings() == ["Sochaczew, Poland"])
    }

    /// Distinct: two people born in the same town is one vocabulary entry, and the
    /// query says so rather than making the match layer deduplicate.
    @Test func repeatedPlacesAreReturnedOnce() throws {
        let index = try makeIndex()

        try index.upsert(
            person("PER-018f3c9a-7b2e-7c41-9e3a-000000000001", place: "Rypin, Poland"))
        try index.upsert(
            person("PER-018f3c9a-7b2e-7c41-9e3a-000000000002", place: "Rypin, Poland"))

        #expect(try index.allPlaceStrings() == ["Rypin, Poland"])
    }
}

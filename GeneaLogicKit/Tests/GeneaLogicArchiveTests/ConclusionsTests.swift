import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// `addPerson`/`addRelationship`/`link` (ARCHITECTURE.md §4.3, §4.4, §4.5, §6.3).
@Suite struct ConclusionsTests {

    @Test func addPersonWritesSidecarAndIsLookupable() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let person = try archive.addPerson(.sample(given: "Jane", surname: "Doe"))

        #expect(person.uid.raw.hasPrefix("PER-"))
        #expect(person.names.first?.full == "Jane Doe")

        let url = root.appendingPathComponent("conclusions/persons/\(person.uid.raw).json")
        #expect(FileManager.default.fileExists(atPath: url.path))

        #expect(archive.person(withID: person.uid)?.uid == person.uid)
    }

    @Test func addPersonHonorsExplicitNamesOverFlatGivenSurname() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let draft = PersonDraft(
            given: "Ignored",
            surname: "AlsoIgnored",
            names: [
                PersonName(type: .birth, given: "Janet", surname: "Smythe", full: "Janet Smythe")
            ]
        )
        let person = try archive.addPerson(draft)

        #expect(person.names.count == 1)
        #expect(person.names[0].given == "Janet")
        #expect(person.names[0].surname == "Smythe")
    }

    @Test func addRelationshipLinksTwoExistingPersons() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let parent = try archive.addPerson(.sample(given: "Mary", surname: "Smith"))
        let child = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: parent.uid, person2Uid: child.uid))

        #expect(relationship.uid.raw.hasPrefix("REL-"))
        #expect(relationship.person1Uid == parent.uid)
        #expect(relationship.person2Uid == child.uid)

        let url = root.appendingPathComponent(
            "conclusions/relationships/\(relationship.uid.raw).json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func addRelationshipThrowsWhenEitherPersonIsMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let realPerson = try archive.addPerson(.sample())
        let bogus = PersonID("PER-does-not-exist")

        #expect(throws: ArchiveError.personNotFound(bogus)) {
            try archive.addRelationship(
                RelationshipDraft(type: .couple, person1Uid: realPerson.uid, person2Uid: bogus))
        }
        #expect(throws: ArchiveError.personNotFound(bogus)) {
            try archive.addRelationship(
                RelationshipDraft(type: .couple, person1Uid: bogus, person2Uid: realPerson.uid))
        }
    }

    @Test func linkCreatesEvidenceLinkWithHonestManualConfirmationShape() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "John Smith", role: .subject,
            informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let person = try archive.addPerson(.sample(given: "John", surname: "Smith"))

        let evidenceLink = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"),
            to: person.uid,
            reviewedBy: .human("researcher@example.com")
        ).link

        #expect(evidenceLink.uid.raw.hasPrefix("LNK-"))
        #expect(evidenceLink.artifactUid == artifact.uid)
        #expect(evidenceLink.personMentionRef == "p1")
        #expect(evidenceLink.personUid == person.uid)

        // Judgment call under test: a manual confirmation is honestly
        // represented — `.humanConfirmed`, full confidence, an `.exact`/`1.0`
        // name dimension (the only thing actually "scored": a human looked at
        // it), and every *computed* matcher dimension left `nil` (not faked).
        #expect(evidenceLink.reviewStatus == .humanConfirmed)
        #expect(evidenceLink.reviewedBy == "researcher@example.com")
        #expect(evidenceLink.reviewedAt != nil)
        #expect(evidenceLink.aggregateConfidence == 100)
        #expect(evidenceLink.match.name.kind == .exact)
        #expect(evidenceLink.match.name.score == 100)
        #expect(evidenceLink.match.birthYear == nil)
        #expect(evidenceLink.match.birthPlace == nil)
        #expect(evidenceLink.match.spouseName == nil)
        #expect(evidenceLink.match.parents == nil)
        #expect(evidenceLink.match.nameAlgo == nil)
        #expect(evidenceLink.match.conflicts.isEmpty)

        let url = root.appendingPathComponent("conclusions/links/\(evidenceLink.uid.raw).json")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func linkWithUnspecifiedReviewerLeavesReviewedByNil() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Jane Doe", role: .subject,
            informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let person = try archive.addPerson(.sample(given: "Jane", surname: "Doe"))

        let evidenceLink = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"), to: person.uid
        ).link

        #expect(evidenceLink.reviewedBy == nil)
    }

    @Test func linkThrowsWhenArtifactIsMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())
        let bogusArtifact = ArtifactID("ART-does-not-exist")

        #expect(throws: ArchiveError.artifactNotFound(bogusArtifact)) {
            try archive.link(
                MentionRef(artifact: bogusArtifact, localRef: "p1"), to: person.uid)
        }
    }

    @Test func linkThrowsWhenPersonIsMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Someone", role: .subject,
            informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let bogusPerson = PersonID("PER-does-not-exist")

        #expect(throws: ArchiveError.personNotFound(bogusPerson)) {
            try archive.link(
                MentionRef(artifact: artifact.uid, localRef: "p1"), to: bogusPerson)
        }
    }

    @Test func linkThrowsWhenLocalRefDoesNotExistOnArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Someone", role: .subject,
            informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let person = try archive.addPerson(.sample())

        #expect(throws: ArchiveError.mentionNotFound("p99", on: artifact.uid)) {
            try archive.link(
                MentionRef(artifact: artifact.uid, localRef: "p99"), to: person.uid)
        }
    }

    // MARK: - Slice 49: conclusions writes are covered by the manifest

    /// The reverse of the Phase 1a rule this test used to pin ("conclusions
    /// writes change neither `files` nor `updatedAt`"). Every conclusion record
    /// now carries a manifest entry, because it is hand-authored data that
    /// nothing else can re-derive — and `updatedAt` moves with `files`, since the
    /// manifest genuinely changed.
    @Test func conclusionsWritesAreCoveredByTheManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let manifestURL = root.appendingPathComponent("manifest.json")
        let before = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))

        let person = try archive.addPerson(.sample())
        let spouse = try archive.addPerson(.sample(given: "Spouse"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: person.uid, person2Uid: spouse.uid))

        let after = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))

        // `updatedAt` has second granularity, so a test this fast can't assert on
        // its *value* — `files` is the claim, and `commitManifest` is what ties
        // the timestamp to it (pinned in `ManifestCoverageTests`).
        #expect(after.files != before.files)
        for path in [
            "conclusions/persons/\(person.uid.raw).json",
            "conclusions/persons/\(spouse.uid.raw).json",
            "conclusions/relationships/\(relationship.uid.raw).json",
        ] {
            let entry = after.files.first { $0.path == path }
            #expect(entry != nil, "\(path) should be in the manifest")
            let onDisk = try Data(contentsOf: root.appendingPathComponent(path))
            #expect(entry?.byteLength == Int64(onDisk.count))
        }
    }
}

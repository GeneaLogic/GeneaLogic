import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 44e — `findDanglingReferences()`, the referential sweep over the
/// conclusion records. Every finding here is the *deliberate* residue of a §2.3
/// no-cascade removal, so each test removes something the real UI can remove and
/// asserts the pointer it left behind is found.
@Suite struct DanglingReferenceTests {

    /// Builds an artifact with one mention, a person, and the link between them —
    /// the smallest complete evidence→conclusion chain, which every case below
    /// breaks in a different place.
    private func makeLinkedArchive(at root: URL) throws -> (
        archive: Archive, artifact: Artifact, person: Person, link: EvidenceLink
    ) {
        let archive = try Archive.create(at: root)
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject, informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [mention]))
        let person = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let link = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p1"), to: person.uid
        ).link
        return (archive, artifact, person, link)
    }

    @Test func intactArchiveHasNoDanglingReferences() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, artifact, person, _) = try makeLinkedArchive(at: root)
        _ = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: person.uid, person2Uid: person.uid))
        _ = artifact

        #expect(archive.findDanglingReferences().isEmpty)
    }

    @Test func removingAPersonDanglesItsLinkAndRelationships() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, _, person, link) = try makeLinkedArchive(at: root)
        let other = try archive.addPerson(.sample(given: "Bob"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: person.uid, person2Uid: other.uid))

        _ = try archive.removePerson(person.uid)

        let found = archive.findDanglingReferences()
        #expect(found.contains(.linkPerson(link: link.uid, missingPerson: person.uid)))
        #expect(
            found.contains(
                .relationshipEndpoint(relationship: relationship.uid, missingPerson: person.uid)))
        // The surviving endpoint is not reported.
        #expect(
            !found.contains(
                .relationshipEndpoint(relationship: relationship.uid, missingPerson: other.uid)))
    }

    @Test func removingAnArtifactDanglesItsLinkWithoutAlsoReportingTheMention() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, artifact, _, link) = try makeLinkedArchive(at: root)

        _ = try archive.removeArtifact(artifact.uid)

        let found = archive.findDanglingReferences()
        #expect(found == [.linkArtifact(link: link.uid, missingArtifact: artifact.uid)])
    }

    @Test func removingAMentionDanglesTheLinksRef() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, artifact, _, link) = try makeLinkedArchive(at: root)

        // The artifact survives; only the mention the link cites is removed —
        // exactly what the inspector's per-mention trash does.
        _ = try archive.updateMetadata(of: artifact.uid) { $0.personsMentioned = [] }

        let found = archive.findDanglingReferences()
        #expect(
            found == [.linkMention(link: link.uid, artifact: artifact.uid, missingRef: "p1")])
    }

    @Test func unlinkingDanglesEveryCitationOfThatLink() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, _, person, link) = try makeLinkedArchive(at: root)
        let other = try archive.addPerson(.sample(given: "Bob"))

        // The three places a link uid is cited: a person fact, a relationship's
        // own `supportedByLinks`, and a fact on that relationship (§4.5).
        _ = try archive.updatePerson(person.uid) {
            $0.facts = [PersonFact(type: .birth, date: "1900", supportedByLinks: [link.uid])]
        }
        let relationship = try archive.addRelationship(
            RelationshipDraft(
                type: .couple, person1Uid: person.uid, person2Uid: other.uid,
                facts: [PersonFact(type: .marriage, date: "1925", supportedByLinks: [link.uid])],
                supportedByLinks: [link.uid]))

        _ = try archive.unlink(link.uid)

        // Asserted as the whole array, not three `contains`: that also pins the
        // documented order (relationships before persons, fields in record
        // order) and catches a regression that reports something *extra*.
        #expect(
            archive.findDanglingReferences() == [
                .relationshipSupport(relationship: relationship.uid, missingLink: link.uid),
                .relationshipFactSupport(
                    relationship: relationship.uid, factIndex: 0, missingLink: link.uid),
                .personFactSupport(person: person.uid, factIndex: 0, missingLink: link.uid),
            ])
    }

    /// The order is part of the contract (the panel lists findings in it), and
    /// the underlying `SELECT`s carry no `ORDER BY` — so without this, dropping
    /// the sweep's `sorted(by:)` calls breaks nothing that any other test sees.
    @Test func findingsAreOrderedByKindThenUID() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, artifact, person, link) = try makeLinkedArchive(at: root)

        // A second link + person, minted after the first, so uid order is known.
        _ = try archive.updateMetadata(of: artifact.uid) {
            $0.personsMentioned.append(
                PersonMention(
                    localRef: "p2", nameAsRecorded: "Bob Roe", role: .witness,
                    informationQuality: .secondary))
        }
        let bob = try archive.addPerson(.sample(given: "Bob", surname: "Roe"))
        let secondLink = try archive.link(
            MentionRef(artifact: artifact.uid, localRef: "p2"), to: bob.uid
        ).link
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: person.uid, person2Uid: bob.uid))

        _ = try archive.removePerson(person.uid)
        _ = try archive.removePerson(bob.uid)

        #expect(
            archive.findDanglingReferences() == [
                // Links first, in uid (creation) order…
                .linkPerson(link: link.uid, missingPerson: person.uid),
                .linkPerson(link: secondLink.uid, missingPerson: bob.uid),
                // …then relationships, endpoints in field order.
                .relationshipEndpoint(relationship: relationship.uid, missingPerson: person.uid),
                .relationshipEndpoint(relationship: relationship.uid, missingPerson: bob.uid),
            ])
    }

    @Test func restoringTheRemovedRecordClearsTheDangle() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, _, person, _) = try makeLinkedArchive(at: root)

        let removed = try archive.removePerson(person.uid)
        #expect(!archive.findDanglingReferences().isEmpty)

        try archive.restorePerson(removed)
        #expect(archive.findDanglingReferences().isEmpty)
    }

    @Test func findingsSurviveAnIndexRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, artifact, _, _) = try makeLinkedArchive(at: root)
        _ = try archive.removeArtifact(artifact.uid)

        let before = archive.findDanglingReferences()
        #expect(!before.isEmpty)  // else the comparison below is vacuous
        try archive.rebuildIndex()
        // The sweep reads records, not a cached verdict — a rebuild changes nothing.
        #expect(archive.findDanglingReferences() == before)
    }

    // MARK: - Stated mention relationships (slice 45k)

    /// The evidence layer's own dangle. Removing a mention doesn't cascade, so the
    /// record goes on stating that somebody who is no longer on it is p1's parent —
    /// findable in one pass rather than only by reading the JSON.
    @Test func removingAMentionDanglesTheEdgeThatNamedIt() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let child = PersonMention(
            localRef: "p1", nameAsRecorded: "Sidney Feldberg", role: .subject,
            informationQuality: .primary)
        let parent = PersonMention(
            localRef: "p2", nameAsRecorded: "Marcus Feldberg", role: .parent,
            informationQuality: .secondary)
        var artifact = try archive.addArtifact(
            .sample(personsMentioned: [child, parent]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1")
            ]
        }
        #expect(archive.findDanglingReferences().isEmpty)

        try archive.updateMetadata(of: artifact.uid) {
            $0.personsMentioned.removeAll { $0.localRef == "p2" }
        }
        artifact = try #require(archive.artifact(withID: artifact.uid))

        #expect(
            archive.findDanglingReferences() == [
                .mentionRelationshipEndpoint(
                    artifact: artifact.uid, edgeIndex: 0, missingRef: "p2")
            ])
    }

    /// Both ends are reported when both are gone, and the surviving end never is —
    /// the same shape as a relationship's endpoints.
    @Test func bothMissingEndpointsOfAStatedEdgeAreReported() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(
            .sample(personsMentioned: [
                PersonMention(
                    localRef: "p3", nameAsRecorded: "Witness", role: .witness,
                    informationQuality: .undetermined)
            ]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .couple, person1Ref: "p1", person2Ref: "p2"),
                MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p9"),
            ]
        }

        #expect(
            archive.findDanglingReferences() == [
                // Edge 0 has lost both ends; edge 1 keeps p3, so only p9 is reported.
                .mentionRelationshipEndpoint(
                    artifact: artifact.uid, edgeIndex: 0, missingRef: "p1"),
                .mentionRelationshipEndpoint(
                    artifact: artifact.uid, edgeIndex: 0, missingRef: "p2"),
                .mentionRelationshipEndpoint(
                    artifact: artifact.uid, edgeIndex: 1, missingRef: "p9"),
            ])
    }

    @Test func aSelfRelationshipWithAMissingPersonIsReportedOnce() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Solo"))
        // Both endpoints name the same person, so both break at once — the
        // finding is one broken pointer, not two identical rows.
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: person.uid, person2Uid: person.uid))
        _ = try archive.removePerson(person.uid)

        #expect(
            archive.findDanglingReferences() == [
                .relationshipEndpoint(relationship: relationship.uid, missingPerson: person.uid)
            ])
    }
}

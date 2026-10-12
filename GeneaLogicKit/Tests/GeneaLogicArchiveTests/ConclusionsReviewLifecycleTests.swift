import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Slice 40 — the conclusions read accessors (`relationships(of:)`, `links(for:)`,
/// `links(forArtifact:)`) and the review-lifecycle mutations (`updatePerson`,
/// `removePerson`/`restorePerson`, `removeRelationship`/`restoreRelationship`,
/// `unlink`/`restoreLink`). Reversible in-session, no trash, no cascade (§2.3).
@Suite struct ConclusionsReviewLifecycleTests {

    // MARK: - Read accessors

    @Test func relationshipsOfReturnsBothEndpointsAndAllListsEverything() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let a = try archive.addPerson(.sample(given: "Ann"))
        let b = try archive.addPerson(.sample(given: "Bob"))
        let c = try archive.addPerson(.sample(given: "Cal"))

        let ab = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: a.uid, person2Uid: b.uid))
        let bc = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: b.uid, person2Uid: c.uid))

        #expect(Set(archive.relationships().map(\.uid)) == [ab.uid, bc.uid])
        // b participates in both; a in only the first.
        #expect(Set(archive.relationships(of: b.uid).map(\.uid)) == [ab.uid, bc.uid])
        #expect(archive.relationships(of: a.uid).map(\.uid) == [ab.uid])
    }

    @Test func linksForPersonAndForArtifact() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let m1 = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject, informationQuality: .primary)
        let m2 = PersonMention(
            localRef: "p2", nameAsRecorded: "Bob Roe", role: .witness,
            informationQuality: .secondary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [m1, m2]))
        let ann = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let bob = try archive.addPerson(.sample(given: "Bob", surname: "Roe"))

        let l1 = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: ann.uid)
            .link
        let l2 = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p2"), to: bob.uid)
            .link

        // The point lookup: a bare link uid (a `supportedByLinks` citation, or a
        // `DanglingReference` finding) resolves to its endpoints through this and
        // nothing else — the `links(for:)` accessors are filtered views.
        #expect(archive.evidenceLink(withID: l1.uid)?.personUid == ann.uid)
        #expect(archive.evidenceLink(withID: l1.uid)?.artifactUid == artifact.uid)
        #expect(archive.evidenceLink(withID: EvidenceLinkID("LNK-nope")) == nil)

        #expect(archive.links(for: ann.uid).map(\.uid) == [l1.uid])
        #expect(archive.links(for: bob.uid).map(\.uid) == [l2.uid])
        #expect(Set(archive.links(forArtifact: artifact.uid).map(\.uid)) == [l1.uid, l2.uid])
    }

    // MARK: - updatePerson

    @Test func updatePersonChangesFieldsPreservesUidAndPersists() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample(given: "Jane", surname: "Doe"))

        let updated = try archive.updatePerson(person.uid) {
            $0.names = [
                PersonName(type: .married, given: "Jane", surname: "Smith", full: "Jane Smith")
            ]
            $0.facts.append(PersonFact(type: .birth, date: "1900"))
        }

        #expect(updated.uid == person.uid)  // identity preserved
        #expect(updated.names.first?.full == "Jane Smith")
        #expect(updated.facts.first?.date == "1900")
        // Provenance is left untouched when the mutate closure doesn't change it
        // (the closure owns provenance edits, exactly like updateMetadata).
        #expect(updated.provenance == person.provenance)

        // Persisted + lookupable (index reflects the write).
        let reread = archive.person(withID: person.uid)
        #expect(reread?.names.first?.full == "Jane Smith")
        #expect(reread?.facts.first?.date == "1900")
    }

    @Test func updatePersonThrowsWhenMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = PersonID("PER-does-not-exist")

        #expect(throws: ArchiveError.personNotFound(bogus)) {
            try archive.updatePerson(bogus) { $0.identifierURI = "x" }
        }
    }

    // MARK: - removePerson / restorePerson

    @Test func removePersonDeletesReturnsRecordAndDoesNotCascade() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)

        let m1 = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject, informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [m1]))
        let ann = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let bob = try archive.addPerson(.sample(given: "Bob"))
        let rel = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: ann.uid, person2Uid: bob.uid))
        let link = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: ann.uid)
            .link

        let removed = try archive.removePerson(ann.uid)

        #expect(removed.uid == ann.uid)
        #expect(archive.person(withID: ann.uid) == nil)
        let sidecar = root.appendingPathComponent("conclusions/persons/\(ann.uid.raw).json")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        // No cascade (§2.3): the relationship + link that referenced Ann are left
        // dangling for verifyIntegrity/findDanglingReferences, not rewritten away.
        #expect(archive.relationships().map(\.uid) == [rel.uid])
        #expect(archive.links(for: ann.uid).map(\.uid) == [link.uid])
    }

    @Test func removePersonThrowsWhenMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = PersonID("PER-does-not-exist")

        #expect(throws: ArchiveError.personNotFound(bogus)) {
            try archive.removePerson(bogus)
        }
    }

    @Test func restorePersonRoundTripsFullRecordAndSurvivesRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        // A person carrying facts (plus the engine-stamped provenance) so restore
        // is exercised on the *whole* record, not just uid + first name.
        let person = try archive.addPerson(
            PersonDraft(
                names: [PersonName(type: .birth, given: "Jane", surname: "Doe", full: "Jane Doe")],
                facts: [
                    PersonFact(type: .birth, date: "1900", place: "Ohio"),
                    PersonFact(type: .death, date: "1975"),
                ]))

        let removed = try archive.removePerson(person.uid)
        #expect(archive.person(withID: person.uid) == nil)

        try archive.restorePerson(removed)

        // Full-record equality: names, facts, provenance, schemaVersion all faithful.
        #expect(archive.person(withID: person.uid) == removed)

        // The sidecar is truly back (not just the index row): a rebuild keeps it.
        try archive.rebuildIndex()
        #expect(archive.person(withID: person.uid) == removed)
    }

    @Test func removePersonSurvivesRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let person = try archive.addPerson(.sample())

        _ = try archive.removePerson(person.uid)
        try archive.rebuildIndex()  // must not resurrect a truly-deleted sidecar

        #expect(archive.person(withID: person.uid) == nil)
    }

    // MARK: - removeRelationship / restoreRelationship

    @Test func removeAndRestoreRelationship() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addPerson(.sample(given: "Ann"))
        let b = try archive.addPerson(.sample(given: "Bob"))
        let rel = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: a.uid, person2Uid: b.uid))

        let removed = try archive.removeRelationship(rel.uid)
        #expect(removed.uid == rel.uid)
        #expect(archive.relationships().isEmpty)
        let sidecar = root.appendingPathComponent("conclusions/relationships/\(rel.uid.raw).json")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        try archive.restoreRelationship(removed)
        #expect(archive.relationships() == [removed])  // full-record faithful
    }

    @Test func removeRelationshipThrowsWhenMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = RelationshipID("REL-does-not-exist")

        #expect(throws: ArchiveError.relationshipNotFound(bogus)) {
            try archive.removeRelationship(bogus)
        }
    }

    // MARK: - updateRelationship (slice 43 — couple facts)

    @Test func updateRelationshipAddsFactsPreservesUidAndPersists() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addPerson(.sample(given: "Ann"))
        let b = try archive.addPerson(.sample(given: "Bob"))
        let rel = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: a.uid, person2Uid: b.uid))
        #expect(rel.facts.isEmpty)

        let updated = try archive.updateRelationship(rel.uid) {
            $0.facts.append(PersonFact(type: .marriage, date: "1918-06-14", place: "Chicago"))
        }

        #expect(updated.uid == rel.uid)  // identity preserved
        #expect(updated.facts.map(\.type) == [.marriage])
        #expect(updated.facts.first?.date == "1918-06-14")

        // Persisted + lookupable (index reflects the write).
        let reread = archive.relationship(withID: rel.uid)
        #expect(reread?.facts.first?.place == "Chicago")
        // And the whole-record read agrees.
        #expect(archive.relationships(of: a.uid).first?.facts.first?.type == .marriage)
    }

    @Test func updateRelationshipThrowsWhenMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = RelationshipID("REL-does-not-exist")

        #expect(throws: ArchiveError.relationshipNotFound(bogus)) {
            try archive.updateRelationship(bogus) {
                $0.facts.append(PersonFact(type: .divorce))
            }
        }
    }

    @Test func updateRelationshipFactsSurviveIndexRebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let a = try archive.addPerson(.sample(given: "Ann"))
        let b = try archive.addPerson(.sample(given: "Bob"))
        let rel = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: a.uid, person2Uid: b.uid))
        _ = try archive.updateRelationship(rel.uid) {
            $0.facts = [
                PersonFact(type: .marriage, date: "1918"),
                PersonFact(type: .divorce, date: "1931~"),
            ]
        }

        try archive.rebuildIndex()

        let reread = archive.relationship(withID: rel.uid)
        #expect(reread?.facts.map(\.type) == [.marriage, .divorce])
        #expect(reread?.facts.last?.date == "1931~")
    }

    // MARK: - unlink / restoreLink

    @Test func unlinkAndRestoreLink() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let m1 = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject, informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [m1]))
        let ann = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let link = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: ann.uid)
            .link

        let removed = try archive.unlink(link.uid)
        #expect(removed.uid == link.uid)
        #expect(archive.links(for: ann.uid).isEmpty)
        let sidecar = root.appendingPathComponent("conclusions/links/\(link.uid.raw).json")
        #expect(!FileManager.default.fileExists(atPath: sidecar.path))

        try archive.restoreLink(removed)
        #expect(archive.links(for: ann.uid) == [removed])  // full-record faithful
    }

    @Test func unlinkThrowsWhenMissing() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let bogus = EvidenceLinkID("LNK-does-not-exist")

        #expect(throws: ArchiveError.evidenceLinkNotFound(bogus)) {
            try archive.unlink(bogus)
        }
    }

    // MARK: - Cross-cutting invariants

    @Test func accessorsReturnEmptyWhenNothingMatches() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let lonely = try archive.addPerson(.sample())
        let artifact = try archive.addArtifact(.sample())

        #expect(archive.relationships().isEmpty)
        #expect(archive.relationships(of: lonely.uid).isEmpty)
        #expect(archive.links(for: lonely.uid).isEmpty)
        #expect(archive.links(forArtifact: artifact.uid).isEmpty)
    }

    /// Since slice 49 the claim is the opposite one: every review-lifecycle write
    /// moves the manifest, an edit re-mints the edited record's entry, and a
    /// remove/restore round trip lands back where it started (the restore writes
    /// the same bytes, so the same hash comes back — no orphan left behind by the
    /// removal, no stale entry left behind by the restore).
    @Test func reviewLifecycleMutationsAreCoveredByTheManifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let m1 = PersonMention(
            localRef: "p1", nameAsRecorded: "Ann Roe", role: .subject, informationQuality: .primary)
        let artifact = try archive.addArtifact(.sample(personsMentioned: [m1]))
        let ann = try archive.addPerson(.sample(given: "Ann", surname: "Roe"))
        let bob = try archive.addPerson(.sample(given: "Bob"))
        let rel = try archive.addRelationship(
            RelationshipDraft(type: .couple, person1Uid: ann.uid, person2Uid: bob.uid))
        let link = try archive.link(MentionRef(artifact: artifact.uid, localRef: "p1"), to: ann.uid)
            .link

        let manifestURL = root.appendingPathComponent("manifest.json")
        let before = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))

        // The removal half on its own: the entry goes away with the record.
        let removedRelationship = try archive.removeRelationship(rel.uid)
        let afterRemoval = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        #expect(
            !afterRemoval.files.contains { $0.path.contains(rel.uid.raw) },
            "a removed relationship must not leave a manifest entry behind")

        // Exercise every review-lifecycle write path.
        try archive.restoreRelationship(removedRelationship)
        try archive.restoreLink(try archive.unlink(link.uid))
        try archive.restorePerson(try archive.removePerson(bob.uid))

        let restored = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        #expect(restored.files == before.files, "a round trip should restore the same entries")

        // An edit re-mints only the record it edited.
        _ = try archive.updatePerson(ann.uid) { $0.identifierURI = "urn:x" }
        let after = try GeneaLogicJSON.decoder.decode(
            Manifest.self, from: Data(contentsOf: manifestURL))
        let annPath = "conclusions/persons/\(ann.uid.raw).json"
        #expect(
            after.files.first { $0.path == annPath }?.sha256
                != before.files.first { $0.path == annPath }?.sha256)
        #expect(
            after.files.filter { $0.path != annPath } == before.files.filter { $0.path != annPath })
    }
}

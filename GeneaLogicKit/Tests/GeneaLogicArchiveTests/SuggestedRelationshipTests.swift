import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// `suggestedRelationships` — promoting what a record states about who is whose into
/// `conclusions/` (slice 45l).
///
/// The gap these pin was found in the real archive: a death certificate (Sidney Feldberg's, in the
/// fictional family) names his parents, both are resolved to concluded persons, and nothing
/// proposed the edge. So the suite is built around that record's shape — a subject with two
/// `parent` mentions — plus the two cases the forks turn on: a marriage register, where the four
/// parents must stay unassignable until the edges are stated, and the dedupe against what
/// `conclusions/` already says.
@Suite struct SuggestedRelationshipTests {

    // MARK: - Fixtures

    private func mention(
        _ ref: String, _ name: String, role: PersonRole
    ) -> PersonMention {
        PersonMention(
            localRef: ref, nameAsRecorded: name, role: role, informationQuality: .primary)
    }

    @discardableResult
    private func addPerson(_ name: String, in archive: Archive) throws -> Person {
        try archive.addPerson(
            PersonDraft(
                names: [PersonName.deriving(type: .birth, given: nil, surname: nil, full: name)]))
    }

    /// A death certificate in the Sidney shape: one subject, two parents, one widow.
    private func deathCertificate(in archive: Archive) throws -> Artifact {
        try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                sourceAuthorityTier: .vital,
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                    mention("p3", "Tauba Pelc", role: .parent),
                ]))
    }

    /// Resolves a mention onto a person the way a human would — a confirmed link.
    private func resolve(
        _ ref: String, on artifact: Artifact, to person: Person, in archive: Archive
    ) throws {
        try archive.link(
            MentionRef(artifact: artifact.uid, localRef: ref), to: person.uid,
            reviewedBy: .human("tester"))
    }

    // MARK: - The record that scheduled the slice

    /// The whole slice in one test: the record states the parents, both are resolved, and
    /// nothing in `conclusions/` says so.
    @Test func suggestsTheParentsAStatedEdgeNames() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let tauba = try addPerson("Tauba Pelc", in: archive)

        let artifact = try deathCertificate(in: archive)
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1"),
                MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
            ]
        }
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        try resolve("p3", on: artifact, to: tauba, in: archive)

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { $0.type == .parentChild })
        #expect(suggestions.allSatisfy { $0.isStated })
        // §4.5's direction, carried across the two layers unchanged: the parent is first.
        #expect(suggestions.allSatisfy { $0.person2 == sidney.uid })
        #expect(Set(suggestions.map(\.person1)) == Set([szlama.uid, tauba.uid]))
        // Both endpoints' links, so the promoted conclusion can say why it believes it.
        #expect(suggestions.allSatisfy { $0.supportedByLinks.count == 2 })
    }

    /// The same record with **no** stated edges: the roles alone say it, through 45g's
    /// star rule, and the suggestion says so rather than claiming the record stated it.
    @Test func infersTheParentsFromRolesWhenNoEdgeIsStated() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let tauba = try addPerson("Tauba Pelc", in: archive)

        let artifact = try deathCertificate(in: archive)
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        try resolve("p3", on: artifact, to: tauba, in: archive)

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 2)
        #expect(suggestions.allSatisfy { !$0.isStated })
        #expect(
            suggestions.allSatisfy { $0.evidence.allSatisfy { $0.basis == .inferredFromRoles } })
        #expect(Set(suggestions.map(\.person1)) == Set([szlama.uid, tauba.uid]))
    }

    /// A widow tagged `spouse` beside the subject is a `couple`, stored in canonical uid
    /// order because the type is symmetric.
    @Test func infersTheCoupleFromASpouseRole() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let gussie = try addPerson("Gussie Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Gussie Feldberg", role: .spouse),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: gussie, in: archive)

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 1)
        #expect(suggestions[0].type == .couple)
        #expect(suggestions[0].person1.raw < suggestions[0].person2.raw)
        #expect(
            Set([suggestions[0].person1, suggestions[0].person2]) == Set([sidney.uid, gussie.uid]))
    }

    // MARK: - The marriage register (fork (c)'s hard case)

    /// **Four parents stay unassignable.** The star rule can only say the parents belong to
    /// "the couple", and the matcher may read that best-of because a wrong guess costs it
    /// nothing; writing a conclusion from the same guess would assert the bride's mother is
    /// the groom's. The couple edge itself is unambiguous and is offered.
    @Test func aMarriageRegistersParentsAreNotInferred() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let bride = try addPerson("Fay Hanner", in: archive)
        let groom = try addPerson("Marcus Feldberg", in: archive)
        let brideFather = try addPerson("Marcus Hanner", in: archive)
        let groomFather = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Feldberg–Hanner marriage register",
                personsMentioned: [
                    mention("p1", "Fay Hanner", role: .spouse),
                    mention("p2", "Marcus Feldberg", role: .spouse),
                    mention("p3", "Marcus Hanner", role: .parent),
                    mention("p4", "Sidney Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: bride, in: archive)
        try resolve("p2", on: artifact, to: groom, in: archive)
        try resolve("p3", on: artifact, to: brideFather, in: archive)
        try resolve("p4", on: artifact, to: groomFather, in: archive)

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 1)
        #expect(suggestions[0].type == .couple)
        #expect(
            Set([suggestions[0].person1, suggestions[0].person2]) == Set([bride.uid, groom.uid]))
    }

    /// **The half-catalogued register**, which the head-count guard let through: bride
    /// entered, groom not yet, both fathers entered. Attributing every parent to the one
    /// spouse on file is the same wrong conclusion as the four-parent case, reached from a
    /// *less* complete record — and it would appear, then silently vanish when the groom was
    /// added. A `spouse` centre means a couple document, whose parents are unassignable
    /// however many parties have been entered. (`/code-review`, 45l.)
    @Test func aSingleSpouseCentreInfersNoParents() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let bride = try addPerson("Fay Hanner", in: archive)
        let brideFather = try addPerson("Marcus Hanner", in: archive)
        let groomFather = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Feldberg–Hanner marriage register",
                personsMentioned: [
                    mention("p1", "Fay Hanner", role: .spouse),
                    mention("p3", "Marcus Hanner", role: .parent),
                    mention("p4", "Sidney Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: bride, in: archive)
        try resolve("p3", on: artifact, to: brideFather, in: archive)
        try resolve("p4", on: artifact, to: groomFather, in: archive)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// …and stating the edges is what makes them assignable — the work 45k exists for.
    @Test func aMarriageRegistersParentsAreSuggestedOnceStated() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let bride = try addPerson("Fay Hanner", in: archive)
        let groom = try addPerson("Marcus Feldberg", in: archive)
        let brideFather = try addPerson("Marcus Hanner", in: archive)
        let groomFather = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Feldberg–Hanner marriage register",
                personsMentioned: [
                    mention("p1", "Fay Hanner", role: .spouse),
                    mention("p2", "Marcus Feldberg", role: .spouse),
                    mention("p3", "Marcus Hanner", role: .parent),
                    mention("p4", "Sidney Feldberg", role: .parent),
                ]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p3", person2Ref: "p1"),
                MentionRelationship(type: .parentChild, person1Ref: "p4", person2Ref: "p2"),
            ]
        }
        try resolve("p1", on: artifact, to: bride, in: archive)
        try resolve("p2", on: artifact, to: groom, in: archive)
        try resolve("p3", on: artifact, to: brideFather, in: archive)
        try resolve("p4", on: artifact, to: groomFather, in: archive)

        let suggestions = archive.suggestedRelationships()

        // Two stated parent edges, plus the couple the two spouse roles still imply.
        #expect(suggestions.count == 3)
        let parents = suggestions.filter { $0.type == .parentChild }
        #expect(parents.count == 2)
        #expect(parents.allSatisfy { $0.isStated })
        #expect(
            Set(parents.map { "\($0.person1.raw)|\($0.person2.raw)" })
                == Set([
                    "\(brideFather.uid.raw)|\(bride.uid.raw)",
                    "\(groomFather.uid.raw)|\(groom.uid.raw)",
                ]))
    }

    /// A record with no centre states no family relation at all: two witnesses to a deed
    /// are related to each other by nothing the document says (45g).
    @Test func aRecordWithNoCentreSuggestsNothing() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let first = try addPerson("Marcus Hanner", in: archive)
        let second = try addPerson("Fay Hanner", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Deed of sale",
                personsMentioned: [
                    mention("p1", "Marcus Hanner", role: .witness),
                    mention("p2", "Fay Hanner", role: .witness),
                ]))
        try resolve("p1", on: artifact, to: first, in: archive)
        try resolve("p2", on: artifact, to: second, in: archive)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    // MARK: - Stated wins per slot, never per record (45k's correction)

    /// Stating the centre's **parents** must not silence the inference of the centre's
    /// **partner**. Reading that silence as denial would mean adding information to a
    /// half-catalogued record removes a suggestion it used to make.
    @Test func aStatedParentEdgeDoesNotSilenceTheCoupleInference() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let gussie = try addPerson("Gussie Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                    mention("p3", "Gussie Feldberg", role: .spouse),
                ]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1")
            ]
        }
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        try resolve("p3", on: artifact, to: gussie, in: archive)

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 2)
        #expect(suggestions.first { $0.type == .parentChild }?.isStated == true)
        #expect(suggestions.first { $0.type == .couple }?.isStated == false)
    }

    /// A stated edge and the inference of the *same* slot are one statement, not two — the
    /// record's own word, once.
    @Test func aStatedEdgeIsNotDuplicatedByTheInference() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p2", person2Ref: "p1")
            ]
        }
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        let suggestions = archive.suggestedRelationships()
        #expect(suggestions.count == 1)
        #expect(suggestions[0].evidence.count == 1)
    }

    // MARK: - The dedupe

    @Test func anAssertedRelationshipIsNotReOffered() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        #expect(archive.suggestedRelationships().count == 1)

        try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: szlama.uid, person2Uid: sidney.uid))

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// **Both directions of a `couple` count as asserted** (§4.5): the reversed pair is the
    /// same statement written the other way round, and re-offering it is the double entry
    /// the symmetry rule exists to prevent.
    @Test func anAssertedCoupleCountsFromEitherDirection() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let gussie = try addPerson("Gussie Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Gussie Feldberg", role: .spouse),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: gussie, in: archive)

        let suggested = archive.suggestedRelationships()
        #expect(suggested.count == 1)
        // Asserted the other way round from the order the suggestion canonicalized to.
        try archive.addRelationship(
            RelationshipDraft(
                type: .couple, person1Uid: suggested[0].person2, person2Uid: suggested[0].person1))

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// A `parent-child` is directional, so declining one direction leaves the other open —
    /// the reason `DismissalSubject.isSymmetric` exists.
    @Test func aDismissalForeclosesOnlyTheDirectionDeclined() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        // Declining the *reverse* claim — Sidney is Szlama's parent — leaves the record's
        // own claim untouched.
        try archive.dismiss(.parentChild, between: sidney.uid, and: szlama.uid)
        #expect(archive.suggestedRelationships().count == 1)

        try archive.dismiss(.parentChild, between: szlama.uid, and: sidney.uid)
        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// Deleting the dismissal returns the pair to the queue — there is no fourth verb (45m).
    @Test func undismissingReturnsTheSuggestion() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        let suggestion = try #require(archive.suggestedRelationships().first)
        try archive.dismiss(suggestion)
        #expect(archive.suggestedRelationships().isEmpty)

        try archive.undismiss(.parentChild, between: szlama.uid, and: sidney.uid)
        #expect(archive.suggestedRelationships().count == 1)
    }

    /// A `same-person` dismissal belongs to 45j's lane and says nothing about a family
    /// relation between the two — it must not silence this one.
    @Test func aSamePersonDismissalDoesNotForecloseARelationship() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        try archive.dismiss(.samePerson, between: szlama.uid, and: sidney.uid)

        #expect(archive.suggestedRelationships().count == 1)
    }

    // MARK: - Unresolved and degenerate endpoints

    @Test func anUnresolvedEndpointYieldsNothing() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// A rejection tombstone resolves nothing (45c), so it cannot supply an endpoint.
    @Test func aRejectedLinkDoesNotResolveAnEndpoint() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try archive.reject(MentionRef(artifact: artifact.uid, localRef: "p2"), as: szlama.uid)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// Both ends resolving to one person is a self-loop, which 45f's merge already drops
    /// rather than writes.
    @Test func aSelfLoopIsNotSuggested() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Sidney Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: sidney, in: archive)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// §2.3: removals don't cascade, so a confirmed link can outlive its person. The pair is
    /// dropped rather than offered — a row whose Record button throws is worse than no row.
    @Test func anEndpointWhosePersonIsGoneYieldsNothing() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        #expect(archive.suggestedRelationships().count == 1)

        try archive.removePerson(szlama.uid)
        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// A stated edge naming a mention the record no longer carries is a dangling reference
    /// (44e reports it); it must not be silently promoted into a conclusion.
    @Test func aDanglingEdgeIsNotPromoted() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [mention("p1", "Sidney Feldberg", role: .subject)]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(type: .parentChild, person1Ref: "p9", person2Ref: "p1")
            ]
        }
        try resolve("p1", on: artifact, to: sidney, in: archive)

        #expect(archive.suggestedRelationships().isEmpty)
    }

    // MARK: - One conclusion, however many records

    @Test func twoRecordsStatingTheSameEdgeAreOneSuggestion() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        for title in ["Death certificate", "Birth register"] {
            let artifact = try archive.addArtifact(
                .sample(
                    title: title,
                    personsMentioned: [
                        mention("p1", "Sidney Feldberg", role: .subject),
                        mention("p2", "Szlama Feldberg", role: .parent),
                    ]))
            try resolve("p1", on: artifact, to: sidney, in: archive)
            try resolve("p2", on: artifact, to: szlama, in: archive)
        }

        let suggestions = archive.suggestedRelationships()

        #expect(suggestions.count == 1)
        #expect(suggestions[0].evidence.count == 2)
        // Four links, one pair per record — the conclusion cites every record behind it.
        #expect(suggestions[0].supportedByLinks.count == 4)
    }

    /// The inspector direction is a **filter** over the same derivation, so it can never
    /// offer something the lane considers settled — and a row confirmed from it still cites
    /// every supporting record.
    @Test func theArtifactDirectionFiltersTheSameAnswer() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let gussie = try addPerson("Gussie Feldberg", in: archive)

        let certificate = try archive.addArtifact(
            .sample(
                title: "Sidney Feldberg death certificate",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: certificate, to: sidney, in: archive)
        try resolve("p2", on: certificate, to: szlama, in: archive)

        let photograph = try archive.addArtifact(
            .sample(
                title: "Wedding photograph",
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Gussie Feldberg", role: .spouse),
                ]))
        try resolve("p1", on: photograph, to: sidney, in: archive)
        try resolve("p2", on: photograph, to: gussie, in: archive)

        #expect(archive.suggestedRelationships().count == 2)

        let onCertificate = archive.suggestedRelationships(forArtifact: certificate.uid)
        #expect(onCertificate.count == 1)
        #expect(onCertificate[0].type == .parentChild)

        let onPhotograph = archive.suggestedRelationships(forArtifact: photograph.uid)
        #expect(onPhotograph.count == 1)
        #expect(onPhotograph[0].type == .couple)
    }

    /// The person direction is the same answer filtered a third way — both endpoints, since
    /// an edge is owed to each of them equally, and a person named by nothing gets nothing.
    @Test func thePersonDirectionFiltersTheSameAnswer() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let tauba = try addPerson("Tauba Pelc", in: archive)
        let stranger = try addPerson("Marcus Hanner", in: archive)

        let artifact = try deathCertificate(in: archive)
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        try resolve("p3", on: artifact, to: tauba, in: archive)

        // The child is named by both edges; each parent by their own.
        #expect(archive.suggestedRelationships(for: sidney.uid).count == 2)
        #expect(archive.suggestedRelationships(for: szlama.uid).count == 1)
        #expect(archive.suggestedRelationships(for: tauba.uid).count == 1)
        #expect(archive.suggestedRelationships(for: stranger.uid).isEmpty)

        // …and it subtracts what the archive has settled, exactly as the lane does — a
        // per-person scan could offer an edge the lane considers done.
        try archive.dismiss(.parentChild, between: szlama.uid, and: sidney.uid)
        #expect(archive.suggestedRelationships(for: szlama.uid).isEmpty)
        #expect(archive.suggestedRelationships(for: sidney.uid).count == 1)
    }

    /// Deterministic across runs: document order (artifact `uid`) then the pair, since
    /// there is no score to rank on.
    @Test func orderingIsDeterministic() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)
        let tauba = try addPerson("Tauba Pelc", in: archive)

        let artifact = try deathCertificate(in: archive)
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)
        try resolve("p3", on: artifact, to: tauba, in: archive)

        let first = archive.suggestedRelationships()
        for _ in 0..<3 {
            #expect(archive.suggestedRelationships() == first)
        }
        #expect(archive.suggestedRelationships(limit: 1).count == 1)
        #expect(archive.suggestedRelationships(limit: -1).isEmpty)
    }

    // MARK: - Promotion

    /// Fork (d): a promoted relationship records **what was derived and who agreed**, not a
    /// hand-made assertion — `human-verified` review status over `createdBy: .machine`.
    @Test func confirmingWritesAMachineProposedHumanVerifiedRelationship() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Szlama Feldberg", role: .parent),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        let suggestion = try #require(archive.suggestedRelationships().first)
        let relationship = try archive.confirm(suggestion)

        #expect(relationship.type == .parentChild)
        #expect(relationship.parent == szlama.uid)
        #expect(relationship.child == sidney.uid)
        #expect(relationship.reviewStatus == .humanVerified)
        #expect(relationship.provenance.createdBy == .machine)
        #expect(relationship.provenance.tool == SuggestedRelationship.toolIdentifier)
        #expect(Set(relationship.supportedByLinks) == Set(suggestion.supportedByLinks))
        // …and having been promoted, it is not offered again.
        #expect(archive.suggestedRelationships().isEmpty)
    }

    /// **Confirming twice writes one record**, like `dismiss`. Reachable from a stale list —
    /// two windows, or a queue left open while the CLI wrote — and two records for one
    /// conclusion leave ⌘Z half-effective. (`/code-review`, 45l.)
    @Test func confirmingAnAlreadyAssertedEdgeIsIdempotent() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let gussie = try addPerson("Gussie Feldberg", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Sidney Feldberg", role: .subject),
                    mention("p2", "Gussie Feldberg", role: .spouse),
                ]))
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: gussie, in: archive)

        let suggestion = try #require(archive.suggestedRelationships().first)
        let first = try archive.confirm(suggestion)
        // The caller still holds the stale suggestion, exactly as a second window would.
        let second = try archive.confirm(suggestion)

        #expect(first.uid == second.uid)
        #expect(archive.relationships().count == 1)
        #expect(archive.asserts(.couple, between: sidney.uid, and: gussie.uid))
        // Symmetric, so the reversed pair is the same claim — `asserts` must say so, since
        // it is what the app checks before registering an undo.
        #expect(archive.asserts(.couple, between: gussie.uid, and: sidney.uid))
        #expect(!archive.asserts(.parentChild, between: sidney.uid, and: gussie.uid))
    }

    /// Suggestions are ephemeral: deriving them writes nothing at all.
    @Test func derivingWritesNothing() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let sidney = try addPerson("Sidney Feldberg", in: archive)
        let szlama = try addPerson("Szlama Feldberg", in: archive)

        let artifact = try deathCertificate(in: archive)
        try resolve("p1", on: artifact, to: sidney, in: archive)
        try resolve("p2", on: artifact, to: szlama, in: archive)

        #expect(!archive.suggestedRelationships().isEmpty)
        #expect(archive.relationships().isEmpty)
        #expect(archive.dismissals().isEmpty)
    }

    /// An unknown relationship type flows through end to end — offered, declined under the
    /// matching unknown subject, and read back as directional (§7's open-vocabulary rule).
    @Test func anUnknownStatedTypeIsCarriedThrough() throws {
        let archive = try Archive.create(at: TestSupport.makeTempDirectory())
        let first = try addPerson("Marcus Hanner", in: archive)
        let second = try addPerson("Fay Hanner", in: archive)

        let artifact = try archive.addArtifact(
            .sample(
                personsMentioned: [
                    mention("p1", "Marcus Hanner", role: .subject),
                    mention("p2", "Fay Hanner", role: .godparent),
                ]))
        try archive.updateMetadata(of: artifact.uid) {
            $0.mentionRelationships = [
                MentionRelationship(
                    type: .unknown("godparent-of"), person1Ref: "p2", person2Ref: "p1")
            ]
        }
        try resolve("p1", on: artifact, to: first, in: archive)
        try resolve("p2", on: artifact, to: second, in: archive)

        let suggestion = try #require(archive.suggestedRelationships().first)
        #expect(suggestion.type == .unknown("godparent-of"))
        #expect(suggestion.dismissalSubject == .unknown("godparent-of"))
        // Directional, as an unknown vocabulary must be: the endpoints stay as stated.
        #expect(suggestion.person1 == second.uid)
        #expect(suggestion.person2 == first.uid)

        try archive.dismiss(suggestion)
        #expect(archive.suggestedRelationships().isEmpty)
    }
}

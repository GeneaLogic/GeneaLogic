import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp

/// Slice 52 — undo and redo still ping-pong now that every engine call is
/// awaited.
///
/// **What these are really guarding.** `NSUndoManager` files a registration
/// according to what it is doing at the moment of the call: one made while it is
/// inside an undo becomes the *redo*, one made at any other time becomes a new
/// *undo*. Before 52 the engine call ran inline, so registering after it was
/// still "during the undo". Now it is awaited — so registering after it would
/// land on the wrong stack and turn ⌘Z into a one-way trip that redoes itself.
/// Nothing throws when that happens, which is why the slice called for coverage
/// before the refactor rather than after it.
///
/// Each test therefore checks the same three things for one mutation kind: the
/// action lands, ⌘Z reverses it, and ⌘⇧Z reapplies it.
@MainActor
@Suite struct UndoRedoTests {

    // MARK: - Artifacts

    @Test func addingAnArtifactUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        #expect(model.artifacts.count == 1)

        await model.undoAndSettle()
        #expect(model.artifacts.isEmpty)

        await model.redoAndSettle()
        #expect(model.artifacts.count == 1)
    }

    @Test func deletingAnArtifactUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let id = try #require(model.artifacts.first?.uid)

        await model.act { model.deleteArtifact(id) }
        #expect(model.artifacts.isEmpty)

        await model.undoAndSettle()
        #expect(model.artifacts.map(\.uid) == [id], "restore must be uid-faithful")

        await model.redoAndSettle()
        #expect(model.artifacts.isEmpty)

        // And back again — the ping-pong has to survive more than one lap, which
        // is exactly what a counterpart filed on the wrong stack would break.
        await model.undoAndSettle()
        #expect(model.artifacts.map(\.uid) == [id])
    }

    @Test func editingArtifactMetadataUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let id = try #require(model.artifacts.first?.uid)
        // Ingest titles the artifact after the source filename, which is unique
        // per run — so the pre-edit title is read, not assumed.
        let originalTitle = try #require(model.fullArtifact(id)?.title)

        await model.act {
            model.updateMetadata(of: id, actionName: "Edit Title") { $0.title = "1920 Census" }
        }
        #expect(model.fullArtifact(id)?.title == "1920 Census")

        await model.undoAndSettle()
        #expect(model.fullArtifact(id)?.title == originalTitle)

        await model.redoAndSettle()
        #expect(model.fullArtifact(id)?.title == "1920 Census")
    }

    /// The same two edits, but each allowed to land before the next — a user
    /// typing, tabbing away, typing again. Separate turns, so separate groups.
    @Test func pausedEditsUndoOneAtATime() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let id = try #require(model.artifacts.first?.uid)
        let originalTitle = try #require(model.fullArtifact(id)?.title)

        await model.act {
            model.updateMetadata(of: id, actionName: "Edit Title") { $0.title = "First" }
        }
        await model.act {
            model.updateMetadata(of: id, actionName: "Edit Title") { $0.title = "Second" }
        }

        await model.undoAndSettle()
        #expect(model.fullArtifact(id)?.title == "First")

        await model.undoAndSettle()
        #expect(model.fullArtifact(id)?.title == originalTitle, "second ⌘Z must not redo")

        await model.redoAndSettle()
        #expect(model.fullArtifact(id)?.title == "First")
    }

    // MARK: - Files

    /// The one path whose counterpart is computed by the engine rather than known
    /// up front (`revert` mints a fresh trash entry), so it goes through
    /// `PendingFileChange`. If that promise is never filled, redo silently no-ops
    /// — which this would catch.
    @Test func detachingAFileUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let id = try #require(model.artifacts.first?.uid)
        let fileID = try #require(model.fullArtifact(id)?.files.first?.uid)

        await model.act { model.detachFile(fileID, from: id) }
        #expect(model.fullArtifact(id)?.files.isEmpty == true)

        await model.undoAndSettle()
        #expect(model.fullArtifact(id)?.files.map(\.uid) == [fileID])

        await model.redoAndSettle()
        #expect(model.fullArtifact(id)?.files.isEmpty == true)
    }

    @Test func changingAFileRoleUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let id = try #require(model.artifacts.first?.uid)
        let fileID = try #require(model.fullArtifact(id)?.files.first?.uid)
        let original = try #require(model.fullArtifact(id)?.files.first?.role)

        await model.act { model.setFileRole(fileID, in: id, to: .accessCopy) }
        #expect(model.fullArtifact(id)?.files.first?.role == .accessCopy)

        await model.undoAndSettle()
        #expect(model.fullArtifact(id)?.files.first?.role == original)

        await model.redoAndSettle()
        #expect(model.fullArtifact(id)?.files.first?.role == .accessCopy)
    }

    // MARK: - People

    @Test func addingAPersonUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let id = try #require(model.persons.first?.uid)

        await model.undoAndSettle()
        #expect(model.persons.isEmpty)

        await model.redoAndSettle()
        #expect(model.persons.map(\.uid) == [id], "restore must be uid-faithful")
    }

    @Test func deletingAPersonUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let id = try #require(model.persons.first?.uid)

        await model.act { model.deletePerson(id) }
        #expect(model.persons.isEmpty)

        await model.undoAndSettle()
        #expect(model.persons.map(\.uid) == [id])

        await model.redoAndSettle()
        #expect(model.persons.isEmpty)
    }

    @Test func editingAPersonUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let id = try #require(model.persons.first?.uid)
        let fact = PersonFact(type: .birth, date: "1888")

        await model.act {
            model.updatePerson(of: id, actionName: "Add Fact") { $0.facts.append(fact) }
        }
        #expect(model.fullPerson(id)?.facts.count == 1)

        await model.undoAndSettle()
        #expect(model.fullPerson(id)?.facts.isEmpty == true)

        await model.redoAndSettle()
        #expect(model.fullPerson(id)?.facts.map(\.date) == ["1888"])
    }

    // MARK: - Relationships

    @Test func addingARelationshipUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        await model.act { model.createPerson(given: "Rose", surname: "Hanner") }
        let ids = model.persons.map(\.uid)
        #expect(ids.count == 2)

        await model.act {
            model.createRelationship(type: .couple, person1: ids[0], person2: ids[1])
        }
        #expect(model.allRelationships().count == 1)

        await model.undoAndSettle()
        #expect(model.allRelationships().isEmpty)

        await model.redoAndSettle()
        #expect(model.allRelationships().count == 1)
    }

    @Test func deletingARelationshipUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        await model.act { model.createPerson(given: "Rose", surname: "Hanner") }
        let ids = model.persons.map(\.uid)
        await model.act {
            model.createRelationship(type: .couple, person1: ids[0], person2: ids[1])
        }
        let rid = try #require(model.allRelationships().first?.uid)

        await model.act { model.deleteRelationship(rid) }
        #expect(model.allRelationships().isEmpty)

        await model.undoAndSettle()
        #expect(model.allRelationships().map(\.uid) == [rid])

        await model.redoAndSettle()
        #expect(model.allRelationships().isEmpty)
    }

    /// Three engine writes behind one ⌘Z. This is the case the single-`work`
    /// rule exists for: a hop per write would scatter the registrations across
    /// run-loop turns and split the action into three separate undo steps.
    @Test func creatingAPersonRelationshipAndFactIsOneUndoStep() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let subject = try #require(model.persons.first?.uid)

        await model.act {
            model.createPersonRelateAndRecord(
                subject: subject, given: "Rose", surname: "Hanner",
                fact: PersonFact(type: .marriage, date: "1910"))
        }
        #expect(model.persons.count == 2)
        #expect(model.allRelationships().count == 1)
        #expect(model.allRelationships().first?.facts.count == 1)

        await model.undoAndSettle()
        #expect(model.persons.map(\.uid) == [subject], "one ⌘Z must undo all three writes")
        #expect(model.allRelationships().isEmpty)

        await model.redoAndSettle()
        #expect(model.persons.count == 2)
        #expect(model.allRelationships().first?.facts.count == 1)
    }

    // MARK: - Merge (the cascading one)

    @Test func mergingPeopleUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        await model.act { model.createPerson(given: "Marcs", surname: "Hanner") }
        let ids = model.persons.map(\.uid)
        #expect(ids.count == 2)

        await model.act { model.mergePersons(ids[1], into: ids[0]) }
        #expect(model.persons.count == 1)

        await model.undoAndSettle()
        #expect(Set(model.persons.map(\.uid)) == Set(ids))

        await model.redoAndSettle()
        #expect(model.persons.map(\.uid) == [ids[0]])
    }

    // MARK: - Evidence links

    @Test func resolvingAMentionUndoesAndRedoes() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let artifactID = try #require(model.artifacts.first?.uid)
        await model.act {
            model.updateMetadata(of: artifactID, actionName: "Add Person Mentioned") {
                $0.personsMentioned.append(
                    PersonMention(
                        localRef: "p1", nameAsRecorded: "Marcus Hanner", role: .subject,
                        informationQuality: .primary))
            }
        }
        await model.act { model.createPerson(given: "Marcus", surname: "Hanner") }
        let personID = try #require(model.persons.first?.uid)

        await model.act { model.resolveMention("p1", in: artifactID, to: personID) }
        #expect(model.personLinks(for: personID).count == 1)

        await model.undoAndSettle()
        #expect(model.personLinks(for: personID).isEmpty)

        await model.redoAndSettle()
        #expect(model.personLinks(for: personID).count == 1)
    }

    /// Two writes, one ⌘Z — and the ordering matters: the person has to exist
    /// when its link is (re)written, on both the undo and the redo pass.
    @Test func creatingAPersonFromAMentionIsOneUndoStep() async throws {
        let (model, root) = try AppTestSupport.makeModel()
        defer { AppTestSupport.remove(root) }

        let source = try makeSourceFile(named: "census.txt", in: root)
        await model.act { model.ingest([source]) }
        let artifactID = try #require(model.artifacts.first?.uid)
        let mention = PersonMention(
            localRef: "p1", nameAsRecorded: "Marcus Hanner", role: .subject,
            informationQuality: .primary)
        await model.act {
            model.updateMetadata(of: artifactID, actionName: "Add Person Mentioned") {
                $0.personsMentioned.append(mention)
            }
        }

        await model.act { model.createPersonAndLink(from: mention, in: artifactID) }
        #expect(model.persons.count == 1)
        #expect(model.artifactLinks(for: artifactID).count == 1)

        await model.undoAndSettle()
        #expect(model.persons.isEmpty, "one ⌘Z must undo both the link and the person")
        #expect(model.artifactLinks(for: artifactID).isEmpty)

        await model.redoAndSettle()
        #expect(model.persons.count == 1)
        #expect(model.artifactLinks(for: artifactID).count == 1)
    }

    // MARK: - Helpers

    /// A small real file outside the archive, for ingest to copy in.
    private func makeSourceFile(named name: String, in root: URL) throws -> URL {
        let url = root.deletingLastPathComponent()
            .appendingPathComponent("src-\(UUID().uuidString)-\(name)")
        try Data("scan".utf8).write(to: url)
        return url
    }
}

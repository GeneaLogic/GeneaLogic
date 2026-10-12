import Foundation
import GeneaLogicModel
import Synchronization
import Testing

@testable import GeneaLogicArchive

/// **A write cut in half leaves one of two states** — slice 65's property.
///
/// Every public mutation is run once on a small seeded archive with a
/// `WriteCheckpoint` hook that copies the whole archive at each on-disk transition.
/// Each copy is the archive a crash at that instant would leave, and is opened as
/// one. At every cut:
///
/// - `open` succeeds, and what the archive holds — every record, the bytes each
///   artifact claims, the trash listing and what it can restore — is exactly the
///   state before the mutation or exactly the state after it;
/// - `verifyIntegrity()` reports nothing but `.interruptedWrite` and
///   `.unreferencedFile`, and the suspect flag is set **iff** an `.interruptedWrite`
///   finding exists;
/// - a second open says the same thing as the first;
/// - `rebaseline()` then leaves it clean, holding the same state.
///
/// **The stated exception** is a mutation that writes several records:
/// `mergePersons`/`revertMerge`, a verdict that supersedes another (`reject` over
/// a confirmation writes the tombstone, then removes the link), and `emptyTrash`
/// (an entry at a time). No ordering makes that atomic across files, so each
/// record — each trash entry — is its before or its after version; the writes that
/// stay land first, so a cut is a superset, never a loss. A journal would close
/// it; that is a format addition, carried. A single purge is held to the full
/// property: it takes its entry out of the listing with one rename.
@Suite struct WriteCutTests {

    // MARK: - The catalogue

    /// What a cut must land on — see the suite's doc comment for the exceptions.
    enum Landing: Sendable {
        /// The whole archive is its before state or its after state.
        case beforeOrAfter
        /// Each record is its before or its after version.
        case recordwise
    }

    struct Mutation: Sendable, CustomTestStringConvertible {
        let name: String
        var landing = Landing.beforeOrAfter
        /// Untimed setup the cut does not see — what `mutate` will undo, typically.
        var prepare: @Sendable (Archive, Seed) throws -> Prepared = { _, _ in .none }
        let mutate: @Sendable (Archive, Seed, Prepared) throws -> Void

        var testDescription: String { name }
    }

    enum Prepared: @unchecked Sendable {
        case none
        case fileChange(FileChange)
        case person(Person)
        case relationship(Relationship)
        case link(EvidenceLink)
        case dismissal(Dismissal)
        case merge(MergeDecision)
    }

    /// The seeded archive: one artifact with two files and two mentions, one
    /// artifact and one detached file already in the trash, three persons, a
    /// relationship, a link and a dismissal — enough for every mutation to have a
    /// real subject.
    struct Seed: Sendable {
        let census: ArtifactID
        let scan: FileID
        let notes: FileID
        let trashedArtifact: ArtifactID
        let trashedFile: FileID
        let marcus: PersonID
        let meir: PersonID
        let ruchla: PersonID
        let relationship: RelationshipID
        let link: EvidenceLinkID
        let dismissal: DismissalID
    }

    static let catalogue: [Mutation] = [
        Mutation(name: "addArtifact") { a, _, _ in
            _ = try a.addArtifact(.sample(title: "Ship manifest"))
        },
        Mutation(name: "updateMetadata") { a, s, _ in
            try a.updateMetadata(of: s.census) { $0.notes = "Enumerated twice." }
        },
        Mutation(name: "removeArtifact") { a, s, _ in
            _ = try a.removeArtifact(s.census)
        },
        Mutation(name: "restoreFromTrash") { a, s, _ in
            _ = try a.restoreFromTrash(s.trashedArtifact)
        },
        Mutation(name: "deleteFromTrash") { a, s, _ in
            try a.deleteFromTrash(s.trashedArtifact)
        },
        Mutation(name: "emptyTrash", landing: .recordwise) { a, _, _ in try a.emptyTrash() },
        Mutation(name: "attachFile") { a, s, _ in
            let source = try TestSupport.makeSourceFile(named: "back.jpg", contents: "verso")
            _ = try a.attachFile(copyingFrom: source, to: s.census, role: .accessCopy)
        },
        Mutation(name: "replaceFile") { a, s, _ in
            let source = try TestSupport.makeSourceFile(named: "scan.jpg", contents: "rescanned")
            _ = try a.replaceFile(s.scan, in: s.census, copyingFrom: source)
        },
        Mutation(
            name: "revert(replaced)",
            prepare: { a, s in
                let source = try TestSupport.makeSourceFile(named: "scan.jpg", contents: "v2")
                return .fileChange(try a.replaceFile(s.scan, in: s.census, copyingFrom: source))
            },
            mutate: { a, _, prepared in
                guard case .fileChange(let change) = prepared else { return }
                _ = try a.revert(change)
            }),
        Mutation(name: "detachFile") { a, s, _ in
            _ = try a.detachFile(s.scan, in: s.census)
        },
        Mutation(name: "restoreFile") { a, s, _ in
            _ = try a.restoreFile(s.trashedFile)
        },
        Mutation(name: "deleteFileFromTrash") { a, s, _ in
            try a.deleteFileFromTrash(s.trashedFile)
        },
        Mutation(name: "setFileRole") { a, s, _ in
            _ = try a.setFileRole(s.scan, in: s.census, to: .derivative)
        },
        Mutation(name: "addPerson") { a, _, _ in
            _ = try a.addPerson(.sample(given: "Leib", surname: "Hanner"))
        },
        Mutation(name: "updatePerson") { a, s, _ in
            _ = try a.updatePerson(s.marcus) { $0.facts = [PersonFact(type: .birth, date: "1881")] }
        },
        Mutation(name: "removePerson") { a, s, _ in _ = try a.removePerson(s.ruchla) },
        Mutation(
            name: "restorePerson",
            prepare: { a, s in .person(try a.removePerson(s.ruchla)) },
            mutate: { a, _, prepared in
                guard case .person(let person) = prepared else { return }
                try a.restorePerson(person)
            }),
        Mutation(name: "addRelationship") { a, s, _ in
            _ = try a.addRelationship(
                RelationshipDraft(type: .couple, person1Uid: s.marcus, person2Uid: s.ruchla))
        },
        Mutation(name: "updateRelationship") { a, s, _ in
            _ = try a.updateRelationship(s.relationship) { $0.facts = [PersonFact(type: .marriage, date: "1905")] }
        },
        Mutation(name: "removeRelationship") { a, s, _ in
            _ = try a.removeRelationship(s.relationship)
        },
        Mutation(
            name: "restoreRelationship",
            prepare: { a, s in .relationship(try a.removeRelationship(s.relationship)) },
            mutate: { a, _, prepared in
                guard case .relationship(let relationship) = prepared else { return }
                try a.restoreRelationship(relationship)
            }),
        Mutation(name: "link") { a, s, _ in
            _ = try a.link(MentionRef(artifact: s.census, localRef: "p2"), to: s.meir)
        },
        Mutation(name: "unlink") { a, s, _ in _ = try a.unlink(s.link) },
        Mutation(
            name: "restoreLink",
            prepare: { a, s in .link(try a.unlink(s.link)) },
            mutate: { a, _, prepared in
                guard case .link(let link) = prepared else { return }
                try a.restoreLink(link)
            }),
        Mutation(name: "confirm") { a, s, _ in
            _ = try a.confirm(MentionRef(artifact: s.census, localRef: "p2"), as: s.meir)
        },
        Mutation(name: "reject", landing: .recordwise) { a, s, _ in
            _ = try a.reject(MentionRef(artifact: s.census, localRef: "p1"), as: s.marcus)
        },
        Mutation(name: "dismiss") { a, s, _ in
            _ = try a.dismiss(.couple, between: s.marcus, and: s.ruchla)
        },
        Mutation(name: "undismiss") { a, s, _ in
            _ = try a.undismiss(.samePerson, between: s.meir, and: s.ruchla)
        },
        Mutation(name: "removeDismissal") { a, s, _ in _ = try a.removeDismissal(s.dismissal) },
        Mutation(
            name: "restoreDismissal",
            prepare: { a, s in .dismissal(try a.removeDismissal(s.dismissal)) },
            mutate: { a, _, prepared in
                guard case .dismissal(let dismissal) = prepared else { return }
                try a.restoreDismissal(dismissal)
            }),
        Mutation(name: "mergePersons", landing: .recordwise) { a, s, _ in
            _ = try a.mergePersons(s.meir, into: s.marcus)
        },
        Mutation(
            name: "revertMerge", landing: .recordwise,
            prepare: { a, s in .merge(try a.mergePersons(s.meir, into: s.marcus)) },
            mutate: { a, _, prepared in
                guard case .merge(let decision) = prepared else { return }
                try a.revertMerge(decision)
            }),
        Mutation(name: "rebaseline") { a, _, _ in try a.rebaseline() },
        Mutation(name: "rebuildIndex") { a, _, _ in _ = try a.rebuildIndex() },
    ]

    // MARK: - The property

    @Test(arguments: catalogue)
    func everyCutOpensIntoBeforeOrAfter(_ mutation: Mutation) throws {
        let workspace = TestSupport.makeTempDirectory(function: "cut-\(mutation.name)")
        let root = workspace.appendingPathComponent("archive.genea", isDirectory: true)
        let (archive, seed) = try Self.seed(at: root)
        let prepared = try mutation.prepare(archive, seed)

        let beforeImage = workspace.appendingPathComponent("before", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: beforeImage)

        let snapshots = Mutex<[(event: String, url: URL)]>([])
        WriteCheckpoint.install(root: root) { event, url in
            snapshots.withLock { taken in
                let image = workspace.appendingPathComponent(
                    "cut-\(taken.count)", isDirectory: true)
                try? FileManager.default.copyItem(at: root, to: image)
                taken.append(("\(event) \(ArchiveLayout.relativePath(of: url, in: root))", image))
            }
        }
        defer { WriteCheckpoint.remove(root: root) }
        try mutation.mutate(archive, seed, prepared)
        WriteCheckpoint.remove(root: root)

        let afterImage = workspace.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.copyItem(at: root, to: afterImage)

        let before = try Self.observe(Archive.open(at: beforeImage))
        let after = try Self.observe(Archive.open(at: afterImage))
        let cuts = snapshots.withLock { $0 }
        #expect(!cuts.isEmpty, "the mutation reported no checkpoint at all")

        var failures: [String] = []
        for (number, cut) in cuts.enumerated() {
            let label = "cut \(number) of \(cuts.count) (after \(cut.event))"
            do {
                failures += try Self.check(
                    cut.url, before: before, after: after, landing: mutation.landing
                ).map { "\(label): \($0)" }
            } catch {
                failures.append("\(label): threw \(error)")
            }
        }
        for failure in failures.prefix(4) { Issue.record(Comment(rawValue: failure)) }
        #expect(failures.count == 0, "\(failures.count) failing cuts in \(mutation.name)")
    }

    /// Every clause of the property, for one crash image. Returns what failed.
    static func check(
        _ image: URL, before: Observation, after: Observation, landing: Landing
    ) throws -> [String] {
        var failures: [String] = []

        let first = try Archive.open(at: image)
        let seen = try observe(first)
        switch landing {
        case .beforeOrAfter where seen != before && seen != after:
            failures.append(
                "neither before nor after — vs before: \(seen.differences(from: before)); "
                    + "vs after: \(seen.differences(from: after))")
        case .recordwise:
            failures += seen.differencesFromBoth(before, after)
        case .beforeOrAfter:
            break
        }
        let issues = try first.verifyIntegrity().issues
        let unexpected = issues.filter { !$0.isCrashResidue }
        if !unexpected.isEmpty { failures.append("findings \(unexpected)") }
        let suspect = first.interruptedWriteSuspected
        if suspect != issues.contains(where: \.isInterruptedWrite) {
            failures.append("flag \(suspect) but findings \(issues)")
        }

        let second = try Archive.open(at: image)
        if try observe(second) != seen { failures.append("a second open saw a different archive") }
        let reissued = try second.verifyIntegrity().issues
        if reissued.map(\.description).sorted() != issues.map(\.description).sorted() {
            failures.append("a second open reported \(reissued), the first \(issues)")
        }
        if second.interruptedWriteSuspected != suspect {
            failures.append("a second open's flag is \(second.interruptedWriteSuspected)")
        }

        try second.rebaseline()
        if try observe(second) != seen { failures.append("rebaseline changed the archive") }
        let settled = try second.verifyIntegrity().issues.filter {
            if case .unreferencedFile = $0 { return false }
            return true
        }
        if !settled.isEmpty { failures.append("after rebaseline: \(settled)") }
        if second.interruptedWriteSuspected { failures.append("rebaseline left the flag set") }
        return failures
    }

    // MARK: - Observation

    /// What the archive holds, as a user could find out: every record, the bytes
    /// each artifact claims, and the trash — what it lists and what it could put back.
    struct Observation: Equatable {
        var records: [String: String]
        var trash: [String: String]

        func differences(from other: Observation) -> [String] {
            let keys = Set(records.keys).union(other.records.keys).sorted()
            let trashKeys = Set(trash.keys).union(other.trash.keys).sorted()
            return keys.filter { records[$0] != other.records[$0] }
                + trashKeys.filter { trash[$0] != other.trash[$0] }.map { "trash \($0)" }
        }

        /// The weaker, per-record property: each record is one side or the other.
        func differencesFromBoth(_ before: Observation, _ after: Observation) -> [String] {
            let keys = Set(records.keys).union(before.records.keys).union(after.records.keys)
            let trashKeys = Set(trash.keys).union(before.trash.keys).union(after.trash.keys)
            return keys.sorted().filter {
                records[$0] != before.records[$0] && records[$0] != after.records[$0]
            }.map { "record \($0) is neither version" }
                + trashKeys.sorted().filter {
                    trash[$0] != before.trash[$0] && trash[$0] != after.trash[$0]
                }.map { "trash \($0) is neither version" }
        }
    }

    static func observe(_ archive: Archive) throws -> Observation {
        let root = archive.rootURL
        func json(_ value: some Encodable) throws -> String {
            String(decoding: try GeneaLogicJSON.encoder.encode(value), as: UTF8.self)
        }
        func digest(of url: URL) -> String {
            (try? Checksum.sha256Hex(ofFileAt: url)) ?? "absent"
        }

        var records: [String: String] = [:]
        try archive.withIndex { index in
            let slugs = try index.allSlugs()
            for artifact in try index.allArtifacts() {
                let slug = slugs[artifact.uid] ?? "?"
                let directory = ArchiveLayout.artifactDirectory(in: root, slug: slug)
                let bytes = artifact.files.map {
                    "\($0.uid.raw)=\(digest(of: directory.appendingPathComponent($0.path)))"
                }
                records[artifact.uid.raw] =
                    "\(slug) \(try json(artifact)) \(bytes.joined(separator: ","))"
            }
            for person in try index.allPersons() { records[person.uid.raw] = try json(person) }
            for relationship in try index.allRelationships() {
                records[relationship.uid.raw] = try json(relationship)
            }
            for link in try index.allLinks() { records[link.uid.raw] = try json(link) }
            for dismissal in try index.allDismissals() {
                records[dismissal.uid.raw] = try json(dismissal)
            }
        }

        var trash: [String: String] = [:]
        for (uid, entry) in TrashStore.entries(in: root) {
            let payload = TrashStore.payloadURL(uid: uid, in: root)
            let restorable =
                entry.kind == .artifact
                ? digest(of: payload.appendingPathComponent(ArchiveLayout.recordFileName))
                : digest(of: payload)
            trash[uid] = "\(try json(entry)) payload=\(restorable)"
        }
        return Observation(records: records, trash: trash)
    }

    // MARK: - The seed

    static func seed(at root: URL) throws -> (Archive, Seed) {
        let archive = try Archive.create(at: root)
        let census = try archive.addArtifact(
            .sample(
                title: "1910 census",
                personsMentioned: [
                    PersonMention(
                        localRef: "p1", nameAsRecorded: "Marcus Hanner", role: .subject,
                        informationQuality: .primary),
                    PersonMention(
                        localRef: "p2", nameAsRecorded: "Meir Hanner", role: .subject,
                        informationQuality: .primary),
                ]))
        let scan = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "scan.jpg", contents: "recto"),
            to: census.uid, role: .preservationMaster)
        let notes = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "notes.txt", contents: "transcribed"),
            to: census.uid, role: .transcript)
        let stray = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "blurry.jpg", contents: "blur"),
            to: census.uid, role: .accessCopy)
        _ = try archive.detachFile(stray.entry.uid, in: census.uid)

        let letter = try archive.addArtifact(.sample(title: "Letter from Lodz"))
        _ = try archive.attachFile(
            copyingFrom: TestSupport.makeSourceFile(named: "letter.jpg", contents: "dear"),
            to: letter.uid, role: .preservationMaster)
        _ = try archive.removeArtifact(letter.uid)

        let marcus = try archive.addPerson(.sample(given: "Marcus", surname: "Hanner"))
        let meir = try archive.addPerson(.sample(given: "Meir", surname: "Hanner"))
        let ruchla = try archive.addPerson(.sample(given: "Ruchla", surname: "Hanner"))
        let relationship = try archive.addRelationship(
            RelationshipDraft(type: .parentChild, person1Uid: marcus.uid, person2Uid: meir.uid))
        let link = try archive.link(
            MentionRef(artifact: census.uid, localRef: "p1"), to: marcus.uid)
        let dismissal = try archive.dismiss(.samePerson, between: meir.uid, and: ruchla.uid)

        return (
            archive,
            Seed(
                census: census.uid, scan: scan.entry.uid, notes: notes.entry.uid,
                trashedArtifact: letter.uid, trashedFile: stray.entry.uid,
                marcus: marcus.uid, meir: meir.uid, ruchla: ruchla.uid,
                relationship: relationship.uid, link: link.link.uid, dismissal: dismissal.uid)
        )
    }
}

extension IntegrityReport.Issue {
    /// What a crash may leave: a write the sentinel explains, or a stray copy.
    fileprivate var isCrashResidue: Bool {
        switch self {
        case .interruptedWrite, .unreferencedFile: true
        default: false
        }
    }

    fileprivate var isInterruptedWrite: Bool {
        if case .interruptedWrite = self { return true }
        return false
    }

    fileprivate var description: String { "\(self)" }
}

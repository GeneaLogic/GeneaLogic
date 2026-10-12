import Foundation
import GeneaLogicModel
import GeneaLogicTestSupport
import Testing

@testable import GeneaLogicArchive

/// **A rebuild agrees with the incremental path** — slice 66's property.
///
/// "The index is a rebuildable cache" (§5.1) is two code paths that must agree:
/// every mutation keeps the index current through `upsert`/`remove…`, and
/// `ArchiveIndex.rebuild(walking:)` regenerates it from the sidecars. Each
/// iteration seeds 65's small archive, runs a random sequence of public mutations
/// (plus out-of-band damage and its repair), then holds the index it ended with
/// against:
///
/// - **an in-place rebuild** — the dirty-marker path and **Rebuild Index**: the
///   derived tables are byte-identical, and the memory tables are untouched except
///   that `orphaned_record` loses the rows whose uid is live again;
/// - **a fresh rebuild** — `.index/` gone, then `open`: the derived tables are
///   byte-identical;
/// - **the disk** — every derived `json` is its sidecar's bytes (58's claim).
///
/// "Byte-identical" is literal: each table is a sorted multiset of every column's
/// type and hex bytes, so a re-encoding drift cannot hide behind decoded equality
/// and a column added later is compared without anyone listing it.
///
/// Uids are minted fresh on every run, so a failing iteration reproduces its
/// *operations* from the seed rather than its exact bytes — 65's terms too.
@Suite struct RebuildAgreementTests {

    // MARK: - The classification (fork a)

    /// A function of the sidecars and payload bytes: what a walk must reproduce.
    static let derivedTables: Set<String> = [
        "artifact", "person", "relationship", "link", "file", "place", "dismissal",
        "unreadable_record",
    ]

    /// What this index has *seen* rather than what the archive holds — settled
    /// against, written, replaced, deleted or abandoned here, or overruled by a
    /// merge — and the preserved copies of unreadable records. No walk can derive
    /// any of it, which is why a rebuild keeps it.
    static let memoryTables: Set<String> = [
        "meta", "settled_file", "superseded_file", "deleted_path", "abandoned_path",
        "contested_file", "orphaned_record",
    ]

    /// The tripwire: a table added without deciding which list it belongs to fails
    /// here, rather than silently dropping out of the comparison below.
    @Test func everyIndexTableIsClassified() throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)
        let db = try SQLiteDatabase(at: ArchiveLayout.indexDatabaseURL(in: root))
        var tables: Set<String> = []
        try db.query(
            try db.prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' "
                    + "AND name NOT LIKE 'sqlite_%';")
        ) { tables.insert(db.columnText($0, 0)) }

        #expect(Self.derivedTables.isDisjoint(with: Self.memoryTables))
        #expect(
            tables.subtracting(Self.derivedTables.union(Self.memoryTables)).isEmpty,
            "unclassified index tables — derived or memory?")
        #expect(Self.derivedTables.union(Self.memoryTables).subtracting(tables).isEmpty)
    }

    // MARK: - The property (forks b–e)

    /// 50 by default (fork e): an iteration is an archive, a sequence and two
    /// rebuilds. `GENEALOGIC_PROPERTY_ITERATIONS` overrides.
    static let defaultIterations = 50
    static let maxSequenceLength = 20

    @Test func aRebuildAgreesWithTheIncrementalPath() throws {
        let run = PropertyRun.fromEnvironment(defaultIterations: Self.defaultIterations)
        var succeeded: [String: Int] = [:]

        try run.forEach { rng, iteration in
            // Everything an iteration writes lives under one directory, removed at
            // the end: a soak is thousands of archives.
            let scratch = TestSupport.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let (archive, seed) = try WriteCutTests.seed(
                at: scratch.appendingPathComponent("archive.genea"))
            var world = World(
                archive: archive, seed: seed,
                sources: scratch.appendingPathComponent("sources", isDirectory: true))
            var log: [String] = []

            for _ in 0..<Int.random(in: 1...Self.maxSequenceLength, using: &rng) {
                // An operation with nothing to act on is re-picked, so a step is
                // spent on something whenever anything applies.
                for _ in 0..<Self.attemptsPerStep {
                    let operation = Self.pick(&rng)
                    do {
                        guard let detail = try operation.run(&world, &rng) else { continue }
                        log.append("\(operation.name)\(detail.isEmpty ? "" : " \(detail)")")
                        succeeded[operation.name, default: 0] += 1
                    } catch let error as ArchiveError
                        where error.isRefusal(of: operation.name, afterDamage: world.damaged)
                    {
                        // A refusal is an outcome too: it must leave the index agreeing.
                        log.append("\(operation.name) refused: \(error)")
                    } catch {
                        Issue.record("\(iteration): \(operation.name) threw \(error)\n\(log)")
                        return
                    }
                    break
                }
            }

            let differences = try Self.disagreements(
                of: archive, scratch: scratch.appendingPathComponent("fresh.genea"))
            if !differences.isEmpty {
                Issue.record(
                    """
                    \(iteration): the index disagrees with a rebuild
                    \(differences.joined(separator: "\n"))
                    operations:
                    \(log.joined(separator: "\n"))
                    """)
            }
        }

        // A sequence of refusals would pass vacuously, so the default run — the one
        // CI repeats, operation for operation — must land every operation at least
        // once. Under another seed the run is hunting, not guarding, and a rare
        // operation missing from it says nothing about the generator.
        if run.seed == PropertyRun.defaultSeed, run.iterations >= Self.defaultIterations {
            let neverLanded = Self.operations.map(\.name).filter { succeeded[$0] == nil }
            #expect(neverLanded.isEmpty, "operations that never succeeded: \(neverLanded)")
        }
    }

    // MARK: - What the property found

    /// `restoreFile` upserted the artifact before moving the bytes back (65's
    /// record-first reorder took the upsert with it), so a restored transcript's
    /// `search_text` was read off a path with nothing at it: its words were not
    /// found until something rebuilt the index.
    @Test func aRestoredTranscriptIsSearchableWithoutARebuild() throws {
        let root = TestSupport.makeTempDirectory()
        let (archive, seed) = try WriteCutTests.seed(at: root)
        let transcribed = ArtifactQuery(text: "transcribed")
        #expect(archive.artifacts(matching: transcribed).map(\.uid) == [seed.census])

        _ = try archive.detachFile(seed.notes, in: seed.census)
        #expect(archive.artifacts(matching: transcribed).isEmpty)

        _ = try archive.restoreFile(seed.notes)
        #expect(archive.artifacts(matching: transcribed).map(\.uid) == [seed.census])
        #expect(
            try Self.disagreements(
                of: archive,
                scratch: TestSupport.makeTempDirectory().appendingPathComponent("fresh"))
                == [])
    }

    // MARK: - The comparison

    /// Every way the index `archive` is holding disagrees with a rebuild or with
    /// the disk; empty if none. Leaves `archive`'s index rebuilt in place, and the
    /// fresh copy at `copy`.
    static func disagreements(of archive: Archive, scratch copy: URL) throws -> [String] {
        let root = archive.rootURL
        let databaseURL = ArchiveLayout.indexDatabaseURL(in: root)
        var differences: [String] = []

        // The incremental state, and what an in-place rebuild may do to memory.
        let incremental = try dump(databaseURL)
        let survivingOrphans = try dump(
            databaseURL, tables: ["orphaned_record"],
            where: "uid NOT IN (SELECT uid FROM artifact UNION ALL SELECT uid FROM person "
                + "UNION ALL SELECT uid FROM relationship UNION ALL SELECT uid FROM link "
                + "UNION ALL SELECT uid FROM dismissal)")
        differences += try sidecarDifferences(databaseURL, root: root)

        // Fresh first, so the copy is taken before the in-place rebuild touches
        // anything (it touches only `.index/`, which the copy drops — but the order
        // makes that not matter).
        try FileManager.default.copyItem(at: root, to: copy)
        try FileManager.default.removeItem(at: ArchiveLayout.indexContainerDirectory(in: copy))
        _ = try Archive.open(at: copy)
        let fresh = try dump(ArchiveLayout.indexDatabaseURL(in: copy))
        differences += compare(incremental, fresh, tables: derivedTables, label: "fresh rebuild")

        // In place, around the walker itself: `rebuildIndex()`'s commit
        // legitimately rewrites the witness in `meta`, which is not the walker's.
        let manifest = try GeneaLogicJSONCoding.decoder.decode(
            Manifest.self, from: Data(contentsOf: ArchiveLayout.manifestURL(in: root)))
        try archive.withIndex { index in
            _ = try index.rebuild(
                walking: root,
                manifestRecordPaths: RecordDiscovery.recordPaths(in: manifest),
                manifestVersion: manifest.schemaVersion)
        }
        let inPlace = try dump(databaseURL)
        differences += compare(
            incremental, inPlace, tables: derivedTables, label: "in-place rebuild")
        var expectedMemory = incremental
        expectedMemory["orphaned_record"] = survivingOrphans["orphaned_record"]
        differences += compare(
            expectedMemory, inPlace, tables: memoryTables, label: "in-place rebuild (memory)")

        return differences
    }

    typealias Dump = [String: [String]]

    /// Each table as a sorted multiset of rows, every column rendered as its
    /// storage class and hex bytes — exact for text with a NUL in it, which
    /// `quote()` is not, and for blobs.
    static func dump(
        _ databaseURL: URL, tables: Set<String> = derivedTables.union(memoryTables),
        where condition: String? = nil
    ) throws -> Dump {
        let db = try SQLiteDatabase(at: databaseURL)
        var result: Dump = [:]
        for table in tables {
            var columns: [String] = []
            try db.query(try db.prepare("PRAGMA table_info(\(table));")) {
                columns.append(db.columnText($0, 1))
            }
            let rendered = columns.map { "typeof(\($0)) || ':' || hex(\($0))" }
                .joined(separator: " || '|' || ")
            let filter = condition.map { " WHERE \($0)" } ?? ""
            var rows: [String] = []
            try db.query(try db.prepare("SELECT \(rendered) FROM \(table)\(filter);")) {
                rows.append(db.columnText($0, 0))
            }
            result[table] = rows.sorted()
        }
        return result
    }

    static func compare(_ expected: Dump, _ actual: Dump, tables: Set<String>, label: String)
        -> [String]
    {
        tables.sorted().compactMap { table in
            let lhs = expected[table] ?? [], rhs = actual[table] ?? []
            guard lhs != rhs else { return nil }
            // As multisets: `file` and `place` have no key, so a row present on
            // both sides a different number of times is a difference too.
            var balance: [String: Int] = [:]
            for row in lhs { balance[row, default: 0] += 1 }
            for row in rhs { balance[row, default: 0] -= 1 }
            let missing = balance.sorted { $0.key < $1.key }.flatMap {
                Array(repeating: $0.key, count: max(0, $0.value))
            }
            let extra = balance.sorted { $0.key < $1.key }.flatMap {
                Array(repeating: $0.key, count: max(0, -$0.value))
            }
            return "\(label): \(table) — only incremental: \(missing.map(decodeRow)); "
                + "only rebuilt: \(extra.map(decodeRow))"
        }
    }

    /// A dumped row made readable for a failure message.
    static func decodeRow(_ row: String) -> String {
        row.split(separator: "|", omittingEmptySubsequences: false).map { cell in
            let parts = cell.split(separator: ":", maxSplits: 1)
            let hex = parts.count > 1 ? String(parts[1]) : ""
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
                index = next
            }
            return String(decoding: bytes, as: UTF8.self).prefix(200).debugDescription
        }.joined(separator: " | ")
    }

    /// Every derived `json` that is not its sidecar's bytes.
    static func sidecarDifferences(_ databaseURL: URL, root: URL) throws -> [String] {
        let db = try SQLiteDatabase(at: databaseURL)
        var differences: [String] = []
        func check(_ sql: String, file: (String) -> URL) throws {
            try db.query(try db.prepare(sql)) { row in
                let url = file(db.columnText(row, 0))
                let onDisk = try? Data(contentsOf: url)
                if onDisk != db.columnData(row, 1) {
                    differences.append(
                        "json column is not the sidecar: "
                            + ArchiveLayout.relativePath(of: url, in: root))
                }
            }
        }
        try check("SELECT slug, json FROM artifact;") {
            ArchiveLayout.recordURL(in: root, slug: $0)
        }
        for (table, directory) in [
            ("person", ArchiveLayout.personsDirectory(in: root)),
            ("relationship", ArchiveLayout.relationshipsDirectory(in: root)),
            ("link", ArchiveLayout.linksDirectory(in: root)),
            ("dismissal", ArchiveLayout.dismissalsDirectory(in: root)),
        ] {
            try check("SELECT uid, json FROM \(table);") {
                directory.appendingPathComponent("\($0).json")
            }
        }
        return differences
    }

    // MARK: - The operations (fork d)

    /// What a sequence can act on: the tokens the undo paths take, which the
    /// archive cannot list, and the live subjects, which it can.
    ///
    /// **Every list is in first-seen order, never uid order** (`/code-review`). A
    /// uid is a UUIDv7 minted fresh each run, so two minted in one millisecond
    /// sort by their random bits, and the trash listings tie on a one-second
    /// `deletedAt` and fall back to directory order — either way the same seed
    /// picked a different subject on a rerun, and the reproduction line in a
    /// failure did not replay its operations. The order a sequence first meets a
    /// uid is a function of the operations alone; the seed's records are met in
    /// the order the seed made them.
    struct World {
        let archive: Archive
        let seed: WriteCutTests.Seed
        /// Where `hostileSourceFile` writes, inside the iteration's scratch.
        let sources: URL
        var fileChanges: [FileChange] = []
        var removedPersons: [Person] = []
        var removedRelationships: [Relationship] = []
        var removedLinks: [EvidenceLink] = []
        var removedDismissals: [Dismissal] = []
        var merges: [MergeDecision] = []
        /// Whether a `damage` step has run — the one thing that licenses 58's
        /// drift guard to refuse an engine write.
        var damaged = false
        /// Every artifact title this archive has held, in the order it got them,
        /// and the folder of every sidecar a `damage` step broke — so a new
        /// folder's name meets a live, trashed or damaged one (58b: the slug was
        /// unique against the index alone). The folder rather than the title,
        /// which `updateMetadata` may have changed since the slug was made from
        /// it (`/code-review`); an engine slug slugifies to itself.
        var titles = ["1910 census", "Letter from Lodz"]
        var damagedSlugs: [String] = []
        private var firstSeen: [String: Int] = [:]

        init(archive: Archive, seed: WriteCutTests.Seed, sources: URL) {
            self.archive = archive
            self.seed = seed
            self.sources = sources
            for uid in [
                seed.census.raw, seed.scan.raw, seed.notes.raw, seed.trashedFile.raw,
                seed.trashedArtifact.raw, seed.marcus.raw, seed.meir.raw, seed.ruchla.raw,
                seed.relationship.raw, seed.link.raw, seed.dismissal.raw,
            ] {
                firstSeen[uid] = firstSeen.count
            }
        }

        /// `items` in the order their uids were first seen. Uids new to this call
        /// are numbered in uid order — a tie only if one step minted two of them.
        mutating func ordered<T>(_ items: [T], by uid: (T) -> String) -> [T] {
            for id in items.map(uid).sorted() where firstSeen[id] == nil {
                firstSeen[id] = firstSeen.count
            }
            return items.sorted { firstSeen[uid($0)]! < firstSeen[uid($1)]! }
        }

        /// Every live artifact with its folder slug — one pass over the index,
        /// rather than a summary listing and then a decode per artifact.
        mutating func liveArtifacts() -> [(slug: String, artifact: Artifact)] {
            let rows = archive.withIndex { index in
                let slugs = (try? index.allSlugs()) ?? [:]
                return ((try? index.allArtifacts()) ?? []).map { (slugs[$0.uid] ?? "", $0) }
            }
            return ordered(rows) { $0.artifact.uid.raw }
        }

        mutating func artifacts() -> [ArtifactID] { liveArtifacts().map(\.artifact.uid) }

        mutating func persons() -> [PersonID] {
            ordered(archive.persons().map(\.uid)) { $0.raw }
        }

        mutating func relationships() -> [Relationship] {
            ordered(archive.relationships()) { $0.uid.raw }
        }

        mutating func links() -> [EvidenceLink] {
            ordered(archive.links(includeRejected: true)) { $0.uid.raw }
        }

        mutating func dismissals() -> [Dismissal] { ordered(archive.dismissals()) { $0.uid.raw } }

        mutating func trashedArtifacts() -> [ArtifactID] {
            ordered(archive.trashedArtifacts().map(\.uid)) { $0.raw }
        }

        mutating func trashedFiles() -> [FileID] {
            ordered(archive.trashedFiles().map(\.uid)) { $0.raw }
        }

        /// Every file of every live artifact, with its owner.
        mutating func files() -> [(artifact: ArtifactID, file: FileEntry)] {
            liveArtifacts().flatMap { row in row.artifact.files.map { (row.artifact.uid, $0) } }
        }

        /// Every mention of every live artifact.
        mutating func mentions() -> [MentionRef] {
            liveArtifacts().flatMap { row in
                row.artifact.personsMentioned.map {
                    MentionRef(artifact: row.artifact.uid, localRef: $0.localRef)
                }
            }
        }

        /// The sidecar of every live record.
        mutating func liveRecordURLs() -> [URL] {
            let root = archive.rootURL
            var urls = liveArtifacts().map { ArchiveLayout.recordURL(in: root, slug: $0.slug) }
            urls += persons().map {
                ArchiveLayout.personsDirectory(in: root).appendingPathComponent("\($0.raw).json")
            }
            urls += relationships().map {
                ArchiveLayout.relationshipsDirectory(in: root)
                    .appendingPathComponent("\($0.uid.raw).json")
            }
            urls += links().map {
                ArchiveLayout.linksDirectory(in: root).appendingPathComponent("\($0.uid.raw).json")
            }
            urls += dismissals().map {
                ArchiveLayout.dismissalsDirectory(in: root)
                    .appendingPathComponent("\($0.uid.raw).json")
            }
            return urls
        }
    }

    /// One operation. `run` returns `nil` when nothing it could act on exists (the
    /// step is skipped), or a short detail for the failure log.
    struct Operation: Sendable {
        let name: String
        /// Relative chance of being picked. The undo paths are weighted up: each
        /// needs an earlier operation to have left it something, so at an even
        /// weight they land a handful of times a run.
        var weight = 1
        let run: @Sendable (inout World, inout SeededGenerator) throws -> String?
    }

    static let attemptsPerStep = 8

    static func pick(_ rng: inout SeededGenerator) -> Operation {
        var ticket = Int.random(in: 0..<operations.reduce(0) { $0 + $1.weight }, using: &rng)
        for operation in operations {
            if ticket < operation.weight { return operation }
            ticket -= operation.weight
        }
        preconditionFailure("weights changed under the pick")
    }

    static let operations: [Operation] = [
        // Artifacts
        Operation(name: "addArtifact") { w, rng in
            let generated = Artifact.arbitrary(&rng)
            let title =
                Int.random(in: 0..<3, using: &rng) == 0
                ? w.titles.randomElement(using: &rng)! : generated.title
            let artifact = try w.archive.addArtifact(.sample(title: title))
            w.titles.append(title)
            return artifact.uid.raw
        },
        // Its own operation rather than a branch of the one above, so the
        // coverage check holds the default run to landing it: reuse alone met a
        // damaged folder twice in 500 iterations (58b).
        Operation(name: "addArtifactOverDamage", weight: 4) { w, rng in
            guard let title = w.damagedSlugs.randomElement(using: &rng) else { return nil }
            let artifact = try w.archive.addArtifact(.sample(title: title))
            w.titles.append(title)
            return artifact.uid.raw
        },
        Operation(name: "updateMetadata") { w, rng in
            guard let id = w.artifacts().randomElement(using: &rng) else { return nil }
            var generated = Artifact.arbitrary(&rng)
            try w.archive.updateMetadata(of: id) {
                generated.uid = $0.uid
                generated.files = $0.files  // `attachFile` and friends own `files[]`
                $0 = generated
            }
            return id.raw
        },
        Operation(name: "removeArtifact") { w, rng in
            guard let id = w.artifacts().randomElement(using: &rng) else { return nil }
            _ = try w.archive.removeArtifact(id)
            return id.raw
        },
        Operation(name: "restoreFromTrash", weight: 4) { w, rng in
            guard let id = w.trashedArtifacts().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.restoreFromTrash(id)
            return id.raw
        },
        Operation(name: "deleteFromTrash") { w, rng in
            guard let id = w.trashedArtifacts().randomElement(using: &rng)
            else { return nil }
            try w.archive.deleteFromTrash(id)
            return id.raw
        },
        Operation(name: "emptyTrash") { w, _ in
            try w.archive.emptyTrash()
            return ""
        },

        // Files
        Operation(name: "attachFile") { w, rng in
            guard let id = w.artifacts().randomElement(using: &rng) else { return nil }
            let source = try Self.hostileSourceFile(in: w.sources, &rng)
            let role: FileRole = Gen.closed(&rng)
            let attached = try w.archive.attachFile(copyingFrom: source, to: id, role: role)
            w.fileChanges.append(FileChange(artifactID: id, operation: .added(attached.entry)))
            return "\(role) \(attached.entry.path.debugDescription)"
        },
        Operation(name: "replaceFile") { w, rng in
            guard let (artifact, file) = w.files().randomElement(using: &rng) else { return nil }
            let source = try Self.hostileSourceFile(in: w.sources, &rng)
            w.fileChanges.append(
                try w.archive.replaceFile(file.uid, in: artifact, copyingFrom: source))
            return file.path.debugDescription
        },
        Operation(name: "detachFile") { w, rng in
            guard let (artifact, file) = w.files().randomElement(using: &rng) else { return nil }
            w.fileChanges.append(try w.archive.detachFile(file.uid, in: artifact))
            return file.path.debugDescription
        },
        Operation(name: "restoreFile", weight: 4) { w, rng in
            guard let id = w.trashedFiles().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.restoreFile(id)
            return id.raw
        },
        Operation(name: "deleteFileFromTrash") { w, rng in
            guard let id = w.trashedFiles().randomElement(using: &rng)
            else { return nil }
            try w.archive.deleteFileFromTrash(id)
            return id.raw
        },
        Operation(name: "setFileRole") { w, rng in
            guard let (artifact, file) = w.files().randomElement(using: &rng) else { return nil }
            let role: FileRole = Gen.closed(&rng)
            _ = try w.archive.setFileRole(file.uid, in: artifact, to: role)
            return "\(file.path.debugDescription) → \(role)"
        },
        Operation(name: "revert", weight: 4) { w, rng in
            guard !w.fileChanges.isEmpty else { return nil }
            let change = w.fileChanges.remove(
                at: Int.random(in: 0..<w.fileChanges.count, using: &rng))
            w.fileChanges.append(try w.archive.revert(change))
            return "\(change.operation)"
        },

        // Persons
        Operation(name: "addPerson") { w, rng in
            let generated = Person.arbitrary(&rng)
            let person = try w.archive.addPerson(
                PersonDraft(names: generated.names, facts: generated.facts))
            return person.uid.raw
        },
        Operation(name: "updatePerson") { w, rng in
            guard let id = w.persons().randomElement(using: &rng) else { return nil }
            var generated = Person.arbitrary(&rng)
            _ = try w.archive.updatePerson(id) {
                generated.uid = $0.uid
                $0 = generated
            }
            return id.raw
        },
        Operation(name: "removePerson") { w, rng in
            guard let id = w.persons().randomElement(using: &rng) else { return nil }
            w.removedPersons.append(try w.archive.removePerson(id))
            return id.raw
        },
        Operation(name: "restorePerson", weight: 4) { w, rng in
            guard !w.removedPersons.isEmpty else { return nil }
            let person = w.removedPersons.remove(
                at: Int.random(in: 0..<w.removedPersons.count, using: &rng))
            try w.archive.restorePerson(person)
            return person.uid.raw
        },
        Operation(name: "mergePersons") { w, rng in
            let persons = w.persons()
            guard persons.count >= 2 else { return nil }
            let pair = persons.shuffled(using: &rng).prefix(2)
            w.merges.append(try w.archive.mergePersons(pair.first!, into: pair.last!))
            return "\(pair.first!.raw) into \(pair.last!.raw)"
        },
        Operation(name: "revertMerge", weight: 4) { w, rng in
            guard !w.merges.isEmpty else { return nil }
            let decision = w.merges.remove(at: Int.random(in: 0..<w.merges.count, using: &rng))
            try w.archive.revertMerge(decision)
            return ""
        },

        // Relationships
        Operation(name: "addRelationship") { w, rng in
            guard let p1 = w.persons().randomElement(using: &rng),
                let p2 = w.persons().randomElement(using: &rng)
            else { return nil }
            let generated = Relationship.arbitrary(&rng)
            let relationship = try w.archive.addRelationship(
                RelationshipDraft(
                    type: generated.type, person1Uid: p1, person2Uid: p2,
                    facts: generated.facts))
            return relationship.uid.raw
        },
        Operation(name: "updateRelationship") { w, rng in
            guard let id = w.relationships().randomElement(using: &rng)?.uid
            else { return nil }
            var generated = Relationship.arbitrary(&rng)
            _ = try w.archive.updateRelationship(id) {
                generated.uid = $0.uid
                generated.person1Uid = $0.person1Uid
                generated.person2Uid = $0.person2Uid
                $0 = generated
            }
            return id.raw
        },
        Operation(name: "removeRelationship") { w, rng in
            guard let id = w.relationships().randomElement(using: &rng)?.uid
            else { return nil }
            w.removedRelationships.append(try w.archive.removeRelationship(id))
            return id.raw
        },
        Operation(name: "restoreRelationship", weight: 4) { w, rng in
            guard !w.removedRelationships.isEmpty else { return nil }
            let relationship = w.removedRelationships.remove(
                at: Int.random(in: 0..<w.removedRelationships.count, using: &rng))
            try w.archive.restoreRelationship(relationship)
            return relationship.uid.raw
        },

        // Links and verdicts
        Operation(name: "link") { w, rng in
            guard let mention = w.mentions().randomElement(using: &rng),
                let person = w.persons().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.link(mention, to: person)
            return "\(mention.localRef.debugDescription) → \(person.raw)"
        },
        Operation(name: "unlink") { w, rng in
            guard let id = w.links().randomElement(using: &rng)?.uid
            else { return nil }
            w.removedLinks.append(try w.archive.unlink(id))
            return id.raw
        },
        Operation(name: "restoreLink", weight: 4) { w, rng in
            guard !w.removedLinks.isEmpty else { return nil }
            let link = w.removedLinks.remove(
                at: Int.random(in: 0..<w.removedLinks.count, using: &rng))
            try w.archive.restoreLink(link)
            return link.uid.raw
        },
        Operation(name: "confirm") { w, rng in
            guard let mention = w.mentions().randomElement(using: &rng),
                let person = w.persons().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.confirm(mention, as: person)
            return "\(mention.localRef.debugDescription) as \(person.raw)"
        },
        Operation(name: "reject") { w, rng in
            guard let mention = w.mentions().randomElement(using: &rng),
                let person = w.persons().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.reject(mention, as: person)
            return "\(mention.localRef.debugDescription) as \(person.raw)"
        },

        // Dismissals
        Operation(name: "dismiss") { w, rng in
            guard let p1 = w.persons().randomElement(using: &rng),
                let p2 = w.persons().randomElement(using: &rng)
            else { return nil }
            let subject: DismissalSubject = Gen.open(&rng)
            _ = try w.archive.dismiss(subject, between: p1, and: p2)
            return "\(subject)"
        },
        Operation(name: "undismiss") { w, rng in
            guard let dismissal = w.dismissals().randomElement(using: &rng)
            else { return nil }
            _ = try w.archive.undismiss(
                dismissal.subject, between: dismissal.person1Uid, and: dismissal.person2Uid)
            return dismissal.uid.raw
        },
        Operation(name: "removeDismissal") { w, rng in
            guard let id = w.dismissals().randomElement(using: &rng)?.uid
            else { return nil }
            w.removedDismissals.append(try w.archive.removeDismissal(id))
            return id.raw
        },
        Operation(name: "restoreDismissal", weight: 4) { w, rng in
            guard !w.removedDismissals.isEmpty else { return nil }
            let dismissal = w.removedDismissals.remove(
                at: Int.random(in: 0..<w.removedDismissals.count, using: &rng))
            try w.archive.restoreDismissal(dismissal)
            return dismissal.uid.raw
        },

        // Whole-archive
        Operation(name: "rebaseline") { w, _ in
            try w.archive.rebaseline()
            return ""
        },
        Operation(name: "rebuildIndex") { w, _ in
            _ = try w.archive.rebuildIndex()
            return ""
        },

        // Out of band: damage, and what the engine offers for it
        Operation(name: "damage") { w, rng in
            guard let url = w.liveRecordURLs().randomElement(using: &rng) else { return nil }
            let root = w.archive.rootURL
            if let row = w.liveArtifacts().first(where: {
                ArchiveLayout.recordURL(in: root, slug: $0.slug) == url
            }) {
                w.damagedSlugs.append(row.slug)
            }
            let bytes = try Data(contentsOf: url)
            try bytes.prefix(bytes.count / 2).write(to: url)
            w.damaged = true
            _ = try w.archive.rebuildIndex()
            return ArchiveLayout.relativePath(of: url, in: w.archive.rootURL)
        },
        Operation(name: "repairRecord", weight: 4) { w, rng in
            let paths = try w.archive.withIndex { try $0.unreadableRecordPaths() }
            guard let path = paths.randomElement(using: &rng) else { return nil }
            _ = try w.archive.repairRecord(
                atPath: path, acceptingInexactRestore: Bool.random(using: &rng))
            return path
        },
        Operation(name: "discardPreservedRecord", weight: 4) { w, rng in
            guard let path = try w.archive.preservedRecordPaths().randomElement(using: &rng)
            else { return nil }
            try w.archive.discardPreservedRecord(atPath: path)
            return path
        },
    ]

    /// A source file for `attachFile`/`replaceFile`: a hostile name where the file
    /// system will take one, and bytes a transcript reader must cope with.
    static func hostileSourceFile(in sources: URL, _ rng: inout SeededGenerator) throws -> URL {
        let contents: Data
        switch Int.random(in: 0..<6, using: &rng) {
        case 0: contents = Data()
        case 1: contents = Data([0xFF, 0xFE, 0x00, 0x41])  // not UTF-8
        case 2: contents = Data("before\u{0}after".utf8)  // a NUL
        case 3: contents = Data([0xEF, 0xBB, 0xBF]) + Data("byte order mark".utf8)
        case 4: contents = Data(String(repeating: "long line ", count: 2_000).utf8)
        default: contents = Data(Gen.string(&rng).utf8)
        }
        let extensions = ["txt", "jpg", "pdf", ""]
        let ext = extensions.randomElement(using: &rng)!
        let directory = sources.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for stem in [Gen.string(&rng), Gen.word(&rng)] {
            let name = ext.isEmpty ? stem : "\(stem).\(ext)"
            let url = directory.appendingPathComponent(name)
            if !stem.isEmpty, !stem.contains("/"), (try? contents.write(to: url)) != nil {
                return url
            }
        }
        let url = directory.appendingPathComponent("source.\(ext)")
        try contents.write(to: url)
        return url
    }
}

extension ArchiveError {
    /// A precondition the generator cannot see refused the operation: a subject it
    /// picked is gone by the time the operation looks (a file whose artifact went
    /// to the trash, a revert of a change already undone), or a pair it drew is
    /// one person twice, a repair of a record whose copy was already discarded.
    /// After damage, 58's guard refusing to write over a sidecar that changed on
    /// disk is the guard working — **except from an operation that makes a new
    /// folder** (58b): `addArtifact` and `restoreFromTrash` overwrite nothing, so a
    /// drift refusal from either is a folder name it should never have picked.
    /// Anything else is the engine failing, and fails the property even when the
    /// index still agrees (`/code-review`, 66).
    fileprivate func isRefusal(of operation: String, afterDamage damaged: Bool) -> Bool {
        switch self {
        case .artifactNotFound, .trashEntryNotFound, .fileTrashEntryNotFound, .fileNotFound,
            .personNotFound, .relationshipNotFound, .evidenceLinkNotFound, .dismissalNotFound,
            .mentionNotFound, .cannotDismissPersonAgainstItself, .cannotMergePersonIntoItself,
            .repairNotByteExact, .noPreservedCopy:
            true
        case .recordDriftedOnDisk:
            damaged
                && !["addArtifact", "addArtifactOverDamage", "restoreFromTrash"].contains(operation)
        default:
            false
        }
    }
}

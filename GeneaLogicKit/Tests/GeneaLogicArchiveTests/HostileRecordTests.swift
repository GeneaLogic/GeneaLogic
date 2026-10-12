import Foundation
@testable import GeneaLogicArchive
import GeneaLogicModel
import GeneaLogicTestSupport
import Testing

/// Hostile bytes at the archive level (slice 63, fork d): a mutated sidecar
/// in place, `.index/` discarded, and the archive must **open**, verify, and rebuild —
/// with the mutated path in **exactly one** of two states: indexed (queryable, equal
/// to what the decoder returns for those bytes) or reported. Never both, never
/// neither. 55 proved this for five hand-picked shapes; this is the same claim over
/// the mutator's families, under a smaller budget than the decoder-level property
/// because each iteration is an open with a rebuild.
///
/// "Reported" for a conclusion has two shapes: a file that cannot be decoded is
/// `.unreadableRecord`; one that decodes to a uid other than its file name is
/// `.misnamedRecord` (50c) — the mutation moved the record out from under its name,
/// and the archive says so rather than serving it. Since 64 a mutated `schemaVersion`
/// adds two more: a stamp ahead of the manifest — or unparsable, which compares as
/// ahead — **refuses the open** (the one file the archive may close over, spec §8), and
/// a stamp behind it is skipped and reported with `.olderFormat`.
@Suite("Hostile records", .timeLimit(.minutes(5))) struct HostileRecordTests {

    /// Mutants per iteration; each is one open-with-rebuild.
    private static let mutantsPerIteration = 2

    private enum Outcome: Equatable, Comparable {
        case indexed
        case unreadable
        case misnamed
        /// `open` threw `archiveNewerThanBuild` naming this path (slice 64).
        case refused
        /// Reported `.unreadableRecord` with `.olderFormat` (slice 64).
        case olderFormat
        /// Never expected here — one file cannot be a copy of a record the archive
        /// holds elsewhere — so an observation of it is a wrong finding, which is
        /// what the case-only uid mutation produced on APFS before the fix.
        case conflictingCopy
    }

    /// Runs the property for one record kind. `path` is where a value's record lives
    /// (archive-relative); `lookup` reads it back from the opened archive.
    private static func check<T: Codable & Equatable & Arbitrary>(
        _ type: T.Type,
        path: (T) -> String,
        version: (T) -> String,
        lookup: @escaping (Archive, T) -> T?,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let root = TestSupport.makeTempDirectory()
        _ = try Archive.create(at: root)

        PropertyRun.fromEnvironment.forEach { rng, iteration in
            let value = T.arbitrary(&rng)
            let relativePath = path(value)
            let fileURL = root.appendingPathComponent(relativePath)
            let document: JSONDocument
            do {
                document = try JSONDocument(try GeneaLogicJSON.encoder.encode(value))
            } catch {
                Issue.record(
                    "\(T.self): could not encode — \(error) — \(iteration)",
                    sourceLocation: sourceLocation)
                return
            }

            for _ in 0..<mutantsPerIteration {
                let mutant = JSONMutator.random(document, &rng)
                do {
                    try FileManager.default.createDirectory(
                        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try mutant.bytes.write(to: fileURL)
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent(".index"))

                    let decoded = try? GeneaLogicJSON.decoder.decode(T.self, from: mutant.bytes)
                    let expected: Outcome
                    if let decoded {
                        if SchemaVersion.isNewer(version(decoded), than: SchemaVersion.current) {
                            expected = .refused
                        } else if path(decoded) != relativePath {
                            expected = .misnamed
                        } else if SchemaVersion.isNewer(
                            SchemaVersion.current, than: version(decoded))
                        {
                            expected = .olderFormat
                        } else {
                            expected = .indexed
                        }
                    } else {
                        expected = .unreadable
                    }

                    let archive: Archive
                    do {
                        archive = try Archive.open(at: root)
                    } catch ArchiveError.archiveNewerThanBuild(let p, _, _) where p == relativePath
                    {
                        #expect(
                            expected == .refused,
                            "\(T.self) [\(mutant)]: refused, expected \(expected) — \(iteration)",
                            sourceLocation: sourceLocation)
                        try? FileManager.default.removeItem(at: fileURL)
                        continue
                    }
                    #expect(
                        expected != .refused,
                        "\(T.self) [\(mutant)]: opened, expected a refusal — \(iteration)",
                        sourceLocation: sourceLocation)
                    let report = try archive.verifyIntegrity()
                    let skipped = try archive.rebuildIndex()

                    var observed: Set<Outcome> = []
                    if let decoded, lookup(archive, decoded) == decoded {
                        observed.insert(.indexed)
                    }
                    for issue in report.issues {
                        switch issue {
                        case .unreadableRecord(let p, .undecodable) where p == relativePath:
                            observed.insert(.unreadable)
                        case .unreadableRecord(let p, .olderFormat) where p == relativePath:
                            observed.insert(.olderFormat)
                        case .misnamedRecord(let p, _) where p == relativePath:
                            observed.insert(.misnamed)
                        case .conflictingCopy(let p) where p == relativePath:
                            observed.insert(.conflictingCopy)
                        default:
                            break
                        }
                    }
                    let disagreement =
                        "\(T.self) [\(mutant)]: expected \(expected), archive says "
                        + "\(observed.sorted()) — \(iteration)"
                    #expect(
                        observed == [expected], Comment(rawValue: disagreement),
                        sourceLocation: sourceLocation)
                    #expect(
                        skipped.contains(relativePath)
                            == (expected == .unreadable || expected == .olderFormat),
                        "\(T.self) [\(mutant)]: rebuildIndex disagrees with verify — \(iteration)",
                        sourceLocation: sourceLocation)
                } catch {
                    Issue.record(
                        "\(T.self) [\(mutant)]: the archive threw \(error) — \(iteration)",
                        sourceLocation: sourceLocation)
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }

    // MARK: - One property per record kind

    /// An artifact's folder name is a free slug, so the file's path never depends on
    /// the uid inside it and a mutated uid is still indexed — just under that uid.
    @Test func artifact() throws {
        try Self.check(
            Artifact.self,
            path: { _ in "artifacts/mutant/record.json" },
            version: { $0.schemaVersion },
            lookup: { $0.artifact(withID: $1.uid) })
    }

    @Test func person() throws {
        try Self.check(
            Person.self,
            path: { "conclusions/persons/\($0.uid.raw).json" },
            version: { $0.schemaVersion },
            lookup: { $0.person(withID: $1.uid) })
    }

    @Test func relationship() throws {
        try Self.check(
            Relationship.self,
            path: { "conclusions/relationships/\($0.uid.raw).json" },
            version: { $0.schemaVersion },
            lookup: { $0.relationship(withID: $1.uid) })
    }

    @Test func evidenceLink() throws {
        try Self.check(
            EvidenceLink.self,
            path: { "conclusions/links/\($0.uid.raw).json" },
            version: { $0.schemaVersion },
            lookup: { $0.evidenceLink(withID: $1.uid) })
    }

    @Test func dismissal() throws {
        try Self.check(
            Dismissal.self,
            path: { "conclusions/dismissals/\($0.uid.raw).json" },
            version: { $0.schemaVersion },
            lookup: { archive, value in archive.dismissals().first { $0.uid == value.uid } })
    }

    // MARK: - The manifest

    /// A mutated `manifest.json` has no skip path (fork e). The contract is narrower:
    /// `open` either succeeds — and then `verifyIntegrity()` completes and says
    /// whatever the damage implies — or throws `corruptManifest`, or 64's version
    /// refusal for a mutated `schemaVersion`. Anything else thrown is a failure, and
    /// a trap is the failure the whole slice exists to rule out.
    @Test func manifest() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        _ = try archive.addArtifact(.sample(title: "One"))
        _ = try archive.addPerson(.sample())
        let manifestURL = root.appendingPathComponent("manifest.json")
        let pristine = try Data(contentsOf: manifestURL)
        let document = try JSONDocument(pristine)

        PropertyRun.fromEnvironment.forEach { rng, iteration in
            for _ in 0..<Self.mutantsPerIteration {
                let mutant = JSONMutator.random(document, &rng)
                do {
                    try mutant.bytes.write(to: manifestURL)
                    try? FileManager.default.removeItem(
                        at: root.appendingPathComponent(".index"))
                    let opened = try Archive.open(at: root)
                    _ = try opened.verifyIntegrity()
                    _ = try opened.rebuildIndex()
                } catch ArchiveError.corruptManifest {
                    // The refusal, with its own wording — see `CorruptManifestTests`.
                } catch ArchiveError.archiveNewerThanBuild, ArchiveError.needsUpgrade,
                    ArchiveError.noUpgradePath
                {
                    // A mutated `schemaVersion` that still decodes is 64's refusal.
                } catch {
                    Issue.record("manifest [\(mutant)]: the archive threw \(error) — \(iteration)")
                }
                try? pristine.write(to: manifestURL)
            }
        }
    }
}

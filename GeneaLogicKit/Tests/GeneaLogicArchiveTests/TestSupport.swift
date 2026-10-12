import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// Shared test scaffolding: every test gets its own throwaway directory
/// (ARCHITECTURE.md "the archive is a directory package, edited in place" —
/// tests must never share or pollute each other's archives).
enum TestSupport {
    /// What is at one path, as `snapshotOutsideIndex` records it.
    enum Node: Equatable {
        case file(Data)
        case directory
        case symlink(to: String)
    }

    /// Everything outside `.index/`, by relative path — files with their bytes,
    /// and folders and symlinks too, so a refusal that leaves an empty folder
    /// (`.damaged/`) behind is caught. What a refusal must leave exactly as it
    /// found it.
    static func snapshotOutsideIndex(_ root: URL) throws -> [String: Node] {
        let fm = FileManager.default
        var snapshot: [String: Node] = [:]
        for case let relative as String in fm.enumerator(atPath: root.path)! {
            if relative == ".index" || relative.hasPrefix(".index/") { continue }
            let url = root.appendingPathComponent(relative)
            switch try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType {
            case .typeDirectory?: snapshot[relative] = .directory
            case .typeSymbolicLink?:
                snapshot[relative] = .symlink(to: try fm.destinationOfSymbolicLink(atPath: url.path))
            default: snapshot[relative] = .file(try Data(contentsOf: url))
            }
        }
        return snapshot
    }

    /// A test-local stand-in for `Slug.normalizedForComparison` (internal to
    /// `GeneaLogicArchive`, not visible here): case-folded + Unicode-NFC, the
    /// same collision-comparison key the engine uses (ARCHITECTURE.md §4.2.1).
    /// Tests use this to assert that two on-disk names the engine produced are
    /// — or aren't — the "same" name under the engine's own collision rules,
    /// without depending on the engine's exact disambiguation strings.
    static func normalizedForComparison(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// Creates a fresh, empty temporary directory under the system temp
    /// directory, named uniquely per call, and returns its URL. Callers are
    /// responsible for the directory's lifetime — tests rely on the OS to clean
    /// up `NSTemporaryDirectory()` rather than removing it themselves, mirroring
    /// the rest of the suite's "don't fight the platform" style.
    static func makeTempDirectory(function: String = #function) -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let safeName = function.replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
        let url = base.appendingPathComponent(
            "GeneaLogicArchiveTests-\(safeName)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Lands `paths` from `source` on `destination`, the way a sync provider
    /// delivers part of another machine's work: each path is replaced by the
    /// source's copy. Stepping the paths one call at a time is how the delivery
    /// tests reach the in-flight states. **A path the source does not have
    /// throws**, so a mistyped path fails rather than quietly delivering a
    /// deletion — that is `deliverRemoval(_:to:)`, asked for by name.
    static func deliver(_ paths: [String], from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for path in paths {
            let target = destination.appendingPathComponent(path)
            try? fm.removeItem(at: target)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    /// The deletion half of a delivery: removes `paths` from `destination`,
    /// which must have them (slice 58c).
    static func deliverRemoval(_ paths: [String], to destination: URL) throws {
        for path in paths {
            try FileManager.default.removeItem(at: destination.appendingPathComponent(path))
        }
    }

    /// A throwaway source file (for `attachFile`/`replaceFile`) with the given
    /// contents, written into its own fresh temp directory so concurrent tests
    /// never collide on a shared filename.
    static func makeSourceFile(named name: String = "source.txt", contents: String = "hello")
        throws -> URL
    {
        let directory = makeTempDirectory(function: "source-\(UUID().uuidString)")
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - Convenience draft factories

extension ArtifactDraft {
    /// A minimal-but-realistic draft for tests that don't care about the
    /// specific descriptive fields, just that an artifact exists.
    static func sample(
        title: String = "1920 US Census – Smith Family",
        mediaType: MediaType = .image,
        // Optional since 46b, but the default stays `.census` so every existing caller
        // keeps the artifact it was written against.
        sourceAuthorityTier: SourceAuthorityTier? = .census,
        personsMentioned: [PersonMention] = [],
        externalIdentifiers: [ExternalIdentifier] = [],
        events: [Event] = [],
        locations: [Location] = [],
        tags: [String] = [],
        transcript: String? = nil,
        notes: String? = nil
    ) -> ArtifactDraft {
        ArtifactDraft(
            title: title,
            mediaType: mediaType,
            sourceAuthorityTier: sourceAuthorityTier,
            events: events,
            personsMentioned: personsMentioned,
            locations: locations,
            transcript: transcript,
            externalIdentifiers: externalIdentifiers,
            tags: tags,
            notes: notes
        )
    }
}

extension PersonDraft {
    static func sample(given: String = "John", surname: String = "Smith") -> PersonDraft {
        PersonDraft(given: given, surname: surname)
    }
}

/// A `MetadataExtractor` stub for the embedded-metadata seam tests
/// (ARCHITECTURE.md §6.4): returns canned, deterministic `EmbeddedMetadata`
/// regardless of the file's actual bytes, so the test asserts the *plumbing*
/// (capture → surfaced via `AttachedFile.embeddedMetadata`, never written to a
/// genealogical field) without depending on any real extraction library.
struct StubMetadataExtractor: MetadataExtractor {
    let metadata: EmbeddedMetadata

    init(metadata: EmbeddedMetadata = StubMetadataExtractor.sampleMetadata) {
        self.metadata = metadata
    }

    func extract(from url: URL) throws -> EmbeddedMetadata {
        metadata
    }

    static var sampleMetadata: EmbeddedMetadata {
        EmbeddedMetadata(entries: [
            EmbeddedMetadataKeyValue(
                key: EmbeddedMetadataKey(namespace: "exif", name: "DateTimeOriginal"),
                value: .string("2026:06:07 12:00:00")
            ),
            EmbeddedMetadataKeyValue(
                key: EmbeddedMetadataKey(namespace: "exif", name: "PixelXDimension"),
                value: .number(4000)
            ),
        ])
    }
}

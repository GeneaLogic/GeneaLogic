import Foundation
import GeneaLogicArchive
import GeneaLogicModel
import Testing

/// The embedded-metadata extraction seam (ARCHITECTURE.md §6.4,
/// `EmbeddedMetadata.swift`): an injected `MetadataExtractor`'s output must be
/// surfaced via `AttachedFile.embeddedMetadata`, and — the governing rule —
/// **never** written into any genealogical field (`events`, `locations`,
/// `personsMentioned`, …).
@Suite struct EmbeddedMetadataSeamTests {

    @Test func injectedExtractorOutputIsSurfacedOnAttachedFile() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Photo with EXIF"))

        let source = try TestSupport.makeSourceFile(named: "photo.jpg", contents: "fake jpeg bytes")
        let extractor = StubMetadataExtractor()

        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .preservationMaster, extractor: extractor)

        let metadata = try #require(attached.embeddedMetadata)
        #expect(!metadata.isEmpty)
        #expect(
            metadata[EmbeddedMetadataKey(namespace: "exif", name: "DateTimeOriginal")]
                == .string("2026:06:07 12:00:00"))
        #expect(
            metadata[EmbeddedMetadataKey(namespace: "exif", name: "PixelXDimension")]
                == .number(4000))
    }

    @Test func noExtractorMeansNilEmbeddedMetadata() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let artifact = try archive.addArtifact(.sample(title: "Photo without extractor"))
        let source = try TestSupport.makeSourceFile(named: "photo.jpg")

        let attached = try archive.attachFile(
            copyingFrom: source, to: artifact.uid, role: .accessCopy)

        #expect(attached.embeddedMetadata == nil)
    }

    /// The governing rule under direct test: even though the stub extractor
    /// returns an `exif:DateTimeOriginal` that — naively applied — would look
    /// like a plausible event date, `attachFile` must not write it (or anything
    /// else the extractor produced) into `events`, `locations`,
    /// `personsMentioned`, or any other genealogical field. The captured value
    /// is surfaced ONLY via the in-memory `AttachedFile.embeddedMetadata` return
    /// — never persisted into `record.json` (there is no field to persist it
    /// into; see `EmbeddedMetadata.swift`'s "no persisted field" note).
    @Test func extractorOutputNeverWritesAnyGenealogicalField() throws {
        let root = TestSupport.makeTempDirectory()
        let archive = try Archive.create(at: root)
        let originalArtifact = try archive.addArtifact(
            .sample(
                title: "Untouched by extraction",
                events: [Event(type: "Census", date: "1920-01-15", location: "Cook County")],
                notes: "original notes"
            ))

        let source = try TestSupport.makeSourceFile(named: "photo.jpg", contents: "fake jpeg bytes")
        let extractor = StubMetadataExtractor()
        _ = try archive.attachFile(
            copyingFrom: source, to: originalArtifact.uid, role: .preservationMaster,
            extractor: extractor)

        let after = try #require(archive.artifact(withID: originalArtifact.uid))

        // Genealogical fields are byte-for-byte unchanged...
        #expect(after.events == originalArtifact.events)
        #expect(after.locations == originalArtifact.locations)
        #expect(after.personsMentioned == originalArtifact.personsMentioned)
        #expect(after.notes == originalArtifact.notes)
        #expect(after.transcript == originalArtifact.transcript)

        // ...in particular, the suspicious-looking EXIF date the stub returns
        // (`"2026:06:07 12:00:00"`, today's date — exactly the "auto-applying
        // capture-time EXIF would silently corrupt the archive" scenario the
        // governing rule exists to prevent) appears nowhere in the persisted
        // record's genealogical surface.
        let suspiciousValue = "2026:06:07"
        #expect(!after.events.contains { ($0.date ?? "").contains(suspiciousValue) })
        #expect(!(after.notes ?? "").contains(suspiciousValue))
        #expect(!(after.transcript ?? "").contains(suspiciousValue))

        // And re-reading the on-disk sidecar confirms nothing was persisted
        // there either — `EmbeddedMetadata` has no field in `Artifact`/`FileEntry`
        // to land in.
        let slug = try #require(archive.artifacts().first?.slug)
        let recordURL = root.appendingPathComponent("artifacts/\(slug)/record.json")
        let recordData = try Data(contentsOf: recordURL)
        let rawJSON = String(decoding: recordData, as: UTF8.self)
        #expect(!rawJSON.contains("DateTimeOriginal"))
        #expect(!rawJSON.contains("embeddedMetadata"))
    }
}

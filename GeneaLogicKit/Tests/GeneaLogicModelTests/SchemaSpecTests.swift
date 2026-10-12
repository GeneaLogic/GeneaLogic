import Foundation
import GeneaLogicModel
import Testing

/// Guards that the human-readable **format spec** (`genealogic-archive-1.0.md`) stays
/// truthful about the on-disk format — a standing tripwire so "touch the archive format,
/// forget the spec" fails CI instead of shipping a lying spec inside every archive.
///
/// Two independent failure modes are covered:
///
/// 1. **Copy drift.** The spec exists in *two* checked-in places that MUST stay
///    byte-identical: the docs copy (`schema/…md`) and the bundled resource
///    (`Sources/GeneaLogicArchive/Resources/…md`) that `Archive.create` ships into every
///    archive via `Bundle.module`. Editing one and not the other would ship a spec that
///    disagrees with the reference docs.
///
/// 2. **Model ↔ spec drift.** Every stored field of every persisted record type must be
///    documented *in that record's own section* of the spec. This is the check that would
///    have caught slice 43 adding `Relationship.facts` without documenting it — a global
///    "does the word appear anywhere" check wouldn't (the label `facts` already appears
///    under Person §6.2), so the coverage is deliberately **section-scoped**.
///
/// The reflection is intentionally *direct* (top-level stored properties only, not
/// recursed): nested value types (Event, Location, PersonMention, MatchDimension, …) are
/// documented inline in their owner's section as prose, which doesn't section-scope
/// cleanly. The high-value, low-brittleness guarantee is on the record types that get
/// their own sidecar/section — exactly where an added field slips through undocumented.
@Suite("Schema spec consistency") struct SchemaSpecTests {

    // MARK: - Locating the two copies

    /// The `GeneaLogicKit/` package root, derived from this test file's own path so the
    /// test needs no bundled resource and works identically on macOS + the Linux CI
    /// container (both run from the checked-out repo).
    private static var kitRoot: URL {
        URL(fileURLWithPath: #filePath)  // …/Tests/GeneaLogicModelTests/SchemaSpecTests.swift
            .deletingLastPathComponent()  // …/Tests/GeneaLogicModelTests
            .deletingLastPathComponent()  // …/Tests
            .deletingLastPathComponent()  // …/GeneaLogicKit
    }

    private static let specFileName = "genealogic-archive-1.0.md"

    private static var docsCopyURL: URL {
        kitRoot.appendingPathComponent("schema/\(specFileName)")
    }

    private static var resourceCopyURL: URL {
        kitRoot.appendingPathComponent(
            "Sources/GeneaLogicArchive/Resources/\(specFileName)")
    }

    // MARK: - 1. The two copies never drift

    @Test("The docs copy and the shipped-resource copy of the spec are byte-identical")
    func schemaCopiesAreByteIdentical() throws {
        let docs = try Data(contentsOf: Self.docsCopyURL)
        let resource = try Data(contentsOf: Self.resourceCopyURL)
        #expect(
            docs == resource,
            """
            The two copies of \(Self.specFileName) have diverged. Any edit to the format \
            spec must be applied to BOTH schema/\(Self.specFileName) and \
            Sources/GeneaLogicArchive/Resources/\(Self.specFileName) (the latter is what \
            Archive.create ships inside every archive).
            """)
    }

    // MARK: - 2. Every record field is documented in its own section

    /// One persisted record type: a sample instance (to reflect its stored-property
    /// names) plus a distinctive substring of its spec section's heading line.
    private struct RecordType {
        let name: String
        let sample: Any
        let headingContains: String
    }

    private static var recordTypes: [RecordType] {
        [
            RecordType(name: "Artifact", sample: canonicalArtifact, headingContains: "Artifact —"),
            RecordType(
                name: "FileEntry", sample: canonicalArtifact.files[0],
                headingContains: "File entries"),
            RecordType(name: "Person", sample: canonicalPerson, headingContains: "Person —"),
            RecordType(
                name: "EvidenceLink", sample: canonicalEvidenceLink,
                headingContains: "Evidence link —"),
            RecordType(
                name: "Relationship", sample: canonicalRelationship,
                headingContains: "Relationship —"),
            RecordType(
                name: "Dismissal", sample: canonicalDismissal,
                headingContains: "Dismissal —"),
            RecordType(
                name: "Provenance", sample: canonicalPerson.provenance,
                headingContains: "Provenance"),
            RecordType(
                name: "Manifest", sample: canonicalManifest, headingContains: "manifest.json"),
            RecordType(
                name: "ManifestEntry", sample: canonicalManifest.files[0],
                headingContains: "manifest.json"),
        ]
    }

    @Test("Every persisted record field is documented in its own spec section")
    func everyRecordFieldIsDocumentedInItsSection() throws {
        let spec = try String(contentsOf: Self.resourceCopyURL, encoding: .utf8)

        for record in Self.recordTypes {
            guard let section = Self.section(headingContaining: record.headingContains, in: spec)
            else {
                Issue.record(
                    """
                    No spec section found for \(record.name) (heading containing \
                    “\(record.headingContains)”).
                    """)
                continue
            }
            for label in Self.storedPropertyNames(of: record.sample) {
                // Match the field name as a **backticked** token (`` `facts` ``), the form
                // every field name takes in the spec's tables and prose. A bare-substring
                // check would be fooled by the word appearing in a field's *description*
                // (e.g. "Relationship-scoped facts") even when the field-name cell is gone.
                #expect(
                    section.contains("`\(label)`"),
                    """
                    \(record.name) has a stored field “\(label)” that is not documented in \
                    its spec section (heading containing “\(record.headingContains)”). \
                    Add it to \(Self.specFileName) (both copies) so the format spec stays \
                    accurate.
                    """)
            }
        }
    }

    // MARK: - Helpers

    /// The direct (non-recursed) stored-property names of a value — the field names a
    /// struct encodes to JSON (our keys are plain camelCase, so the property name *is*
    /// the on-disk key, §3).
    private static func storedPropertyNames(of value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label)
    }

    /// The body of the markdown section whose heading line contains `needle`: from that
    /// heading up to (but excluding) the next heading line. Heading = a line whose first
    /// non-whitespace character is `#`.
    private static func section(headingContaining needle: String, in doc: String) -> String? {
        let lines = doc.components(separatedBy: "\n")
        func isHeading(_ line: String) -> Bool {
            line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }
        guard let start = lines.firstIndex(where: { isHeading($0) && $0.contains(needle) })
        else { return nil }

        var body = [lines[start]]
        var i = start + 1
        while i < lines.count, !isHeading(lines[i]) {
            body.append(lines[i])
            i += 1
        }
        return body.joined(separator: "\n")
    }
}

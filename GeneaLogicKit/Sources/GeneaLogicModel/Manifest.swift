/// The archive manifest — the root `manifest.json` file that holds the archive's
/// identity, format version, and an integrity manifest of every file.
///
/// Documented in ARCHITECTURE.md §3 (archive layout) and §3 (integrity / BagIt-flavored).
///
/// NOTE: The doc describes `manifest.json` as carrying:
///   - archive format version
///   - archive UUID
///   - a manifest of every file with its SHA-256 and byte length
/// The exact JSON structure is NOT shown in a code block in the doc — this struct's
/// field names and nesting are a minimal reasonable interpretation. Flagged for Opus review.
///
/// NOTE (archiveUID): The archive's own UUID is stored here. It is a plain `String`
/// (not `Foundation.UUID`) for consistency with the uid-as-String strategy in Phase 0.
/// Flagged for Opus review.
///
/// NOTE (manifestEntries): Each entry records a file's path (relative to the archive
/// root), SHA-256, and byte length. This is the BagIt-flavored integrity surface.
/// The field name `files` is used (minimal, matching the spirit of BagIt's manifest).
/// Flagged for Opus review — the open question in §10 is whether to adopt literal
/// BagIt layout or keep the custom `manifest.json`.

// MARK: - ManifestEntry

/// A single file record in the archive-wide integrity manifest.
public struct ManifestEntry: Codable, Sendable, Equatable {
    /// Path relative to the archive root (e.g. `"artifacts/ART-001/census-1920.tif"`).
    public var path: String

    /// SHA-256 checksum as a hex string.
    public var sha256: String

    /// File size in bytes.
    public var byteLength: Int64

    public init(
        path: String,
        sha256: String,
        byteLength: Int64
    ) {
        self.path = path
        self.sha256 = sha256
        self.byteLength = byteLength
    }
}

// MARK: - Manifest

/// The archive-wide manifest (`manifest.json` at the archive root).
public struct Manifest: Codable, Sendable, Equatable {
    /// The format version of the archive schema (e.g. `"1.0"`).
    public var schemaVersion: String

    /// A stable identifier for this archive. Used to namespace cross-archive
    /// references: globally, a record's identity is `(archiveUID, recordUID)`
    /// per ARCHITECTURE.md §4.1.
    public var archiveUID: ArchiveID

    /// Human-readable name for this archive (optional display label).
    /// NOTE: Not explicitly listed in the doc; added as a minimal useful field.
    /// Flagged for Opus review.
    public var name: String?

    /// ISO 8601 timestamp when this manifest was last written.
    public var updatedAt: String

    /// Integrity manifest: every file in the archive with its checksum and size.
    public var files: [ManifestEntry]

    public init(
        archiveUID: ArchiveID,
        name: String? = nil,
        updatedAt: String,
        files: [ManifestEntry] = []
    ) {
        self.schemaVersion = SchemaVersion.current
        self.archiveUID = archiveUID
        self.name = name
        self.updatedAt = updatedAt
        self.files = files
    }
}

/// Provenance for externally-sourced records: where, when, and with what integrity check
/// the record was retrieved from an external repository.
///
/// Documented in `Artifact.retrieval` (ARCHITECTURE.md §4.2). Present only when
/// the artifact originated from an external source (e.g. an online database, archive).
///
/// NOTE: The JSON key in the doc is `"retrieval"` — a top-level optional object.
/// It is modeled as `Artifact.retrieval: Retrieval?` (nil for locally-created records).
///
/// NOTE (checksum): `checksum` is `String?` in the doc example (`null`). It is
/// not specified which hash algorithm applies here — assumed SHA-256 for consistency
/// with `FileEntry.sha256`, but not enforced. Flagged for Opus review.
public struct Retrieval: Codable, Sendable, Equatable {
    /// Name or description of the source repository or service.
    public var source: String

    /// ISO 8601 date string of when the record was retrieved.
    public var date: String

    /// Checksum of the retrieved data (assumed SHA-256 hex string), or `nil`.
    public var checksum: String?

    public init(
        source: String,
        date: String,
        checksum: String? = nil
    ) {
        self.source = source
        self.date = date
        self.checksum = checksum
    }
}

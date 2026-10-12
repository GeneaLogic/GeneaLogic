/// A single physical file associated with an artifact.
///
/// Documented in `Artifact.files[]` (ARCHITECTURE.md §4.2 and §4.2.1).
///
/// Key design points from the spec:
/// - `path` is package-assigned and collision-free; `originalName` is the user's name.
/// - `uid` is a type-prefixed UUIDv7 (e.g. `FIL-018f…`), stored as `String` for Phase 0.
/// - `sha256` is a plain `String` (hex-encoded) — no `swift-crypto` in Phase 0.
/// - `byteLength` is `Int64` to handle files larger than 2 GB.
///
/// NOTE (uid typing): `uid` and all cross-record references are `String` in Phase 0.
/// A typed-ID wrapper (e.g. `struct FileUID: RawRepresentable`) would catch cross-type
/// confusion at compile time. Deferred; flagged for Opus review.
///
/// NOTE (byteLength): The doc shows `10485760` as an example. `Int` would overflow
/// on 32-bit platforms for large files; `Int64` is used for safety. Flagged for Opus review.
public struct FileEntry: Codable, Sendable, Equatable {
    /// Type-prefixed UUIDv7 identifier, e.g. `"FIL-018f…"`.
    public var uid: FileID

    /// Package-assigned, collision-free path relative to the artifact folder.
    public var path: String

    /// The original filename as supplied by the user. Display/export only; never used to locate.
    public var originalName: String

    /// The file's role within the artifact.
    public var role: FileRole

    /// Format description string (e.g. `"TIFF"`, `"PDF/A"`).
    /// NOTE: Kept as a plain `String` rather than an enum — the set of formats is
    /// open-ended and not enumerated in the doc. Flagged for Opus review.
    public var format: String

    /// File size in bytes.
    public var byteLength: Int64

    /// SHA-256 checksum as a hex string. Plain `String` in Phase 0 (no swift-crypto yet).
    public var sha256: String

    public init(
        uid: FileID,
        path: String,
        originalName: String,
        role: FileRole,
        format: String,
        byteLength: Int64,
        sha256: String
    ) {
        self.uid = uid
        self.path = path
        self.originalName = originalName
        self.role = role
        self.format = format
        self.byteLength = byteLength
        self.sha256 = sha256
    }
}

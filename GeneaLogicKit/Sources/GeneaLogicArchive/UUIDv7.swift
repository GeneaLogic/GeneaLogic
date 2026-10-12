import Foundation
import GeneaLogicModel

/// A minimal UUIDv7 (time-ordered UUID, RFC 9562) generator.
///
/// `Foundation.UUID` only produces v4 (random) UUIDs, but ARCHITECTURE.md §4.1
/// mandates v7 so that `uid`s sort chronologically and listings stay roughly
/// browsable. This is a small, dependency-free implementation — it needs no
/// cryptographic guarantees (just well-distributed randomness), so it uses
/// `SystemRandomNumberGenerator` rather than pulling in swift-crypto for it.
///
/// Layout (RFC 9562 §5.7), big-endian 128 bits:
/// ```
/// 48 bits  unix_ts_ms        milliseconds since the Unix epoch
///  4 bits  ver = 0b0111      version 7
/// 12 bits  rand_a            random
///  2 bits  var = 0b10        RFC 9562 variant
/// 62 bits  rand_b            random
/// ```
/// Monotonicity within the same millisecond is **not** guaranteed beyond what
/// the random bits statistically provide — sufficient for this archive's needs
/// (ARCHITECTURE.md explicitly notes math collisions are negligible at our
/// scale); a counter-based monotonic variant would add complexity with no
/// practical benefit here.
enum UUIDv7 {
    /// Generates a new time-ordered UUIDv7, formatted as a canonical
    /// lowercase-hyphenated UUID string (e.g. `"018f3c9a-7b2e-7c41-9e3a-2b1c4d5e6f70"`).
    static func generate(
        now: Date = Date(),
        using rng: inout some RandomNumberGenerator
    ) -> String {
        let unixMillis = UInt64(now.timeIntervalSince1970 * 1000)

        var bytes = [UInt8](repeating: 0, count: 16)

        // 48-bit timestamp, big-endian, into bytes[0...5].
        bytes[0] = UInt8((unixMillis >> 40) & 0xFF)
        bytes[1] = UInt8((unixMillis >> 32) & 0xFF)
        bytes[2] = UInt8((unixMillis >> 24) & 0xFF)
        bytes[3] = UInt8((unixMillis >> 16) & 0xFF)
        bytes[4] = UInt8((unixMillis >> 8) & 0xFF)
        bytes[5] = UInt8(unixMillis & 0xFF)

        // Remaining 10 bytes (80 bits) are random; we then overlay the version
        // and variant bits per the layout above.
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }

        // Byte 6: high nibble = version (0111), low nibble = top 4 bits of rand_a.
        bytes[6] = (0x70 | (bytes[6] & 0x0F))

        // Byte 8: top 2 bits = variant (10), remaining 6 bits = rand_b high bits.
        bytes[8] = (0x80 | (bytes[8] & 0x3F))

        return formatAsUUIDString(bytes)
    }

    /// Convenience overload using the system RNG.
    static func generate(now: Date = Date()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(now: now, using: &rng)
    }

    private static func formatAsUUIDString(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let start = hex.startIndex
        func slice(_ range: Range<Int>) -> String {
            String(
                hex[
                    hex.index(
                        start, offsetBy: range.lowerBound)..<hex.index(
                            start, offsetBy: range.upperBound)])
        }
        return [slice(0..<8), slice(8..<12), slice(12..<16), slice(16..<20), slice(20..<32)]
            .joined(separator: "-")
    }
}

/// Mints type-prefixed UUIDv7 identifiers for new records (ARCHITECTURE.md §4.1).
///
/// Centralizing minting here ensures every record kind gets the right prefix and
/// that **callers never supply `uid`s** — the engine mints them, once, at
/// creation. (`localRef`/folder-slug generation is separate; see `Slug.swift`.)
enum IdentifierMinter {
    static func artifact() -> ArtifactID { ArtifactID("ART-" + UUIDv7.generate()) }
    static func file() -> FileID { FileID("FIL-" + UUIDv7.generate()) }
    static func person() -> PersonID { PersonID("PER-" + UUIDv7.generate()) }
    static func evidenceLink() -> EvidenceLinkID { EvidenceLinkID("LNK-" + UUIDv7.generate()) }
    static func relationship() -> RelationshipID { RelationshipID("REL-" + UUIDv7.generate()) }
    static func dismissal() -> DismissalID { DismissalID("DSM-" + UUIDv7.generate()) }
    static func archive() -> ArchiveID { ArchiveID(UUIDv7.generate()) }
}

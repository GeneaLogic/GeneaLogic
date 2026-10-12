import Crypto
import GeneaLogicModel
import Foundation

/// SHA-256 checksums via **swift-crypto** (never `CryptoKit`, which is Apple-only
/// and would break the Linux build — CLAUDE.md, ARCHITECTURE.md §6.1).
enum Checksum {
    /// The chunk size used when streaming a file through the hasher, so large
    /// preservation masters (multi-GB TIFF/FFV1) are never loaded fully into memory.
    private static let chunkSize = 1 << 20  // 1 MiB

    /// Computes the lowercase-hex SHA-256 digest of the file at `url`, streaming
    /// it in fixed-size chunks.
    ///
    /// - Parameter isCancelled: Consulted **between chunks**, and throwing
    ///   `.cancelled` when it answers `true`. Defaults to never — every write
    ///   path hashes what it has just written and must not be abandoned halfway
    ///   because something cancelled the task around it.
    ///
    ///   `verifyIntegrity()` is the one caller that passes a real one, and the
    ///   granularity is the reason it is here rather than a check between files:
    ///   reading a cloud placeholder blocks *inside* this loop while the provider
    ///   fetches, so a per-file check would leave a multi-gigabyte transfer
    ///   running after the user asked it to stop (`/code-review`, 57b). **What it
    ///   stops is the reading**; a file provider that has already begun a fetch
    ///   may well finish it, and no surface should promise otherwise.
    static func sha256Hex(
        ofFileAt url: URL, isCancelled: () -> Bool = { false }
    ) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw ChecksumError.cannotOpenFile(url)
        }
        stream.open()
        defer { stream.close() }
        // **An open that failed must not hash as empty** (`/code-review`, 57b).
        // `InputStream.open()` reports failure only through `streamError`, and the
        // loop below then finds no bytes available and returns the SHA-256 of
        // *nothing* — a real digest, wrong, and indistinguishable from a
        // successfully-read empty file. Every caller compares it to a recorded
        // hash, so a file that could not be opened was reported as **corruption**:
        // the wrong accusation, on a machine where the actual problem is a
        // permission or a disk. Found by a test that chmod-0'd a file expecting
        // `verifyIntegrity()` to say it could not read it.
        //
        // **`streamStatus`, never `streamError` here.** Reading `streamError` on
        // a stream that opened *fine* segfaults in swift-corelibs-foundation —
        // the whole engine suite crashed on Linux at the first `Archive.create`,
        // while macOS was green. The status is the question being asked anyway.
        if stream.streamStatus == .error { throw ChecksumError.cannotOpenFile(url) }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while stream.hasBytesAvailable {
            if isCancelled() { throw ChecksumError.cancelled }
            let bytesRead = stream.read(&buffer, maxLength: chunkSize)
            if bytesRead < 0 {
                throw stream.streamError ?? ChecksumError.readFailed(url)
            }
            if bytesRead == 0 { break }
            hasher.update(data: buffer[0..<bytesRead])
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Computes the lowercase-hex SHA-256 digest of bytes already in memory.
    ///
    /// The write-time half of slice 49: a sidecar's manifest entry is minted from
    /// the very bytes `AtomicIO` just wrote, so covering `record.json` and
    /// `conclusions/**` costs one hash of a small `Data` per mutation rather than
    /// a re-read (let alone a re-walk) of the archive.
    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    enum ChecksumError: Error, Equatable {
        case cannotOpenFile(URL)
        case readFailed(URL)
        /// The caller's `isCancelled` said stop. **Not a read failure** — the
        /// bytes are not suspect, nobody finished looking at them — and
        /// `verifyIntegrity()` distinguishes the two in its report.
        case cancelled
    }
}

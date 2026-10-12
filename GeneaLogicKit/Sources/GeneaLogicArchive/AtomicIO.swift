import Foundation
import GeneaLogicModel

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Atomic file-write helpers (write-temp-then-rename), used for every sidecar,
/// manifest, and copied-in media file mutation.
///
/// ARCHITECTURE.md calls for "changing one artifact rewrites one small JSON file
/// atomically" (§3) and "atomic sidecar rewrite" in the §6.3 API sketch. The
/// scheme: write the new bytes to a uniquely-named temp file in the **same
/// directory** as the destination (so the rename is same-volume and atomic on
/// POSIX filesystems), then atomically rename it into place over the destination
/// with a single POSIX `rename(2)` call (see `moveIntoPlace` for why we call it
/// directly rather than via `FileManager`). If the process is interrupted
/// mid-write, the destination is left intact — either the old bytes (rename
/// never ran) or the new bytes (rename completed), never missing or half-written
/// — and at worst a stray temp file remains.
///
/// **Against the machine dying too, not only the process** (slice 69, fork d).
/// `rename(2)` is atomic against a crash because the page cache survives one;
/// a power cut does not, and without a flush the rename can reach the disk
/// before the data it names — an empty sidecar where a whole one was. So the
/// temp file is flushed before every rename (`flushToDisk`). That is ordering,
/// not durability of the last write, which is all the guarantee above promises.
enum AtomicIO {
    /// Atomically writes `data` to `destination`, replacing any existing file.
    ///
    /// - Throws: If the temp file cannot be written, or the replace/rename fails
    ///   (in which case the temp file is best-effort cleaned up and the
    ///   destination is left exactly as it was).
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempName = ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempName)

        do {
            // Not `.atomic`: the temp name is already unique, and Foundation's
            // own write-then-rename would only put a second rename, unflushed,
            // under ours.
            try data.write(to: tempURL)
            try flushToDisk(tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        WriteCheckpoint.reached("temp written", at: tempURL)

        try Self.moveIntoPlace(from: tempURL, to: destination)
    }

    /// Atomically renames `tempURL` onto `destination` via a single POSIX
    /// `rename(2)` call, replacing any existing file in one syscall.
    ///
    /// `rename(2)` atomically replaces an existing destination on the same volume
    /// — there is **no window** in which `destination` is absent, so a crash
    /// leaves either the old file or the new file fully in place, never neither.
    /// The temp file is always created in `destination`'s own directory, so the
    /// two are guaranteed same-volume.
    ///
    /// We call `rename(2)` directly rather than through `FileManager` because:
    /// `FileManager.moveItem` refuses to overwrite an existing destination (so a
    /// remove-then-move would be required, reintroducing the absent-destination
    /// window), and `FileManager.replaceItemAt` is unreliable on
    /// `swift-corelibs-foundation` as of Swift 6.1 — it throws
    /// `NSCocoaErrorDomain` "the file doesn't exist" even when `destination`
    /// exists and can leave the old bytes in place. `rename(2)` is the primitive
    /// both of those are supposed to wrap, and behaves identically on macOS and Linux.
    private static func moveIntoPlace(from tempURL: URL, to destination: URL) throws {
        let result = tempURL.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            guard let sourcePath else { return -1 }
            return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let destinationPath else { return -1 }
                return rename(sourcePath, destinationPath)
            }
        }
        if result != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(code),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "rename(2) failed moving \(tempURL.lastPathComponent) into place: "
                        + String(cString: strerror(code))
                ])
        }
        WriteCheckpoint.reached("renamed", at: destination)
    }

    /// Encodes `value` with the canonical archive encoder and atomically writes
    /// it to `destination`. The single chokepoint every sidecar/manifest write
    /// goes through, so "every JSON write is atomic" is structural, not a
    /// per-call discipline.
    ///
    /// - Returns: The bytes written — the input to the manifest entry
    ///   `Archive.writeAuthoredJSON` mints for it (slice 49), so a sidecar's
    ///   checksum is taken from what we wrote rather than from a re-read.
    @discardableResult
    static func writeJSON(_ value: some Encodable, to destination: URL) throws -> Data {
        let data = try GeneaLogicJSONCoding.encoder.encode(value)
        try write(data, to: destination)
        return data
    }

    /// Atomically copies the file at `source` to `destination` (write-temp,
    /// then rename), so a crash mid-copy never leaves a partially-written media
    /// file at the final path.
    static func copyFile(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempName = ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        let tempURL = directory.appendingPathComponent(tempName)

        do {
            try FileManager.default.copyItem(at: source, to: tempURL)
            try flushToDisk(tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        WriteCheckpoint.reached("temp written", at: tempURL)

        try Self.moveIntoPlace(from: tempURL, to: destination)
    }

    /// Puts the file at `url` on the disk **ahead of anything written after it**
    /// (slice 69, fork d) — called on a temp file before its rename, and on the
    /// dirty marker before the writes it journals.
    ///
    /// On Darwin, `F_BARRIERFSYNC`: an `fsync` plus a barrier, so everything
    /// `fsync`ed before it persists before any I/O after it. That is the
    /// guarantee the rename needs, and the one that keeps a sidecar ahead of the
    /// manifest naming it; `F_FULLFSYNC` would also wait for the drive to drain,
    /// which buys durability of the last write at many times the cost. A file
    /// system that refuses the barrier gets a plain `fsync`. On Linux there is
    /// only `fsync`.
    ///
    /// **Throws when the flush fails** — an `EIO` here is the disk saying the
    /// bytes did not land, and renaming them into place would publish that.
    static func flushToDisk(_ url: URL) throws {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        #if canImport(Darwin)
        if fcntl(descriptor, F_BARRIERFSYNC) == 0 { return }
        #endif
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Whether **nothing at all** is at `url` — and a throw when the file system
    /// cannot say. `lstat`, so a dangling symlink is something; and only
    /// `ENOENT` is nothing, so an `EACCES` or `EIO` is an error rather than an
    /// answer either way (`ManifestMerge.nothingIsThere`, slice 58b).
    static func isAbsent(_ url: URL) throws -> Bool {
        try url.withUnsafeFileSystemRepresentation { representation -> Bool in
            guard let representation else { throw CocoaError(.fileReadInvalidFileName) }
            var st = stat()
            guard lstat(representation, &st) != 0 else { return false }
            let code = errno
            guard code == ENOENT else {
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            return true
        }
    }
}

/// Re-exports the canonical JSON coding configuration under a name local to this
/// target, so call sites read naturally (`GeneaLogicJSONCoding.encoder`) without
/// importing `GeneaLogicModel`'s `GeneaLogicJSON` enum under its original name —
/// purely a readability alias; same `JSONEncoder`/`JSONDecoder` instances.
enum GeneaLogicJSONCoding {
    static let encoder = GeneaLogicJSON.encoder
    static let decoder = GeneaLogicJSON.decoder
}

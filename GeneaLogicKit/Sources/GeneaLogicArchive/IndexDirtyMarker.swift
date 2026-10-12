import Foundation

/// The `.index/dirty` sentinel: present exactly while a mutation is in flight,
/// so an *interrupted* one is detectable afterwards (slice 47, fork f). The open
/// that finds it rebuilds the index, then asks whether the manifest is behind
/// (`Archive.recoverFromInterruptedWrite()`) and writes the answer down as
/// `InterruptedWriteMarker` before clearing this one (slice 65).
///
/// **The hole it plugs.** A mutation writes the authoritative sidecar first and
/// the derived index second. If the process dies in between — or the index write
/// itself fails — the two diverge, and nothing notices: `Archive.open` rebuilds
/// only when `.index/index.sqlite` is missing, unopenable, or schema-stale,
/// never on *content* drift. The sentinel converts that silent divergence into a
/// one-bit fact on disk, and `Archive.open` turns the bit into a rebuild.
///
/// **Why a file and not a row in the index's `meta` table:** the failure this
/// exists to catch includes *the index being unwritable*. A marker that lives
/// inside the thing that might be broken cannot report that it is broken.
///
/// **What it does not do.** It sees only writes this engine started. A sidecar
/// hand-edited or delivered by cloud sync leaves no marker and still serves
/// stale reads — that is §10.4's generation marker, which needs a home in the
/// *format* and belongs to the sync slice. This sentinel does not foreclose it.
///
/// **Deliberate over-triggering.** The marker spans the whole mutation and is
/// *left behind when one throws*, including for a pre-write validation error
/// like `artifactNotFound` that could not possibly have diverged anything. The
/// cost is one unnecessary rebuild on the next open; the alternative — trying to
/// classify which errors wrote something — trades a cheap false positive for an
/// undetectable false negative, which is the exact failure being fixed.
///
/// **It is also a write-ahead journal of what the mutation authored** (slice 68,
/// `/code-review`). Before each engine-authored file is written, the path and the
/// hash of the bytes about to land are appended here; before each is unlinked,
/// the path is. The open that recovers reads it back, and the drift guard exempts
/// a path only while it still holds the bytes *we* wrote — the one mismatch a
/// crash leaves that is ours. Inferring that from "whatever differs from the
/// manifest" exempted every hand edit and delivery already on disk as well.
/// Lines that are not journal entries (the stamp each mutation opens with) are
/// ignored, and an empty sentinel journals nothing, so it exempts nothing.
enum IndexDirtyMarker {
    /// Marks a mutation as in flight. Throws if it cannot be written: an
    /// unwritable `.index/` means the mutation about to run cannot keep the
    /// index in lockstep either, so failing here is the honest answer.
    ///
    /// **Appends when one is already here** (slice 68): a sentinel left by an
    /// earlier divergence carries that write's journal, which the open that
    /// recovers still needs.
    ///
    /// **Flushed, like every journal entry** (slice 69, fork d): the barrier on
    /// the sidecar that follows orders only I/O already `fsync`ed, and a marker
    /// that a power cut lost while keeping the write it guards is the silent
    /// divergence this exists to prevent.
    static func set(in root: URL) throws {
        let stamp = "\(getpid()) \(ISO8601DateFormatter().string(from: Date()))\n"
        let url = ArchiveLayout.indexDirtyMarkerURL(in: root)
        if try !append(Data(stamp.utf8), to: url) {
            try Data(stamp.utf8).write(to: url)
            try AtomicIO.flushToDisk(url)
        }
        WriteCheckpoint.reached("marker set", at: root)
    }

    /// Journals a write of `sha256` to `path`, ahead of it. Best-effort: an entry
    /// that fails to land only means its bytes will not be exempt after a crash,
    /// which is the closed direction.
    static func journalWrite(of path: String, sha256: String, in root: URL) {
        _ = try? append(
            Data("\(writeTag)\t\(sha256)\t\(path)\n".utf8),
            to: ArchiveLayout.indexDirtyMarkerURL(in: root))
    }

    /// Journals an unlink of `path`, ahead of it — cancelling an earlier write.
    static func journalRemoval(of path: String, in root: URL) {
        _ = try? append(
            Data("\(removeTag)\t\(path)\n".utf8), to: ArchiveLayout.indexDirtyMarkerURL(in: root))
    }

    /// What the journal says each path last received from us: the hash of the
    /// bytes written, with an unlink cancelling the write before it.
    static func journaledWrites(in root: URL) -> [String: String] {
        var writes: [String: String] = [:]
        for entry in journal(in: root) {
            writes[entry.path] = entry.sha256
        }
        return writes
    }

    /// The paths the journal says were last **unlinked** by us — what crash
    /// recovery may discard a preserved copy for, and nothing else (slice 69,
    /// fork c; `ArchiveIndex.rebuild(unlinkedByDiedWrite:)`). A later write of the
    /// same path takes it back out.
    static func journaledRemovals(in root: URL) -> Set<String> {
        var removals: Set<String> = []
        for entry in journal(in: root) {
            if entry.sha256 == nil {
                removals.insert(entry.path)
            } else {
                removals.remove(entry.path)
            }
        }
        return removals
    }

    /// The journal's entries in order: a write carries the hash it wrote, an
    /// unlink `nil`.
    private static func journal(in root: URL) -> [(path: String, sha256: String?)] {
        guard
            let data = try? Data(contentsOf: ArchiveLayout.indexDirtyMarkerURL(in: root)),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        var entries: [(path: String, sha256: String?)] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            if fields.count == 3, fields[0] == writeTag {
                entries.append((fields[2], fields[1]))
            } else if fields.count == 2, fields[0] == removeTag {
                entries.append((fields[1], nil))
            }
        }
        return entries
    }

    private static let writeTag = "write"
    private static let removeTag = "unlink"

    /// Appends to an existing file and flushes it; `false` when there is none to
    /// append to.
    ///
    /// **Throws, rather than answering `false`, once a file is there** (slice 69,
    /// `/code-review`): `set()` reads `false` as *no marker*, and writing a fresh
    /// one over a marker whose write or flush merely failed truncated an earlier
    /// divergence's journal — its exemptions and its removals with it. The same
    /// holds for the open (cloud review of 67–71): only a file that is really
    /// absent answers `false`; any other failure to open one throws.
    private static func append(_ data: Data, to url: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            guard try AtomicIO.isAbsent(url) else { throw error }
            return false
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return true
    }

    /// Clears the marker after a mutation completes. Lenient about absence so a
    /// clear is never the thing that fails a successful write.
    static func clear(in root: URL) {
        WriteCheckpoint.reached("before marker clear", at: root)
        try? FileManager.default.removeItem(at: ArchiveLayout.indexDirtyMarkerURL(in: root))
    }

    static func isSet(in root: URL) -> Bool {
        FileManager.default.fileExists(atPath: ArchiveLayout.indexDirtyMarkerURL(in: root).path)
    }
}

/// The `.index/interrupted` marker: an interrupted write the manifest has not
/// caught up on, **left unresolved** — what the flag `Archive` raises on open is
/// read from, so a second open says what the first did (slice 65).
///
/// **Separate from `dirty`, because the two cost differently.** `dirty` means the
/// index must be rebuilt and the manifest compared against it, a walk and a
/// hash of every sidecar; once that has been done the answer does not change
/// until someone writes, so the open that settles it records the verdict here and
/// every later open reads one file. Keeping `dirty` instead (65's first cut) made
/// every launch of a suspect archive pay for the whole recovery again.
///
/// Written by the open that settles a crash; cleared only by `rebaseline()`.
///
/// **It carries what the drift guard exempts** (slice 68, fork c) — a JSON
/// object of archive-relative path → SHA-256: the bytes our interrupted write
/// left, as `IndexDirtyMarker`'s journal recorded them. Rewritten when a later
/// mutation of ours rewrites or removes one of those paths. An empty file (one
/// written before 68) exempts nothing. Machine-local and non-authoritative like
/// the rest of `.index/`, so its contents are not part of the archive format.
enum InterruptedWriteMarker {
    static func set(in root: URL, exempting exemptions: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(exemptions)) ?? Data()
        // Through `AtomicIO`, so flushed before its rename like every other
        // write (slice 69, `/code-review`): this verdict is recorded and then
        // `dirty` is cleared, and a power cut that kept the clear but not these
        // bytes lost the crash's exemptions.
        try? AtomicIO.write(data, to: ArchiveLayout.interruptedWriteMarkerURL(in: root))
    }

    /// What the marker exempts — empty when there is none, or it records none.
    static func exemptions(in root: URL) -> [String: String] {
        guard
            let data = try? Data(contentsOf: ArchiveLayout.interruptedWriteMarkerURL(in: root)),
            let exemptions = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return exemptions
    }

    static func clear(in root: URL) {
        try? FileManager.default.removeItem(at: ArchiveLayout.interruptedWriteMarkerURL(in: root))
    }

    static func isSet(in root: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: ArchiveLayout.interruptedWriteMarkerURL(in: root).path)
    }
}

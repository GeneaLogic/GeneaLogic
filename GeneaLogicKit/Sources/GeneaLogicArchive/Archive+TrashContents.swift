import Foundation
import GeneaLogicModel

extension Archive {
    // MARK: - What a trashed item holds (slice 87)

    /// The files a trashed artifact holds whose bytes are still in its `.trash/` payload,
    /// in its record's order: what a preview of it shows before Delete Permanently…
    /// destroys it.
    ///
    /// **Read-only.** The URLs point into `.trash/`, which restore renames back into
    /// place, so they are good until the next restore or purge, and nothing should write
    /// through them. Empty when `uid` isn't a trashed artifact, or its payload record
    /// can't be read.
    public func trashedFileContents(ofArtifact uid: ArtifactID) -> [TrashedFileContent] {
        withReadState { _, _ in
            guard TrashStore.entry(uid: uid.raw, in: rootURL)?.kind == .artifact else {
                return []
            }
            let payload = TrashStore.payloadURL(uid: uid.raw, in: rootURL)
            let recordURL = payload.appendingPathComponent(ArchiveLayout.recordFileName)
            guard let data = try? Data(contentsOf: recordURL),
                let artifact = try? GeneaLogicJSONCoding.decoder.decode(Artifact.self, from: data)
            else { return [] }
            return artifact.files.compactMap { entry in
                let url = payload.appendingPathComponent(entry.path)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return TrashedFileContent(
                    uid: entry.uid, originalName: entry.originalName, url: url)
            }
        }
    }

    /// A trashed file's bytes, or `nil` when `uid` isn't a trashed file or its entry is
    /// record-only (its bytes were already gone when it was detached). Read-only, as
    /// `trashedFileContents(ofArtifact:)`'s are.
    public func trashedFileContent(_ uid: FileID) -> TrashedFileContent? {
        withReadState { _, _ in
            guard let entry = TrashStore.entry(uid: uid.raw, in: rootURL),
                entry.kind == .file, let info = entry.file
            else { return nil }
            let url = TrashStore.payloadURL(uid: uid.raw, in: rootURL)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return TrashedFileContent(
                uid: info.entry.uid, originalName: info.entry.originalName, url: url)
        }
    }
}

/// A file in the trash whose bytes are there to show: its `uid`, the user's filename, and
/// where the bytes are (slice 87).
public struct TrashedFileContent: Sendable, Equatable {
    public let uid: FileID
    /// The user's filename, for display. The URL's last component is package-assigned.
    public let originalName: String
    public let url: URL
}

/// The `deletion.json` sidecar written beside a trashed item's payload in
/// `.trash/<uid>/` inside an archive package. Records *what* was deleted and the
/// information needed to restore or list it.
///
/// The `kind` discriminator makes the trash store **format-extensible**: an entry
/// is either an `.artifact` (a whole artifact folder) or a `.file` (a single file
/// detached from an artifact). The discriminator was added before the `.file` case
/// existed precisely so it could arrive **without migrating existing entries** — old
/// `kind: artifact` records keep decoding, and the `*Info` payload present is selected
/// by the kind. Documented alongside the `.trash/` reserved package path (format
/// spec §2 / ARCHITECTURE.md §3).
///
/// A trashed item is immutable while it sits in the trash, so the denormalized
/// display fields here (e.g. `ArtifactTrashInfo.title`) cannot drift from the payload.
public struct TrashEntry: Codable, Sendable, Equatable {
    /// Which kind of item was trashed (and thus which `*Info` payload is present).
    public var kind: TrashedItemKind

    /// ISO 8601 timestamp of when the item was moved to the trash.
    public var deletedAt: String

    /// Restore/display info for a trashed artifact. Present iff `kind == .artifact`.
    public var artifact: ArtifactTrashInfo?

    /// Restore/display info for a trashed file. Present iff `kind == .file`.
    public var file: FileTrashInfo?

    public init(
        kind: TrashedItemKind,
        deletedAt: String,
        artifact: ArtifactTrashInfo? = nil,
        file: FileTrashInfo? = nil
    ) {
        self.kind = kind
        self.deletedAt = deletedAt
        self.artifact = artifact
        self.file = file
    }
}

/// The kind of item held in a trash entry. **Closed.** Both members are live:
/// `.artifact` (a whole artifact folder) and `.file` (a single file detached from an
/// artifact); the matching `TrashEntry.*Info` payload tells callers which.
public enum TrashedItemKind: String, Codable, Sendable, Equatable {
    case artifact
    case file
}

/// Restore/display info for a trashed artifact: enough to list it in a Trash UI and
/// to put it back. The artifact's bytes (its whole folder — `record.json` + files)
/// live beside this record at `.trash/<uid>/payload/`.
public struct ArtifactTrashInfo: Codable, Sendable, Equatable {
    /// The trashed artifact's uid — also the `.trash/<uid>/` folder name.
    public var uid: ArtifactID

    /// The artifact's title, denormalized so a Trash listing needs no payload read.
    public var title: String

    /// The folder slug to reuse on restore when it's still free; the slug is a
    /// non-authoritative friendly name (§4.1), so a fresh one is assigned if taken.
    public var originalSlug: String

    public init(uid: ArtifactID, title: String, originalSlug: String) {
        self.uid = uid
        self.title = title
        self.originalSlug = originalSlug
    }
}

/// Restore/display info for a trashed *file*: enough to list it in a Trash UI and to
/// re-attach it to the artifact it was detached from. The file's bytes live beside
/// this record at `.trash/<uid>/payload` (a single file — present unless the on-disk
/// content was already gone at delete time, a record-only degraded entry).
public struct FileTrashInfo: Codable, Sendable, Equatable {
    /// The detached file's full entry, restored **verbatim** (same `FIL-` uid, role,
    /// checksum); `uid` is also the `.trash/<uid>/` folder name. The package `path`
    /// is reused on restore when free, else reassigned (it is non-authoritative, §4.2.1).
    public var entry: FileEntry

    /// The artifact the file was detached from, and where restore re-attaches it. If
    /// that artifact no longer exists at restore time, restore fails (the file can't
    /// be re-homed) — surfaced to the user, not silently dropped.
    public var artifactUID: ArtifactID

    /// The owning artifact's title, denormalized so a Trash listing ("deleted from …")
    /// needs no live lookup — and stays correct even if that artifact is later renamed.
    public var artifactTitle: String

    public init(entry: FileEntry, artifactUID: ArtifactID, artifactTitle: String) {
        self.entry = entry
        self.artifactUID = artifactUID
        self.artifactTitle = artifactTitle
    }
}

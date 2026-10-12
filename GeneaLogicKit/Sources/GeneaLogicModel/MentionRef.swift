/// A reference to a specific person-mention within an artifact: the artifact's id
/// plus the mention's record-local `localRef` (see `PersonMention.localRef`).
///
/// This is an **API value, not a stored record** — it names the "name as it
/// appears here" that an evidence link points at. `EvidenceLink` persists the
/// equivalent information as flat `artifactUid` + `personMentionRef` fields, so
/// `MentionRef` is not itself serialized; it exists to give the archive API a
/// single, self-documenting argument instead of a bare `(ArtifactID, String)` tuple.
public struct MentionRef: Sendable, Equatable, Hashable {
    /// The artifact containing the mention.
    public var artifact: ArtifactID

    /// The mention's record-local reference (`PersonMention.localRef`).
    public var localRef: String

    public init(artifact: ArtifactID, localRef: String) {
        self.artifact = artifact
        self.localRef = localRef
    }
}

/// What an artifact with a blank title is called, wherever its title is shown or copied:
/// the sidebar's row, the Trash, a copy and File ▸ Quick Look (slice 87's `/code-review`:
/// they had three answers).
enum ArtifactTitle {
    static let untitled = "Untitled Artifact"

    static func display(_ title: String) -> String {
        title.trimmed.isEmpty ? untitled : title
    }
}

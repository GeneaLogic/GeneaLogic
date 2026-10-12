/// An external identifier for an artifact, enabling future federation.
///
/// Documented in `Artifact.externalIdentifiers[]` (ARCHITECTURE.md §4.2).
///
/// NOTE: `scheme` is typed as `ExternalIdentifierScheme` (an enum). The doc's
/// example is `"ark"`. However, the set of identifier schemes is inherently
/// open-ended; keeping `scheme` as a `String` would allow forward compatibility
/// without code changes. The enum approach is chosen for type safety in Phase 0,
/// but this is flagged for Opus review — a plain `String` may be preferable.
public struct ExternalIdentifier: Codable, Sendable, Equatable {
    /// The identifier scheme (e.g. `"ark"`, `"doi"`, `"url"`).
    public var scheme: ExternalIdentifierScheme

    /// The identifier value within the scheme.
    public var value: String

    /// The repository or institution that assigned this identifier.
    public var repository: String?

    public init(
        scheme: ExternalIdentifierScheme,
        value: String,
        repository: String? = nil
    ) {
        self.scheme = scheme
        self.value = value
        self.repository = repository
    }
}

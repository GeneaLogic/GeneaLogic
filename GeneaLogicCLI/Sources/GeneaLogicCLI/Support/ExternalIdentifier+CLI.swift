import GeneaLogicModel

extension ExternalIdentifier {
    /// Parses a `scheme=value` CLI token into an `ExternalIdentifier`, shared by
    /// `set-meta --external-id` and `lookup --external-id`.
    ///
    /// The scheme is an open vocabulary (`.parsing`), so an unrecognized scheme
    /// round-trips as `.unknown`; the value is everything after the first `=` (so
    /// a value may itself contain `=`). The `repository` field is not expressible
    /// through this shorthand — a deliberate simplification for the CLI.
    static func parsing(token: String) throws -> ExternalIdentifier {
        guard let separator = token.firstIndex(of: "=") else {
            throw CLIUserError("--external-id must be scheme=value (e.g. ark=12345/abc).")
        }
        let scheme = String(token[..<separator])
        let value = String(token[token.index(after: separator)...])
        guard !scheme.isEmpty, !value.isEmpty else {
            throw CLIUserError("--external-id must be scheme=value (e.g. ark=12345/abc).")
        }
        return ExternalIdentifier(scheme: .parsing(scheme), value: value)
    }
}

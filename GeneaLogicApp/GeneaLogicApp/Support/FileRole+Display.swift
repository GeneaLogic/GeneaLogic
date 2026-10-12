import GeneaLogicModel

extension FileRole {
    /// A human-readable label for the role, shown on file rows and in the
    /// attach-role menu.
    var displayName: String {
        switch self {
        case .preservationMaster: "Preservation Master"
        case .accessCopy: "Access Copy"
        case .derivative: "Derivative"
        case .transcript: "Transcript"
        }
    }
}

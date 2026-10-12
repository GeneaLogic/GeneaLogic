import GeneaLogicModel

/// App-layer display labels for the person-mention vocabularies. Kept in the app
/// (not the engine) because they're UI presentation; explicit switches so a future
/// vocabulary addition fails to compile here until it's given a label.
extension PersonRole {
    /// Title-cased label for menus and detail rows.
    ///
    /// Derived from the raw value rather than switched, because `PersonRole` became
    /// an **open** vocabulary in slice 44h: a role a record carries that this build
    /// has never heard of still has to render, and an exhaustive switch cannot
    /// produce a label for `.unknown("marriage-broker")`. This is the same
    /// `prettifiedVocabularyLabel` the other open vocabularies use, so an unknown
    /// role reads like a known one instead of leaking a raw token.
    var displayName: String { prettifiedVocabularyLabel(rawValue) }
}

extension InformationQuality {
    /// Title-cased label for menus and detail rows.
    var displayName: String {
        switch self {
        case .primary: return "Primary"
        case .secondary: return "Secondary"
        case .undetermined: return "Undetermined"
        }
    }
}

import Foundation
import GeneaLogicModel

// Human-readable labels for the person conclusion vocabularies, shown on the
// People-tab detail rows and in the person editor's type pickers — matching the
// `displayName` convention used by `FileRole`/`PersonRole`/`InformationQuality`.

extension NameType {
    /// A label for the name type ("also-known-as" → "Also Known As").
    var displayName: String { prettifiedVocabularyLabel(rawValue) }
}

extension FactType {
    /// A label for the fact type ("Birth" → "Birth", "Bar-Mitzvah" → "Bar Mitzvah",
    /// "AdoptiveParent" → "Adoptive Parent").
    var displayName: String { prettifiedVocabularyLabel(rawValue) }

    /// The short form of a parent-child qualifier, for the relationship editor's
    /// "Nature" picker and the relative rows — "Adoptive" reads better than "Adoptive
    /// Parent" next to a row already labelled Parent or Child. Falls back to the full
    /// ``displayName`` for anything that isn't a parent-role type.
    var natureLabel: String {
        switch self {
        case .biologicalParent: "Biological"
        case .adoptiveParent: "Adoptive"
        case .stepParent: "Step"
        case .fosterParent: "Foster"
        case .guardianParent: "Guardian"
        default: displayName
        }
    }
}

/// A compact "language/script" tag for a name (`PersonName` or `PersonMention`) —
/// "ru/Cyrl", or just "ru" / "Cyrl" when only one is set; `nil` when neither is. The two
/// are orthogonal (a transliterated Russian name is `ru`/`Latn`), so either stands alone.
/// Shared by the artifact mention rows and the People-tab Names rows so they don't drift.
func languageScriptTag(language: String?, script: String?) -> String? {
    let parts = [language?.trimmedNonEmpty, script?.trimmedNonEmpty].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "/")
}

/// An open-vocabulary raw value rendered for display: camelCase split into words,
/// hyphens as spaces, title-cased.
///
/// The camelCase split matters because `.capitalized` lowercases the remainder of each
/// word — without it the GEDCOM X parent-role types render as "Adoptiveparent".
///
/// Internal rather than file-private since slice 44h opened `PersonRole`, which now
/// renders through this too (an exhaustive switch can't label an `.unknown` case).
///
/// `nonisolated` because its callers are extensions on `GeneaLogicModel` types, which
/// are nonisolated — this is a pure `String → String` function that the module's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` put on the actor for no reason.
nonisolated func prettifiedVocabularyLabel(_ raw: String) -> String {
    var spaced = ""
    var previous: Character?
    for character in raw {
        if let previous, character.isUppercase, !previous.isUppercase, previous != "-" {
            spaced.append(" ")
        }
        spaced.append(character)
        previous = character
    }
    return spaced.replacingOccurrences(of: "-", with: " ").capitalized
}

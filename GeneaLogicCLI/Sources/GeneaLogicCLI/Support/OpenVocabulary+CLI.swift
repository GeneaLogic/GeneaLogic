import GeneaLogicModel

/// Parses a CLI argument into an `OpenVocabulary` value (`MediaType`,
/// `SourceAuthorityTier`, `FactType`, …).
///
/// A thin alias for the model's `parsingLeniently` so call sites read
/// `MediaType.parsing(argument)`. The rule itself — fold to a known case
/// case/whitespace-insensitively, else preserve the value verbatim as
/// `.unknown` — lives in `GeneaLogicModel` (slice 44c) because the app needs the
/// identical behavior, and because getting it wrong produces `.unknown("birth")`
/// sitting beside `.birth`: two values that render the same and never compare
/// equal.
///
/// Note this is emphatically *not* `init(parsing:)`, which is the decode path and
/// must keep round-tripping stored values verbatim — see `parsingLeniently`.
extension OpenVocabulary {
    static func parsing(_ argument: String) -> Self {
        parsingLeniently(argument)
    }
}

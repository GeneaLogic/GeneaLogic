import GeneaLogicModel

extension OpenVocabulary {
    /// The known cases for a `Picker`, plus `anchor` when it's an unrecognized
    /// (`.unknown(...)`) term authored elsewhere — so the picker never silently drops a
    /// value it can't otherwise represent.
    ///
    /// Pass a **stable** anchor (the record's original value), not the live selection:
    /// anchoring on the mutable selection would make the `.unknown` option vanish the
    /// moment the user picks a known case, with no way back to it.
    static func pickerOptions(including anchor: Self) -> [Self] {
        pickerOptions(from: knownCases, including: anchor)
    }

    /// The same rule over a **restricted** base list rather than all `knownCases` — so a
    /// picker can offer just the relevant subset (e.g. `FactType.coupleCases` for a
    /// couple's marriage/divorce facts) while still surfacing an `.unknown(...)` (or any
    /// off-list) `anchor` already stored on the record.
    static func pickerOptions(from base: [Self], including anchor: Self) -> [Self] {
        base.contains(anchor) ? base : base + [anchor]
    }
}

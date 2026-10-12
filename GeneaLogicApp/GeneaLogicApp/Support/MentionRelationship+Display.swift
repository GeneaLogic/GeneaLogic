import GeneaLogicModel

/// How a stated edge (slice 45k) reads **from one end of it** — the one place that decides,
/// for every surface that shows one.
///
/// It exists because the phrasing was open-coded twice, in the mention editor and in the
/// artifact inspector's row, and hand-testing found both copies saying something ambiguous
/// in the same way. `Parent: Marcus Feldberg` under a name leaves the direction to the
/// reader: is Marcus the parent, or is this person Marcus's? §4.5 fixes the direction on
/// disk, and a label that doesn't carry it hands the reader a coin to flip.
///
/// So the phrase is **possessive and explicit** — *Their parent: Marcus Feldberg* — and the
/// pronoun's antecedent is always the row it sits under. `their` rather than a gendered
/// pronoun because a `PersonMention` records a name as written, never a gender: the record
/// may not say, and the app must not guess.
extension MentionRelationship {

    /// This edge as read from `selfRef`'s side, e.g. `"Their parent: Marcus Feldberg"`.
    ///
    /// - Parameters:
    ///   - selfRef: The mention whose row this is — the referent of *their*.
    ///   - name: Resolves the other endpoint's recorded name; `nil` when the record no
    ///     longer carries that mention.
    func phrase(from selfRef: String, name: (String) -> String?) -> String {
        let otherRef = other(from: selfRef) ?? person2Ref
        // A ref the record no longer carries renders as "(removed)" rather than vanishing
        // or showing a raw `localRef`: that dangle is what the integrity panel reports, so
        // no surface should be the one that hides it — and a `localRef` tells a reader
        // nothing at all.
        let displayName = name(otherRef) ?? "(removed)"
        return "\(label(from: selfRef)): \(displayName)"
    }

    /// The possessive label alone — *Their parent*, *Their child*, *Their partner* — for a
    /// caller that lays the name out itself.
    func label(from selfRef: String) -> String {
        switch type {
        case .parentChild:
            // §4.5's direction, read through the accessor rather than by hand: if this
            // mention is the parent, the other end is their child.
            return parentRef == selfRef ? "Their child" : "Their parent"
        case .couple:
            return "Their partner"
        case .unknown(let raw):
            // An unknown type is directional and this version cannot know which way, so it
            // is reported verbatim rather than dressed in a possessive that might invert it.
            return raw
        }
    }
}

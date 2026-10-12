//
//  DanglingReference+Display.swift
//  GeneaLogicApp
//

import Foundation
import GeneaLogicArchive
import GeneaLogicModel

/// Row text for the integrity panel's **Dangling References** group.
///
/// These rows stay in the panel's diagnostic register — kind, the uid of the
/// record that holds the broken pointer, and what it points at — rather than
/// resolving display names. The record on the *other* end is gone by definition,
/// so there is no name to show for it, and the uid is what makes the survivor
/// findable (it's what the CLI's `person show` / `find` take).
extension DanglingReference {
    /// A short kind label shown as the row's headline.
    var summary: String {
        switch self {
        case .relationshipEndpoint: "Relationship names a deleted person"
        case .relationshipSupport, .relationshipFactSupport, .personFactSupport:
            "Citation points at a removed link"
        case .linkArtifact: "Citation names a deleted document"
        case .linkPerson: "Citation names a deleted person"
        case .linkMention: "Citation names a removed mention"
        case .mentionRelationshipEndpoint: "Document states a relationship to a removed mention"
        case .dismissalEndpoint: "Dismissed suggestion names a deleted person"
        }
    }

    /// The uid of the record that still exists and carries the broken pointer —
    /// the one a human would edit or delete to resolve the finding.
    var holderUID: String {
        switch self {
        case .relationshipEndpoint(let relationship, _): relationship.raw
        case .relationshipSupport(let relationship, _): relationship.raw
        case .relationshipFactSupport(let relationship, _, _): relationship.raw
        case .personFactSupport(let person, _, _): person.raw
        case .linkArtifact(let link, _): link.raw
        case .linkPerson(let link, _): link.raw
        case .linkMention(let link, _, _): link.raw
        case .mentionRelationshipEndpoint(let artifact, _, _): artifact.raw
        case .dismissalEndpoint(let dismissal, _): dismissal.raw
        }
    }

    /// A one-line explanation naming the missing target, shown beneath the uid.
    var detail: String {
        switch self {
        case .relationshipEndpoint(_, let person):
            "One end of this relationship is \(person.raw), which no longer exists."
        case .relationshipSupport(_, let link):
            "This relationship cites evidence link \(link.raw), which was unlinked."
        case .relationshipFactSupport(_, let factIndex, let link):
            "Fact \(factIndex + 1) cites evidence link \(link.raw), which was unlinked."
        case .personFactSupport(_, let factIndex, let link):
            "Fact \(factIndex + 1) cites evidence link \(link.raw), which was unlinked."
        case .linkArtifact(_, let artifact):
            "This link cites document \(artifact.raw), which was deleted."
        case .linkPerson(_, let person):
            "This link resolves to person \(person.raw), which was deleted."
        case .linkMention(_, let artifact, let missingRef):
            "The mention “\(missingRef)” it cites is gone from document \(artifact.raw)."
        case .mentionRelationshipEndpoint(_, let edgeIndex, let missingRef):
            "Stated relationship \(edgeIndex + 1) names mention “\(missingRef)”, "
                + "which was removed from this document."
        case .dismissalEndpoint(_, let person):
            "This “not a duplicate” record names person \(person.raw), which was deleted. "
                + "It still keeps that pair out of the suggestion queue."
        }
    }

    /// Whether some view in the app actually *renders* this finding, and so whether
    /// offering "Reveal" leads anywhere useful.
    ///
    /// Only four of the nine do. A broken `supportedByLinks` citation is not drawn
    /// anywhere (a person fact shows "cited by N sources" — the count, never which),
    /// and a link whose **mention** is gone has no row either, since the Persons
    /// Mentioned section iterates *mentions*: the row it would appear on is precisely
    /// what was deleted. Revealing those would dismiss the panel onto a page that looks
    /// entirely normal, having thrown away the only thing that named the problem — so
    /// the panel's own Remove Stale Reference is their fix, and Reveal is not offered.
    var isRevealable: Bool {
        switch self {
        // The artifact's mention row → "Missing person" + Re-resolve…
        case .linkPerson: true
        // The person's Sources row → "Unknown artifact" + Unlink.
        case .linkArtifact: true
        // The person's Relationships row → "Unknown person" + Replace Person…
        case .relationshipEndpoint: true
        // The artifact's Persons Mentioned section, where the stated relationships are
        // drawn under the rows they connect — and where the edge can be edited away.
        // **Conditionally useful, and the condition is checked at reveal time**: this
        // enum can't see the record, and an edge that lost *both* ends is drawn on no
        // row at all. `revealDanglingReference` answers `false` for that case rather
        // than dismissing the panel onto a page with nothing on it.
        case .mentionRelationshipEndpoint: true
        // Nothing draws a dismissal — it works by making something *not* appear — so
        // there is no row to reveal, and Remove Stale Reference is the fix.
        case .dismissalEndpoint: false
        case .linkMention, .relationshipSupport, .relationshipFactSupport, .personFactSupport:
            false
        }
    }

    /// SF Symbol for the row. Constant, unlike `IntegrityReport.Issue`'s: the
    /// file report uses the symbol to tell corruption from strays, while every
    /// finding here is the same kind of problem.
    ///
    /// The rows share the stray files' orange rather than corruption's red, and
    /// that is deliberate: a dangling reference is worth reviewing but is not
    /// data loss — nothing is unrecoverable, the pointer just needs clearing.
    var systemImage: String { "exclamationmark.triangle.fill" }
}

// `DanglingReference` is `Hashable` and the sweep de-duplicates its output, so
// the value **is** its own `ForEach` identity — no synthesized string id (the
// one `IntegrityReport.Issue` needs, being only `Equatable`). Deriving identity
// from display prose would also make editing a user-facing string a row-identity
// change.

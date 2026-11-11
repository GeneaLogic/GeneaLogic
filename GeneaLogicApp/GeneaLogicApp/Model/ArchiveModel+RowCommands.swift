import Foundation
import GeneaLogicArchive
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Row commands (slice 83b)

    /// Runs a row command the model can run from its subject's ids, and says whether it
    /// did. One that opens a sheet is left for the pane that drew the row.
    func performRowCommand(_ command: ArchiveCommand, on subject: CommandSubject) -> Bool {
        switch (command, subject) {
        case (.showMentionedPerson, .mention(let target)):
            if case .linked(_, let person) = target.link { navigateToPerson(person) }
        case (.unlinkMention, .mention(let target)):
            if let link = target.link.id { unlinkMention(link) }
        case (.removeMention, .mention(let target)):
            removeMention(target)
        case (.recordSuggestedFact, .factSuggestion(let target)):
            if let suggestion = factSuggestion(target) {
                recordSuggestedFact(suggestion, for: target.person)
            }
        case (.recordSuggestedRelationship, .relationshipSuggestion(let target)):
            if let item = relationshipSuggestion(target) { confirmSuggestedRelationship(item) }
        case (.dismissSuggestedRelationship, .relationshipSuggestion(let target)):
            if let item = relationshipSuggestion(target) { dismissSuggestedRelationship(item) }
        case (.showSource, .source(let target)):
            navigateToArtifact(target.artifact)
        case (.unlinkSource, .source(let target)):
            unlinkMention(target.link)
        case (.showRelative, .relationship(let target)):
            navigateToPerson(target.other)
        case (.removeRelationship, .relationship(let target)):
            deleteRelationship(target.relationship)
        case (.confirmCandidate, .candidate(let target)),
            (.rejectCandidate, .candidate(let target)):
            decideCandidate(target, confirming: command == .confirmCandidate)
        default:
            return false
        }
        return true
    }

    /// Removes a mention (undoable). It is found by `localRef`, starting at the row's
    /// index, in the record the write reads: a list that shifted since removes this
    /// mention or nothing (79b). Any `EvidenceLink` pointing at the removed `localRef` is
    /// left dangling — that's `verifyIntegrity()`'s job (§2.3).
    private func removeMention(_ target: MentionTarget) {
        let ref = target.localRef
        let index = target.index
        updateMetadata(of: target.artifact, actionName: "Remove Person Mentioned") {
            guard
                let position = $0.personsMentioned.position(
                    near: index, where: { $0.localRef == ref })
            else { return }
            $0.personsMentioned.remove(at: position)
        }
    }

    /// The suggestion `target` names, read afresh by the code the person pane and Review's
    /// lane both read (`SuggestedFacts`), so the write records what the row showed.
    func factSuggestion(_ target: FactSuggestionTarget) -> FactSuggestion? {
        let recordedFacts = SuggestedFacts.recordedFacts(
            of: fullPerson(target.person), relationships: relationships(of: target.person))
        return linkedEvidence(for: target.person, recordedFacts: recordedFacts)
            .suggestions.first { $0.id == target.id }
    }

    /// The suggested relationship `target` names, from its surface's own list.
    func relationshipSuggestion(
        _ target: RelationshipSuggestionTarget
    ) -> RelationshipReviewItem? {
        let items =
            switch target.owner {
            case .artifact(let id): suggestedRelationships(forArtifact: id)
            case .person(let id): suggestedRelationships(for: id)
            }
        return items.first { $0.id == target.id }
    }
}

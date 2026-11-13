import GeneaLogicModel
import SwiftUI

// The verbs on rows inside panes (slice 83b): a mention's Resolve…, a metadata entry's
// Apply…, a suggestion's Record. A pane's rows have no selection, so these have no
// menu-bar item; the row's buttons and its context menu draw from the one source.
//
// Each subject carries the row's state its availability reads, as `ReviewTarget`'s lane
// does for Review, so availability stays a pure function. It also carries the row's own
// value where a command needs one (the mention, the suggestion), so what runs it acts on
// exactly what the row showed rather than looking the row up again, which costs a reload
// and can miss.
//
// Those values are only `Equatable`, so a subject that carries one hashes by the row's
// identity alone: equal subjects still hash alike, as `Hashable` requires.

/// A mention in the inspector's *Persons Mentioned*.
struct MentionTarget: Hashable {
    /// What the mention is linked to.
    enum Link: Hashable {
        case none
        case linked(EvidenceLinkID, to: PersonID)
        /// Linked to a person who no longer exists (§2.3, no cascade).
        case stale(EvidenceLinkID)

        var id: EvidenceLinkID? {
            switch self {
            case .none: nil
            case .linked(let id, _), .stale(let id): id
            }
        }

        var isStale: Bool {
            if case .stale = self { true } else { false }
        }
    }

    let artifact: ArtifactID
    /// The mention as the row drew it: what its sheets open on. A `localRef` repeated in
    /// a hand-edited record names two mentions, and this is the row's one (79b).
    let mention: PersonMention
    /// Where the row was drawn: the hint a remove starts from (79b).
    let index: Int
    let link: Link
    /// Whether the record names anyone else, for Add Relationship… to relate it to.
    let namesOthers: Bool

    var localRef: String { mention.localRef }

    func hash(into hasher: inout Hasher) {
        hasher.combine(artifact)
        hasher.combine(mention.localRef)
        hasher.combine(index)
    }
}

/// A suggested fact, on a person's pane or in Review's facts lane.
struct FactSuggestionTarget: Hashable {
    let person: PersonID
    /// The suggestion as the row drew it: what Record records and Edit… opens.
    let suggestion: FactSuggestion

    var isDirectlyRecordable: Bool { suggestion.isDirectlyRecordable }
}

/// A suggested relationship, in the inspector or on a person's pane.
struct RelationshipSuggestionTarget: Hashable {
    /// The suggestion as the row drew it: what Record and Not This are handed.
    let item: RelationshipReviewItem

    func hash(into hasher: inout Hasher) {
        hasher.combine(item.id)
    }
}

/// One of a person's sources.
struct SourceTarget: Hashable {
    let person: PersonID
    let link: EvidenceLinkID
    let artifact: ArtifactID
    /// The citing artifact still exists, so there is somewhere to jump to.
    let artifactExists: Bool
    /// The mention's name as recorded, when it isn't yet one of the person's names.
    let newName: String?
}

/// One of a person's relationships.
struct RelationshipTarget: Hashable {
    let person: PersonID
    let relationship: RelationshipID
    let other: PersonID
    /// The other person still exists. When not, the row dangles (§2.3).
    let otherExists: Bool
    /// "parent", "partner": what Replace Person…'s picker asks for.
    let roleDescription: String
}

/// One candidate card in Review's names lane.
struct CandidateTarget: Hashable {
    let row: ReviewTarget
    let person: PersonID
}

extension CommandSubject {
    /// Whether this row's state offers `command`, the row half of `canPerform`.
    func offers(_ command: ArchiveCommand) -> Bool {
        switch (command, self) {
        case (.resolveMention, .mention(let target)):
            if case .linked = target.link { false } else { true }
        case (.showMentionedPerson, .mention(let target)):
            if case .linked = target.link { true } else { false }
        case (.unlinkMention, .mention(let target)): target.link != .none
        case (.addMentionRelationship, .mention(let target)): target.namesOthers
        case (.recordSuggestedFact, .factSuggestion(let target)): target.isDirectlyRecordable
        case (.showSource, .source(let target)): target.artifactExists
        case (.addSourceName, .source(let target)): target.newName != nil
        case (.showRelative, .relationship(let target)): target.otherExists
        case (.replaceRelative, .relationship(let target)): !target.otherExists
        default: true
        }
    }

    /// The row's context menu: its decision, its jump, its edits and adds, then the verbs
    /// that take something away, after a divider. What the row's state doesn't offer is
    /// left out by the menu, not dimmed.
    var rowMenu: [[ArchiveCommand]] {
        switch self {
        case .mention:
            [
                [
                    .resolveMention, .showMentionedPerson, .editMention, .addMentionFact,
                    .addMentionRelationship,
                ],
                [.unlinkMention, .removeMention],
            ]
        case .metadataEntry: [[.applyMetadata]]
        case .factSuggestion: [[.recordSuggestedFact, .editSuggestedFact]]
        case .relationshipSuggestion:
            [[.recordSuggestedRelationship], [.dismissSuggestedRelationship]]
        case .source: [[.showSource, .addSourceName], [.unlinkSource]]
        case .relationship: [[.showRelative, .replaceRelative], [.removeRelationship]]
        case .candidate: [[.confirmCandidate], [.rejectCandidate]]
        case .archive, .artifact, .file, .person, .review: []
        }
    }
}

extension CommandSubject {
    /// The row's context menu as it shows: `rowMenu` with what the row's state doesn't
    /// offer taken out, and empty groups dropped. A verb waiting on a write is dimmed by
    /// its item rather than left out, so the menu doesn't change shape under the pointer.
    var offeredRowMenu: [[ArchiveCommand]] {
        rowMenu.map { $0.filter(offers) }.filter { !$0.isEmpty }
    }
}

/// A row's context menu (`offeredRowMenu`).
struct RowCommandMenu: View {
    let subject: CommandSubject

    var body: some View {
        let groups = subject.offeredRowMenu
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index], id: \.self) { CommandButton($0, on: subject, inPane: true) }
        }
    }
}

extension View {
    /// The context menu of the row `subject` names (slice 83b).
    func rowCommandMenu(_ subject: CommandSubject) -> some View {
        contextMenu { RowCommandMenu(subject: subject) }
    }
}

/// A row's small inline verb (Resolve…, Unlink, Record), drawn from the command and shown
/// only while the row's state offers it, so the button and the context menu can't
/// disagree. Dimmed, not hidden, while a write it waits for is in flight, so the row
/// doesn't reflow.
struct RowCommandButton: View {
    /// How the verb reads beside the row's text.
    enum Emphasis {
        /// The row's next step, in the accent colour.
        case primary
        /// A verb that undoes or declines, in secondary.
        case secondary
    }

    @Environment(ArchiveModel.self) private var model
    let command: ArchiveCommand
    let subject: CommandSubject
    var emphasis = Emphasis.primary
    var showsSymbol = false

    init(
        _ command: ArchiveCommand, on subject: CommandSubject, emphasis: Emphasis = .primary,
        showsSymbol: Bool = false
    ) {
        self.command = command
        self.subject = subject
        self.emphasis = emphasis
        self.showsSymbol = showsSymbol
    }

    var body: some View {
        if subject.offers(command) {
            Button {
                model.perform(command, on: subject)
            } label: {
                let title = command.paneTitle(on: subject)
                if showsSymbol {
                    Label(title, systemImage: command.systemImage(on: subject))
                } else {
                    Text(title)
                }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(emphasis == .primary ? Color.accentColor : Color.secondary)
            .help(command.help(on: subject) ?? "")
            .disabled(!model.canOffer(command, on: subject))
        }
    }
}

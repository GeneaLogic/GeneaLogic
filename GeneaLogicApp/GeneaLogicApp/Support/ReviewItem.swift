import GeneaLogicArchive
// `ScoredMatch` lives in `GeneaLogicMatch` and reaches here re-exported by
// `GeneaLogicArchive`'s `public import` (slice 45b). The app target enables
// `MemberImportVisibility`, under which a re-export makes a type *nameable* but not its
// members readable — so reading a score needs the defining module named here. No target
// dependency is added; the module is already transitively available.
import GeneaLogicMatch
import GeneaLogicModel

/// What a Review sidebar selection points at — the section carries **two lanes in one
/// list** (slice 45i), and one selection has to be able to name a row in either.
///
/// Kept as a prefixed string rather than the enum itself because the selection is
/// `@SceneStorage`-persisted, and because the ids double as `ForEach` identities. Nothing
/// parses one back: the detail pane resolves a selection by looking for it in the two
/// worklists, so an id left over from a previous launch (a mention since resolved, a
/// person since deleted, or a pre-45i unprefixed id) simply doesn't match and the pane
/// falls back to its placeholder — which is what should happen anyway.
enum ReviewSelection {
    case mention(MentionRef)
    case person(PersonID)
    case duplicate(PersonID, PersonID)
    case relationship(RelationshipType, PersonID, PersonID)

    var id: String {
        switch self {
        case .mention(let ref): "mention|\(ref.artifact.raw)|\(ref.localRef)"
        case .person(let id): "person|\(id.raw)"
        // The pair arrives in canonical (uid) order from the engine, so this is stable
        // across scans rather than depending on which person the loop reached first.
        case .duplicate(let first, let second): "duplicate|\(first.raw)|\(second.raw)"
        // The **type** is part of the identity, not decoration: the same two people can be
        // proposed as a couple and as parent-and-child at once, and those are two rows with
        // two separate judgements (which is why 45m's dismissal carries a subject).
        case .relationship(let type, let first, let second):
            "relationship|\(type.rawValue)|\(first.raw)|\(second.raw)"
        }
    }
}

/// One row of the Review section's worklist: an **unresolved mention**, the record
/// context needed to judge it, and everyone the matcher thinks it might be (slice 45e).
///
/// A view projection, assembled by `ArchiveModel.refreshReviewWorklist()`. The engine's
/// `MentionSuggestions` carries ids and scores and deliberately no display fields — they
/// would go stale the moment either record was edited — so resolving the recorded name,
/// the artifact title and the candidates' names is this layer's job.
///
/// **`candidates` may be empty, and that is the point.** A mention nothing matched is
/// exactly the *somebody new* case; if the worklist dropped it, "this record names
/// nobody", "every name on it is resolved" and "here is a name the archive has never
/// seen" would be one indistinguishable absence, and only the last has work attached.
struct ReviewItem: Identifiable {
    /// The pair of ids that addresses this mention — what every write path takes.
    let mention: MentionRef

    /// The citing document's title, for context in the row and the pane.
    let artifactTitle: String

    /// The mention itself: the name as recorded, its role, its recorded facts, its age.
    /// Carried whole rather than field by field because it is also the input to
    /// `createPersonAndLink` on the somebody-new path.
    let recordedMention: PersonMention

    /// Who this might be, best first. Empty when nothing cleared the confidence floor.
    var candidates: [ReviewCandidate]

    /// The rejection tombstones already on this **mention** (any person), populated only
    /// for a candidate-less item — the one case that reads them.
    ///
    /// The distinction 45d's tuning pass turned up in the CLI: candidates disappear for
    /// **two** reasons — scoring under the floor, and being foreclosed by an earlier
    /// rejection — and the engine's result cannot tell them apart. Blaming the floor
    /// unconditionally sends a user who rejected the only candidate off to lower a
    /// threshold forever, when the fix is one un-reject.
    ///
    /// Carried as the **links** rather than a count so that fix is reachable from here:
    /// un-rejecting is deleting the tombstone, which needs its `uid`.
    var rejectedLinks: [EvidenceLink]

    var rejectedCount: Int { rejectedLinks.count }

    /// Stable across reloads: the mention's own address, not a synthesized id that would
    /// re-create the row (and drop its state) on every refresh. Lane-prefixed since 45i,
    /// because the facts lane shares this selection space.
    var id: String { ReviewSelection.mention(mention).id }

    var recordedName: String { recordedMention.nameAsRecorded }

    /// What to say when there is nothing to offer — never "this is a new person".
    ///
    /// The wording states what actually happened (nothing reached the floor) and, when
    /// the mention carries rejections, that they exist. It deliberately proposes nothing:
    /// the matcher's blind spot is the name it cannot recognize at all, so this is the
    /// weakest possible ground for a conclusion about who the person is.
    func noCandidateExplanation(floor: Int) -> String {
        var text = "No one in this archive scored \(floor) or above against this name."
        if rejectedCount > 0 {
            text +=
                rejectedCount == 1
                ? " One candidate here was rejected earlier and isn’t offered again."
                : " \(rejectedCount) candidates here were rejected earlier and aren’t offered again."
        }
        return text
    }
}

/// One row of the Review section's **second** lane: a person who has promotable evidence
/// waiting on their linked sources (slice 45i).
///
/// A row is a **person, not a suggestion**. Their evidence is reviewed together — eight
/// facts off one census are one act of judgement about one person, not eight trips through
/// a queue — and it puts this pane and `PersonDetailView`'s own Suggested Facts section
/// side by side showing the same list, which is the agreement the lane has to keep.
///
/// A person with nothing pending isn't here at all: unlike the links lane, where an
/// unresolved mention with no candidates is itself the work (`ReviewItem`), a person with
/// no un-promoted evidence has nothing owed.
struct FactReviewItem: Identifiable {
    let person: PersonSummary
    var suggestions: [FactSuggestion]

    var id: String { ReviewSelection.person(person.uid).id }
    /// Same fallback as `ReviewCandidate`: a person with no name yet is a normal state
    /// (they exist, they're just unnamed), and reading their uid here would say nothing.
    var displayName: String { person.displayName ?? "Unnamed person" }
    var subtitle: String { person.browseSubtitle }
}

/// One row of the Review section's **third** lane: two concluded persons that may be one
/// person, and the matcher's reasoning for thinking so (slice 45m over 45j's scorer).
///
/// Unlike the other two lanes, the action on offer is **destructive** — a merge rewrites
/// every record naming the absorbed person — so the row exists to be read, not to be
/// cleared quickly. The decomposed breakdown is what the pane shows; `aggregateConfidence`
/// only orders the queue.
///
/// Either summary may be `nil`: a person removed between the scan and the render is a
/// normal state (§2.3 — removals don't cascade), not an error.
struct DuplicateReviewItem: Identifiable {
    /// The pair and its `DuplicateScore` — handed to `dismiss` unchanged, so a declined
    /// record stores **the reasoning the user was shown** rather than a recomputation.
    let candidate: DuplicateCandidate

    let first: PersonSummary?
    let second: PersonSummary?

    var id: String { ReviewSelection.duplicate(candidate.person1, candidate.person2).id }

    /// Same fallback as `ReviewCandidate`: an unnamed person is a normal state, and their
    /// uid would say nothing to a reader deciding whether two records are one human being.
    var firstName: String { first?.displayName ?? "Unnamed person" }
    var secondName: String { second?.displayName ?? "Unnamed person" }

    var confidence: Int { candidate.match.aggregateConfidence }
}

/// One row of the Review section's **fourth** lane: a relationship the archive's records
/// state (or unambiguously imply) that `conclusions/` does not yet assert (slice 45l).
///
/// **The only lane with no confidence figure**, and the absence is the design. Both
/// endpoints' links were already confirmed by a human, so nothing here is a guess about
/// identity; what the record says about who is whose is either stated outright or read off
/// its roles, and *which of those two* is the reasoning a reviewer needs. A number would
/// have to be invented to sit here.
///
/// Either summary may be `nil`: a person removed between the sweep and the render is a
/// normal state (§2.3 — removals don't cascade), not an error.
struct RelationshipReviewItem: Identifiable {
    /// The proposal and its supporting records — handed to `confirm`/`dismiss` unchanged.
    let suggestion: SuggestedRelationship

    let first: PersonSummary?
    let second: PersonSummary?

    /// The titles of the records behind it, in the engine's evidence order. Resolved here
    /// rather than carried by the engine, for the reason `SuggestedLink` carries no display
    /// fields: a title goes stale the moment the record is renamed.
    let sourceTitles: [String]

    var id: String {
        ReviewSelection.relationship(
            suggestion.type, suggestion.person1, suggestion.person2
        ).id
    }

    var firstName: String { first?.displayName ?? "Unnamed person" }
    var secondName: String { second?.displayName ?? "Unnamed person" }

    /// The claim in words, from `person1`'s side — the direction §4.5 fixes, said out loud
    /// so nobody has to remember which endpoint is the parent.
    var claim: String {
        switch suggestion.type {
        case .parentChild: "\(firstName) is a parent of \(secondName)"
        case .couple: "\(firstName) and \(secondName) are a couple"
        case .unknown(let raw): "\(firstName) → \(secondName) (\(raw))"
        }
    }

    /// The one citation a single-line row names: a **stating** record when any record states
    /// it, otherwise the first that implies it — with *that record's own* basis.
    ///
    /// The pairing is the point. `suggestion.isStated` is an **archive-wide** flag ("some
    /// record states this"), and reading it beside a particular title claims that *this*
    /// document stated it — so a suggestion implied by record A and stated by record B told
    /// the reader that A states it. Found by `/code-review`. A one-line row has to name the
    /// title and the basis **together or not at all**; the detail pane, which lists every
    /// citation with its own basis, never had the problem.
    var leadCitation: (title: String, basis: RelationshipBasis)? {
        let index =
            suggestion.evidence.firstIndex { $0.basis == .stated }
            ?? suggestion.evidence.indices.first
        guard let index, sourceTitles.indices.contains(index) else { return nil }
        return (sourceTitles[index], suggestion.evidence[index].basis)
    }

    /// How **one particular record** supports the claim, or `nil` if it doesn't — what the
    /// artifact inspector shows, since a row there is standing on that record and must speak
    /// for it rather than for the archive.
    func basis(on artifact: ArtifactID) -> RelationshipBasis? {
        suggestion.evidence.first { $0.artifact == artifact }?.basis
    }

    /// The claim as read from **one endpoint's** side — `"Their parent: Szlama Feldberg"` —
    /// for a surface already about that person, where `claim`'s two full names would repeat
    /// the page's own title back at the reader.
    ///
    /// Possessive rather than a bare `Parent:` label, which is the phrasing hand-testing
    /// found ambiguous on the evidence side (see `MentionRelationship+Display`): the label
    /// alone leaves it open whether the named person is the parent or the child. `their`
    /// because a person's gender is not something this app infers to render a row.
    ///
    /// Falls back to the full `claim` for an unknown type, whose direction this version
    /// cannot name in a possessive without risking inverting it.
    func phrase(from subject: PersonID) -> String {
        switch suggestion.type {
        case .parentChild:
            return subject == suggestion.person2
                ? "Their parent: \(firstName)"
                : "Their child: \(secondName)"
        case .couple:
            return subject == suggestion.person1
                ? "Their partner: \(secondName)"
                : "Their partner: \(firstName)"
        case .unknown:
            return claim
        }
    }
}

/// One candidate person for a mention: the engine's scored pair, plus the name to show.
struct ReviewCandidate: Identifiable {
    /// The pair and its breakdown — what `confirm`/`reject` are handed, so the record
    /// stores **the score the user was shown** rather than a recomputation (45c).
    let suggestion: SuggestedLink

    /// The concluded person, or `nil` if they were deleted between the sweep and now
    /// (§2.3 — removals don't cascade, so this is a normal state, not an error).
    let person: PersonSummary?

    var id: String { suggestion.personID.raw }

    var displayName: String {
        person?.displayName ?? "Unnamed person"
    }

    var subtitle: String {
        person?.browseSubtitle ?? suggestion.personID.raw
    }

    /// 0–100. **Only ever an ordering aid and a secondary figure** — §4.6's whole point
    /// is that the breakdown beside it is what a human reviews, so this never appears
    /// without those rows.
    var confidence: Int { suggestion.match.aggregateConfidence }
}

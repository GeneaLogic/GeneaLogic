import Foundation
import GeneaLogicModel

// `public`, because `SuggestedLink.match` and `matchScore` hand `ScoredMatch` across
// this module's public boundary. Without it a consumer that imports only
// `GeneaLogicArchive` receives a type it cannot name — and under
// `MemberImportVisibility` cannot even read members of — so every downstream target
// (45d's CLI, 45e's app) would have to declare a dependency on a module it never
// mentions. Re-exporting is the honest statement: the matcher's vocabulary is part of
// this API.
public import GeneaLogicMatch

/// Candidate generation — the seam that points slice 45's scorer at a real archive
/// (ARCHITECTURE.md §4.6, §6.3).
///
/// `GeneaLogicMatch` compares two plain value views and returns a ``ScoredMatch``; it
/// has never heard of an archive. This file is the other side of that boundary: it
/// walks the records, projects them into those views, scores the pairs worth scoring,
/// and returns the results ranked.
///
/// **Suggestions are ephemeral.** Nothing here writes. A `SuggestedLink` has no uid,
/// no provenance and no sidecar — it is a computed opinion that lives until the caller
/// drops it. Turning one into an `EvidenceLink` takes a human, and that path is slice
/// 45c's. This is what keeps `conclusions/` meaning *conclusions* (§2.3): no read path
/// has to filter out unreviewed machine guesses, because none are ever stored, and a
/// re-run reflects the archive as it is now rather than reconciling against stale
/// suggestion records.
extension Archive {

    // MARK: - Suggestion

    /// Suggests mentions across the archive that may name `personID`.
    ///
    /// The inspector-primary direction (§6.3): the user is looking at a person and
    /// asking what else in the archive is about them.
    ///
    /// - Parameters:
    ///   - personID: The concluded person to find evidence for.
    ///   - minimumConfidence: Suggestions scoring below this are dropped. See
    ///     ``defaultMinimumConfidence`` for what the default excludes.
    ///   - limit: At most this many suggestions, taking the highest-scoring; `nil`
    ///     for all of them.
    /// - Returns: Suggestions ranked by `aggregateConfidence`, highest first.
    ///   Empty if `personID` doesn't exist — a missing person has no evidence, which
    ///   is the same answer as a person nothing matches.
    public func suggestLinks(
        for personID: PersonID,
        minimumConfidence: Int = Archive.defaultMinimumConfidence,
        limit: Int? = nil
    ) -> [SuggestedLink] {
        withIndex { index in
            guard let person = try? index.person(personID) else { return [] }
            let corpus = (try? MatchCorpus.forSuggestion(index: index)) ?? MatchCorpus.empty
            // The only direction that needs every artifact — it is asking what, across
            // the whole archive, might name this person.
            let artifacts = (try? index.allArtifacts()) ?? []
            return corpus.suggestions(
                persons: [person],
                artifacts: artifacts,
                minimumConfidence: minimumConfidence,
                limit: limit)
        }
    }

    /// Suggests concluded persons that this artifact's mentions may name, **one entry
    /// per unresolved mention**.
    ///
    /// The other direction of the same question, and equally necessary: the user is
    /// looking at a newly catalogued record and asking who in the tree is on it. This
    /// is the triage surface, so it is grouped rather than flat — see
    /// ``MentionSuggestions`` for why a mention that matched *nothing* has to be in the
    /// result rather than absent from it.
    ///
    /// - Parameters:
    ///   - artifactID: The artifact whose unresolved mentions to match.
    ///   - minimumConfidence: Candidates scoring below this are dropped. The mention
    ///     itself is still reported, with no candidates.
    ///   - limit: At most this many candidates **per mention**, taking the
    ///     highest-scoring; `nil` for all of them.
    /// - Returns: The artifact's unresolved mentions in record order, each with its
    ///   candidates ranked by `aggregateConfidence`. Empty if `artifactID` doesn't
    ///   exist, or if every mention on it is already resolved.
    public func suggestLinks(
        forArtifact artifactID: ArtifactID,
        minimumConfidence: Int = Archive.defaultMinimumConfidence,
        limit: Int? = nil
    ) -> [MentionSuggestions] {
        withIndex { index in
            guard let artifact = try? index.artifact(artifactID) else { return [] }
            let corpus = (try? MatchCorpus.forSuggestion(index: index)) ?? MatchCorpus.empty
            return corpus.groupedSuggestions(
                persons: corpus.persons,
                artifact: artifact,
                minimumConfidence: minimumConfidence,
                limit: limit)
        }
    }

    /// Suggests concluded persons for **every unresolved mention in the archive**, one
    /// entry per mention.
    ///
    /// The worklist direction (slice 45e), and the reason it is a third entry point
    /// rather than the app looping over ``suggestLinks(forArtifact:minimumConfidence:limit:)``:
    /// the corpus — every person, every relationship, every link — is built **once**
    /// here, where a loop rebuilds and re-projects all of it per artifact. Same results,
    /// one pass.
    ///
    /// Grouped for the same reason the artifact direction is: a triage queue whose
    /// zero-candidate mentions were absent would be missing exactly the work worth
    /// doing. See ``MentionSuggestions``.
    ///
    /// **Document order, not confidence order.** Mentions come artifact by artifact (by
    /// `uid`, so a UUIDv7 archive reads in cataloguing order) and then in each
    /// artifact's own `personsMentioned` order; only the candidates within a mention are
    /// ranked. A mention nothing scored has no confidence to sort on, so an overall
    /// ranking could not place it at all — and grouping the queue for display is a
    /// decision about a *reader*, which is the caller's to make (the same reasoning that
    /// keeps display fields off ``SuggestedLink``).
    ///
    /// - Parameters:
    ///   - minimumConfidence: Candidates scoring below this are dropped; the mention is
    ///     still reported, with no candidates.
    ///   - limit: At most this many candidates **per mention**; `nil` for all of them.
    /// - Returns: Every unresolved mention in the archive, each with its ranked
    ///   candidates. Empty when the archive has no unresolved mentions at all.
    public func suggestLinks(
        minimumConfidence: Int = Archive.defaultMinimumConfidence,
        limit: Int? = nil
    ) -> [MentionSuggestions] {
        withIndex { index in
            let corpus = (try? MatchCorpus.forSuggestion(index: index)) ?? MatchCorpus.empty
            // `allArtifacts()` has no `ORDER BY`, and SQLite's unordered row order is
            // unspecified — a queue that reshuffled between launches for no reason the
            // user could see would be a bug, so the order is imposed here rather than
            // inherited from the index.
            let artifacts = ((try? index.allArtifacts()) ?? []).sorted { $0.uid.raw < $1.uid.raw }
            return corpus.groupedSuggestions(
                persons: corpus.persons,
                artifacts: artifacts,
                minimumConfidence: minimumConfidence,
                limit: limit)
        }
    }

    /// Scores one specific mention against one specific person, whatever their
    /// review state and however badly they score.
    ///
    /// The explain path. ``suggestLinks(for:minimumConfidence:limit:)`` answers "what
    /// should I look at?" and therefore hides pairs that are resolved, rejected, or
    /// weak; this answers "why did *these two* score the way they did?", which is a
    /// question worth asking about exactly those hidden pairs. It applies no
    /// threshold and no skip rules, so a rejected pair can be re-examined and a
    /// confirmed one can be audited against what the matcher would say today.
    ///
    /// - Returns: The score, or `nil` if the artifact, the mention within it, or the
    ///   person doesn't exist.
    public func matchScore(of mention: MentionRef, against personID: PersonID) -> ScoredMatch? {
        withIndex { index in
            guard let artifact = try? index.artifact(mention.artifact),
                let personMention = artifact.personsMentioned.first(
                    where: { $0.localRef == mention.localRef }),
                let person = try? index.person(personID),
                // Scoring one pair needs the relational context and nothing else — no
                // artifacts, no links. Reading them would mean decoding every record in
                // the archive, under the lock, to answer a question about two.
                let corpus = try? MatchCorpus.forScoring(index: index)
            else { return nil }

            return Matcher.score(
                MatchCorpus.mentionView(of: personMention, in: artifact),
                against: corpus.personView(of: person),
                places: corpus.places)
        }
    }

    /// The confidence a suggestion must reach to be worth showing.
    ///
    /// Calibrated against what the roll-up actually produces (see `Matcher.aggregate`),
    /// not picked round: the name is the only dimension every record supplies, so a
    /// pair whose names genuinely agree clears this even with nothing else to go on and
    /// a weak source — an exact name-only match on a middling source lands near 80, a
    /// phonetic one near 55. What falls below is a pair whose *name did not match* and
    /// that is being propped up by an incidental agreement elsewhere: a birth year that
    /// happens to coincide drags a zero-scoring name up to roughly 25, and shipping
    /// that to a review queue would teach the user to stop reading it.
    ///
    /// It is a **default, not a policy** — every entry point takes it as a parameter,
    /// because the right threshold depends on the archive and finding it is what the
    /// 45d CLI tuning pass exists for.
    public static let defaultMinimumConfidence = 50

    // MARK: - Review lifecycle

    /// Records that a human agrees a mention names a person, storing **the matcher's
    /// real reasoning**.
    ///
    /// This is the honest confirm path, beside — not replacing — `link()`. `link()`
    /// exists for a mention a human resolved unaided, and writes the *minimum* a
    /// `MatchBreakdown` can honestly express (`name: .exact/100`, every optional
    /// dimension `nil`). Writing that same placeholder when a matcher actually ran
    /// would throw away the decomposed accounting that is the whole point of §4.6, and
    /// leave a confirmed suggestion indistinguishable from a hand-made link.
    ///
    /// So the record this writes is deliberately mixed: `reviewStatus:
    /// .humanConfirmed` (a person decided), `provenance.createdBy: .machine` with
    /// ``GeneaLogicMatch/Matcher/toolIdentifier`` (a machine proposed), and the
    /// computed dimension scores exactly as the matcher produced them — **not**
    /// rounded up to 100 because a human agreed. A confirmation is a verdict on the
    /// pair, not a re-scoring of the evidence: a link confirmed on a birth year three
    /// years off should still say so a decade later.
    ///
    /// - Parameters:
    ///   - mention: The artifact + `localRef` being resolved.
    ///   - personID: The concluded person it names.
    ///   - match: The breakdown to store. `nil` recomputes it here, which is what a
    ///     caller holding only the pair (a CLI invocation) wants; a caller holding the
    ///     suggestion it showed the user should pass **that** score, so the record
    ///     matches what the user actually saw.
    ///   - reviewedBy: Who decided. Resolves to `EvidenceLink.reviewedBy`.
    /// - Throws: `ArchiveError.artifactNotFound` / `.personNotFound` /
    ///   `.mentionNotFound`, as `link()` does.
    @discardableResult
    public func confirm(
        _ mention: MentionRef,
        as personID: PersonID,
        match: ScoredMatch? = nil,
        reviewedBy: Reviewer = .unspecified
    ) throws -> ReviewDecision {
        try recordReview(
            mention, personID, status: .humanConfirmed, match: match, reviewedBy: reviewedBy)
    }

    /// Records that a human says a mention does **not** name a person — a rejection
    /// tombstone.
    ///
    /// **A rejection has to be a record, because the alternative is a matcher with no
    /// memory.** Suggestions are ephemeral (see this file's header), so nothing about
    /// declining one survives the closing of the queue; the next run would recompute
    /// the identical score and offer the identical pair, forever. The tombstone is what
    /// makes "no" stick, and it is the third state §4.4's `reviewStatus` has always
    /// documented rather than anything new.
    ///
    /// It stores the computed breakdown for the same reason a confirmation does: a
    /// rejection *of a strong match* is a far more interesting record than a rejection
    /// of a weak one — it is where the matcher is wrong in a way worth understanding —
    /// and discarding the score would erase exactly that distinction.
    ///
    /// **Scoped to the pair, not the mention.** Rejecting `Szlama Feldberg` on this deed
    /// as *this* Szlama forecloses that one pair; every other candidate stays open, and
    /// the mention stays unresolved. Only a confirmation resolves a mention.
    ///
    /// Reversible with ``unlink(_:)`` — a tombstone *is* an `EvidenceLink`, so deleting
    /// it is precisely un-rejecting it, and the pair returns to the queue.
    @discardableResult
    public func reject(
        _ mention: MentionRef,
        as personID: PersonID,
        match: ScoredMatch? = nil,
        reviewedBy: Reviewer = .unspecified
    ) throws -> ReviewDecision {
        try recordReview(
            mention, personID, status: .humanRejected, match: match, reviewedBy: reviewedBy)
    }

    /// Confirms the pair a suggestion names, storing the score the user was shown.
    @discardableResult
    public func confirm(
        _ suggestion: SuggestedLink, reviewedBy: Reviewer = .unspecified
    ) throws -> ReviewDecision {
        try confirm(
            suggestion.mention, as: suggestion.personID, match: suggestion.match,
            reviewedBy: reviewedBy)
    }

    /// Rejects the pair a suggestion names, storing the score the user was shown.
    @discardableResult
    public func reject(
        _ suggestion: SuggestedLink, reviewedBy: Reviewer = .unspecified
    ) throws -> ReviewDecision {
        try reject(
            suggestion.mention, as: suggestion.personID, match: suggestion.match,
            reviewedBy: reviewedBy)
    }

    /// The one write path behind ``confirm(_:as:match:reviewedBy:)`` and
    /// ``reject(_:as:match:reviewedBy:)`` — they differ by a single enum case, and
    /// forking the validation, scoring and supersession would mean two chances to get
    /// each of them wrong.
    private func recordReview(
        _ mention: MentionRef,
        _ personID: PersonID,
        status: LinkReviewStatus,
        match: ScoredMatch?,
        reviewedBy: Reviewer
    ) throws -> ReviewDecision {
        try withState { _, index in
            guard let artifact = try index.artifact(mention.artifact) else {
                throw ArchiveError.artifactNotFound(mention.artifact)
            }
            guard let person = try index.person(personID) else {
                throw ArchiveError.personNotFound(personID)
            }
            guard
                let personMention = artifact.personsMentioned.first(
                    where: { $0.localRef == mention.localRef })
            else {
                throw ArchiveError.mentionNotFound(mention.localRef, on: mention.artifact)
            }

            // Recomputed only when the caller didn't bring a score — a caller that did
            // is storing what the user actually saw, and must not have it silently
            // rescored here (see the `match` parameter's documentation).
            let scored: ScoredMatch
            if let match {
                scored = match
            } else {
                let corpus = try MatchCorpus.forScoring(index: index)
                scored = Matcher.score(
                    MatchCorpus.mentionView(of: personMention, in: artifact),
                    against: corpus.personView(of: person),
                    places: corpus.places)
            }

            // One link per pair — see `linksForPair`/`supersede`, which `link()` shares.
            // Read now; the delete runs below, once the replacement is durable.
            let superseded = try linksForPair(mention, personID: personID, index: index)

            let id = IdentifierMinter.evidenceLink()
            let now = ISO8601DateFormatter().string(from: Date())

            let link = EvidenceLink(
                uid: id,
                artifactUid: mention.artifact,
                personMentionRef: mention.localRef,
                personUid: personID,
                match: scored.breakdown,
                sourceAuthorityWeight: scored.sourceAuthorityWeight,
                informationQualityWeight: scored.informationQualityWeight,
                aggregateConfidence: scored.aggregateConfidence,
                reviewStatus: status,
                reviewedBy: reviewedBy.resolvedName,
                reviewedAt: now,
                provenance: Provenance(
                    createdBy: .machine,
                    createdAt: now,
                    tool: Matcher.toolIdentifier,
                    reviewStatus: .humanVerified
                )
            )

            try write(.link(link), index: index)
            try supersede(superseded, index: index)

            return try decision(writing: link, superseding: superseded, index: index)
        }
    }
}

// MARK: - SuggestedLink

/// A mention that may name a person, and the matcher's reasoning for thinking so.
///
/// **Not a record.** No uid, no provenance, no `reviewStatus`, no sidecar — those
/// belong to `EvidenceLink`, which is what a *human decision* produces. Keeping the
/// two types apart is what makes the ephemeral-suggestions rule enforceable rather
/// than merely intended: there is no code path that can accidentally persist one of
/// these, because it has nothing to persist.
///
/// Deliberately narrow — the pair and the score, no display fields. A suggestion that
/// carried the recorded name, the person's display name and the artifact title would
/// be a view model, and it would go stale the moment either record is edited. Callers
/// that need those have the ids to look them up, index-backed and cheap.
public struct SuggestedLink: Sendable, Equatable {
    /// The mention that might be this person.
    public var mention: MentionRef

    /// The concluded person it might be.
    public var personID: PersonID

    /// **The reasoning, which is the point** (§4.6). The breakdown inside is what a
    /// reviewer reads; `aggregateConfidence` only orders the queue.
    public var match: ScoredMatch

    public init(mention: MentionRef, personID: PersonID, match: ScoredMatch) {
        self.mention = mention
        self.personID = personID
        self.match = match
    }
}

// MARK: - MentionSuggestions

/// One unresolved mention and everyone it might be — **possibly nobody**.
///
/// The empty-`candidates` case is the reason this type exists rather than a flat
/// `[SuggestedLink]`. Scored pairs can only report matches, so a mention the archive has
/// no candidate for vanishes from the results, and a caller cannot tell it apart from a
/// record with no mentions at all or one whose mentions are all resolved. Those are
/// three different situations and only one of them is *this is a person we don't have
/// yet* — the case with actual work attached to it.
///
/// Not a record and never persisted, exactly like ``SuggestedLink``.
public struct MentionSuggestions: Sendable, Equatable {
    /// The unresolved mention being triaged.
    public var mention: MentionRef

    /// Who it might be, best first. **Empty means the matcher found nobody above the
    /// floor — not that this is a new person.** The matcher's blind spot is precisely
    /// the name it cannot recognize (an americanization, an unlisted variant), so an
    /// empty list is where it is least trustworthy, and a UI that reads it as "create
    /// new" mints duplicates exactly there.
    public var candidates: [SuggestedLink]

    public init(mention: MentionRef, candidates: [SuggestedLink]) {
        self.mention = mention
        self.candidates = candidates
    }
}

// MARK: - Projection

/// The conclusions side of the archive, read once and shaped for projection.
///
/// **Reads only what the caller asked for.** The relational dimensions need every
/// person and every relationship whatever the question is, but the skip rules need the
/// links only when suggestions are being generated, and *nothing* here needs artifacts
/// — the entry points pass those in, one or all. That matters because artifacts carry
/// transcripts and are by far the heaviest rows in the index, and every read below
/// happens under `Archive`'s lock: building a whole-archive corpus to score a single
/// pair would block every other reader to answer a question about two records.
/// Internal rather than file-private since slice 45j: `Archive+Duplicates.swift` needs
/// `personView(of:)` and the relationship buckets behind it, and the alternative was a
/// second projection of the same records that could drift from this one.
struct MatchCorpus {
    var persons: [Person]
    var personsByID: [PersonID: Person]

    /// Relationships bucketed by endpoint, **not** a flat list.
    ///
    /// `personView` is called once per candidate, and scanning every relationship
    /// inside it would make the artifact direction O(persons × relationships) — which
    /// is exactly the quadratic behavior this file's candidate-generation note claims
    /// not to have. Bucketing once makes the claim true rather than aspirational; the
    /// results are identical either way. A self-referential relationship appears once
    /// under its single endpoint, which is what the `personView` guard below expects.
    var relationshipsByPerson: [PersonID: [Relationship]]

    /// Mentions a human has already resolved, and pairs a human has already rejected.
    /// Empty on the scoring path, which applies no skip rules by design.
    var resolvedMentions: Set<MentionRef>
    var rejectedPairs: Set<RejectedPair>

    /// What the archive's own place strings prove about place depth (slice 45o).
    ///
    /// **Built in `init` rather than per entry point, and that is the whole design.**
    /// The vocabulary changes scores, so if the suggestion queue built one and the
    /// explain path built another, `matchScore` would report a different number than
    /// the row it exists to explain — and `confirm(match: nil)`, which recomputes and
    /// *writes* the breakdown, would store a different one again depending on which
    /// surface the user confirmed from. Every corpus gets it, so every path agrees.
    ///
    /// It reads the index's `place` projection, not the records: gathering it from the
    /// artifacts themselves would mean decoding every artifact in the archive under the
    /// lock, on paths (`matchScore`, `confirm`, `duplicateCandidates`) that deliberately
    /// decode one or none.
    var places: PlaceVocabulary

    struct RejectedPair: Hashable {
        var mention: MentionRef
        var personID: PersonID
    }

    /// For `suggestLinks` — adds the human's decisions, which are what the skip rules
    /// read.
    static func forSuggestion(index: ArchiveIndex) throws -> MatchCorpus {
        var corpus = try MatchCorpus(index: index)

        var resolved: Set<MentionRef> = []
        var rejected: Set<RejectedPair> = []
        for link in try index.allLinks() {
            let mention = MentionRef(artifact: link.artifactUid, localRef: link.personMentionRef)
            switch link.reviewStatus {
            case .humanConfirmed:
                resolved.insert(mention)
            case .humanRejected:
                rejected.insert(RejectedPair(mention: mention, personID: link.personUid))
            case .machineSuggested:
                // GeneaLogic never writes this (the ephemeral-suggestions decision), so
                // reaching it means a foreign writer put an unreviewed guess on disk.
                // An unreviewed guess is not a human decision: it neither resolves the
                // mention nor forecloses the pair, so it is deliberately ignored here
                // and the matcher will form its own opinion.
                break
            }
        }
        corpus.resolvedMentions = resolved
        corpus.rejectedPairs = rejected
        return corpus
    }

    /// For `matchScore` — the relational context alone. Skipping the link read isn't
    /// only cheaper, it is *correct*: the explain path deliberately applies no skip
    /// rules, so loading the state that drives them would be dead weight.
    static func forScoring(index: ArchiveIndex) throws -> MatchCorpus {
        try MatchCorpus(index: index)
    }

    private init(index: ArchiveIndex) throws {
        persons = try index.allPersons()
        personsByID = Dictionary(
            persons.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in
                first
            })

        var byPerson: [PersonID: [Relationship]] = [:]
        for relationship in try index.allRelationships() {
            byPerson[relationship.person1Uid, default: []].append(relationship)
            if relationship.person2Uid != relationship.person1Uid {
                byPerson[relationship.person2Uid, default: []].append(relationship)
            }
        }
        relationshipsByPerson = byPerson
        places = PlaceVocabulary(placeStrings: try index.allPlaceStrings())

        resolvedMentions = []
        rejectedPairs = []
    }

    private init() {
        persons = []
        personsByID = [:]
        relationshipsByPerson = [:]
        places = .empty
        resolvedMentions = []
        rejectedPairs = []
    }

    /// The corpus a failed read degrades to. `Archive+Lookup`'s convention (see its
    /// header): a SQL read failure between a successful `open()` and this call reads
    /// as "nothing found" rather than throwing through a non-throwing surface.
    static let empty = MatchCorpus()

    // MARK: Scoring

    /// Scores every unresolved pair drawn from `artifacts` × `persons`.
    ///
    /// **Brute force over the scoped side, deliberately.** A phonetic-key pre-filter
    /// was specced and dropped: the scorer's `.within` band exists precisely for pairs
    /// whose keys *differ* (`Fay`/`Faye`, one woman written both ways, key
    /// apart), so a key gate would make that band unreachable from an archive. A gate
    /// wide enough to preserve it has to stay a superset of everything the scorer can
    /// score — an invariant with no compiler check and no exhaustive test, which would
    /// rot silently the first time a threshold moved, and whose failure mode is an
    /// invisible false negative. Neither **suggestion** entry point is quadratic over the
    /// archive (one person × every mention, or one artifact's mentions × every person), so
    /// there is nothing to buy. Blocking remains available later as a strict
    /// optimization behind this same API: if it is a superset it changes no results.
    ///
    /// That claim is about *these* entry points only. Since slice 45j this corpus also
    /// serves `duplicateCandidates` (`Archive+Duplicates.swift`), which **is** quadratic
    /// over `persons()` by design — see its header for the cost and why blocking stayed
    /// out of the mini-phase there too.
    func suggestions(
        persons: [Person],
        artifacts: [Artifact],
        minimumConfidence: Int,
        limit: Int?
    ) -> [SuggestedLink] {
        let views = persons.map { (id: $0.uid, view: personView(of: $0)) }
        var found: [SuggestedLink] = []

        for artifact in artifacts {
            for personMention in artifact.personsMentioned {
                let mention = MentionRef(
                    artifact: artifact.uid, localRef: personMention.localRef)
                guard !resolvedMentions.contains(mention) else { continue }
                found.append(
                    contentsOf: candidates(
                        for: personMention, in: artifact, against: views,
                        minimumConfidence: minimumConfidence))
            }
        }

        return Self.ranked(found, limit: limit)
    }

    /// The artifact direction, grouped by mention — **including mentions nothing
    /// scored**.
    ///
    /// A flat list of scored pairs cannot express the case this exists for. A mention
    /// whose every candidate fell below the floor simply isn't in it, which makes "this
    /// record names nobody", "every name on it is already resolved", and "here is a name
    /// the archive has never seen" the same empty result. The third is exactly the
    /// *this is somebody new* case — the one where the user has something to do — and it
    /// was invisible.
    ///
    /// So a mention appears here whenever it is unresolved, whether or not anything
    /// matched it, and an empty `candidates` is the answer rather than an absence.
    /// **It is not evidence that the person is new**: the matcher's known blind spot is
    /// the variant case (`Zelig`/`Sidney`) it cannot see at all, so a caller offering
    /// "create new" off an empty list should show what a zero floor turns up beside it
    /// (§45e).
    ///
    /// Mentions keep the artifact's own `personsMentioned` order — a triage surface is
    /// read alongside the document, and the document's order is the one the reader has
    /// in front of them. Only the candidates within each are ranked.
    func groupedSuggestions(
        persons: [Person],
        artifacts: [Artifact],
        minimumConfidence: Int,
        limit: Int?
    ) -> [MentionSuggestions] {
        // Projected once for the whole run, not once per artifact: `personView` walks
        // the relationship buckets and copies name arrays, and the archive-wide entry
        // point (45e) passes every artifact. This is the saving that makes it a third
        // entry point rather than a loop at the call site.
        let views = persons.map { (id: $0.uid, view: personView(of: $0)) }

        return artifacts.flatMap { artifact in
            artifact.personsMentioned.compactMap { personMention -> MentionSuggestions? in
                let mention = MentionRef(artifact: artifact.uid, localRef: personMention.localRef)
                guard !resolvedMentions.contains(mention) else { return nil }

                let scored = candidates(
                    for: personMention, in: artifact, against: views,
                    minimumConfidence: minimumConfidence)
                return MentionSuggestions(
                    mention: mention, candidates: Self.ranked(scored, limit: limit))
            }
        }
    }

    /// The single-artifact direction — the same walk over one record.
    func groupedSuggestions(
        persons: [Person],
        artifact: Artifact,
        minimumConfidence: Int,
        limit: Int?
    ) -> [MentionSuggestions] {
        groupedSuggestions(
            persons: persons, artifacts: [artifact], minimumConfidence: minimumConfidence,
            limit: limit)
    }

    /// Scores one mention against every candidate person, dropping rejected pairs and
    /// anything under the floor. Unranked — the caller decides what order means.
    private func candidates(
        for personMention: PersonMention,
        in artifact: Artifact,
        against views: [(id: PersonID, view: PersonMatchView)],
        minimumConfidence: Int
    ) -> [SuggestedLink] {
        let mention = MentionRef(artifact: artifact.uid, localRef: personMention.localRef)
        let mentionView = Self.mentionView(of: personMention, in: artifact)

        return views.compactMap { personID, personView in
            guard !rejectedPairs.contains(RejectedPair(mention: mention, personID: personID))
            else { return nil }

            let score = Matcher.score(mentionView, against: personView, places: places)
            guard score.aggregateConfidence >= minimumConfidence else { return nil }
            return SuggestedLink(mention: mention, personID: personID, match: score)
        }
    }

    /// Ranked by confidence, then broken deterministically by id: two suggestions that
    /// score identically must not swap places between runs, or a queue reorders itself
    /// under the user for no reason and a test can't pin an order at all.
    ///
    /// The `limit` is clamped, not asserted. A negative one reached
    /// `removeSubrange((-1)...)` and tripped an `Array` precondition — which fires in
    /// release too, so a CLI flag or a bad slider binding could take down the app to
    /// answer a read-only query. A non-positive limit now means "no results," which is
    /// what asking for at most zero suggestions should mean.
    private static func ranked(_ suggestions: [SuggestedLink], limit: Int?) -> [SuggestedLink] {
        let sorted = suggestions.sorted { a, b in
            if a.match.aggregateConfidence != b.match.aggregateConfidence {
                return a.match.aggregateConfidence > b.match.aggregateConfidence
            }
            if a.mention.artifact.raw != b.mention.artifact.raw {
                return a.mention.artifact.raw < b.mention.artifact.raw
            }
            if a.mention.localRef != b.mention.localRef {
                return a.mention.localRef < b.mention.localRef
            }
            return a.personID.raw < b.personID.raw
        }
        if let limit { return Array(sorted.prefix(max(0, limit))) }
        return sorted
    }

    // MARK: Views

    /// Projects a concluded person, resolving the relational dimensions' inputs.
    ///
    /// `partnerNames` and `parentNames` are the reason this projection needs the
    /// corpus: both mean "walk the relationships this person is an endpoint of, then
    /// fetch the *other* person and take their names." A person whose partner record
    /// has been removed contributes nothing rather than failing — §2.3's no-cascade
    /// rule means dangling endpoints are a normal, expected state here.
    func personView(of person: Person) -> PersonMatchView {
        var partnerNames: [PersonName] = []
        var parentNames: [PersonName] = []

        for relationship in relationshipsByPerson[person.uid] ?? [] {
            switch relationship.type {
            case .couple:
                // `other(from:)` returns the *same* person for a self-referential
                // relationship, which would make them their own spouse and let a record
                // corroborate a match against the person's own name. Self-relationships
                // are a data error rather than a normal state, but a reachable one —
                // `DanglingReferenceTests` already covers them — and the damage here is
                // silent: on this corpus, where a record routinely names several people
                // sharing a surname, it reads as a plausible `spouseName` agreement
                // rather than as anything obviously wrong.
                guard let other = relationship.other(from: person.uid), other != person.uid,
                    let partner = personsByID[other]
                else { continue }
                partnerNames.append(contentsOf: partner.names)
            case .parentChild:
                // Only when this person is the *child* — §4.5's convention decoded
                // through `Relationship.parent`/`.child` rather than by hand. The
                // `parentID != person.uid` guard is the same self-reference case as
                // above: a `parent-child` edge whose endpoints are one person would
                // otherwise make them their own parent.
                guard relationship.child == person.uid,
                    let parentID = relationship.parent, parentID != person.uid,
                    let parent = personsByID[parentID]
                else { continue }
                parentNames.append(contentsOf: parent.names)
            case .unknown:
                continue
            }
        }

        return PersonMatchView(
            personID: person.uid,
            names: person.names,
            facts: person.facts,
            partnerNames: partnerNames,
            parentNames: parentNames)
    }

    /// Projects one mention, carrying its record's context with it.
    ///
    /// The co-mentions are every *other* person named on the same artifact — the
    /// relational evidence §4.6 wants, and the reason a marriage register scores so
    /// much better than a name in isolation. The artifact's two authority axes ride
    /// along because a mention is never scored outside the record that carries it, and
    /// so do its stated relationships (slice 45k), which say which co-mention stands in
    /// which relation instead of leaving the matcher to infer it from roles.
    ///
    /// The record's edges are passed **whole**, not filtered to this mention: resolving
    /// them is the matcher's decision, and a filter here would have to duplicate the
    /// §4.5 direction rule at a second site.
    ///
    /// `static` because it needs nothing from the corpus: a mention's whole world is
    /// its own artifact.
    static func mentionView(of mention: PersonMention, in artifact: Artifact)
        -> MentionMatchView
    {
        let coMentions = artifact.personsMentioned
            .filter { $0.localRef != mention.localRef }
            .map {
                CoMention(
                    localRef: $0.localRef, nameAsRecorded: $0.nameAsRecorded, role: $0.role,
                    nameScript: $0.nameScript)
            }

        return MentionMatchView(
            artifactID: artifact.uid,
            localRef: mention.localRef,
            nameAsRecorded: mention.nameAsRecorded,
            nameLanguage: mention.nameLanguage,
            nameScript: mention.nameScript,
            role: mention.role,
            informationQuality: mention.informationQuality,
            facts: mention.facts,
            coMentions: coMentions,
            mentionRelationships: artifact.mentionRelationships,
            sourceTier: artifact.sourceAuthorityTier,
            sourceDerivation: artifact.sourceDerivation)
    }
}

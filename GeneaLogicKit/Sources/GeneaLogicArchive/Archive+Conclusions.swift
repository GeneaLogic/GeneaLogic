import Foundation
import GeneaLogicModel

/// Conclusions writes: persons, relationships, and evidence links
/// (ARCHITECTURE.md §4.3, §4.4, §4.5, §6.3).
///
/// Unlike artifacts (`artifacts/<slug>/record.json`, a *folder* with a friendly
/// name), conclusion records are filed directly as `conclusions/<kind>/<UID>.json`
/// — the doc's `<UID>` placeholder in §4.3–§4.5 is the literal on-disk name, not a
/// derived slug. There is no `originalName`/`path` split to manage here (§4.2.1 is
/// an artifact-file concern), so these writes are simpler than `Archive+Files`'.
///
/// **Manifest scope — reversed in slice 49.** Phase 1a scoped `manifest.files` to
/// artifact payload plus the schema spec, on the reasoning that conclusion sidecars
/// are the engine's own normalized records rather than "evidence" in the
/// BagIt-payload sense, and these methods therefore touched neither `files` nor
/// `updatedAt`. That got the value backwards: a preservation master is the most
/// reproducible thing in the archive (there is a physical original and a backup
/// behind it), while the conclusion layer is hand-authored and re-derivable from
/// nothing. So every write here is now covered — `writeAuthoredJSON` mints the
/// entry, `withState` commits it — and `updatedAt` moves with it, because `files`
/// moved. See `Archive.recomputeManifestFiles`.
/// What a link write actually did — the return of `link`, `confirm` and `reject`.
///
/// The written link alone isn't enough for the caller. A write can *remove* records (see
/// `supersede`), and an undo that knew only what was added would restore the archive
/// to a state missing whatever the write displaced. Returning all three parts keeps the
/// operation reversible the way every other conclusions mutation is:
/// `unlink(decision.link.uid)` plus `restoreLink` for each superseded record puts things
/// back exactly.
public struct ReviewDecision: Sendable, Equatable {
    /// The link this write created.
    public var link: EvidenceLink

    /// Links removed because they decided this same pair, `uid`-ordered. Almost always
    /// empty; non-empty exactly when a verdict on this pair already existed.
    public var superseded: [EvidenceLink]

    /// `supportedByLinks` citations left dangling by the removal, in the same shape
    /// `findDanglingReferences()` reports.
    ///
    /// Reported at the moment it happens rather than left for the next sweep, because
    /// that is what every other removal path in the engine does — `removePerson`,
    /// `removeArtifact` and mention removal all tell the caller what they stranded, and
    /// the CLI prints it. A rejection that quietly cut the evidence out from under a
    /// concluded fact would be the one removal that didn't say so.
    public var strandedCitations: [DanglingReference]

    public init(
        link: EvidenceLink,
        superseded: [EvidenceLink] = [],
        strandedCitations: [DanglingReference] = []
    ) {
        self.link = link
        self.superseded = superseded
        self.strandedCitations = strandedCitations
    }
}

extension Archive {

    // MARK: - addPerson

    /// Creates a new concluded person from `draft`, minting its `PER-` id and
    /// writing `conclusions/persons/<uid>.json`.
    ///
    /// - Returns: The created `Person`, including its minted `uid`.
    @discardableResult
    public func addPerson(_ draft: PersonDraft) throws -> Person {
        try withState { _, index in
            let id = IdentifierMinter.person()
            let provenance = draft.provenance ?? Provenance.assertedNow()

            let person = Person(
                uid: id,
                names: draft.resolvedNames(),
                facts: draft.facts,
                identifierURI: draft.identifierURI,
                provenance: provenance
            )

            try write(.person(person), index: index)
            return person
        }
    }

    // MARK: - addRelationship

    /// Creates a new concluded relationship from `draft`, minting its `REL-` id
    /// and writing `conclusions/relationships/<uid>.json`.
    ///
    /// Both endpoints must already exist as concluded persons — a relationship
    /// pointing at a nonexistent `PersonID` would be a dangling conclusion from
    /// the moment it's written.
    ///
    /// - Throws: `ArchiveError.personNotFound` if either `person1Uid`/`person2Uid`
    ///   doesn't exist.
    /// - Returns: The created `Relationship`, including its minted `uid`.
    @discardableResult
    public func addRelationship(_ draft: RelationshipDraft) throws -> Relationship {
        try withState { _, index in
            guard try index.person(draft.person1Uid) != nil else {
                throw ArchiveError.personNotFound(draft.person1Uid)
            }
            guard try index.person(draft.person2Uid) != nil else {
                throw ArchiveError.personNotFound(draft.person2Uid)
            }

            let id = IdentifierMinter.relationship()
            let provenance = draft.provenance ?? Provenance.assertedNow()

            let relationship = Relationship(
                uid: id,
                type: draft.type,
                person1Uid: draft.person1Uid,
                person2Uid: draft.person2Uid,
                facts: draft.facts,
                supportedByLinks: draft.supportedByLinks,
                reviewStatus: draft.reviewStatus,
                provenance: provenance
            )

            try write(.relationship(relationship), index: index)
            return relationship
        }
    }

    // MARK: - link

    /// Manually links a person mention in an artifact to a concluded person,
    /// minting an `LNK-` evidence link and writing `conclusions/links/<uid>.json`
    /// (ARCHITECTURE.md §4.4, §6.3: `archive.link(MentionRef(...), to: p.uid,
    /// reviewedBy: .human)`).
    ///
    /// - Parameters:
    ///   - mention: The artifact + `localRef` of the `PersonMention` being linked.
    ///   - to: The concluded person this mention identifies.
    ///   - reviewedBy: Who performed this manual confirmation (`.human(name)` or
    ///     `.unspecified`). Resolves to `EvidenceLink.reviewedBy`.
    ///   - provenance: Override for the link's provenance. Defaults to a `.human`/
    ///     `.asserted` stamp — see the judgment call below for why.
    /// - Throws: `ArchiveError.artifactNotFound` if `mention.artifact` doesn't
    ///   exist; `ArchiveError.personNotFound` if `to` doesn't exist; a generic
    ///   "mention not found" surfaced as `ArchiveError.artifactNotFound` is NOT
    ///   used — instead `mentionNotFound` documents the missing-`localRef` case
    ///   precisely (see `ArchiveError`).
    /// - Returns: The created `EvidenceLink`.
    ///
    /// **Judgment call (flagged for review — manual link's `MatchBreakdown` and
    /// review status):** `EvidenceLink.match`/`aggregateConfidence`/
    /// `sourceAuthorityWeight`/`informationQualityWeight` are described in §4.4 as
    /// the *output of the matcher* (Phase 6, explicitly out of scope here) — a
    /// decomposed accounting of *why a machine thinks two records describe the
    /// same person*. A human manually confirming "yes, this mention is this
    /// person" has not run that algorithm and computed no such breakdown; forging
    /// plausible-looking dimension scores (`.exact`/`100` everywhere) would be
    /// dishonest telemetry — exactly the kind of "confidence theater" the
    /// decomposed-breakdown design (§4.6) exists to avoid. This implementation:
    ///   - Represents "no computed match" with `MatchBreakdown(name:
    ///     MatchDimension(kind: .exact, score: 100), conflicts: [])` — i.e. the
    ///     *minimum* breakdown the type can honestly express for "a human looked
    ///     at the name and confirmed it," using `.exact`/`100` only for the one
    ///     dimension (`name`) every link must carry, and leaving every optional
    ///     dimension (`birthYear`, `birthPlace`, `spouseName`, `parents`) `nil`
    ///     — `nil` reading as "not assessed," not "assessed and scored 0/1".
    ///     `nameAlgo` is left `nil` (no phonetic algorithm ran).
    ///   - Sets `aggregateConfidence: 100` — a human confirmation IS the ground
    ///     truth the matcher's score is trying to approximate; representing it as
    ///     anything less would understate a stronger signal than any machine
    ///     match. `sourceAuthorityWeight`/`informationQualityWeight` are set to
    ///     `100` for the same reason — they exist to *discount* a machine's
    ///     confidence by the source's epistemic weight, which is meaningless once
    ///     a human has directly confirmed the identification.
    ///   - Sets `reviewStatus: .humanConfirmed` — never `.machineSuggested` (no
    ///     machine suggested it) and never `.humanRejected` (the link exists
    ///     *because* it was confirmed, not despite a rejection).
    ///   - Sets `reviewedBy`/`reviewedAt` from `reviewedBy`/now — the one place a
    ///     manual link's provenance genuinely differs from a machine one.
    /// An alternative would be a parallel "manually-asserted" link shape without
    /// `match`/weights at all — but that would fork `EvidenceLink` into two
    /// incompatible record shapes mid-format, which CLAUDE.md's "format changes
    /// are the most expensive mistake" weighs heavily against.
    ///
    /// **Revisit resolved (slice 45c).** The note above anticipated this being
    /// reconsidered once real machine-scored links existed, and they now do:
    /// `Archive.confirm(_:as:match:)` is the path for a mention a *matcher* proposed,
    /// and it stores the computed dimension scores unaltered rather than this
    /// placeholder. The two coexist because they record genuinely different events —
    /// this one is "a human read the record and knew who it was," which no algorithm
    /// scored and which the honest minimum below describes exactly. Rejection is
    /// `Archive.reject(_:as:match:)`; there is no manual equivalent, because declining
    /// a suggestion is the only thing a rejection can mean.
    ///
    /// Supersedes any existing link for this pair and reports it in the returned
    /// ``ReviewDecision`` — see ``linksForPair(_:personID:index:)`` and
    /// ``supersede(_:index:)``.
    @discardableResult
    public func link(
        _ mention: MentionRef,
        to personID: PersonID,
        reviewedBy: Reviewer = .unspecified,
        provenance: Provenance? = nil
    ) throws -> ReviewDecision {
        try withState { _, index in
            guard let artifact = try index.artifact(mention.artifact) else {
                throw ArchiveError.artifactNotFound(mention.artifact)
            }
            guard try index.person(personID) != nil else {
                throw ArchiveError.personNotFound(personID)
            }
            guard artifact.personsMentioned.contains(where: { $0.localRef == mention.localRef })
            else {
                throw ArchiveError.mentionNotFound(mention.localRef, on: mention.artifact)
            }

            // One link per pair, the same rule `confirm`/`reject` obey. Resolving a
            // mention a matcher suggestion had been rejected for is an ordinary flow
            // (the user changes their mind, or reaches the same pair from the inspector
            // instead of the queue), and leaving the tombstone behind would foreclose
            // the pair the moment this link is ever undone.
            //
            // Read now, delete after the new record is durable — see `supersede`.
            let superseded = try linksForPair(mention, personID: personID, index: index)

            let id = IdentifierMinter.evidenceLink()
            let now = ISO8601DateFormatter().string(from: Date())
            let linkProvenance = provenance ?? Provenance.assertedNow()

            // See the judgment-call note above for why every field below is what
            // it is — this is the "honest minimum" representation of a manual
            // confirmation, not a forged machine score.
            let manualConfirmationBreakdown = MatchBreakdown(
                name: MatchDimension(kind: .exact, score: 100),
                nameAlgo: nil,
                birthYear: nil,
                birthPlace: nil,
                spouseName: nil,
                parents: nil,
                conflicts: []
            )

            let evidenceLink = EvidenceLink(
                uid: id,
                artifactUid: mention.artifact,
                personMentionRef: mention.localRef,
                personUid: personID,
                match: manualConfirmationBreakdown,
                sourceAuthorityWeight: 100,
                informationQualityWeight: 100,
                aggregateConfidence: 100,
                reviewStatus: .humanConfirmed,
                reviewedBy: reviewedBy.resolvedName,
                reviewedAt: now,
                provenance: linkProvenance
            )

            try write(.link(evidenceLink), index: index)
            try supersede(superseded, index: index)
            return try decision(
                writing: evidenceLink, superseding: superseded, index: index)
        }
    }

    // MARK: - One link per pair

    /// Removes every existing link for `(mention, personID)`, returning what it took.
    ///
    /// **A pair holds one verdict.** The three writers — `link`, `confirm`, `reject` —
    /// each state something about the same two records, and two of those records
    /// coexisting means the archive asserts a pair is both resolved and foreclosed, with
    /// read order deciding which is true.
    ///
    /// The rule covers **same-status duplicates too**, which an earlier version of this
    /// slice deliberately allowed on the reasoning that a repeat is redundant rather
    /// than contradictory. That holds for confirmations and **fails for rejections**:
    /// each tombstone forecloses the pair independently, and `unlink` is uid-addressed,
    /// so un-rejecting removes one and leaves the pair just as hidden — reporting
    /// success while changing nothing the user can see. A rule that depends on which
    /// status you are writing is one the next caller gets wrong, so there isn't one.
    ///
    /// A stray `.machineSuggested` (never written here — suggestions are ephemeral) goes
    /// the same way: an unreviewed guess does not outlive a human verdict on its pair.
    ///
    /// **Split in two on purpose — read here, destroy after the replacement is durable.**
    /// This half is read-only, so a caller can learn what it is about to displace
    /// *before* committing to anything. See ``supersede(_:index:)`` for why the order
    /// matters.
    ///
    /// **It also refuses up front if any of them drifted on disk** (slice 68, fork b).
    /// `supersede` unlinks through the drift guard, and it runs after the new link is
    /// written, so a refusal there would leave both verdicts on the pair and arm the
    /// interrupted-write flag. Every caller reaches here before its first write.
    func linksForPair(
        _ mention: MentionRef, personID: PersonID, index: ArchiveIndex
    ) throws -> [EvidenceLink] {
        // `try`, not `try?`: silently skipping supersession would write the second,
        // contradictory record this exists to prevent, and report an empty `superseded`
        // so no undo could repair it. Failing the whole write is the safe direction.
        let links = try index.allLinks()
            .filter {
                $0.artifactUid == mention.artifact
                    && $0.personMentionRef == mention.localRef
                    && $0.personUid == personID
            }
            .sorted { $0.uid.raw < $1.uid.raw }
        try refuseToTouchDriftedRecords(
            at: links.map { ArchiveLayout.recordURL(in: rootURL, link: $0.uid) })
        return links
    }

    /// Deletes the links a completed write displaced.
    ///
    /// **Called only after the replacement is on disk and in the index**, which is the
    /// whole point of the split. Superseding first read as the natural order — clear the
    /// pair, then write the one true verdict — but it makes every failure between the two
    /// steps *destructive*: `withState` has no rollback, so a `writeJSON` that throws
    /// after the delete leaves the pair with no verdict at all, and the throw means no
    /// `ReviewDecision` comes back, so neither the CLI's displacement report nor the
    /// app's undo registration can name what was lost. The user is told the operation
    /// failed while their confirmation is silently gone.
    ///
    /// Writing first trades that for a *transient* one: a crash between the write and
    /// this call leaves two links on a pair, momentarily asserting both resolved and
    /// foreclosed. That state is visible, reachable, and repairable — the next write to
    /// the pair supersedes both, and `unlink` addresses either by uid — whereas the
    /// destroyed verdict is none of those things. **Recoverable inconsistency beats
    /// irrecoverable loss**, and it is the same reasoning as the sidecar-before-index
    /// ordering inside the loop. No in-process reader can observe the window: `withState`
    /// holds the lock across both halves.
    func supersede(_ links: [EvidenceLink], index: ArchiveIndex) throws {
        for link in links { try remove(.link(link.uid), index: index) }
    }

    /// Packages a completed write with what it displaced, including any citation the
    /// displacement stranded.
    ///
    /// The stranded-citation sweep runs **only when something was superseded**, which is
    /// the rare path — it reads every person and relationship to find `supportedByLinks`
    /// entries naming a removed link, and charging every confirm in a triage session for
    /// that would be absurd.
    func decision(
        writing link: EvidenceLink, superseding superseded: [EvidenceLink],
        index: ArchiveIndex
    ) throws -> ReviewDecision {
        guard !superseded.isEmpty else { return ReviewDecision(link: link) }
        return ReviewDecision(
            link: link,
            superseded: superseded,
            strandedCitations: try strandedCitations(
                naming: Set(superseded.map(\.uid)), index: index))
    }

    /// Every `supportedByLinks` citation naming one of `removed`.
    ///
    /// Shared by the review lifecycle (a superseded verdict) and the merge cascade (a
    /// collapsed duplicate) because both remove links out from under citations that may
    /// name them, and a caller that reported one kind of strand but not the other would
    /// be the inconsistency. Runs **only when something was actually removed** — it reads
    /// every person and relationship, and charging every confirm in a triage session for
    /// that would be absurd.
    func strandedCitations(
        naming removed: Set<EvidenceLinkID>, index: ArchiveIndex
    ) throws -> [DanglingReference] {
        guard !removed.isEmpty else { return [] }
        var stranded: [DanglingReference] = []

        for person in try index.allPersons().sorted(by: { $0.uid.raw < $1.uid.raw }) {
            for (factIndex, fact) in person.facts.enumerated() {
                for support in fact.supportedByLinks where removed.contains(support) {
                    stranded.append(
                        .personFactSupport(
                            person: person.uid, factIndex: factIndex, missingLink: support))
                }
            }
        }

        for relationship in try index.allRelationships()
            .sorted(by: { $0.uid.raw < $1.uid.raw })
        {
            for support in relationship.supportedByLinks where removed.contains(support) {
                stranded.append(
                    .relationshipSupport(
                        relationship: relationship.uid, missingLink: support))
            }
            for (factIndex, fact) in relationship.facts.enumerated() {
                for support in fact.supportedByLinks where removed.contains(support) {
                    stranded.append(
                        .relationshipFactSupport(
                            relationship: relationship.uid, factIndex: factIndex,
                            missingLink: support))
                }
            }
        }

        return stranded
    }

    // MARK: - Review-lifecycle mutations (edit / remove / restore)

    /// The conclusions layer's edit + removal surface, powering Phase 3's
    /// confirm/reject/edit flows. Three design choices apply to every method here:
    ///
    /// - **Manifest-covered, like the add methods above** — a removal drops the
    ///   record's manifest entry, a restore mints a fresh one from the bytes it
    ///   writes (slice 49; see this file's header).
    /// - **In-session reversible, not trashed.** Each `remove*`/`unlink` returns the
    ///   record it deleted, and a paired `restore*` rewrites the *exact* sidecar
    ///   (uid faithful) + re-upserts it — so the app's `UndoManager` can ping-pong a
    ///   removal like it does artifact/file ops. Unlike artifacts (slice 20) and
    ///   files (slice 21), conclusions are **not** staged into `.trash/`: the manual
    ///   conclusions loop is new, a person/relationship/link is cheap to recreate,
    ///   and in-session undo covers the immediate "oops." A cross-session trash for
    ///   conclusions (the `TrashEntry.kind` discriminator could take a `.person`
    ///   case) is a possible later follow-on, exactly as ingest-undo predated the
    ///   file trash.
    /// - **No cascade (§2.3).** Removing a person leaves any `Relationship`/
    ///   `EvidenceLink` that referenced it dangling rather than silently rewriting
    ///   other conclusion records; unlinking leaves the `supportedByLinks` entries
    ///   that named the link dangling. `verifyIntegrity()` (or a future
    ///   `findDanglingReferences()`) is where such dangles surface for review — and
    ///   leaving them untouched is *also* what keeps each removal cleanly
    ///   reversible, since nothing else changes when the record comes back.
    /// - **Delete ordering: sidecar first, then the index row.** The filesystem and
    ///   the SQLite index aren't a single transaction, so a failure *between* the two
    ///   steps (a rare mid-statement SQLite error) leaves a transient
    ///   `{index-has-record, sidecar-gone}` state. That's not data loss — the record's
    ///   full JSON still lives in the index until the next `rebuildIndex()`, which
    ///   then reconciles *toward deletion* (the sidecar is authoritative, §5.1). The
    ///   reverse order would be worse: a rebuild would *resurrect* a just-removed
    ///   record from its surviving sidecar. (Trash-staging the way `removeArtifact`
    ///   does would close the window entirely, but conclusions deliberately skip the
    ///   trash — see the reversibility note above.)

    /// Atomically rewrites a concluded person's sidecar after applying `mutate` to
    /// an in-memory copy — the person analog of `updateMetadata(of:_:)`. `uid`/
    /// `schemaVersion` are restored after the closure (identity is not mutable via
    /// this path).
    ///
    /// - Throws: `ArchiveError.personNotFound` if `id` doesn't exist.
    /// - Returns: The updated `Person`.
    @discardableResult
    public func updatePerson(_ id: PersonID, _ mutate: (inout Person) -> Void) throws -> Person {
        try withState { _, index in
            guard var person = try index.person(id) else {
                throw ArchiveError.personNotFound(id)
            }
            mutate(&person)
            person.uid = id
            person.schemaVersion = SchemaVersion.current

            try write(.person(person), index: index)
            return person
        }
    }

    /// Atomically rewrites a concluded relationship's sidecar after applying `mutate`
    /// to an in-memory copy — the relationship analog of `updatePerson(of:_:)`, and
    /// the write path behind editing a couple's marriage/divorce facts (§4.5).
    /// `uid`/`schemaVersion` are restored after the closure (identity is not mutable
    /// via this path). Endpoints (`person1Uid`/`person2Uid`) *are* mutable via `mutate`
    /// but the app doesn't currently expose that; callers who reassign them are
    /// responsible for the targets existing (no re-validation here, matching how
    /// `updatePerson` doesn't re-check anything the closure touches).
    ///
    /// - Throws: `ArchiveError.relationshipNotFound` if `id` doesn't exist.
    /// - Returns: The updated `Relationship`.
    @discardableResult
    public func updateRelationship(
        _ id: RelationshipID, _ mutate: (inout Relationship) -> Void
    ) throws -> Relationship {
        try withState { _, index in
            guard var relationship = try index.relationship(id) else {
                throw ArchiveError.relationshipNotFound(id)
            }
            mutate(&relationship)
            relationship.uid = id
            relationship.schemaVersion = SchemaVersion.current

            try write(.relationship(relationship), index: index)
            return relationship
        }
    }

    /// Removes a concluded person (`conclusions/persons/<uid>.json` + its index
    /// row), returning the removed `Person` for the undo path (`restorePerson`).
    ///
    /// - Throws: `ArchiveError.personNotFound` if `id` doesn't exist.
    @discardableResult
    public func removePerson(_ id: PersonID) throws -> Person {
        try withState { _, index in
            guard let person = try index.person(id) else {
                throw ArchiveError.personNotFound(id)
            }
            try remove(.person(id), index: index)
            return person
        }
    }

    /// Re-writes a person removed by `removePerson` back to its sidecar (uid
    /// faithful) and re-inserts it into the index — the in-session undo path. A
    /// faithful rewrite, so it's idempotent and takes no "already exists" guard.
    public func restorePerson(_ person: Person) throws {
        try withState { _, index in
            try write(.person(person), index: index)
        }
    }

    /// Removes a concluded relationship (`conclusions/relationships/<uid>.json` +
    /// its index row), returning the removed `Relationship` for the undo path.
    ///
    /// - Throws: `ArchiveError.relationshipNotFound` if `id` doesn't exist.
    @discardableResult
    public func removeRelationship(_ id: RelationshipID) throws -> Relationship {
        try withState { _, index in
            guard let relationship = try index.relationship(id) else {
                throw ArchiveError.relationshipNotFound(id)
            }
            try remove(.relationship(id), index: index)
            return relationship
        }
    }

    /// Re-writes a relationship removed by `removeRelationship` back to its sidecar
    /// (uid faithful) and re-inserts it into the index — the in-session undo path.
    public func restoreRelationship(_ relationship: Relationship) throws {
        try withState { _, index in
            try write(.relationship(relationship), index: index)
        }
    }

    /// Removes an evidence link (`conclusions/links/<uid>.json` + its index row) —
    /// "reject this mention→person link" — returning the removed `EvidenceLink` for
    /// the undo path (`restoreLink`).
    ///
    /// - Throws: `ArchiveError.evidenceLinkNotFound` if `id` doesn't exist.
    @discardableResult
    public func unlink(_ id: EvidenceLinkID) throws -> EvidenceLink {
        try withState { _, index in
            guard let link = try index.evidenceLink(id) else {
                throw ArchiveError.evidenceLinkNotFound(id)
            }
            try remove(.link(id), index: index)
            return link
        }
    }

    /// Re-writes a link removed by `unlink` back to its sidecar (uid faithful) and
    /// re-inserts it into the index — the in-session undo path.
    public func restoreLink(_ link: EvidenceLink) throws {
        try withState { _, index in
            try write(.link(link), index: index)
        }
    }
}

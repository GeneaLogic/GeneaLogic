import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Suggested facts (slices 42c/44i; hoisted for the cross-person lane, 45i)

    /// One person's Sources rows and promotable evidence — the person pane's half of the
    /// pair. Takes `recordedFacts` from the caller (which has already loaded the person and
    /// their relationships for other sections) rather than re-fetching both, but that list
    /// must be built by `SuggestedFacts.recordedFacts(of:relationships:)` so the person pane
    /// and the cross-person lane dedupe against the same thing.
    func linkedEvidence(for id: PersonID, recordedFacts: [PersonFact]) -> (
        sources: [PersonSource], suggestions: [FactSuggestion]
    ) {
        var records: [ArtifactID: Artifact?] = [:]
        return SuggestedFacts.assemble(
            links: personLinks(for: id),
            recordedFacts: recordedFacts,
            artifactTitle: { artifactID in artifacts.first { $0.uid == artifactID }?.title },
            artifactRecord: { artifactID in
                if let cached = records[artifactID] { return cached }
                let loaded = fullArtifact(artifactID)
                records[artifactID] = loaded
                return loaded
            })
    }

    /// Records a suggestion **as-recorded** in one click — the un-edited counterpart of the
    /// "Record Fact from Evidence" sheet's person-fact save (slice 44i). Builds the
    /// `PersonFact` from the suggestion's prefills (date shorthand normalized exactly as the
    /// sheet does), cites the supporting link, and appends via the undoable `updatePerson`
    /// (⌘Z removes it).
    ///
    /// **Guarded, not merely documented.** Only a directly-recordable suggestion may take
    /// this path — a couple fact belongs on the `Relationship` (§4.5), not in
    /// `Person.facts`, and a recorded age has no year until a human derives one (§2.3).
    /// While this was private next to its one caller the button's own condition was the
    /// guarantee; as model API with two callers and more to come, the invariant has to be
    /// enforced where it is stated. `assertionFailure` so a future miswiring is loud in
    /// debug rather than quietly writing a marriage onto a person.
    ///
    /// `SuggestedFacts.isAlreadyRecorded` matches what this writes, so the recorded fact
    /// deduplicates the suggestion out on the next reload, in both surfaces that show it.
    func recordSuggestedFact(_ suggestion: FactSuggestion, for id: PersonID) {
        guard suggestion.isDirectlyRecordable else {
            assertionFailure("recordSuggestedFact called for a suggestion needing the editor")
            return
        }
        let fact = FactForm.build(
            type: suggestion.suggestedType,
            date: suggestion.prefillDate ?? "",
            place: suggestion.prefillPlace ?? "",
            value: suggestion.prefillValue ?? "",
            supportedByLinks: [suggestion.link])
        updatePerson(of: id, actionName: "Record Fact from Evidence") {
            $0.facts.append(fact)
        }
    }

    // MARK: - Matching (slice 45e)

    /// Rebuilds the worklist from the archive.
    ///
    /// Runs on entering the section, from its Refresh button, and — once it has been
    /// loaded at all — from `refresh()`, so a decision, an undo, or an edit made in
    /// another section is reflected. **A recompute cannot reorder the queue**, which is
    /// what makes wiring it to every mutation safe rather than disorienting: the engine
    /// returns document order (artifact `uid`, then the record's own mention order), and a
    /// decision on one pair moves nothing else. Patching the list in place instead would
    /// save a sweep this archive can't measure and would leave ⌘Z showing a stale queue.
    ///
    /// Synchronous, on the main actor, like every other `Archive` call here: the real
    /// archive is 22 mentions × 11 persons, and the engine builds the conclusions corpus
    /// once for the whole sweep rather than once per artifact. An archive large enough to
    /// make that visible wants a progress affordance and an off-main read, which is a
    /// different slice than this one.
    func refreshReviewWorklist() {
        hasLoadedReviewWorklist = true
        guard let archive else {
            reviewItems = []
            factItems = []
            return
        }
        // Cached per artifact: a record carrying five mentions is one decode, not five.
        var records: [ArtifactID: Artifact] = [:]

        reviewItems = archive.suggestLinks().compactMap { group in
            let artifactID = group.mention.artifact
            let record: Artifact?
            if let cached = records[artifactID] {
                record = cached
            } else {
                record = archive.artifact(withID: artifactID)
                if let record { records[artifactID] = record }
            }
            guard let record,
                let mention = record.personsMentioned.first(
                    where: { $0.localRef == group.mention.localRef })
            else { return nil }

            return ReviewItem(
                mention: group.mention,
                artifactTitle: record.title,
                recordedMention: mention,
                candidates: group.candidates.map { candidate in
                    ReviewCandidate(
                        suggestion: candidate,
                        person: persons.first { $0.uid == candidate.personID })
                },
                // Filled in below, for the few items that can read them.
                rejectedLinks: [])
        }
        fillRejections(archive)
        refreshFactSuggestions(archive)
        refreshRelationshipSuggestions(archive)
    }

    /// The Review section's **second lane**: every person with promotable evidence still
    /// un-promoted, ordered as the People sidebar orders them (slice 45i).
    ///
    /// Same governing rule as the links lane — recomputed, never stored. A suggestion is
    /// a reading of the current records, so the moment one is recorded (or the fact is
    /// undone) the answer changes, and there is nothing on disk to go stale.
    ///
    /// **One decode pass, not one per person.** `links(for:)` decodes the whole link table
    /// per call, so asking it person by person would be O(persons × all-links) main-actor
    /// decodes on every mutation; the archive-wide `links()` added by this slice answers it
    /// once, and `relationships()` likewise. The artifact-record cache spans the whole
    /// sweep rather than one person, since a census cited by six people is one decode.
    ///
    /// What a suggestion *is*, and when it counts as already recorded, is decided entirely
    /// by `SuggestedFacts` — the same code the person pane calls — because a lane that
    /// disagreed with the person pane about the same person would be a silent
    /// contradiction with no way for the user to tell which surface was right.
    private func refreshFactSuggestions(_ archive: Archive) {
        let linksByPerson = Dictionary(grouping: archive.links(), by: \.personUid)
        // Both endpoints, so a couple fact is seen from either partner — the same set
        // `relationships(of:)` would return, without a query per person.
        var relationshipsByPerson: [PersonID: [Relationship]] = [:]
        for relationship in archive.relationships() {
            relationshipsByPerson[relationship.person1Uid, default: []].append(relationship)
            if relationship.person2Uid != relationship.person1Uid {
                relationshipsByPerson[relationship.person2Uid, default: []].append(relationship)
            }
        }

        var records: [ArtifactID: Artifact?] = [:]
        func record(_ id: ArtifactID) -> Artifact? {
            if let cached = records[id] { return cached }
            let loaded = archive.artifact(withID: id)
            records[id] = loaded
            return loaded
        }

        factItems = persons.compactMap { summary in
            guard let links = linksByPerson[summary.uid], !links.isEmpty else { return nil }
            let recorded = SuggestedFacts.recordedFacts(
                of: archive.person(withID: summary.uid),
                relationships: relationshipsByPerson[summary.uid] ?? [])
            let (_, suggestions) = SuggestedFacts.assemble(
                links: links,
                recordedFacts: recorded,
                artifactTitle: { id in artifacts.first { $0.uid == id }?.title },
                artifactRecord: record)
            guard !suggestions.isEmpty else { return nil }
            return FactReviewItem(person: summary, suggestions: suggestions)
        }
    }

    // MARK: - Suggested relationships (slice 45l)

    /// Assembles the lane from the engine's derivation.
    ///
    /// The engine owns *what is suggested and what has already been settled*; this owns only
    /// the names and titles, which are resolved here rather than carried across the boundary
    /// because they go stale the moment either record is renamed (the same reason
    /// `SuggestedLink` has no display fields).
    private func refreshRelationshipSuggestions(_ archive: Archive) {
        relationshipItems = assemble(archive.suggestedRelationships())
    }

    /// The same lane, narrowed to the record the user is standing on — the artifact
    /// inspector's half of 45l (fork (a)).
    ///
    /// It goes through the engine's *filter* over the whole-archive derivation rather than a
    /// per-record scan, so this surface and the lane can never disagree about whether an
    /// edge is still owed. Read on demand by `ArtifactDetailView` (with the record and its
    /// links) rather than held here: it is a property of one artifact, not of the window.
    func suggestedRelationships(forArtifact id: ArtifactID) -> [RelationshipReviewItem] {
        guard let archive else { return [] }
        return assemble(archive.suggestedRelationships(forArtifact: id))
    }

    /// The same lane narrowed to one person — the person pane's Suggested Relationships
    /// section, beside its Relationships one.
    ///
    /// Read on demand like the artifact direction, for the same reason: it is a property of
    /// one person rather than of the window, and the pane already reloads on
    /// `mutationVersion`.
    func suggestedRelationships(for id: PersonID) -> [RelationshipReviewItem] {
        guard let archive else { return [] }
        return assemble(archive.suggestedRelationships(for: id))
    }

    private func assemble(_ suggestions: [SuggestedRelationship]) -> [RelationshipReviewItem] {
        let titles = Dictionary(
            artifacts.map { ($0.uid, $0.title) }, uniquingKeysWith: { first, _ in first })
        return suggestions.map { suggestion in
            RelationshipReviewItem(
                suggestion: suggestion,
                first: persons.first { $0.uid == suggestion.person1 },
                second: persons.first { $0.uid == suggestion.person2 },
                // A record deleted between the sweep and now is a normal state (§2.3), and
                // an untitled row is better than a dropped citation.
                sourceTitles: suggestion.evidence.map {
                    titles[$0.artifact] ?? "Unknown document"
                })
        }
    }

    /// Promotes a suggested relationship into `conclusions/`.
    ///
    /// The record it writes is `human-verified` over `createdBy: .machine` (45c's rule,
    /// 45l's fork (d)) and cites every link behind it — all of that is the engine's, so this
    /// only has to make it undoable and refresh the lane the row leaves.
    func confirmSuggestedRelationship(_ item: RelationshipReviewItem) {
        mutate(unopened: "Open an archive before recording a relationship.") { archive in
            // **Only register an undo for a record this click created.** `confirm` is
            // idempotent and returns the existing relationship when the archive already
            // asserts the claim — from another window, or the CLI — and undoing *that*
            // would delete a conclusion this action never made. Checked before writing
            // rather than inferred after, since the returned record looks identical
            // either way. The same trap 45m's review found on the dismissal side.
            //
            // The check runs here, inside the work closure, so it is on the same side of
            // the actor hop as the write it guards (52) — reading it on the main actor
            // first would leave a window in which another process asserts the claim.
            let alreadyAsserted = archive.asserts(
                item.suggestion.type,
                between: item.suggestion.person1, and: item.suggestion.person2)
            return (try archive.confirm(item.suggestion), alreadyAsserted)
        } commit: { [self] relationship, alreadyAsserted in
            if !alreadyAsserted {
                registerRelationshipRedelete(of: relationship.uid, actionName: "Add Relationship")
            }
            // A full refresh, not a local row removal: promoting an edge changes what the
            // *matcher* sees too (a person's parents and partners feed the relational
            // dimensions), so the names lane's scores are no longer what they were.
            bumpAndRefresh()
        }
    }

    /// Records that the archive's records do **not** support this relationship, and drops it
    /// from the lane (45m's dismissal, under the matching subject).
    ///
    /// Same shape as `dismissDuplicate`, deliberately: one mechanism, two lanes. No
    /// breakdown is stored, because this suggestion was read off a record rather than
    /// scored, and inventing a number for it would be a lie.
    func dismissSuggestedRelationship(_ item: RelationshipReviewItem) {
        mutate(unopened: "Open an archive before dismissing a suggestion.") { archive in
            // Only register an undo for a record *this* click created — see
            // `dismissDuplicate` for why an idempotent write must not be undone blind.
            let alreadyDeclined = archive.isDismissed(
                item.suggestion.dismissalSubject,
                between: item.suggestion.person1, and: item.suggestion.person2)
            return (try archive.dismiss(item.suggestion), alreadyDeclined)
        } commit: { [self] dismissal, alreadyDeclined in
            if !alreadyDeclined {
                registerDismissalRemoval(dismissal, actionName: "Not This Relationship")
            }
            relationshipItems.removeAll { $0.id == item.id }
            bump()
        }
    }

    /// Re-derives whichever lane a dismissal belongs to, after one is written back or
    /// removed by undo.
    ///
    /// Two lanes now share the dismissal record, and they are refreshed by different means:
    /// the duplicates sweep is quadratic and has its own off-actor path, while the
    /// relationships lane rides the ordinary worklist refresh. Routing on the subject keeps
    /// undo from re-running the expensive one to restore a row in the cheap one.
    private func refreshLane(for subject: DismissalSubject) {
        switch subject {
        case .samePerson: refreshDuplicateCandidates()
        default: if hasLoadedReviewWorklist { refreshReviewWorklist() }
        }
    }

    // MARK: - The duplicates lane (slice 45m)

    /// Rebuilds the duplicates lane **off the main actor**.
    ///
    /// Every other Review sweep is a linear read this archive cannot measure. This one is
    /// `n(n−1)/2` scored pairs under `Archive`'s lock (45j's review raised it), so running
    /// it inline the way `refreshReviewWorklist` runs would freeze the window on an archive
    /// large enough to have duplicates worth finding. `Archive` is `@unchecked Sendable`
    /// behind that lock, so the scan is simply a detached read whose result is applied back
    /// here; the lock still serializes it against any concurrent write.
    ///
    /// **Not wired into `refresh()`**, unlike the other two lanes. A quadratic sweep on
    /// every mutation is the cost this indirection exists to avoid, and unlike the names
    /// lane the answer does not change under an ordinary edit — so it runs on entering the
    /// section and from Refresh. What *does* invalidate it immediately is a decision on one
    /// of its own rows, and those drop the row locally rather than re-scanning.
    /// Re-scans **only if the lane has been shown**, for a change that invalidates it
    /// structurally — a person ceasing to exist, which every merge and every delete does.
    ///
    /// This is the fix for a bug the first hand-test found: a merge left its own row in
    /// the lane, still naming the absorbed person, and clicking Merge on it a second time
    /// threw `personNotFound`. A stale row here is not merely out of date — it **offers an
    /// operation that cannot succeed**, which no other Review row can do.
    ///
    /// A full re-scan rather than dropping the row, because a merge genuinely changes the
    /// answer for *other* pairs too: the survivor absorbed the other record's names and
    /// facts, so it now scores differently against everyone. Removing one row would leave
    /// the rest quietly wrong.
    func refreshDuplicateCandidatesIfShown() {
        guard hasScannedDuplicates || isScanningDuplicates else { return }
        refreshDuplicateCandidates()
    }

    /// Drops every duplicates row naming `person`, *now*, ahead of the re-scan.
    ///
    /// The scan is asynchronous and deliberately leaves the old rows up while it runs (so
    /// Refresh doesn't flash the lane empty), which would leave a row offering a merge of
    /// a person who no longer exists for as long as the sweep takes. These rows are known
    /// dead the instant the person goes, so they don't wait for the answer.
    func dropDuplicateRows(naming person: PersonID) {
        duplicateItems.removeAll {
            $0.candidate.person1 == person || $0.candidate.person2 == person
        }
    }

    func refreshDuplicateCandidates() {
        duplicateScanTask?.cancel()
        guard let archive else {
            duplicateItems = []
            isScanningDuplicates = false
            return
        }
        isScanningDuplicates = true
        // **The read is here, on the main actor, and it is linear** — one pass over the
        // conclusions to build the snapshot, the same cost the other two lanes pay. Only
        // the quadratic scoring goes off-actor, and it takes no lock, so an archive read
        // from anywhere else does not queue behind it. Scoring *inside* `withIndex` on a
        // background thread would have moved the freeze rather than removed it (45m's
        // `/code-review`).
        let input = archive.duplicateScanInput()
        duplicateScanTask = Task { [weak self] in
            let candidates = await Self.scoreDuplicates(input)
            guard !Task.isCancelled, let self else { return }
            self.duplicateItems = candidates.map { candidate in
                DuplicateReviewItem(
                    candidate: candidate,
                    first: self.persons.first { $0.uid == candidate.person1 },
                    second: self.persons.first { $0.uid == candidate.person2 })
            }
            self.isScanningDuplicates = false
            self.hasScannedDuplicates = true
        }
    }

    /// The quadratic half, off the main actor.
    ///
    /// `nonisolated` + `async` rather than `Task.detached`: a detached task is unstructured
    /// and outlives the cancellation of whatever started it, so rapid Refresh clicks would
    /// pile up sweeps nobody is waiting for. This one is part of the task that awaits it.
    private nonisolated static func scoreDuplicates(
        _ input: DuplicateScanInput
    ) async -> [DuplicateCandidate] {
        Archive.duplicateCandidates(in: input)
    }

    /// Records that a pair is **not** a duplicate, and drops it from the lane.
    ///
    /// The record is what makes the answer stick past this launch (§6.6): without it the
    /// next scan re-derives the same score and re-offers the same pair, in the one section
    /// whose meaning depends on being able to reach empty.
    ///
    /// **Undoable by deleting it** — there is no fourth verb (45c). ⌘Z removes the
    /// dismissal, ⌘⇧Z writes it again, and the row comes back with the row's own local
    /// removal reversed alongside.
    func dismissDuplicate(_ item: DuplicateReviewItem) {
        mutate(unopened: "Open an archive before dismissing a suggestion.") { archive in
            // **Only register an undo for a record this click created.** `dismiss` is
            // idempotent and returns the existing record when the pair was already
            // declined — from the CLI, or another window on the same archive — and undoing
            // *that* would delete a judgement this action never made, which is the one
            // thing an undo must never do. Checked before writing rather than inferred
            // after, since the returned record looks identical either way.
            let alreadyDeclined = archive.isDismissed(
                .samePerson, between: item.candidate.person1, and: item.candidate.person2)
            return (try archive.dismiss(item.candidate), alreadyDeclined)
        } commit: { [self] dismissal, alreadyDeclined in
            if !alreadyDeclined {
                registerDismissalRemoval(dismissal, actionName: "Not a Duplicate")
            }
            // Dropped locally rather than by re-scanning: the sweep is quadratic, and its
            // answer for every *other* pair is unchanged by this decision.
            duplicateItems.removeAll { $0.id == item.id }
            bump()
        }
    }

    /// Undo for a dismissal: remove the record, which returns the pair to the queue.
    private func registerDismissalRemoval(_ dismissal: Dismissal, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerDismissalRestore(dismissal, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.removeDismissal(dismissal.uid)
            } commit: { _ in
                model.refreshLane(for: dismissal.subject)
                model.bump()
            } failure: { error in
                // Already gone (another window, or `genea person undismiss`) — the state
                // the undo was reaching for, so there is nothing to report.
                guard case ArchiveError.dismissalNotFound = error else { return false }
                model.refreshLane(for: dismissal.subject)
                return true
            }
        }
    }

    func registerDismissalRestore(_ dismissal: Dismissal, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerDismissalRemoval(dismissal, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.restoreDismissal(dismissal)
            } commit: { _ in
                // Redo drops the row it declined, without re-deriving either lane: the
                // record is back, so the sweep would return the same list minus this row.
                model.duplicateItems.removeAll {
                    $0.candidate.person1 == dismissal.person1Uid
                        && $0.candidate.person2 == dismissal.person2Uid
                }
                model.relationshipItems.removeAll {
                    $0.suggestion.dismissalSubject == dismissal.subject
                        && $0.suggestion.person1 == dismissal.person1Uid
                        && $0.suggestion.person2 == dismissal.person2Uid
                }
                model.bump()
            }
        }
    }

    /// Collects each **candidate-less** item's existing rejection tombstones.
    ///
    /// A second pass, and scoped to the empty items on purpose. `rejectedLinks` is only
    /// ever read to explain an empty candidate list (see
    /// `ReviewItem.noCandidateExplanation(floor:)`) and to offer the un-reject that undoes
    /// it, and `links(forArtifact:)` decodes **every link in the archive** on each call — so
    /// reading eagerly made building the worklist O(artifacts × links) main-actor JSON
    /// decodes, on every mutation, to answer a question almost none of the rows ask. On the
    /// real archive that is 2 artifacts rather than 20; a fully-triaged archive asks nothing.
    ///
    /// Deliberately the "record on disk" reading of `links(forArtifact:)` rather than the
    /// citation one (45c's rule): a tombstone is exactly what is being looked for.
    private func fillRejections(_ archive: Archive) {
        var rejections: [ArtifactID: [EvidenceLink]] = [:]
        for index in reviewItems.indices where reviewItems[index].candidates.isEmpty {
            let artifactID = reviewItems[index].mention.artifact
            let onRecord =
                rejections[artifactID]
                ?? {
                    let found = archive.links(forArtifact: artifactID, includeRejected: true)
                        .filter(\.isRejection)
                    rejections[artifactID] = found
                    return found
                }()
            reviewItems[index].rejectedLinks = onRecord.filter {
                $0.personMentionRef == reviewItems[index].mention.localRef
            }
        }
    }

    /// Un-rejects a pair: deletes the tombstone, so the candidate returns to the queue.
    ///
    /// **There is no fourth verb** — a rejection *is* an `EvidenceLink`, so removing it is
    /// precisely un-rejecting it (45c), which is why this delegates to `unlinkMention` with
    /// its own undo label rather than adding an engine call. 45e specced this as CLI-only
    /// (`genea match unreject`) on the grounds that ⌘Z covers the immediate mistake; it
    /// doesn't cover the one made in an earlier session, and the queue is exactly where that
    /// is discovered — the row says a candidate was rejected and then offered no way back.
    func restoreRejectedPair(_ link: EvidenceLink) {
        unlinkMention(link.uid, actionName: "Restore Rejected Candidate")
    }

    /// Mints a person from an unresolved mention's recorded name and links it — the
    /// **somebody new** outcome, and the reason the worklist reports mentions nothing
    /// matched at all.
    ///
    /// Nothing new happens here: `createPersonAndLink` is slice 42's path, already one
    /// undoable step. What 45e adds is what the *caller* must show first — see
    /// `closestCandidates(to:)` — because an empty candidate list is not evidence that a
    /// person is new.
    func createPersonForReviewItem(_ item: ReviewItem) {
        createPersonAndLink(from: item.recordedMention, in: item.mention.artifact)
    }
}

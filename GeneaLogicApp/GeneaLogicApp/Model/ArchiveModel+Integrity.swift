import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Damage the archive already knows about (slice 56)

    /// Placeholder rows for records the archive could not read, split by the list
    /// each one is missing *from*. A record that failed to decode has no index
    /// row and therefore no title, name or uid to show — only its path — which is
    /// exactly why the row exists: without it the record is not "damaged" on
    /// screen, it is simply absent (slice 55's hand-test).
    ///
    /// **Since 58d these include records whose file is gone** but whose copy the
    /// index kept — absent from the list for a different reason, and the same
    /// problem from the user's chair. They come after the unreadable ones.
    var unreadableArtifacts: [UnreadableRecordRow] {
        placeholderRows.filter { $0.kind == .artifact }
    }

    var unreadablePersons: [UnreadableRecordRow] {
        placeholderRows.filter { $0.kind == .person }
    }

    /// Every record that stands in a list as a placeholder: unreadable (56) and
    /// missing with a copy (58d).
    private var placeholderRows: [UnreadableRecordRow] {
        standingFindings.unreadable.compactMap { UnreadableRecordRow($0) }
            + standingFindings.vanished.compactMap { UnreadableRecordRow(missing: $0) }
    }

    /// Unreadable records that have no browse list of their own (relationships,
    /// links, dismissals). They can only be reported in the banner — there is no
    /// row for them to be missing from.
    var unreadableOthers: [UnreadableRecordRow] {
        standingFindings.unreadable.compactMap { UnreadableRecordRow($0) }
            .filter { $0.kind == .other }
    }

    // MARK: - The cheap sweep (slice 57)

    /// Whether there is anything for the damage banner to say — either kind.
    var hasStandingDamage: Bool { !standingFindings.isEmpty || fileDamage != nil }

    /// Re-runs the cheap sweep **off the main actor** (fork e).
    ///
    /// Unlike `reloadStandingFindings()` — a `SELECT` over a tiny table, cheap
    /// enough to run inline — this is a `stat` per manifest entry, so its cost
    /// scales with the archive and it does not belong on the main actor. The
    /// engine call takes the read lock only long enough to snapshot the manifest,
    /// so the walk itself blocks no other reader.
    func reloadFileDamage() {
        guard let archive else {
            fileSweepTask?.cancel()
            fileSweepTask = nil
            fileSweepCoalesced = false
            fileDamage = nil
            return
        }
        // **Coalesce onto the walk already running; never cancel it**
        // (`/code-review`, 61). Cancel-and-replace was safe while the only
        // caller was `refresh()`, and stopped being safe the moment slice 61 put
        // this on the 1 Hz poll: `sweepFileSizes()` has no suspension point, so a
        // cancelled sweep runs to completion anyway and only its *result* is
        // thrown away. On an archive where one walk outlasts one tick — a large
        // manifest, a slow volume — every sweep was therefore cancelled by its
        // successor and **no result was ever applied**: `fileDamage` froze and
        // `deliveryLastProgressAt` never advanced, so a healthy multi-file
        // delivery escalated to "hasn't finished arriving" at ten minutes. That
        // is precisely the staleness fork (f) exists to remove, reintroduced by
        // the mechanism meant to bound its cost.
        //
        // Coalescing bounds the cost better anyway: one walk at a time whatever
        // the request rate, where cancel-and-replace piled up a new concurrent
        // walk every tick and merely *marked* the old ones dead.
        guard fileSweepTask == nil else {
            fileSweepCoalesced = true
            return
        }
        fileSweepCoalesced = false
        fileSweepTask = Task { [weak self] in
            let report = await Self.sweepFiles(archive)
            guard let self else { return }
            self.fileSweepTask = nil
            // The window may have loaded a different archive while we walked —
            // the same guard, and the same reason, as the reconcile task's.
            guard let report, self.archive === archive else { return }
            self.fileDamage = FileDamageSummary(report)
            self.noteArrivalProgress(in: report)
        }
    }

    /// The walk itself. `nonisolated` + `async` rather than `Task.detached`, for
    /// the reason `scoreDuplicates` is: a detached task outlives the cancellation
    /// of whatever started it.
    ///
    /// **Cancellation is checked here, before the walk, and that is the only
    /// place it can be** (review finding, 57). `sweepFileSizes()` is synchronous
    /// with no suspension point, so cancelling a sweep that has already started
    /// does nothing — it runs to completion whatever the handle says. Bounding a
    /// walk already in flight would mean a cancellation-aware sweep in the engine,
    /// which is not worth it for a call measured in milliseconds.
    ///
    /// **What that asymmetry cost, and why nothing supersedes a sweep any more**
    /// (`/code-review`, 61): since a cancelled walk runs anyway, cancel-and-replace
    /// only ever discarded a *finished* answer, which starved the display outright
    /// once slice 61 put this on the 1 Hz poll. Requests now coalesce onto the
    /// running walk (see `reloadFileDamage`), so the only cancellation left is the
    /// archive going away.
    private nonisolated static func sweepFiles(
        _ archive: Archive
    ) async -> Archive.FileSweepReport? {
        guard !Task.isCancelled else { return nil }
        return archive.sweepFileSizes()
    }

    /// Re-reads the standing findings, **never downgrading a warning because a
    /// read failed** (review finding, 56). `standingFindings()` throws when the
    /// index can't be read, which is itself a problem — clearing the banner on
    /// it would turn a second fault into reassurance. Keeping the last known
    /// findings is the safe direction, and the next refresh retries.
    func reloadStandingFindings() {
        guard let archive else {
            standingFindings = Archive.StandingFindings()
            repairPlans = [:]
            return
        }
        if let findings = try? archive.standingFindings() {
            standingFindings = findings
        }
        reloadRepairPlans()
    }

    // MARK: - Restoring a damaged record (slice 59)

    /// One call for the whole list, not one per record (review finding, 59).
    ///
    /// The plural engine call exists because the singular one is not as cheap as
    /// it looks: each reads and decodes the whole `manifest.json`, so a row-at-a-
    /// time loop parsed the manifest once per damaged record — on the main actor,
    /// on every refresh. Batched it is one parse whatever the damage count, which
    /// is what lets this ride the standing findings the way those ride every
    /// refresh: a repair that only appears after the user thinks to re-check is a
    /// repair nobody finds.
    private func reloadRepairPlans() {
        guard let archive else {
            repairPlans = [:]
            return
        }
        repairPlans =
            (try? archive.repairPlans(
                forRecordsAt: standingFindings.unreadableRecords + standingFindings.vanished))
            ?? [:]
    }

    /// Restores the record at `path` from the preserved copy (`repairRecord`).
    ///
    /// **Not on the undo stack**, for the reason `rebaseline()` isn't: its inverse
    /// would be putting a file the archive could not read back where it was, which
    /// is not an action to offer. What makes it reversible is the engine's own
    /// quarantine — the damaged file is moved to `.damaged/`, not overwritten — so
    /// the recovery path is a human with a text editor, which is the same audience
    /// the damaged file was always for.
    ///
    /// `announce` takes the quarantine notice instead of the window's alert — for
    /// the Verify Integrity panel, which sits in front of that alert. Handing the
    /// message over rather than having the sheet drain `actionInfo` afterwards
    /// means it can only ever be *this* restore's (`/code-review`, 58d).
    func repairRecord(
        atPath path: String, acceptingInexactRestore: Bool = false,
        announce: (@MainActor (String) -> Void)? = nil
    ) {
        mutate(unopened: "Open an archive before restoring a record.") { archive in
            try archive.repairRecord(
                atPath: path, acceptingInexactRestore: acceptingInexactRestore)
        } commit: { [self] outcome in
            bumpAndRefresh()
            // Said out loud rather than left to the row quietly turning real: a
            // repair moves a file the user may want, and where it went is the one
            // thing they cannot work out afterwards.
            if let quarantined = outcome.quarantinedPath {
                let message = Self.restoredMessage(quarantinedAt: quarantined)
                if let announce {
                    announce(message)
                } else {
                    showInfo(message, title: "Record Restored")
                }
            }
        }
    }

    static func restoredMessage(quarantinedAt quarantined: String) -> String {
        "The record was restored. The file that was there is kept in the archive at "
            + "\(quarantined), in case it was an edit you meant."
    }

    /// Repair plans for paths the caller holds rather than the standing findings —
    /// the Verify Integrity panel's `unreadableRecord` and `missingFile` rows (58d,
    /// fork h). Empty when no archive is open or the index can't be read: a row
    /// with no plan offers nothing, which is the safe side.
    func recordRepairPlans(forRecordsAt paths: [String]) -> [String: Archive.RecordRepairPlan] {
        guard let archive, !paths.isEmpty else { return [:] }
        return (try? archive.repairPlans(forRecordsAt: paths)) ?? [:]
    }

    /// Deletes a record whose file is gone (`deleteVanishedRecord`, slice 58d): the
    /// engine puts it back from its copy and deletes it the ordinary way.
    ///
    /// **Undoable, by the undo each kind already has** (settled on the hand-test):
    /// the engine hands back exactly what that kind's own delete does, so ⌘Z brings
    /// the record back as a live one and ⌘⇧Z deletes it again. Not back to *missing*
    /// — that state was damage, and the record restored is what the user can act on.
    /// An artifact is also in the Trash, which outlives the session.
    ///
    /// The engine refuses, under the write lock, when something is at the path; the
    /// refusal reaches the user through `actionError` like any failed mutation.
    func deleteVanishedRecord(atPath path: String) {
        mutate(unopened: "Open an archive before deleting a record.") { archive in
            try archive.deleteVanishedRecord(atPath: path)
        } commit: { [self] deleted in
            let actionName = "Delete Record"
            switch deleted {
            case .artifact(let uid, let deletion):
                registerArtifactRestore(of: uid, deletion: deletion, actionName: actionName)
            case .person(let person):
                registerPersonRestore(person, actionName: actionName)
            case .relationship(let relationship):
                registerRelationshipRestore(relationship, actionName: actionName)
            case .link(let link):
                registerLinkRestore(link, actionName: actionName)
            case .dismissal(let dismissal):
                registerDismissalRestore(dismissal, actionName: actionName)
            }
            bumpAndRefresh()
        }
    }

    // MARK: - Verify Integrity, dangling references, rebuild

    /// Runs the engine's `verifyIntegrity()` — SHA-256-checks every tracked file
    /// against the manifest and sweeps for stray files (§3, §6.3). `nil` only if
    /// no archive is open (the menu command is disabled in that case). Read-only:
    /// it touches nothing and is safe to re-run.
    ///
    /// **Off the main actor** (slice 57b), the same `nonisolated` + `async` shape
    /// `sweepFiles` uses. It was a synchronous main-actor call, which was already
    /// a long freeze on a large archive and became an unbounded one the moment
    /// this call could be asked to *download* the files it hashes: a spinner that
    /// paints once and then a dead window for as long as the network takes.
    ///
    /// - Parameter includingDatalessFiles: Hash files that aren't downloaded to
    ///   this machine, **downloading them to do it**. The default skips them and
    ///   the report names them (`IntegrityReport.notChecked`); only the panel's
    ///   explicit *Download and Check the Rest* passes `true`.
    ///
    /// Throws only `ArchiveError.archiveNewerThanBuild` in practice (slice 70): a
    /// record from a newer GeneaLogic is refused, not reported as damage.
    func verifyIntegrity(includingDatalessFiles: Bool = false) async throws -> IntegrityReport? {
        guard let archive else { return nil }
        return try await Self.verify(archive, includingDatalessFiles: includingDatalessFiles)
    }

    /// **Deliberately without `sweepFiles`' `guard !Task.isCancelled` check**
    /// (`/code-review`, 57b). That guard exists because the sweep is synchronous
    /// and uncancellable once started, so the only thing cancellation can do is
    /// stop one that has not begun — and its `nil` means *no answer*. This pass
    /// is cancellable to the chunk, and a cancelled one returns a **report**:
    /// everything it did not read, named. Returning `nil` here instead would
    /// discard that and leave the panel rendering "No archive is open" for a
    /// download the user themselves stopped.
    private nonisolated static func verify(
        _ archive: Archive, includingDatalessFiles: Bool
    ) async throws -> IntegrityReport {
        try archive.verifyIntegrity(includingDatalessFiles: includingDatalessFiles)
    }

    /// Runs the engine's `findDanglingReferences()` — the referential sweep over
    /// the conclusion records, reported beside the file checks in the same panel.
    /// A separate call because it answers a different question (do the pointers
    /// resolve, not do the bytes match) and costs no hashing. `nil` only if no
    /// archive is open. Read-only, like `verifyIntegrity()`.
    func findDanglingReferences() -> [DanglingReference]? {
        archive?.findDanglingReferences()
    }

    /// Clears one dangling reference by removing the **stale pointer**, never the record
    /// that still exists (slice 44g — the integrity panel's "Remove Stale Reference").
    /// Every case routes through an existing undoable mutation, so ⌘Z puts the pointer
    /// back; nothing here is a new kind of write.
    ///
    /// Note the asymmetry, which is deliberate: a broken *citation* (`supportedByLinks`)
    /// is dropped from the record that holds it, and a broken **link** is unlinked — but
    /// a relationship whose endpoint is gone can only be removed **whole**, because a
    /// relationship with one end is not a relationship. That is why the panel offers
    /// Reveal too: repointing it at a surviving person (the Relationships row's "Replace
    /// Person…") is usually what the researcher actually wants.
    func removeDanglingReference(_ dangling: DanglingReference) {
        switch dangling {
        case .linkArtifact(let link, _), .linkPerson(let link, _), .linkMention(let link, _, _):
            unlinkMention(link, actionName: "Remove Stale Reference")
        case .relationshipEndpoint(let relationship, _):
            deleteRelationship(relationship)
        case .relationshipSupport(let relationship, let missing):
            updateRelationship(of: relationship, actionName: "Remove Stale Citation") {
                $0.supportedByLinks.removeAll { $0 == missing }
            }
        case .relationshipFactSupport(let relationship, let factIndex, let missing):
            updateRelationship(of: relationship, actionName: "Remove Stale Citation") {
                // Bounds-checked inside the closure: the index was read from a snapshot
                // that an undo could have superseded (the Events/Facts editing rule).
                guard $0.facts.indices.contains(factIndex) else { return }
                $0.facts[factIndex].supportedByLinks.removeAll { $0 == missing }
            }
        case .personFactSupport(let person, let factIndex, let missing):
            updatePerson(of: person, actionName: "Remove Stale Citation") {
                guard $0.facts.indices.contains(factIndex) else { return }
                $0.facts[factIndex].supportedByLinks.removeAll { $0 == missing }
            }
        case .mentionRelationshipEndpoint(let artifact, let edgeIndex, let missingRef):
            // A stated edge with one end missing is the relationship case, not the
            // citation case: an edge to nobody is not an edge, so it goes whole. The
            // edge is re-identified by its endpoint rather than trusted by index —
            // the panel's snapshot may predate an undo that reordered the array.
            updateMetadata(of: artifact, actionName: "Remove Stale Relationship") { record in
                guard record.mentionRelationships.indices.contains(edgeIndex),
                    record.mentionRelationships[edgeIndex].involves(missingRef)
                else { return }
                record.mentionRelationships.remove(at: edgeIndex)
            }
        case .dismissalEndpoint(let dismissal, _):
            // A dismissal about somebody who no longer exists is the relationship case,
            // not the citation case: it is a judgement *about the pair*, so it goes whole.
            removeDismissal(dismissal, actionName: "Remove Stale Reference")
        }
    }

    /// Removes one dismissal by uid, undoably — the repair path for a dangling one. Kept
    /// beside `removeDanglingReference` rather than inside it because the undo has to
    /// register the same restore↔remove ping-pong `dismissDuplicate` does.
    private func removeDismissal(_ id: DismissalID, actionName: String) {
        mutate(unopened: "Open an archive before removing a dismissal.") { archive in
            try archive.removeDismissal(id)
        } commit: { [self] removed in
            registerDismissalRestore(removed, actionName: actionName)
            bump()
        } failure: { [self] error in
            guard case ArchiveError.dismissalNotFound = error else { return false }
            showInfo("That dismissal is no longer in the archive.", title: "Already Removed")
            return true
        }
    }

    /// Jumps to the record that *holds* a dangling reference, so it can be repaired in
    /// context (the integrity panel's "Reveal"). The target is the surviving end: a link
    /// whose artifact is gone is revealed on its **person** (the Sources section), any
    /// other link on its **artifact** (the Persons Mentioned row that can re-resolve it),
    /// and a relationship on whichever endpoint still exists.
    ///
    /// - Returns: `false` when nothing survives to navigate to — a link with *both* ends
    ///   deleted, say — so the caller can leave the panel open rather than dismissing it
    ///   onto nothing.
    @discardableResult
    func revealDanglingReference(_ dangling: DanglingReference) -> Bool {
        func showPerson(_ id: PersonID) -> Bool {
            guard persons.contains(where: { $0.uid == id }) else { return false }
            navigateToPerson(id)
            return true
        }
        func showArtifact(_ id: ArtifactID) -> Bool {
            guard artifacts.contains(where: { $0.uid == id }) else { return false }
            navigateToArtifact(id)
            return true
        }

        switch dangling {
        case .linkArtifact(let link, _):
            guard let record = archive?.evidenceLink(withID: link) else { return false }
            return showPerson(record.personUid)
        case .linkPerson(let link, _), .linkMention(let link, _, _):
            guard let record = archive?.evidenceLink(withID: link) else { return false }
            return showArtifact(record.artifactUid)
        case .relationshipEndpoint(let relationship, _), .relationshipSupport(let relationship, _),
            .relationshipFactSupport(let relationship, _, _):
            guard let record = archive?.relationship(withID: relationship) else { return false }
            return showPerson(record.person1Uid) || showPerson(record.person2Uid)
        case .personFactSupport(let person, _, _):
            return showPerson(person)
        case .mentionRelationshipEndpoint(let artifact, _, let missingRef):
            // Only when the edge is actually *drawn* over there. It renders under the
            // surviving end's mention row (as "(removed)"), so an edge that lost **both**
            // ends appears nowhere — revealing that would dismiss the panel onto a page
            // that looks entirely normal, which is precisely what `isRevealable`'s rule
            // forbids. Same shape as a relationship with neither endpoint left: offer it,
            // and answer `false` when nothing survives to navigate to.
            guard let record = archive?.artifact(withID: artifact),
                let edge = record.mentionRelationships.first(where: { $0.involves(missingRef) }),
                let survivor = edge.other(from: missingRef),
                record.personsMentioned.contains(where: { $0.localRef == survivor })
            else { return false }
            return showArtifact(artifact)
        case .dismissalEndpoint:
            // Nothing draws a dismissal, so there is nowhere to reveal it — see
            // `isRevealable`, which never offers this one.
            return false
        }
    }

    /// Regenerates the disposable `.index/` cache from the on-disk sidecars (the
    /// §5.1 out-of-band-edit fix surfaced from the integrity panel). Safe and
    /// idempotent — it rebuilds a *derived* cache and never touches a record — so
    /// it is deliberately **not** on the undo stack.
    ///
    /// Goes through `bumpAndRefresh()` rather than `refresh()`: a rebuild exists
    /// precisely because the index may have been serving something other than what
    /// the sidecars say, so it can change what an **open detail pane** shows, not
    /// just the browse list. It called plain `refresh()` until slice 51 and left
    /// that pane stale — the same defect `/code-review` found on the
    /// external-change path, arrived at independently, which is why `refresh()` is
    /// now private.
    func rebuildIndex() {
        mutate(unopened: "Open an archive before rebuilding the index.") { archive in
            try archive.rebuildIndex()
        } commit: { [self] _ in
            bumpAndRefresh()
        }
    }

    /// Accepts the archive's current contents as the truth: rebuilds the index and
    /// re-records every checksum the manifest is the sole authority for (slice 49's
    /// `rebaseline()`, surfaced from the integrity panel).
    ///
    /// **Offered only when the panel has something for it to resolve**, because it
    /// is the one action there that can *stop* a real problem being reported: a
    /// mismatch on a `record.json` is either a hand edit or bit rot, and the engine
    /// deliberately refuses to guess which. Surfacing it as an always-available
    /// button next to Rebuild Index would invite it as a way to make the report go
    /// quiet. Like the rebuild it changes no record, so it is not on the undo stack
    /// — but unlike the rebuild it is not idempotent in the sense that matters: the
    /// prior baseline is gone afterwards.
    func rebaseline() {
        mutate(unopened: "Open an archive before rebaselining.") { archive in
            try archive.rebaseline()
        } commit: { [self] _ in
            bumpAndRefresh()
        }
    }

    /// **Stops waiting for one named file** the manifest expects and that is
    /// never going to arrive (slice 50d's `abandonDelivery(path:)`, surfaced per
    /// row from the integrity panel).
    ///
    /// **Per row, not per archive**, which is the whole difference from
    /// `rebaseline()` above: this decides one path, on the row that names it,
    /// and leaves every other finding exactly as it was. It is also recoverable
    /// — nothing is deleted, and a version that turns up later is adopted
    /// normally — which is why it is offered inline where "Accept Current
    /// Contents" is deliberately a footer button behind a confirmation.
    ///
    /// The engine refuses anything that is not actually awaited, so a row that
    /// has resolved itself between the sweep and the click reports rather than
    /// laundering damage.
    func abandonDelivery(path: String) {
        mutate(unopened: "Open an archive before abandoning a delivery.") { archive in
            try archive.abandonDelivery(path: path)
        } commit: { [self] _ in
            bumpAndRefresh()
        }
    }
}

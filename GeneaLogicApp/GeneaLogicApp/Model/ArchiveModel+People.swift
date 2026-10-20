import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - People (conclusions, Phase 3): browse, read, reload

    /// Whether the people list is filtered — a non-blank people search.
    var isFilteringPeople: Bool { !personSearchText.trimmed.isEmpty }

    /// What the People tab shows: the full list, or the current search results.
    var displayedPersons: [PersonSummary] { isFilteringPeople ? personFilterResults : persons }

    /// The full `Person` record behind a browse summary, for the detail pane.
    /// `nil` if the archive isn't open or the id is unknown. The People analog of
    /// `fullArtifact`.
    func fullPerson(_ id: PersonID) -> Person? {
        archive?.person(withID: id)
    }

    /// Reloads the People browse list from the engine, re-sorted by display name,
    /// and re-runs the active people search if one is up. Called from `load()` and
    /// on every `refresh()`, so a person add/delete (or undo/redo) is visible.
    func reloadPersons() {
        guard let archive else {
            persons = []
            personFilterResults = []
            return
        }
        persons = Self.sortedPersons(archive.persons())
        if isFilteringPeople { applyPersonFilter() }
    }

    /// Orders people by display name (case/diacritic-insensitive), unnamed people
    /// last, with a uid tiebreak so the order is stable.
    private static func sortedPersons(_ list: [PersonSummary]) -> [PersonSummary] {
        list.sorted { a, b in
            switch (a.displayName, b.displayName) {
            case let (x?, y?):
                let r = x.localizedStandardCompare(y)
                if r != .orderedSame { return r == .orderedAscending }
            case (_?, nil): return true  // named before unnamed
            case (nil, _?): return false
            case (nil, nil): break
            }
            return a.uid.raw < b.uid.raw
        }
    }

    /// Runs the people search through the engine's `persons(matching:)` (name
    /// search across every one of a person's names) into `personFilterResults`.
    /// With no query it clears them (`displayedPersons` then shows the full list).
    func applyPersonFilter() {
        let query = personSearchText.trimmed
        guard let archive, !query.isEmpty else {
            personFilterResults = []
            return
        }
        personFilterResults = Self.sortedPersons(
            archive.persons(matching: PersonQuery(text: query)))
    }

    /// A synchronous name search over concluded persons — across *every* one of a
    /// person's names, via the same engine `persons(matching:)` the People tab's
    /// `.searchable` uses — so the resolve-mention picker matches identically. An empty
    /// query returns the full (sorted) list.
    func matchingPersons(_ text: String) -> [PersonSummary] {
        let query = text.trimmed
        guard !query.isEmpty else { return persons }
        guard let archive else { return [] }
        return Self.sortedPersons(archive.persons(matching: PersonQuery(text: query)))
    }

    // MARK: - People (create / delete, undoable)

    /// Creates a concluded person from a given/surname pair (the New Person sheet,
    /// via `PersonDraft`'s convenience path). **Undoable**: the first ⌘Z removes the
    /// person, ⌘⇧Z restores it uid-faithfully — the same delete↔restore ping-pong as
    /// artifacts, but **in-session only, not trash-backed** (the slice-40 decision:
    /// the manual conclusions loop is new and records are cheap to recreate).
    /// Publishes `lastCreatedPerson` so the People tab selects the new person.
    func createPerson(given: String?, surname: String?) {
        mutate(unopened: "Open an archive before adding a person.") { archive in
            try archive.addPerson(PersonDraft(given: given, surname: surname))
        } commit: { [self] person in
            registerPersonRedelete(of: person.uid, actionName: "Add Person")
            lastCreatedPerson = person.uid
            bumpAndRefresh()
            // A new person can *be* a duplicate — that is the case the lane exists for,
            // and the one the somebody-new path creates by accident.
            refreshDuplicateCandidatesIfShown()
        }
    }

    /// Deletes a concluded person (the People list's ⌫ / context-menu delete),
    /// undoably. Removing a person leaves any relationship/evidence-link that
    /// referenced it **dangling** — that's `verifyIntegrity`'s job (§2.3), and is
    /// also what keeps the delete cleanly reversible (no cascade to undo).
    func deletePerson(_ id: PersonID) {
        mutate(unopened: "Open an archive before deleting.") { archive in
            try archive.removePerson(id)
        } commit: { [self] removed in
            registerPersonRestore(removed, actionName: "Delete Person")
            bumpAndRefresh()
            // Same reason as the merge: a duplicates row naming a deleted person offers a
            // merge that can only throw.
            dropDuplicateRows(naming: id)
            refreshDuplicateCandidatesIfShown()
        }
    }

    /// Applies an in-place edit to person `id` — add/edit/remove a name or fact (the
    /// People-tab detail pane's editors). The person analog of `updateMetadata`, and
    /// like it **undoable** via a full-record **snapshot-restore** (the before/after
    /// records ping-pong on ⌘Z/⌘⇧Z under `actionName`) — a *different* shape from the
    /// create/delete redelete ping-pong: an edit restores a snapshot, it doesn't
    /// re-create a record. `uid`/`schemaVersion` are immutable via the engine path.
    ///
    /// The `mutate` closure edits by array index and must bounds-check against the
    /// record it's handed (an index captured at row-render time can go stale before
    /// the write commits — a concurrent undo, say — so the guard lives *inside* the
    /// closure, over the current record).
    /// `edit` is `@Sendable`, and the before-snapshot is taken on the write queue,
    /// both for the reasons spelled out on `updateMetadata`.
    func updatePerson(
        of id: PersonID, actionName: String = "Edit Person",
        _ edit: @escaping @Sendable (inout Person) -> Void
    ) {
        guard archive?.person(withID: id) != nil else {
            actionError =
                archive == nil
                ? "Open an archive before editing." : "Couldn't load this person to edit."
            return
        }
        mutate(unopened: "Open an archive before editing.") { archive in
            let before = archive.person(withID: id)
            return (before, try archive.updatePerson(id, edit))
        } commit: { [self] before, after in
            if let before {
                registerPersonEdit(of: id, to: before, redoingTo: after, actionName: actionName)
            }
            bumpAndRefresh()
        }
    }

    /// Registers an undo that restores person `id` to the `target` snapshot, then
    /// re-registers the symmetric redo (`redoTarget`) — so an edit undoes/redoes
    /// indefinitely, the same snapshot-restore ping-pong as `registerArtifactRestore`.
    /// If the person has since gone out-of-band (deleted), the step no-ops
    /// **gracefully** (a benign notice, not an error), and the stack advances.
    private func registerPersonEdit(
        of id: PersonID, to target: Person, redoingTo redoTarget: Person, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
            model.registerPersonEdit(
                of: id, to: redoTarget, redoingTo: target, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.updatePerson(id) { $0 = target }
            } commit: { _ in
                model.bumpAndRefresh()
            } failure: { error in
                guard case ArchiveError.personNotFound = error else { return false }
                model.showInfo("That person is no longer in the archive.", title: "Can’t Edit")
                return true
            }
        }
    }

    /// Registers an undo that **restores** a removed person (the exact uid-faithful
    /// record), then registers the symmetric redo (remove it again) — the undo side
    /// of a *deletion*. `restorePerson` rewrites the same sidecar, so ⌘Z/⌘⇧Z
    /// ping-pong indefinitely. The removed `Person` is captured in the closure, so
    /// there's no trash entry to go missing (in-session only).
    func registerPersonRestore(_ person: Person, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.restorePerson(person, actionName: actionName)
        }
    }

    /// The promised-payload variant: a redelete can't name the record it will
    /// remove until it has removed it. See `PendingFileChange`.
    private func registerPersonRestore(pending: PendingPerson, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            guard let person = pending.person else { return }
            model.restorePerson(person, actionName: actionName)
        }
    }

    /// Restores `person` and registers the redelete that reverses it.
    private func restorePerson(_ person: Person, actionName: String) {
        // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
        registerPersonRedelete(of: person.uid, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.restorePerson(person)
        } commit: { [self] _ in
            bumpAndRefresh()
            refreshDuplicateCandidatesIfShown()
        }
    }

    /// The removed `Person` a redelete hands to the restore that reverses it.
    private final class PendingPerson {
        var person: Person?
    }

    /// Registers an undo that **deletes** person `id` (capturing the removed record),
    /// then registers the symmetric restore — the undo side of an *addition* (and the
    /// redo side of a deletion). `createPerson` calls this so adding a person is
    /// undoable. If the person is already gone (removed out-of-band), it no-ops
    /// gracefully with a benign notice, and the stack advances.
    func registerPersonRedelete(of id: PersonID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            let removed = PendingPerson()
            // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
            model.registerPersonRestore(pending: removed, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.removePerson(id)
            } commit: { person in
                removed.person = person
                model.bumpAndRefresh()
                // Same structural change as `deletePerson`, so the same two steps: drop
                // the rows that are now impossible, then re-score the rest.
                model.dropDuplicateRows(naming: id)
                model.refreshDuplicateCandidatesIfShown()
            } failure: { error in
                guard case ArchiveError.personNotFound = error else { return false }
                model.showInfo(
                    "That person is no longer in the archive.", title: "Already Removed")
                return true
            }
        }
    }

    /// Merges one concluded person into another — the People list's "Merge Into…"
    /// (slice 45f). Every record naming `absorbed` is repointed at `survivor`, the two
    /// records' names and facts are union'd, and the absorbed sidecar goes.
    ///
    /// **The one mutation in the app that cascades**, which is why its undo is shaped
    /// differently from every other one here: a merge rewrites N records, so there is no
    /// snapshot to ping-pong. The engine hands back a `MergeDecision` carrying the
    /// before-state of everything it touched, and undo replays it through `revertMerge`
    /// — one step, however many records moved. Redo re-runs the merge, which is
    /// deterministic over the restored archive.
    ///
    /// Publishes `lastCreatedPerson` so the People tab follows the survivor: the row the
    /// user right-clicked is gone, and leaving the selection on a deleted person shows
    /// "Person Not Found" at the end of a successful operation.
    func mergePersons(_ absorbed: PersonID, into survivor: PersonID) {
        mutate(unopened: "Open an archive before merging.") { archive in
            try archive.mergePersons(absorbed, into: survivor)
        } commit: { [self] decision in
            registerMergeRevert(decision, actionName: "Merge People")
            lastCreatedPerson = survivor
            bumpAndRefresh()
            // The absorbed person is gone, so any duplicates row naming them now offers an
            // impossible operation — and every *other* pair's score moved too, since the
            // survivor absorbed a second record's names and facts.
            dropDuplicateRows(naming: absorbed)
            refreshDuplicateCandidatesIfShown()
            reportMerge(decision)
        } failure: { [self] error in
            // The cascade writes before it deletes (45d's ordering), so a throw can leave
            // real changes on disk — show them either way, rather than a pane still
            // drawing the pre-merge archive.
            defer {
                bumpAndRefresh()
                refreshDuplicateCandidatesIfShown()
            }
            // `personNotFound` is reachable from a stale row: another window, an undo, or
            // a merge already done from this same row. Not an error the user can act on —
            // say so plainly and re-scan, which is what clears the row that offered it.
            guard case ArchiveError.personNotFound = error else { return false }
            showInfo(
                "One of those people is no longer in the archive. This list has been "
                    + "refreshed.", title: "Can’t Merge")
            return true
        }
    }

    /// Registers an undo that reverts `decision`, then registers the symmetric redo —
    /// the merge↔revert ping-pong.
    ///
    /// Re-merging on redo rather than replaying a stored "after" state is deliberate:
    /// the revert restored the exact archive the merge ran against, so the same call
    /// produces the same cascade, and a *new* decision is what the next undo needs. A
    /// captured after-state would go stale the moment anything else changed.
    private func registerMergeRevert(_ decision: MergeDecision, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.revertMerge(decision, actionName: actionName)
        }
    }

    /// Reverts `decision` and registers the re-merge that reverses it — the body
    /// behind both registration variants.
    private func revertMerge(_ decision: MergeDecision, actionName: String) {
        // Counterpart first — see *Undo across the actor hop* in `ArchiveModel.swift`.
        registerMergeRedo(
            absorbed: decision.absorbed.uid, survivor: decision.survivor.uid,
            actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.revertMerge(decision)
        } commit: { [self] _ in
            bumpAndRefresh()
            // The absorbed person exists again, so the pair is a candidate again.
            refreshDuplicateCandidatesIfShown()
        } failure: { [self] _ in
            refreshDuplicateCandidatesIfShown()
            return false
        }
    }

    private func registerMergeRedo(
        absorbed: PersonID, survivor: PersonID, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            // A re-merge produces a *new* decision (that is the point — see
            // `registerMergeRevert`), so its counterpart is a promise.
            let redone = PendingMerge()
            model.registerMergeRevert(pending: redone, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.mergePersons(absorbed, into: survivor)
            } commit: { decision in
                redone.decision = decision
                model.bumpAndRefresh()
                model.dropDuplicateRows(naming: absorbed)
                model.refreshDuplicateCandidatesIfShown()
            } failure: { error in
                guard case ArchiveError.personNotFound = error else { return false }
                model.showInfo(
                    "One of those people is no longer in the archive.", title: "Can’t Merge")
                model.refreshDuplicateCandidatesIfShown()
                return true
            }
        }
    }

    /// The `MergeDecision` a redo hands back to the revert that reverses it.
    private final class PendingMerge {
        var decision: MergeDecision?
    }

    /// The promised-payload variant of `registerMergeRevert`.
    private func registerMergeRevert(pending: PendingMerge, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            guard let decision = pending.decision else { return }
            model.revertMerge(decision, actionName: actionName)
        }
    }

    /// Tells the user what the cascade did — the app-side analog of `genea person merge`'s
    /// report, and of `reportDisplacement` for a link write.
    ///
    /// A merge silently rewrites records the user never named; the counts are how they
    /// find out. Dropped records are named individually, because they no longer exist and
    /// a number is not something anyone can go and look at. Benign-info channel: nothing
    /// failed.
    private func reportMerge(_ decision: MergeDecision) {
        var lines: [String] = []

        // Only records whose *endpoint* moved are reported as moved: a relationship the
        // merge touched solely to follow a citation can belong to two people who have
        // nothing to do with it, and "moved onto Marcus Hanner" would be false of them.
        let moved = decision.repointedRelationships.count
        if decision.relinkedLinks.count + moved > 0 {
            lines.append(
                "Repointed \(decision.relinkedLinks.count) evidence link(s) and "
                    + "\(moved) relationship(s) onto "
                    + "“\(decision.survivor.displayName ?? "this person")”.")
        }
        if decision.citationFollowingRewrites > 0 {
            lines.append(
                "Updated \(decision.citationFollowingRewrites) other record(s) that cited a "
                    + "link the merge combined.")
        }
        for link in decision.droppedLinks {
            lines.append(
                "Dropped an earlier “\(link.reviewStatus.rawValue)” verdict "
                    + "(\(link.uid.raw)) — the merge put two verdicts on one mention.")
        }
        for relationship in decision.droppedRelationships {
            lines.append(
                relationship.involves(decision.absorbed.uid)
                    && relationship.involves(decision.survivor.uid)
                    ? "Dropped a relationship between the two merged people "
                        + "(\(relationship.uid.raw))."
                    : "Dropped a duplicate relationship (\(relationship.uid.raw)); its facts "
                        + "were kept on the one that remains.")
        }
        // The contradiction gets its own sentence, and it is the strongest one here: every
        // other line reports bookkeeping, this one reports that the merge overruled an
        // earlier judgement of the user's own. A cascade effect that reverses a human
        // decision must not be folded into a count.
        let contradicted = Set(decision.contradictedDismissals.map(\.uid))
        for dismissal in decision.droppedDismissals {
            lines.append(
                contradicted.contains(dismissal.uid)
                    ? "You had recorded these two as different people. That record is gone — "
                        + "merging them says otherwise."
                    : "Dropped a duplicate “not a duplicate” record (\(dismissal.uid.raw)).")
        }
        for stranded in decision.strandedCitations {
            lines.append("\(stranded.summary): \(stranded.detail)")
        }

        guard !lines.isEmpty else { return }
        lines.append("⌘Z undoes the whole merge.")
        showInfo(lines.joined(separator: "\n\n"), title: "Merged")
    }
}

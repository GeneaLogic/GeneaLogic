import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Relationships (assert / delete / edit, undoable — slice 43)

    /// Every relationship in which `id` participates (as parent, child, or partner) —
    /// the person detail pane's Relationships section. A read-only projection over the
    /// index; the detail view loads it off `mutationVersion`, so an assert/delete/undo
    /// refreshes the section.
    func relationships(of id: PersonID) -> [Relationship] {
        archive?.relationships(of: id) ?? []
    }

    /// Every relationship in the archive — the whole conclusion graph, which the Tree
    /// tab feeds to `TreeProjection` in one pass rather than walking outward with
    /// per-person queries. Uid-ordered from the index, which is what makes the derived
    /// layout reproducible. Read off `mutationVersion` like the other projections.
    func allRelationships() -> [Relationship] {
        archive?.relationships() ?? []
    }

    /// Asserts a relationship between two existing persons (the Relationship editor's
    /// Create action). For `parent-child`, `person1` is the **parent** and `person2` the
    /// **child** (the fixed §4.5 convention the perspective picker maps to); for a
    /// `couple` the endpoints are symmetric. **Undoable**: ⌘Z removes it, ⌘⇧Z re-creates
    /// it — the create↔delete ping-pong. No dedup: asserting the same pair twice is the
    /// user's call (the engine doesn't dedupe, and a manual double-assert is cheap to
    /// undo), consistent with the no-cascade minimalism (§2.3).
    /// `qualifier` records the **nature** of a `parent-child` link (adoptive, step,
    /// foster, guardian, or explicitly biological — slice 44f) as a fact on the
    /// relationship, per GEDCOM X. `nil` leaves it **unspecified**, which is not the
    /// same as biological: a link whose nature hasn't been established must not have
    /// one asserted on the researcher's behalf.
    func createRelationship(
        type: RelationshipType, person1: PersonID, person2: PersonID,
        qualifier: FactType? = nil
    ) {
        mutate(unopened: "Open an archive before adding a relationship.") { archive in
            try archive.addRelationship(
                RelationshipDraft(
                    type: type, person1Uid: person1, person2Uid: person2,
                    facts: qualifier.map { [PersonFact(type: $0)] } ?? []))
        } commit: { [self] relationship in
            registerRelationshipRedelete(of: relationship.uid, actionName: "Add Relationship")
            bumpAndRefresh()
        }
    }

    /// Sets (or clears, with `nil`) the **nature** of an existing `parent-child`
    /// relationship — the retroactive twin of `createRelationship`'s `qualifier`, since
    /// the nature of a link is often learned after the link itself (slice 44f).
    ///
    /// Replaces any existing parent-child qualifier rather than appending, so a link
    /// carries at most one: they are mutually exclusive answers to the same question.
    /// Any *other* fact on the relationship (a dated adoption's place, a value written
    /// by another tool) is carried through untouched. **Undoable** via the shared
    /// snapshot-restore path.
    func setParentChildQualifier(_ id: RelationshipID, to qualifier: FactType?) {
        updateRelationship(of: id, actionName: "Change Relationship Nature") { relationship in
            relationship.facts.removeAll { FactType.parentChildCases.contains($0.type) }
            if let qualifier {
                relationship.facts.append(PersonFact(type: qualifier))
            }
        }
    }

    /// Repoints a relationship endpoint that dangles onto a deleted person at a person
    /// who still exists (slice 44g — the Relationships row's "Replace Person…"). Which
    /// side is rewritten follows from *which* uid is missing, so the §4.5 convention
    /// (`person1Uid` is the parent) is preserved without the caller thinking about it.
    ///
    /// Undoable through the shared `updateRelationship` snapshot ping-pong. A no-op if
    /// `missing` isn't actually an endpoint (the record changed under us).
    func replaceRelationshipEndpoint(
        _ id: RelationshipID, replacing missing: PersonID, with replacement: PersonID
    ) {
        updateRelationship(of: id, actionName: "Replace Person") { relationship in
            if relationship.person1Uid == missing { relationship.person1Uid = replacement }
            if relationship.person2Uid == missing { relationship.person2Uid = replacement }
        }
    }

    /// Deletes a relationship (a Relationships-row remove), undoably. Removing it leaves
    /// both endpoint persons untouched (a relationship references persons, not the
    /// reverse) — there's no cascade to worry about here.
    func deleteRelationship(_ id: RelationshipID) {
        mutate(unopened: "Open an archive before deleting.") { archive in
            try archive.removeRelationship(id)
        } commit: { [self] removed in
            registerRelationshipRestore(removed, actionName: "Delete Relationship")
            bumpAndRefresh()
        }
    }

    /// Undo side of *removing* a relationship (`deleteRelationship`): restore the exact
    /// record on ⌘Z, then re-register the redelete — the restore↔redelete ping-pong
    /// (parallels `registerPersonRestore`). The removed `Relationship` is captured, so
    /// there's no trash entry to go missing (in-session only, §2.3).
    func registerRelationshipRestore(_ relationship: Relationship, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.restoreRelationship(relationship, actionName: actionName)
        }
    }

    /// The promised-payload variant: a redelete can't name the record it will
    /// remove until it has removed it. See `PendingFileChange`.
    private func registerRelationshipRestore(
        pending: PendingRelationship, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            guard let relationship = pending.relationship else { return }
            model.restoreRelationship(relationship, actionName: actionName)
        }
    }

    /// Restores `relationship` and registers the redelete that reverses it.
    private func restoreRelationship(_ relationship: Relationship, actionName: String) {
        // Counterpart first — see *Undo across the actor hop* above.
        registerRelationshipRedelete(of: relationship.uid, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.restoreRelationship(relationship)
        } commit: { [self] _ in
            bumpAndRefresh()
        }
    }

    /// The removed `Relationship` a redelete hands to the restore that reverses it.
    private final class PendingRelationship {
        var relationship: Relationship?
    }

    /// Undo side of *adding* a relationship (`createRelationship`) and redo side of a
    /// deletion: remove `id` (capturing the record) on ⌘Z, then re-register the restore
    /// (parallels `registerPersonRedelete`). Already-gone no-ops gracefully.
    func registerRelationshipRedelete(of id: RelationshipID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            let removed = PendingRelationship()
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerRelationshipRestore(pending: removed, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.removeRelationship(id)
            } commit: { relationship in
                removed.relationship = relationship
                model.bumpAndRefresh()
            } failure: { error in
                guard case ArchiveError.relationshipNotFound = error else { return false }
                model.showInfo(
                    "That relationship is no longer in the archive.", title: "Already Removed")
                return true
            }
        }
    }

    /// Applies an in-place edit to relationship `id` — add/edit/remove a couple's
    /// marriage/divorce/annulment fact (slice 43b). The relationship analog of
    /// `updatePerson`, and like it **undoable** via a full-record **snapshot-restore**
    /// (before/after ping-pong on ⌘Z/⌘⇧Z under `actionName`), a *different* shape from
    /// the create/delete redelete ping-pong. `uid`/`schemaVersion` are immutable via the
    /// engine path; the app only ever mutates `facts` through this closure (never the
    /// endpoints).
    ///
    /// The `mutate` closure edits `facts` by array index and must bounds-check against
    /// the record it's handed — an index captured at row-render time can go stale before
    /// the write commits (a concurrent undo), so the guard lives *inside* the closure.
    /// `edit` is `@Sendable`, and the before-snapshot is taken on the write queue,
    /// both for the reasons spelled out on `updateMetadata`.
    func updateRelationship(
        of id: RelationshipID, actionName: String = "Edit Relationship",
        _ edit: @escaping @Sendable (inout Relationship) -> Void
    ) {
        guard archive?.relationship(withID: id) != nil else {
            actionError =
                archive == nil
                ? "Open an archive before editing."
                : "Couldn't load this relationship to edit."
            return
        }
        mutate(unopened: "Open an archive before editing.") { archive in
            let before = archive.relationship(withID: id)
            return (before, try archive.updateRelationship(id, edit))
        } commit: { [self] before, after in
            if let before {
                registerRelationshipEdit(
                    of: id, to: before, redoingTo: after, actionName: actionName)
            }
            bumpAndRefresh()
        }
    }

    /// Registers an undo that restores relationship `id` to the `target` snapshot, then
    /// re-registers the symmetric redo — the snapshot-restore ping-pong behind editing a
    /// couple's facts (parallels `registerPersonEdit`). If the relationship has since
    /// gone out-of-band (deleted), the step no-ops **gracefully** (a benign notice, not
    /// an error), and the stack advances.
    private func registerRelationshipEdit(
        of id: RelationshipID, to target: Relationship, redoingTo redoTarget: Relationship,
        actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerRelationshipEdit(
                of: id, to: redoTarget, redoingTo: target, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.updateRelationship(id) { $0 = target }
            } commit: { _ in
                model.bumpAndRefresh()
            } failure: { error in
                guard case ArchiveError.relationshipNotFound = error else { return false }
                model.showInfo(
                    "That relationship is no longer in the archive.", title: "Can’t Edit")
                return true
            }
        }
    }

    /// Records a couple fact (marriage/divorce/annulment) between `subject` and an
    /// existing `partner` who **isn't yet** a couple partner — creating the couple
    /// relationship first, then appending the fact (slice 43c's "Other person…" path).
    /// Both writes register their undo in one run-loop event, so the window's
    /// `UndoManager` groups them: one ⌘Z removes the fact *and* the relationship the fact
    /// created, one ⌘⇧Z brings both back. Registration order (relationship-create, then
    /// fact-edit) makes ⌘Z run fact-restore then relationship-remove (LIFO), and redo run
    /// relationship-restore then fact-redo — so the relationship always exists when its
    /// fact is (re)written (the same ordering discipline as `createPersonAndLink`).
    func recordCoupleFact(
        between subject: PersonID, and partner: PersonID, fact: PersonFact,
        actionName: String = "Add Relationship Fact"
    ) {
        // Both engine writes in one `work`, so both undo registrations land in one
        // run-loop turn and stay a single ⌘Z (52) — see `mutate`.
        mutate(unopened: "Open an archive before recording a marriage.") { archive in
            let relationship = try archive.addRelationship(
                RelationshipDraft(type: .couple, person1Uid: subject, person2Uid: partner))
            // Caught rather than thrown, so `commit` still sees the relationship this
            // call did create and can register its undo — see `Partial`.
            do {
                let after = try archive.updateRelationship(relationship.uid) {
                    $0.facts.append(fact)
                }
                return Partial(value: (relationship, Optional(after)))
            } catch {
                return Partial(value: (relationship, nil), failure: error)
            }
        } commit: { [self] partial in
            let (relationship, after) = partial.value
            registerRelationshipRedelete(of: relationship.uid, actionName: actionName)
            if let after {
                registerRelationshipEdit(
                    of: relationship.uid, to: relationship, redoingTo: after,
                    actionName: actionName)
            }
            if let failure = partial.failure { actionError = describe(failure) }
            // Refresh either way: a fault after `addRelationship` succeeded leaves a new
            // (bare, but undoable) relationship the Relationships section must show.
            bumpAndRefresh()
        }
    }

    /// Mints a **brand-new** spouse (from a given/surname pair) *and* relates them to
    /// `subject` as a couple *and* records the couple fact on that relationship — the
    /// inline "create a new person" branch of slice 43c's partner selector. All three
    /// writes register their undo in one run-loop event, so one ⌘Z removes the fact, the
    /// relationship, *and* the new person, one ⌘⇧Z brings all three back. Registration
    /// order (person-create, relationship-create, fact-edit) makes ⌘Z run fact-restore →
    /// relationship-remove → person-remove (LIFO), and redo run person-restore →
    /// relationship-restore → fact-redo — so each record always exists when the one that
    /// references it is (re)written.
    ///
    /// Like `createPersonAndLink`, this deliberately does **not** publish
    /// `lastCreatedPerson`: the user stays on the subject's detail recording the marriage.
    func createPersonRelateAndRecord(
        subject: PersonID, given: String?, surname: String?, fact: PersonFact,
        actionName: String = "Add Relationship Fact"
    ) {
        // All three engine writes in one `work`: one run-loop turn for the three undo
        // registrations, so they stay a single ⌘Z (52). Partial results are carried
        // back rather than thrown, so a fault partway through still leaves what *was*
        // written reversible — see `Partial`.
        mutate(unopened: "Open an archive before recording a marriage.") { archive in
            let person = try archive.addPerson(PersonDraft(given: given, surname: surname))
            do {
                let relationship = try archive.addRelationship(
                    RelationshipDraft(
                        type: .couple, person1Uid: subject, person2Uid: person.uid))
                do {
                    let after = try archive.updateRelationship(relationship.uid) {
                        $0.facts.append(fact)
                    }
                    return Partial(value: (person, Optional(relationship), Optional(after)))
                } catch {
                    return Partial(
                        value: (person, Optional(relationship), nil), failure: error)
                }
            } catch {
                return Partial(value: (person, nil, nil), failure: error)
            }
        } commit: { [self] partial in
            let (person, relationship, after) = partial.value
            registerPersonRedelete(of: person.uid, actionName: actionName)
            if let relationship {
                registerRelationshipRedelete(of: relationship.uid, actionName: actionName)
                if let after {
                    registerRelationshipEdit(
                        of: relationship.uid, to: relationship, redoingTo: after,
                        actionName: actionName)
                }
            }
            if let failure = partial.failure { actionError = describe(failure) }
            // Refresh either way: a fault partway through leaves an undoable person
            // (and possibly relationship) the People / Relationships views must show.
            bumpAndRefresh()
        }
    }
}

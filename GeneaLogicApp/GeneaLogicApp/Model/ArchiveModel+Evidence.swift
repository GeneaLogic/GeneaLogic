import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Evidence links (resolve a mention → person, undoable)

    /// The evidence links whose evidence side is this artifact — i.e. which of the
    /// artifact's person-mentions have been resolved to a concluded person. A read-only
    /// projection over the index; the detail view loads it beside the full record and
    /// reloads it off `mutationVersion`.
    /// Rejection tombstones are excluded by the engine — the Persons Mentioned section
    /// shows citations, and a "no" is not one. `refClaimingLinks(for:)` is the one
    /// caller that needs them.
    func artifactLinks(for id: ArtifactID) -> [EvidenceLink] {
        archive?.links(forArtifact: id) ?? []
    }

    /// Every link claiming a `localRef` on this artifact, **rejections included** — the
    /// input to `PersonMention.nextLocalRef`, and the one place the app must see
    /// tombstones.
    ///
    /// The mint's rule is "never hand out a ref some surviving link still points at,"
    /// and a rejection points at one just as firmly as a confirmation does. Reading the
    /// filtered list here would let a removed mention's ref be reissued to a new person,
    /// silently re-aiming a recorded "this is not Szlama" at whoever now holds `p3`.
    func refClaimingLinks(for id: ArtifactID) -> [EvidenceLink] {
        archive?.links(forArtifact: id, includeRejected: true) ?? []
    }

    /// The evidence links whose conclusion side is this person — i.e. which artifact
    /// mentions cite it (the person "Sources" section, slice 42b). The symmetric
    /// mirror of `artifactLinks(for:)`; the person detail view loads it off
    /// `mutationVersion` so an unlink refreshes the section.
    func personLinks(for id: PersonID) -> [EvidenceLink] {
        archive?.links(for: id) ?? []
    }

    /// The ranked candidates for one mention at the usual floor — the resolve sheet's
    /// in-place suggestions (§6.3's inspector-primary direction).
    ///
    /// Scoped to one artifact rather than reusing the worklist: the sheet can be opened
    /// from the Artifacts section without Review ever having been visited, and asking
    /// about one record is much less work than sweeping the archive to answer it.
    func suggestions(forMention localRef: String, in artifactID: ArtifactID) -> [SuggestedLink] {
        guard let archive else { return [] }
        return archive.suggestLinks(forArtifact: artifactID)
            .first { $0.mention.localRef == localRef }?.candidates ?? []
    }

    /// The candidates for one mention **with no confidence floor** — what the
    /// somebody-new step shows before it will mint a person.
    ///
    /// An empty candidate list at the default floor is *not* evidence that a mention
    /// names somebody new. The matcher's blind spot is precisely the name it cannot
    /// recognize (an americanization, an unlisted variant), so an empty list is where it
    /// is **least** trustworthy — and a UI that read it as "create new" would mint
    /// duplicates exactly there. This is the mitigation: the closest existing people,
    /// with their real scores, shown before the irreversible-ish step.
    ///
    /// **The floor is 1, not 0.** A zero is not a faint resemblance, it is the absence of
    /// one — and every person who resembles the name in no way whatsoever ties at zero, so
    /// a floor of 0 fills this list with whoever the uid tiebreak happens to put first.
    /// Three arbitrary strangers presented as "closest" is exactly the false suggestion
    /// this step exists to avoid; when nothing scores at all, saying so is the honest
    /// answer (see `SomebodyNewSheet`).
    func closestCandidates(to mention: MentionRef, limit: Int = 3) -> [SuggestedLink] {
        guard let archive else { return [] }
        return archive.suggestLinks(
            forArtifact: mention.artifact, minimumConfidence: 1, limit: limit
        )
        .first { $0.mention == mention }?.candidates ?? []
    }

    /// Confirms a suggestion — a human agreeing that this mention names this person.
    ///
    /// Writes **the score the user was shown**, not a recomputation and not `100`: a
    /// confirmation is a verdict on the pair, not a re-scoring of the evidence, so a link
    /// confirmed on a birth year three years out still says so a decade later (45c).
    /// That is why this takes the whole `SuggestedLink` rather than the pair.
    ///
    /// Undoable on `resolveMention`'s pattern — ⌘Z unlinks the new link and restores
    /// anything it displaced.
    func confirmSuggestion(_ suggestion: SuggestedLink) {
        recordReview(suggestion, confirming: true)
    }

    /// Rejects a suggestion — a human saying this mention does **not** name this person.
    ///
    /// The write is a tombstone (`.humanRejected`), which is what makes "no" stick: the
    /// matcher has no other memory, so without it the next sweep would recompute the
    /// identical score and offer the identical pair forever. Scoped to the pair — every
    /// other candidate for the mention stays open, and the mention stays unresolved.
    ///
    /// ⌘Z removes the tombstone, which *is* un-rejecting (a tombstone is an
    /// `EvidenceLink`, so there is no fourth verb — 45c).
    func rejectSuggestion(_ suggestion: SuggestedLink) {
        recordReview(suggestion, confirming: false)
    }

    /// The one write path behind confirm and reject: they differ by which engine verb
    /// runs, and forking the undo registration and the displacement report would mean two
    /// chances to get each wrong (the engine's own `recordReview` makes the same call).
    private func recordReview(_ suggestion: SuggestedLink, confirming: Bool) {
        let actionName = confirming ? "Confirm Suggestion" : "Reject Suggestion"
        mutate(unopened: "Open an archive before reviewing a suggestion.") { archive in
            confirming ? try archive.confirm(suggestion) : try archive.reject(suggestion)
        } commit: { [self] decision in
            // Restore-then-redelete, registered in this order so undo runs LIFO:
            // drop the new link first, then put back whatever it superseded. A verdict
            // on this pair may already have existed (the user rejected it and is now
            // confirming it, or vice versa), and an undo that only removed the new link
            // would silently discard the earlier decision.
            for displaced in decision.superseded {
                registerLinkRestore(displaced, actionName: actionName)
            }
            registerLinkRedelete(of: decision.link.uid, actionName: actionName)
            bumpAndRefresh()
            reportDisplacement(decision)
        } failure: { [self] _ in
            // Refresh on failure too, exactly as `resolveMention` and
            // `createPersonAndLink` do. The engine writes the new link and upserts it into
            // the index *before* superseding the pair's old verdict, and `withState` has no
            // rollback (45d) — so a throw from the supersede step leaves a link durably on
            // disk. Without this, the worklist keeps offering a decision that has already
            // been made and the pane never shows the record that now exists.
            bumpAndRefresh()
            return false
        }
    }

    /// Tells the user when a decision **removed** something — a previous verdict on the
    /// same pair, or a concluded fact's citation that the removal stranded.
    ///
    /// Both are silent on the happy path (`superseded` is empty almost always), and both
    /// are exactly what 45d had to fix in the CLI: a write that quietly cut the evidence
    /// out from under a conclusion is the one removal that didn't say so. Routed through
    /// the benign-info channel rather than the error alert — nothing failed.
    private func reportDisplacement(_ decision: ReviewDecision) {
        guard !decision.superseded.isEmpty || !decision.strandedCitations.isEmpty else { return }
        var lines: [String] = []
        for displaced in decision.superseded {
            lines.append(
                "Replaced an earlier “\(displaced.reviewStatus.rawValue)” verdict on this pair "
                    + "(\(displaced.uid.raw)).")
        }
        for stranded in decision.strandedCitations {
            lines.append("\(stranded.summary): \(stranded.detail)")
        }
        lines.append("⌘Z undoes this and puts back what it replaced.")
        showInfo(lines.joined(separator: "\n\n"), title: "Earlier Decision Replaced")
    }

    /// Resolves the person-mention `localRef` in artifact `artifactID` to an existing
    /// concluded person, creating an `EvidenceLink` (the resolve sheet's Link action).
    /// **Undoable**: ⌘Z unlinks it, ⌘⇧Z re-creates it — the create↔delete ping-pong
    /// (a link is re-created on redo, not snapshot-restored).
    ///
    /// `replacing` is the **repair** path (slice 44g): when the mention's existing link
    /// points at a person that no longer exists, that stale link is removed first and
    /// the new one takes its place. Both writes land in one run-loop event, so the
    /// window's `UndoManager` groups them — one ⌘Z drops the new link *and* brings the
    /// dangling one back, leaving the archive exactly as it was.
    func resolveMention(
        _ localRef: String, in artifactID: ArtifactID, to personID: PersonID,
        replacing stale: EvidenceLinkID? = nil
    ) {
        let actionName = stale == nil ? "Resolve Mention" : "Re-resolve Mention"
        mutate(unopened: "Open an archive before resolving a mention.") { archive in
            // Removed first, so its undo registers first and undo runs
            // unlink-new-then-restore-stale (LIFO) — the ref is never claimed twice.
            let removed = try stale.map { try archive.unlink($0) }
            do {
                let decision = try archive.link(
                    MentionRef(artifact: artifactID, localRef: localRef), to: personID)
                return Partial(value: (removed, Optional(decision)))
            } catch {
                return Partial(value: (removed, nil), failure: error)
            }
        } commit: { [self] partial in
            let (removed, decision) = partial.value
            if let removed { registerLinkRestore(removed, actionName: actionName) }
            if let decision {
                // A tombstone for this pair is displaced by the resolve, so undo has to
                // put it back — otherwise ⌘Z would leave the pair *un*-rejected, quietly
                // discarding a decision the user made earlier and never took back.
                for displaced in decision.superseded {
                    registerLinkRestore(displaced, actionName: actionName)
                }
                registerLinkRedelete(of: decision.link.uid, actionName: actionName)
            }
            if let failure = partial.failure { actionError = describe(failure) }
            // The stale link may already be gone — show the partial result rather than
            // leaving the section rendering a link that no longer exists.
            bumpAndRefresh()
        }
    }

    /// Removes an evidence link (the resolved-mention chip's Unlink). Undoable: ⌘Z
    /// restores the exact link (uid-faithful), ⌘⇧Z unlinks again. Leaves the mention
    /// itself and any `supportedByLinks` entry that named the link dangling (§2.3) —
    /// that's `verifyIntegrity`'s job, not a cascade.
    func unlinkMention(_ id: EvidenceLinkID, actionName: String = "Unlink Mention") {
        mutate(unopened: "Open an archive before unlinking.") { archive in
            try archive.unlink(id)
        } commit: { [self] removed in
            registerLinkRestore(removed, actionName: actionName)
            bumpAndRefresh()
        }
    }

    /// Creates a new concluded person seeded from a mention's recorded name **and**
    /// links the mention to it, in one step (the resolve sheet's "create new … and
    /// link"). Both mutations register their undo in the same run-loop event, so the
    /// window's `UndoManager` groups them: one ⌘Z removes the link *and* the person,
    /// one ⌘⇧Z brings both back. Registration order (person, then link) makes undo run
    /// unlink-then-remove-person (LIFO) and redo run restore-person-then-restore-link,
    /// so the person always exists when its link is (re)written.
    ///
    /// Deliberately does **not** publish `lastCreatedPerson`: the user stays on the
    /// Artifacts tab looking at the evidence; jumping to the new person is the separate,
    /// explicit chip tap.
    ///
    /// `replacing` is the repair path, exactly as in `resolveMention`: a stale link is
    /// removed first and joins the same undo group.
    func createPersonAndLink(
        from mention: PersonMention, in artifactID: ArtifactID,
        replacing stale: EvidenceLinkID? = nil
    ) {
        let actionName = stale == nil ? "New Person from Mention" : "Re-resolve Mention"
        mutate(unopened: "Open an archive before resolving a mention.") { archive in
            let removed = try stale.map { try archive.unlink($0) }
            let (given, surname) = Self.splitRecordedName(mention.nameAsRecorded)
            // Preserve the exact recorded string in `full` (so the display name is
            // faithful at once) plus a best-effort given/surname split the user can
            // correct in the person editor.
            let name = PersonName(
                type: .birth, given: given, surname: surname, full: mention.nameAsRecorded)
            let person = try archive.addPerson(PersonDraft(names: [name]))
            // Caught, not thrown: the two writes share no transaction, so if `link`
            // fails the person still exists and `commit` must still make it reversible
            // (⌘Z removes the orphan) rather than stranding an un-undoable record.
            do {
                let link = try archive.link(
                    MentionRef(artifact: artifactID, localRef: mention.localRef),
                    to: person.uid
                ).link
                return Partial(value: (removed, person, Optional(link)))
            } catch {
                return Partial(value: (removed, person, nil), failure: error)
            }
        } commit: { [self] partial in
            let (removed, person, link) = partial.value
            if let removed { registerLinkRestore(removed, actionName: actionName) }
            // The person's undo registers *before* the link's, so undo runs
            // unlink-then-remove-person (LIFO) and redo the reverse — the person always
            // exists when its link is (re)written. Both land in one run-loop turn, so a
            // successful pair still groups into a single ⌘Z.
            registerPersonRedelete(of: person.uid, actionName: actionName)
            // No `superseded` to restore here, unlike `resolveMention`: the person was
            // minted a moment ago, so no earlier verdict on this pair can exist.
            if let link { registerLinkRedelete(of: link.uid, actionName: actionName) }
            if let failure = partial.failure { actionError = describe(failure) }
            bumpAndRefresh()
            // *Somebody new* is the most likely way to mint a duplicate — the user did not
            // recognize a person the archive already holds — so the lane re-scans here.
            refreshDuplicateCandidatesIfShown()
        } failure: { [self] _ in
            refreshDuplicateCandidatesIfShown()
            return false
        }
    }

    /// Naively splits a recorded name into `(given, surname)` to seed a new person: the
    /// last whitespace-separated token is the surname, the rest the given name(s); a
    /// single token becomes the given name. A *seed* for a manual conclusion, not an
    /// authoritative parse — the recorded string is kept verbatim in the name's `full`,
    /// and the user corrects given/surname in the person editor.
    /// `nonisolated` because `createPersonAndLink` seeds the new person's name
    /// inside its work closure, off the main actor (52). Pure string handling —
    /// it touches no model state.
    private nonisolated static func splitRecordedName(
        _ recorded: String
    ) -> (given: String?, surname: String?) {
        let parts = recorded.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        switch parts.count {
        case 0: return (nil, nil)
        case 1: return (parts[0], nil)
        default: return (parts.dropLast().joined(separator: " "), parts.last)
        }
    }

    /// Undo side of *creating* a link (`resolveMention` / `createPersonAndLink`):
    /// unlink it on ⌘Z (capturing the removed record), then re-register the restore for
    /// ⌘⇧Z. Parallels `registerPersonRedelete`. A link already gone (removed
    /// out-of-band) no-ops gracefully with a benign notice, and the stack advances.
    private func registerLinkRedelete(of id: EvidenceLinkID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            let removed = PendingLink()
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerLinkRestore(pending: removed, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.unlink(id)
            } commit: { link in
                removed.link = link
                model.bumpAndRefresh()
            } failure: { error in
                guard case ArchiveError.evidenceLinkNotFound = error else { return false }
                model.showInfo(
                    "That link is no longer in the archive.", title: "Already Removed")
                return true
            }
        }
    }

    /// The removed `EvidenceLink` an unlink hands to the restore that reverses it.
    private final class PendingLink {
        var link: EvidenceLink?
    }

    /// Undo side of *removing* a link (`unlinkMention`): restore the exact link on ⌘Z,
    /// then re-register the redelete for ⌘⇧Z — the same restore↔redelete ping-pong as
    /// `registerPersonRestore`. The removed `EvidenceLink` is captured in the closure,
    /// so there's no trash entry to go missing (in-session only).
    func registerLinkRestore(_ link: EvidenceLink, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.restoreLink(link, actionName: actionName)
        }
    }

    /// The promised-payload variant. See `PendingFileChange`.
    private func registerLinkRestore(pending: PendingLink, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            guard let link = pending.link else { return }
            model.restoreLink(link, actionName: actionName)
        }
    }

    /// Restores `link` and registers the unlink that reverses it.
    private func restoreLink(_ link: EvidenceLink, actionName: String) {
        // Counterpart first — see *Undo across the actor hop* above.
        registerLinkRedelete(of: link.uid, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.restoreLink(link)
        } commit: { [self] _ in
            bumpAndRefresh()
        }
    }
}

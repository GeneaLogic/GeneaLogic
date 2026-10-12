import Foundation
import GeneaLogicMatch
import GeneaLogicModel

/// Declining a suggestion, and remembering it (slice 45m) — spec §6.6.
///
/// **The one thing in the matcher mini-phase that a suggestion sweep must subtract.**
/// Everything else here is computed and thrown away: `suggestLinks`, `duplicateCandidates`
/// and 45l's suggested relationships all re-derive their answers from the records as they
/// are now, which is what keeps them from going stale. A *no* has nowhere in that scheme
/// to live — there is no mention to tombstone (45c) — so without a record the same pair is
/// re-offered at every launch, in the one section whose meaning depends on reaching empty.
///
/// ## The verbs
///
/// `dismiss` and `undismiss`, and there is no third. A dismissal is itself the negative
/// record, so retracting one is *deleting* it — precisely what `unlink` is to a rejection
/// tombstone — and the pair returns to the queue with nothing left behind. A status field
/// would mean a tombstone over a tombstone, and every read applying the skip rule would
/// have to learn to filter it.
///
/// ## Scoped to the subject
///
/// A pair of persons can be proposed two different ways — 45j says *these are one person*,
/// 45l says *this one is that one's parent* — so a dismissal names which claim was
/// declined and forecloses only that one. Symmetry follows the subject
/// (`DismissalSubject.isSymmetric`): the pair is canonicalized on write when it is
/// symmetric, and left exactly as given when it is directional, where reversing the
/// endpoints states the opposite thing.
extension Archive {

    // MARK: - Reads

    /// Every dismissal in the archive, in `uid` order (a UUIDv7, so creation order).
    public func dismissals() -> [Dismissal] {
        withIndex { index in
            ((try? index.allDismissals()) ?? []).sorted { $0.uid.raw < $1.uid.raw }
        }
    }

    /// Every dismissal naming `person` at either endpoint.
    public func dismissals(involving person: PersonID) -> [Dismissal] {
        dismissals().filter { $0.involves(person) }
    }

    /// Whether a human has already declined this exact claim.
    ///
    /// Answered through ``Dismissal/declines(_:between:and:)`` rather than by comparing
    /// fields here, so the symmetric/directional rule is applied in one place.
    public func isDismissed(
        _ subject: DismissalSubject, between person1: PersonID, and person2: PersonID
    ) -> Bool {
        dismissals().contains { $0.declines(subject, between: person1, and: person2) }
    }

    // MARK: - dismiss

    /// Records that a human declined a suggestion over two concluded persons.
    ///
    /// Storing the breakdown is 45c's reasoning unchanged: declining a *strong* candidate
    /// is where the matcher is wrong in a way worth understanding, and a record without the
    /// score cannot tell that from declining a weak one. `match` is optional because not
    /// every declinable suggestion is scored — 45l's are read off a stated mention edge and
    /// two confirmed links, and inventing a number for them would be a lie.
    ///
    /// **Idempotent.** Declining a pair already declined returns the existing record
    /// untouched rather than minting a second one: two records for one judgement would
    /// leave `undismiss` half-effective, and re-declining is the ordinary consequence of
    /// two windows on one archive.
    ///
    /// - Throws: `ArchiveError.personNotFound` if either person is missing;
    ///   `ArchiveError.cannotDismissPersonAgainstItself` if they are the same person —
    ///   every subject in the vocabulary is a claim *between* two people, and a pair that
    ///   is one person is not a claim any lane can produce.
    @discardableResult
    public func dismiss(
        _ subject: DismissalSubject,
        between person1: PersonID,
        and person2: PersonID,
        match: MatchBreakdown? = nil,
        aggregateConfidence: Int? = nil,
        dismissedBy: Reviewer = .unspecified
    ) throws -> Dismissal {
        try withState { _, index in
            guard person1 != person2 else {
                throw ArchiveError.cannotDismissPersonAgainstItself(person1)
            }
            guard try index.person(person1) != nil else {
                throw ArchiveError.personNotFound(person1)
            }
            guard try index.person(person2) != nil else {
                throw ArchiveError.personNotFound(person2)
            }

            if let existing = try index.allDismissals()
                .sorted(by: { $0.uid.raw < $1.uid.raw })
                .first(where: { $0.declines(subject, between: person1, and: person2) })
            {
                return existing
            }

            let (first, second) = Dismissal.canonicalPair(person1, person2, subject: subject)
            let now = ISO8601DateFormatter().string(from: Date())
            let dismissal = Dismissal(
                uid: IdentifierMinter.dismissal(),
                subject: subject,
                person1Uid: first,
                person2Uid: second,
                match: match,
                // Kept in lockstep with `match`: an aggregate with no breakdown behind it
                // is the opaque percentage §4.6 exists to refuse.
                aggregateConfidence: match == nil ? nil : aggregateConfidence,
                dismissedBy: dismissedBy.resolvedName,
                dismissedAt: now,
                // **A human act by definition** — GeneaLogic never writes a dismissal from
                // a machine, so unlike a confirmed suggestion (which is machine-proposed,
                // human-decided) there is no mixed provenance to record here.
                provenance: Provenance(
                    createdBy: .human, createdAt: now, reviewStatus: .humanVerified))

            try write(.dismissal(dismissal), index: index)
            return dismissal
        }
    }

    /// Records that a human declined a duplicate candidate, storing the reasoning they
    /// were shown.
    @discardableResult
    public func dismiss(
        _ candidate: DuplicateCandidate, dismissedBy: Reviewer = .unspecified
    ) throws -> Dismissal {
        try dismiss(
            .samePerson, between: candidate.person1, and: candidate.person2,
            match: candidate.match.breakdown,
            aggregateConfidence: candidate.match.aggregateConfidence,
            dismissedBy: dismissedBy)
    }

    // MARK: - undismiss

    /// Retracts a dismissal, returning the pair to the queue.
    ///
    /// Deletion *is* the retraction — see this file's header. Returns the removed records
    /// (normally one) so a caller can put them back with ``restoreDismissal(_:)``; empty
    /// when the claim was never declined, which is not an error but the state the caller
    /// asked for.
    @discardableResult
    public func undismiss(
        _ subject: DismissalSubject, between person1: PersonID, and person2: PersonID
    ) throws -> [Dismissal] {
        try withState { _, index in
            let matching = try index.allDismissals()
                .filter { $0.declines(subject, between: person1, and: person2) }
                .sorted { $0.uid.raw < $1.uid.raw }
            // Normally one, but not always — so all or nothing (slice 68, fork b).
            try applyCascade(
                writing: [], removing: matching.map { .dismissal($0.uid) }, index: index)
            return matching
        }
    }

    /// Removes one dismissal by uid, returning it for the undo path.
    ///
    /// - Throws: `ArchiveError.dismissalNotFound` if `id` doesn't exist.
    @discardableResult
    public func removeDismissal(_ id: DismissalID) throws -> Dismissal {
        try withState { _, index in
            guard let dismissal = try index.dismissal(id) else {
                throw ArchiveError.dismissalNotFound(id)
            }
            try remove(.dismissal(id), index: index)
            return dismissal
        }
    }

    /// Re-writes a removed dismissal back to its sidecar (uid faithful) and re-inserts it
    /// into the index — the in-session undo path, matching `restorePerson`/`restoreLink`.
    public func restoreDismissal(_ dismissal: Dismissal) throws {
        try withState { _, index in
            try write(.dismissal(dismissal), index: index)
        }
    }
}

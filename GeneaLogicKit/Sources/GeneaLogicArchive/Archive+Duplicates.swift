import Foundation
import GeneaLogicModel
public import GeneaLogicMatch

/// Duplicate detection — pointing slice 45j's person↔person scorer at a real archive
/// (ARCHITECTURE.md §4.1, §4.6).
///
/// **Entity duplication is left to this layer by design** (§4.1): `uid`s are minted, not
/// derived, so two records for one human being are an expected state rather than
/// corruption. `mergePersons` (45f) is how they become one; this is how they are *found*,
/// which until now was eyeballing the People list.
///
/// **Candidates are ephemeral**, exactly as suggested links are (see
/// `Archive+Matching.swift`'s header). Nothing here writes, and the act this feeds —
/// a merge — stores no breakdown, so there is no record to go stale. What a *declined*
/// pair needs is a record, and slice 45m is where it landed: a `Dismissal` with subject
/// `same-person` (spec §6.6), which this pass subtracts.
///
/// ## One skip rule, and one that looks compelling but isn't
///
/// The link direction skips resolved mentions and rejected pairs; this direction skips
/// only what a human has explicitly declined. In particular **two persons
/// confirmed on *different* mentions of the same record are still offered as a pair.**
/// It reads like proof they are distinct — a census naming John Smith Sr. and John Smith
/// Jr. names two people — but the inference only holds if the human who made those two
/// links had already noticed they were two people. A user who resolved a mention onto a
/// duplicate without realizing produces the identical shape on disk, and that user is
/// precisely who this surface exists for. A skip rule here would blind the detector in
/// the one case it was built to catch.
///
/// ## Cost
///
/// One pass over `persons()` × `persons()`, every pair scored. Since 45m the scan itself
/// runs **off** the lock (`duplicateScanInput()` snapshots under it; the scoring is pure),
/// and a UI runs it off the main actor with a progress affordance.
///
/// It is still `n(n−1)/2` comparisons. Measured in release, after 45p: **~15µs per pair**,
/// so 100 persons ≈ 0.07s, 500 ≈ 1.8s, 1,000 ≈ 7s, 5,000 ≈ 3min. Comfortable for the
/// archives this phase targets, and quadratic all the same.
///
/// ### Why 45p memoized instead of blocking
///
/// The specced fix was a candidate pre-filter. **It cannot be built soundly for *this*
/// scorer**, for two independent reasons, and both are load-bearing rather than
/// conservative:
///
/// 1. A key gate makes the name dimension's `.within` band unreachable — `Fay`/`Faye` stand in for
///    one woman written both ways in the real archive, and key *apart*. `Archive+Matching`'s
///    `suggestions` already rejected blocking on exactly this ground.
/// 2. Worse here: ``defaultMinimumDuplicateConfidence`` is *calibrated* on a pair whose
///    names agree on **nothing** and which is corroborated three ways — the
///    `Zelig`/`Sidney` case. A name-keyed gate drops precisely the pair the floor was
///    chosen to admit, and the failure mode is an invisible false negative in the surface
///    whose entire job is to not miss a duplicate.
///
/// So 45p took the cost out of the *comparison* rather than out of the candidate set:
/// Daitch–Mokotoff keying, which measured ~60µs of the ~92µs pair, is a pure function of a
/// string and is now memoized in `DaitchMokotoff` — `O(distinct name tokens)` instead of
/// `O(pairs)`. That is a **6× measured** improvement which, being the same function on the
/// same input, provably changes no result. 45b's standing condition for blocking ("if it
/// is a superset it changes no results") is satisfied trivially by not filtering at all.
///
/// What remains per pair is Jaro–Winkler over token pairs, which is inherently pairwise
/// and is the floor for any approach that does not filter. Going below it needs a gate
/// that bounds *string similarity* rather than phonetic equality — an ngram index, a real
/// slice, and still owing the superset proof neither 45b nor this note could supply.
extension Archive {

    /// Finds pairs of concluded persons that may be one person.
    ///
    /// - Parameters:
    ///   - minimumConfidence: Pairs scoring below this are dropped. See
    ///     ``defaultMinimumDuplicateConfidence`` for what the default admits, which is
    ///     a different question from the link floor's.
    ///   - limit: At most this many pairs, taking the highest-scoring; `nil` for all.
    /// - Returns: Pairs ranked by `aggregateConfidence`, highest first. Each unordered
    ///   pair appears **once**, nobody is compared with themselves, and a pair a human
    ///   has dismissed as *not a duplicate* (45m) is not offered at all.
    public func duplicateCandidates(
        minimumConfidence: Int = Archive.defaultMinimumDuplicateConfidence,
        limit: Int? = nil
    ) -> [DuplicateCandidate] {
        Self.duplicateCandidates(
            in: duplicateScanInput(), minimumConfidence: minimumConfidence, limit: limit)
    }

    /// Everything the pairwise pass needs, read in **one linear pass under the lock** so
    /// the quadratic comparison can run without holding it.
    ///
    /// **The split is what makes an off-main scan actually off-main.** `withIndex` takes
    /// `Archive`'s single `NSLock`, so a sweep that scored inside it held that lock for
    /// `n(n−1)/2` comparisons — and every other archive read, on any thread, waited behind
    /// it. Moving the *call* to a background thread without moving the *lock* would have
    /// relocated the freeze rather than removed it (found by 45m's `/code-review`). Only
    /// the reads need serializing; `DuplicateMatcher.score` touches nothing shared.
    ///
    /// The snapshot is a value, so a caller may hold it across a suspension point and
    /// score at leisure. It is a snapshot in the ordinary sense: a concurrent write is not
    /// reflected, and the answer is re-derived by taking a fresh one.
    public func duplicateScanInput() -> DuplicateScanInput {
        withIndex { index in
            // `forScoring`, not `forSuggestion`: the *links* table drives the link
            // direction's skip rules, and none of them mean anything here. A confirmed
            // link neither resolves a person nor forecloses a pair, so reading the links
            // would be dead weight — and the one skip rule that looks compelling is the
            // one the header explains must not exist. The skip that does apply comes from
            // the dismissals, read below.
            let corpus = (try? MatchCorpus.forScoring(index: index)) ?? MatchCorpus.empty

            // A human's recorded "not a duplicate" (§6.6), as a set of canonical pairs —
            // read **once** for the whole quadratic pass, since a linear scan per pair
            // would make the sweep cubic in the thing 45p already has to speed up.
            // Canonicalized through `Dismissal`'s own rule rather than by sorting here,
            // so the symmetric-pair question keeps one owner.
            let dismissed = Set(
                ((try? index.allDismissals()) ?? [])
                    .filter { $0.subject == .samePerson }
                    .map {
                        PairKey(
                            Dismissal.canonicalPair(
                                $0.person1Uid, $0.person2Uid, subject: .samePerson))
                    })

            // Sorted by uid, which makes `i < j` mean "canonical order" for free: each
            // unordered pair is visited once, always with the lower uid first. That is
            // what lets the conflict sentences say "the first"/"the second" and mean it,
            // and what keeps the greedy name pairing (see `NameMatching.score(_:against:)`)
            // from depending on which person the loop happened to reach first.
            let views = corpus.persons
                .sorted { $0.uid.raw < $1.uid.raw }
                .map { corpus.personView(of: $0) }

            return DuplicateScanInput(views: views, places: corpus.places, dismissed: dismissed)
        }
    }

    /// Scores a snapshot. **Pure** — no archive, no lock, no I/O — which is what lets a
    /// caller run it off the main actor (or on several, later, when 45p adds blocking).
    public static func duplicateCandidates(
        in input: DuplicateScanInput,
        minimumConfidence: Int = Archive.defaultMinimumDuplicateConfidence,
        limit: Int? = nil
    ) -> [DuplicateCandidate] {
        var found: [DuplicateCandidate] = []
        for (offset, first) in input.views.enumerated() {
            for second in input.views[input.views.index(after: offset)...] {
                // The views are uid-sorted, so `(first, second)` is already the canonical
                // order a symmetric dismissal is stored in.
                guard !input.dismissed.contains(PairKey((first.personID, second.personID)))
                else { continue }
                let score = DuplicateMatcher.score(
                    first, against: second, places: input.places)
                guard score.aggregateConfidence >= minimumConfidence else { continue }
                found.append(
                    DuplicateCandidate(
                        person1: first.personID, person2: second.personID, match: score))
            }
        }
        return Self.ranked(found, limit: limit)
    }

    /// The confidence a duplicate candidate must reach to be worth showing.
    ///
    /// Numerically the same as ``defaultMinimumConfidence`` and arrived at from a
    /// different direction, since the roll-up beneath it is a different one (no source
    /// discount, a harsher corroboration factor). **The anchor is the matcher's blind
    /// spot:** two persons whose names disagree *entirely* but whose birth year, birth
    /// place and partners all agree land at exactly 50 — admitted, at the bottom of the
    /// queue. That is the `Zelig`/`Sidney` case the name matcher cannot see at all
    /// (one man's Yiddish name and the American one he took), and a pair corroborated
    /// three ways is the one kind of zero-name result worth keeping.
    ///
    /// What it excludes: a weak-phonetic-only pair (45), a name agreement propped up by
    /// one or two incidental facts, and — via the conflict penalty rather than the floor
    /// — an exact-name pair whose birth years disagree (21), which is the grandson named
    /// for his grandfather.
    ///
    /// A **default, not a policy**: the entry point takes it as a parameter and
    /// `genea person duplicates --min-confidence` exists to tune it against a real
    /// archive.
    public static let defaultMinimumDuplicateConfidence = 50

    /// Ranked by confidence, then broken deterministically by uid — a queue that
    /// reordered itself between runs would be a bug, and a test could not pin it.
    ///
    /// `limit` is clamped rather than asserted, for the reason `Archive+Matching`'s
    /// `ranked` documents: a negative one tripped an `Array` precondition, which fires
    /// in release, taking the process down to answer a read-only query.
    private static func ranked(
        _ candidates: [DuplicateCandidate], limit: Int?
    ) -> [DuplicateCandidate] {
        let sorted = candidates.sorted { a, b in
            if a.match.aggregateConfidence != b.match.aggregateConfidence {
                return a.match.aggregateConfidence > b.match.aggregateConfidence
            }
            if a.person1.raw != b.person1.raw { return a.person1.raw < b.person1.raw }
            return a.person2.raw < b.person2.raw
        }
        if let limit { return Array(sorted.prefix(max(0, limit))) }
        return sorted
    }
}

// MARK: - DuplicateScanInput

/// A lock-free snapshot of the corpus the duplicate pass compares — see
/// ``Archive/duplicateScanInput()`` for why it exists.
///
/// Opaque by design: its contents are the scorer's business, and a caller's only use for
/// it is to carry it from ``Archive/duplicateScanInput()`` to
/// ``Archive/duplicateCandidates(in:minimumConfidence:limit:)`` — possibly across a
/// suspension point, which is the whole point.
public struct DuplicateScanInput: Sendable {
    /// Uid-sorted, so `i < j` is canonical pair order for free.
    let views: [PersonMatchView]
    let places: PlaceVocabulary
    let dismissed: Set<PairKey>

    /// How many persons the pass will compare — the only thing about a snapshot worth
    /// showing a user (a progress affordance has to say what it is waiting on).
    public var personCount: Int { views.count }
}

// MARK: - PairKey

/// Two person ids as one hashable value, for set membership. Carries **no** ordering
/// rule of its own: callers hand it a pair already in the order the subject stores, which
/// is why it is not `Comparable` and does not sort.
struct PairKey: Hashable, Sendable {
    var first: String
    var second: String

    init(_ pair: (PersonID, PersonID)) {
        self.first = pair.0.raw
        self.second = pair.1.raw
    }
}

// MARK: - DuplicateCandidate

/// Two concluded persons that may be one, and the matcher's reasoning for thinking so.
///
/// **Not a record** — no uid, no provenance, no sidecar — for the same reason
/// `SuggestedLink` isn't one: there is nothing to persist, so there is no code path that
/// could accidentally persist it.
///
/// Deliberately narrow, again like `SuggestedLink`: the two ids and the score, no display
/// fields. Names would go stale the moment either person was edited, and a caller that
/// needs them has index-backed lookups.
public struct DuplicateCandidate: Sendable, Equatable {
    /// The lower of the two `uid`s. The pair is unordered — this is canonical order, not
    /// a claim about which record is the original or which should survive a merge.
    public var person1: PersonID

    /// The higher of the two `uid`s.
    public var person2: PersonID

    /// **The reasoning, which is the point** (§4.6). The breakdown inside is what a
    /// reviewer reads before merging; `aggregateConfidence` only orders the queue.
    public var match: DuplicateScore

    public init(person1: PersonID, person2: PersonID, match: DuplicateScore) {
        self.person1 = person1
        self.person2 = person2
        self.match = match
    }
}

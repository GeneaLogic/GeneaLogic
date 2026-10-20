import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

extension ArchiveModel {
    // MARK: - Noticing another writer (slice 51)

    /// How often `refreshIfChangedExternally()` is polled by the archive window.
    ///
    /// A second is short enough that an agent's writes appear while you are
    /// still looking at the window, and the check itself is one `PRAGMA` read on
    /// an already-open connection — cheap enough that tuning it further would be
    /// measuring noise.
    static let externalChangePollInterval: Duration = .seconds(1)

    /// The ceiling the adaptive backoff below will not exceed, so a big archive
    /// under sustained external writes still updates on a human timescale.
    static let maxExternalChangePollInterval: Duration = .seconds(15)

    /// Reloads the browse lists **only if another process has committed** since
    /// the last check (slice 51). Driven by the archive window's poll loop.
    ///
    /// Cheap by design: the common case is one `PRAGMA data_version` read and an
    /// integer compare, with no engine query and no view invalidation. Our own
    /// mutations provably don't move the token, so this never fires on them —
    /// which matters, because firing on our own writes would rebuild the lists
    /// twice per edit.
    ///
    /// **Selection needs no special handling here** and deliberately gets none:
    /// selection lives in the window's `@SceneStorage` as a raw id, and the
    /// detail pane resolves it against `artifacts` at render time — so a
    /// surviving selection is kept and an externally-deleted one falls back to
    /// the placeholder, both for free. That is the same path a selection deleted
    /// between sessions already took.
    func refreshIfChangedExternally() {
        nextExternalChangePollDelay = Self.externalChangePollInterval
        guard let archive else { return }
        // Second, and off the main actor — see `reconcileIfStaleExternally`.
        defer { reconcileIfStaleExternally() }
        // **While a delivery is in flight the sweep rides the poll** (slice 61,
        // fork f), rather than only `refresh()`. Nothing commits during a
        // delivery, so the token below never moves and a reconcile that is
        // backing off rebuilds nothing — which left the sweep's view of the
        // archive a poll or more stale for exactly as long as the one state
        // where it is being watched. It is off the main actor and the state is
        // transient; the cost is one `stat` per manifest entry per second, on an
        // archive that is by definition busy receiving one.
        if deliveryInFlightSince != nil || fileSweepCoalesced { reloadFileDamage() }
        guard let token = archive.externalChangeToken() else { return }
        defer { lastExternalChangeToken = token }
        // No baseline yet (the token was unreadable at load) — adopt this one
        // rather than refreshing on a comparison we can't make.
        guard let last = lastExternalChangeToken, token != last else { return }

        let started = ContinuousClock.now
        applyExternalChange()
        let cost = ContinuousClock.now - started
        nextExternalChangePollDelay = min(
            max(Self.externalChangePollInterval, cost * 9), Self.maxExternalChangePollInterval)
    }

    /// Picks up a change that reached the *files* without any process committing
    /// it through this engine (slice 60).
    ///
    /// **`externalChangeToken()` structurally cannot see this case.** That token
    /// is `PRAGMA data_version`, which moves when another process commits — an
    /// agent driving `genea`, which is slice 51's whole subject. A `record.json`
    /// delivered by cloud sync from another machine, restored from a backup, or
    /// merged in by `git` commits nothing, so the token never moves and the poll
    /// above never fires. The engine compares what the index was built from
    /// against what `manifest.json` now says, and rebuilds if they disagree.
    ///
    /// **Off the main actor, and that is not optional.** The cheap path is one
    /// `stat` and an integer compare, but the expensive path is a full index
    /// rebuild — a mutation, and on a large archive a slow one. Running it inline
    /// would put back exactly the freeze slice 52 took out, on a cadence another
    /// machine controls.
    ///
    /// **The token baseline is re-read after a rebuild**, not before: the rebuild
    /// commits through our own connection, so it does not move `data_version`
    /// itself, but another process may have committed while we walked and that
    /// change is now already in what we rebuilt. Adopting the current token stops
    /// the next poll refreshing a second time for something we have.
    private func reconcileIfStaleExternally() {
        guard let archive, reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            let outcome = await Self.reconcileIfStale(archive)
            guard let self else { return }
            self.reconcileTask = nil
            // **The window may have loaded a different archive while we walked**
            // (second `/code-review`). A rebuild takes as long as it takes, and
            // `load()` can land in the middle of it; adopting the old handle's
            // token as this window's baseline would install a number from an
            // archive we are no longer showing, and the next genuine external
            // change to the *current* one could compare equal and be missed.
            //
            // The same guard covers the in-flight state below, for the same
            // reason: it would otherwise describe the archive this window has
            // just stopped showing.
            guard self.archive === archive else { return }
            // Every tick, not only the ones that rebuilt — this is the half of
            // slice 61 that keeps the indicator from inheriting the staleness it
            // exists to remove.
            self.updateIncomingChange(inFlight: outcome.deliveryInFlight)
            guard outcome.rebuilt else { return }
            self.lastExternalChangeToken = archive.externalChangeToken()
            self.applyExternalChange()
        }
    }

    /// `nonisolated` + `async` so the work leaves the main actor, the same shape
    /// `sweepFiles` uses. Deliberately **not** cancellation-checked: unlike a
    /// sweep, this can be halfway through writing an index, and abandoning it is
    /// not cheaper than finishing it.
    ///
    /// **Both halves are read here, off the main actor, and that is why they
    /// travel together** (slice 61). `deliveryIsInFlight` is one `stat` when the
    /// manifest is the settled one, but a manifest read and digest when it is
    /// not — which is precisely the state the indicator is up in, so reading it
    /// on the main actor once a second would put a manifest parse back where 52
    /// took the freezes out. The reconcile has just computed the same fact
    /// anyway.
    private nonisolated static func reconcileIfStale(
        _ archive: Archive
    ) async -> (rebuilt: Bool, deliveryInFlight: Bool) {
        let rebuilt = (try? archive.reconcileIfStale()) ?? false
        return (rebuilt, archive.deliveryIsInFlight)
    }

    // MARK: - A change on its way in (slice 61)

    /// Folds the engine's in-flight fact into what the window says, once per
    /// poll.
    ///
    /// **The boundary is adoption, not arrival.** `deliveryIsInFlight` stays true
    /// until the index has actually taken the change in, which is a reconcile
    /// back-off *after* the last file lands. Clearing on the files instead would
    /// take the bar away while the list still showed the old record — announcing
    /// a change and then withdrawing the announcement before it appeared.
    func updateIncomingChange(inFlight: Bool, now: ContinuousClock.Instant = .now) {
        guard inFlight else {
            deliveryInFlightSince = nil
            deliveryLastProgressAt = nil
            outstandingArrivals = []
            incomingChange = nil
            return
        }
        let since = deliveryInFlightSince ?? now
        deliveryInFlightSince = since
        let lastProgress = deliveryLastProgressAt ?? since
        deliveryLastProgressAt = lastProgress

        guard now - since >= incomingChangeDelay else {
            incomingChange = nil
            return
        }
        incomingChange = now - lastProgress >= incomingChangeStallThreshold ? .stalled : .receiving
    }

    /// Records that the set of files still to arrive has moved, which is what
    /// keeps a long-but-healthy delivery from escalating.
    ///
    /// **Deliberately reads the sweep rather than the engine's own back-off.**
    /// 60 keys its back-off on the manifest's stamp, so a delivery that replaces
    /// its manifest reads as progress there; a multi-file delivery landing one
    /// file at a time under *one* manifest does not, and that is the case this
    /// threshold most needs to get right.
    func noteArrivalProgress(in report: Archive.FileSweepReport) {
        let outstanding = Set(
            report.issues.compactMap { issue -> String? in
                guard case .awaitingDelivery(let path) = issue else { return nil }
                return path
            })
        guard outstanding != outstandingArrivals else { return }
        outstandingArrivals = outstanding
        deliveryLastProgressAt = .now
    }

    /// Applies another process's committed change to everything this window is
    /// showing.
    ///
    /// **Must be as complete as a local mutation's follow-up, and originally
    /// wasn't** (review finding, 51). It goes through `bumpAndRefresh()` rather
    /// than `refresh()` because the browse lists are only half the picture: the
    /// artifact and person detail panes and the Tree tab all reload off
    /// `mutationVersion`, not off `artifacts`/`persons`. Calling plain `refresh()`
    /// left an externally-edited *selected* record stale indefinitely, and an
    /// externally asserted relationship never redrew the tree at all.
    ///
    /// The duplicates lane needs its own invalidation for the same reason a local
    /// merge or delete does: an external `genea person remove` makes a person
    /// cease to exist, and a row still naming them **offers an operation that
    /// cannot succeed** (`personNotFound`) rather than merely showing stale text.
    /// Local paths can `dropDuplicateRows(naming:)` because they know who went;
    /// here we don't, so it re-scans — which that method's own doc argues is the
    /// more correct answer anyway. It self-limits to lanes actually on screen.
    private func applyExternalChange() {
        bumpAndRefresh()
        refreshDuplicateCandidatesIfShown()
    }
}

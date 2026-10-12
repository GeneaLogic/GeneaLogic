import Foundation
import GeneaLogicArchive
import GeneaLogicExtract
import GeneaLogicModel

/// Per-window state for one open archive.
///
/// Each archive window owns its own `ArchiveModel`, built from that window's
/// `URL` value — there is no longer a single app-wide model (the multi-archive
/// window model, ARCHITECTURE.md §7). Opening/creating an archive happens at the
/// scene level (the welcome screen or the File menu) and *then* opens a window
/// for the resulting URL, so this model only ever loads an already-chosen
/// archive and adds media to it.
///
/// `Archive` is a non-Sendable class pinned to the main actor; the app target's
/// default actor isolation is already `MainActor`, made explicit here for clarity.
@MainActor
@Observable
final class ArchiveModel {
    /// The on-disk location of this window's `.genea` package. Security-scoped
    /// access to it is owned by `ArchiveAccessStore` — acquired before the window
    /// was opened and released when it closes — so this model never touches the
    /// archive URL's scope itself.
    let url: URL

    /// The open archive, populated by `load()`. `nil` until opened (or if the
    /// open failed — see `openError`).
    private(set) var archive: Archive?

    /// The browse list for the open archive (every artifact, sorted by title).
    private(set) var artifacts: [ArtifactSummary] = []

    // MARK: - Damage the archive already knows about (slice 56)

    /// What `Archive.standingFindings()` last reported: records that could not be
    /// read, and whether a write is known to have died. Refreshed wherever the
    /// browse lists are, because it costs a `SELECT` over a tiny table — the
    /// point of the engine call is that this is affordable on every refresh.
    ///
    /// The expensive question (does every tracked file still match its hash?)
    /// stays where it was: Verify Integrity, on demand.
    private(set) var standingFindings = Archive.StandingFindings()

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

    /// What `Archive.sweepFileSizes()` last found: tracked files that are gone, or
    /// the wrong length. `nil` until the first sweep finishes.
    ///
    /// This answers what `standingFindings` above cannot. 56 surfaces damage the
    /// archive already *knows about*, and a file deleted or truncated on disk
    /// commits nothing for it to know — which is exactly what 56's hand-test hit,
    /// and why this slice exists.
    private(set) var fileDamage: FileDamageSummary?

    /// Whether there is anything for the damage banner to say — either kind.
    var hasStandingDamage: Bool { !standingFindings.isEmpty || fileDamage != nil }

    /// The in-flight sweep, so a burst of refreshes drops the ones still queued
    /// rather than running all of them (see `sweepFiles` for what cancellation
    /// can and cannot do here).
    ///
    /// Readable (not settable) beyond this type only so the tests can await the
    /// real task rather than poll for its effect — the sweep is fire-and-forget in
    /// the app, since nothing waits on a banner, and a completion handle added to
    /// the production type purely for tests would be the tail wagging the dog
    /// (same call as `mutate`'s, see `AppTestSupport`).
    private(set) var fileSweepTask: Task<Void, Never>?

    /// Re-runs the cheap sweep **off the main actor** (fork e).
    ///
    /// Unlike `reloadStandingFindings()` — a `SELECT` over a tiny table, cheap
    /// enough to run inline — this is a `stat` per manifest entry, so its cost
    /// scales with the archive and it does not belong on the main actor. The
    /// engine call takes the read lock only long enough to snapshot the manifest,
    /// so the walk itself blocks no other reader.
    private func reloadFileDamage() {
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

    /// Whether a sweep was asked for while one was already walking, so the poll
    /// owes the caller a fresh one.
    ///
    /// Without this, a mutation whose `refresh()` coalesced away would leave the
    /// banner describing the archive as it was *before* that mutation until
    /// something else asked. The poll is already running once a second and is the
    /// natural place to drain it — no self-chaining task, which would also make
    /// `fileSweepSettled()` await the wrong one of two.
    private var fileSweepCoalesced = false

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
    private func reloadStandingFindings() {
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

    /// What can be put back, by path — the answer 56's placeholder row needs
    /// before it offers anything.
    ///
    /// **A row shows the action only when there is an entry here.** Damage and
    /// repairability are different questions: the copy lives in `.index/`, so it
    /// does not survive the rebuilds that discard the database, and a record that
    /// never decoded was never in the index to begin with. Deriving the button
    /// from the damage instead would put one on rows that cannot honour it, which
    /// is the lie 56 was careful not to tell.
    private(set) var repairPlans: [String: Archive.RecordRepairPlan] = [:]

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

    // MARK: - People (conclusions, Phase 3)

    /// The People-tab browse list: every concluded person, sorted by display name.
    /// Loaded by `load()` and reloaded by `refresh()` alongside the artifacts.
    private(set) var persons: [PersonSummary] = []

    /// The People-tab search query, bound to that sidebar's `.searchable`. Empty
    /// means "no filter"; when non-blank, `applyPersonFilter()` runs it through the
    /// engine's `persons(matching:)` (name search across all of a person's names).
    var personSearchText: String = ""

    /// Results of the active people search, recomputed by `applyPersonFilter()`.
    /// Only meaningful while `isFilteringPeople`.
    private(set) var personFilterResults: [PersonSummary] = []

    /// Whether the people list is filtered — a non-blank people search.
    var isFilteringPeople: Bool { !personSearchText.trimmed.isEmpty }

    /// What the People tab shows: the full list, or the current search results.
    var displayedPersons: [PersonSummary] { isFilteringPeople ? personFilterResults : persons }

    /// One-shot "select this newly-created person" intent (the People analog of
    /// `lastCreatedArtifact`). `createPerson` sets it; the People tab observes it,
    /// moves the scene-stored selection there, and clears it back to `nil`.
    var lastCreatedPerson: PersonID?

    /// One-shot "jump to the People tab and select this person" intent — the
    /// resolved-mention chip's tap (slice 42). Unlike `lastCreatedPerson` (which
    /// selects on the *current* People tab after a create), this also switches the
    /// window to the People tab. The container observes it, moves the scene-stored
    /// tab + person selection, and clears it back to `nil`.
    var pendingPersonNavigation: PersonID?

    /// One-shot "jump to the Artifacts tab and select this artifact" intent — the
    /// mirror of `pendingPersonNavigation`, driven by a person Sources row's tap
    /// (slice 42b). The container observes it, moves the scene-stored tab + artifact
    /// selection, and clears it back to `nil`.
    var pendingArtifactNavigation: ArtifactID?

    /// The current search query, bound to the sidebar `.searchable`. Empty means
    /// "no text filter".
    var searchText: String = ""

    /// The set of tags the toolbar Filter menu has selected (lowercased for
    /// case-insensitive matching). Empty means "no tag filter". Selected tags
    /// AND-combine with each other and with `searchText` (the engine's
    /// `ArtifactQuery` applies both facets in one pass, §5.1).
    private(set) var selectedTags: Set<String> = []

    /// Results of the active filter (text and/or tags), recomputed by
    /// `applyFilters()`. Only meaningful while `isFiltering`.
    private(set) var filterResults: [ArtifactSummary] = []

    /// Whether any filter is active — a non-blank search **or** a selected tag.
    var isFiltering: Bool {
        !searchText.trimmed.isEmpty || !selectedTags.isEmpty
    }

    /// The field the browse list is sorted by, driven by the sidebar Sort menu.
    /// In-memory only (not restored across relaunch — same deliberate scoping as
    /// search/filter, slice 18). Default `.title` reproduces the engine's existing
    /// order, so the list looks unchanged until the user picks a sort.
    var sortKey: ArtifactSortKey = .title

    /// Sort direction. `true` = ascending (A→Z / oldest / earliest).
    var sortAscending: Bool = true

    /// What the browser actually shows: the full list when no filter is active,
    /// otherwise the current filtered results — then ordered by the active sort.
    var displayedArtifacts: [ArtifactSummary] {
        sorted(isFiltering ? filterResults : artifacts)
    }

    /// How the browse list can be ordered (sidebar Sort menu, UI audit F7). Each
    /// case sorts a field already on `ArtifactSummary`, so sorting is client-side —
    /// no engine query.
    enum ArtifactSortKey: String, CaseIterable, Identifiable {
        case title
        case dateAdded
        case primaryDate

        var id: String { rawValue }

        /// The menu's section-row label for picking this key.
        var label: String {
            switch self {
            case .title: "Title"
            case .dateAdded: "Date Added"
            case .primaryDate: "Primary Date"
            }
        }

        /// Direction labels, phrased for the key (clearer than a bare
        /// "Ascending/Descending" for dates).
        var ascendingLabel: String {
            switch self {
            case .title: "A to Z"
            case .dateAdded: "Oldest First"
            case .primaryDate: "Earliest First"
            }
        }
        var descendingLabel: String {
            switch self {
            case .title: "Z to A"
            case .dateAdded: "Newest First"
            case .primaryDate: "Latest First"
            }
        }
    }

    /// Orders `list` by the active sort key + direction. Stable: equal primary keys
    /// fall back to title then uid so the order never jitters. For `.primaryDate`,
    /// undated artifacts sort **last** regardless of direction.
    private func sorted(_ list: [ArtifactSummary]) -> [ArtifactSummary] {
        let ascending = sortAscending
        return list.sorted { a, b in
            switch sortKey {
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                if r != .orderedSame {
                    return ascending ? r == .orderedAscending : r == .orderedDescending
                }
            case .dateAdded:
                // The uid is a time-ordered UUIDv7, so its raw string sorts by creation time.
                if a.uid.raw != b.uid.raw {
                    return ascending ? a.uid.raw < b.uid.raw : a.uid.raw > b.uid.raw
                }
            case .primaryDate:
                // Order by the EDTF-parsed chronological bound, not the raw string —
                // a lexicographic compare mis-sorts masked/approximate dates (e.g.
                // "19XX" vs "1920"). Undated *and* unparseable-as-date values sort last.
                let x = a.primaryDate.flatMap { EDTFDate.parse($0)?.sortBound }
                let y = b.primaryDate.flatMap { EDTFDate.parse($0)?.sortBound }
                switch (x, y) {
                case let (x?, y?) where x != y:
                    return ascending ? x < y : x > y
                case (nil, _?): return false  // undated → after a dated one
                case (_?, nil): return true  // dated → before an undated one
                default: break  // both nil, or equal bounds → fall through to tiebreak
                }
            }
            // Tiebreak: title, then uid — deterministic and stable.
            let t = a.title.localizedStandardCompare(b.title)
            if t != .orderedSame { return t == .orderedAscending }
            return a.uid.raw < b.uid.raw
        }
    }

    /// Every distinct tag across the open archive's artifacts, with how many
    /// artifacts carry it, sorted by tag name. Drives the toolbar Filter menu.
    /// Tags are compared case-insensitively but presented in their first-seen
    /// original casing. Derived from the loaded browse summaries — no extra query.
    var tagFacets: [TagFacet] {
        var counts: [String: (display: String, count: Int)] = [:]
        for artifact in artifacts {
            for tag in artifact.tags {
                let key = tag.lowercased()
                if let existing = counts[key] {
                    counts[key] = (existing.display, existing.count + 1)
                } else {
                    counts[key] = (tag, 1)
                }
            }
        }
        return
            counts
            .map { TagFacet(key: $0.key, display: $0.value.display, count: $0.value.count) }
            .sorted { $0.display.localizedStandardCompare($1.display) == .orderedAscending }
    }

    /// One selectable tag in the Filter menu: its lowercased match `key`, the
    /// `display` casing to show, and how many artifacts carry it.
    struct TagFacet: Identifiable {
        let key: String
        let display: String
        let count: Int
        var id: String { key }
    }

    /// A fatal "couldn't open this archive" message, shown inline in place of the
    /// browser. Kept distinct from `actionError` (a transient, dismissable alert)
    /// so an open failure doesn't also raise an alert over an unusable window.
    private(set) var openError: String?

    /// A transient per-action failure (e.g. an ingest error), surfaced as an
    /// `.alert`. `nil` when there is nothing to report.
    var actionError: String?

    /// Bool projection of `actionError` for `.alert(isPresented:)`. Reading it in
    /// a view body establishes the observation dependency a manual
    /// `Binding(get:set:)` over `actionError` would miss; setting it `false`
    /// (alert dismissed) clears the error.
    var isShowingError: Bool {
        get { actionError != nil }
        set {
            if !newValue {
                actionError = nil
                keptScans = []
            }
        }
    }

    /// A transient, benign informational message (e.g. "no embedded metadata
    /// found"), surfaced as an `.alert`. Kept distinct from `actionError` so a
    /// successful-but-empty outcome isn't framed to the user as a failure. Set via
    /// `showInfo(_:title:)` so its `actionInfoTitle` always matches.
    private(set) var actionInfo: String?

    /// The title shown above `actionInfo` — varies by source (a metadata scan, a
    /// can't-restore notice, …), so the alert never wears the wrong heading.
    private(set) var actionInfoTitle: String = ""

    /// Bool projection of `actionInfo` for `.alert(isPresented:)` (see
    /// `isShowingError`).
    var isShowingInfo: Bool {
        get { actionInfo != nil }
        set { if !newValue { actionInfo = nil } }
    }

    /// Surfaces a benign informational alert with its own `title` — the one channel
    /// for "nothing to report" outcomes that shouldn't read as errors.
    func showInfo(_ message: String, title: String) {
        actionInfoTitle = title
        actionInfo = message
    }

    /// What a completed import should do — set when the (single, shared) importer
    /// is presented, read by `handleImport`. Only one `.fileImporter` may be live
    /// per view hierarchy, so add-media and attach-to-existing multiplex this one.
    enum ImportMode: Equatable {
        /// Each picked file becomes a *new* artifact (the `+` / drag-in path).
        case addMedia
        /// Each picked file is attached to an existing artifact under the default
        /// role (`Self.defaultFileRole`); the user re-assigns the role afterward
        /// via the per-file menu (slice 32 — a sensible default in all cases plus
        /// a way to change it later, rather than an inconsistent pre-pick).
        case attach(to: ArtifactID)
        /// The first picked file replaces the content of an existing file entry
        /// (any extra selection is ignored — replace targets one file).
        case replace(fileID: FileID, artifactID: ArtifactID)
    }

    /// The role every newly added file gets — new-artifact ingest and
    /// attach-to-existing alike (slice 32). Chosen as the archival original by
    /// default; correct it afterward with `setFileRole` (the per-file Role menu).
    ///
    /// `nonisolated` because `ingest`/`attach` read it inside `mutate`'s off-main
    /// work closure (52). It is an immutable value in a `Sendable` enum; only the
    /// module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` put it on the actor.
    nonisolated static let defaultFileRole: FileRole = .preservationMaster

    /// The mode the importer was last presented in. Defaults to `.addMedia`.
    private(set) var importMode: ImportMode = .addMedia

    /// Drives the shared `.fileImporter`. Opening an archive is no longer a
    /// per-window concern (it happens before a window exists), so this importer
    /// only ever adds media or attaches files to an existing artifact.
    var isImporterPresented = false

    /// Drives the integrity-report sheet (File ▸ Verify Integrity…).
    var isShowingIntegrityReport = false

    /// Drives the trash sheet (File ▸ Show Trash…).
    var isShowingTrash = false

    /// One-shot "select this newly-created artifact" intent (slice 29). Set by
    /// `ingest` to the last artifact it minted; the view observes it, moves the
    /// (scene-stored, view-owned) selection there, and clears it back to `nil`.
    /// Kept as an intent — not a direct selection write — because selection lives
    /// in `@SceneStorage` in the container, which the model shouldn't touch.
    var lastCreatedArtifact: ArtifactID?

    /// Session cache of embedded metadata captured during ingest, keyed by the
    /// artifact it was captured for. Never persisted, never written to any
    /// genealogical field (ARCHITECTURE.md §6.4 — the scan-date trap); surfaced
    /// read-only as a suggestion in `ArtifactDetailView`.
    private(set) var capturedMetadata: [ArtifactID: EmbeddedMetadata] = [:]

    /// The window's undo manager, supplied by the view (`@Environment(\.undoManager)`).
    /// Each archive window has its own, so undo/redo is per-archive. `nil` until the
    /// view wires it (and whenever the window has none), in which case mutations
    /// simply aren't recorded — they still happen.
    ///
    /// **Grouping is left to `groupsByEvent`, deliberately — do not turn it off.**
    ///
    /// 52's review found that two actions whose commits drain in the same
    /// run-loop turn land in one event group, so a single ⌘Z reverses both, and
    /// the obvious fix is to group explicitly instead. That was tried and
    /// **reverted**: this is the *window's* undo manager, shared with AppKit's own
    /// text-field undo, which registers typing steps against it. Switching event
    /// grouping off changed their behaviour too — a second ⌘Z after renaming an
    /// artifact landed on the text field's undo entry and restored the typed text,
    /// which reads exactly like a redo. Found by hand-test; no automated test
    /// covered it, because the model tests supply their own bare `UndoManager`
    /// with no text field attached to it.
    ///
    /// The merging case is the lesser evil and stays known: see slice 52's spec.
    /// Giving the model its own undo stack would fix it properly, and would also
    /// take ⌘Z away from in-field typing — a UI decision, not a refactor.
    var undoManager: UndoManager?

    /// Bumped on every committed mutation (including undo/redo). The detail view
    /// keys its full-record reload on this, so a change originating in the *model*
    /// — an undo/redo — visibly refreshes the pane, not just user-initiated edits.
    private(set) var mutationVersion = 0

    // MARK: - Menu-command routing (UI audit F6)
    //
    // The menu bar lives in `ArchiveCommands` (a `Commands`, not a view), so it
    // can't see the window's view-owned selection (`@SceneStorage` in the
    // container / local `@State` in the detail view). These mirrors reflect that
    // selection **down** into the model purely so the File/Artifact/View menus can
    // enable and target their commands; the views remain the source of truth and
    // the model never writes selection back up. The paired one-shot intents let a
    // menu ask a view to run a verb it owns (a sheet, an export panel, the
    // inspector's `@SceneStorage`); the view observes the intent, performs it, and
    // clears it back to `nil`/`false` so picking the same command twice re-fires.

    /// The selected artifact, mirrored from the container's selection. Drives menu
    /// enablement and is the target of the artifact-scoped commands.
    var selectedArtifact: ArtifactID?

    /// The file selected in the detail pane, mirrored from that view. Drives the
    /// Artifact ▸ Selected File submenu's enablement and is the per-file target.
    var selectedFile: FileID?

    /// Whether the detail inspector is currently shown, mirrored from the view's
    /// `@SceneStorage`, so the View menu can label its toggle Show vs. Hide.
    var inspectorVisible = true

    /// The active window tab, mirrored from the container's `@SceneStorage`. The
    /// artifact-scoped menu commands (Artifact menu, Selected File, inspector toggle)
    /// gate on this being `.artifacts`, so they don't act on a stale artifact
    /// selection while the People or Tree tab is showing.
    var activeTab: ArchiveTab = .artifacts

    /// An artifact-scoped verb the menu bar wants run against `selectedArtifact`.
    /// The detail view observes it and drives its own sheet state. Attach and
    /// Delete are routed separately (`beginAttachOrScan` / `pendingArtifactDeletion`).
    enum ArtifactCommand { case addEvent, addPlace, addPerson, editTranscript }
    var pendingArtifactCommand: ArtifactCommand?

    /// A per-file verb the menu bar wants run against `selectedFile`. The detail
    /// view (which owns the file selection and the preview/export handlers)
    /// observes and dispatches it.
    enum FileCommand {
        case openSeparateWindow, openInDefaultApp, saveCopy, replace, delete
    }
    var pendingFileCommand: FileCommand?

    /// One-shot "confirm-then-delete the selected artifact" intent (Artifact ▸
    /// Delete Artifact… / ⌘⌫). The sidebar list observes it and raises the *same*
    /// confirm dialog as its own ⌫ / context-menu delete.
    var pendingArtifactDeletion = false

    /// One-shot "toggle the inspector" intent (View ▸ Show/Hide Inspector, ⌘⌥I).
    /// The detail view owns the inspector's `@SceneStorage` visibility, so it flips
    /// that and updates `inspectorVisible`.
    var pendingInspectorToggle = false

    /// Requests an artifact-scoped command from the menu bar.
    func requestArtifactCommand(_ command: ArtifactCommand) { pendingArtifactCommand = command }

    /// Requests a per-file command from the menu bar.
    func requestFileCommand(_ command: FileCommand) { pendingFileCommand = command }

    /// Requests confirm-and-delete of the selected artifact from the menu bar.
    func requestDeleteSelectedArtifact() { pendingArtifactDeletion = true }

    /// Requests an inspector-visibility toggle from the menu bar.
    func requestInspectorToggle() { pendingInspectorToggle = true }

    init(url: URL) {
        self.url = url
    }

    /// Opens the archive at `url` and loads its artifact list. Idempotent — a
    /// no-op once the archive is open.
    ///
    /// Ensures security-scoped access first: for a freshly opened archive the
    /// opener already `acquire`d it (no-op here); for a window **restored across
    /// relaunch** (or reopened from a stale URL) no live scope exists, so this
    /// re-derives one from the persisted bookmark. If that fails — the archive was
    /// moved or deleted since it was last open — it reports a clear, actionable
    /// error instead of an opaque permissions failure.
    func load() {
        guard archive == nil else { return }
        guard ArchiveAccessStore.shared.ensureAccess(to: url) else {
            openError =
                "GeneaLogic can no longer reach this archive — it may have been moved, "
                + "renamed, or deleted. Open it again from File ▸ Open Archive…"
            return
        }
        do {
            let opened = try Archive.open(at: url)
            archive = opened
            artifacts = opened.artifacts()
            reloadPersons()
            reloadStandingFindings()
            reloadFileDamage()
            // Baseline for external-change detection: everything on screen is
            // current as of this token, so only a *later* value means somebody
            // else wrote.
            lastExternalChangeToken = opened.externalChangeToken()
            // A window can be opened *into* a delivery, so the arrival indicator
            // needs its baseline here too, not only from the poll (slice 61).
            // `open()` has already reconciled by this point, so this is the
            // settled answer rather than a guess — and it is one `stat` on the
            // common path.
            updateIncomingChange(inFlight: opened.deliveryIsInFlight)
        } catch {
            openError = describe(error)
        }
    }

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

    /// How long the window should wait before its next check.
    ///
    /// Normally `externalChangePollInterval`. After a refresh it scales with what
    /// that refresh actually cost (review finding, 51): the poll runs `refresh()`
    /// on the main actor, and under a *sustained* external write loop it would
    /// otherwise do so once a second at a cadence another process controls — on a
    /// large archive with the Review section loaded, that refresh includes a match
    /// sweep. Backing off proportionally caps the work at roughly a tenth of the
    /// main actor no matter how heavy the refresh or how fast the other process
    /// writes, and costs nothing in the common case where refreshes are quick.
    private(set) var nextExternalChangePollDelay: Duration = externalChangePollInterval

    /// The change token this window's lists were built from. `nil` until `load()`
    /// succeeds, or whenever the token can't be read.
    private var lastExternalChangeToken: Int?

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

    /// The staleness check in flight, if any. One at a time: it can end in a full
    /// index rebuild, and a second one behind it would rebuild what the first
    /// just did.
    private(set) var reconcileTask: Task<Void, Never>?

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

    /// What the window is currently saying about a change arriving from another
    /// machine — `nil` for the overwhelmingly common case of nothing arriving.
    ///
    /// **Slice 60 could already tell an arrival from damage; only the Verify
    /// panel said so**, and that is a menu item nobody opens speculatively. So a
    /// synced archive part-way through receiving a large record showed nothing at
    /// all, while every edit to the arriving record was refused with an error
    /// that came out of nowhere (`recordAwaitingDelivery`). This is that state,
    /// said out loud.
    private(set) var incomingChange: IncomingChange?

    /// How long a delivery must have been in flight before the bar appears.
    ///
    /// **A delay, because most deliveries land between polls**, and an indicator
    /// that flickers on every small sync teaches the user to ignore it. It costs
    /// nothing to wait: the state it reports was invisible altogether until this
    /// slice.
    ///
    /// An instance property rather than a `static` so a test can set it to zero
    /// without reaching into state a suite running in parallel depends on. The
    /// engine's `reconcileBackoffBounds` is the same shape for the same reason;
    /// production assigns neither.
    var incomingChangeDelay: Duration = .seconds(2)

    /// How long a delivery may sit **without progress** before the wording
    /// escalates — see `IncomingChange.stalled`.
    ///
    /// **Ten minutes, and long deliberately.** The escalation cannot be
    /// certain — a large file arriving over a slow link looks exactly like one
    /// that stopped, because sync providers stage a download elsewhere and swap
    /// it in, so the file is simply absent throughout. A short threshold would
    /// therefore mislabel every slow preservation master, which is the crying
    /// wolf 57's rule exists to prevent. Ten minutes with hedged wording is the
    /// trade: late enough to be worth saying, phrased so it stays true either
    /// way.
    var incomingChangeStallThreshold: Duration = .seconds(600)

    /// When the current in-flight period began. `nil` means nothing is arriving,
    /// and doubles as the gate on the poll's extra sweep above.
    private var deliveryInFlightSince: ContinuousClock.Instant?

    /// When `outstandingArrivals` last changed — the only progress this app can
    /// observe, and what the stall threshold is measured from.
    private var deliveryLastProgressAt: ContinuousClock.Instant?

    /// The paths the last sweep reported as not yet arrived. Kept but never
    /// shown: it is the *change* in this set that means something, not its
    /// contents (fork b — this indicator names no files).
    private var outstandingArrivals: Set<String> = []

    /// Folds the engine's in-flight fact into what the window says, once per
    /// poll.
    ///
    /// **The boundary is adoption, not arrival.** `deliveryIsInFlight` stays true
    /// until the index has actually taken the change in, which is a reconcile
    /// back-off *after* the last file lands. Clearing on the files instead would
    /// take the bar away while the list still showed the old record — announcing
    /// a change and then withdrawing the announcement before it appeared.
    private func updateIncomingChange(inFlight: Bool, now: ContinuousClock.Instant = .now) {
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
    private func noteArrivalProgress(in report: Archive.FileSweepReport) {
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

    /// Re-runs `artifacts()` against the open archive. No-op if nothing is open.
    /// If a search is active, its results are recomputed too so the filtered list
    /// reflects the mutation (e.g. a retitled artifact dropping out of matches).
    ///
    /// **`private` on purpose — call `bumpAndRefresh()` instead.** This reloads the
    /// browse lists and *only* the browse lists; both detail panes and the Tree tab
    /// reload off `mutationVersion`, which this does not touch. Anything that
    /// changes what the archive holds must go through `bumpAndRefresh()`, or an
    /// open detail pane silently keeps showing the old record.
    ///
    /// That is not hypothetical: slice 51's external-change path called this
    /// directly and left an externally-edited *selected* record stale (caught by
    /// `/code-review`), and `rebuildIndex()` had the same bug independently. Both
    /// were possible only because this was reachable and has the more inviting
    /// name — so the fix is to make the wrong call unavailable rather than to
    /// remember not to make it.
    private func refresh() {
        guard let archive else { return }
        artifacts = archive.artifacts()
        // Drop any selected tags that no longer exist on any artifact (e.g. an
        // edit removed the last use of one), so the filter can't get stuck on a
        // vanished tag, then re-run whatever filter is still active.
        let available = Set(artifacts.flatMap { $0.tags.map { $0.lowercased() } })
        selectedTags.formIntersection(available)
        if isFiltering { applyFilters() }
        reloadPersons()
        // Cheap enough to ride every refresh, which is what makes damage arriving
        // from another writer (51's poll goes through here) visible without the
        // user thinking to run anything (slice 56).
        reloadStandingFindings()
        // 57's half of the same idea, and the one that catches damage nothing has
        // recorded yet. Off the main actor, so it does not ride this call's cost.
        reloadFileDamage()
        // After the people list, which the worklist's candidate names read. Only once the
        // Review section has actually been opened — a window that never visits it never
        // pays for a match sweep (see `refreshReviewWorklist`).
        if hasLoadedReviewWorklist { refreshReviewWorklist() }
    }

    // MARK: - People (read + reload)

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

    /// Marks a mutation as committed (bumping `mutationVersion` so the detail pane
    /// reloads) and refreshes the browse list. The single chokepoint every
    /// model-level write — including undo/redo — funnels through.
    ///
    /// **And now the only way in**, since `refresh()` became private: "something
    /// about this archive changed" has exactly one expression, whoever caused the
    /// change. That is enforcement rather than convention — the previous wording
    /// already called this the single chokepoint, and two call sites bypassed it
    /// anyway.
    private func bumpAndRefresh() {
        mutationVersion += 1
        refresh()
    }

    /// Marks a mutation as committed **without** re-reading the archive — for a write that
    /// changes nothing any browse list or detail pane displays. Today that is the dismissal
    /// record alone (45m): it is read only by the suggestion sweeps, and the lane that
    /// wrote it updates its own row. Going through `bumpAndRefresh` would re-run the whole
    /// match worklist to reflect a change none of it can see.
    private func bump() {
        mutationVersion += 1
    }

    // MARK: - Mutations off the main actor (slice 52)

    /// The serial queue every engine **write** runs on.
    ///
    /// A dedicated `DispatchQueue` rather than an `actor` or `Task.detached`:
    /// since slice 47 a mutation can park for up to `ArchiveLock.timeout` (5s)
    /// waiting for another process, and parking a *cooperative pool* thread that
    /// long can starve unrelated async work in the app. This queue's thread is
    /// ours to block.
    ///
    /// **Serial**, so writes commit in the order the user issued them. That is
    /// what keeps undo coherent: the undo stack is built in `commit`, on the main
    /// actor, in the same order the queue finishes.
    private let writeQueue = DispatchQueue(
        label: "com.genealogic.app.archive-write", qos: .userInitiated)

    /// How long a mutation has to be in flight before the window admits it is
    /// waiting. Normal writes are microseconds, so nothing appears for them —
    /// a control that flickered on every keystroke-driven edit would be worse
    /// than none (slice 52, fork c).
    static let waitIndicatorDelay: Duration = .milliseconds(300)

    /// Whether a mutation has been waiting long enough to say so. Drives the
    /// window's non-modal "waiting for another process" strip.
    private(set) var isWaitingOnAnotherProcess = false

    /// How many mutations are in flight. The indicator is a property of *any*
    /// of them being slow, not of a particular one.
    private var mutationsInFlight = 0

    /// Whether any mutation is still on the write queue.
    var hasMutationsInFlight: Bool { mutationsInFlight > 0 }

    /// Bumped whenever a mutation **fails**.
    ///
    /// Editors watch this to re-seed fields that are showing text the archive
    /// refused. `mutationVersion` cannot serve: a failed write leaves the record
    /// exactly as it was, so the reloaded snapshot is `Equatable`-identical and
    /// nothing keyed on the record notices. The field, meanwhile, still holds
    /// what the user typed — which reads as saved.
    ///
    /// Found by hand-test twice: first as "the edit is lost" (it wasn't lost, it
    /// was never written), then again after the first fix, which refreshed the
    /// model but left the editor's own `@State` untouched for exactly this reason.
    private(set) var writeFailures = 0

    /// Continuations parked in `writesSettled()`, resumed together when the last
    /// in-flight mutation commits.
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends until no mutation is in flight.
    ///
    /// **Most of the app must not need this**, and doesn't: a view renders model
    /// state, and `commit` republishes that state when a write lands. The
    /// exceptions are callers that keep their *own* copy of engine state, or that
    /// tear something down a write depends on — and 52's `/code-review` found
    /// that all three had been left behind by the move to async writes:
    ///
    /// - `TrashSheet` holds its own `trashedArtifacts()`/`trashedFiles()` arrays
    ///   and reloaded them in the same turn as the mutation, so rows never left.
    /// - `IntegrityReportSheet` re-runs its own sweep after a repair, and reads
    ///   `actionError` to report a failure the sheet would otherwise hide.
    /// - The archive window releases its security scope on close, which must not
    ///   happen while a write is still parked on the archive lock.
    ///
    /// Reach for it only in that shape — "I keep state the model doesn't
    /// republish, or I am about to remove something the write needs". Awaiting it
    /// to sequence one mutation after another is a sign the two belong in one
    /// `work` instead (see `mutate`).
    func writesSettled() async {
        guard mutationsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            settledWaiters.append(continuation)
        }
    }

    /// The pending "reveal the indicator" timer, cancelled when the last
    /// in-flight mutation finishes before it fires.
    private var waitIndicatorTask: Task<Void, Never>?

    /// **The one place an engine write leaves the main actor.**
    ///
    /// `work` runs on `writeQueue` and gets the open `Archive` (which is
    /// `@unchecked Sendable`, its own locks doing the serializing); `commit` runs
    /// back on the main actor with whatever `work` returned, and is where undo
    /// registration and `bumpAndRefresh()` belong. Reads stay on the main actor
    /// deliberately — since 52's engine change they no longer queue behind a
    /// writer waiting on another process, so moving them would buy nothing and
    /// cost every call site an `await`.
    ///
    /// **Everything one user action writes must go in a single `work`.** Two
    /// `mutate` calls in a row are two hops, which would split their undo
    /// registrations across two run-loop turns — and `NSUndoManager` groups by
    /// turn, so one ⌘Z would become several. The multi-write paths
    /// (`recordCoupleFact`, `createPersonAndLink`, `ingest`, …) are written that
    /// way for exactly this reason.
    ///
    /// - Parameters:
    ///   - unopened: The error to show when no archive is open.
    ///   - failure: Runs on the main actor for a thrown error. Return `true` if
    ///     it handled the error (nothing further is shown); `false` to fall
    ///     through to the standard `actionError` message.
    private func mutate<T: Sendable>(
        unopened: String,
        work: @escaping @Sendable (Archive) throws -> T,
        commit: @escaping @MainActor (T) -> Void,
        failure: (@MainActor (Error) -> Bool)? = nil
    ) {
        guard let archive else {
            actionError = unopened
            return
        }
        beginMutation()
        Task { @MainActor in
            defer { endMutation() }
            do {
                let result = try await onWriteQueue { try work(archive) }
                commit(result)
            } catch {
                if failure?(error) != true { actionError = describe(error) }
                // **Resync the views even though nothing was written** (52's
                // hand-test). A failed write leaves an editor showing text the user
                // typed and the archive never accepted, which reads as saved.
                // `writeFailures` is what the editors actually key on — see its
                // doc for why the refresh below cannot reach them on its own.
                writeFailures += 1
                bumpAndRefresh()
            }
        }
    }

    /// What a multi-write `work` managed to do, plus the error that stopped it.
    ///
    /// **Why the multi-write paths catch instead of throwing.** Several actions
    /// are two or three engine writes with no transaction between them
    /// (`recordCoupleFact`, `createPersonRelateAndRecord`, `createPersonAndLink`,
    /// `resolveMention`). Each has always registered undo for every record it
    /// actually created, so a fault halfway through still leaves the completed
    /// writes reversible rather than stranding them. Throwing out of `work` would
    /// have quietly dropped that: `commit` is where registration lives, and a
    /// throw skips it. So they hand back what they achieved and let `commit`
    /// register it, then report the failure.
    private struct Partial<Value: Sendable>: Sendable {
        var value: Value
        var failure: Error?
    }

    /// Bridges `writeQueue` into `async`. Separate from `mutate` only so the
    /// continuation plumbing isn't repeated.
    private func onWriteQueue<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writeQueue.async {
                continuation.resume(with: Result(catching: body))
            }
        }
    }

    /// How often the armed indicator re-asks the engine whether we are blocked.
    /// A write can start uncontended and *become* blocked, or the reverse.
    private static let waitIndicatorPollInterval: Duration = .milliseconds(200)

    /// Counts a mutation in and arms the delayed indicator.
    ///
    /// **Elapsed time alone is not evidence of contention** (52's `/code-review`):
    /// a 20-file ingest or an index rebuild easily outlives the delay while
    /// nothing else is touching the archive, and the bar would have announced
    /// another process that did not exist. So after the delay this asks the engine
    /// (`Archive.isWaitingForAnotherProcess`, which is true only once a lock
    /// attempt has actually failed) and keeps asking while the write is in flight.
    /// A slow *local* write therefore shows nothing at all, which is right — this
    /// slice is about contention, and a general progress affordance is a different
    /// question.
    private func beginMutation() {
        mutationsInFlight += 1
        guard waitIndicatorTask == nil else { return }
        waitIndicatorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.waitIndicatorDelay)
            while !Task.isCancelled, let self, mutationsInFlight > 0 {
                isWaitingOnAnotherProcess = archive?.isWaitingForAnotherProcess ?? false
                try? await Task.sleep(for: Self.waitIndicatorPollInterval)
            }
        }
    }

    /// Counts a mutation out; the indicator goes when the last one does, and
    /// anyone parked in `writesSettled()` is released.
    private func endMutation() {
        mutationsInFlight -= 1
        guard mutationsInFlight == 0 else { return }
        waitIndicatorTask?.cancel()
        waitIndicatorTask = nil
        isWaitingOnAnotherProcess = false
        let waiters = settledWaiters
        settledWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    // MARK: - Undo grouping (slice 52, and its review)

    /// **Every undo registration in this file goes through here.**
    ///
    /// Chiefly so there is one place to reason about registration, which is what
    /// the async hop made subtle — and one place to have got the grouping
    /// experiment wrong, and to undo it (see `undoManager`). Grouping itself is
    /// `groupsByEvent`'s job: all of one action's registrations happen inside a
    /// single `commit`, so they share a run-loop turn and a group.
    ///
    /// The pairing with `setActionName` used to be repeated at all 23 sites, and
    /// is now impossible to forget.
    private func registerUndoStep(
        actionName: String, _ body: @escaping @MainActor (ArchiveModel) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in body(model) }
        undoManager.setActionName(actionName)
    }

    // MARK: - Undo across the actor hop (slice 52)
    //
    // Every `registerUndo` block below follows one rule, and it is the rule that
    // makes undo survive the hop:
    //
    //     **Register the counterpart first, synchronously. Then mutate.**
    //
    // `NSUndoManager` decides which stack a registration lands on by what it is
    // doing *at the moment of the call*: a `registerUndo` issued while it is
    // inside an undo becomes the redo, and one issued at any other time becomes a
    // new undo. Before 52 the engine call ran inline, so registering afterwards
    // was still "during the undo" and the ping-pong worked. Now the engine call
    // is awaited — so a registration after it would run a turn later, with the
    // manager idle, and would be filed as a *fresh undo*. ⌘Z would become a
    // one-way trip that re-does itself: the exact silent breakage 52 flagged, and
    // one no test caught because nothing covered undo at all (hence
    // `UndoRedoTests`).
    //
    // The cost of registering first is that the counterpart is on the stack even
    // if the engine call then fails. That is a real behaviour change, and a small
    // one: the paths where a failure is *expected* (a record removed out-of-band,
    // a purged trash entry) already no-op gracefully with a benign notice when
    // invoked, so the stack advances over a step that does nothing instead of
    // stopping at a step that was never registered.

    /// Runs the active filter through the engine's index-backed
    /// `artifacts(matching:)` into `filterResults`: free text over title + inline
    /// transcript + notes + the text of any `role: .transcript` *file* (§5.1),
    /// AND an exact whole-tag match for every selected tag. With no filter active
    /// it clears the results (`displayedArtifacts` then shows the full list).
    func applyFilters() {
        let query = searchText.trimmed
        guard let archive, isFiltering else {
            filterResults = []
            return
        }
        filterResults = archive.artifacts(
            matching: ArtifactQuery(
                text: query.isEmpty ? nil : query,
                tags: Array(selectedTags)))
    }

    /// Toggles tag `key` (already lowercased) in the Filter menu and re-runs the
    /// filter.
    func toggleTag(_ key: String) {
        if selectedTags.contains(key) {
            selectedTags.remove(key)
        } else {
            selectedTags.insert(key)
        }
        applyFilters()
    }

    /// Clears the tag filter (leaves the text search untouched) and re-runs.
    func clearTagFilter() {
        selectedTags.removeAll()
        applyFilters()
    }

    /// Presents the importer in add-media mode (⌘I / + button): picked files
    /// become new artifacts.
    func beginAddMedia() {
        importMode = .addMedia
        isImporterPresented = true
    }

    /// The window's Continuity Camera scanner, set by `ContinuityCameraHost` once
    /// the view hierarchy exists. Referenced through a UI-free protocol so this
    /// model needs no AppKit import. `nil` until the host wires it (and on a window
    /// with no scanner), in which case the scan actions simply do nothing.
    weak var continuityScanner: (any ContinuityScanning)?

    /// The toolbar **+**: presents one menu offering **Add Media…** (the file
    /// importer) alongside the Continuity Camera scan options, so adding from disk
    /// and scanning a new artifact live in a single connected menu rather than a
    /// floating pop-up. A scan is routed through the same `ingest` path as Add
    /// Media, so it's metadata-extracted and undoable (⌘Z). Falls back to the plain
    /// importer if no scanner is wired (e.g. before the view appears).
    func beginAddOrScan() {
        guard archive != nil else {
            actionError = "Open an archive before adding media."
            return
        }
        guard let continuityScanner else {
            beginAddMedia()
            return
        }
        continuityScanner.requestAddOrScan(
            leadingTitle: "Add Artifact…",
            onChooseFiles: { [weak self] in self?.beginAddMedia() },
            onScanned: { [weak self] url in self?.ingestScanned([url], mode: .addMedia) })
    }

    /// The per-artifact **Attach File…**: presents **one** connected menu offering
    /// *Attach File…* (the importer) alongside the Continuity Camera scan options, so
    /// attaching from disk and scanning a file into the existing artifact `id` live in
    /// a single connected menu — never a SwiftUI menu that pops a second AppKit menu
    /// (a slice 32 follow-up). Mirrors `beginAddOrScan`; a scan routes through the same
    /// `attach` path (metadata-extracted, undoable), the new file taking the default
    /// role, corrected afterward via the per-file menu. Falls back to the plain
    /// importer if no scanner is wired (e.g. before the view appears).
    func beginAttachOrScan(to id: ArtifactID) {
        guard archive != nil else {
            actionError = "Open an archive before attaching files."
            return
        }
        guard let continuityScanner else {
            beginAttach(to: id)
            return
        }
        continuityScanner.requestAddOrScan(
            leadingTitle: "Attach File…",
            onChooseFiles: { [weak self] in self?.beginAttach(to: id) },
            onScanned: { [weak self] url in self?.ingestScanned([url], mode: .attach(to: id)) })
    }

    /// Routes a freshly captured Continuity Camera file through new-artifact
    /// ingest or attach-to-existing. `.replace` is never a scan target.
    ///
    /// **A scan is deleted only once it has landed** (slice 67). Until then
    /// this removed the temp file as soon as `ingest`/`attach` returned, and
    /// since 52 they only enqueue their write — so the engine found the file
    /// already gone: an empty artifact, and a capture that existed nowhere else.
    /// A scan the engine refuses is **kept** and the error offers it in Finder
    /// (fork b, settled the other way on `/code-review`): a refusal can be
    /// transient — `archiveBusy` after another process holds the lock for five
    /// seconds — and a document scan may be many pages.
    func ingestScanned(_ urls: [URL], mode: ImportMode) {
        let extractor = MetadataExtractors.makeDefault()
        switch mode {
        case .addMedia:
            consumeScans(urls, unopened: "Open an archive before adding media.") { archive in
                Self.ingestEach(urls, into: archive, extractor: extractor)
            } commit: { [self] outcomes in
                commitIngest(outcomes)
            }
        case .attach(let id):
            consumeScans(urls, unopened: "Open an archive before attaching files.") { archive in
                Self.attachEach(urls, to: id, in: archive, extractor: extractor)
            } commit: { [self] outcomes in
                commitAttach(outcomes, to: id)
            }
        case .replace:
            break
        }
    }

    /// Scans a refused write kept, offered by the error alert's *Show in
    /// Finder*. Cleared only when the user dismisses the alert.
    ///
    /// **Accumulates** (cloud review of 67–71): scans arrive one capture at a
    /// time, so a second refusal before the first alert is dismissed used to
    /// replace the first capture's entry — and this offer is the only way back
    /// to a file in a folder the user cannot find. For the same reason a later
    /// error that has nothing to do with scans does not clear it; the alert
    /// still says the scans are kept (`errorMessage`), which stays true.
    private(set) var keptScans: [URL] = []

    /// What the error alert says: `actionError`, then — while any refused scan
    /// is kept — that it was kept. Composed here rather than written into
    /// `actionError` once, so a later error replacing the text cannot drop it.
    var errorMessage: String {
        let note: String? =
            switch keptScans.count {
            case 0: nil
            case 1: "The scan was kept. Show it in Finder to add it again."
            default: "The scans were kept. Show them in Finder to add them again."
            }
        return [actionError, note].compactMap(\.self).joined(separator: "\n\n")
    }

    /// The scan path's `mutate`: runs `each` — `ingestEach` or `attachEach`,
    /// whose outcomes line up with `urls` — deletes the scans that landed, inside
    /// the write, and keeps the rest.
    ///
    /// Owns its "no archive" case rather than leaving it to `mutate`, whose early
    /// return would skip the work closure — and with it any decision about the
    /// scan at all.
    private func consumeScans<Outcome: FileOutcome>(
        _ urls: [URL], unopened: String,
        each: @escaping @Sendable (Archive) -> [Outcome],
        commit: @escaping @MainActor ([Outcome]) -> Void
    ) {
        guard archive != nil else {
            actionError = unopened
            keepScans(urls)
            return
        }
        mutate(unopened: unopened) { archive in
            let outcomes = each(archive)
            var kept: [URL] = []
            for (url, outcome) in zip(urls, outcomes) {
                if outcome.failure == nil { Self.discardScan(at: url) } else { kept.append(url) }
            }
            return (outcomes: outcomes, kept: kept)
        } commit: { [self] result in
            commit(result.outcomes)
            if !result.kept.isEmpty { keepScans(result.kept) }
        }
    }

    /// Adds `urls` to the scans the alert offers.
    private func keepScans(_ urls: [URL]) {
        keptScans += urls.filter { !keptScans.contains($0) }
    }

    /// Deletes a scan that landed, and the per-capture folder
    /// `ContinuityScanner` wrote it into. `rmdir` only removes an empty
    /// directory, so a URL that did not come from the scanner keeps its parent.
    private nonisolated static func discardScan(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        rmdir(url.deletingLastPathComponent().path)
    }

    /// Presents the integrity-report sheet (File ▸ Verify Integrity…). The sheet
    /// runs the verification itself, off this synchronous call.
    func beginVerifyIntegrity() {
        isShowingIntegrityReport = true
    }

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

    // MARK: - Trash (recoverable deletes)

    /// Presents the trash sheet (File ▸ Show Trash…).
    func beginShowTrash() {
        isShowingTrash = true
    }

    /// The artifacts currently in the archive's `.trash/`, most recently deleted
    /// first — what the trash sheet lists. Empty when no archive is open.
    func trashedArtifacts() -> [TrashedArtifact] {
        archive?.trashedArtifacts() ?? []
    }

    /// Restores a trashed artifact back into the archive (the trash sheet's Restore
    /// action) and refreshes the browse list. **Undoable**: ⌘Z re-deletes it (back to
    /// the Trash), ⌘⇧Z restores again — the same delete↔restore ping-pong as the
    /// sidebar Delete, so the undo stack stays coherent with out-of-band recovery from
    /// the sheet (undoing a delete and restoring from the sheet are two doors to one
    /// store). Without this, a restore would leave the original delete's undo pointing
    /// at an entry the restore already consumed.
    func restoreFromTrash(_ uid: ArtifactID) {
        mutate(unopened: "Open an archive before restoring.") { archive in
            _ = try archive.restoreFromTrash(uid)
        } commit: { [self] _ in
            registerArtifactRedelete(of: uid, actionName: "Restore Artifact")
            bumpAndRefresh()
        }
    }

    /// Permanently deletes one trashed artifact (the per-row "Delete Permanently"
    /// action) — irreversible; the bytes leave the package.
    func deleteFromTrash(_ uid: ArtifactID) {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.deleteFromTrash(uid)
        } commit: { _ in
        }
    }

    /// Permanently empties the trash (the sheet's "Empty Trash" action) —
    /// irreversible; clears both trashed artifacts **and** trashed files. Any
    /// in-session ⌘Z that still points at a now-purged entry no-ops gracefully if
    /// invoked (see `registerFileRevert` / `registerArtifactRestore`).
    func emptyTrash() {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.emptyTrash()
        } commit: { _ in
        }
    }

    /// The files currently in the archive's `.trash/`, most recently detached first —
    /// the trash sheet's Files section. Empty when no archive is open.
    func trashedFiles() -> [TrashedFile] {
        archive?.trashedFiles() ?? []
    }

    /// Restores a trashed file back onto the artifact it was detached from (the trash
    /// sheet's per-file Restore). **Undoable** via the same `revert` ping-pong as a
    /// detach: modeling the restore as an `.added` change means ⌘Z re-detaches it (back
    /// to the Trash) and ⌘⇧Z restores again — so the in-session undo stack and the
    /// sheet stay two doors to one store (mirrors artifact `restoreFromTrash`).
    func restoreFile(_ trashed: TrashedFile) {
        mutate(unopened: "Open an archive before restoring.") { archive in
            try archive.restoreFile(trashed.uid)
        } commit: { [self] entry in
            registerFileRevert(
                FileChange(artifactID: trashed.artifactUID, operation: .added(entry)),
                actionName: "Restore File")
            bumpAndRefresh()
        }
    }

    /// Permanently deletes one trashed file (the per-row "Delete Permanently") —
    /// irreversible; the bytes leave the package.
    func deleteFileFromTrash(_ uid: FileID) {
        mutate(unopened: "Open an archive before emptying the Trash.") { archive in
            try archive.deleteFileFromTrash(uid)
        } commit: { _ in
        }
    }

    /// Presents the importer in attach mode: picked files are attached to the
    /// artifact `id` under the default role (the per-artifact "Attach File…"
    /// action in the detail view). The role is corrected afterward via the
    /// per-file menu (slice 32).
    func beginAttach(to id: ArtifactID) {
        importMode = .attach(to: id)
        isImporterPresented = true
    }

    /// Presents the importer in replace mode: the picked file's content overwrites
    /// the existing file `fileID` on artifact `artifactID`, preserving its uid/path
    /// (the per-file "Replace…" action). Undoable.
    func beginReplace(fileID: FileID, artifactID: ArtifactID) {
        importMode = .replace(fileID: fileID, artifactID: artifactID)
        isImporterPresented = true
    }

    /// Routes a completed importer selection to new-artifact ingest,
    /// attach-to-existing, or replace, per the mode set when the importer was presented.
    func handleImport(_ urls: [URL]) {
        switch importMode {
        case .addMedia:
            ingest(urls)
        case .attach(let id):
            attach(urls, to: id)
        case .replace(let fileID, let artifactID):
            if let url = urls.first { replaceFile(fileID, in: artifactID, with: url) }
        }
    }

    /// Fetches the full `Artifact` record behind a browse summary, for editing.
    /// The browse list carries only the derived `ArtifactSummary`; the editor
    /// needs the whole record (notes, language, events, …). `nil` if the archive
    /// isn't open or the id is unknown.
    func fullArtifact(_ id: ArtifactID) -> Artifact? {
        archive?.artifact(withID: id)
    }

    /// The on-disk URL of an attached file's bytes inside the package, for the
    /// **inline** (in-process) Quick Look preview. `nil` if nothing is open or the
    /// id is unknown. Read-only — see the engine's `fileURL(of:in:)`.
    func fileURL(of fileID: FileID, in artifactID: ArtifactID) -> URL? {
        archive?.fileURL(of: fileID, in: artifactID)
    }

    /// Writes a **copy** of an attached file to `destination` (the "Save a Copy…"
    /// export). Never hands out the original inside the package. Errors → `actionError`.
    func exportFile(_ fileID: FileID, in artifactID: ArtifactID, to destination: URL) {
        guard let source = fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            actionError = describe(error)
        }
    }

    /// A session-temp **copy** of an attached file under `originalName`, for handing
    /// to another process — "Open in Default App" or a pop-out preview window — so
    /// the package original is never exposed (an external app could otherwise mutate
    /// package contents and desync the manifest/index). `nil` on failure (which also
    /// sets `actionError`). Copies are namespaced by file id under the temp dir, so
    /// reopening the same file reuses one path.
    func temporaryCopy(of fileID: FileID, in artifactID: ArtifactID, originalName: String) -> URL? {
        guard let source = fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return nil
        }
        let name = originalName.isEmpty ? source.lastPathComponent : originalName
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GeneaLogicPreview", isDirectory: true)
            .appendingPathComponent(fileID.raw, isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            actionError = describe(error)
            return nil
        }
    }

    /// Re-runs the metadata extractor against an **already-stored** file on demand
    /// and drops any embedded metadata into the session suggestion cache for its
    /// artifact (`capturedMetadata`) — the on-demand counterpart to ingest-time
    /// capture, lifting the limit that suggestions only ever appeared for files
    /// added *this* session.
    ///
    /// Nothing is written to the record: the captured values stay read-only
    /// suggestions (ARCHITECTURE.md §6.4, the scan-date trap), promoted into an
    /// `Event`/`Location` only through the human-confirmed Apply step. Reads the
    /// package file directly (the app holds the archive's security scope). A file
    /// with no extractable metadata reports it via the benign `actionInfo`.
    func scanFileForMetadata(_ fileID: FileID, in artifactID: ArtifactID, originalName: String) {
        guard let archive else { return }
        guard let extractor = MetadataExtractors.makeDefault() else {
            actionError = "Metadata extraction isn't available on this platform."
            return
        }
        guard let url = archive.fileURL(of: fileID, in: artifactID) else {
            actionError = "Couldn't locate that file in the archive."
            return
        }
        do {
            let embedded = try extractor.extract(from: url)
            if embedded.isEmpty {
                showInfo(
                    "No embedded metadata found in “\(originalName).”",
                    title: "Scan for Metadata")
            } else {
                capturedMetadata[artifactID] = embedded
            }
        } catch {
            actionError = describe(error)
        }
    }

    /// Applies `mutate` to an artifact's record through the engine — the **sole**
    /// in-place writer — then refreshes the browse list so the change is visible
    /// (a renamed title, a changed tier, …). The selection is keyed by
    /// `ArtifactID`, so it survives the refresh. Errors surface as `actionError`.
    ///
    /// Provenance is intentionally left untouched: an `Artifact`'s `provenance`
    /// records its *creation*, and `updateMetadata` only bumps `schemaVersion`.
    /// Callers that append a new assertion (the apply-suggestion path) do so under
    /// the artifact's existing human/asserted provenance umbrella — the model has
    /// no per-event provenance, and a human-reviewed suggestion is an honest human
    /// assertion, not a machine one (ARCHITECTURE.md §6.4).
    ///
    /// The edit is **undoable**: the full record is snapshotted before and after,
    /// and an inverse registered on the window's `UndoManager` under `actionName`
    /// (so the Edit menu reads "Undo \(actionName)"). Undo/redo are themselves
    /// ordinary engine writes that restore a snapshot — the engine stays the sole
    /// writer (§7).
    /// **`edit` is `@Sendable` because it runs off the main actor** (52), applied
    /// to the record the engine reads *under the archive lock*. Keeping it there
    /// rather than applying it to a main-actor snapshot is the point: a snapshot
    /// taken before a five-second wait for another process, then written back
    /// wholesale, would silently clobber whatever that process committed in the
    /// meantime. Every call site passes a closure over value types, so the
    /// annotation costs nothing.
    ///
    /// **The undo snapshot is taken on the write queue, for the same reason**
    /// (52's `/code-review`). Reading `before` on the main actor read it *at
    /// enqueue time*, so two edits to one record issued back to back both
    /// snapshotted the original: the second edit's undo restored a state that
    /// skipped the first, and one ⌘Z silently discarded two edits. Inside `work`
    /// the serial queue guarantees the first edit has already committed.
    func updateMetadata(
        of id: ArtifactID, actionName: String = "Edit",
        _ edit: @escaping @Sendable (inout Artifact) -> Void
    ) {
        guard archive?.artifact(withID: id) != nil else {
            actionError =
                archive == nil
                ? "Open an archive before editing." : "Couldn't load this artifact to edit."
            return
        }
        mutate(unopened: "Open an archive before editing.") { archive in
            let before = archive.artifact(withID: id)
            try archive.updateMetadata(of: id, edit)
            return (before, archive.artifact(withID: id))
        } commit: { [self] before, after in
            if let before, let after {
                registerArtifactRestore(
                    of: id, to: before, redoingTo: after, actionName: actionName)
            }
            bumpAndRefresh()
        }
    }

    /// Registers an undo that restores artifact `id` to the `target` snapshot, and
    /// (when invoked) re-registers the symmetric redo to `redoTarget` — so undo and
    /// redo ping-pong indefinitely. Restoring a whole-record snapshot is safe for
    /// metadata edits: they never touch `files`, so the snapshot's file list always
    /// matches what's on disk (file *content* changes go through `revert`, not here).
    private func registerArtifactRestore(
        of id: ArtifactID, to target: Artifact, redoingTo redoTarget: Artifact, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerArtifactRestore(
                of: id, to: redoTarget, redoingTo: target, actionName: actionName)
            model.mutate(unopened: "Open an archive before editing.") { archive in
                try archive.updateMetadata(of: id) { $0 = target }
            } commit: { _ in
                model.bumpAndRefresh()
            }
        }
    }

    /// Replaces the content of `fileID` on `artifactID` with the file at `url`
    /// (the per-file "Replace…" action, via the importer), undoably.
    /// The security scope is opened and closed **inside** `work` (52): the copy
    /// now happens on the write queue, so a `defer` out here would drop the scope
    /// while the copy is still reading the source.
    private func replaceFile(_ fileID: FileID, in artifactID: ArtifactID, with url: URL) {
        mutate(unopened: "Open an archive before replacing files.") { archive in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try archive.replaceFile(fileID, in: artifactID, copyingFrom: url)
        } commit: { [self] change in
            registerFileRevert(change, actionName: "Replace File")
            bumpAndRefresh()
        }
    }

    /// Detaches `fileID` from `artifactID` (the per-file "Delete" action), undoably —
    /// the engine stages the file's bytes so the deletion can be reverted.
    func detachFile(_ fileID: FileID, from artifactID: ArtifactID) {
        mutate(unopened: "Open an archive before deleting files.") { archive in
            try archive.detachFile(fileID, in: artifactID)
        } commit: { [self] change in
            registerFileRevert(change, actionName: "Delete File")
            bumpAndRefresh()
        }
    }

    /// Changes `fileID`'s role on `artifactID` (the per-file Role menu, slice 32),
    /// undoably. A no-op change (the role is already `role`) does nothing and
    /// registers no undo step. Content, uid, and path are untouched.
    func setFileRole(_ fileID: FileID, in artifactID: ArtifactID, to role: FileRole) {
        mutate(unopened: "Open an archive before changing a file’s role.") { archive in
            try archive.setFileRole(fileID, in: artifactID, to: role)
        } commit: { [self] prior in
            guard prior != role else { return }
            registerFileRoleRestore(fileID, in: artifactID, to: prior, redoingTo: role)
            bumpAndRefresh()
        }
    }

    /// Registers an undo that sets `fileID`'s role back to `role`, then re-registers
    /// the symmetric redo (`redoRole`) — so a role change undoes/redoes indefinitely,
    /// like the metadata and file-revert paths. If the file or artifact has since
    /// gone out-of-band, the step no-ops **gracefully** (a benign notice, not an
    /// error), with the stack advancing.
    private func registerFileRoleRestore(
        _ fileID: FileID, in artifactID: ArtifactID, to role: FileRole, redoingTo redoRole: FileRole
    ) {
        registerUndoStep(actionName: "Change File Role") { model in
            // Counterpart first — see *Undo across the actor hop* above.
            model.registerFileRoleRestore(fileID, in: artifactID, to: redoRole, redoingTo: role)
            model.mutate(unopened: "Open an archive before changing a file’s role.") { archive in
                _ = try archive.setFileRole(fileID, in: artifactID, to: role)
            } commit: { _ in
                model.bumpAndRefresh()
            } failure: { error in
                switch error {
                case ArchiveError.fileNotFound, ArchiveError.artifactNotFound:
                    model.showInfo(
                        "That file is no longer in the archive, so its role can’t be changed back.",
                        title: "Can’t Change Role")
                    return true
                default:
                    return false
                }
            }
        }
    }

    /// Registers an undo that reverts `change` through the engine and re-registers
    /// the inverse for redo (`Archive.revert` returns the opposite change), so file
    /// add/remove/replace undo and redo ping-pong like the metadata path above.
    ///
    /// A detached file's bytes live in the persistent `.trash/` (not in-session temp),
    /// so an undo/redo step can find its bytes **permanently removed** (Empty Trash /
    /// Delete Permanently from the sheet) or its file/artifact gone out-of-band. Those
    /// no-op **gracefully**: a benign notice (not an error), with no inverse
    /// re-registered, so the stack simply advances — exactly like the artifact
    /// delete/restore path (the menu title can't be relabeled after the fact, NSUndoManager).
    private func registerFileRevert(_ change: FileChange, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            model.revertFile(change, actionName: actionName)
        }
    }

    /// Carries a counterpart's payload from the `commit` that computes it to the
    /// undo step that was registered before it existed.
    ///
    /// **The file paths are the one place the general rule needs help.** Every
    /// other counterpart is known up front (a snapshot, a uid, a captured
    /// record), so it can be registered synchronously with its payload in hand.
    /// A file revert's inverse is *computed by the engine* — reverting a detach
    /// re-attaches the bytes and mints a fresh trash entry for the redo to find,
    /// and nothing can predict that id. Registering after the await would file
    /// the step on the wrong stack (see *Undo across the actor hop*), so the
    /// registration goes up on time and reads its payload from here when it runs.
    private final class PendingFileChange {
        var change: FileChange?
    }

    /// The artifact-deletion twin of `PendingFileChange`: re-deleting an artifact
    /// stages a *new* folder in the trash, so the restore that reverses it can't
    /// be described until the delete has run.
    private final class PendingDeletion {
        var deletion: ArtifactDeletion?
    }

    /// Reverts `change` and registers the step that reverses *that* — the body
    /// behind both a fresh registration and a promised one, so the ping-pong has
    /// one implementation rather than two that must agree.
    private func revertFile(_ change: FileChange, actionName: String) {
        let inverse = PendingFileChange()
        // Counterpart first — see *Undo across the actor hop* above.
        registerFileRevert(pending: inverse, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.revert(change)
        } commit: { [self] produced in
            inverse.change = produced
            bumpAndRefresh()
        } failure: { [self] error in
            switch error {
            case ArchiveError.fileTrashEntryNotFound:
                showInfo(
                    "That file was permanently removed from the Trash, so it can’t be brought back.",
                    title: "Can’t Restore File")
            case ArchiveError.artifactNotFound:
                showInfo(
                    "The artifact this file belonged to no longer exists, so the file can’t be restored.",
                    title: "Can’t Restore File")
            case ArchiveError.fileNotFound:
                showInfo(
                    "That file is no longer attached to the artifact.", title: "Already Removed")
            default:
                return false
            }
            return true
        }
    }

    /// Registers the reverse of a revert whose payload is still being computed.
    /// If the revert failed, the promise stays empty and this step no-ops — the
    /// same graceful advance the purged-trash cases already take.
    private func registerFileRevert(pending: PendingFileChange, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            guard let change = pending.change else { return }
            model.revertFile(change, actionName: actionName)
        }
    }

    /// Deletes the artifact `id` and its files (the sidebar "Delete Artifact"
    /// action), undoably — the engine stages the whole folder so the deletion can be
    /// reverted. If the deleted artifact was the selection, the detail pane falls
    /// back to its placeholder on its own (the id stops resolving).
    func deleteArtifact(_ id: ArtifactID) {
        mutate(unopened: "Open an archive before deleting.") { archive in
            try archive.removeArtifact(id)
        } commit: { [self] deletion in
            registerArtifactRestore(of: id, deletion: deletion, actionName: "Delete Artifact")
            bumpAndRefresh()
        }
    }

    /// Registers an undo that **restores** a deleted artifact, then registers the
    /// symmetric redo (delete again, producing a fresh staged folder) — the undo
    /// side of a *deletion*. Undo and redo ping-pong as in the file/metadata paths.
    /// `actionName` names the originating action in the Edit menu ("Delete Artifact").
    private func registerArtifactRestore(
        of id: ArtifactID, deletion: ArtifactDeletion, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            model.restoreArtifact(deletion, of: id, actionName: actionName)
        }
    }

    /// The promised-payload variant, for a redelete whose staged folder isn't
    /// known until the delete lands. An empty promise means the delete failed, so
    /// there is nothing to restore and the step no-ops — see `PendingFileChange`
    /// for why this shape exists at all.
    private func registerArtifactRestore(
        of id: ArtifactID, pending: PendingDeletion, actionName: String
    ) {
        registerUndoStep(actionName: actionName) { model in
            guard let deletion = pending.deletion else { return }
            model.restoreArtifact(deletion, of: id, actionName: actionName)
        }
    }

    /// Restores `deletion` and registers the redelete that reverses it — the body
    /// both registrations above run, so the ping-pong has one implementation.
    private func restoreArtifact(
        _ deletion: ArtifactDeletion, of id: ArtifactID, actionName: String
    ) {
        // Counterpart first — see *Undo across the actor hop* above.
        registerArtifactRedelete(of: id, actionName: actionName)
        mutate(unopened: "Open an archive before undoing.") { archive in
            try archive.restoreArtifact(deletion)
        } commit: { [self] _ in
            bumpAndRefresh()
        } failure: { [self] error in
            // The artifact's bytes were permanently removed (Empty Trash / Delete
            // Permanently) after this undo was registered — there's nothing to bring
            // back. No-op gracefully with a benign notice, not an error. The redo is
            // on the stack (it had to go up before the await), and re-deleting an
            // artifact that was never restored no-ops just as gracefully.
            guard case ArchiveError.trashEntryNotFound = error else { return false }
            showInfo(
                "That artifact was permanently removed from the Trash, so it can’t be "
                    + "brought back.", title: "Can’t Restore Artifact")
            return true
        }
    }

    /// Registers an undo that **deletes** artifact `id`, then registers the
    /// symmetric redo (restore it) — the undo side of an *addition* (and the redo
    /// side of a deletion). `ingest` calls this directly so adding a new artifact is
    /// undoable: the first ⌘Z removes it (the engine stages its folder so it can come
    /// back), ⌘⇧Z restores it (uid faithful). `actionName` names it in the Edit menu
    /// ("Add Artifact" for ingest, "Delete Artifact" when reached via the delete redo).
    private func registerArtifactRedelete(of id: ArtifactID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            // This is the one counterpart shape that *must* wait for its payload
            // (the fresh `ArtifactDeletion`), so it takes the same promise route
            // as the file paths.
            let deletion = PendingDeletion()
            model.registerArtifactRestore(of: id, pending: deletion, actionName: actionName)
            model.mutate(unopened: "Open an archive before undoing.") { archive in
                try archive.removeArtifact(id)
            } commit: { produced in
                deletion.deletion = produced
                model.bumpAndRefresh()
            } failure: { error in
                // The artifact is already gone (e.g. removed out-of-band) — nothing to
                // delete. No-op gracefully and let the stack advance.
                guard case ArchiveError.artifactNotFound = error else { return false }
                model.showInfo(
                    "That artifact is no longer in the archive.", title: "Already Removed")
                return true
            }
        }
    }

    /// Ingests `urls` (from `.fileImporter` or drag-and-drop) into the open
    /// archive: each becomes a new artifact with the source file attached as its
    /// preservation master.
    ///
    /// Errors for individual files are collected into `actionError` (the most
    /// recent one wins) without stopping the rest of the batch. Refreshes the
    /// artifact list once at the end.
    ///
    /// **Undoable as one step.** Each created artifact registers a "delete me" undo
    /// (`registerArtifactRedelete`); because the whole batch runs in a single
    /// run-loop event, the window's `UndoManager` groups those registrations, so one
    /// ⌘Z removes every artifact the call added and ⌘⇧Z brings them all back (uid
    /// faithful — the engine stages each folder). This is the same event-grouping the
    /// multi-file Attach path relies on.
    /// **The whole batch is one `mutate`** (52), not one per file: the undo
    /// registrations have to land in a single run-loop turn for `NSUndoManager`
    /// to group them, and a hop per file would scatter them across turns — one
    /// ⌘Z per file instead of one for the add. The per-file error collection
    /// moves into the work closure with them and is reported at the end.
    func ingest(_ urls: [URL]) {
        let extractor = MetadataExtractors.makeDefault()
        mutate(unopened: "Open an archive before adding media.") { archive in
            Self.ingestEach(urls, into: archive, extractor: extractor)
        } commit: { [self] outcomes in
            commitIngest(outcomes)
        }
    }

    /// `ingest`'s work: one outcome per URL, **in `urls` order** — the scan path
    /// pairs them back up by position (`consumeScans`).
    private nonisolated static func ingestEach(
        _ urls: [URL], into archive: Archive, extractor: (any MetadataExtractor)?
    ) -> [IngestOutcome] {
        var outcomes: [IngestOutcome] = []
        for url in urls {
            // fileImporter/drag URLs may be security-scoped; the archive needs to
            // read the source file to copy it in.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Set once the artifact exists, so a file that then fails to attach
            // still reports the artifact it left behind (slice 67's
            // `/code-review`): without it, commit never registered the add's
            // undo, and an empty artifact sat in the archive with no ⌘Z.
            var added: ArtifactID?
            do {
                let title = url.deletingPathExtension().lastPathComponent
                let artifact = try archive.addArtifact(
                    // **No source tier.** Ingest cannot know the genre of a file that
                    // was just dragged in, and until 46b it asserted `compiled` anyway
                    // — the lowest tier, and a claim that an original held as an image
                    // is somebody's conclusion. Absent means unstated; the sidebar
                    // surfaces the count so the debt is visible rather than silently
                    // wrong.
                    ArtifactDraft(title: title, mediaType: .image))
                added = artifact.uid
                let attached = try archive.attachFile(
                    copyingFrom: url, to: artifact.uid, role: Self.defaultFileRole,
                    extractor: extractor)
                outcomes.append(
                    .init(artifact: artifact.uid, embedded: attached.embeddedMetadata))
            } catch {
                outcomes.append(.init(artifact: added, failure: error))
            }
        }
        return outcomes
    }

    /// `ingest`'s commit. An artifact whose file failed to attach is registered
    /// and selected like any other — it exists, so it must be undoable — and the
    /// failure is reported beside it.
    private func commitIngest(_ outcomes: [IngestOutcome]) {
        var created: ArtifactID?
        for outcome in outcomes {
            if let failure = outcome.failure { actionError = describe(failure) }
            guard let id = outcome.artifact else { continue }
            if let embedded = outcome.embedded, !embedded.isEmpty {
                capturedMetadata[id] = embedded
            }
            // Make the add undoable: the first undo deletes this artifact (its
            // folder, including the file just attached), redo restores it.
            registerArtifactRedelete(of: id, actionName: "Add Artifact")
            created = id
        }
        bumpAndRefresh()
        // Select the new artifact so its document/inspector shows at once (slice
        // 29). A multi-file add lands on the last one created. Only set when a
        // create actually succeeded, so a wholly-failed ingest leaves selection be.
        if let created { lastCreatedArtifact = created }
    }

    /// What the scan path needs from either outcome type: whether the file landed.
    /// `nonisolated` like the outcomes themselves — it is read inside the write.
    private nonisolated protocol FileOutcome: Sendable {
        var failure: Error? { get }
    }

    /// One file's result from a batch ingest, carried back to the main actor so
    /// the undo registration and the error report happen there, together.
    ///
    /// `nonisolated`: it is *constructed* off-main, inside the work closure, and
    /// only read on the main actor. A pure value type, already `Sendable`.
    private nonisolated struct IngestOutcome: FileOutcome {
        var artifact: ArtifactID?
        var embedded: EmbeddedMetadata?
        var failure: Error?

        init(artifact: ArtifactID, embedded: EmbeddedMetadata?) {
            self.artifact = artifact
            self.embedded = embedded
        }
        /// `artifact` is the one created before the failure, if any.
        init(artifact: ArtifactID?, failure: Error) {
            self.artifact = artifact
            self.failure = failure
        }
    }

    /// Attaches `urls` to the existing artifact `id` under the default role
    /// (`Self.defaultFileRole`, slice 32). Mirrors `ingest`'s per-file error
    /// handling and security scoping, but adds files to an artifact instead of
    /// minting new ones.
    ///
    /// Any embedded metadata the newly attached file carries is captured into the
    /// session cache for `id` (last file wins) — still surfaced read-only, never
    /// auto-applied (ARCHITECTURE.md §6.4).
    /// One `mutate` for the whole batch, for the same undo-grouping reason as
    /// `ingest`.
    private func attach(_ urls: [URL], to id: ArtifactID) {
        let extractor = MetadataExtractors.makeDefault()
        mutate(unopened: "Open an archive before attaching files.") { archive in
            Self.attachEach(urls, to: id, in: archive, extractor: extractor)
        } commit: { [self] outcomes in
            commitAttach(outcomes, to: id)
        }
    }

    /// `attach`'s work: one outcome per URL, in `urls` order (see `ingestEach`).
    private nonisolated static func attachEach(
        _ urls: [URL], to id: ArtifactID, in archive: Archive,
        extractor: (any MetadataExtractor)?
    ) -> [AttachOutcome] {
        var outcomes: [AttachOutcome] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                let attached = try archive.attachFile(
                    copyingFrom: url, to: id, role: Self.defaultFileRole,
                    extractor: extractor)
                outcomes.append(
                    .init(entry: attached.entry, embedded: attached.embeddedMetadata))
            } catch {
                outcomes.append(.init(failure: error))
            }
        }
        return outcomes
    }

    /// `attach`'s commit.
    private func commitAttach(_ outcomes: [AttachOutcome], to id: ArtifactID) {
        for outcome in outcomes {
            if let failure = outcome.failure { actionError = describe(failure) }
            guard let entry = outcome.entry else { continue }
            if let embedded = outcome.embedded, !embedded.isEmpty {
                capturedMetadata[id] = embedded
            }
            // Attaching is undoable: model it as an `.added` change whose revert
            // detaches the file (staging its bytes for redo).
            registerFileRevert(
                FileChange(artifactID: id, operation: .added(entry)),
                actionName: "Attach File")
        }
        bumpAndRefresh()
    }

    /// One file's result from a batch attach — the `ingest` twin.
    /// Constructed off-main and read on the main actor, exactly like
    /// `IngestOutcome` above — `nonisolated` for the same reason.
    private nonisolated struct AttachOutcome: FileOutcome {
        var entry: FileEntry?
        var embedded: EmbeddedMetadata?
        var failure: Error?

        init(entry: FileEntry, embedded: EmbeddedMetadata?) {
            self.entry = entry
            self.embedded = embedded
        }
        init(failure: Error) { self.failure = failure }
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
            // Counterpart first — see *Undo across the actor hop* above.
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
    private func registerPersonRestore(_ person: Person, actionName: String) {
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
        // Counterpart first — see *Undo across the actor hop* above.
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
    private func registerPersonRedelete(of id: PersonID, actionName: String) {
        registerUndoStep(actionName: actionName) { model in
            let removed = PendingPerson()
            // Counterpart first — see *Undo across the actor hop* above.
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
        // Counterpart first — see *Undo across the actor hop* above.
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
    private func registerRelationshipRestore(_ relationship: Relationship, actionName: String) {
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
    private func registerRelationshipRedelete(of id: RelationshipID, actionName: String) {
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

    /// The Review section's worklist: every unresolved mention in the archive, with its
    /// ranked candidates and the record context needed to judge them (§4.6, slice 45e).
    ///
    /// **Recomputed, never stored on disk** — the mini-phase's governing decision, not an
    /// implementation shortcut: nothing is written until a human confirms or rejects, so
    /// there is no suggestion record to go stale and a re-run always reflects the archive
    /// as it is now. Held here (rather than in a view) because the sidebar and the detail
    /// pane read the same list and must agree about it.
    private(set) var reviewItems: [ReviewItem] = []

    /// The Review section's second lane (slice 45i): persons with evidence still waiting to
    /// be promoted into facts. Rebuilt by the same `refreshReviewWorklist()` sweep — the two
    /// lanes share one list, so they must never be refreshed at different moments.
    private(set) var factItems: [FactReviewItem] = []

    /// Whether `refreshReviewWorklist()` has ever run in this window — the difference
    /// between "nothing to review" and "not looked yet", which are different empty states.
    private(set) var hasLoadedReviewWorklist = false

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

    /// The Review section's **fourth lane**: relationships the archive's records state, or
    /// unambiguously imply, that `conclusions/` does not yet assert.
    ///
    /// Rebuilt by the same `refreshReviewWorklist()` sweep as the names and facts lanes — a
    /// linear read, unlike the duplicates scan — because a confirm anywhere in the app can
    /// change it: resolving one more mention is exactly what makes an edge promotable.
    private(set) var relationshipItems: [RelationshipReviewItem] = []

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

    /// The Review section's **third** lane: pairs of concluded persons that may be one
    /// person (45j's `duplicateCandidates`), with the reasoning behind each.
    ///
    /// Held separately from `reviewItems`/`factItems` and refreshed separately, because it
    /// is the one lane whose sweep is not linear — see `refreshDuplicateCandidates()`.
    private(set) var duplicateItems: [DuplicateReviewItem] = []

    /// Whether a duplicate scan is running right now. Drives the lane's progress
    /// affordance — this sweep is the only one in the app a user can be made to wait for.
    private(set) var isScanningDuplicates = false

    /// Whether the scan has ever completed in this window: "no duplicates" and "not looked
    /// yet" are different empty states, exactly as `hasLoadedReviewWorklist` distinguishes
    /// them for the other two lanes.
    private(set) var hasScannedDuplicates = false

    /// The in-flight scan, cancelled when a newer one starts so a slow sweep can never
    /// overwrite a fresher result.
    private var duplicateScanTask: Task<Void, Never>?

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
    private func refreshDuplicateCandidatesIfShown() {
        guard hasScannedDuplicates || isScanningDuplicates else { return }
        refreshDuplicateCandidates()
    }

    /// Drops every duplicates row naming `person`, *now*, ahead of the re-scan.
    ///
    /// The scan is asynchronous and deliberately leaves the old rows up while it runs (so
    /// Refresh doesn't flash the lane empty), which would leave a row offering a merge of
    /// a person who no longer exists for as long as the sweep takes. These rows are known
    /// dead the instant the person goes, so they don't wait for the answer.
    private func dropDuplicateRows(naming person: PersonID) {
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

    private func registerDismissalRestore(_ dismissal: Dismissal, actionName: String) {
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

    /// Requests a cross-tab jump to the People tab with `id` selected (the resolved-
    /// mention chip's tap). Sets the one-shot `pendingPersonNavigation` intent the
    /// container observes.
    func navigateToPerson(_ id: PersonID) {
        pendingPersonNavigation = id
    }

    /// Requests a cross-tab jump to the Artifacts tab with `id` selected (a person
    /// Sources row's tap, slice 42b — the mirror of `navigateToPerson`). Sets the
    /// one-shot `pendingArtifactNavigation` intent the container observes.
    func navigateToArtifact(_ id: ArtifactID) {
        pendingArtifactNavigation = id
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
    private func registerLinkRestore(_ link: EvidenceLink, actionName: String) {
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

    /// Converts a thrown error into a user-facing message. `ArchiveError` already
    /// has a friendly `description`; other errors fall back to `String(describing:)`.
    private func describe(_ error: Error) -> String {
        if let archiveError = error as? ArchiveError {
            return archiveError.description
        }
        return String(describing: error)
    }
}

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

    // MARK: - Stored state, by domain
    //
    // Swift allows no stored properties in an extension, so every one lives here,
    // grouped by the domain file (`ArchiveModel+<Domain>.swift`) that uses it.

    // MARK: Artifacts

    /// The current search query, bound to the sidebar `.searchable`. Empty means
    /// "no text filter".
    var searchText: String = ""

    /// The set of tags the toolbar Filter menu has selected (lowercased for
    /// case-insensitive matching). Empty means "no tag filter". Selected tags
    /// AND-combine with each other and with `searchText` (the engine's
    /// `ArtifactQuery` applies both facets in one pass, §5.1).
    var selectedTags: Set<String> = []

    /// Results of the active filter (text and/or tags), recomputed by
    /// `applyFilters()`. Only meaningful while `isFiltering`.
    var filterResults: [ArtifactSummary] = []

    /// The field the browse list is sorted by, driven by the sidebar Sort menu.
    /// In-memory only (not restored across relaunch — same deliberate scoping as
    /// search/filter, slice 18). Default `.title` reproduces the engine's existing
    /// order, so the list looks unchanged until the user picks a sort.
    var sortKey: ArtifactSortKey = .title

    /// Sort direction. `true` = ascending (A→Z / oldest / earliest).
    var sortAscending: Bool = true

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
    var capturedMetadata: [ArtifactID: EmbeddedMetadata] = [:]

    /// Scans a refused write kept, offered by the error alert's *Show in
    /// Finder*. Cleared only when the user dismisses the alert.
    ///
    /// **Accumulates** (cloud review of 67–71): scans arrive one capture at a
    /// time, so a second refusal before the first alert is dismissed used to
    /// replace the first capture's entry — and this offer is the only way back
    /// to a file in a folder the user cannot find. For the same reason a later
    /// error that has nothing to do with scans does not clear it; the alert
    /// still says the scans are kept (`errorMessage`), which stays true.
    var keptScans: [URL] = []

    // MARK: People

    /// The People-tab browse list: every concluded person, sorted by display name.
    /// Loaded by `load()` and reloaded by `refresh()` alongside the artifacts.
    var persons: [PersonSummary] = []

    /// The People-tab search query, bound to that sidebar's `.searchable`. Empty
    /// means "no filter"; when non-blank, `applyPersonFilter()` runs it through the
    /// engine's `persons(matching:)` (name search across all of a person's names).
    var personSearchText: String = ""

    /// Results of the active people search, recomputed by `applyPersonFilter()`.
    /// Only meaningful while `isFilteringPeople`.
    var personFilterResults: [PersonSummary] = []

    /// One-shot "select this newly-created person" intent (the People analog of
    /// `lastCreatedArtifact`). `createPerson` sets it; the People tab observes it,
    /// moves the scene-stored selection there, and clears it back to `nil`.
    var lastCreatedPerson: PersonID?

    // MARK: Integrity

    /// What `Archive.standingFindings()` last reported: records that could not be
    /// read, and whether a write is known to have died. Refreshed wherever the
    /// browse lists are, because it costs a `SELECT` over a tiny table — the
    /// point of the engine call is that this is affordable on every refresh.
    ///
    /// The expensive question (does every tracked file still match its hash?)
    /// stays where it was: Verify Integrity, on demand.
    var standingFindings = Archive.StandingFindings()

    /// What `Archive.sweepFileSizes()` last found: tracked files that are gone, or
    /// the wrong length. `nil` until the first sweep finishes.
    ///
    /// This answers what `standingFindings` above cannot. 56 surfaces damage the
    /// archive already *knows about*, and a file deleted or truncated on disk
    /// commits nothing for it to know — which is exactly what 56's hand-test hit,
    /// and why this slice exists.
    var fileDamage: FileDamageSummary?

    /// The in-flight sweep, so a burst of refreshes drops the ones still queued
    /// rather than running all of them (see `sweepFiles` for what cancellation
    /// can and cannot do here).
    ///
    /// Readable (not settable) beyond this type only so the tests can await the
    /// real task rather than poll for its effect — the sweep is fire-and-forget in
    /// the app, since nothing waits on a banner, and a completion handle added to
    /// the production type purely for tests would be the tail wagging the dog
    /// (same call as `mutate`'s, see `AppTestSupport`).
    var fileSweepTask: Task<Void, Never>?

    /// Whether a sweep was asked for while one was already walking, so the poll
    /// owes the caller a fresh one.
    ///
    /// Without this, a mutation whose `refresh()` coalesced away would leave the
    /// banner describing the archive as it was *before* that mutation until
    /// something else asked. The poll is already running once a second and is the
    /// natural place to drain it — no self-chaining task, which would also make
    /// `fileSweepSettled()` await the wrong one of two.
    var fileSweepCoalesced = false

    /// What can be put back, by path — the answer 56's placeholder row needs
    /// before it offers anything.
    ///
    /// **A row shows the action only when there is an entry here.** Damage and
    /// repairability are different questions: the copy lives in `.index/`, so it
    /// does not survive the rebuilds that discard the database, and a record that
    /// never decoded was never in the index to begin with. Deriving the button
    /// from the damage instead would put one on rows that cannot honour it, which
    /// is the lie 56 was careful not to tell.
    var repairPlans: [String: Archive.RecordRepairPlan] = [:]

    // MARK: External changes

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
    var nextExternalChangePollDelay: Duration = externalChangePollInterval

    /// The change token this window's lists were built from. `nil` until `load()`
    /// succeeds, or whenever the token can't be read.
    var lastExternalChangeToken: Int?

    /// The staleness check in flight, if any. One at a time: it can end in a full
    /// index rebuild, and a second one behind it would rebuild what the first
    /// just did.
    var reconcileTask: Task<Void, Never>?

    /// What the window is currently saying about a change arriving from another
    /// machine — `nil` for the overwhelmingly common case of nothing arriving.
    ///
    /// **Slice 60 could already tell an arrival from damage; only the Verify
    /// panel said so**, and that is a menu item nobody opens speculatively. So a
    /// synced archive part-way through receiving a large record showed nothing at
    /// all, while every edit to the arriving record was refused with an error
    /// that came out of nowhere (`recordAwaitingDelivery`). This is that state,
    /// said out loud.
    var incomingChange: IncomingChange?

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
    /// and doubles as the gate on the poll's extra sweep
    /// (`refreshIfChangedExternally`).
    var deliveryInFlightSince: ContinuousClock.Instant?

    /// When `outstandingArrivals` last changed — the only progress this app can
    /// observe, and what the stall threshold is measured from.
    var deliveryLastProgressAt: ContinuousClock.Instant?

    /// The paths the last sweep reported as not yet arrived. Kept but never
    /// shown: it is the *change* in this set that means something, not its
    /// contents (fork b — this indicator names no files).
    var outstandingArrivals: Set<String> = []

    // MARK: Review

    /// The Review section's worklist: every unresolved mention in the archive, with its
    /// ranked candidates and the record context needed to judge them (§4.6, slice 45e).
    ///
    /// **Recomputed, never stored on disk** — the mini-phase's governing decision, not an
    /// implementation shortcut: nothing is written until a human confirms or rejects, so
    /// there is no suggestion record to go stale and a re-run always reflects the archive
    /// as it is now. Held here (rather than in a view) because the sidebar and the detail
    /// pane read the same list and must agree about it.
    var reviewItems: [ReviewItem] = []

    /// The Review section's second lane (slice 45i): persons with evidence still waiting to
    /// be promoted into facts. Rebuilt by the same `refreshReviewWorklist()` sweep — the two
    /// lanes share one list, so they must never be refreshed at different moments.
    var factItems: [FactReviewItem] = []

    /// Whether `refreshReviewWorklist()` has ever run in this window — the difference
    /// between "nothing to review" and "not looked yet", which are different empty states.
    var hasLoadedReviewWorklist = false

    /// The Review section's **fourth lane**: relationships the archive's records state, or
    /// unambiguously imply, that `conclusions/` does not yet assert.
    ///
    /// Rebuilt by the same `refreshReviewWorklist()` sweep as the names and facts lanes — a
    /// linear read, unlike the duplicates scan — because a confirm anywhere in the app can
    /// change it: resolving one more mention is exactly what makes an edge promotable.
    var relationshipItems: [RelationshipReviewItem] = []

    /// The Review section's **third** lane: pairs of concluded persons that may be one
    /// person (45j's `duplicateCandidates`), with the reasoning behind each.
    ///
    /// Held separately from `reviewItems`/`factItems` and refreshed separately, because it
    /// is the one lane whose sweep is not linear — see `refreshDuplicateCandidates()`.
    var duplicateItems: [DuplicateReviewItem] = []

    /// Whether a duplicate scan is running right now. Drives the lane's progress
    /// affordance — this sweep is the only one in the app a user can be made to wait for.
    var isScanningDuplicates = false

    /// Whether the scan has ever completed in this window: "no duplicates" and "not looked
    /// yet" are different empty states, exactly as `hasLoadedReviewWorklist` distinguishes
    /// them for the other two lanes.
    var hasScannedDuplicates = false

    /// The in-flight scan, cancelled when a newer one starts so a slow sweep can never
    /// overwrite a fresher result.
    var duplicateScanTask: Task<Void, Never>?

    // MARK: Window state (the macOS-shaped part; its methods are in `+Window`)
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

    var pendingArtifactCommand: ArtifactCommand?

    var pendingFileCommand: FileCommand?

    /// One-shot "confirm-then-delete the selected artifact" intent (Artifact ▸
    /// Delete Artifact… / ⌘⌫). The sidebar list observes it and raises the *same*
    /// confirm dialog as its own ⌫ / context-menu delete.
    var pendingArtifactDeletion = false

    /// One-shot "toggle the inspector" intent (View ▸ Show/Hide Inspector, ⌘⌥I).
    /// The detail view owns the inspector's `@SceneStorage` visibility, so it flips
    /// that and updates `inspectorVisible`.
    var pendingInspectorToggle = false

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

    /// The mode the importer was last presented in. Defaults to `.addMedia`.
    var importMode: ImportMode = .addMedia

    /// Drives the shared `.fileImporter`. Opening an archive is no longer a
    /// per-window concern (it happens before a window exists), so this importer
    /// only ever adds media or attaches files to an existing artifact.
    var isImporterPresented = false

    /// Drives the integrity-report sheet (File ▸ Verify Integrity…).
    var isShowingIntegrityReport = false

    /// Drives the trash sheet (File ▸ Show Trash…).
    var isShowingTrash = false

    /// The window's Continuity Camera scanner, set by `ContinuityCameraHost` once
    /// the view hierarchy exists. Referenced through a UI-free protocol so this
    /// model needs no AppKit import. `nil` until the host wires it (and on a window
    /// with no scanner), in which case the scan actions simply do nothing.
    weak var continuityScanner: (any ContinuityScanning)?

    // MARK: - Errors and notices

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

    /// Converts a thrown error into a user-facing message. `ArchiveError` already
    /// has a friendly `description`; other errors fall back to `String(describing:)`.
    func describe(_ error: Error) -> String {
        if let archiveError = error as? ArchiveError {
            return archiveError.description
        }
        return String(describing: error)
    }

    // MARK: - Undo

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

    // MARK: - Loading

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

    /// Marks a mutation as committed (bumping `mutationVersion` so the detail pane
    /// reloads) and refreshes the browse list. The single chokepoint every
    /// model-level write — including undo/redo — funnels through.
    ///
    /// **And now the only way in**, since `refresh()` became private: "something
    /// about this archive changed" has exactly one expression, whoever caused the
    /// change. That is enforcement rather than convention — the previous wording
    /// already called this the single chokepoint, and two call sites bypassed it
    /// anyway.
    func bumpAndRefresh() {
        mutationVersion += 1
        refresh()
    }

    /// Marks a mutation as committed **without** re-reading the archive — for a write that
    /// changes nothing any browse list or detail pane displays. Today that is the dismissal
    /// record alone (45m): it is read only by the suggestion sweeps, and the lane that
    /// wrote it updates its own row. Going through `bumpAndRefresh` would re-run the whole
    /// match worklist to reflect a change none of it can see.
    func bump() {
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
    func mutate<T: Sendable>(
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
    struct Partial<Value: Sendable>: Sendable {
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

    // MARK: - Undo across the actor hop (slice 52)
    //
    // Every `registerUndo` block in the domain files follows one rule, and it is
    // the rule that makes undo survive the hop:
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

    // MARK: - Undo grouping (slice 52, and its review)

    /// **Every undo registration in the model goes through here.**
    ///
    /// Chiefly so there is one place to reason about registration, which is what
    /// the async hop made subtle — and one place to have got the grouping
    /// experiment wrong, and to undo it (see `undoManager`). Grouping itself is
    /// `groupsByEvent`'s job: all of one action's registrations happen inside a
    /// single `commit`, so they share a run-loop turn and a group.
    ///
    /// The pairing with `setActionName` used to be repeated at all 23 sites, and
    /// is now impossible to forget.
    func registerUndoStep(
        actionName: String, _ body: @escaping @MainActor (ArchiveModel) -> Void
    ) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in body(model) }
        undoManager.setActionName(actionName)
    }
}

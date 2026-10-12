import Foundation
import GeneaLogicModel
import Testing

@testable import GeneaLogicApp
@testable import GeneaLogicArchive

/// Slice 61 — the window says when a change is on its way in.
///
/// Slice 60 gave the engine the fact: `manifest.json` is not the one the index
/// last settled, so a change is arriving rather than a file being damaged. It
/// said so only in the Verify panel, which nobody opens speculatively — so a
/// synced archive part-way through receiving a record showed the user nothing,
/// and refused edits to that record with an error out of nowhere. These are the
/// two halves of closing that: the indicator itself, and the poll that keeps it
/// from being a poll or more stale.
@MainActor
@Suite struct IncomingChangeTests {

    // MARK: - Standing in for a sync provider

    /// Copies what the other machine wrote, one path at a time — so a test can
    /// deliver `manifest.json` **without** the record it describes, which is
    /// precisely the state this slice exists to announce. Sync is not atomic
    /// across files (slice 60, fork e).
    private func deliver(_ paths: [String], from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        for path in paths {
            let target = destination.appendingPathComponent(path)
            try? fm.removeItem(at: target)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source.appendingPathComponent(path), to: target)
        }
    }

    private func clone(_ root: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("genealogic-other-machine-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: root, to: copy)
        return copy
    }

    /// One turn of the archive window's loop, with both of its off-main tasks
    /// awaited — the reconcile first, since it is what starts the sweep.
    private func poll(_ model: ArchiveModel) async {
        model.refreshIfChangedExternally()
        await model.reconcileSettled()
        await model.fileSweepSettled()
    }

    /// A model watching an archive, with both of slice 61's delays out of the way
    /// and the engine's reconcile back-off with them.
    ///
    /// **The back-off matters as much as the delays.** Without it a delivery that
    /// lands mid-test would not be adopted for up to half a minute (slice 60's
    /// fork (e) doubling), so "the indicator clears when the delivery completes"
    /// would be a test of the clock. `reconcileBackoffBounds` exists for exactly
    /// this, and is the precedent these two follow.
    private func watcher(on root: URL) -> ArchiveModel {
        let model = ArchiveModel(url: root)
        model.incomingChangeDelay = .zero
        model.load()
        model.archive?.reconcileBackoffBounds = (.zero, .zero)
        return model
    }

    /// An archive with one artifact, and a second copy of it that has since
    /// grown a *new* artifact — everything needed to deliver a change by hand.
    private func seededPair() throws -> (root: URL, other: URL, deliveredSlug: String) {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Already Here", mediaType: .image))

        let other = try clone(root)
        let otherMachine = try Archive.open(at: other)
        let added = try otherMachine.addArtifact(
            ArtifactDraft(title: "On Its Way", mediaType: .image))
        let slug = try #require(otherMachine.artifacts().first { $0.uid == added.uid }?.slug)
        return (root, other, slug)
    }

    // MARK: - The indicator

    /// **The assertion the slice is for.** The manifest has arrived and the
    /// record it describes has not, which is invisible everywhere else: nothing
    /// committed, so 51's token never moves, and the damage banner stays silent
    /// by name (57's rule — an arrival is not a finding).
    @Test func aDeliveryStillInFlightPutsAQuietIndicatorInTheWindow() async throws {
        let (root, other, _) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = watcher(on: root)
        #expect(model.incomingChange == nil)

        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)

        #expect(model.incomingChange == .receiving)
    }

    /// It waits before speaking. Most deliveries land between polls, and an
    /// indicator that flickers on every small sync teaches the user to ignore it.
    @Test func anArrivalIsGivenAMomentToLandBeforeAnythingIsSaid() async throws {
        let (root, other, _) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = ArchiveModel(url: root)
        model.incomingChangeDelay = .seconds(60)
        model.load()
        model.archive?.reconcileBackoffBounds = (.zero, .zero)

        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)

        #expect(model.incomingChange == nil)
    }

    /// And it goes when the change has actually landed — with no dismiss control
    /// anywhere, which is why this one has to be true.
    @Test func theIndicatorClearsItselfWhenTheDeliveryCompletes() async throws {
        let (root, other, slug) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = watcher(on: root)
        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)
        #expect(model.incomingChange == .receiving)

        try deliver(["artifacts/\(slug)/record.json"], from: other, to: root)
        await poll(model)

        #expect(model.incomingChange == nil)
        // **Cleared because the change is *there*, not merely because the bytes
        // are.** The indicator tracks adoption, so the record it announced is in
        // the list by the time it stops announcing it.
        #expect(model.artifacts.map(\.title).sorted() == ["Already Here", "On Its Way"])
    }

    /// A delivery that stops arriving eventually stops reading as progress.
    /// The wording escalates and offers somewhere to look; it still does not
    /// accuse the sync of having failed, because a slow large file is
    /// indistinguishable from a stalled one (see `IncomingChange`).
    @Test func aDeliveryThatStopsArrivingEscalatesAndOffersVerify() async throws {
        let (root, other, _) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = watcher(on: root)
        model.incomingChangeStallThreshold = .zero

        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)

        #expect(model.incomingChange == .stalled)
        #expect(model.incomingChange?.offersVerify == true)
    }

    // MARK: - The line it must not cross

    /// **Damage is not an arrival**, which is the distinction slice 60 spent
    /// three rounds establishing and the one this indicator could most easily
    /// undo. A truncated payload file changes no manifest, so the settled witness
    /// still matches and nothing is in flight.
    @Test func damageDoesNotClaimAChangeIsArriving() async throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        let archive = try #require(seed.archive)
        let artifact = try archive.addArtifact(ArtifactDraft(title: "Deed", mediaType: .image))
        let scan = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-\(UUID().uuidString).tif")
        try Data(repeating: 0xAB, count: 4096).write(to: scan)
        _ = try archive.attachFile(
            copyingFrom: scan, to: artifact.uid, role: .preservationMaster)
        try? FileManager.default.removeItem(at: scan)

        // Artifact-relative, so it needs its folder in front of it to name the
        // file on disk (the same join `seedOneFile` makes in 57's suite).
        let slug = try #require(archive.artifacts().first?.slug)
        let entry = try #require(archive.artifact(withID: artifact.uid)?.files.first?.path)
        try Data(repeating: 0xAB, count: 12).write(
            to: root.appendingPathComponent("artifacts/\(slug)/\(entry)"))

        let model = watcher(on: root)
        await poll(model)

        #expect(model.incomingChange == nil)
        #expect(model.fileDamage?.wrongSizeCount == 1)
    }

    /// And the converse: while a delivery is in flight, the damage banner says
    /// nothing at all. The two must never describe the same file, and the sweep
    /// classifies every outstanding path as an arrival rather than a loss —
    /// otherwise a large record syncing would put "1 file is missing from this
    /// archive" on screen for the whole download.
    @Test func theDamageBannerStaysSilentForAFileThatIsMerelyArriving() async throws {
        let (root, other, _) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = watcher(on: root)
        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)

        #expect(model.incomingChange == .receiving)
        #expect(model.fileDamage == nil)
        #expect(!model.hasStandingDamage)
    }

    /// **A request made while a sweep is walking must not cancel it**
    /// (`/code-review`, 61).
    ///
    /// `sweepFileSizes()` has no suspension point, so a cancelled walk runs to
    /// completion regardless and only its *result* is discarded. That was
    /// harmless while `refresh()` was the only caller, and stopped being harmless
    /// the moment slice 61 put the sweep on the 1 Hz poll: on an archive where one
    /// walk outlasts one tick, every sweep was cancelled by its successor and
    /// **nothing was ever published** — the banner froze and the stall threshold,
    /// which measures progress from this sweep, ran to ten minutes on a perfectly
    /// healthy delivery.
    ///
    /// Asserted as the mechanism rather than as the race, deliberately: a test
    /// that needed one walk to outlast another would be timing-dependent, and the
    /// invariant that fixes it — *coalesce onto the running walk, never replace
    /// it* — is fully synchronous and cannot pass on the old behaviour.
    @Test func aSecondRequestCoalescesOntoTheWalkAlreadyRunning() async throws {
        let (root, other, _) = try seededPair()
        defer {
            AppTestSupport.remove(root)
            AppTestSupport.remove(other)
        }

        let model = watcher(on: root)
        try deliver(["manifest.json"], from: other, to: root)
        await poll(model)
        #expect(model.incomingChange == .receiving)

        // Two poll ticks with no suspension between them, which is what the app
        // does for as long as a delivery is in flight.
        model.refreshIfChangedExternally()
        let walking = try #require(model.fileSweepTask)
        model.refreshIfChangedExternally()

        // `Task` is a value type, but a `Hashable` one whose identity is the
        // underlying job — so `==` here means "the same walk".
        #expect(model.fileSweepTask == walking)
        await model.fileSweepSettled()
        #expect(!walking.isCancelled)
    }

    /// A quiet archive is not told it is receiving anything — the poll runs once
    /// a second for as long as a window is open, and this is the state it is in
    /// nearly all of that time.
    @Test func aQuietArchiveSaysNothing() async throws {
        let (seed, root) = try AppTestSupport.makeModel(undo: false)
        defer { AppTestSupport.remove(root) }
        _ = try #require(seed.archive).addArtifact(
            ArtifactDraft(title: "Steady", mediaType: .image))

        let model = watcher(on: root)
        for _ in 0..<3 { await poll(model) }

        #expect(model.incomingChange == nil)
    }
}

/// The wording itself, held here rather than inferred from a rendered view.
@MainActor
@Suite struct IncomingChangeWordingTests {

    /// No count, no file names, no octagon — and nothing that reads as damage.
    @Test func theArrivingLineNamesNothingAndAsksForNothing() {
        #expect(IncomingChange.receiving.headline == "Receiving a change from another machine…")
        #expect(IncomingChange.receiving.detail == nil)
        #expect(!IncomingChange.receiving.offersVerify)
    }

    /// The escalation says the change *hasn't finished*, which is true whether
    /// the sync stopped or is merely slow — and offers a place to look rather
    /// than a diagnosis.
    @Test func theStalledLineHedgesAndPointsSomewhere() throws {
        #expect(
            IncomingChange.stalled.headline == "A change from another machine hasn't finished "
                + "arriving.")
        let detail = try #require(IncomingChange.stalled.detail)
        #expect(detail.contains("Verify Integrity"))
        #expect(IncomingChange.stalled.offersVerify)
    }
}

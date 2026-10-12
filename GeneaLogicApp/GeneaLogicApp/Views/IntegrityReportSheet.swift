import AppKit
import GeneaLogicArchive
import SwiftUI

/// The integrity panel (File ▸ Verify Integrity…): a read-only report over the
/// engine's `verifyIntegrity()` — does every manifest-tracked file still match
/// its recorded SHA-256 and size, and is there anything extra lying around?
/// (ARCHITECTURE.md §3, §6.3.)
///
/// Verification SHA-256s every file, so it runs from a `.task` that lets the
/// spinner paint before the sweep (which is off the main actor since 57b). The
/// only action the panel offers is **Rebuild Index** — regenerating the
/// disposable `.index/` cache, the safe §5.1 fix for an index that has drifted
/// from on-disk edits. `repair()` is an honest engine stub (it throws) and is
/// deliberately not surfaced.
///
/// **What it does not do is download the archive** (slice 57b). Hashing a file
/// that is not downloaded to this machine pulls it down, so on a synced archive
/// this panel used to be a whole-archive download wearing a menu item's clothes,
/// ending in *Archive Is Intact*. Those files are now listed under **Not
/// Checked**, the headline is gated on having actually read everything, and
/// downloading them is a separate, priced click.
///
/// The panel reports **two** sweeps side by side: `verifyIntegrity()` over the
/// manifest-tracked files (Corruption / Stray Files) and `findDanglingReferences()`
/// over the conclusion records (Dangling References — the residue of the §2.3
/// no-cascade removals). They stay separate engine calls because they answer
/// different questions; the panel is simply the one place a researcher asks
/// "is anything wrong with this archive?"
struct IntegrityReportSheet: View {
    @Environment(ArchiveModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    /// Both sweeps' results — what a completed check produced.
    private struct Findings {
        var report: IntegrityReport
        var dangling: [DanglingReference]
        /// What can be restored, by path, for the rows that are records (58d).
        var plans: [String: Archive.RecordRepairPlan] = [:]

        var isVerified: Bool {
            IntegrityReportSheet.showsIntactHeadline(report: report, dangling: dangling)
        }
    }

    /// Whether this panel may say **Archive Is Intact**.
    ///
    /// **`isClean` is not enough, and that is the whole of slice 57b's app half.**
    /// A pass that skipped every un-downloaded preservation master finds no
    /// problems, so it is clean — and this is the one sentence in the app that
    /// claims verification, so rendering it there would be exactly the claim the
    /// engine went to the trouble of not making. `isComplete` is the engine's
    /// answer to *did we actually read everything*, and the headline gates on it.
    ///
    /// Static and testable because the string is the risk: no engine test can see
    /// what this view renders (`IntegrityReportSectionTests`).
    static func showsIntactHeadline(report: IntegrityReport, dangling: [DanglingReference]) -> Bool
    {
        report.isClean && report.isComplete && dangling.isEmpty
    }

    private enum Phase {
        /// `downloading` when the pass was asked to fetch the files it would
        /// otherwise skip — the one case where the wait is bounded by a network
        /// rather than a disk, and the spinner has to say so.
        case checking(downloading: Bool)
        case done(Findings)
        case unavailable
        /// The pass refused the archive, and says why — today only a record from
        /// a newer GeneaLogic (slice 70), which is not this build's to judge.
        case refused(String)
    }

    @State private var phase: Phase = .checking(downloading: false)
    @State private var isRebuilding = false

    /// The download-and-check pass, held so it can be **cancelled** — by the Stop
    /// button, and by the sheet going away (`/code-review`, 57b).
    ///
    /// Unstructured `Task`s do not inherit the view's lifetime the way `.task`
    /// does, so without this handle a confirmed multi-gigabyte transfer went on
    /// running after Done dismissed the panel, with no surface left to say so.
    /// The engine pass now checks `Task.isCancelled` between files and between
    /// chunks, so cancelling it actually stops the reading — what it cannot stop
    /// is a fetch the file provider has already begun, which is why nothing here
    /// promises the transfer ends the instant you click.
    @State private var downloading: Task<Void, Never>?

    /// A message raised by a repair action, shown in a **sheet-local** alert — the
    /// model's `actionInfo`/`actionError` alerts are bound on the window behind this
    /// sheet and so can't surface while it's up.
    @State private var notice: String?

    /// Gate on "Download and Check the Rest" — see `downloadAndCheckTheRest()`.
    /// Confirmed rather than immediate because the click's cost is the one thing
    /// the button's label cannot carry: the dialog states the files and the bytes.
    @State private var isConfirmingDownload = false

    /// Gate on "Accept Current Contents" — see `rebaseline()`.
    @State private var isConfirmingRebaseline = false

    /// The path a "Stop Waiting for This File…" click is confirming, if any
    /// (slice 50d). Confirmed rather than immediate for the same reason the
    /// rebaseline is: waiting is the *correct* answer for a delivery that is
    /// merely slow, and a slow link is indistinguishable from a stopped one — so
    /// the user is asked to say they know which this is.
    @State private var abandoning: String?

    /// The record a Restore… or Delete… click is confirming (58d, fork h) —
    /// item-based for the reason `abandoning` is.
    @State private var restoring: Archive.RecordRepairPlan?
    @State private var deleting: Archive.RecordRepairPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Verify Integrity")
                .font(.headline)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .padding(Layout.sheetPadding)
        // Resizable so the issues list can grow to show more rows. `.fitted` opts back
        // into resizable sheets (fixed-size by default on macOS 15+) (UI audit F5).
        .presentationSizing(.fitted)
        .frame(
            minWidth: Layout.ContentSheet.minWidth, idealWidth: Layout.ContentSheet.idealWidth,
            maxWidth: .infinity,
            minHeight: Layout.ContentSheet.minHeight, idealHeight: Layout.ContentSheet.idealHeight,
            maxHeight: .infinity
        )
        .task { await verify() }
        .onDisappear { downloading?.cancel() }
        .alert(
            "Verify Integrity",
            isPresented: Binding(
                get: { notice != nil }, set: { if !$0 { notice = nil } })
        ) {
            Button("OK", role: .cancel) { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .confirmationDialog(
            "Accept the archive's current contents?",
            isPresented: $isConfirmingRebaseline, titleVisibility: .visible
        ) {
            Button("Accept Current Contents") { rebaseline() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "GeneaLogic will record the files as they are on disk now, and stop reporting "
                    + "the differences above. Do this for changes you made yourself — if a file "
                    + "was damaged, restore it from a backup first, because this replaces the "
                    + "record of what it used to be.")
        }
        .confirmationDialog(
            "Download these files and check them?",
            isPresented: $isConfirmingDownload, titleVisibility: .visible
        ) {
            Button("Download and Check") { downloadAndCheckTheRest() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(downloadPrompt)
        }
        // **Item-based, not a boolean binding** (`/code-review`). With
        // `isPresented:` the dialog's own dismissal nils `abandoning` through the
        // setter, and the button action then reads it — so if dismissal wins the
        // race the confirmed action silently does nothing. `presenting:` hands
        // the path to the action instead, which is why every other item-based
        // confirmation in this app uses it.
        .confirmationDialog(
            "Stop waiting for this file?",
            isPresented: Binding(
                get: { abandoning != nil }, set: { if !$0 { abandoning = nil } }),
            titleVisibility: .visible,
            presenting: abandoning
        ) { path in
            Button("Stop Waiting") { abandon(path) }
            Button("Cancel", role: .cancel) { abandoning = nil }
        } message: { path in
            Text(
                "GeneaLogic will stop expecting a version of \(path) that hasn't arrived. "
                    + "Do this only if the change has plainly stopped coming — a slow "
                    + "connection looks exactly the same. Nothing is deleted, any copy on "
                    + "this machine is kept as it is, and if the other version does arrive "
                    + "later it will still be taken up.")
        }
        // The row views' confirmations, word for word (58d, fork h): the same
        // action must not be described two ways depending on where it was clicked.
        .confirmationDialog(
            UnreadableRecordRowView.restoreDialogTitle,
            isPresented: Binding(
                get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible,
            presenting: restoring
        ) { plan in
            Button(
                UnreadableRecordRowView.restoreConfirmTitle(plan),
                role: plan.requiresExplicitAcceptance ? .destructive : nil
            ) { restore(plan) }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: { plan in
            Text(UnreadableRecordRowView.restoreMessage(plan))
        }
        .confirmationDialog(
            UnreadableRecordRowView.deleteDialogTitle,
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible,
            presenting: deleting
        ) { plan in
            Button(UnreadableRecordRowView.deleteConfirmTitle, role: .destructive) {
                delete(plan)
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { plan in
            // ⌘Z can't reach the archive window's undo stack from inside this sheet
            // (a sheet is its own key window), so the panel says when it can.
            Text(
                UnreadableRecordRowView.deleteMessage(
                    named: plan.recordLabel ?? "",
                    kind: UnreadableRecordRow(plan.path)?.kind ?? .other)
                    + " Undo is in the Edit menu once this panel is closed.")
        }
    }

    /// Which record actions a row offers (58d, fork h). **The rule is the
    /// panel's, not per kind:** an unreadable or missing record GeneaLogic kept a
    /// copy of can be restored, and a missing one deleted (undoably — see
    /// `ArchiveModel.deleteVanishedRecord`). Relationships, links and dismissals have no list and
    /// so no placeholder row — this is the only place the app offers them either;
    /// artifacts and persons get it here too, because one rule is simpler than a
    /// kind filter. An older-format record has no plan (the engine refuses it).
    ///
    /// Static so the tests can hold it without rendering the sheet.
    static func recordActions(
        for issue: IntegrityReport.Issue, plans: [String: Archive.RecordRepairPlan]
    ) -> (restore: Archive.RecordRepairPlan?, delete: Archive.RecordRepairPlan?) {
        switch issue {
        case .unreadableRecord(let path, .undecodable):
            return (plans[path], nil)
        case .missingFile(let path):
            let plan = plans[path]
            return (plan, plan?.isDeletable == true ? plan : nil)
        default:
            return (nil, nil)
        }
    }

    /// A row's detail line: the issue's own, and — for a record GeneaLogic kept a
    /// copy of — what the sidebar row says on hover, named from the copy (58d, on
    /// the hand-test: the panel is where those actions are visible, so it is where
    /// the explanation belongs too). Static so the tests can read it.
    static func detail(
        for issue: IntegrityReport.Issue, plans: [String: Archive.RecordRepairPlan]
    ) -> String {
        let condition: UnreadableRecordRow.Condition
        switch issue {
        case .missingFile: condition = .missing
        case .unreadableRecord(_, .undecodable): condition = .undecodable
        default: return issue.detail
        }
        guard let plan = plans[issue.path],
            let row = UnreadableRecordRow(issue.path, condition: condition)
        else { return issue.detail }
        return issue.detail + " " + row.panelDetail(named: plan.recordLabel)
    }

    /// The paths whose plans the panel asks for — the rows `recordActions` can act on.
    static func recordPaths(in report: IntegrityReport) -> [String] {
        report.issues.compactMap { issue in
            switch issue {
            case .unreadableRecord(let path, .undecodable), .missingFile(let path): path
            default: nil
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .checking(let downloading):
            ProgressView(
                downloading
                    ? "Downloading the remaining files and checking them…"
                    : "Checking every tracked file…"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            ContentUnavailableView(
                "Couldn't Verify", systemImage: "exclamationmark.triangle",
                description: Text("No archive is open."))
        case .refused(let reason):
            ContentUnavailableView(
                "Couldn't Verify", systemImage: "exclamationmark.triangle",
                description: Text(reason))
        case .done(let findings) where findings.isVerified:
            // **The notes outlive a clean report**, so a clean archive that
            // stopped waiting for something still says so — otherwise the one
            // surface that explains the decision disappears the moment it takes
            // effect (slice 50d).
            if findings.report.abandonedPaths.isEmpty {
                cleanState
            } else {
                VStack(spacing: 12) {
                    cleanState
                    List { abandonedSection(findings) }
                        .listStyle(.inset)
                        .frame(maxHeight: 160)
                }
            }
        case .done(let findings):
            issues(findings)
        }
    }

    private var cleanState: some View {
        ContentUnavailableView {
            Label("Archive Is Intact", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } description: {
            Text(
                "Every tracked file matches its recorded checksum and size, "
                    + "no stray files were found, and every conclusion points at a "
                    + "record that still exists.")
        }
    }

    /// One section per severity, in the order they are shown.
    ///
    /// **A table rather than a filter per section, because the filters were a
    /// trapdoor** (second `/code-review`, slice 60): adding `.arriving` to the
    /// enum compiled cleanly and matched none of the three hand-written filters,
    /// so an archive whose only findings were arrivals is not `isClean`, skipped
    /// the "Archive Is Intact" branch, and rendered a `List` with **zero
    /// sections** — a blank sheet, on the one surface the banner deliberately
    /// stays silent in favour of. `sectionsCoverEverySeverity` holds this to
    /// every case, so the next severity fails a test instead of rendering
    /// nothing.
    static let sections: [(severity: IntegrityReport.Issue.Severity, title: String, tint: Color)] =
        [
            (.corruption, "Corruption", .red),
            (.interrupted, "Interrupted Writes", .orange),
            (.arriving, "Still Arriving", .blue),
            (.stray, "Stray Files", .orange),
            (.duplicate, "Conflicting Copies", .orange),
        ]

    private func issues(_ findings: Findings) -> some View {
        List {
            // **First, because it is the caveat over everything below it**: a
            // report that skipped files is not a verification, and the sections
            // that follow are only as complete as this section is empty.
            notCheckedSection(findings)
            ForEach(Self.sections, id: \.title) { section in
                let matching = findings.report.issues.filter { $0.severity == section.severity }
                if !matching.isEmpty {
                    Section("\(section.title) (\(matching.count))") {
                        ForEach(matching, id: \.id) {
                            row($0, tint: section.tint, plans: findings.plans)
                        }
                    }
                }
            }
            if !findings.dangling.isEmpty {
                Section("Dangling References (\(findings.dangling.count))") {
                    ForEach(findings.dangling, id: \.self) { danglingRow($0) }
                }
            }
            abandonedSection(findings)
        }
        .listStyle(.inset)
    }

    /// The files whose contents were **not read**, and the action that pays to
    /// read them (slice 57b).
    ///
    /// **Not a finding, and tinted like the notes rather than the damage** —
    /// nothing is wrong with these files. What they are is the reason the panel
    /// cannot say *Archive Is Intact*, and the section header carries the whole
    /// bill so the decision can be made from it: how many files, and how many
    /// bytes.
    ///
    /// **The action is beside the list, not ahead of the pass** (fork f). A modal
    /// before verifying would have to guess the number; the pass is what produces
    /// it. That makes this one more rung on 57's ladder — free, cheap, hashing,
    /// and now downloading — each entered deliberately.
    @ViewBuilder
    private func notCheckedSection(_ findings: Findings) -> some View {
        if !findings.report.notChecked.isEmpty {
            let flagged = Set(findings.report.issues.map(\.path))
            Section {
                ForEach(findings.report.notChecked, id: \.path) { file in
                    detailRow(
                        summary: "Not checked",
                        identifier: file.path,
                        detail: Self.notCheckedDetail(
                            file, alsoReported: flagged.contains(file.path)),
                        systemImage: Self.notCheckedSymbol(file.reason),
                        tint: .secondary)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(Self.notCheckedHeadline(findings.report))
                    Spacer(minLength: 0)
                    // Only when a download is what would resolve something here:
                    // it does nothing for a file that failed to read, or one a
                    // stopped pass never reached (`/code-review`, 57b).
                    if !findings.report.downloadableNotChecked.isEmpty {
                        Button("Download and Check the Rest…") { isConfirmingDownload = true }
                            .disabled(isRebuilding || isChecking)
                            .font(.caption)
                            .buttonStyle(.link)
                            .fixedSize()
                            .help(
                                "Download the files that aren't on this machine and check "
                                    + "their contents. This transfers them onto this machine "
                                    + "and can take a long time.")
                    }
                }
            } footer: {
                // **The half of the answer that is otherwise missing.** With
                // nothing else in the list this section is the whole sheet, and
                // "Archive Is Intact" is exactly what must not be said — but
                // "nothing was found in what was read" is true, is worth saying,
                // and is the sentence the headline would have swallowed.
                if findings.report.isClean && findings.dangling.isEmpty {
                    Text(
                        "No problems were found in the files that are on this machine. The "
                            + "files above weren't read, so this isn't a full verification.")
                }
            }
        }
    }

    /// "Not Checked (41 files, 3.2 GB)" — the count *and* the size, because a
    /// bare count is not something anyone can decide from, and both come free
    /// from the manifest.
    ///
    /// **It does not say why here**, because the rows can disagree: a pass can
    /// hold placeholders, a file that failed to read, and a stopped remainder all
    /// at once, and one summary sentence for all three would be wrong about two
    /// of them.
    static func notCheckedHeadline(_ report: IntegrityReport) -> String {
        let count = report.notChecked.count
        let size = report.notCheckedByteCount.formatted(.byteCount(style: .file))
        return "Not Checked (\(count) \(count == 1 ? "file" : "files"), \(size))"
    }

    /// What one unread file's row says.
    ///
    /// **Two things it must not get wrong** (`/code-review`, 57b). The reason is
    /// switched over rather than assumed — "isn't downloaded to this machine" is
    /// false of a file that could not be read. And the reassuring half, *it is
    /// present and the size the archive recorded*, is dropped when the same path
    /// is **also** reported as a finding: a dataless file whose size no longer
    /// matches appears in both lists, and a row calling it the right size
    /// contradicts the row above it about one file.
    static func notCheckedDetail(_ file: IntegrityReport.NotCheckedFile, alsoReported: Bool)
        -> String
    {
        let size = file.byteLength.formatted(.byteCount(style: .file))
        let closing =
            alsoReported
            ? "It is also reported above, so what is on this machine already disagrees with "
                + "the archive's record of it."
            : "It is present and the size the archive recorded — \(size) — but nothing here "
                + "can tell you whether its contents are intact."
        switch file.reason {
        case .notOnThisMachine:
            return "This file isn't downloaded to this machine, so its contents weren't read. "
                + closing
        case .couldNotRead:
            return "This file couldn't be read, so its contents weren't checked. Check the "
                + "permissions on it and the disk it is stored on."
        case .checkWasStopped:
            return "The check was stopped before it got to this file, so its contents weren't "
                + "read. Re-run to check it."
        }
    }

    static func notCheckedSymbol(_ reason: IntegrityReport.NotCheckedFile.Reason) -> String {
        switch reason {
        case .notOnThisMachine: "icloud.and.arrow.down"
        case .couldNotRead: "eye.slash"
        case .checkWasStopped: "stop.circle"
        }
    }

    /// The confirmation's text — what will be fetched, and what it costs.
    ///
    /// **Priced from `downloadableNotChecked`, not the whole list**, so the
    /// number is what this action will actually transfer.
    private var downloadPrompt: String {
        guard case .done(let findings) = phase else { return "" }
        let count = findings.report.downloadableNotChecked.count
        let size = findings.report.downloadableByteCount.formatted(.byteCount(style: .file))
        return
            "GeneaLogic will download \(count) \(count == 1 ? "file" : "files") (\(size)) from "
            + "your file provider and check the contents against the archive's record of them. "
            + "They will then be stored on this machine. Nothing is changed either way — this "
            + "only reads."
    }

    /// **A row that is still arriving is the one actionable file row** (slice
    /// 50d). Every other finding here is either damage, which the panel must not
    /// offer to bless per row, or a stray file the archive does not own; an
    /// arrival that never arrives is the one case where the archive is *waiting*
    /// and only a human can say the waiting is over.
    ///
    /// **A misnamed record gets Reveal, which is not an exception to that** (slice
    /// 50c, hand-test). It performs nothing on the archive; it opens Finder on a
    /// file the user has already been told to rename. The row without it was 57's
    /// mistake in the plainer form — a remedy stated in a panel with no way to
    /// reach the thing it names, inside a package bundle you cannot open by
    /// double-clicking. Renaming it is the user's, because the engine offering to
    /// do it is a verb with refusals and CLI parity of its own, and 50c settled on
    /// *report and touch nothing*.
    ///
    /// **The wording is load-bearing.** It says *Stop Waiting for This File*,
    /// never Repair or Fix: nothing here is damaged, the file that is here is
    /// perfectly good, and a verb that implied otherwise would be 57's mistake in
    /// the other direction — a sentence claiming an assurance the action does
    /// not give. It is placed on the row and not in the footer because the
    /// decision is per path, which is exactly what the footer's archive-wide
    /// "Accept Current Contents" is not.
    ///
    /// **A record with a saved copy gets Restore, and a missing one Delete** (58d,
    /// fork h) — not an exception either: Restore puts back the archive's own last
    /// version and proves it, and Delete is the ordinary, undoable delete of a
    /// record the user has decided against. Neither blesses damage the way Accept
    /// Current Contents does.
    private func row(
        _ issue: IntegrityReport.Issue, tint: Color, plans: [String: Archive.RecordRepairPlan]
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            detailRow(
                summary: issue.summary, identifier: issue.path,
                detail: Self.detail(for: issue, plans: plans),
                systemImage: issue.systemImage, tint: tint)
            if case .awaitingDelivery(let path) = issue {
                Spacer(minLength: 0)
                Button("Stop Waiting for This File…") { abandoning = path }
                    .disabled(isRebuilding || isChecking)
                    .font(.caption)
                    .buttonStyle(.link)
                    .fixedSize()
                    .help(
                        "Stop expecting a version of this file that hasn't arrived. Nothing "
                            + "is deleted — any copy on this machine is kept exactly as it "
                            + "is — and a version that turns up later is still taken up.")
            }
            if case .misnamedRecord = issue {
                Spacer(minLength: 0)
                Button("Reveal in Finder") { reveal(issue.path) }
                    .font(.caption)
                    .buttonStyle(.link)
                    .fixedSize()
                    .help(
                        "Show this file in Finder. Nothing here changes it — renaming it is "
                            + "yours to do, and Rebuild Index then picks the record up.")
            }
            let actions = Self.recordActions(for: issue, plans: plans)
            if actions.restore != nil || actions.delete != nil {
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 4) {
                    if let plan = actions.restore {
                        Button(UnreadableRecordRowView.restoreActionTitle(plan)) { restoring = plan }
                        .help(
                            "Put back \(plan.recordLabel.map { "“\($0)”" } ?? "this record") as "
                                + "GeneaLogic last wrote it, from the copy it kept.")
                    }
                    if let plan = actions.delete {
                        Button(UnreadableRecordRowView.deleteActionTitle) { deleting = plan }
                            .help("Accept that this record is gone, and delete the copy.")
                    }
                }
                .disabled(isRebuilding || isChecking)
                .font(.caption)
                .buttonStyle(.link)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func abandonedSection(_ findings: Findings) -> some View {
        if !findings.report.abandonedPaths.isEmpty {
            Section("Stopped Waiting (\(findings.report.abandonedPaths.count))") {
                ForEach(findings.report.abandonedPaths, id: \.self) { abandonedRow($0) }
            }
        }
    }

    /// The notes beside the findings: paths this machine stopped waiting for.
    ///
    /// **Rendered even when the archive is clean**, which is the point of them —
    /// an abandonment leaves an ordinary-looking manifest entry, so this is the
    /// only place that answers "why does this record hold my version and not
    /// theirs?". It is not a finding and carries no severity tint.
    private func abandonedRow(_ path: String) -> some View {
        detailRow(
            summary: "Stopped waiting",
            identifier: path,
            detail: "This machine stopped waiting for a version that hadn't arrived. If it "
                + "turns up later it will still be taken up.",
            systemImage: "hand.raised",
            tint: .secondary)
    }

    /// A dangling reference reads like the file rows, with the holder record's
    /// uid where a file row shows its path — that's the handle onto the record
    /// that survived and still needs editing or deleting.
    ///
    /// Unlike the file rows it is **actionable**, because these findings are
    /// fixable from inside the app: **Reveal** jumps to the surviving record so
    /// the repair happens in context (where a mention can be re-resolved or a
    /// relationship repointed), and **Remove Stale Reference** clears the pointer
    /// here — the only possible fix for a stale fact citation, which has no
    /// editor of its own. Both are undoable; neither touches a live record.
    private func danglingRow(_ dangling: DanglingReference) -> some View {
        HStack(alignment: .top, spacing: 10) {
            detailRow(
                summary: dangling.summary, identifier: dangling.holderUID, detail: dangling.detail,
                systemImage: dangling.systemImage, tint: .orange)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                // Offered only where a view actually draws this finding — see
                // `isRevealable`. A button that dismisses the panel onto a page with no
                // trace of the problem is worse than no button.
                if dangling.isRevealable {
                    Button("Reveal") { reveal(dangling) }
                        .help("Show the record that holds this reference, to fix it in context")
                }
                Button("Remove Stale Reference") { removeStale(dangling) }
                    // Deliberately *not* "⌘Z to undo" like the in-pane controls: a
                    // sheet is its own key window, so ⌘Z doesn't reach the archive
                    // window's UndoManager until this panel is closed (verified live).
                    // The step is on the stack either way — it just can't be taken here.
                    .help(
                        "Clear the broken pointer, leaving every surviving record. "
                            + "Undoable with ⌘Z once you close this panel.")
            }
            .font(.caption)
            .buttonStyle(.link)
            .fixedSize()
        }
    }

    /// Jumps to the holder record. The sheet dismisses only when there is somewhere
    /// to go — a finding whose every end is deleted (a link with *both* its artifact
    /// and its person removed) leaves the panel open with a notice instead.
    ///
    /// That notice is **sheet-local**, not the model's `showInfo` channel: the app's
    /// info/error alerts are bound on the archive window, which is behind this modal
    /// sheet, so a message raised from here wouldn't reach the user at the moment they
    /// clicked. (The same separation is why ⌘Z doesn't work in here.)
    /// Reveals one archive-relative path. Deliberately does **not** dismiss the
    /// sheet, unlike the dangling-reference reveal: the remedy has a second half
    /// (Rebuild Index, in this sheet's own footer), and closing the panel would
    /// hide it at the moment it becomes the thing to do.
    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([model.url.appendingPathComponent(path)])
    }

    private func reveal(_ dangling: DanglingReference) {
        if model.revealDanglingReference(dangling) {
            dismiss()
        } else {
            notice =
                "Every record this reference names has been deleted, so there's nothing to "
                + "show. Remove Stale Reference will clear it."
        }
    }

    /// Clears the pointer, then re-runs **only** the reference sweep so the row
    /// disappears — re-verifying would re-hash every file to learn nothing new.
    /// **Both halves have to wait for the repair to land** (52's `/code-review`).
    /// The write is asynchronous now, so draining `actionError` in the same turn
    /// always found it `nil` — a failed repair was reported nowhere, since the
    /// window's alert can't present from behind this sheet — and the re-sweep ran
    /// against the pre-repair archive, leaving the row it had just fixed.
    private func removeStale(_ dangling: DanglingReference) {
        Task {
            model.removeDanglingReference(dangling)
            await model.writesSettled()
            // A repair that failed (the holder changed under us) sets the model's error
            // channel, which can't present from behind this sheet — so it's drained here
            // and shown locally, rather than the row just sitting there unexplained.
            if let failure = model.actionError {
                model.actionError = nil
                notice = failure
            }
            if case .done(var findings) = phase {
                findings.dangling = model.findDanglingReferences() ?? []
                phase = .done(findings)
            }
        }
    }

    private func detailRow(
        summary: String, identifier: String, detail: String, systemImage: String, tint: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.headline)
                Text(identifier)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button("Rebuild Index") { rebuild() }
                .disabled(isRebuilding || isChecking)
                // "Safe — it never changes your data" was true of the sidecars
                // and false of the one thing a rebuild could destroy: the last
                // copy of a record it can't read (slice 58). It now keeps that
                // copy, and the text says which of the two it is promising.
                .help(
                    "Regenerate the disposable search index from the on-disk "
                        + "records. It doesn't change your records, and it keeps "
                        + "the last copy of any record it can't read.")
            // Only when there is something it can resolve — see
            // `ArchiveModel.rebaseline()` for why this isn't a standing button.
            if hasRebaselinableFindings {
                Button("Accept Current Contents…") { isConfirmingRebaseline = true }
                    .disabled(isRebuilding || isChecking)
                    .help(
                        "Record the archive as it is on disk now, so these findings stop "
                            + "being reported. Use it for an edit you made yourself.")
            }
            if isRebuilding {
                ProgressView().controlSize(.small)
            }
            // Only for the download: it is the one pass here whose length is
            // bounded by a network rather than a disk, and the only one launched
            // through a handle this can cancel.
            if case .checking(downloading: true) = phase {
                Button("Stop") { stopDownloading() }
                    .help(
                        "Stop downloading and checking. Files already read stay checked; "
                            + "the rest are reported as not checked.")
            }
            Spacer()
            Button("Re-run") { Task { await verify() } }
                // Also while rebuilding: a sweep against a half-regenerated index
                // reports drift that isn't there (see `rebuild`).
                .disabled(isChecking || isRebuilding)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var isChecking: Bool {
        if case .checking = phase { return true }
        return false
    }

    /// Whether anything in the report is a finding `rebaseline()` can actually
    /// resolve. **The engine decides** (`rebaselinableIssues`), because the rule
    /// is not the issue's kind: a checksum mismatch on an *attached* file is rot
    /// in a preservation master, which `rebaseline()` refuses to bless, so
    /// offering the button for it would be a scary confirmation followed by an
    /// unchanged report (review finding, 49).
    private var hasRebaselinableFindings: Bool {
        guard case .done(let findings) = phase else { return false }
        return !findings.report.rebaselinableIssues.isEmpty
    }

    /// Clears one awaited path, then re-verifies so the row goes and the note
    /// takes its place. **Waits for the write to land first** — 52's
    /// `/code-review` lesson, twice paid: mutations are asynchronous, so
    /// draining the error channel or re-sweeping in the same turn reads the
    /// pre-write archive and leaves the row it just cleared.
    private func abandon(_ path: String) {
        abandoning = nil
        Task {
            isRebuilding = true
            model.abandonDelivery(path: path)
            await model.writesSettled()
            isRebuilding = false
            // A refusal (the row resolved itself between the sweep and the
            // click) reaches the model's error channel, which cannot present
            // from behind this sheet — so it is drained and shown locally.
            if let failure = model.actionError {
                model.actionError = nil
                notice = failure
            }
            await verify()
        }
    }

    /// Restores one record. A quarantine notice comes back through `announce`
    /// rather than the window's alert, which is behind this sheet — and so can only
    /// be this restore's, not whatever else was pending (`/code-review`, 58d).
    private func restore(_ plan: Archive.RecordRepairPlan) {
        restoring = nil
        runRecordAction {
            model.repairRecord(
                atPath: plan.path, acceptingInexactRestore: plan.requiresExplicitAcceptance,
                announce: { notice = $0 })
        }
    }

    /// Deletes one missing record. The engine refuses it if anything came back
    /// since the check ran, and the refusal is shown here.
    private func delete(_ plan: Archive.RecordRepairPlan) {
        deleting = nil
        runRecordAction { model.deleteVanishedRecord(atPath: plan.path) }
    }

    /// One record action, then the whole check again — after the write lands, for
    /// `abandon`'s reason — rather than dropping the row: a deleted artifact
    /// takes its payload entries with it, so other rows change too. A failure is
    /// drained into the sheet's own alert, since the window's can't present.
    private func runRecordAction(_ action: () -> Void) {
        isRebuilding = true
        action()
        Task {
            await model.writesSettled()
            isRebuilding = false
            if let failure = model.actionError {
                model.actionError = nil
                notice = failure
            }
            await verify()
        }
    }

    /// **Confirmed, not immediate.** Every other action in this panel is either
    /// read-only or reversible; this one discards the baseline the report is
    /// measured against, and if the mismatch was bit rot rather than the user's
    /// own edit, it is the step that stops the archive ever mentioning it again.
    private func rebaseline() {
        Task {
            isRebuilding = true
            model.rebaseline()
            await model.writesSettled()
            isRebuilding = false
            if let failure = model.actionError {
                model.actionError = nil
                notice = failure
            }
            await verify()
        }
    }

    /// Runs both sweeps and shows what they found.
    ///
    /// - Parameter includingDatalessFiles: Hash the files that aren't downloaded
    ///   to this machine, **downloading them** — only ever `true` from the
    ///   confirmed *Download and Check the Rest*. Every other path (the initial
    ///   `.task`, Re-run, and the re-checks after a repair) leaves them alone, so
    ///   no ordinary use of this panel starts a transfer.
    private func verify(includingDatalessFiles: Bool = false) async {
        phase = .checking(downloading: includingDatalessFiles)
        // Let the spinner paint before the sweep. The hash pass itself runs off
        // the main actor (slice 57b) — a download-and-check has no bound on how
        // long it takes, and a frozen window for the length of a transfer is not
        // a thing to offer a button for.
        await Task.yield()
        let report: IntegrityReport?
        do {
            report = try await model.verifyIntegrity(includingDatalessFiles: includingDatalessFiles)
        } catch {
            phase = .refused((error as? ArchiveError)?.description ?? String(describing: error))
            return
        }
        if let report, let dangling = model.findDanglingReferences() {
            phase = .done(
                Findings(
                    report: report, dangling: dangling,
                    plans: model.recordRepairPlans(forRecordsAt: Self.recordPaths(in: report))))
        } else {
            phase = .unavailable
        }
    }

    /// Pays for the skipped files: downloads each one and hashes it.
    ///
    /// **Read-only, like every other verification** — it transfers bytes onto
    /// this machine and changes nothing in the archive, which is what the
    /// confirmation says. The result replaces the report, so the section
    /// disappears and the headline becomes available for the first time.
    private func downloadAndCheckTheRest() {
        downloading?.cancel()
        downloading = Task { await verify(includingDatalessFiles: true) }
    }

    /// Stops a running download. The report that comes back describes exactly how
    /// far it got — every file it never read is listed as such — so a stopped
    /// check can never be mistaken for a finished one.
    private func stopDownloading() {
        downloading?.cancel()
        downloading = nil
    }

    /// **The re-verify must not overlap the rebuild** (52's `/code-review`).
    /// `rebuildIndex` drops and regenerates the index off the main actor now, so
    /// flipping `isRebuilding` back in the same turn meant the spinner never
    /// appeared *and* the re-verify queried a half-rebuilt index — reporting mass
    /// drift that does not exist. `verifyIntegrity` reads through a handle it
    /// captures rather than holding the lock across its sweep (see
    /// `Archive.withReadState`), so nothing lower down would have stopped it.
    private func rebuild() {
        Task {
            isRebuilding = true
            model.rebuildIndex()
            await model.writesSettled()
            isRebuilding = false
            // A rebuild can resolve index-drift findings — re-verify to reflect it.
            await verify()
        }
    }
}

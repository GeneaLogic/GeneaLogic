//
//  UnreadableRecordRowView.swift
//  GeneaLogicApp
//

import AppKit
import GeneaLogicArchive
import SwiftUI

/// The pinned row that stands where an unreadable record's artifact or person
/// would have been (slice 56).
///
/// Pinned at the top of the list rather than sorted into it, because there is
/// nothing to sort by — the name is what failed to decode — and because damage
/// buried mid-list is damage nobody sees. Not selectable: it carries no `.tag`,
/// so the list's selection (typed to `ArtifactID`/`PersonID`) cannot land on it,
/// which is the honest outcome of having no uid to select *with*.
///
/// **Since 59 it can offer a repair — but only when there is one** (`plan`). 56
/// shipped read-only because every mutation is addressed by uid and the uid was
/// inside the file that failed to parse; what changed is that the index kept the
/// record's bytes (58) and the manifest kept their checksum (49), so the file can
/// be put back and the restoration proved. Where no copy was kept the row is
/// exactly what it was, which is the point: it never offers what it cannot do.
///
/// **Since 58d it also stands for a record whose file is gone** — a third action,
/// Delete, in the context menu (kept off the inline button on the hand-test: it is
/// the rarer choice, and a second button crowds the name). It is undoable, like
/// every other delete. Reveal in Finder goes for those rows: there is no file to
/// reveal.
struct UnreadableRecordRowView: View {
    let row: UnreadableRecordRow
    /// The archive root, for Reveal in Finder.
    let root: URL
    /// What restoring this record would do, or `nil` when nothing was kept for it.
    var plan: Archive.RecordRepairPlan?
    /// Performs the restore, told whether the caller accepted an inexact one.
    var restore: ((_ acceptingInexactRestore: Bool) -> Void)?
    /// Deletes the missing record (58d).
    var delete: (() -> Void)?

    @State private var isConfirmingRestore = false
    @State private var isConfirmingDelete = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                // The identity, on its own line so the headline above it can
                // never be the thing that gets truncated. Middle truncation
                // because a slug's tail ("…-of-sale-1899") distinguishes it as
                // much as its head does.
                Text(row.displayLabel(named: plan?.recordLabel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if canRestore {
                // **Two labels, never one button doing both** (fork a). The exact
                // restore can promise something; the inexact one is a different
                // offer and says so before it is opened, not only inside the
                // confirmation.
                Button(restoreActionTitle) { isConfirmingRestore = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if canRestore {
                Button(restoreActionTitle, systemImage: "arrow.uturn.backward") {
                    isConfirmingRestore = true
                }
            }
            if canDelete {
                Button(Self.deleteActionTitle, systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
            }
            if row.canReveal {
                Button("Reveal in Finder", systemImage: "folder") { reveal() }
            }
        }
        // Double-click reveals too (review finding, 56 — an earlier comment here
        // claimed this and the body didn't do it). A row whose only affordance is
        // hidden behind a right-click is a dead end for anyone who doesn't think
        // to try one, and double-click-to-open is the Mac reflex the row's
        // neighbours already answer to. `contentShape` makes the whole row the
        // target rather than just the glyphs.
        .contentShape(.rect)
        .onTapGesture(count: 2) { if row.canReveal { reveal() } }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            row.accessibilityLabel(
                canRestore: canRestore, canDelete: canDelete, named: plan?.recordLabel))
        // **The row's actions have to be named, not just drawn** (review finding,
        // 59). `children: .combine` plus a hand-written label makes one element
        // whose wording is ours, which is right for a row with nothing to navigate
        // into — and means a button added inside it announces nothing. Both
        // affordances are declared here so VoiceOver reaches the restore by the
        // same rotor the sighted user reaches by clicking, and Reveal in Finder
        // stops being context-menu-only while we are here.
        .accessibilityActions {
            if canRestore {
                Button(restoreActionTitle) { isConfirmingRestore = true }
            }
            if canDelete {
                Button(Self.deleteConfirmTitle) { isConfirmingDelete = true }
            }
            if row.canReveal {
                Button("Reveal in Finder") { reveal() }
            }
        }
        .confirmationDialog(
            Self.restoreDialogTitle, isPresented: $isConfirmingRestore, titleVisibility: .visible
        ) {
            Button(
                Self.restoreConfirmTitle(plan),
                role: plan?.requiresExplicitAcceptance == true ? .destructive : nil
            ) {
                restore?(plan?.requiresExplicitAcceptance == true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.restoreMessage(plan))
        }
        .confirmationDialog(
            Self.deleteDialogTitle, isPresented: $isConfirmingDelete, titleVisibility: .visible
        ) {
            Button(Self.deleteConfirmTitle, role: .destructive) { delete?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.deleteMessage(named: row.displayLabel(named: plan?.recordLabel), kind: row.kind))
        }
    }

    // MARK: - Wording shared with the Verify Integrity panel (58d, fork h)

    // One set of strings for both surfaces (`/code-review`): the same action must
    // not come to be described two ways depending on where it was clicked.

    static let restoreDialogTitle = "Restore this record from GeneaLogic's saved copy?"
    static let deleteDialogTitle = "Delete this missing record?"
    static let deleteConfirmTitle = "Delete Record"
    static let deleteActionTitle = "Delete…"

    /// The button that opens the restore confirmation: two labels, never one
    /// button doing both (59, fork a).
    static func restoreActionTitle(_ plan: Archive.RecordRepairPlan?) -> String {
        plan?.requiresExplicitAcceptance == true ? "Restore Older Copy…" : "Restore…"
    }

    static func restoreConfirmTitle(_ plan: Archive.RecordRepairPlan?) -> String {
        plan?.requiresExplicitAcceptance == true ? "Restore Older Copy" : "Restore Record"
    }

    /// Whether this row can offer a delete: the record's file is gone and a
    /// handler was given.
    private var canDelete: Bool { plan?.isDeletable == true && delete != nil }

    /// The delete confirmation: what happens, and how to take it back. An artifact
    /// goes to the Trash with anything still in its folder — the reason the first
    /// version's "files left" refusal could go.
    static func deleteMessage(named label: String, kind: UnreadableRecordRow.Kind) -> String {
        let named = label.isEmpty ? "This record" : "“\(label)”"
        switch kind {
        case .artifact:
            return "\(named) is no longer in the archive. Deleting it moves what GeneaLogic kept "
                + "of it, and anything still in its folder, to the Trash. You can undo this, or "
                + "restore it from the Trash later."
        case .person, .other:
            return "\(named) is no longer in the archive. Deleting it removes GeneaLogic's saved "
                + "copy too. You can undo this."
        }
    }

    private var helpText: String {
        var lines = [row.detail]
        lines.append(
            row.canReveal ? "\(row.path) — double-click to reveal it in Finder." : row.path)
        return lines.joined(separator: "\n")
    }

    /// Whether this row can offer a restore at all: a copy was kept for it, and a
    /// handler was given to run it. Both halves matter — a preview that passes no
    /// handler must not draw a button that does nothing.
    private var canRestore: Bool { plan != nil && restore != nil }

    /// One name for the action, used by the button, the context menu and the
    /// accessibility action alike, so the three cannot come to say different
    /// things about the same click.
    private var restoreActionTitle: String { Self.restoreActionTitle(plan) }

    /// **It restores the last version *GeneaLogic wrote*, and has to say so**
    /// (fork d). If the file was edited by hand and the edit was good, this
    /// discards it — so the sentence that matters is not "this is safe" but "this
    /// is whose version you are getting, and here is where the other one goes."
    /// The register is `rebaseline()`'s: what will happen, in what order, and what
    /// it costs. Static so the Verify Integrity panel's Restore says the same
    /// thing (58d, fork h).
    static func restoreMessage(_ plan: Archive.RecordRepairPlan?) -> String {
        let ending =
            plan?.replacesFileOnDisk == true
            ? "The file that is there now will be kept in the archive's damaged folder, so "
                + "an edit you made by hand can still be recovered."
            : "There is no file there now, so nothing will be replaced."

        if plan?.isByteExact == true {
            return "GeneaLogic will put back this record exactly as it last wrote it — "
                + "checked against the checksum the archive recorded for it, so the "
                + "restored file is byte-for-byte the original. " + ending
        }
        return "GeneaLogic's saved copy does not match the checksum the archive recorded "
            + "for this file. It is the last version this app could read, and it may be "
            + "missing anything written by a newer version of GeneaLogic. " + ending
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([row.fileURL(in: root)])
    }
}

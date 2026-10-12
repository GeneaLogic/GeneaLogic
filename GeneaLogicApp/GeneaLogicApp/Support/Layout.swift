//
//  Layout.swift
//  GeneaLogicApp
//
//  Named layout metrics — the content widths, sheet sizes, and small repeated chrome
//  that were previously scattered as magic numbers through the views (UI audit F13).
//  Grouping them here makes the intent legible ("this is a content-sheet floor," not
//  "480") and keeps the family of sizes consistent instead of drifting per view.
//

import SwiftUI

enum Layout {
    /// Inset around a sheet's content (all modal sheets share this).
    static let sheetPadding: CGFloat = 20

    /// Square hit area for a borderless icon button (pop-out, ⋯, per-row trash) — a
    /// comfortable target around an otherwise small glyph.
    static let iconButtonHitSize: CGFloat = 28

    /// Corner radius for hover/selection row fills and small inline chips.
    static let rowCornerRadius: CGFloat = 6

    /// Max width of the inspector's editable field column, so text fields don't stretch
    /// to an awkward length in a wide inspector.
    static let fieldColumnMaxWidth: CGFloat = 420

    /// Max width of a readable text block (e.g. the transcript) for comfortable line
    /// length.
    static let readableTextMaxWidth: CGFloat = 640

    /// Max width of a truncating file-name label in a compact file chip.
    static let fileNameChipMaxWidth: CGFloat = 160

    /// A content-heavy, freely-resizable sheet (integrity report, trash, transcript
    /// editor). One shared size keeps them consistent; `maxWidth`/`maxHeight` are
    /// `.infinity` at the call site so they can grow to the screen.
    enum ContentSheet {
        static let minWidth: CGFloat = 500
        static let idealWidth: CGFloat = 580
        static let minHeight: CGFloat = 380
        static let idealHeight: CGFloat = 460
    }

    /// The assertion editor is a *form*: it resizes in width only, its height fitting
    /// the fields.
    ///
    /// The height *floors* matter because `.presentationSizing(.fitted)` sizes a sheet
    /// to its content **once at open and does not regrow** when a control reveals extra
    /// rows mid-sheet — a custom-type field, a Value field, a "With" partner picker
    /// (slices 43b/44i). Without a floor the header and footer clip the moment such a
    /// field appears. `idealHeight` is deliberately *not* set (it would *cap* the fit and
    /// clip a taller static layout); the floor reserves room, `.fitted` still grows past
    /// it for content that's taller.
    enum FormSheet {
        static let minWidth: CGFloat = 420
        static let idealWidth: CGFloat = 460
        static let maxWidth: CGFloat = 640
        /// A compact form that reveals at most a Value/Custom-Type row (the person-fact
        /// edit mode — no evidence context, no partner picker).
        static let compactMinHeight: CGFloat = 360
        /// A form that can reveal a Value row plus a partner picker or evidence context.
        static let minHeight: CGFloat = 460
        /// The recorded-fact form, which additionally carries an Information Quality row.
        static let tallMinHeight: CGFloat = 500
        /// The person-mention form, whose Relationships section grows with the record
        /// (slice 45k) rather than with which optional field is revealed. The floor is
        /// what the common case needs; past it the form **scrolls**, because "how many
        /// relationships does this record state" has no bound a floor could reserve for.
        static let scrollingMinHeight: CGFloat = 520
    }

    /// Trailing inset reserved for an overlay scroll indicator, so it doesn't come down
    /// on top of trailing-edge controls (a row's trash button) when it appears.
    static let scrollIndicatorGutter: CGFloat = 14

    /// Floor for a popped-out file-preview window.
    enum PreviewWindow {
        static let minWidth: CGFloat = 480
        static let minHeight: CGFloat = 360
    }

    /// The family-tree canvas (slice 44). `TreeProjection` emits abstract slots — one
    /// unit per node width, one per generation — and these turn them into points, so
    /// the projection stays free of font metrics.
    enum Tree {
        static let nodeWidth: CGFloat = 168
        static let nodeHeight: CGFloat = 54
        /// Horizontal gap between adjacent node slots.
        static let columnGap: CGFloat = 28
        /// Vertical gap between generations, big enough for the connector elbow.
        static let rowGap: CGFloat = 64
        /// Inset around the whole drawing, so edge nodes aren't flush to the scroller.
        static let canvasPadding: CGFloat = 48

        /// Distance between the left edges of two adjacent slots.
        static var columnPitch: CGFloat { nodeWidth + columnGap }
        /// Distance between the top edges of two adjacent generations.
        static var rowPitch: CGFloat { nodeHeight + rowGap }

        /// Vertical separation between the child-buses of two unions sharing a
        /// generation. Small enough to stay well inside `rowGap`.
        static let busLaneSpacing: CGFloat = 9

        static let minMagnification: CGFloat = 0.25
        static let maxMagnification: CGFloat = 3

        /// The searchable focus-person popover.
        static let focusPickerWidth: CGFloat = 300
        static let focusPickerHeight: CGFloat = 360
    }
}

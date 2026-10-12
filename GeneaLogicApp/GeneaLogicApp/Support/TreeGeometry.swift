//
//  TreeGeometry.swift
//  GeneaLogicApp
//
//  The pixel half of the tree render (slice 44, commit 2). `TreeProjection` emits
//  abstract slots — one unit per node width, one per generation — deliberately
//  free of font metrics, since those are a UI concern. This turns those slots into
//  points for the canvas, and is the *only* place that conversion happens.
//

import GeneaLogicModel
import SwiftUI

/// Maps a `TreeLayout`'s slot coordinates onto the drawing canvas.
struct TreeGeometry {
    let layout: TreeLayout
    /// The topmost generation present, which becomes row 0 on screen (generations are
    /// relative to the focus, so the ancestor rows are negative).
    private let topGeneration: Int

    init(layout: TreeLayout) {
        self.layout = layout
        self.topGeneration = layout.generationRange?.lowerBound ?? 0
    }

    /// The rect a person's card occupies.
    func frame(of node: TreeLayout.Node) -> CGRect {
        CGRect(
            x: Layout.Tree.canvasPadding + node.order * Layout.Tree.columnPitch,
            y: Layout.Tree.canvasPadding
                + CGFloat(node.generation - topGeneration) * Layout.Tree.rowPitch,
            width: Layout.Tree.nodeWidth,
            height: Layout.Tree.nodeHeight
        )
    }

    func frame(of person: PersonID) -> CGRect? {
        layout.node(for: person).map(frame(of:))
    }

    /// The x of a slot's centre — used for connectors, which hang off union midpoints
    /// that fall *between* slots (a couple bar's drop point is at `x.5`).
    func centerX(ofSlot slot: Double) -> CGFloat {
        Layout.Tree.canvasPadding + slot * Layout.Tree.columnPitch + Layout.Tree.nodeWidth / 2
    }

    /// The y of the top edge of a generation's row.
    func rowTop(ofGeneration generation: Int) -> CGFloat {
        Layout.Tree.canvasPadding + CGFloat(generation - topGeneration) * Layout.Tree.rowPitch
    }

    func rowBottom(ofGeneration generation: Int) -> CGFloat {
        rowTop(ofGeneration: generation) + Layout.Tree.nodeHeight
    }

    /// The horizontal bus a union's children hang from: midway down the gap between
    /// the partners' row and the children's row.
    ///
    /// `lane` separates unions that share a generation, whose spans can overlap (a
    /// half-sibling's single-parent union reaches past the full siblings' one). Lane 0
    /// sits at the midpoint and later lanes step *down* toward the children, staying
    /// inside the row gap.
    func busY(belowGeneration generation: Int, lane: Int = 0) -> CGFloat {
        rowBottom(ofGeneration: generation) + Layout.Tree.rowGap / 2
            + CGFloat(lane) * Layout.Tree.busLaneSpacing
    }

    /// The full drawing size, padded on all sides.
    var canvasSize: CGSize {
        let maxSlot = layout.nodes.map(\.order).max() ?? 0
        let rows = (layout.generationRange.map { $0.upperBound - $0.lowerBound } ?? 0) + 1
        return CGSize(
            width: Layout.Tree.canvasPadding * 2 + maxSlot * Layout.Tree.columnPitch
                + Layout.Tree.nodeWidth,
            height: Layout.Tree.canvasPadding * 2 + CGFloat(rows - 1) * Layout.Tree.rowPitch
                + Layout.Tree.nodeHeight
        )
    }
}

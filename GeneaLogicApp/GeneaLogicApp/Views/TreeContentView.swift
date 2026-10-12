//
//  TreeContentView.swift
//  GeneaLogicApp
//
//  The tree drawing: connectors in one Canvas, person cards as real SwiftUI views
//  layered over it (slice 44, commit 2).
//

import GeneaLogicArchive
import GeneaLogicModel
import SwiftUI

/// One generation-and-slot drawing of a `TreeLayout`.
///
/// Connectors go in a single `Canvas` **behind** the cards, in the same coordinate
/// space, because they are pure drawing with no interaction. The cards stay real
/// SwiftUI views so they keep `contextMenu`, hover, and accessibility for free —
/// the reason this is native rather than an SVG in a web view.
struct TreeContentView: View {
    let layout: TreeLayout
    /// Built once per rebuild by `TreeTab` and passed in — constructing it here would
    /// redo an O(n) scan on every body evaluation (hover, focus change, resize).
    let geometry: TreeGeometry
    let personsByID: [PersonID: PersonSummary]
    /// The nature of each qualified parent-child relationship (slice 44f). Absent
    /// means *unspecified*, which draws as a normal solid line — only an explicitly
    /// non-biological link is distinguished, so the drawing never implies a nature
    /// the record doesn't claim.
    let qualifiers: [RelationshipID: FactType]
    /// Refocuses the tree on a person (a card tap).
    let onFocus: (PersonID) -> Void
    /// Jumps to the People tab (a card's context menu).
    let onShowInPeople: (PersonID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                draw(in: &context, geometry: geometry)
            }
            .frame(width: geometry.canvasSize.width, height: geometry.canvasSize.height)
            .accessibilityHidden(true)

            ForEach(layout.nodes) { node in
                let frame = geometry.frame(of: node)
                TreePersonCard(
                    summary: personsByID[node.person],
                    isFocus: node.isFocus,
                    onFocus: { onFocus(node.person) },
                    onShowInPeople: { onShowInPeople(node.person) }
                )
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(
            width: geometry.canvasSize.width,
            height: geometry.canvasSize.height,
            alignment: .topLeading
        )
    }

    // MARK: - Connectors

    private func draw(in context: inout GraphicsContext, geometry: TreeGeometry) {
        let line = Color.secondary.opacity(0.55)
        let lanes = busLanes()

        for union in layout.unions {
            drawCoupleBar(union, in: &context, geometry: geometry, color: line)
            drawChildren(
                union, in: &context, geometry: geometry, color: line,
                lane: lanes[union.id] ?? 0)
        }
        drawRepeats(in: &context, geometry: geometry)
    }

    /// A distinct horizontal lane for each child-bearing union in a generation.
    ///
    /// Two unions in one row can have overlapping bus spans — a half-sibling's union
    /// hangs from a single parent and reaches past the full siblings' union, which
    /// *contains* it. Drawn at the same height the two merge into one line and it
    /// becomes impossible to see which parents a given child hangs from, which is
    /// exactly what the half-sibling grouping exists to show. Sorting by span keeps
    /// the assignment stable rather than dependent on union creation order.
    private func busLanes() -> [TreeLayout.UnionID: Int] {
        var lanes: [TreeLayout.UnionID: Int] = [:]
        let byGeneration = Dictionary(
            grouping: layout.unions.filter { !$0.children.isEmpty }, by: \.generation)
        for (_, unions) in byGeneration where unions.count > 1 {
            let ordered = unions.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.id.raw < rhs.id.raw
            }
            for (index, union) in ordered.enumerated() { lanes[union.id] = index }
        }
        return lanes
    }

    /// The horizontal bar joining a union's partners, drawn across their midlines.
    private func drawCoupleBar(
        _ union: TreeLayout.Union,
        in context: inout GraphicsContext,
        geometry: TreeGeometry,
        color: Color
    ) {
        // Spans the *gap* between the two outermost partners, edge to edge — not
        // centre to centre, which would run the line under (and, for the tinted focus
        // and hover fills, visibly through) the cards themselves.
        let frames = union.partners.compactMap { geometry.frame(of: $0) }.sorted {
            $0.minX < $1.minX
        }
        guard let left = frames.first, let right = frames.last, left.maxX < right.minX
        else { return }
        var path = Path()
        path.move(to: CGPoint(x: left.maxX, y: left.midY))
        path.addLine(to: CGPoint(x: right.minX, y: right.midY))
        context.stroke(path, with: .color(color), lineWidth: 1.5)
    }

    /// The drop from a union to its children: a stem down to a horizontal bus, the bus
    /// across the children, then a short drop into each child's top edge. Orthogonal
    /// elbows, not curves — it reads as a pedigree chart rather than a mind map.
    private func drawChildren(
        _ union: TreeLayout.Union,
        in context: inout GraphicsContext,
        geometry: TreeGeometry,
        color: Color,
        lane: Int
    ) {
        let placedChildren = union.children.compactMap { child -> (PersonID, Double)? in
            layout.node(for: child).map { (child, $0.order) }
        }
        guard !placedChildren.isEmpty else { return }

        let busY = geometry.busY(belowGeneration: union.generation, lane: lane)
        let childTop = geometry.rowTop(ofGeneration: union.generation + 1)
        let stemX = geometry.centerX(ofSlot: union.order)

        // Stem + bus are always solid: they represent the union, not any one link.
        var trunk = Path()
        trunk.move(to: CGPoint(x: stemX, y: geometry.rowBottom(ofGeneration: union.generation)))
        trunk.addLine(to: CGPoint(x: stemX, y: busY))
        let xs = placedChildren.map { geometry.centerX(ofSlot: $0.1) }
        let left = min(xs.min() ?? stemX, stemX)
        let right = max(xs.max() ?? stemX, stemX)
        trunk.move(to: CGPoint(x: left, y: busY))
        trunk.addLine(to: CGPoint(x: right, y: busY))
        context.stroke(trunk, with: .color(color), lineWidth: 1.5)

        // Each child's own drop carries that child's qualifier, so an adopted child in
        // an otherwise biological sibling group is the only dashed line.
        var solid = Path()
        var dashed = Path()
        for (child, slot) in placedChildren {
            let x = geometry.centerX(ofSlot: slot)
            if isNonBiological(child: child, in: union) {
                dashed.move(to: CGPoint(x: x, y: busY))
                dashed.addLine(to: CGPoint(x: x, y: childTop))
            } else {
                solid.move(to: CGPoint(x: x, y: busY))
                solid.addLine(to: CGPoint(x: x, y: childTop))
            }
        }
        context.stroke(solid, with: .color(color), lineWidth: 1.5)
        context.stroke(
            dashed, with: .color(color),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
    }

    /// Whether *any* of this child's links to this union's parents is explicitly
    /// non-biological. A child can be biological to one parent and adoptive to the
    /// other; the tree draws one line per child, so it shows the qualified case and
    /// leaves the per-parent detail to the People tab.
    private func isNonBiological(child: PersonID, in union: TreeLayout.Union) -> Bool {
        union.parentEdges.contains { edge in
            guard edge.child == child, let qualifier = qualifiers[edge.relationship] else {
                return false
            }
            return qualifier != .biologicalParent
        }
    }

    /// Repeat arrivals (pedigree collapse, or a cycle in the data) — the person is
    /// drawn once, so the second link is a dashed cross-edge to the existing card
    /// rather than a duplicate node.
    private func drawRepeats(in context: inout GraphicsContext, geometry: TreeGeometry) {
        guard !layout.repeats.isEmpty else { return }
        var path = Path()
        for repeated in layout.repeats {
            guard let from = geometry.frame(of: repeated.via),
                let to = geometry.frame(of: repeated.person)
            else { continue }
            path.move(to: CGPoint(x: from.midX, y: from.midY))
            path.addLine(to: CGPoint(x: to.midX, y: to.midY))
        }
        context.stroke(
            path,
            with: .color(Color.accentColor.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        )
    }
}

// MARK: - Person card

/// One person in the tree: display name over their EDTF-glossed primary date.
private struct TreePersonCard: View {
    let summary: PersonSummary?
    let isFocus: Bool
    let onFocus: () -> Void
    let onShowInPeople: () -> Void

    @State private var isHovering = false

    /// A person present in the relationship graph but missing from the person list has
    /// been deleted out from under a relationship (§2.3 — removals do not cascade).
    private var isDangling: Bool { summary == nil }

    private var name: String {
        guard let summary else { return "Unknown person" }
        return summary.displayName ?? "Unnamed person"
    }

    private var dateLine: String? {
        guard let raw = summary?.primaryDate else { return nil }
        return EDTFDate.parse(raw)?.humanDescription ?? raw
    }

    var body: some View {
        Button(action: onFocus) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(isFocus ? .semibold : .regular))
                    .foregroundStyle(isDangling ? .secondary : .primary)
                    .lineLimit(1)
                if let dateLine {
                    Text(dateLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            // An **opaque** base under the tint: the cards sit over the connector
            // canvas, so a translucent fill would let a couple bar or drop line show
            // through the card it passes behind.
            .background(
                RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                            .fill(tint)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.rowCornerRadius)
                    .stroke(
                        isFocus ? Color.accentColor : Color.secondary.opacity(0.35),
                        lineWidth: isFocus ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .disabled(isDangling)
        .help(isDangling ? "This person's record was deleted" : "Focus the tree on \(name)")
        .accessibilityLabel(name)
        .contextMenu {
            Button("Focus Here", action: onFocus)
            Button("Show in People", action: onShowInPeople)
        }
    }

    /// Layered over the opaque base, never used alone.
    private var tint: Color {
        if isFocus { return Color.accentColor.opacity(0.18) }
        if isHovering { return Color.secondary.opacity(0.16) }
        return .clear
    }
}

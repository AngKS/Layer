import CoreGraphics
import Foundation
import os

/// The room offered to a node on each axis. Nil on an axis means "take your ideal size".
struct ProposedSize: Equatable, Sendable {
    var width: CGFloat?
    var height: CGFloat?
}

/// Something the layout engine noticed and left alone: it reports, it never corrects.
struct LayoutDiagnostic: Equatable, Sendable {
    /// Only what the engine alone knows. Clipping and small controls are the validator's.
    enum Kind: Equatable, Sendable { case overflow, textTooWide }
    var node: UUID
    var kind: Kind
}

/// Lays out the semantic tree's rows, columns, grids and overlays, with fit, fill and fixed
/// sizing. It is pure and deterministic: the same tree always gets the same frames. No UIKit
/// and no SwiftUI, so it builds on macOS and runs off the main actor.
///
/// Settle, measure, then place. What a free container decides on its own is settled first,
/// inside out (see `settle`). Then rows, columns, grids and overlays measure and place, top
/// down. A width always settles before its height, because a text's height depends on the
/// width it wraps to. Bad numbers (non-finite or negative) read as 0, or as no limit for a
/// minimum or maximum; numbers far too large to be a design's read as the largest that can be
/// (see `maximumLength`), so no frame it writes is ever non-finite.
enum LayoutEngine {
    /// The farthest any position reaches from its parent's origin, and the largest size, in points.
    static let maximumLength: CGFloat = 1_000_000
    /// The largest padding or spacing, in points.
    static let maximumGap: CGFloat = 10_000

    /// The size `node` takes for `proposal`: fixed sizes, natural sizes, or (containers) content plus padding. Text
    /// is measured at the size `tokens` give it, as it is drawn (`NaturalSize.fontSize(of:tokens:)`).
    static func size(of node: LayerNode, proposal: ProposedSize, measure: TextMeasure,
                     tokens: DesignTokens = .standard) -> CGSize {
        var node = node
        settle(&node, previous: nil, placedByParent: true, measure: measure, tokens: tokens)
        let width = Self.width(of: node, offered: offer(proposal.width), measure: measure, tokens: tokens)
        let height = Self.height(of: node, width: width, offered: offer(proposal.height), measure: measure, tokens: tokens)
        return CGSize(width: finite(width), height: finite(height))
    }

    /// Places `node`'s children for `node.frame.size`, recursively, writing their frames.
    ///
    /// A `.free` container leaves its children's frames as they are, except that a container
    /// sized to fit takes the size of what it holds (see `settle`). A free root sized to fit
    /// does too, moving so that nothing it holds moves.
    ///
    /// `previous` is `node` as it was last laid out. A container that is the same as its same-id
    /// one there, at the same size, is left as it is with everything inside it. So diagnostics
    /// come only from the containers laid out this time. Text is measured at the size `tokens` give it; laid out with
    /// other tokens than `previous` was, `previous` is no guide (`TreeRules` passes none then).
    static func layOut(_ node: inout LayerNode, previous: LayerNode?, measure: TextMeasure,
                       tokens: DesignTokens = .standard, diagnostics: inout [LayoutDiagnostic]) {
        settle(&node, previous: previous, placedByParent: false, measure: measure, tokens: tokens)
        place(&node, previous: previous, measure: measure, tokens: tokens, diagnostics: &diagnostics)
    }

    /// Settles what free containers decide on their own, inside out, before anything is placed.
    /// A free container sized to fit hugs what it holds (see `hug`), and a row, column, grid or
    /// overlay sized to fit in a free container takes its fitting size there. Neither depends on
    /// the room a parent offers, so a row or column measuring a free child later only reads it.
    /// `placedByParent` is true under a row, column, grid or overlay, which will write its frame.
    private static func settle(_ node: inout LayerNode, previous: LayerNode?, placedByParent: Bool,
                               measure: TextMeasure, tokens: DesignTokens) {
        guard node.isContainer else { return }
        let free = node.resolvedLayout == .free
        if !isUnchanged(node, since: previous) {
            let earlier = sameIDContainers(in: previous)
            // Hidden children, and what is inside them, are left as they are.
            for index in node.children.indices where node.children[index].isContainer && !node.children[index].isHidden {
                settle(&node.children[index], previous: earlier[node.children[index].id], placedByParent: !free,
                       measure: measure, tokens: tokens)
                if free, let frame = fittedInFreeParent(node.children[index], measure: measure, tokens: tokens) {
                    node.children[index].frame = frame
                }
            }
        }
        // Even unchanged inside, a free container takes the size it hugs, which is the size its
        // place gives it: under a new free parent, a frame a column stretched gives way to it.
        if free { hug(&node, movingItsFrame: !placedByParent) }
    }

    /// Places children, top down, once everything is settled. A free container's children are
    /// already where they go, so it only passes on down.
    private static func place(_ node: inout LayerNode, previous: LayerNode?, measure: TextMeasure, tokens: DesignTokens,
                              diagnostics: inout [LayoutDiagnostic]) {
        guard node.isContainer, !isUnchanged(node, since: previous) else { return }
        #if DEBUG
        countLaidOut(node.id)
        #endif
        // Hidden children take no space, and what is inside them is left as it is.
        let visible = node.children.indices.filter { !node.children[$0].isHidden }
        let earlier = sameIDContainers(in: previous)
        let kids = visible.map { node.children[$0] }
        let placement: Placement
        switch node.resolvedLayout {
        case .free:
            for index in visible {
                place(&node.children[index], previous: earlier[node.children[index].id], measure: measure, tokens: tokens,
                      diagnostics: &diagnostics)
            }
            return
        case .stack(let stack): placement = placeStack(kids, stack, in: contentBox(of: node), measure: measure, tokens: tokens)
        case .grid(let grid): placement = placeGrid(kids, grid, in: contentBox(of: node), measure: measure, tokens: tokens)
        case .overlay(let alignment):
            placement = placeOverlay(kids, alignment, in: contentBox(of: node), measure: measure, tokens: tokens)
        }
        for (index, frame) in zip(visible, placement.frames) {
            node.children[index].frame = written(frame, for: node.children[index])
        }
        if placement.overflows { diagnostics.append(LayoutDiagnostic(node: node.id, kind: .overflow)) }
        for index in visible where hasWordTooWide(node.children[index], measure: measure, tokens: tokens) {
            diagnostics.append(LayoutDiagnostic(node: node.children[index].id, kind: .textTooWide))
        }
        for index in visible {
            place(&node.children[index], previous: earlier[node.children[index].id], measure: measure, tokens: tokens,
                  diagnostics: &diagnostics)
        }
    }

    // MARK: - Sizes

    /// A node's width for the width offered to it (nil = its ideal).
    private static func width(of node: LayerNode, offered: CGFloat?, measure: TextMeasure, tokens: DesignTokens) -> CGFloat {
        switch (node.width.mode, offered) {
        case (.fixed, _): clean(node.frame.size.width)
        case (.fill, let offered?): clamped(offered, node.width)
        default: clamped(fittingWidth(of: node, offered: offered, measure: measure, tokens: tokens), node.width)
        }
    }

    /// A node's height once its width has settled.
    private static func height(of node: LayerNode, width: CGFloat, offered: CGFloat?, measure: TextMeasure,
                               tokens: DesignTokens) -> CGFloat {
        switch (node.height.mode, offered) {
        case (.fixed, _): clean(node.frame.size.height)
        case (.fill, let offered?): clamped(offered, node.height)
        default: clamped(fittingHeight(of: node, width: width, measure: measure, tokens: tokens), node.height)
        }
    }

    /// A leaf's natural width, or a container's content plus padding, at the offered width.
    /// A leaf offered no room at all takes its ideal size, as `TextMeasure` reads a zero width.
    private static func fittingWidth(of node: LayerNode, offered: CGFloat?, measure: TextMeasure,
                                     tokens: DesignTokens) -> CGFloat {
        guard node.isContainer else {
            let room = offered.flatMap { $0 > 0 ? $0 : nil }
            return clean(NaturalSize.of(node, width: room, measure: measure, tokens: tokens).width)
        }
        let padding = cleaned(node.padding)
        let inner = offered.map { max(0, $0 - padding.leading - padding.trailing) }
        return contentWidth(visibleChildren(of: node), node.resolvedLayout, offered: inner, measure: measure, tokens: tokens)
            + padding.leading + padding.trailing
    }

    /// A leaf's natural height, or a container's content plus padding, at a settled width.
    private static func fittingHeight(of node: LayerNode, width: CGFloat, measure: TextMeasure,
                                      tokens: DesignTokens) -> CGFloat {
        guard node.isContainer else {
            return clean(NaturalSize.of(node, width: width > 0 ? width : nil, measure: measure, tokens: tokens).height)
        }
        let padding = cleaned(node.padding)
        let inner = max(0, width - padding.leading - padding.trailing)
        return contentHeight(visibleChildren(of: node), node.resolvedLayout, width: inner, measure: measure, tokens: tokens)
            + padding.top + padding.bottom
    }

    /// How wide a container's content is when it fits it. This asks only for widths (a free
    /// container's children are settled, so it only reads their frames), so measuring a deep tree
    /// never measures a subtree twice over for each level above it.
    private static func contentWidth(_ kids: [LayerNode], _ layout: LayerNode.Layout, offered: CGFloat?,
                                     measure: TextMeasure, tokens: DesignTokens) -> CGFloat {
        guard !kids.isEmpty else { return 0 }
        switch layout {
        case .free:
            return shapesBox(of: kids)?.width ?? 0
        case .stack(let stack):
            let widths = Self.widths(of: kids, in: stack, box: offered, stretching: false, measure: measure, tokens: tokens)
            return stack.axis == .vertical ? widths.max() ?? 0 : widths.reduce(0, +) + gaps(stack.spacing, kids.count)
        case .grid(let grid):
            // Equal columns share the width offered. With none, every column, empty ones included,
            // is as wide as the widest child, so placing at this width gives each child its cell.
            if let offered { return offered }
            let columns = columnCount(grid)
            let widest = kids.map { width(of: $0, offered: nil, measure: measure, tokens: tokens) }.max() ?? 0
            return CGFloat(columns) * widest + gaps(grid.columnSpacing, columns)
        case .overlay:
            return kids.map { width(of: $0, offered: offered, measure: measure, tokens: tokens) }.max() ?? 0
        }
    }

    /// How tall a container's content is when it fits it, at a settled content width.
    private static func contentHeight(_ kids: [LayerNode], _ layout: LayerNode.Layout, width: CGFloat,
                                      measure: TextMeasure, tokens: DesignTokens) -> CGFloat {
        guard !kids.isEmpty else { return 0 }
        switch layout {
        case .free:
            return shapesBox(of: kids)?.height ?? 0
        case .stack(let stack):
            let heights = stackSizes(kids, stack, width: width, height: nil, measure: measure, tokens: tokens).map(\.height)
            return stack.axis == .vertical ? heights.reduce(0, +) + gaps(stack.spacing, kids.count) : heights.max() ?? 0
        case .grid(let grid):
            let sizes = gridSizes(kids, grid, width: width, measure: measure, tokens: tokens)
            let rows = rowHeights(sizes, columns: columnCount(grid))
            return rows.reduce(0, +) + gaps(grid.rowSpacing, rows.count)
        case .overlay:
            return overlaySizes(kids, width: width, height: nil, measure: measure, tokens: tokens).map(\.height).max() ?? 0
        }
    }

    /// Each child's size in a stack whose content box is `width` wide and `height` high (nil
    /// while the stack is fitting its content, when nothing stretches to a height).
    private static func stackSizes(_ kids: [LayerNode], _ stack: LayerNode.Stack, width: CGFloat, height: CGFloat?,
                                   measure: TextMeasure, tokens: DesignTokens) -> [CGSize] {
        let widths = Self.widths(of: kids, in: stack, box: width, stretching: true, measure: measure, tokens: tokens)
        let heights = Self.heights(of: kids, widths: widths, in: stack, box: height, measure: measure, tokens: tokens)
        return zip(widths, heights).map { CGSize(width: $0, height: $1) }
    }

    /// Each child's size in a grid whose content box is `width` wide. Filling children take the
    /// column's width (and, when placed, the row's height); the rest their fixed or natural size
    /// at the column's width.
    private static func gridSizes(_ kids: [LayerNode], _ grid: LayerNode.Grid, width: CGFloat,
                                  measure: TextMeasure, tokens: DesignTokens) -> [CGSize] {
        let column = columnWidth(grid, width)
        return kids.map { kid in
            let childWidth = self.width(of: kid, offered: column, measure: measure, tokens: tokens)
            return CGSize(width: childWidth,
                          height: self.height(of: kid, width: childWidth, offered: nil, measure: measure, tokens: tokens))
        }
    }

    /// Each child's size in an overlay whose content box is `width` wide and `height` high (nil while fitting).
    private static func overlaySizes(_ kids: [LayerNode], width: CGFloat, height: CGFloat?,
                                     measure: TextMeasure, tokens: DesignTokens) -> [CGSize] {
        kids.map { kid in
            let childWidth = self.width(of: kid, offered: width, measure: measure, tokens: tokens)
            return CGSize(width: childWidth,
                          height: self.height(of: kid, width: childWidth, offered: height, measure: measure, tokens: tokens))
        }
    }

    /// Children's widths in a stack whose content is `box` wide (nil = ideal). `stretching` is
    /// false while a column works out how wide it is, so `.fill` alignment doesn't make it greedy.
    /// A stretch leaves a kind with a shape of its own at its size (`NaturalSize.keepsItsShape`).
    private static func widths(of kids: [LayerNode], in stack: LayerNode.Stack, box: CGFloat?, stretching: Bool,
                               measure: TextMeasure, tokens: DesignTokens) -> [CGFloat] {
        guard stack.axis == .vertical else {
            return mainSizes(of: kids, sizing: \.width, room: box, spacing: stack.spacing,
                             takesTheRoomOffered: { takesTheWidthOffered(kids[$0]) }) { index, offered in
                width(of: kids[index], offered: offered, measure: measure, tokens: tokens)
            }
        }
        let stretches = stretching && stack.alignment == .fill
        return kids.map { kid in
            if stretches, let box, kid.width.mode != .fixed, !NaturalSize.keepsItsShape(kid.kind) {
                return clamped(box, kid.width)
            }
            return width(of: kid, offered: box, measure: measure, tokens: tokens)
        }
    }

    /// Children's heights, at their settled widths, in a stack whose content is `box` high.
    private static func heights(of kids: [LayerNode], widths: [CGFloat], in stack: LayerNode.Stack, box: CGFloat?,
                                measure: TextMeasure, tokens: DesignTokens) -> [CGFloat] {
        guard stack.axis == .horizontal else {
            // A fitting height is the same whatever room is offered: it depends on the width alone.
            return mainSizes(of: kids, sizing: \.height, room: box, spacing: stack.spacing,
                             takesTheRoomOffered: { _ in false }) { index, offered in
                height(of: kids[index], width: widths[index], offered: offered, measure: measure, tokens: tokens)
            }
        }
        let stretches = stack.alignment == .fill
        return kids.indices.map { index in
            let kid = kids[index]
            if stretches, let box, kid.height.mode != .fixed, !NaturalSize.keepsItsShape(kid.kind) {
                return clamped(box, kid.height)
            }
            return height(of: kid, width: widths[index], offered: box, measure: measure, tokens: tokens)
        }
    }

    /// Whether a node fitting its width takes some of the width offered, rather than one size
    /// whatever it's offered: a container, or a leaf whose natural width is the width offered.
    private static func takesTheWidthOffered(_ node: LayerNode) -> Bool {
        node.isContainer || NaturalSize.takesTheWidthOffered(node.kind)
    }

    /// Sizes along a stack's axis, sharing the room as SwiftUI's stacks share it. Fixed children
    /// take their size, and so do fitting children whose size doesn't depend on the room offered.
    /// The other fitting children share what is left after the spacing: smallest ideal size first,
    /// each is offered an equal share of what is left and takes what it uses, so a long label
    /// beside a toggle wraps in the room the toggle leaves rather than pushing it out, and two long
    /// labels share a row about half and half. Filling children then share what is left by weight,
    /// each clamped; a share cut by a maximum stays unused. With no room known (the stack is
    /// fitting its content), every child takes its ideal size. Nothing is offered less than room
    /// that is there, so a stack overflows only when what it holds can't fit.
    private static func mainSizes(of kids: [LayerNode], sizing: (LayerNode) -> LayerNode.Sizing, room: CGFloat?,
                                  spacing: CGFloat, takesTheRoomOffered: (Int) -> Bool,
                                  size: (Int, CGFloat?) -> CGFloat) -> [CGFloat] {
        var sizes: [CGFloat?] = kids.indices.map { index in
            switch sizing(kids[index]).mode {
            case .fixed: size(index, nil)
            case .fit: room == nil || !takesTheRoomOffered(index) ? size(index, nil) : nil
            case .fill: room == nil ? size(index, nil) : nil
            }
        }
        guard let room else { return sizes.map { $0 ?? 0 } }
        var left = max(0, room - gaps(spacing, kids.count) - sizes.compactMap { $0 }.reduce(0, +))
        let sharing = kids.indices.filter { sizes[$0] == nil && sizing(kids[$0]).mode == .fit }
        let ideals = sharing.map { size($0, nil) }
        let order = sharing.indices.sorted { (ideals[$0], $0) < (ideals[$1], $1) }
        for (count, place) in order.enumerated() {
            let index = sharing[place]
            let length = size(index, left / CGFloat(order.count - count))
            sizes[index] = length
            left = max(0, left - length)
        }
        let weights = kids.map { weight(of: sizing($0)) }
        let total = weights.reduce(0, +)
        for index in kids.indices where sizes[index] == nil {
            sizes[index] = clamped(total > 0 ? left * weights[index] / total : 0, sizing(kids[index]))
        }
        return sizes.map { $0 ?? 0 }
    }

    // MARK: - Placing

    private struct Placement {
        var frames: [CGRect]
        var overflows: Bool
    }

    /// Where a container's children go: its frame's size, inset by its padding, in its own space.
    private static func contentBox(of node: LayerNode) -> CGRect {
        let padding = cleaned(node.padding)
        return CGRect(
            x: padding.leading, y: padding.top,
            width: max(0, clean(node.frame.size.width) - padding.leading - padding.trailing),
            height: max(0, clean(node.frame.size.height) - padding.top - padding.bottom))
    }

    private static func placeStack(_ kids: [LayerNode], _ stack: LayerNode.Stack, in box: CGRect,
                                   measure: TextMeasure, tokens: DesignTokens) -> Placement {
        let vertical = stack.axis == .vertical
        let sizes = stackSizes(kids, stack, width: box.width, height: box.height, measure: measure, tokens: tokens)
        let along = sizes.map { vertical ? $0.height : $0.width }
        let room = vertical ? box.height : box.width
        let spacing = gap(stack.spacing)
        let needed = along.reduce(0, +) + gaps(spacing, kids.count)
        // Justify spreads leftover room only when no child fills it.
        let fills = kids.contains { (vertical ? $0.height : $0.width).mode.fills }
        let (lead, gap) = distribution(stack.justify, leftover: fills ? 0 : max(0, room - needed), count: kids.count,
                                       spacing: spacing)
        var position = lead
        var frames: [CGRect] = []
        for (size, length) in zip(sizes, along) {
            let cross = vertical
                ? offset(stack.alignment, room: box.width, size: size.width)
                : offset(stack.alignment, room: box.height, size: size.height)
            let origin = vertical
                ? CGPoint(x: box.minX + cross, y: box.minY + position)
                : CGPoint(x: box.minX + position, y: box.minY + cross)
            frames.append(CGRect(origin: origin, size: size))
            position += length + gap
        }
        return Placement(frames: frames, overflows: needed > room + slack)
    }

    private static func placeGrid(_ kids: [LayerNode], _ grid: LayerNode.Grid, in box: CGRect,
                                  measure: TextMeasure, tokens: DesignTokens) -> Placement {
        let columns = columnCount(grid)
        let column = columnWidth(grid, box.width)
        let columnSpacing = gap(grid.columnSpacing)
        let rowSpacing = gap(grid.rowSpacing)
        let sizes = gridSizes(kids, grid, width: box.width, measure: measure, tokens: tokens)
        let rows = rowHeights(sizes, columns: columns)
        var frames: [CGRect] = []
        var top = box.minY
        for (row, rowHeight) in rows.enumerated() {
            for index in (row * columns)..<min((row + 1) * columns, kids.count) {
                var size = sizes[index]
                if kids[index].height.mode.fills { size.height = clamped(rowHeight, kids[index].height) }
                let cellX = box.minX + CGFloat(index - row * columns) * (column + columnSpacing)
                frames.append(CGRect(
                    x: cellX + offset(grid.alignment.horizontal, room: column, size: size.width),
                    y: top + offset(grid.alignment.vertical, room: rowHeight, size: size.height),
                    width: size.width, height: size.height))
            }
            top += rowHeight + rowSpacing
        }
        let needed = rows.reduce(0, +) + gaps(rowSpacing, rows.count)
        let tooWide = sizes.contains { $0.width > column + slack }
        return Placement(frames: frames, overflows: needed > box.height + slack || tooWide)
    }

    private static func placeOverlay(_ kids: [LayerNode], _ alignment: LayerNode.Alignment, in box: CGRect,
                                     measure: TextMeasure, tokens: DesignTokens) -> Placement {
        let sizes = overlaySizes(kids, width: box.width, height: box.height, measure: measure, tokens: tokens)
        let frames = sizes.map { size in
            CGRect(x: box.minX + offset(alignment.horizontal, room: box.width, size: size.width),
                   y: box.minY + offset(alignment.vertical, room: box.height, size: size.height),
                   width: size.width, height: size.height)
        }
        let overflows = sizes.contains { $0.width > box.width + slack || $0.height > box.height + slack }
        return Placement(frames: frames, overflows: overflows)
    }

    /// Where the first child starts and the gap after each, for leftover room spread by `justify`.
    private static func distribution(_ justify: LayerNode.Justify, leftover: CGFloat, count: Int,
                                     spacing: CGFloat) -> (lead: CGFloat, gap: CGFloat) {
        let count = CGFloat(count)
        switch justify {
        case .start: return (0, spacing)
        case .center: return (leftover / 2, spacing)
        case .end: return (leftover, spacing)
        case .spaceBetween: return count > 1 ? (0, spacing + leftover / (count - 1)) : (0, spacing)
        case .spaceAround: return (leftover / count / 2, spacing + leftover / count)
        case .spaceEvenly: return (leftover / (count + 1), spacing + leftover / (count + 1))
        }
    }

    private static func offset(_ alignment: LayerNode.CrossAlignment, room: CGFloat, size: CGFloat) -> CGFloat {
        switch alignment {
        case .start, .fill: 0
        case .center: (room - size) / 2
        case .end: room - size
        }
    }

    private static func offset(_ edge: LayerNode.Edge3, room: CGFloat, size: CGFloat) -> CGFloat {
        switch edge {
        case .start: 0
        case .center: (room - size) / 2
        case .end: room - size
        }
    }

    /// Whether a text leaf holds a word wider than the width its words wrap to, which Core Text
    /// can only break mid-word. `TextMeasure` never measures wider than the width offered, so
    /// when the text is wider than that on one line, its widest word is measured on its own
    /// (once for each text: see `TextMeasure.widestWord`, which keeps the words out of the cache
    /// of texts the layout measures).
    private static func hasWordTooWide(_ node: LayerNode, measure: TextMeasure, tokens: DesignTokens) -> Bool {
        let inset: CGFloat
        switch node.kind {
        case .title, .body, .text: inset = 0
        case .stickyNote: inset = 2 * stickyNoteTextInset
        default: return false
        }
        let text = node.content.text
        let width = max(0, clean(node.frame.size.width) - inset)
        let fontSize = NaturalSize.fontSize(of: node, tokens: tokens), weight = NaturalSize.fontWeight(of: node)
        guard !text.isEmpty,
              measure.size(of: text, fontSize: fontSize, weight: weight, width: nil).width > width + slack else { return false }
        return measure.widestWord(in: text, fontSize: fontSize, weight: weight) > width + slack
    }

    /// How far in from each side a sticky note's words sit, as the canvas draws them.
    private static let stickyNoteTextInset: CGFloat = 12

    // MARK: - Free containers

    /// In a free parent, a row, column, grid or overlay sized to fit takes its fitting size on that
    /// axis. Its top-left corner stays where it is, turned or not. Nil when its frame stays as it is.
    private static func fittedInFreeParent(_ node: LayerNode, measure: TextMeasure, tokens: DesignTokens) -> CGRect? {
        let fitsWidth = node.width.mode == .fit, fitsHeight = node.height.mode == .fit
        guard node.isContainer, node.resolvedLayout != .free, fitsWidth || fitsHeight else { return nil }
        let width = fitsWidth
            ? clean(snap(width(of: node, offered: nil, measure: measure, tokens: tokens))) : clean(node.frame.size.width)
        let height = fitsHeight
            ? clean(snap(height(of: node, width: width, offered: nil, measure: measure, tokens: tokens))) : clean(node.frame.size.height)
        return reframed(node, size: CGSize(width: width, height: height), shift: .zero)
    }

    /// A free container sized to fit hugs its visible children's turned shapes. On each axis that
    /// fits, it takes their box plus its padding, and everything it holds, hidden children too,
    /// moves so that the box starts inside the padding. With nothing visible it fits its padding,
    /// and nothing moves. Unless a laid-out parent will place it, its frame then moves so that
    /// each child stays where it was in the parent's space, turned or not.
    private static func hug(_ node: inout LayerNode, movingItsFrame: Bool) {
        let fitsWidth = node.width.mode == .fit, fitsHeight = node.height.mode == .fit
        guard fitsWidth || fitsHeight else { return }
        let padding = cleaned(node.padding)
        let box = shapesBox(of: visibleChildren(of: node))
        let content = box ?? .zero
        let shift = CGVector(dx: fitsWidth && box != nil ? padding.leading - content.minX : 0,
                             dy: fitsHeight && box != nil ? padding.top - content.minY : 0)
        if shift != .zero {
            for index in node.children.indices {
                let frame = node.children[index].frame
                node.children[index].frame = CGRect(
                    x: finite(finite(frame.origin.x) + shift.dx), y: finite(finite(frame.origin.y) + shift.dy),
                    width: finite(frame.size.width), height: finite(frame.size.height))
            }
        }
        let size = CGSize(
            width: fitsWidth
                ? clean(snap(clamped(content.width + padding.leading + padding.trailing, node.width))) : clean(node.frame.size.width),
            height: fitsHeight
                ? clean(snap(clamped(content.height + padding.top + padding.bottom, node.height))) : clean(node.frame.size.height))
        if movingItsFrame, let frame = reframed(node, size: size, shift: shift) { node.frame = frame }
    }

    /// `node`'s frame at `size` once what it holds has moved by `shift`, placed so that nothing it
    /// holds moves in its parent's space: the point that was at -shift is its new top-left
    /// corner, wherever its turn puts that. Nil when neither changes, so a turned frame doesn't creep.
    private static func reframed(_ node: LayerNode, size: CGSize, shift: CGVector) -> CGRect? {
        guard size != node.frame.size || shift != .zero else { return nil }
        let corner = CGPoint(x: -shift.dx, y: -shift.dy).applying(node.transformToParent)
        var resized = node
        resized.frame = CGRect(origin: .zero, size: size)
        let offset = CGPoint.zero.applying(resized.transformToParent)
        return CGRect(x: finite(corner.x - offset.x), y: finite(corner.y - offset.y), width: size.width, height: size.height)
    }

    /// The box round children's turned shapes, out to whole points, or nil when there are none.
    /// A thousandth of a point is a turn's rounding error, not a reason to take a whole point more.
    private static func shapesBox(of kids: [LayerNode]) -> CGRect? {
        guard !kids.isEmpty else { return nil }
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for kid in kids {
            let frame = kid.frame
            let rect = CGRect(x: finite(frame.origin.x), y: finite(frame.origin.y),
                              width: clean(frame.size.width), height: clean(frame.size.height))
            let degrees = kid.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let shape = degrees == 0 ? rect : TurnedRect(rect: rect, degrees: degrees).bounds
            (minX, minY) = (min(minX, shape.minX), min(minY, shape.minY))
            (maxX, maxY) = (max(maxX, shape.maxX), max(maxY, shape.maxY))
        }
        let left = (minX + roundingError).rounded(.down), top = (minY + roundingError).rounded(.down)
        let right = max(left, (maxX - roundingError).rounded(.up)), bottom = max(top, (maxY - roundingError).rounded(.up))
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static let roundingError: CGFloat = 0.001

    // MARK: - Laying out only what changed

    /// Whether a container is as it was when it was last laid out, at the same size. Where it
    /// sits makes no difference to what is inside it.
    private static func isUnchanged(_ node: LayerNode, since previous: LayerNode?) -> Bool {
        guard let previous, node.frame.size == previous.frame.size else { return false }
        var placed = node
        placed.frame.origin = previous.frame.origin
        return placed == previous
    }

    /// The containers among `previous`'s children, by id, so each can be found as it was last laid
    /// out. A hidden one wasn't: what is inside a hidden child is left as it is, so it may have
    /// changed since it was last laid out without being laid out again. Shown again, it is laid
    /// out in full, as a first layout would.
    private static func sameIDContainers(in previous: LayerNode?) -> [UUID: LayerNode] {
        guard let previous else { return [:] }
        return Dictionary(previous.children.lazy.filter { $0.isContainer && !$0.isHidden }.map { ($0.id, $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Grids

    private static func columnCount(_ grid: LayerNode.Grid) -> Int { min(12, max(1, grid.columns)) }

    static func columnWidth(_ grid: LayerNode.Grid, _ width: CGFloat) -> CGFloat {
        let columns = CGFloat(columnCount(grid))
        return max(0, (width - (columns - 1) * gap(grid.columnSpacing)) / columns)
    }

    private static func rowHeights(_ sizes: [CGSize], columns: Int) -> [CGFloat] {
        stride(from: 0, to: sizes.count, by: columns).map { start in
            sizes[start..<min(start + columns, sizes.count)].map(\.height).max() ?? 0
        }
    }

    // MARK: - Numbers

    /// Half a point is rounding, not overflow.
    private static let slack: CGFloat = 0.5

    /// Frames are whole points, snapped edge by edge so that neighbours that touch still touch.
    /// Drawings keep theirs exact. Anything non-finite is written as 0.
    private static func written(_ frame: CGRect, for node: LayerNode) -> CGRect {
        let x = finite(frame.origin.x), y = finite(frame.origin.y)
        let width = finite(frame.size.width), height = finite(frame.size.height)
        if node.kind == .drawing { return CGRect(x: x, y: y, width: width, height: height) }
        let left = snap(x), top = snap(y)
        return CGRect(x: left, y: top,
                      width: max(0, finite(snap(x + width) - left)), height: max(0, finite(snap(y + height) - top)))
    }

    /// Rounds half up, so a run of edges shifts as one.
    private static func snap(_ value: CGFloat) -> CGFloat { (value + 0.5).rounded(.down) }

    /// A position as the engine reads and writes it: non-finite is 0, and it's never farther than `maximumLength`.
    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? min(max(value, -maximumLength), maximumLength) : 0
    }

    /// A length as the engine reads it: non-finite or negative is 0, and it's never more than `maximumLength`.
    private static func clean(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? min(value, maximumLength) : 0 }

    /// A padding or spacing as the engine reads it: a length, never more than `maximumGap`.
    private static func gap(_ value: CGFloat) -> CGFloat { min(clean(value), maximumGap) }

    /// An offered length: non-finite is no offer (the ideal size), negative is 0.
    private static func offer(_ value: CGFloat?) -> CGFloat? {
        value.flatMap { $0.isFinite ? min(max(0, $0), maximumLength) : nil }
    }

    /// A minimum or maximum: non-finite or negative is no limit.
    private static func limit(_ value: CGFloat?) -> CGFloat? {
        value.flatMap { $0.isFinite && $0 >= 0 ? min($0, maximumLength) : nil }
    }

    /// Within the sizing's maximum, then its minimum (a minimum above the maximum wins).
    private static func clamped(_ value: CGFloat, _ sizing: LayerNode.Sizing) -> CGFloat {
        var value = value
        if let maximum = limit(sizing.maximum) { value = min(value, maximum) }
        if let minimum = limit(sizing.minimum) { value = max(value, minimum) }
        return value
    }

    /// A filling child's weight; a bad one is 0, and so takes no share.
    private static func weight(of sizing: LayerNode.Sizing) -> CGFloat {
        guard case .fill(let weight) = sizing.mode else { return 0 }
        return clean(weight)
    }

    private static func gaps(_ spacing: CGFloat, _ count: Int) -> CGFloat { gap(spacing) * CGFloat(max(0, count - 1)) }

    private static func cleaned(_ padding: LayerNode.Padding) -> LayerNode.Padding {
        LayerNode.Padding(top: gap(padding.top), leading: gap(padding.leading),
                          bottom: gap(padding.bottom), trailing: gap(padding.trailing))
    }

    private static func visibleChildren(of node: LayerNode) -> [LayerNode] { node.children.filter { !$0.isHidden } }
}

private extension LayerNode.Sizing.Mode {
    var fills: Bool {
        if case .fill = self { true } else { false }
    }
}

#if DEBUG
extension LayoutEngine {
    /// Containers laid out, rather than left as they were, since launch. Counted under a lock,
    /// since layouts run on any thread.
    static var containersLaidOut: Int { work.withLock { $0.total } }

    /// How many times the container with this id has been laid out. Tests count this way,
    /// because suites that run alongside lay out containers of their own.
    static func timesLaidOut(_ id: UUID) -> Int { work.withLock { $0.byContainer[id] ?? 0 } }

    fileprivate static func countLaidOut(_ id: UUID) {
        work.withLock { work in
            work.total += 1
            work.byContainer[id, default: 0] += 1
        }
    }

    private static let work = OSAllocatedUnfairLock(initialState: (total: 0, byContainer: [UUID: Int]()))
}
#endif

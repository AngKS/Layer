import CoreGraphics
import Foundation

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
/// Measure, then place. A width always settles before its height, because a text's height
/// depends on the width it wraps to. Bad numbers (non-finite or negative) read as 0, or as no
/// limit for a minimum or maximum, and no frame it writes is ever non-finite.
enum LayoutEngine {
    /// The size `node` takes for `proposal`: fixed sizes, natural sizes, or (containers) content plus padding.
    static func size(of node: LayerNode, proposal: ProposedSize, measure: TextMeasure) -> CGSize {
        let width = Self.width(of: node, offered: offer(proposal.width), measure: measure)
        let height = Self.height(of: node, width: width, offered: offer(proposal.height), measure: measure)
        return CGSize(width: finite(width), height: finite(height))
    }

    /// Places `node`'s children for `node.frame.size`, recursively, writing their frames.
    /// `previous` is not used yet. A `.free` container's children keep their frames.
    static func layOut(_ node: inout LayerNode, previous: LayerNode?, measure: TextMeasure,
                       diagnostics: inout [LayoutDiagnostic]) {
        guard node.isContainer else { return }
        // Hidden children take no space, and their frames and insides are left as they are.
        let visible = node.children.indices.filter { !node.children[$0].isHidden }
        if !visible.isEmpty, let placement = place(node, kids: visible.map { node.children[$0] }, measure: measure) {
            for (index, frame) in zip(visible, placement.frames) {
                node.children[index].frame = written(frame, for: node.children[index])
            }
            if placement.overflows { diagnostics.append(LayoutDiagnostic(node: node.id, kind: .overflow)) }
            for index in visible where hasWordTooWide(node.children[index], measure: measure) {
                diagnostics.append(LayoutDiagnostic(node: node.children[index].id, kind: .textTooWide))
            }
        }
        for index in visible {
            layOut(&node.children[index], previous: nil, measure: measure, diagnostics: &diagnostics)
        }
    }

    // MARK: - Sizes

    /// A node's width for the width offered to it (nil = its ideal).
    private static func width(of node: LayerNode, offered: CGFloat?, measure: TextMeasure) -> CGFloat {
        switch (node.width.mode, offered) {
        case (.fixed, _): clean(node.frame.size.width)
        case (.fill, let offered?): clamped(offered, node.width)
        default: clamped(fittingWidth(of: node, offered: offered, measure: measure), node.width)
        }
    }

    /// A node's height once its width has settled.
    private static func height(of node: LayerNode, width: CGFloat, offered: CGFloat?, measure: TextMeasure) -> CGFloat {
        switch (node.height.mode, offered) {
        case (.fixed, _): clean(node.frame.size.height)
        case (.fill, let offered?): clamped(offered, node.height)
        default: clamped(fittingHeight(of: node, width: width, measure: measure), node.height)
        }
    }

    /// A leaf's natural width, or a container's content plus padding, at the offered width.
    /// A leaf offered no room at all takes its ideal size, as `TextMeasure` reads a zero width.
    private static func fittingWidth(of node: LayerNode, offered: CGFloat?, measure: TextMeasure) -> CGFloat {
        guard node.isContainer else {
            return clean(NaturalSize.of(node, width: offered.flatMap { $0 > 0 ? $0 : nil }, measure: measure).width)
        }
        let layout = node.resolvedLayout
        // Until free containers hug their content, a fitting one keeps its size.
        if layout == .free { return clean(node.frame.size.width) }
        let padding = cleaned(node.padding)
        let inner = offered.map { max(0, $0 - padding.leading - padding.trailing) }
        return contentWidth(visibleChildren(of: node), layout, offered: inner, measure: measure)
            + padding.leading + padding.trailing
    }

    /// A leaf's natural height, or a container's content plus padding, at a settled width.
    private static func fittingHeight(of node: LayerNode, width: CGFloat, measure: TextMeasure) -> CGFloat {
        guard node.isContainer else {
            return clean(NaturalSize.of(node, width: width > 0 ? width : nil, measure: measure).height)
        }
        let layout = node.resolvedLayout
        if layout == .free { return clean(node.frame.size.height) }
        let padding = cleaned(node.padding)
        let inner = max(0, width - padding.leading - padding.trailing)
        return contentHeight(visibleChildren(of: node), layout, width: inner, measure: measure)
            + padding.top + padding.bottom
    }

    /// How wide a container's content is when it fits it. This asks only for widths, so
    /// measuring a deep tree never measures a subtree twice over for each level above it.
    private static func contentWidth(_ kids: [LayerNode], _ layout: LayerNode.Layout, offered: CGFloat?,
                                     measure: TextMeasure) -> CGFloat {
        guard !kids.isEmpty else { return 0 }
        switch layout {
        case .free:
            return 0
        case .stack(let stack):
            let widths = Self.widths(of: kids, in: stack, box: offered, stretching: false, measure: measure)
            return stack.axis == .vertical ? widths.max() ?? 0 : widths.reduce(0, +) + gaps(stack.spacing, kids.count)
        case .grid(let grid):
            // Equal columns share the width offered. With none, every column, empty ones included,
            // is as wide as the widest child, so placing at this width gives each child its cell.
            if let offered { return offered }
            let columns = columnCount(grid)
            let widest = kids.map { width(of: $0, offered: nil, measure: measure) }.max() ?? 0
            return CGFloat(columns) * widest + gaps(grid.columnSpacing, columns)
        case .overlay:
            return kids.map { width(of: $0, offered: offered, measure: measure) }.max() ?? 0
        }
    }

    /// How tall a container's content is when it fits it, at a settled content width.
    private static func contentHeight(_ kids: [LayerNode], _ layout: LayerNode.Layout, width: CGFloat,
                                      measure: TextMeasure) -> CGFloat {
        guard !kids.isEmpty else { return 0 }
        let sizes = childSizes(kids, layout, width: width, height: nil, measure: measure)
        switch layout {
        case .free:
            return 0
        case .stack(let stack):
            let heights = sizes.map(\.height)
            return stack.axis == .vertical ? heights.reduce(0, +) + gaps(stack.spacing, kids.count) : heights.max() ?? 0
        case .grid(let grid):
            let rows = rowHeights(sizes, columns: columnCount(grid))
            return rows.reduce(0, +) + gaps(grid.rowSpacing, rows.count)
        case .overlay:
            return sizes.map(\.height).max() ?? 0
        }
    }

    /// Each child's size in a content box `width` wide and `height` high (nil while the
    /// container is fitting its content, when nothing stretches to a height).
    private static func childSizes(_ kids: [LayerNode], _ layout: LayerNode.Layout, width: CGFloat, height: CGFloat?,
                                   measure: TextMeasure) -> [CGSize] {
        switch layout {
        case .free:
            return kids.map(\.frame.size)
        case .stack(let stack):
            let widths = Self.widths(of: kids, in: stack, box: width, stretching: true, measure: measure)
            let heights = Self.heights(of: kids, widths: widths, in: stack, box: height, measure: measure)
            return zip(widths, heights).map { CGSize(width: $0, height: $1) }
        case .grid(let grid):
            // Filling children take the column's width (and, when placed, the row's height);
            // the rest their fixed or natural size at the column's width.
            let column = columnWidth(grid, width)
            return kids.map { kid in
                let childWidth = self.width(of: kid, offered: column, measure: measure)
                return CGSize(width: childWidth, height: self.height(of: kid, width: childWidth, offered: nil, measure: measure))
            }
        case .overlay:
            return kids.map { kid in
                let childWidth = self.width(of: kid, offered: width, measure: measure)
                return CGSize(width: childWidth, height: self.height(of: kid, width: childWidth, offered: height, measure: measure))
            }
        }
    }

    /// Children's widths in a stack whose content is `box` wide (nil = ideal). `stretching` is
    /// false while a column works out how wide it is, so `.fill` alignment doesn't make it greedy.
    private static func widths(of kids: [LayerNode], in stack: LayerNode.Stack, box: CGFloat?, stretching: Bool,
                               measure: TextMeasure) -> [CGFloat] {
        guard stack.axis == .vertical else {
            return mainSizes(of: kids, sizing: \.width, room: box, spacing: stack.spacing) { index, offered in
                width(of: kids[index], offered: offered, measure: measure)
            }
        }
        let stretches = stretching && stack.alignment == .fill
        return kids.map { kid in
            if stretches, let box, kid.width.mode != .fixed { return clamped(box, kid.width) }
            return width(of: kid, offered: box, measure: measure)
        }
    }

    /// Children's heights, at their settled widths, in a stack whose content is `box` high.
    private static func heights(of kids: [LayerNode], widths: [CGFloat], in stack: LayerNode.Stack, box: CGFloat?,
                                measure: TextMeasure) -> [CGFloat] {
        guard stack.axis == .horizontal else {
            return mainSizes(of: kids, sizing: \.height, room: box, spacing: stack.spacing) { index, offered in
                height(of: kids[index], width: widths[index], offered: offered, measure: measure)
            }
        }
        let stretches = stack.alignment == .fill
        return kids.indices.map { index in
            let kid = kids[index]
            if stretches, let box, kid.height.mode != .fixed { return clamped(box, kid.height) }
            return height(of: kid, width: widths[index], offered: box, measure: measure)
        }
    }

    /// Sizes along a stack's axis. Fixed and fitting children come first: fitting ones are offered
    /// the room the spacing and fixed children leave. Filling children then share what is left by
    /// weight, each clamped; a share cut by a maximum stays unused. With no room known (the stack
    /// is fitting its content), filling children take their fitting size.
    private static func mainSizes(of kids: [LayerNode], sizing: (LayerNode) -> LayerNode.Sizing, room: CGFloat?,
                                  spacing: CGFloat, size: (Int, CGFloat?) -> CGFloat) -> [CGFloat] {
        let spacingTotal = gaps(spacing, kids.count)
        let fixed = kids.indices.filter { sizing(kids[$0]).mode == .fixed }.map { size($0, nil) }.reduce(0, +)
        let fitOffer = room.map { max(0, $0 - spacingTotal - fixed) }
        var sizes: [CGFloat?] = kids.indices.map { index in
            switch sizing(kids[index]).mode {
            case .fixed: size(index, nil)
            case .fit: size(index, fitOffer)
            case .fill: room == nil ? size(index, nil) : nil
            }
        }
        guard let room else { return sizes.map { $0 ?? 0 } }
        let rest = max(0, room - spacingTotal - sizes.compactMap { $0 }.reduce(0, +))
        let weights = kids.map { weight(of: sizing($0)) }
        let total = weights.reduce(0, +)
        for index in kids.indices where sizes[index] == nil {
            sizes[index] = clamped(total > 0 ? rest * weights[index] / total : 0, sizing(kids[index]))
        }
        return sizes.map { $0 ?? 0 }
    }

    // MARK: - Placing

    private struct Placement {
        var frames: [CGRect]
        var overflows: Bool
    }

    /// Children's frames in `node`'s space, or nil for a free container, whose children stay put.
    private static func place(_ node: LayerNode, kids: [LayerNode], measure: TextMeasure) -> Placement? {
        let padding = cleaned(node.padding)
        let box = CGRect(
            x: padding.leading, y: padding.top,
            width: max(0, clean(node.frame.size.width) - padding.leading - padding.trailing),
            height: max(0, clean(node.frame.size.height) - padding.top - padding.bottom))
        switch node.resolvedLayout {
        case .free: return nil
        case .stack(let stack): return placeStack(kids, stack, in: box, measure: measure)
        case .grid(let grid): return placeGrid(kids, grid, in: box, measure: measure)
        case .overlay(let alignment): return placeOverlay(kids, alignment, in: box, measure: measure)
        }
    }

    private static func placeStack(_ kids: [LayerNode], _ stack: LayerNode.Stack, in box: CGRect,
                                   measure: TextMeasure) -> Placement {
        let vertical = stack.axis == .vertical
        let sizes = childSizes(kids, .stack(stack), width: box.width, height: box.height, measure: measure)
        let along = sizes.map { vertical ? $0.height : $0.width }
        let room = vertical ? box.height : box.width
        let spacing = clean(stack.spacing)
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
                                  measure: TextMeasure) -> Placement {
        let columns = columnCount(grid)
        let column = columnWidth(grid, box.width)
        let columnSpacing = clean(grid.columnSpacing)
        let rowSpacing = clean(grid.rowSpacing)
        let sizes = childSizes(kids, .grid(grid), width: box.width, height: nil, measure: measure)
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
                                     measure: TextMeasure) -> Placement {
        let sizes = childSizes(kids, .overlay(alignment), width: box.width, height: box.height, measure: measure)
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
    /// when the text is wider than that on one line, each of its words is measured on its own.
    private static func hasWordTooWide(_ node: LayerNode, measure: TextMeasure) -> Bool {
        let inset: CGFloat
        switch node.kind {
        case .title, .body, .text: inset = 0
        case .stickyNote: inset = 2 * stickyNoteTextInset
        default: return false
        }
        let text = node.content.text
        let width = max(0, clean(node.frame.size.width) - inset)
        let fontSize = NaturalSize.fontSize(of: node), weight = NaturalSize.fontWeight(of: node)
        func tooWide(_ words: String) -> Bool {
            measure.size(of: words, fontSize: fontSize, weight: weight, width: nil).width > width + slack
        }
        guard !text.isEmpty, tooWide(text) else { return false }
        var words = Set<String>()
        text.enumerateSubstrings(in: text.startIndex..., options: .byWords) { word, _, _, _ in
            if let word { words.insert(word) }
        }
        return words.contains(where: tooWide)
    }

    /// How far in from each side a sticky note's words sit, as the canvas draws them.
    private static let stickyNoteTextInset: CGFloat = 12

    // MARK: - Grids

    private static func columnCount(_ grid: LayerNode.Grid) -> Int { min(12, max(1, grid.columns)) }

    private static func columnWidth(_ grid: LayerNode.Grid, _ width: CGFloat) -> CGFloat {
        let columns = CGFloat(columnCount(grid))
        return max(0, (width - (columns - 1) * clean(grid.columnSpacing)) / columns)
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

    private static func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? value : 0 }

    /// A length as the engine reads it: non-finite or negative is 0.
    private static func clean(_ value: CGFloat) -> CGFloat { value.isFinite && value > 0 ? value : 0 }

    /// An offered length: non-finite is no offer (the ideal size), negative is 0.
    private static func offer(_ value: CGFloat?) -> CGFloat? { value.flatMap { $0.isFinite ? max(0, $0) : nil } }

    /// A minimum or maximum: non-finite or negative is no limit.
    private static func limit(_ value: CGFloat?) -> CGFloat? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }

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

    private static func gaps(_ spacing: CGFloat, _ count: Int) -> CGFloat { clean(spacing) * CGFloat(max(0, count - 1)) }

    private static func cleaned(_ padding: LayerNode.Padding) -> LayerNode.Padding {
        LayerNode.Padding(top: clean(padding.top), leading: clean(padding.leading),
                          bottom: clean(padding.bottom), trailing: clean(padding.trailing))
    }

    private static func visibleChildren(of node: LayerNode) -> [LayerNode] { node.children.filter { !$0.isHidden } }
}

private extension LayerNode.Sizing.Mode {
    var fills: Bool {
        if case .fill = self { true } else { false }
    }
}

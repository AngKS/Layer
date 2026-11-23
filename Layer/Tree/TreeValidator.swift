import CoreGraphics
import Foundation

/// The checks every tree can be held to, and the fixes for trees that weren't made by hand:
/// generated and imported ones. Depth counts from the root at 0, so the root's 32nd level
/// of descendants is the deepest allowed. Nothing here recurses deeper than 33 levels, so any
/// input is safe, however deep or large.
///
/// A number is bad when it isn't one a design can hold: not finite, negative where a length
/// is meant, or past what the layout engine reads (`LayoutEngine.maximumLength` for positions
/// and sizes, `maximumGap` for padding, spacing, corner radii and borders, 1,000 points for text,
/// 0 to 1 for opacity and progress).
enum TreeValidator {
    struct Issue: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case notAllowedHere, tooDeep, tooMany, badGeometry, clipped, smallText, smallControl }
        var node: UUID?
        var kind: Kind
    }

    /// The least a button or text field is tall, and the smallest and largest text, in points.
    private static let smallestControlHeight: CGFloat = 44
    private static let smallestText: CGFloat = 11
    private static let largestText: CGFloat = 1_000
    private static let columnRange = 1...12

    // MARK: - Check

    /// Reports; never changes anything. `device` nil = not on a screen. A drawing is allowed only
    /// as a top-level canvas node, so one anywhere inside `root` is not allowed here; `root` itself may be one.
    /// Stops looking past the 5,000th node, and reports a node beyond depth 32 once, not its descendants.
    static func check(_ root: LayerNode, on device: DeviceFrame?) -> [Issue] {
        var issues: [Issue] = []
        let bounds = device.map { CGRect(origin: .zero, size: $0.size).insetBy(dx: -0.01, dy: -0.01) }
        var seen = 0
        // Each node waits with its depth and the screen position of its parent's origin.
        var pending: [(node: LayerNode, depth: Int, origin: CGPoint)] = [(root, 0, .zero)]
        while let (node, depth, parentOrigin) = pending.popLast() {
            seen += 1
            if seen > TreeRules.maximumNodes {
                issues.append(Issue(node: node.id, kind: .tooMany))
                break
            }
            if depth == TreeRules.maximumDepth + 1 { issues.append(Issue(node: node.id, kind: .tooDeep)) }
            if depth > 0 && node.kind == .drawing { issues.append(Issue(node: node.id, kind: .notAllowedHere)) }
            if hasBadNumbers(node) { issues.append(Issue(node: node.id, kind: .badGeometry)) }

            let origin = CGPoint(x: parentOrigin.x + finite(node.frame.origin.x), y: parentOrigin.y + finite(node.frame.origin.y))
            if let bounds {
                let rect = CGRect(origin: origin, size: CGSize(width: finite(node.frame.size.width), height: finite(node.frame.size.height)))
                if !bounds.contains(rect) { issues.append(Issue(node: node.id, kind: .clipped)) }
            }
            if isText(node) && !(NaturalSize.fontSize(of: node) >= smallestText) {
                issues.append(Issue(node: node.id, kind: .smallText))
            }
            if isControl(node) && !(node.frame.size.height >= smallestControlHeight) {
                issues.append(Issue(node: node.id, kind: .smallControl))
            }

            guard !node.children.isEmpty else { continue }
            if !node.isContainer {
                // A child under a leaf: each is reported, and none is looked into.
                for child in node.children { issues.append(Issue(node: child.id, kind: .notAllowedHere)) }
                continue
            }
            // Not pushed past the first level too deep: its own children aren't looked at.
            if depth > TreeRules.maximumDepth { continue }
            for child in node.children.reversed() { pending.append((child, depth + 1, origin)) }
        }
        return issues
    }

    /// Whether any of a node's numbers is bad: its frame, padding, spacing, columns, sizing, angle,
    /// scale, text size, corner radius, border, opacity or progress.
    private static func hasBadNumbers(_ node: LayerNode) -> Bool {
        let frame = node.frame
        if isBadPosition(frame.origin.x) || isBadPosition(frame.origin.y) { return true }
        if isBadLength(frame.size.width) || isBadLength(frame.size.height) { return true }
        let padding = node.padding
        if [padding.top, padding.leading, padding.bottom, padding.trailing].contains(where: isBadGap) { return true }
        switch node.resolvedLayout {
        case .free, .overlay: break
        case .stack(let stack): if isBadGap(stack.spacing) { return true }
        case .grid(let grid):
            if isBadGap(grid.columnSpacing) || isBadGap(grid.rowSpacing) || !columnRange.contains(grid.columns) { return true }
        }
        if isBad(node.width) || isBad(node.height) { return true }
        if node.rotation.map({ !$0.isFinite }) == true || node.scale.map({ !$0.isFinite }) == true { return true }
        let style = node.style
        if style.fontSize.map({ !($0 > 0 && $0 <= largestText) }) == true { return true }
        if style.cornerRadius.map(isBadGap) == true || style.borderWidth.map(isBadGap) == true { return true }
        if style.opacity.map(isBadFraction) == true || node.content.value.map(isBadFraction) == true { return true }
        return false
    }

    private static func isBadPosition(_ number: CGFloat) -> Bool { !(abs(number) <= LayoutEngine.maximumLength) }
    private static func isBadLength(_ number: CGFloat) -> Bool { !(number >= 0 && number <= LayoutEngine.maximumLength) }
    private static func isBadGap(_ number: CGFloat) -> Bool { !(number >= 0 && number <= LayoutEngine.maximumGap) }
    private static func isBadFraction(_ number: Double) -> Bool { !(number >= 0 && number <= 1) }

    private static func isBad(_ sizing: LayerNode.Sizing) -> Bool {
        if case .fill(let weight) = sizing.mode, isBadLength(weight) { return true }
        return sizing.minimum.map(isBadLength) == true || sizing.maximum.map(isBadLength) == true
    }

    private static func finite(_ number: CGFloat) -> CGFloat { number.isFinite ? number : 0 }

    private static func isText(_ node: LayerNode) -> Bool {
        node.kind == .title || node.kind == .body || node.kind == .text
    }

    private static func isControl(_ node: LayerNode) -> Bool {
        node.kind == .button || node.kind == .textField
    }

    // MARK: - Fix

    /// For generated and imported trees only: fixes what can be fixed and reports it. Nodes deeper
    /// than 32 move up beside their depth-32 ancestor, in reading order; nodes past the `limit`th
    /// (5,000th) in reading order, children of leaves and drawings inside the root are dropped.
    /// Bad numbers are brought into range: one that isn't finite or is negative reads as 0 (as
    /// none, for a limit, an angle, a scale, a style or a progress), and one too large as the
    /// largest there can be; columns are clamped to 1-12. Text is raised to 11 pt, and buttons and
    /// text fields whose height is fixed to 44 high. A control the layout sizes is left to it,
    /// as it gets its natural height there, unless its maximum keeps it under 44, which is raised.
    static func fixGenerated(_ root: inout LayerNode, keepingAtMost limit: Int = TreeRules.maximumNodes) -> [Issue] {
        var issues: [Issue] = []
        flatten(&root, depth: 0, issues: &issues)
        var remaining = max(1, min(limit, TreeRules.maximumNodes))
        var dropped: UUID?
        cut(&root, remaining: &remaining, firstDropped: &dropped)
        if let dropped { issues.append(Issue(node: dropped, kind: .tooMany)) }
        fixNodes(&root, issues: &issues)
        return issues
    }

    /// Takes a node at depth 32's descendants out, in reading order, and puts them after it in its
    /// parent's children, each without children of its own. Recursion stops at depth 32.
    private static func flatten(_ node: inout LayerNode, depth: Int, issues: inout [Issue]) {
        if depth == TreeRules.maximumDepth - 1 {
            // Its children are at depth 32, the deepest allowed: they stay, and take what is below them out.
            var index = 0
            while index < node.children.count {
                let lifted = takeDescendants(of: &node.children[index])
                if !lifted.isEmpty { issues.append(Issue(node: node.children[index].id, kind: .tooDeep)) }
                node.children.insert(contentsOf: lifted, at: index + 1)
                index += 1 + lifted.count
            }
            return
        }
        for index in node.children.indices {
            flatten(&node.children[index], depth: depth + 1, issues: &issues)
        }
    }

    /// Every descendant of `node` in reading order, each stripped of its children; `node` ends with none.
    private static func takeDescendants(of node: inout LayerNode) -> [LayerNode] {
        var taken: [LayerNode] = []
        var stack = Array(node.children.reversed())
        node.children = []
        while var current = stack.popLast() {
            stack.append(contentsOf: current.children.reversed())
            current.children = []
            taken.append(current)
        }
        return taken
    }

    /// Keeps the first `remaining` nodes in reading order. Depth is at most 33 levels here.
    private static func cut(_ node: inout LayerNode, remaining: inout Int, firstDropped: inout UUID?) {
        remaining -= 1
        var kept = 0
        for index in node.children.indices {
            if remaining <= 0 {
                if firstDropped == nil { firstDropped = node.children[index].id }
                break
            }
            cut(&node.children[index], remaining: &remaining, firstDropped: &firstDropped)
            kept = index + 1
        }
        if kept < node.children.count { node.children.removeSubrange(kept...) }
    }

    private static func fixNodes(_ node: inout LayerNode, issues: inout [Issue]) {
        if !node.isContainer, !node.children.isEmpty {
            for child in node.children { issues.append(Issue(node: child.id, kind: .notAllowedHere)) }
            node.children = []
        }
        let drawings = node.children.filter { $0.kind == .drawing }
        if !drawings.isEmpty {
            for drawing in drawings { issues.append(Issue(node: drawing.id, kind: .notAllowedHere)) }
            node.children.removeAll { $0.kind == .drawing }
        }
        if fixNumbers(&node) { issues.append(Issue(node: node.id, kind: .badGeometry)) }
        if isText(node) && !(NaturalSize.fontSize(of: node) >= smallestText) {
            node.style.fontSize = smallestText
            issues.append(Issue(node: node.id, kind: .smallText))
        }
        if isControl(node) {
            // Before layout a fit or fill height reads as 0, so only a fixed one can be told short.
            if node.height.mode == .fixed, !(node.frame.size.height >= smallestControlHeight) {
                node.frame.size.height = smallestControlHeight
                issues.append(Issue(node: node.id, kind: .smallControl))
            } else if node.height.mode != .fixed, let maximum = node.height.maximum, maximum < smallestControlHeight {
                node.height.maximum = smallestControlHeight
                issues.append(Issue(node: node.id, kind: .smallControl))
            }
        }
        for index in node.children.indices {
            fixNodes(&node.children[index], issues: &issues)
        }
    }

    /// Brings bad numbers into range and clamps the columns. True if anything changed.
    private static func fixNumbers(_ node: inout LayerNode) -> Bool {
        guard hasBadNumbers(node) else { return false }
        let maximum = LayoutEngine.maximumLength, widest = LayoutEngine.maximumGap
        func position(_ number: CGFloat) -> CGFloat { number.isFinite ? min(max(number, -maximum), maximum) : 0 }
        func length(_ number: CGFloat) -> CGFloat { number.isFinite && number > 0 ? min(number, maximum) : 0 }
        func gap(_ number: CGFloat) -> CGFloat { min(length(number), widest) }
        func limit(_ number: CGFloat) -> CGFloat? { number.isFinite && number >= 0 ? min(number, maximum) : nil }
        func fraction(_ number: Double) -> Double? { number.isFinite ? min(max(number, 0), 1) : nil }
        func sizing(_ sizing: LayerNode.Sizing) -> LayerNode.Sizing {
            var sizing = sizing
            if case .fill(let weight) = sizing.mode { sizing.mode = .fill(weight: length(weight)) }
            sizing.minimum = sizing.minimum.flatMap(limit)
            sizing.maximum = sizing.maximum.flatMap(limit)
            return sizing
        }
        node.frame = CGRect(x: position(node.frame.origin.x), y: position(node.frame.origin.y),
                            width: length(node.frame.size.width), height: length(node.frame.size.height))
        node.padding = LayerNode.Padding(top: gap(node.padding.top), leading: gap(node.padding.leading),
                                         bottom: gap(node.padding.bottom), trailing: gap(node.padding.trailing))
        switch node.layout {
        case .stack(var stack):
            stack.spacing = gap(stack.spacing)
            node.layout = .stack(stack)
        case .grid(var grid):
            grid.columnSpacing = gap(grid.columnSpacing)
            grid.rowSpacing = gap(grid.rowSpacing)
            grid.columns = min(max(grid.columns, columnRange.lowerBound), columnRange.upperBound)
            node.layout = .grid(grid)
        case .free, .overlay, nil: break
        }
        node.width = sizing(node.width)
        node.height = sizing(node.height)
        node.rotation = node.rotation.flatMap { $0.isFinite ? $0 : nil }
        node.scale = node.scale.flatMap { $0.isFinite ? $0 : nil }
        node.style.fontSize = node.style.fontSize.flatMap { $0.isFinite && $0 > 0 ? min($0, largestText) : nil }
        node.style.cornerRadius = node.style.cornerRadius.flatMap { $0.isFinite ? gap($0) : nil }
        node.style.borderWidth = node.style.borderWidth.flatMap { $0.isFinite ? gap($0) : nil }
        node.style.opacity = node.style.opacity.flatMap(fraction)
        node.content.value = node.content.value.flatMap(fraction)
        return true
    }
}

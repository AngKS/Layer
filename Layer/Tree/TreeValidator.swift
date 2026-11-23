import CoreGraphics
import Foundation

/// The checks every tree can be held to, and the fixes for trees that weren't made by hand:
/// generated and imported ones. Depth counts from the root at 0, so the root's 32nd level
/// of descendants is the deepest allowed. Nothing here recurses deeper than 33 levels, so any
/// input is safe, however deep or large.
enum TreeValidator {
    struct Issue: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case notAllowedHere, tooDeep, tooMany, badGeometry, clipped, smallText, smallControl }
        var node: UUID?
        var kind: Kind
    }

    /// The least a button or text field is tall, and the smallest text, in points.
    private static let smallestControlHeight: CGFloat = 44
    private static let smallestText: CGFloat = 11
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
            if hasBadGeometry(node) { issues.append(Issue(node: node.id, kind: .badGeometry)) }

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

    private static func hasBadGeometry(_ node: LayerNode) -> Bool {
        let frame = node.frame
        if !frame.origin.x.isFinite || !frame.origin.y.isFinite { return true }
        if isBad(frame.size.width) || isBad(frame.size.height) { return true }
        let padding = node.padding
        if [padding.top, padding.leading, padding.bottom, padding.trailing].contains(where: isBad) { return true }
        switch node.resolvedLayout {
        case .free, .overlay: break
        case .stack(let stack): if isBad(stack.spacing) { return true }
        case .grid(let grid):
            if isBad(grid.columnSpacing) || isBad(grid.rowSpacing) || !columnRange.contains(grid.columns) { return true }
        }
        return false
    }

    private static func isBad(_ number: CGFloat) -> Bool { !(number.isFinite && number >= 0) }

    private static func finite(_ number: CGFloat) -> CGFloat { number.isFinite ? number : 0 }

    private static func isText(_ node: LayerNode) -> Bool {
        node.kind == .title || node.kind == .body || node.kind == .text
    }

    private static func isControl(_ node: LayerNode) -> Bool {
        node.kind == .button || node.kind == .textField
    }

    // MARK: - Fix

    /// For generated and imported trees only: fixes what can be fixed and reports it. Nodes deeper
    /// than 32 move up beside their depth-32 ancestor, in reading order; nodes past the 5,000th in
    /// reading order, children of leaves and drawings inside the root are dropped; bad numbers
    /// read as 0, columns are clamped to 1-12, buttons and text fields are raised to 44 high and text to 11 pt.
    static func fixGenerated(_ root: inout LayerNode) -> [Issue] {
        var issues: [Issue] = []
        flatten(&root, depth: 0, issues: &issues)
        var remaining = TreeRules.maximumNodes
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
        if fixGeometry(&node) { issues.append(Issue(node: node.id, kind: .badGeometry)) }
        if isText(node) && !(NaturalSize.fontSize(of: node) >= smallestText) {
            node.style.fontSize = smallestText
            issues.append(Issue(node: node.id, kind: .smallText))
        }
        if isControl(node) && !(node.frame.size.height >= smallestControlHeight) {
            node.frame.size.height = smallestControlHeight
            issues.append(Issue(node: node.id, kind: .smallControl))
        }
        for index in node.children.indices {
            fixNodes(&node.children[index], issues: &issues)
        }
    }

    /// Reads bad numbers as 0 and clamps the columns. True if anything changed.
    private static func fixGeometry(_ node: inout LayerNode) -> Bool {
        guard hasBadGeometry(node) else { return false }
        func clean(_ number: CGFloat) -> CGFloat { isBad(number) ? 0 : number }
        node.frame.origin = CGPoint(x: finite(node.frame.origin.x), y: finite(node.frame.origin.y))
        node.frame.size = CGSize(width: clean(node.frame.size.width), height: clean(node.frame.size.height))
        node.padding = LayerNode.Padding(top: clean(node.padding.top), leading: clean(node.padding.leading),
                                         bottom: clean(node.padding.bottom), trailing: clean(node.padding.trailing))
        switch node.layout {
        case .stack(var stack):
            stack.spacing = clean(stack.spacing)
            node.layout = .stack(stack)
        case .grid(var grid):
            grid.columnSpacing = clean(grid.columnSpacing)
            grid.rowSpacing = clean(grid.rowSpacing)
            grid.columns = min(max(grid.columns, columnRange.lowerBound), columnRange.upperBound)
            node.layout = .grid(grid)
        case .free, .overlay, nil: break
        }
        return true
    }
}

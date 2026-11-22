import CoreGraphics

enum LayerLayoutEngine {
    struct Validation: Equatable, Sendable {
        var warnings: [String]
        var clippingCount: Int
    }

    /// Pure, recursive layout resolution. Manual/freeform nodes retain their resolved frame.
    static func resolve(_ nodes: [LayerNode], in bounds: CGRect) -> ([LayerNode], Validation) {
        var warnings: [String] = []
        var clipping = 0
        let resolved = nodes.sorted { $0.zIndex < $1.zIndex }.enumerated().map { _, node -> LayerNode in
            var result = resolveNode(node, in: bounds)
            if let frame = result.resolvedFrame, !bounds.contains(frame) {
                warnings.append("Node \(result.name ?? result.id.uuidString) extends outside the screen")
                clipping += 1
            }
            return result
        }
        return (resolved, Validation(warnings: warnings, clippingCount: clipping))
    }

    private static func resolveNode(_ node: LayerNode, in bounds: CGRect) -> LayerNode {
        var result = node
        if node.sketchIntent?.placementIsAuthoritative == true,
           let frame = node.resolvedFrame,
           frame.minX >= bounds.minX || frame.minY >= bounds.minY {
            result.resolvedFrame = frame
            return result
        }
        if node.isContainer {
            result.resolvedFrame = bounds
            result.children = layoutChildren(node.children, layout: node.layout, in: bounds)
        } else if let frame = node.resolvedFrame {
            result.resolvedFrame = frame
        } else {
            result.resolvedFrame = CGRect(origin: bounds.origin, size: intrinsicSize(for: node))
        }
        return result
    }

    private static func layoutChildren(_ children: [LayerNode], layout: LayerNode.LayoutSpec, in bounds: CGRect) -> [LayerNode] {
        guard !children.isEmpty else { return [] }
        switch layout.kind {
        case .overlay:
            return children.enumerated().map { index, child in
                var result = resolveNode(child, in: bounds)
                result.zIndex = max(result.zIndex, index)
                return result
            }
        case .grid:
            let columns = max(1, layout.columns)
            let spacing = layout.spacing
            let columnWidth = max(0, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let rows = stride(from: 0, to: children.count, by: columns).count
            let rowHeight = rows == 0 ? 0 : max(44, (bounds.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            return children.enumerated().map { index, child in
                let row = index / columns
                let column = index % columns
                let frame = CGRect(
                    x: bounds.minX + CGFloat(column) * (columnWidth + spacing),
                    y: bounds.minY + CGFloat(row) * (rowHeight + spacing),
                    width: columnWidth,
                    height: rowHeight
                )
                return resolveNode(child, in: frame)
            }
        default:
            let axisIsRow = layout.kind == .row
            let count = CGFloat(children.count)
            let available = axisIsRow ? bounds.width : bounds.height
            let spacing = layout.spacing
            let cell = max(0, (available - spacing * max(0, count - 1)) / count)
            var cursor = axisIsRow ? bounds.minX : bounds.minY
            return children.map { child in
                var frame: CGRect
                if axisIsRow {
                    frame = CGRect(x: cursor, y: bounds.minY, width: cell, height: bounds.height)
                    cursor += cell + spacing
                } else {
                    frame = CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: cell)
                    cursor += cell + spacing
                }
                return resolveNode(child, in: frame)
            }
        }
    }

    private static func intrinsicSize(for node: LayerNode) -> CGSize {
        switch node.kind {
        case .button: CGSize(width: 160, height: 44)
        case .textField: CGSize(width: 240, height: 44)
        case .divider: CGSize(width: 240, height: 1)
        case .icon: CGSize(width: 44, height: 44)
        case .title: CGSize(width: 240, height: 40)
        case .text, .body: CGSize(width: 240, height: 44)
        case .image: CGSize(width: 240, height: 160)
        default: CGSize(width: 44, height: 44)
        }
    }
}

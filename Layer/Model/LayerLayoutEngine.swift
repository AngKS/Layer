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
        let sorted = nodes.sorted { $0.zIndex < $1.zIndex }
        var cursor = bounds.minY
        var resolved: [LayerNode] = []
        for node in sorted {
            let available = CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: max(0, bounds.maxY - cursor))
            var result = resolveNode(node, in: available)
            if node.sketchIntent?.placementIsAuthoritative == true,
               let frame = result.resolvedFrame {
                resolved.append(result)
                cursor = max(cursor, frame.maxY)
                continue
            }
            if let frame = result.resolvedFrame {
                cursor = frame.maxY
            }
            if let frame = result.resolvedFrame, !bounds.contains(frame) {
                warnings.append("Node \(result.name ?? result.id.uuidString) extends outside the screen")
                clipping += 1
            }
            resolved.append(result)
        }
        return (resolved, Validation(warnings: warnings, clippingCount: clipping))
    }

    private static func resolveNode(_ node: LayerNode, in bounds: CGRect) -> LayerNode {
        var result = node
        if node.sketchIntent?.placementIsAuthoritative == true,
           let frame = node.resolvedFrame {
            result.resolvedFrame = frame.integral
            return result
        }
        if node.isContainer {
            let padded = bounds.insetBy(dx: node.layout.padding, dy: node.layout.padding)
            let intrinsic = CGSize(
                width: resolvedDimension(node.layout.width, available: bounds.width, intrinsic: bounds.width),
                height: resolvedDimension(node.layout.height, available: bounds.height, intrinsic: containerHeight(node, in: padded))
            )
            let frame = alignedFrame(size: intrinsic, in: bounds, alignment: node.layout.alignment)
            result.resolvedFrame = frame
            result.children = layoutChildren(node.children, layout: node.layout, in: frame.insetBy(dx: node.layout.padding, dy: node.layout.padding))
        } else if let frame = node.resolvedFrame {
            result.resolvedFrame = frame.integral
        } else {
            let intrinsic = intrinsicSize(for: node)
            let size = CGSize(
                width: resolvedDimension(node.layout.width, available: bounds.width, intrinsic: intrinsic.width),
                height: resolvedDimension(node.layout.height, available: bounds.height, intrinsic: intrinsic.height)
            )
            result.resolvedFrame = alignedFrame(size: size, in: bounds, alignment: node.layout.alignment)
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
            let spacing = max(0, layout.spacing)
            let available = axisIsRow ? bounds.width : bounds.height
            let fixedSpace = spacing * max(0, count - 1)
            let flexCount = children.filter {
                $0.layout.width.sizing == .fill ||
                (axisIsRow == false && $0.layout.height.sizing == .fill)
            }.count
            let fixedWidth = children.reduce(CGFloat.zero) { sum, child in
                let spec = axisIsRow ? child.layout.width : child.layout.height
                switch spec.sizing {
                case .fixed: return sum + (spec.value ?? 0)
                case .intrinsic:
                    return sum + (axisIsRow ? intrinsicSize(for: child).width : intrinsicSize(for: child).height)
                case .fractional:
                    return sum
                case .fill:
                    return sum
                }
            }
            let remaining = max(0, available - fixedSpace - fixedWidth)
            var cursor = axisIsRow ? bounds.minX : bounds.minY
            return children.map { child in
                let widthSpec = axisIsRow ? child.layout.width : child.layout.height
                let cell: CGFloat
                switch widthSpec.sizing {
                case .fixed:
                    cell = widthSpec.value ?? intrinsicSize(for: child).width
                case .fractional:
                    cell = remaining * min(1, max(0, widthSpec.fraction ?? 1))
                case .fill:
                    cell = flexCount > 0 ? remaining / CGFloat(flexCount) : 0
                case .intrinsic:
                    cell = axisIsRow ? intrinsicSize(for: child).width : intrinsicSize(for: child).height
                }
                var frame: CGRect
                if axisIsRow {
                    frame = CGRect(x: cursor, y: bounds.minY, width: cell, height: bounds.height)
                    cursor += cell + spacing
                } else {
                    frame = CGRect(x: bounds.minX, y: cursor, width: bounds.width, height: max(cell, intrinsicSize(for: child).height))
                    cursor += cell + spacing
                }
                return resolveNode(child, in: frame)
            }
        }
    }

    private static func resolvedDimension(_ spec: LayerNode.SizeSpec, available: CGFloat, intrinsic: CGFloat) -> CGFloat {
        switch spec.sizing {
        case .fixed: return min(available, spec.value ?? intrinsic)
        case .fill: return available
        case .fractional: return available * min(1, max(0, spec.fraction ?? 1))
        case .intrinsic: return intrinsic
        }
    }

    private static func alignedFrame(size: CGSize, in bounds: CGRect, alignment: LayerNode.Alignment) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x: CGFloat
        switch alignment {
        case .trailing: x = bounds.maxX - width
        case .center: x = bounds.midX - width / 2
        default: x = bounds.minX
        }
        let y: CGFloat
        switch alignment {
        case .bottom: y = bounds.maxY - height
        case .top: y = bounds.minY
        default: y = bounds.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func containerHeight(_ node: LayerNode, in bounds: CGRect) -> CGFloat {
        let spacing = max(0, node.layout.spacing)
        switch node.layout.kind {
        case .grid:
            let columns = max(1, node.layout.columns)
            let rows = Int(ceil(CGFloat(node.children.count) / CGFloat(columns)))
            return CGFloat(rows) * 44 + spacing * CGFloat(max(0, rows - 1))
        case .row:
            return node.children.map { intrinsicSize(for: $0).height }.max() ?? 44
        case .overlay:
            return node.children.map { intrinsicSize(for: $0).height }.max() ?? 44
        default:
            return node.children.reduce(CGFloat.zero) { sum, child in
                sum + intrinsicSize(for: child).height
            } + spacing * CGFloat(max(0, node.children.count - 1))
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

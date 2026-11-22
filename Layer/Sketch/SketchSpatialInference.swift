import CoreGraphics

enum SketchSpatialInference {
    /// Builds conservative semantic containers from confident geometry relationships.
    /// Low-confidence structures remain detached/freeform nodes.
    static func infer(from nodes: [LayerNode]) -> [LayerNode] {
        let meaningful = nodes.filter { $0.kind != .drawing && $0.kind != .shape }
        guard meaningful.count >= 2 else { return nodes }

        let horizontalPairs = pairs(in: meaningful) { a, b in
            verticalOverlap(a, b) >= 0.5 &&
            abs((a.resolvedFrame?.midY ?? 0) - (b.resolvedFrame?.midY ?? 0)) < 20 &&
            abs((a.resolvedFrame?.midX ?? 0) - (b.resolvedFrame?.midX ?? 0)) < 240
        }
        if horizontalPairs.count == 1,
           let pair = horizontalPairs.first,
           let a = pair.a.resolvedFrame,
           let b = pair.b.resolvedFrame {
            let union = a.union(b)
            let row = LayerNode(
                kind: .row,
                name: "Inferred Row",
                children: [pair.a, pair.b].sorted { ($0.resolvedFrame?.minX ?? 0) < ($1.resolvedFrame?.minX ?? 0) },
                layout: LayerNode.LayoutSpec(kind: .row, width: .init(sizing: .fixed, value: union.width), height: .init(sizing: .fixed, value: union.height), spacing: max(8, b.minX - a.maxX)),
                resolvedFrame: union,
                zIndex: pair.a.zIndex
            )
            return replace(Set([pair.a.id, pair.b.id]), with: row, in: nodes)
        }

        let gridCells = meaningful.filter { $0.resolvedFrame != nil }
        if gridCells.count >= 4 {
            let xs = Set(gridCells.compactMap { $0.resolvedFrame.map { Int($0.midX.rounded()) } })
            let ys = Set(gridCells.compactMap { $0.resolvedFrame.map { Int($0.midY.rounded()) } })
            if xs.count >= 2, ys.count >= 2 {
                let union = gridCells.compactMap(\.resolvedFrame).dropFirst().reduce(gridCells.compactMap(\.resolvedFrame).first ?? .zero) { $0.union($1) }
                let grid = LayerNode(
                    kind: .grid,
                    name: "Inferred Grid",
                    children: gridCells.sorted {
                        let ay = $0.resolvedFrame?.minY ?? 0
                        let by = $1.resolvedFrame?.minY ?? 0
                        if abs(ay - by) < 12 { return ($0.resolvedFrame?.minX ?? 0) < ($1.resolvedFrame?.minX ?? 0) }
                        return ay < by
                    },
                    layout: LayerNode.LayoutSpec(kind: .grid, width: .init(sizing: .fill), height: .init(sizing: .intrinsic), columns: xs.count, spacing: 12),
                    resolvedFrame: union
                )
                return replace(Set(gridCells.map(\.id)), with: grid, in: nodes)
            }
        }
        return nodes
    }

    private struct Pair { let a: LayerNode; let b: LayerNode }
    private static func pairs(in nodes: [LayerNode], where condition: (LayerNode, LayerNode) -> Bool) -> [Pair] {
        var found: [Pair] = []
        for (i, a) in nodes.enumerated() {
            for b in nodes.dropFirst(i + 1) where condition(a, b) { found.append(Pair(a: a, b: b)) }
        }
        return found
    }

    private static func verticalOverlap(_ a: LayerNode, _ b: LayerNode) -> CGFloat {
        guard let ar = a.resolvedFrame, let br = b.resolvedFrame else { return 0 }
        let overlap = min(ar.maxY, br.maxY) - max(ar.minY, br.minY)
        return overlap / max(1, min(ar.height, br.height))
    }

    private static func replace(_ ids: Set<UUID>, with container: LayerNode, in nodes: [LayerNode]) -> [LayerNode] {
        var result: [LayerNode] = []
        var inserted = false
        for node in nodes {
            if ids.contains(node.id) {
                if !inserted { result.append(container); inserted = true }
            } else {
                result.append(node)
            }
        }
        return result
    }
}

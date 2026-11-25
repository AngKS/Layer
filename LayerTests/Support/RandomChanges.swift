import CoreGraphics
import Foundation
@testable import Layer

/// A random number generator that gives the same numbers for the same seed (SplitMix64), so that a run of random
/// changes is the same run every time it fails.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random changes made through a store's own verbs, each chosen by a seeded generator from what the design holds now:
/// moves, resizes, turns, locks, hides, words, looks, adds, deletes, moves to another parent, reorders, wraps, unwraps,
/// duplicates, a canvas node's scale, a screen's device, the text's size, a container's layout, undo and redo. Many are
/// refused by the store in some states; a refused one changes nothing, which the store's checks then see too.
@MainActor
struct RandomChanges {
    let store: DesignStore
    let undo: UndoManager
    var random: SeededGenerator
    /// No adds or duplicates past this many nodes, so that a long run stays small.
    var largest = 250

    /// A node of the design, as the run picks one.
    private struct Picked {
        var node: LayerNode
        var parent: NodeParent?
        var onCanvasTop: Bool
    }

    /// Every node, depth first, screens before the canvas, with what holds it (nil for a screen's root).
    private func everything() -> [Picked] {
        var found: [Picked] = []
        func visit(_ node: LayerNode, in parent: NodeParent?, onCanvasTop: Bool) {
            found.append(Picked(node: node, parent: parent, onCanvasTop: onCanvasTop))
            for child in node.children { visit(child, in: .node(node.id), onCanvasTop: false) }
        }
        for screen in store.tree.screens { visit(screen.root, in: nil, onCanvasTop: false) }
        for node in store.tree.canvas { visit(node, in: .canvas, onCanvasTop: true) }
        return found
    }

    /// Makes one random change and says what it was.
    mutating func change() -> String {
        let all = everything()
        let movable = all.filter { $0.parent != nil }
        let containers = all.filter(\.node.isContainer)
        let small = all.count < largest
        switch Int.random(in: 0..<20, using: &random) {
        case 0:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to move" }
            let dx = CGFloat(Int.random(in: -30...30, using: &random)), dy = CGFloat(Int.random(in: -30...30, using: &random))
            store.update(picked.node.id) { $0.frame.origin.x += dx; $0.frame.origin.y += dy }
            return "move"
        case 1:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to resize" }
            let grow = CGFloat(Int.random(in: -10...40, using: &random))
            store.update(picked.node.id) { $0.frame.size.width = max(1, $0.frame.size.width + grow) }
            return "resize"
        case 2:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to turn" }
            let degrees: Double? = Bool.random(using: &random) ? Double(Int.random(in: 0..<360, using: &random)) : nil
            store.update(picked.node.id) { $0.rotation = degrees }
            return "turn"
        case 3:
            guard let picked = all.randomElement(using: &random) else { return "nothing to lock" }
            store.update(picked.node.id) { $0.isLocked.toggle() }
            return "lock"
        case 4:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to hide" }
            store.update(picked.node.id) { $0.isHidden.toggle() }
            return "hide"
        case 5:
            guard let picked = all.filter({ $0.node.kind.hasText }).randomElement(using: &random) else { return "no words" }
            let words = String(repeating: "word ", count: Int.random(in: 1...8, using: &random))
            store.update(picked.node.id) { $0.content.text = words }
            return "words"
        case 6:
            guard let picked = all.randomElement(using: &random) else { return "nothing to restyle" }
            let tint = RGBColor(hex: UInt32.random(in: 0...0xFFFFFF, using: &random))
            store.update(picked.node.id) { $0.style.tint = tint; $0.style.hasShadow.toggle() }
            return "look"
        case 7:
            guard small else { return "too large to add" }
            var leaf = LayerNode(kind: Bool.random(using: &random) ? .text : .shape)
            leaf.frame = CGRect(x: CGFloat(Int.random(in: 0...200, using: &random)), y: CGFloat(Int.random(in: 0...400, using: &random)),
                                width: 60, height: 24)
            leaf.content.text = "Added"
            let targets: [NodeParent] = containers.map { .node($0.node.id) } + store.tree.screens.map { .screen($0.id) } + [.canvas]
            guard let parent = targets.randomElement(using: &random) else { return "nowhere to add" }
            if parent == .canvas { leaf.scale = 1 }
            store.add(leaf, to: parent, at: nil)
            return "add"
        case 8:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to delete" }
            store.delete(nodes: [picked.node.id])
            return "delete"
        case 9:
            guard let picked = movable.randomElement(using: &random) else { return "nothing to reparent" }
            let targets: [NodeParent] = containers.map { .node($0.node.id) } + store.tree.screens.map { .screen($0.id) } + [.canvas]
            guard let parent = targets.randomElement(using: &random) else { return "nowhere to go" }
            let place = Bool.random(using: &random) ? 0 : nil
            store.move(picked.node.id, to: parent, at: place)
            return "reparent"
        case 10:
            let parents: [(NodeParent, [LayerNode])] = containers.map { (.node($0.node.id), $0.node.children) }
                + store.tree.screens.map { (.screen($0.id), $0.root.children) }
            guard let (parent, children) = parents.filter({ $0.1.count > 1 }).randomElement(using: &random) else { return "nothing to reorder" }
            store.reorder([parent: children.map(\.id).shuffled(using: &random)])
            return "reorder"
        case 11:
            let lists = containers.map(\.node.children) + store.tree.screens.map(\.root.children)
            guard let list = lists.filter({ $0.count > 1 }).randomElement(using: &random) else { return "nothing to wrap" }
            let first = Int.random(in: 0..<(list.count - 1), using: &random)
            store.wrap([list[first].id, list[first + 1].id], in: Bool.random(using: &random) ? .group : .card,
                       layout: Bool.random(using: &random) ? .free : .stack(LayerNode.Stack(axis: .vertical, spacing: 8)))
            return "wrap"
        case 12:
            guard let picked = containers.filter({ $0.parent != nil }).randomElement(using: &random) else { return "nothing to unwrap" }
            store.unwrap(picked.node.id)
            return "unwrap"
        case 13:
            guard small, let picked = movable.randomElement(using: &random) else { return "nothing to duplicate" }
            store.duplicate(node: picked.node.id)
            return "duplicate"
        case 14:
            guard let top = store.tree.canvas.randomElement(using: &random) else { return "no canvas node" }
            let scale = [0.5, 0.75, 1, 1.5][Int.random(in: 0..<4, using: &random)]
            store.update(top.id) { $0.scale = CGFloat(scale) }
            return "canvas scale"
        case 15:
            guard let screen = store.tree.screens.randomElement(using: &random) else { return "no screen" }
            let device = [nil, "ipad", "iphone-se"][Int.random(in: 0..<3, using: &random)]
            store.setDevice(of: screen.id, to: device)
            return "device"
        case 16:
            let size = CGFloat(Int.random(in: 12...24, using: &random))
            store.updateCanvas { $0.tokens.textSizes.text = size }
            return "text size"
        case 17:
            guard let picked = containers.randomElement(using: &random) else { return "no container" }
            let layouts: [LayerNode.Layout] = [.free, .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)),
                                               .stack(LayerNode.Stack(axis: .vertical, spacing: 12)), .grid(LayerNode.Grid(columns: 2))]
            store.setLayout(picked.node.id, layouts[Int.random(in: 0..<layouts.count, using: &random)])
            return "layout"
        case 18:
            if undo.canUndo { undo.undo() }
            return "undo"
        default:
            if undo.canRedo { undo.redo() }
            return "redo"
        }
    }
}

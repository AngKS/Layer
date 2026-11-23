import Foundation

/// What a change touched, on the tree: the nodes it added, removed or altered, the screens it
/// added, removed or altered and those it put a node on or took one off, and whether it changed
/// the board. A node is compared as `TreeRecords` keeps it: its fields without its children,
/// its parent and its pose in its host, so that a pure reorder touches nothing, as today, and
/// neither does a container fitted again round what it holds, to what is inside. A node moved
/// from one container to another touches both, as one moved between hosts touches both hosts:
/// a change that made a container meets one that put something in it.
/// The undo history asks it whether two changes meet, and which screen a step was to.
struct TreeChange: Sendable {
    var nodes: Set<UUID> = []
    var screens: Set<TreeScreen.ID> = []
    /// The title, the settings, or what this version didn't understand of the content or its
    /// manifest, the canvas nodes it couldn't read among them.
    var board = false

    init() {}

    init(from before: TreeContent, to after: TreeContent) {
        board = before.title != after.title || before.settings != after.settings
            || before.unknownKeys != after.unknownKeys || before.manifestUnknownKeys != after.manifestUnknownKeys
            || before.unreadCanvas != after.unreadCanvas
        guard before.screens != after.screens || before.canvas != after.canvas else { return }
        // A host the same on both sides holds the same nodes the same way: not looked into.
        let alike = TreeRecords.hosts(alikeIn: [before, after])
        let was = TreeRecords(before, leavingWhole: alike), now = TreeRecords(after, leavingWhole: alike)
        for id in Set(was.records.keys).union(now.records.keys) {
            let old = was.records[id], new = now.records[id]
            if let old, let new, old.isSame(as: new) { continue }
            nodes.insert(id)
            if let old, let new, old.parent != new.parent {
                for case .node(let parent) in [old.parent, new.parent] where was.records[parent] != nil || now.records[parent] != nil {
                    nodes.insert(parent)
                }
            }
            // Added, removed, or moved to another host: the hosts are touched too.
            guard old?.host != new?.host else { continue }
            for case .screen(let screen)? in [old?.host, new?.host] { screens.insert(screen) }
        }
        // Nodes that share an id with another, which only a damaged design has, are compared
        // whole, those of each id in turn.
        if !was.passengers.isEmpty || !now.passengers.isEmpty {
            let old = Dictionary(grouping: was.passengers, by: \.node.id), new = Dictionary(grouping: now.passengers, by: \.node.id)
            for id in Set(old.keys).union(new.keys) {
                let oldOnes = old[id] ?? [], newOnes = new[id] ?? []
                guard oldOnes.count != newOnes.count || zip(oldOnes, newOnes).contains(where: { !$0.isSame(as: $1) }) else { continue }
                nodes.insert(id)
                guard oldOnes.map(\.host) != newOnes.map(\.host) else { continue }
                for case .screen(let screen) in (oldOnes + newOnes).map(\.host) { screens.insert(screen) }
            }
        }
        let screensBefore = Dictionary(was.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let screensAfter = Dictionary(now.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(screensBefore.keys).union(screensAfter.keys) where screensBefore[id] != screensAfter[id] {
            screens.insert(id)
        }
    }

    mutating func formUnion(_ other: TreeChange) {
        nodes.formUnion(other.nodes)
        screens.formUnion(other.screens)
        board = board || other.board
    }

    func meets(_ other: TreeChange) -> Bool {
        (board && other.board) || !nodes.isDisjoint(with: other.nodes) || !screens.isDisjoint(with: other.screens)
    }

    /// The host of every node in `content`, for `onlyScreen`: the first of nodes that share an
    /// id, as `TreeIndex` has it.
    static func hosts(in content: TreeContent) -> [UUID: TreeIndex.Host] {
        var hosts: [UUID: TreeIndex.Host] = [:]
        func add(_ node: LayerNode, on host: TreeIndex.Host) {
            guard hosts[node.id] == nil else { return }
            hosts[node.id] = host
            for child in node.children { add(child, on: host) }
        }
        for screen in content.screens { add(screen.root, on: .screen(screen.id)) }
        for node in content.canvas { add(node, on: .canvas) }
        return hosts
    }
}

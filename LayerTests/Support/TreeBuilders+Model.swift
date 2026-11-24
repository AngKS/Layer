import CoreGraphics
import Foundation
import Testing
@testable import Layer

// What the model's and the canvas's ported tests read and build beyond Task 1's builders (plan 6, Task 9). Each read is
// what a test read of the flat list, taken from the tree: a host's things in the list's order, a screen's leaves as its
// view showed them, a node's container, angle, host and frames. Each builder makes on the tree what a test built with
// the flat list: nodes set on a screen, a loose sketch, a group made round things where they are as its item was, and
// the code of a free screen of leaves, as the flat screen's code was written.

extension LayerNode {
    /// Turns it to `degrees`, kept from 0 up to 360, and nothing when upright: as the flat element was turned.
    mutating func setRotation(_ degrees: Double) {
        rotation = Rotation.kept(degrees)
    }

    /// How many strokes a drawing is made of: none for anything else.
    var strokeCount: Int {
        guard kind == .drawing, let ink = content.ink else { return 0 }
        return DecodedInk.drawing(id, ink: ink)?.strokes.count ?? 0
    }
}

extension TreeContent {
    /// A node, wherever it is, a screen's root included.
    func node(_ id: UUID) -> LayerNode? {
        TreeIndex(self).node(id, in: self)
    }

    /// Changes a node in place, wherever it is, running no rules: as the flat content's update of an element did.
    mutating func update(_ id: UUID, _ body: (inout LayerNode) -> Void) {
        guard let entry = TreeIndex(self)[id] else { return }
        changeNode(on: entry.host, at: entry.path, body)
    }

    /// A node's own frame in its host's points, centred on its turned shape: see `DesignStore.ownFrame(_:)`.
    func ownFrame(_ id: UUID) -> CGRect? {
        TreeIndex(self).ownPose(of: id, in: self)?.frame
    }

    /// Every node but the screens' roots, each host's as `listed(on:)` gives them: what the flat list held.
    var listedEverywhere: [LayerNode] {
        screens.flatMap { listed(on: $0.id) } + listed(on: nil)
    }

    /// The containers a node is in, the nearest first: what the flat element's groups above it were. A screen's root
    /// isn't one: it is the screen.
    func containers(above id: UUID) -> [UUID] {
        let index = TreeIndex(self)
        return index.ancestors(of: id).filter { index[$0].map { !$0.path.isEmpty } ?? false }
    }

    /// What is on a screen, or on the open canvas when `screenID` is nil, back to front as the flat list held it: depth
    /// first, each container just in front of what it holds.
    func listed(on screenID: TreeScreen.ID?) -> [LayerNode] {
        let top: [LayerNode] = if let screenID { screens.first { $0.id == screenID }?.root.children ?? [] } else { canvas }
        return top.flatMap(Self.listed)
    }

    private static func listed(_ node: LayerNode) -> [LayerNode] {
        node.isContainer ? node.children.flatMap(listed) + [node] : [node]
    }

    /// Makes a group round `members`, top-level things on one host, built whole as the flat list's group item was: the
    /// group, `adjust`ed, starts with a frame of zero at its host's origin, and each member keeps its pose, carried into
    /// the group's own points through the host's (on the canvas, through canvas points, the group drawn at `scale`, 1 if
    /// not given). The rules, run at the end of a store's change, fit its box round what it holds.
    ///
    /// It goes where the list's gather put the item: among the things that aren't drawings, in the frontmost member's
    /// place; and each drawing keeps its index in the list (`listed(on:)`) with the item added at its end, so a group of
    /// things behind a drawing goes in front of it. Nil, and nothing changes, when the members aren't top-level things on
    /// one host.
    @discardableResult
    mutating func group(_ members: [UUID], named name: String = "G", scale: CGFloat? = nil,
                        adjust: (inout LayerNode) -> Void = { _ in }) -> UUID? {
        let index = TreeIndex(self)
        let entries = members.compactMap { index[$0] }
        guard let host = entries.first?.host, entries.count == members.count,
              entries.allSatisfy({ $0.host == host && $0.path.count == 1 }) else { return nil }
        let wanted = Set(members)

        var group = LayerNode(kind: .group)
        group.name = name
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        adjust(&group)
        group.frame = .zero
        let groupPlacement: Placement
        let groupSpace: TreeIndex.OwnSpace
        if host == .canvas {
            group.scale = scale ?? 1
            groupPlacement = Placement(origin: .zero, scale: group.scale ?? 1)
            groupSpace = TreeIndex.OwnSpace.host.placing(group).space
        } else {
            guard case .screen(let screenID) = host, let screen = screens.first(where: { $0.id == screenID }) else { return nil }
            groupPlacement = screen.placement
            groupSpace = TreeIndex.OwnSpace.host.placing(screen.root).space.placing(group).space
        }

        let tops = children(on: host, at: []) ?? []
        group.children = tops.filter { wanted.contains($0.id) }.map { top in
            var member = top
            guard let pose = index.ownPose(of: member.id, in: self), let placement = index.placement(of: member.id, in: self)
            else { return member }
            // In the group's host's points: on the canvas, carried into the group's scale when the member's is another.
            let inHost = placement == groupPlacement ? pose.frame : groupPlacement.localRect(for: placement.canvasRect(for: pose.frame))
            member.frame = groupSpace.local(of: inHost)
            member.rotation = Rotation.kept(pose.degrees - groupSpace.degrees)
            member.scale = nil
            return member
        }

        // The things that aren't drawings, the group in its frontmost member's place.
        var placed = tops.filter { $0.kind != .drawing }
        let slots = placed.indices.filter { wanted.contains(placed[$0].id) }
        guard let front = slots.last else { return nil }
        for slot in slots.reversed() { placed.remove(at: slot) }
        placed.insert(group, at: front - (slots.count - 1))
        // Each drawing back at its index in the list, and the top level in the order the list then has it.
        let list = tops.flatMap(Self.listed)
        var relisted = placed.flatMap(Self.listed)
        for (slot, node) in list.enumerated() where node.kind == .drawing {
            relisted.insert(node, at: min(slot, relisted.count))
        }
        let topIDs = Set(placed.map(\.id) + tops.filter { $0.kind == .drawing }.map(\.id))
        let ordered = relisted.filter { topIDs.contains($0.id) }
        changeChildren(on: host, at: []) { $0 = ordered }
        return group.id
    }
}

@MainActor
extension DesignStore {
    /// `TreeContent.listed(on:)` for a host of the store's design.
    func listed(on host: ElementRef.Host) -> [LayerNode] {
        let screenID: TreeScreen.ID? = if case .screen(let id) = host { id } else { nil }
        return tree.listed(on: screenID)
    }

    /// The container a node is in: what the flat element called its group. Nil on a screen's root or the canvas's top
    /// level, and for an id the design doesn't have.
    func container(of id: UUID) -> UUID? {
        if case .node(let container)? = parent(of: id) { container } else { nil }
    }

    /// A screen's leaves as the flat screen showed them, depth first, back to front: each with its own frame in screen
    /// points and its summed angle, and hidden or locked when it or a container above it is.
    func shownLeaves(on screenID: TreeScreen.ID) -> [LayerNode] {
        let tree = tree, index = index
        return tree.leaves(on: screenID).map { leaf in
            var shown = leaf
            if let pose = index.ownPose(of: leaf.id, in: tree) {
                shown.frame = pose.frame
                shown.rotation = Rotation.kept(pose.degrees)
            }
            shown.isHidden = index[leaf.id]?.isHiddenWithAncestors ?? leaf.isHidden
            shown.isLocked = index[leaf.id]?.isLockedWithAncestors ?? leaf.isLocked
            return shown
        }
    }

    /// Ready-made nodes added to a screen in front of what is there, as one step, as the flat list's elements were set
    /// on it: a sticky note or a drawing, which the tree keeps on the open canvas, goes there where the screen would have
    /// shown it, at the screen's scale. Where each now lives.
    @discardableResult
    func add(_ nodes: [LayerNode], onScreen screenID: TreeScreen.ID) -> [ElementRef] {
        guard let screen = treeScreen(screenID) else { return [] }
        let scale = screen.scale.isFinite && screen.scale > 0 ? screen.scale : 1
        asOneStep {
            for node in nodes {
                guard !node.kind.belongsOnScreens else {
                    add(node, to: .screen(screenID))
                    continue
                }
                var loose = node
                loose.frame.origin.x += screen.origin.x / scale
                loose.frame.origin.y += screen.origin.y / scale
                loose.scale = scale
                add(loose, to: .canvas)
            }
        }
        return nodes.map { ElementRef(host: $0.kind.belongsOnScreens ? .screen(screenID) : .canvas, element: $0.id) }
    }

    /// `addCanvasNode(_:scale:)`, as a ref.
    @discardableResult
    func addOnCanvas(_ node: LayerNode, scale: CGFloat = 1) -> ElementRef {
        ElementRef(host: .canvas, element: addCanvasNode(node, scale: scale))
    }

    /// What the flat store's loose sketch made of `sketch` (canvas points): a new leaf of `kind`, about as large as it was
    /// drawn at `looseScale` as its kind's loose size allows, centred on it through `place(_:centredAt:)`.
    @discardableResult
    func addLoose(_ kind: ElementKind, from sketch: CGRect) -> ElementRef? {
        var node = LayerNode.standard(kind)
        let drawn = CGSize(width: sketch.width / looseScale, height: sketch.height / looseScale)
        node.frame.size = kind.spec.looseSize.size(from: node.frame.size, drawn: drawn)
        return place(node, centredAt: CGPoint(x: sketch.midX, y: sketch.midY))
    }

    /// A screen's frame on the canvas, drawn as its device. Nil for a screen the design doesn't have.
    func canvasFrame(ofScreen id: TreeScreen.ID) -> CGRect? {
        let tree = tree
        return treeScreen(id).map { $0.canvasFrame(on: tree.device(of: $0)) }
    }

    /// Where a screen's name is drawn on the canvas. Nil for a screen the design doesn't have.
    func labelFrame(ofScreen id: TreeScreen.ID) -> CGRect? {
        let tree = tree
        return treeScreen(id).map { $0.labelFrame(on: tree.device(of: $0)) }
    }

    /// A node's angle as the flat element kept it: summed with its containers', from 0 up to 360, nil when upright.
    func rotation(of id: UUID) -> Double? {
        index.ownPose(of: id, in: tree).flatMap { Rotation.kept($0.degrees) }
    }

    /// The screen a node is on: what the flat element called its parent. Nil on the open canvas, and for an id the design
    /// doesn't have.
    func hostScreen(of id: UUID) -> TreeScreen.ID? {
        if case .screen(let screenID)? = index[id]?.host { screenID } else { nil }
    }

    /// What a container holds directly, back to front: what the flat list called a group's members. None for an id the
    /// design doesn't have, or a leaf.
    func members(of id: UUID) -> [LayerNode] {
        node(id)?.children ?? []
    }

    /// `TreeContent.containers(above:)` in the store's design.
    func containers(above id: UUID) -> [UUID] {
        tree.containers(above: id)
    }

    /// `shownLeaves(on:)` for the screen at `index` among the design's screens. Nil when there is no screen there.
    func shownLeaves(onScreenAt index: Int) -> [LayerNode]? {
        let screens = tree.screens
        return screens.indices.contains(index) ? shownLeaves(on: screens[index].id) : nil
    }

    /// A node's upright frame on the canvas, centred on its turned shape: what the flat list's canvas frame was. Nil for an
    /// id the design doesn't have.
    func canvasRect(of id: UUID) -> CGRect? {
        placed(id).map { $0.placement.canvasRect(for: $0.frame) }
    }

    /// Whether a node is hidden, by itself or by a container above it.
    func isHiddenWithItsContainers(_ id: UUID) -> Bool {
        index[id]?.isHiddenWithAncestors ?? false
    }

    /// Whether a node is locked, by itself or by a container above it.
    func isLockedWithItsContainers(_ id: UUID) -> Bool {
        index[id]?.isLockedWithAncestors ?? false
    }
}

extension SwiftUICodeGenerator {
    /// The code of a screen whose free root holds `nodes`, each where its frame puts it, alone in a design: what the
    /// tests of the code had from a flat screen of the same leaves (plan 6, Task 9). Named `typeName`, or by the
    /// screen's name.
    static func code(forFreeScreenHolding nodes: [LayerNode], named name: String = "Screen 1", device: DeviceFrame = .iPhone,
                     typeName: String? = nil, settings: CodeSettings = CodeSettings()) -> String {
        let content = design(holding: nodes, named: name, device: device)
        var context = Context(content)
        context.typeNames[content.screens[0].id] = typeName ?? TreeScreen.typeName(forScreenNamed: name)
        return code(for: content.screens[0], in: context, settings: settings)
    }

    /// A design of one screen whose free root holds `nodes`, each where its frame puts it.
    static func design(holding nodes: [LayerNode], named name: String = "Screen 1", device: DeviceFrame = .iPhone) -> TreeContent {
        var root = LayerNode(kind: .group)
        root.layout = .free
        root.children = nodes.map { node in
            var held = node
            held.scale = nil
            return held
        }
        var content = TreeContent()
        if device.isCustom { content.settings.customDevices.append(device) }
        var screen = TreeScreen(name: name, origin: .zero, scale: 1, deviceID: device == .iPhone ? nil : device.id, root: root)
        if device.isCustom { screen.keepRootToDevice(device) }
        content.screens = [screen]
        return content
    }
}

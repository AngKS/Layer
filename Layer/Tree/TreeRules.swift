import CoreGraphics
import Foundation

/// The rules a design is kept to after every change, undo, redo and read: its structure first,
/// then the layout of what changed. The store runs them inside each of its changes.
///
/// The structure, in order:
/// 1. Each screen's root is kept to its device (built-in or the design's own): a group at the
///    device's bounds, fixed and upright. A root that lays its children out is inset by the
///    device's safe areas and its margin, and its column is at most the device's
///    `maxContentWidth` wide (1080 on a desktop), centred. A free root isn't inset.
/// 2. Drawings live only at the canvas's top level, and 3. sticky notes only on the canvas. One
///    anywhere else moves there, where it was on the canvas, in front of what is already there.
/// 4. An empty free group goes, and 5. a free group of one dissolves, its child taking its place,
///    its lock and its hide, at the angle the two make together. Screen roots and cards stay, and
///    so do groups that lay their children out, with any number of children, none included: a row
///    of one is still a row, and a row whose last child was dragged out is still there.
///
/// Then each screen that changed is laid out at its device's size, and each container on the
/// canvas's top level that changed at its own size, which it fits on each axis sized to fit, as
/// in a free container. Text is measured at the design's sizes (`settings.tokens`), so when the
/// tokens change every screen and every such container is laid out again, from scratch (F25).
/// Applying them again changes nothing.
///
/// What this build can't read inside a node counts as a child: a group holding only that isn't
/// empty, and it keeps its place among the children when one of the others goes.
enum TreeRules {
    static let maximumDepth = 32
    static let maximumNodes = 5_000

    /// Structure first, then layout of what changed since `previous` (everything when nil). Idempotent.
    ///
    /// `kept` is a version of the design that already follows every rule, laid out in full: the store's version before
    /// its change (`DesignStore.followsTheRules`). A screen whose root and device are as they are there, and a node on
    /// the canvas's top level the same as its own there, follow the structure already, so the structure passes look
    /// only at the rest: a change pays for what it touched, not for the whole design (plan 6's final review B, M1 and
    /// M2). What comes of it is the same as without.
    @discardableResult
    static func apply(to content: inout TreeContent, after previous: TreeContent?, kept: TreeContent? = nil,
                      measure: TextMeasure = .shared) -> [LayoutDiagnostic] {
        let screensKept = kept.map { unchangedScreens(in: content, since: $0) }
        for index in content.screens.indices where screensKept?[index] != true {
            keepToDevice(&content.screens[index], on: content.device(of: content.screens[index]))
        }
        let canvasKept = kept.map { KeptNodes($0.canvas) }
        moveToCanvas(&content, screensKept: screensKept, canvasKept: canvasKept)
        for index in content.screens.indices where screensKept?[index] != true {
            tidyInside(&content.screens[index].root)
        }
        let count = content.canvas.count
        let removed = tidy(&content.canvas, besides: canvasKept)
        keepUnreadPlaces(&content.unreadCanvas, among: count, removing: removed)
        return layOut(&content, after: previous, kept: kept, measure: measure)
    }

    // MARK: - What is as it was

    /// For each of `content`'s screens, in order, whether `kept` has it with its root unchanged
    /// (`LayerNode.isUnchanged(from:)`), on the same device: then it follows the structure already.
    private static func unchangedScreens(in content: TreeContent, since kept: TreeContent) -> [Bool] {
        let earlier = Dictionary(kept.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return content.screens.map { screen in
            guard let before = earlier[screen.id] else { return false }
            return screen.root.isUnchanged(from: before.root) && kept.device(of: before) == content.device(of: screen)
        }
    }

    /// The canvas's top-level nodes of a version that follows the rules: a node unchanged from its own there follows
    /// the structure already. Looked up by id only once a node isn't where it was.
    private final class KeptNodes {
        let nodes: [LayerNode]
        private lazy var byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        init(_ nodes: [LayerNode]) {
            self.nodes = nodes
        }

        /// Whether `list[index]` is as it is here, unchanged (`LayerNode.isUnchanged(from:)`).
        func holds(_ list: [LayerNode], at index: Int) -> Bool {
            let node = list[index]
            if nodes.indices.contains(index), nodes[index].id == node.id { return node.isUnchanged(from: nodes[index]) }
            return byID[node.id].map(node.isUnchanged(from:)) ?? false
        }
    }

    /// A version of the design that follows the rules, laid out in full: a screen or canvas container laid out alike
    /// there (`LayoutEngine.laysOutAlike`), holding no text that `tokens` measure at another size than its tokens did,
    /// needs no layout.
    private final class LaidOut {
        let content: TreeContent
        /// The tokens the design is laid out with now.
        let tokens: DesignTokens
        /// Made when first looked in.
        private lazy var screens = Dictionary(content.screens.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        private lazy var canvas = Dictionary(content.canvas.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        init(_ content: TreeContent, laidOutWith tokens: DesignTokens) {
            self.content = content
            self.tokens = tokens
        }

        /// Whether `screen`, of `design`, is laid out alike on the same device here.
        func laysOutAlike(_ screen: TreeScreen, in design: TreeContent) -> Bool {
            guard let own = screens[screen.id], content.device(of: own) == design.device(of: screen) else { return false }
            return LayoutEngine.laysOutAlike(screen.root, own.root) && isMeasuredAlike(screen.root)
        }

        /// Whether a container on the canvas's top level is laid out alike here.
        func laysOutAlike(_ node: LayerNode) -> Bool {
            guard let own = canvas[node.id] else { return false }
            return LayoutEngine.laysOutAlike(node, own) && isMeasuredAlike(node)
        }

        /// Whether all `node` holds is measured as it was: no text in it is measured at a size the tokens changed.
        private func isMeasuredAlike(_ node: LayerNode) -> Bool {
            let earlier = content.settings.tokens
            return earlier.textSizes == tokens.textSizes
                || !TreeEdit.holds(node) { NaturalSize.isMeasuredDifferently($0, with: earlier, and: tokens) }
        }
    }

    /// The margin round a device's column: its token (20, 32 and 48 for the built-in families).
    static func margin(for device: DeviceFrame) -> CGFloat { device.margin }

    // MARK: - 1. Screen roots

    private static func keepToDevice(_ screen: inout TreeScreen, on device: DeviceFrame) {
        screen.keepRootToDevice(device)
        screen.root.padding = padding(for: screen.root.resolvedLayout, on: device)
    }

    /// The safe areas and the margin round a root that lays its children out, its sides
    /// widened to keep the column to the device's `maxContentWidth`, centred. None round a free
    /// root, whose children stay where they were put.
    private static func padding(for layout: LayerNode.Layout, on device: DeviceFrame) -> LayerNode.Padding {
        guard layout != .free else { return LayerNode.Padding() }
        let margin = margin(for: device)
        var leading = device.safeLeading + margin, trailing = device.safeTrailing + margin
        if let widest = device.maxContentWidth {
            let extra = device.size.width - leading - trailing - widest
            if extra > 0 {
                leading += extra / 2
                trailing += extra / 2
            }
        }
        return LayerNode.Padding(top: device.safeTop + margin, leading: leading,
                                 bottom: device.safeBottom + margin, trailing: trailing)
    }

    // MARK: - 2 and 3. Drawings and sticky notes

    /// Moves every drawing off the screens and out of the canvas's containers, and every sticky
    /// note off the screens, to the canvas's top level, where each was on the canvas. A screen kept as it was
    /// (`screensKept`) and a top-level node as it was (`canvasKept`) hold none.
    private static func moveToCanvas(_ content: inout TreeContent, screensKept: [Bool]?, canvasKept: KeptNodes?) {
        var moved: [LayerNode] = []
        for index in content.screens.indices where screensKept?[index] != true {
            let screen = content.screens[index]
            // From the screen's points to the canvas's, at the screen's scale: the same size in
            // its own points, and drawn at the same size.
            let scale = screen.scale.isFinite && screen.scale > 0 ? screen.scale : 1
            for var node in takeOut(from: &content.screens[index].root, where: isOffScreen) {
                node = inParent(node, of: screen.root)
                node.frame.origin.x += screen.origin.x / scale
                node.frame.origin.y += screen.origin.y / scale
                node.scale = scale
                moved.append(node)
            }
        }
        // Looked for first, so that a canvas with nothing to move isn't copied to look inside it.
        let canvas = content.canvas
        let looked = canvasKept.map { kept in canvas.isShared(with: kept.nodes) ? [] : canvas.indices.filter { !kept.holds(canvas, at: $0) } }
        for index in looked ?? Array(canvas.indices) where holds(content.canvas[index], where: isDrawing) {
            let top = content.canvas[index]
            // In the space the top-level node sits in, so at its scale.
            for var node in takeOut(from: &content.canvas[index], where: isDrawing) {
                node = inParent(node, of: top)
                node.scale = top.scale
                moved.append(node)
            }
        }
        content.canvas += moved
    }

    private static func isOffScreen(_ node: LayerNode) -> Bool { node.kind == .drawing || node.kind == .stickyNote }

    private static func isDrawing(_ node: LayerNode) -> Bool { node.kind == .drawing }

    /// Takes everything `isTaken` picks out of `node`'s subtree, in reading order, each placed in
    /// `node`'s own space, where it was there and at its angle there.
    private static func takeOut(from node: inout LayerNode, where isTaken: (LayerNode) -> Bool) -> [LayerNode] {
        guard holds(node, where: isTaken) else { return [] }
        var taken: [LayerNode] = [], kept: [LayerNode] = [], removed: [Int] = []
        for (index, var child) in node.children.enumerated() {
            let inside = takeOut(from: &child, where: isTaken).map { inParent($0, of: child) }
            if isTaken(child) {
                removed.append(index)
                taken.append(child)
            } else {
                kept.append(child)
            }
            taken += inside
        }
        keepUnreadPlaces(in: &node, removing: removed)
        node.children = kept
        return taken
    }

    private static func holds(_ node: LayerNode, where isTaken: (LayerNode) -> Bool) -> Bool {
        node.children.contains { isTaken($0) || holds($0, where: isTaken) }
    }

    // MARK: - 4 and 5. Empty groups and free groups of one

    /// Removes the empty groups among `nodes` and dissolves the free groups of one, and does
    /// the same inside each first, so that a group left empty or alone by that goes too.
    /// Returns the indices of those removed. A node `kept` holds as it is needs none of it.
    private static func tidy(_ nodes: inout [LayerNode], besides kept: KeptNodes? = nil) -> [Int] {
        let list = nodes
        if let kept {
            guard !list.isShared(with: kept.nodes), list.indices.contains(where: { !kept.holds(list, at: $0) && needsTidying(list[$0]) })
            else { return [] }
        }
        guard nodes.contains(where: needsTidying) else { return [] }
        var kept: [LayerNode] = [], removed: [Int] = []
        for (index, var node) in nodes.enumerated() {
            tidyInside(&node)
            if isEmptyGroup(node) {
                removed.append(index)
            } else if isFreeGroupOfOne(node) {
                kept.append(dissolved(node))
            } else {
                kept.append(node)
            }
        }
        nodes = kept
        return removed
    }

    private static func tidyInside(_ node: inout LayerNode) {
        guard node.children.contains(where: needsTidying) else { return }
        var children = node.children
        let removed = tidy(&children)
        keepUnreadPlaces(in: &node, removing: removed)
        node.children = children
    }

    private static func needsTidying(_ node: LayerNode) -> Bool {
        isEmptyGroup(node) || isFreeGroupOfOne(node) || node.children.contains(where: needsTidying)
    }

    /// A free group holding nothing. One that lays its children out stays, as a card does.
    private static func isEmptyGroup(_ node: LayerNode) -> Bool {
        node.kind == .group && node.resolvedLayout == .free && node.children.isEmpty && node.unreadChildren.isEmpty
    }

    private static func isFreeGroupOfOne(_ node: LayerNode) -> Bool {
        node.kind == .group && node.resolvedLayout == .free && node.children.count == 1 && node.unreadChildren.isEmpty
    }

    /// A free group of one's child in the group's place: see `released(_:from:)`.
    private static func dissolved(_ group: LayerNode) -> LayerNode {
        released(group.children[0], from: group)
    }

    /// A container's child in the container's place, as a free group of one dissolves and as Ungroup
    /// puts it: where it was on screen, locked or hidden if either was, and at the container's scale,
    /// which only a node on the canvas's top level has. Its angle is kept as an element keeps one
    /// (`Rotation.kept`): from 0 up to 360, and none when upright.
    static func released(_ child: LayerNode, from container: LayerNode) -> LayerNode {
        var child = inParent(child, of: container)
        child.rotation = child.rotation.flatMap(Rotation.kept)
        child.isLocked = child.isLocked || container.isLocked
        child.isHidden = child.isHidden || container.isHidden
        child.scale = container.scale
        return child
    }

    // MARK: - Moving between spaces

    /// `node`, from `parent`'s space into the space `parent` sits in: the same size, about the
    /// same point, turned by the parent's angle too. An upright parent only moves it.
    private static func inParent(_ node: LayerNode, of parent: LayerNode) -> LayerNode {
        var node = node
        let turn = degrees(of: parent)
        guard turn != 0 else {
            node.frame.origin.x += parent.frame.origin.x
            node.frame.origin.y += parent.frame.origin.y
            return node
        }
        let centre = CGPoint(x: node.frame.midX, y: node.frame.midY).applying(parent.transformToParent)
        node.frame.origin = CGPoint(x: centre.x - node.frame.width / 2, y: centre.y - node.frame.height / 2)
        node.rotation = degrees(of: node) + turn
        return node
    }

    /// An angle that isn't a number is upright, as `transformToParent` reads it.
    private static func degrees(of node: LayerNode) -> Double {
        node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
    }

    /// Keeps each unread child at its place among those left when the children at `removed`
    /// (indices into `node.children`, not yet taken out) go. A file lists the unread ones at
    /// their indices among all of them (see `LayerNode`'s coding).
    static func keepUnreadPlaces(in node: inout LayerNode, removing removed: [Int]) {
        keepUnreadPlaces(&node.unreadChildren, among: node.children.count, removing: removed)
    }

    /// The same for any list of nodes with unread ones among them, a node's children or the
    /// canvas's nodes: `count` read nodes, of which those at `removed` go.
    static func keepUnreadPlaces(_ unread: inout [LayerNode.UnreadChild], among count: Int, removing removed: [Int]) {
        guard !unread.isEmpty, !removed.isEmpty else { return }
        let taken = Set(unread.map(\.index))
        var places: [Int] = [], place = 0
        for _ in 0..<count {
            while taken.contains(place) { place += 1 }
            places.append(place)
            place += 1
        }
        let gone = removed.map { places[$0] }
        for index in unread.indices {
            let place = unread[index].index
            unread[index].index = place - gone.count { $0 < place }
        }
    }

    // MARK: - Layout

    /// Lays out each screen whose root or device changed since `previous`, at its device's size,
    /// and each canvas top-level container that changed, at its own size once fitted (see
    /// `fitOnCanvas`), with the design's tokens. What didn't change was laid out with `previous`,
    /// and the engine leaves alone what is the same inside the rest. When the tokens aren't
    /// `previous`'s, nothing was laid out with them: every screen and every such container is laid
    /// out, with no `previous` (F25).
    ///
    /// With `kept` (see `apply`), laid out in full, a screen or a canvas container the engine lays out alike there
    /// (`LayoutEngine.laysOutAlike`), its look changed and nothing it is laid out by, is laid out already: what the
    /// engine would give it is what it has. So is one that holds no text measured at a size the tokens changed, when
    /// they did (`NaturalSize.isMeasuredDifferently`): a scrub of a token lays out only what is measured by it, and of
    /// one nothing is measured by (a card's radius, the rhythm), nothing.
    private static func layOut(_ content: inout TreeContent, after previous: TreeContent?, kept: TreeContent?,
                               measure: TextMeasure) -> [LayoutDiagnostic] {
        var diagnostics: [LayoutDiagnostic] = []
        let tokens = content.settings.tokens
        let earlier = previous.flatMap { $0.settings.tokens == tokens ? $0 : nil }
        let screens = Dictionary((earlier?.screens ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let laidOut = kept.map { LaidOut($0, laidOutWith: tokens) }
        for index in content.screens.indices {
            let screen = content.screens[index], before = screens[screen.id]
            if let before, let earlier, earlier.device(of: before) == content.device(of: screen),
               before.root == screen.root { continue }
            if let laidOut, laidOut.laysOutAlike(screen, in: content) { continue }
            LayoutEngine.layOut(&content.screens[index].root, previous: before?.root, measure: measure, tokens: tokens,
                                diagnostics: &diagnostics)
        }
        let canvas = Dictionary((earlier?.canvas ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in content.canvas.indices where content.canvas[index].isContainer {
            let before = canvas[content.canvas[index].id]
            if before == content.canvas[index] { continue }
            if let laidOut, laidOut.laysOutAlike(content.canvas[index]) { continue }
            fitOnCanvas(&content.canvas[index], measure: measure, tokens: tokens)
            LayoutEngine.layOut(&content.canvas[index], previous: before, measure: measure, tokens: tokens,
                                diagnostics: &diagnostics)
        }
        return diagnostics
    }

    /// The canvas places its top-level nodes freely, so a row, column, grid or overlay there that
    /// is sized to fit takes its fitting size on that axis, as it does in a free container (the
    /// engine's `fittedInFreeParent`, whose numbers these are): its other axis keeps its frame's
    /// size, and its top-left corner stays where it is, turned or not. A free container sized to
    /// fit hugs what it holds in the engine instead.
    private static func fitOnCanvas(_ node: inout LayerNode, measure: TextMeasure, tokens: DesignTokens) {
        let fitsWidth = node.width.mode == .fit, fitsHeight = node.height.mode == .fit
        guard node.resolvedLayout != .free, fitsWidth || fitsHeight else { return }
        // Measured with the axis that doesn't fit held at the frame's size, as a free parent holds it.
        var held = node
        if !fitsWidth { held.width = LayerNode.Sizing(.fixed) }
        if !fitsHeight { held.height = LayerNode.Sizing(.fixed) }
        let fitting = LayoutEngine.size(of: held, proposal: ProposedSize(width: nil, height: nil), measure: measure,
                                        tokens: tokens)
        let size = CGSize(width: fitsWidth ? snapped(fitting.width) : fitting.width,
                          height: fitsHeight ? snapped(fitting.height) : fitting.height)
        guard size != node.frame.size else { return }
        // The point that was its top-left corner, wherever its turn put it, is its new one.
        let corner = CGPoint.zero.applying(node.transformToParent)
        var resized = node
        resized.frame = CGRect(origin: .zero, size: size)
        let offset = CGPoint.zero.applying(resized.transformToParent)
        node.frame = CGRect(x: finite(corner.x - offset.x), y: finite(corner.y - offset.y),
                            width: size.width, height: size.height)
    }

    /// Whole points, half up, as the engine writes them.
    private static func snapped(_ value: CGFloat) -> CGFloat { (value + 0.5).rounded(.down) }

    private static func finite(_ value: CGFloat) -> CGFloat { value.isFinite ? value : 0 }
}

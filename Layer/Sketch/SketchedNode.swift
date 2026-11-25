import CoreGraphics
import Foundation

/// What a reading becomes on a screen (spec §5, plan 5's calls 6 to 8): a node where its sketch lands, laid out there,
/// remembering its sketch. Pure, and free of UIKit and SwiftUI, so that the store and the macOS sketch harness share it.
///
/// - In a free container it is placed as a Magic Pen sketch always was (`ElementLayout.sketched`), among that container's
///   visible children: on a screen's root by the screen's device, and in a nested container by a stand-in device of the
///   container's size, so that centring, two columns and text after a neighbour still mean something there. It is
///   `.fixed` on both axes.
/// - In a row, column or grid it takes the slot nearest its centre, sized like the nearest sibling of its kind, or as its
///   kind starts (`NaturalSize.defaultSizing`), and the engine places it.
/// - A leaf has no colour of its own: its kind's (the accent) is what it is drawn and written in.
/// - A card (call 6) is at the drawn box, in whole points, padded by the design's card padding. Its tint is nil and it has
///   no words, so that it is drawn and written with the design's card fill (F2).
///   - In a free container it is `.fixed`. It takes what it encloses that isn't locked, hidden or turned, the person's own
///     containers included, where they are on screen, and grows to hold them. Nothing goes out of sight: it goes in just
///     behind the backmost thing it doesn't take that its final box overlaps at all, but in front of anything its whole
///     final box lies on, such as a background, and of anything that lay behind a thing it takes and overlapped it;
///     else in front. That slot then moves as little as needed so that nothing seen is wholly hidden by one thing,
///     where some slot can do that. Hidden things count for none of this.
///   - In a row, column, grid or overlay, round what it can take there in place (`SketchLanding.takenInPlace`), it takes
///     that: their slot, and them, held as that container held them, padded by the design's card padding (plan 5's
///     final review, B1 and its follow-up). It never makes what holds it wider: it is as wide as they were, and its
///     padding narrows them, never below 44 pt. Down, it grows by its padding, so only what lies below it there moves,
///     by exactly that (plan 6's Task P5C, `inPlace`). Round nothing there, it takes nothing, and keeps the drawn box: as
///     tall as drawn, and as wide as drawn, or as wide as what holds it when it was drawn across the screen
///     (`PlacementIntent.proportional`).
enum SketchedNode {
    struct Made: Equatable, Sendable {
        var node: LayerNode
        var landing: SketchLanding
        /// What a card takes: the receiving container's children it encloses, back to front. Empty for anything else.
        /// A card in a row, column, grid or overlay holds them already in `node`, fitted to it (`inPlace`).
        var takes: [UUID]
        /// What a card in a free container goes in just behind, so that nothing goes out of sight
        /// (`behind(_:taking:among:)`). Nil: in front.
        var behind: UUID? = nil
    }

    /// The node a reading of `kind` becomes where `sketch` (canvas points) lands, with its SketchIntent (call 7, call 8).
    /// Nil off every screen.
    static func make(_ kind: ElementKind, sketch: CGRect, in content: TreeContent, index: TreeIndex,
                     confidence: Double, decidedBy: LayerNode.DecidedBy) -> Made? {
        guard let landing = SketchLanding.of(sketch, in: content, index: index, forCard: kind == .card),
              let screen = content.screens.first(where: { $0.id == landing.screen }),
              let parent = landing.parent == screen.root.id ? screen.root : index.node(landing.parent, in: content)
        else { return nil }
        let device = content.device(of: screen)
        let intent = LayerNode.SketchIntent(sketched: screen.placement.localRect(for: sketch), on: device.size,
                                            margin: device.margin, confidence: confidence, decidedBy: decidedBy)
        return build(kind, intent: intent, landing: landing, parent: parent, depth: index[parent.id]?.depth ?? 0, screen: screen,
                     content: content)
    }

    /// `node` as `kind`, laid out afresh in its current parent from `node.sketch.originalBounds` (or `fallback`, screen
    /// points, when it has none). Its id, name and lock are kept, and so are its words when both kinds show words;
    /// everything else is as a reading of `kind` there would make it, its intent saying the person chose (`.asked`,
    /// confidence 1) over the same bounds.
    ///
    /// It keeps its slot, but for a card it becomes: in a free container that goes where `make` puts a card, so that
    /// nothing seen is hidden (`behind(_:taking:among:)`), and in a row, column, grid or overlay one that takes what it
    /// encloses takes their slot. A card the node is gives back what it held, where it was on screen, in front of the
    /// node's slot; a card it becomes takes what it encloses (`Made.takes`), as `make` does. The result is put in by
    /// `replacing(_:with:in:)`. Nil when the node isn't on a screen, or has neither bounds.
    static func remade(_ node: LayerNode, as kind: ElementKind, fallback: CGRect?, in content: TreeContent,
                       index: TreeIndex) -> Made? {
        guard let entry = index[node.id], case .screen(let screenID) = entry.host, let parentID = entry.parent,
              let screen = content.screens.first(where: { $0.id == screenID }),
              let held = parentID == screen.root.id ? screen.root : index.node(parentID, in: content),
              let at = held.children.firstIndex(where: { $0.id == node.id }),
              let drawn = node.sketch?.originalBounds ?? fallback
        else { return nil }
        // The parent as it is once the node is out of it, what it held given back.
        var parent = held
        release(node, from: &parent)
        let device = content.device(of: screen)
        let isLaidOut = parent.resolvedLayout != .free
        // A card in a free container goes where nothing seen is hidden; anything else keeps the slot it had.
        let slot = kind == .card && !isLaidOut ? nil : at
        guard let landing = SketchLanding.within(held, on: screen, drawn: drawn, slot: slot, in: content, index: index)
        else { return nil }
        var intent = node.sketch ?? LayerNode.SketchIntent(sketched: drawn, on: device.size, margin: device.margin,
                                                           confidence: 1, decidedBy: .asked)
        intent.confidence = 1
        intent.decidedBy = .asked

        var made = build(kind, intent: intent, landing: landing, parent: parent, depth: entry.depth - 1, screen: screen,
                         content: content, without: node.id)
        made.node.id = node.id
        made.node.name = node.name
        made.node.isLocked = node.isLocked
        if kind.hasText, node.kind.hasText, node.content.text != node.kind.placeholder {
            made.node.content.text = node.content.text
        }
        return made
    }

    /// The root with the node `id` taken out and `made`, its remaking, put in where `made.landing` says: the card it was
    /// gives back what it held first, in front of the slot it leaves.
    static func replacing(_ id: UUID, with made: Made, in root: LayerNode) -> LayerNode {
        var root = root
        _ = swap(id, for: made, in: &root)
        return root
    }

    /// The shared tail of `make` and `remade`: `kind` laid out in `parent` at `landing`, remembering `intent`. `without`
    /// is a node the screen is counted without, the one being remade.
    private static func build(_ kind: ElementKind, intent: LayerNode.SketchIntent, landing: SketchLanding,
                              parent: LayerNode, depth: Int, screen: TreeScreen, content: TreeContent,
                              without: UUID? = nil) -> Made {
        let device = content.device(of: screen)
        // A screen's root is laid out on the screen's device; anything inside it on a device of the container's size.
        let standIn = parent.id == screen.root.id ? device
            : DeviceFrame.custom(name: parent.kind.rawValue, size: parent.frame.size, family: device.family)

        var node: LayerNode
        var landing = landing
        var takes: [UUID] = []
        var behind: UUID?
        if kind == .card {
            (node, takes, behind) = card(in: parent, at: depth, landing: landing, tokens: content.settings.tokens)
            if landing.isLaidOut, let first = takes.first {
                // Call 6, as ruled (B1): in the slot of what it takes.
                landing.index = parent.children.firstIndex { $0.id == first }
            } else if landing.isLaidOut, intent.placement == .proportional {
                // Call 6: round nothing, as drawn. Drawn across the screen, it is as wide as what holds it.
                node.width = LayerNode.Sizing(.fill(weight: 1))
            }
        } else {
            node = leaf(kind, in: parent, landing: landing, on: standIn, tokens: content.settings.tokens)
            if kind == .button, hasFilledButton(screen.root, except: without) {
                // A screen's first button is its main action; any more are outlined beside or below it.
                node.content.buttonLook = .bordered
                node.content.text = "Cancel"
            }
            if landing.isLaidOut { size(&node, likeTheNearestOf: parent, to: landing.local) }
        }
        node.sketch = intent
        return Made(node: node, landing: landing, takes: takes, behind: behind)
    }

    /// The root with `made` put in: at its slot, a card holding what it takes at their places on screen, just behind what
    /// it overlaps and doesn't take (`Made.behind`).
    static func inserting(_ made: Made, into root: LayerNode) -> LayerNode {
        var root = root
        _ = put(made, in: &root)
        return root
    }

    // MARK: - How it is made

    /// A leaf with today's fields: its placeholder text, and no colour of its own, so that its kind's is what it is drawn
    /// in. It is placed in a free container as a Magic Pen sketch always was. In a row, column or grid, which places it, it
    /// starts at the size it would have on a phone. A title drawn small or large carries its size as its own font size
    /// (`sketchedTitleSize`), wherever it lands.
    private static func leaf(_ kind: ElementKind, in parent: LayerNode, landing: SketchLanding, on device: DeviceFrame,
                             tokens: DesignTokens) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = kind.placeholder
        let laid = landing.isLaidOut
            ? ElementLayout.sketched(kind, sketch: landing.local)
            : ElementLayout.sketched(kind, sketch: landing.local, on: device,
                                     among: parent.children.filter { !$0.isHidden }.map(\.frame))
        node.frame = laid.frame
        if !landing.isLaidOut { node.style.textAlignment = laid.alignment }
        if node.frame.size.width < 1 {
            // A container narrower than the margins a kind that runs across keeps: the least it can be, on the sketch.
            let width = kind.spec.minimumSize.width
            node.frame = CGRect(x: (landing.local.midX - width / 2).rounded(), y: node.frame.minY, width: width,
                                height: node.frame.height)
        }
        if kind == .title { node.style.fontSize = ElementLayout.sketchedTitleSize(height: laid.frame.height, tokens: tokens) }
        return node
    }

    /// A card at the drawn box in whole points, `.fixed`, what it takes, and what it goes behind. In a free container it
    /// takes what it encloses (`SketchLanding.enclosed`) whose subtrees stay within depth 32 once inside it (F9), and the
    /// box grows to hold them; where it goes among what stays is `behind(_:taking:among:)`'s. In a row, column, grid or
    /// overlay it is `inPlace(_:drawn:in:at:)`. `depth` is the receiving container's.
    private static func card(in parent: LayerNode, at depth: Int, landing: SketchLanding,
                             tokens: DesignTokens) -> (LayerNode, takes: [UUID], behind: UUID?) {
        var node = LayerNode(kind: .card)
        node.padding = LayerNode.Padding(all: tokens.card.padding)
        let drawn = landing.local
        let minX = drawn.minX.rounded(), minY = drawn.minY.rounded()
        node.frame = CGRect(x: minX, y: minY, width: drawn.maxX.rounded() - minX, height: drawn.maxY.rounded() - minY)
        guard !landing.isLaidOut else {
            let (held, takes) = inPlace(node, drawn: drawn, in: parent, at: depth)
            return (held, takes, nil)
        }
        let enclosed = Set(SketchLanding.enclosed(by: drawn, in: parent))
        let taken = parent.children.filter { enclosed.contains($0.id) && fitsInACard($0, at: depth) }
        if let box = TreeEdit.shapesBox(of: taken) { node.frame = node.frame.union(box).integral }
        let takes = taken.map(\.id)
        return (node, takes, behind(node.frame, taking: Set(takes), among: parent.children))
    }

    /// `card`, drawn round `drawn` in a row, column, grid or overlay (call 6, as ruled in plan 5's final review, B1, and
    /// in plan 6's Task P5C). Round what it can take there in place (`SketchLanding.takenInPlace`), all within depth 32
    /// once inside it (F9), it holds that as the container held it, in their slot, with the card's padding: the person
    /// drew a card, so it looks like one. Screens scroll down, never across, so:
    /// - Across, it never makes what holds it wider. It is as wide as what it takes was (`horizontalExtent`), filling
    ///   when they filled, and its padding there insets them: each too wide for the room left fills it, so it is
    ///   narrower by the padding (`narrowed`). No member is narrowed below 44 pt; where the card's whole padding would
    ///   do that, its padding across is only what leaves that room, down to none.
    /// - Down, it grows by its padding and its members keep their heights: what lies below it in what holds it moves
    ///   down by exactly that padding (the members after it in a column, the rows below in a grid), and a row grows
    ///   taller. It fits them, or, along a column whose members fill it, fills with their weights together.
    ///
    /// `card`'s `children` are then what it takes, fitted so, in its space. Round nothing there, it takes nothing, as
    /// drawn.
    private static func inPlace(_ card: LayerNode, drawn: CGRect, in parent: LayerNode,
                                at depth: Int) -> (LayerNode, takes: [UUID]) {
        guard let takes = SketchLanding.takenInPlace(by: drawn, in: parent), !takes.isEmpty else { return (card, []) }
        let taking = Set(takes)
        let taken = parent.children.filter { taking.contains($0.id) }
        guard taken.allSatisfy({ fitsInACard($0, at: depth) }) else { return (card, []) }

        var node = card
        var axis: LayerNode.Axis?
        switch parent.resolvedLayout {
        case .stack(let stack):
            node.layout = .stack(LayerNode.Stack(axis: stack.axis, spacing: stack.spacing, alignment: stack.alignment))
            axis = stack.axis
        case .overlay(let alignment):
            node.layout = .overlay(alignment)
        case .grid(let grid):
            // Holding one cell.
            node.layout = .overlay(grid.alignment)
        case .free:
            return (card, [])
        }
        /// Filling: one thing's own sizing, or, along a stack, their weights together. Else `otherwise`.
        func sizing(_ length: KeyPath<LayerNode, LayerNode.Sizing>, along: Bool,
                    otherwise: LayerNode.Sizing.Mode) -> LayerNode.Sizing {
            let weights = taken.compactMap { thing -> CGFloat? in
                if case .fill(let weight) = thing[keyPath: length].mode { weight } else { nil }
            }
            if weights.isEmpty { return LayerNode.Sizing(otherwise) }
            if taken.count == 1 { return taken[0][keyPath: length] }
            return LayerNode.Sizing(.fill(weight: along ? weights.reduce(0, +) : 1))
        }
        let held = taken.dropFirst().reduce(taken[0].frame) { $0.union($1.frame) }
        let extent = horizontalExtent(of: held, in: parent)
        node.width = sizing(\.width, along: axis == .horizontal, otherwise: .fixed)
        node.height = sizing(\.height, along: axis == .vertical, otherwise: .fit)
        let fitted = narrowed(taken, into: extent, sideBySide: axis == .horizontal, padding: &node.padding)
        node.frame = CGRect(x: held.minX, y: held.minY, width: extent,
                            height: held.height + node.padding.top + node.padding.bottom)
        // In its space, where the card's padding starts them; the card lays them out.
        node.children = fitted.map { thing in
            var inside = thing
            inside.frame.origin = CGPoint(x: thing.frame.minX - held.minX + node.padding.leading,
                                          y: thing.frame.minY - held.minY + node.padding.top)
            return inside
        }
        return (node, takes)
    }

    /// How wide a card taking things whose box is `held` in `parent` is: their box's width, or in a grid the width of a
    /// column, which is the cell's.
    private static func horizontalExtent(of held: CGRect, in parent: LayerNode) -> CGFloat {
        guard case .grid(let grid) = parent.resolvedLayout else { return held.width }
        let columns = CGFloat(min(12, max(1, grid.columns)))
        let content = parent.frame.width - parent.padding.leading - parent.padding.trailing
        let column = (content - (columns - 1) * max(0, grid.columnSpacing)) / columns
        return column.isFinite && column > 0 ? column : held.width
    }

    /// The least a card narrows a member to: the height of the smallest control (`TreeValidator`), across.
    private static let narrowest: CGFloat = 44

    /// `taken`, back to front, fitted across a card `extent` wide whose `padding` is the design's, which is cut across
    /// to what leaves each member at least `narrowest` wide (or its own width, when that is less), down to none.
    /// - Side by side (a row), the members together are narrower by the padding: each gives up a share of what it has
    ///   past `narrowest`, at a fixed width. When some fill, they alone give it up, as the card shares its room.
    /// - Otherwise each is on its own: one too wide for the card's room inside fills it, so it is narrowed to that room
    ///   and follows the card's width from then on.
    private static func narrowed(_ taken: [LayerNode], into extent: CGFloat, sideBySide: Bool,
                                 padding: inout LayerNode.Padding) -> [LayerNode] {
        func fills(_ thing: LayerNode) -> Bool {
            if case .fill = thing.width.mode { true } else { false }
        }
        let wanted = padding.leading + padding.trailing
        var fitted = taken
        if sideBySide {
            let giving = taken.contains(where: fills) ? taken.indices.filter { fills(taken[$0]) } : Array(taken.indices)
            let spare = giving.map { max(0, (taken[$0].frame.width - narrowest).rounded(.down)) }
            let given = min(wanted, spare.reduce(0, +))
            cut(&padding, to: given)
            guard given > 0 else { return fitted }
            // Shares of what is given, by what each can spare, in whole points; what rounding leaves goes one by one.
            let total = spare.reduce(0, +)
            var shares = spare.map { ($0 * given / total).rounded(.down) }
            var left = given - shares.reduce(0, +)
            for place in shares.indices where left > 0 && shares[place] < spare[place] {
                shares[place] += 1
                left -= 1
            }
            for (place, index) in giving.enumerated() where shares[place] > 0 {
                if !fills(fitted[index]) { fitted[index].width.mode = .fixed }
                fitted[index].frame.size.width -= shares[place]
            }
            return fitted
        }
        let widest = taken.map(\.frame.width).max() ?? 0
        let room = max(extent - min(widest, narrowest), 0)
        cut(&padding, to: min(wanted, room.rounded(.down)))
        let inside = extent - padding.leading - padding.trailing
        for index in fitted.indices where fitted[index].frame.width > inside + 0.5 {
            if !fills(fitted[index]) { fitted[index].width.mode = .fill(weight: 1) }
            fitted[index].frame.size.width = inside
        }
        return fitted
    }

    /// `padding` with `across` points across it in all, shared evenly between its leading and trailing sides.
    private static func cut(_ padding: inout LayerNode.Padding, to across: CGFloat) {
        guard across < padding.leading + padding.trailing else { return }
        padding.leading = (across / 2).rounded(.down)
        padding.trailing = across - padding.leading
    }

    /// Whether `thing`, held by a card that goes in a container at `depth`, stays within depth 32 (F9): a child of the
    /// card sits two levels below the container.
    private static func fitsInACard(_ thing: LayerNode, at depth: Int) -> Bool {
        depth + 2 + TreeEdit.levels(below: thing) <= TreeRules.maximumDepth
    }

    /// What a card whose final box is `box`, taking `taking` from `children` (back to front), goes in just behind, so
    /// that nothing goes out of sight; nil: in front. Each thing counts as the box round its turned shape, and a hidden
    /// thing, which isn't drawn, counts for nothing.
    /// 1. The ruled slot. The card stays in front of what holds its whole box, such as a background, and of what lay
    ///    behind a thing it takes and overlapped it, which that thing, in the card now, must stay in front of; and of
    ///    all behind those. Past the frontmost of them, it goes behind the first thing its box overlaps at all.
    /// 2. Moved as little as needed among the slots where nothing seen is wholly hidden by one thing: in front of what
    ///    would hide the card whole, or hide whole a thing it takes that was seen; behind what it would hide whole.
    ///    Where no slot does that, the ruled slot stands, and something is hidden: the accepted limit.
    private static func behind(_ box: CGRect, taking: Set<UUID>, among children: [LayerNode]) -> UUID? {
        let shapes = children.map { TreeEdit.shapesBox(of: [$0]) ?? $0.frame }
        let takenAt = children.indices.filter { taking.contains(children[$0].id) }
        // What stays, back to front: the card goes in at one of its slots, from 0, behind it all, to its count.
        let staying = children.indices.filter { !taking.contains(children[$0].id) }
        func isDrawn(_ at: Int) -> Bool { !children[at].isHidden }
        /// Seen before the card: drawn, and not wholly under one drawn thing in front of it.
        func wasSeen(_ at: Int) -> Bool {
            isDrawn(at) && !children.indices.contains { over in
                over > at && isDrawn(over) && shapes[over].contains(shapes[at])
            }
        }

        // 1. The ruled slot.
        let floor = staying.lastIndex { at in
            isDrawn(at) && (shapes[at].contains(box) || takenAt.contains { $0 > at && overlaps(shapes[at], shapes[$0]) })
        } ?? -1
        let ruled = staying.indices.first { $0 > floor && isDrawn(staying[$0]) && overlaps(shapes[staying[$0]], box) }
            ?? staying.count

        // 2. The slots that hide nothing seen run from `lowest` to `highest`; the ruled slot is moved into them.
        let lowest = 1 + (staying.lastIndex { at in
            isDrawn(at) && (shapes[at].contains(box)
                || takenAt.contains { $0 > at && shapes[at].contains(shapes[$0]) && wasSeen($0) })
        } ?? -1)
        let highest = staying.firstIndex { box.contains(shapes[$0]) && wasSeen($0) } ?? staying.count
        let slot = lowest <= highest ? min(max(ruled, lowest), highest) : ruled
        return slot < staying.count ? children[staying[slot]].id : nil
    }

    /// Sized for a row, column or grid (call 7): like the visible sibling of its kind whose middle is nearest the sketch's,
    /// its size included when it is fixed; else as its kind starts.
    private static func size(_ node: inout LayerNode, likeTheNearestOf parent: LayerNode, to sketch: CGRect) {
        let centre = CGPoint(x: sketch.midX, y: sketch.midY)
        func distance(_ sibling: LayerNode) -> CGFloat {
            hypot(sibling.frame.midX - centre.x, sibling.frame.midY - centre.y)
        }
        let alike = parent.children.filter { $0.kind == node.kind && !$0.isHidden }
        if let nearest = alike.min(by: { distance($0) < distance($1) }) {
            node.width = nearest.width
            node.height = nearest.height
            node.frame.size = nearest.frame.size
        } else {
            (node.width, node.height) = NaturalSize.defaultSizing(for: node.kind)
        }
    }

    /// Whether two boxes share any area.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let shared = a.intersection(b)
        return !shared.isNull && shared.width > 0 && shared.height > 0
    }

    /// Whether a screen shows a filled button: one not hidden, nor inside anything hidden, and not `except`. What
    /// `except` holds counts: a card remade as a button gives it back.
    private static func hasFilledButton(_ node: LayerNode, except: UUID? = nil) -> Bool {
        guard !node.isHidden else { return false }
        if node.id != except, node.kind == .button, (node.content.buttonLook ?? .filled) == .filled { return true }
        return node.children.contains { hasFilledButton($0, except: except) }
    }

    /// `made` put in `node`, or in what `node` holds, wherever its landing's parent is. False when it isn't there.
    private static func put(_ made: Made, in node: inout LayerNode) -> Bool {
        guard node.id == made.landing.parent else {
            for index in node.children.indices {
                if put(made, in: &node.children[index]) { return true }
            }
            return false
        }
        var added = made.node
        var children = node.children
        if !made.takes.isEmpty {
            let taking = Set(made.takes)
            if added.children.isEmpty {
                // Back to front as they were, each where it is on screen: moved into the card's space. A card taken in
                // a row, column, grid or overlay holds them already, fitted to it (`inPlace`).
                added.children = children.filter { taking.contains($0.id) }.map { child in
                    var held = child
                    held.frame.origin = CGPoint(x: child.frame.minX - added.frame.minX,
                                                y: child.frame.minY - added.frame.minY)
                    return held
                }
            }
            children.removeAll { taking.contains($0.id) }
        }
        let slot = made.behind.flatMap { behind in children.firstIndex { $0.id == behind } }
            ?? made.landing.index.map { min(max($0, 0), children.count) } ?? children.count
        children.insert(added, at: slot)
        TreeEdit.give(children, to: &node)
        return true
    }

    /// `parent` without `old`, which it gives back what it held at its place, where it was on screen and at its angle
    /// there, in front of the slot it leaves.
    private static func release(_ old: LayerNode, from parent: inout LayerNode) {
        guard let at = parent.children.firstIndex(where: { $0.id == old.id }) else { return }
        let toParent = old.transformToParent
        let turn = old.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
        let given = old.children.map { child -> LayerNode in
            var held = child
            let centre = CGPoint(x: child.frame.midX, y: child.frame.midY).applying(toParent)
            held.frame.origin = CGPoint(x: centre.x - child.frame.width / 2, y: centre.y - child.frame.height / 2)
            if turn != 0 { held.rotation = Rotation.kept((child.rotation ?? 0) + turn) }
            return held
        }
        var children = parent.children
        children.replaceSubrange(at...at, with: given)
        TreeEdit.give(children, to: &parent)
    }

    /// `node`, or what it holds, with `id` taken out and `made` put in, wherever its landing's parent is.
    private static func swap(_ id: UUID, for made: Made, in node: inout LayerNode) -> Bool {
        guard node.id == made.landing.parent else {
            for index in node.children.indices {
                if swap(id, for: made, in: &node.children[index]) { return true }
            }
            return false
        }
        guard let old = node.children.first(where: { $0.id == id }) else { return false }
        release(old, from: &node)
        return put(made, in: &node)
    }
}

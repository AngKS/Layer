import CoreGraphics
import Foundation

/// What can be done to several things at once: elements, drawings among them, and
/// screens, wherever each of them is. Things are lined up and moved by where they are on
/// the canvas, so that an element on a screen and a note on the open canvas can be lined
/// up with each other. Each of these is one step to undo.
extension DesignStore {
    /// The shape something takes up on the canvas: an element's rect with the angle it is
    /// turned to, or a screen's frame, which never turns. Nil for several things, which
    /// have no shape of their own, and when it is gone or no longer where the selection says.
    /// Read from the index and the node's path (`placed(_:)`).
    func canvasShape(of selection: CanvasSelection) -> TurnedRect? {
        switch selection {
        case .element(let ref):
            return placed(ref)?.canvasShape
        case .screen(let id):
            return treeScreen(id).map { TurnedRect(rect: $0.canvasFrame(on: tree.device(of: $0)), degrees: 0) }
        case .several:
            return nil
        }
    }

    /// Where something is on the canvas: a screen's frame, the upright box round an
    /// element's turned shape, or the area that several things cover together. Nil when it
    /// is gone.
    func canvasFrame(of selection: CanvasSelection) -> CGRect? {
        switch selection {
        case .element, .screen:
            return canvasShape(of: selection)?.bounds
        case .several(let things):
            let frames = things.compactMap(canvasFrame(of:))
            return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
        }
    }

    /// Whether something is locked in place. An element is when it, or a group above it, is
    /// locked: nothing in a locked group moves, turns or is resized on its own (F4). Several
    /// things are, when every one of them is.
    func isLocked(_ selection: CanvasSelection) -> Bool {
        switch selection {
        case .element(let ref): placed(ref)?.isLocked == true
        case .screen(let id): treeScreen(id)?.isLocked == true
        case .several(let things): things.allSatisfy(isLocked)
        }
    }

    /// The single things of a selection that are still there, in the design's own order:
    /// its screens, then its elements from the back to the front, host by host (the screens'
    /// in their order, then the open canvas's), each before what it holds. What is in a
    /// container selected is left out. Read from the index: no walk of the design.
    func things(in selection: CanvasSelection?) -> [CanvasSelection] {
        #if DEBUG
        CanvasWork.thingsListed += 1
        #endif
        guard let selection else { return [] }
        let picked = selection.things
        guard picked.count > 1 else { return Array(picked.filter { canvasFrame(of: $0) != nil }) }
        let memo = index, screens = tree.screens
        let screenRank = Dictionary(screens.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var ordered: [CanvasSelection] = screens.map { .screen($0.id) }.filter(picked.contains)
        var elements: [(rank: Int, path: [Int], ref: ElementRef)] = []
        for case .element(let ref) in picked {
            guard let entry = memo[ref.element], !entry.path.isEmpty, ElementRef.Host(entry.host) == ref.host else { continue }
            let rank = switch entry.host {
            case .screen(let id): screenRank[id] ?? screens.count
            case .canvas: screens.count
            }
            elements.append((rank, entry.path, ref))
        }
        // In the order the design holds them: a container before what it holds, each before the
        // siblings after it.
        elements.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.path.lexicographicallyPrecedes($1.path) }
        // What is in a container selected goes with it: a member picked beside its container would be
        // copied or moved twice, and the lone copy would join the original.
        let selected = Set(elements.map(\.ref.element))
        for element in elements where memo.ancestors(of: element.ref.element).allSatisfy({ !selected.contains($0) }) {
            ordered.append(.element(element.ref))
        }
        return ordered
    }

    /// The frames of everything showing on the canvas apart from some things, and apart
    /// from what is on any screen among them or in any container among them: what those
    /// things can be lined up with as they are dragged. A dragged container's contents move
    /// with it, and lined up with where they were, they would stick there. Each screen's
    /// frame, then the things on it that aren't containers, back to front, then the open
    /// canvas's: read from the tree, each turned thing by the box round its shape.
    func canvasFrames(besides things: Set<CanvasSelection>) -> [CGRect] {
        let tree = tree
        var moving: Set<UUID> = []
        for case .element(let ref) in things { moving.insert(ref.element) }
        var frames: [CGRect] = []
        func visit(_ node: LayerNode, in space: TreeIndex.OwnSpace, on host: ElementRef.Host, at placement: Placement) {
            guard !node.isHidden else { return }
            let placed = space.placing(node)
            guard node.isContainer else {
                guard !things.contains(.element(ElementRef(host: host, element: node.id))) else { return }
                let shape = TurnedRect(rect: placed.frame, degrees: Rotation.kept(placed.degrees) ?? 0)
                frames.append(placement.canvasRect(for: shape.bounds))
                return
            }
            // A container dragged takes what is in it along.
            guard !moving.contains(node.id) else { return }
            for child in node.children { visit(child, in: placed.space, on: host, at: placement) }
        }
        for screen in tree.screens where !things.contains(.screen(screen.id)) {
            let placement = screen.placement
            frames.append(screen.canvasFrame(on: tree.device(of: screen)))
            let root = TreeIndex.OwnSpace.host.placing(screen.root).space
            for node in screen.root.children { visit(node, in: root, on: .screen(screen.id), at: placement) }
        }
        for node in tree.canvas {
            let scale = node.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            visit(node, in: .host, on: .canvas, at: Placement(origin: .zero, scale: scale))
        }
        return frames
    }

    /// Puts things where the top-left corners of their boxes (see `canvasFrame(of:)`) are
    /// given, in canvas points; a turned element's own frame moves by the same distance.
    /// Elements and screens land on whole points of their own, so that those that started
    /// on whole points keep their places relative to each other; a drawing, whose ink lies
    /// where it was drawn, goes exactly where it is put. Whatever is locked or gone stays.
    /// All of it is one change, read from the index and written on the tree: nothing lowers
    /// the projection, on any frame of a drag.
    ///
    /// A container placed freely moves by its own frame, in one write, and everything in it
    /// rides along, those locked on their own included: it is one thing. Anything else goes
    /// through its parent as `place` puts it (`placing(_:at:)`), the one place My call 20 is
    /// worked out: in a row, column, grid or overlay, a new place takes it out to the top of
    /// its screen, or of the open canvas, unless what holds its screen's things is laid out
    /// too, which lays it back. A screen moves by its origin.
    func position(_ origins: [CanvasSelection: CGPoint]) {
        // Worked out first, against one version of the tree: the design can't be read while it is being changed.
        var containers: [(host: TreeIndex.Host, path: [Int], origin: CGPoint)] = []
        var placings: [Placing] = []
        var screens: [TreeScreen.ID: CGPoint] = [:]
        // A member given beside its container moves with it, not on its own.
        let alone = Set(things(in: CanvasSelection(origins.keys)))
        for (thing, origin) in origins where alone.contains(thing) {
            switch thing {
            case .element(let ref):
                // Read from the tree, as every frame of a drag reads it, so that a frame builds the store's
                // index and never lowers the design to its list (clause (m)).
                guard let placed = placed(ref), !placed.isLocked else { continue }
                let box = placed.canvasShape.bounds
                let target = placed.placement.localPoint(for: origin), current = placed.placement.localPoint(for: box.origin)
                let distance = CGSize(width: target.x - current.x, height: target.y - current.y)
                guard placed.node.isContainer, !placed.isLaidOut else {
                    if let placing = placing(ref.element, at: placed.frame.offsetBy(dx: distance.width, dy: distance.height)) {
                        placings.append(placing)
                    }
                    continue
                }
                // Where the container is, from the index `placed` built for this version.
                guard let entry = index[ref.element], let moved = self.origin(of: ref.element, movedBy: distance) else { continue }
                let landed = CGPoint(x: moved.x.rounded(), y: moved.y.rounded())
                if landed != placed.node.frame.origin { containers.append((entry.host, entry.path, landed)) }
            case .screen(let id):
                guard let screen = treeScreen(id), screen.isLocked != true else { continue }
                let landed = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
                if landed != screen.origin { screens[id] = landed }
            case .several:
                continue
            }
        }
        guard !containers.isEmpty || !placings.isEmpty || !screens.isEmpty else { return }
        #if DEBUG
        let version = contentVersion
        #endif
        apply { content in
            // Frames and origins first: none of them changes a path, and a thing taken out of a row may.
            for container in containers {
                content.tree.changeNode(on: container.host, at: container.path) { $0.frame.origin = container.origin }
            }
            for (id, origin) in screens {
                guard let index = content.tree.screens.firstIndex(where: { $0.id == id }) else { continue }
                content.tree.screens[index].origin = origin
            }
            Self.write(placings, to: &content.tree)
        }
        #if DEBUG
        if contentVersion != version { ListWork.wrote(containers.count + placings.count) }
        #endif
    }

    /// Lines several things up with one another: by an edge, or through the middle, of
    /// the area they cover together. A locked thing stays where it is and the others line
    /// up with it all the same.
    func align(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) {
        lineUp(selection) { ElementLayout.aligned($0, alignment) }
    }

    /// Spaces three or more things evenly, across or down, between the two furthest apart.
    func distribute(_ selection: CanvasSelection, _ distribution: ElementLayout.Distribution) {
        lineUp(selection) { ElementLayout.distributed($0, distribution) }
    }

    /// Lines up what is selected as `rule` lines up their boxes on the canvas, moving only those `moves` lets go; the
    /// others stay where they are, and the rest line up with them all the same. What is already in place is left exactly
    /// where it is. One change.
    func lineUp(_ selection: CanvasSelection, moving moves: (CanvasSelection) -> Bool = { _ in true }, _ rule: ([CGRect]) -> [CGRect]) {
        let placed = things(in: selection).compactMap { thing in canvasFrame(of: thing).map { (thing, $0) } }
        guard placed.count > 1 else { return }
        let arranged = rule(placed.map(\.1))
        var origins: [CanvasSelection: CGPoint] = [:]
        // What is already in place is left exactly where it is, not put back on a whole point.
        for (index, (thing, frame)) in placed.enumerated() where moves(thing) && !isClose(arranged[index].origin, frame.origin) {
            origins[thing] = arranged[index].origin
        }
        position(origins)
    }

    private func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }

    /// Locks or unlocks everything selected, as one step: each thing's own flag, and nothing above it.
    func setLocked(_ isLocked: Bool, _ selection: CanvasSelection) {
        var nodes: [UUID] = []
        var screens: [TreeScreen.ID] = []
        for thing in things(in: selection) {
            switch thing {
            case .element(let ref): nodes.append(ref.element)
            case .screen(let id): screens.append(id)
            case .several: continue
            }
        }
        setOwnLocks(isLocked, nodes: nodes, screens: screens)
    }

    /// Sets the own lock of each node and screen given, as one change: a node's own flag, and a screen's (nil once
    /// unlocked). A screen's root, and what the design doesn't have, are passed over. Found through the index.
    func setOwnLocks(_ isLocked: Bool, nodes: [UUID], screens: [TreeScreen.ID]) {
        let memo = index
        var seen: Set<UUID> = []
        let places = nodes.compactMap { id -> (host: TreeIndex.Host, path: [Int])? in
            guard seen.insert(id).inserted, let entry = memo[id], !entry.path.isEmpty else { return nil }
            return (entry.host, entry.path)
        }
        guard !places.isEmpty || !screens.isEmpty else { return }
        changeTree(writing: places.count) { tree in
            for place in places { tree.changeNode(on: place.host, at: place.path) { $0.isLocked = isLocked } }
            for id in screens {
                guard let index = tree.screens.firstIndex(where: { $0.id == id }) else { continue }
                tree.screens[index].isLocked = isLocked ? true : nil
            }
        }
    }

    /// Copies everything selected: each element a little down and to the right of its
    /// original, a container whole with everything in it (`duplicate(node:)`), and the screens
    /// together to the right of them all, as one step. Returns the copies.
    @discardableResult
    func duplicate(_ selection: CanvasSelection) -> CanvasSelection? {
        let originals = things(in: selection)
        let screenFrames = originals.compactMap { thing -> CGRect? in
            if case .screen(let id) = thing { treeScreen(id).map { $0.canvasFrame(on: tree.device(of: $0)) } } else { nil }
        }
        // Far enough that no copy of a screen lands on another of the screens copied.
        let shift = screenFrames.dropFirst().reduce(screenFrames.first) { $0?.union($1) }.map { $0.width + 60 } ?? 0
        var copies: [CanvasSelection] = []
        asOneStep {
            for thing in originals {
                switch thing {
                case .element(let ref):
                    if let copy = duplicate(node: ref.element) { copies.append(.element(ElementRef(host: ref.host, element: copy))) }
                case .screen(let id):
                    guard let original = treeScreen(id), let copy = duplicateTreeScreen(id) else { continue }
                    updateTreeScreen(copy) { $0.origin.x = original.origin.x + shift }
                    copies.append(.screen(copy))
                case .several:
                    continue
                }
            }
        }
        return CanvasSelection(copies)
    }

    /// Deletes everything selected that isn't locked, by itself or by a group above it, as
    /// one step. A container goes with everything in it, those locked on their own too
    /// (`delete(nodes:)`).
    func delete(_ selection: CanvasSelection) {
        let things = things(in: selection).filter { !isLocked($0) }
        asOneStep {
            delete(nodes: Set(things.compactMap { thing -> UUID? in
                if case .element(let ref) = thing { ref.element } else { nil }
            }))
            for case .screen(let id) in things { deleteScreen(id) }
        }
    }

    /// Gives each element selected to whatever it now lies on, as after a drag: see
    /// `rehost(_:)`. Each moves on the tree in a change of its own, a container whole with
    /// everything in it, all of them one step; each lands in the design's
    /// order, back to front, on top of what is on its new host, so that those landing together
    /// are stacked there as they were. Returns the selection as it now stands.
    func rehost(_ selection: CanvasSelection) -> CanvasSelection? {
        var rehomed: [CanvasSelection] = []
        asOneStep {
            for thing in things(in: selection) {
                if case .element(let ref) = thing {
                    rehomed.append(.element(rehost(ref)))
                } else {
                    rehomed.append(thing)
                }
            }
        }
        return CanvasSelection(rehomed)
    }
}

import CoreGraphics
import Foundation

/// What can be done to several things at once: elements, drawings among them, and
/// screens, wherever each of them is. Things are lined up and moved by where they are on
/// the canvas, so that an element on a screen and a note on the open canvas can be lined
/// up with each other. Each of these is one step to undo.
extension DesignStore {
    /// The shape something takes up on the canvas: an element's rect with the angle it is
    /// turned to, or a screen's frame, which never turns. Nil for several things, which
    /// have no shape of their own, and when it is gone.
    func canvasShape(of selection: CanvasSelection) -> TurnedRect? {
        switch selection {
        case .element(let ref):
            return resolve(ref).map { TurnedRect(rect: $0.placement.canvasRect(for: $0.element.frame), degrees: $0.element.resolvedRotation) }
        case .screen(let id):
            return screen(id).map { TurnedRect(rect: $0.canvasFrame, degrees: 0) }
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
        case .element(let ref): resolve(ref).map { isLockedWithItsGroups($0.element) } == true
        case .screen(let id): screen(id)?.isLocked == true
        case .several(let things): things.allSatisfy(isLocked)
        }
    }

    /// The single things of a selection that are still there, in the design's own order:
    /// its screens, then its elements from the back to the front.
    func things(in selection: CanvasSelection?) -> [CanvasSelection] {
        guard let selection else { return [] }
        let picked = selection.things
        guard picked.count > 1 else { return Array(picked.filter { canvasFrame(of: $0) != nil }) }
        var ordered: [CanvasSelection] = screens.map { .screen($0.id) }.filter(picked.contains)
        for element in content.elements {
            let host: ElementRef.Host = element.parent.map { .screen($0) } ?? .canvas
            let thing = CanvasSelection.element(ElementRef(host: host, element: element.id))
            if picked.contains(thing) { ordered.append(thing) }
        }
        return ordered
    }

    /// The frames of everything showing on the canvas apart from some things, and apart
    /// from what is on any screen among them or in any group among them: what those things
    /// can be lined up with as they are dragged. A dragged group's members move with it, and
    /// lined up with where they were, it would stick there.
    func canvasFrames(besides things: Set<CanvasSelection>) -> [CGRect] {
        var moving: Set<DesignElement.ID> = []
        for case .element(let ref) in things where groupItem(ref.element) != nil {
            moving.formUnion(content.leaves(of: ref.element).map(\.id))
        }
        func isLeftOut(_ id: DesignElement.ID, on host: ElementRef.Host) -> Bool {
            moving.contains(id) || things.contains(.element(ElementRef(host: host, element: id)))
        }
        var frames: [CGRect] = []
        for screen in screens where !things.contains(.screen(screen.id)) {
            frames.append(screen.canvasFrame)
            for element in screen.elements where !element.isHidden && !isLeftOut(element.id, on: .screen(screen.id)) {
                frames.append(screen.placement.canvasRect(for: element.shapeBounds))
            }
        }
        for floating in floating where !floating.element.isHidden && !isLeftOut(floating.id, on: .canvas) {
            frames.append(floating.placement.canvasRect(for: floating.element.shapeBounds))
        }
        return frames
    }

    /// Puts things where the top-left corners of their boxes (see `canvasFrame(of:)`) are
    /// given, in canvas points; a turned element's own frame moves by the same distance.
    /// Elements and screens land on whole points of their own, so that those that started
    /// on whole points keep their places relative to each other; a drawing, whose ink lies
    /// where it was drawn, goes exactly where it is put. Whatever is locked or gone stays.
    ///
    /// A group moves everything in it by the same distance across the canvas, in the same
    /// change, those locked on their own included: a group is one thing. Its box is fitted
    /// round them where they land (`keepGroupsSound()`).
    func position(_ origins: [CanvasSelection: CGPoint]) {
        // Worked out first: the design can't be read while it is being changed.
        var elements: [DesignElement.ID: CGPoint] = [:]
        // What moves with a group: put after the rest, it wins over the same thing given alone.
        var grouped: [DesignElement.ID: CGPoint] = [:]
        var screens: [DesignScreen.ID: CGPoint] = [:]
        for (thing, origin) in origins where !isLocked(thing) {
            switch thing {
            case .element(let ref):
                guard let (element, placement) = resolve(ref), let box = canvasShape(of: thing)?.bounds else { continue }
                guard element.kind == .group else {
                    elements[ref.element] = Self.origin(of: element, movedBy: box.origin, to: origin, in: placement)
                    continue
                }
                for leaf in content.leaves(of: element.id) {
                    guard let own = self.placement(of: leaf) else { continue }
                    grouped[leaf.id] = Self.origin(of: leaf, movedBy: box.origin, to: origin, in: own)
                }
            case .screen(let id):
                guard screen(id) != nil else { continue }
                screens[id] = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
            case .several:
                continue
            }
        }
        elements.merge(grouped) { _, withItsGroup in withItsGroup }
        guard !elements.isEmpty || !screens.isEmpty else { return }
        apply { content in
            for (id, origin) in elements { content.update(id) { $0.frame.origin = origin } }
            for (id, origin) in screens { content.updateScreen(id) { $0.origin = origin } }
        }
    }

    /// Where an element's frame goes, in its own points, when a box on the canvas with it is
    /// moved from `from` to `to`: by the same distance, on whole points unless it is a drawing.
    private static func origin(of element: DesignElement, movedBy from: CGPoint, to: CGPoint, in placement: Placement) -> CGPoint {
        let target = placement.localPoint(for: to), current = placement.localPoint(for: from)
        let local = CGPoint(x: element.frame.minX + target.x - current.x, y: element.frame.minY + target.y - current.y)
        return element.kind == .drawing ? local : CGPoint(x: local.x.rounded(), y: local.y.rounded())
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

    private func lineUp(_ selection: CanvasSelection, _ rule: ([CGRect]) -> [CGRect]) {
        let placed = things(in: selection).compactMap { thing in canvasFrame(of: thing).map { (thing, $0) } }
        guard placed.count > 1 else { return }
        let arranged = rule(placed.map(\.1))
        var origins: [CanvasSelection: CGPoint] = [:]
        // What is already in place is left exactly where it is, not put back on a whole point.
        for (index, (thing, frame)) in placed.enumerated() where !isClose(arranged[index].origin, frame.origin) {
            origins[thing] = arranged[index].origin
        }
        position(origins)
    }

    private func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
    }

    /// Makes one change to several elements, as one step.
    func update(_ refs: [ElementRef], _ body: (inout DesignElement) -> Void) {
        let present = refs.filter { resolve($0) != nil }
        guard !present.isEmpty else { return }
        apply { content in
            for ref in present { content.update(ref.element, body) }
        }
    }

    /// Locks or unlocks everything selected.
    func setLocked(_ isLocked: Bool, _ selection: CanvasSelection) {
        let present = things(in: selection)
        apply { content in
            for thing in present {
                switch thing {
                case .element(let ref):
                    content.update(ref.element) { $0.isLocked = isLocked }
                case .screen(let id):
                    content.updateScreen(id) { $0.isLocked = isLocked ? true : nil }
                case .several:
                    continue
                }
            }
        }
    }

    /// Copies everything selected: each element a little down and to the right of its
    /// original, and the screens together to the right of them all. Returns the copies.
    @discardableResult
    func duplicate(_ selection: CanvasSelection) -> CanvasSelection? {
        let originals = things(in: selection)
        let screenFrames = originals.compactMap { thing -> CGRect? in
            if case .screen(let id) = thing { screen(id)?.canvasFrame } else { nil }
        }
        // Far enough that no copy of a screen lands on another of the screens copied.
        let shift = screenFrames.dropFirst().reduce(screenFrames.first) { $0?.union($1) }.map { $0.width + 60 } ?? 0
        var copies: [CanvasSelection] = []
        asOneStep {
            for thing in originals {
                switch thing {
                case .element(let ref):
                    if let copy = duplicate(ref) { copies.append(.element(copy)) }
                case .screen(let id):
                    guard let original = screen(id), let copy = duplicateScreen(id) else { continue }
                    updateScreen(copy.id) { $0.origin.x = original.origin.x + shift }
                    copies.append(.screen(copy.id))
                case .several:
                    continue
                }
            }
        }
        return CanvasSelection(copies)
    }

    /// Deletes everything selected that isn't locked.
    func delete(_ selection: CanvasSelection) {
        let things = things(in: selection).filter { !isLocked($0) }
        asOneStep {
            delete(things.compactMap { thing -> ElementRef? in
                if case .element(let ref) = thing { ref } else { nil }
            })
            for case .screen(let id) in things { deleteScreen(id) }
        }
    }

    /// Gives each element selected to whatever it now lies on, as after a drag: see
    /// `rehost(_:)`. A group lands whole, in a change of its own (`rehostGroup(_:)`); each
    /// lands in the design's order, back to front, on top of what is on its new host, so that
    /// those landing together are stacked there as they were. Returns the selection as it now
    /// stands.
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

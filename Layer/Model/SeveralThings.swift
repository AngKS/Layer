import CoreGraphics
import Foundation

/// What can be done to several things at once: elements, drawings among them, and
/// screens, wherever each of them is. Things are lined up and moved by where they are on
/// the canvas, so that an element on a screen and a note on the open canvas can be lined
/// up with each other. Each of these is one step to undo.
extension DesignStore {
    /// Where something is on the canvas: a screen's frame, an element's, or the area that
    /// several things cover together. Nil when it is gone.
    func canvasFrame(of selection: CanvasSelection) -> CGRect? {
        switch selection {
        case .element(let ref):
            return resolve(ref).map { $0.placement.canvasRect(for: $0.element.frame) }
        case .screen(let id):
            return screen(id)?.canvasFrame
        case .several(let things):
            let frames = things.compactMap(canvasFrame(of:))
            return frames.dropFirst().reduce(frames.first) { $0?.union($1) }
        }
    }

    /// Whether something is locked in place. Several things are, when every one of them is.
    func isLocked(_ selection: CanvasSelection) -> Bool {
        switch selection {
        case .element(let ref): resolve(ref)?.element.isLocked == true
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
    /// from what is on any screen among them: what those things can be lined up with as
    /// they are dragged.
    func canvasFrames(besides things: Set<CanvasSelection>) -> [CGRect] {
        var frames: [CGRect] = []
        for screen in screens where !things.contains(.screen(screen.id)) {
            frames.append(screen.canvasFrame)
            for element in screen.elements where !element.isHidden && !things.contains(.element(ElementRef(host: .screen(screen.id), element: element.id))) {
                frames.append(screen.placement.canvasRect(for: element.frame))
            }
        }
        for floating in floating where !floating.element.isHidden && !things.contains(.element(ElementRef(host: .canvas, element: floating.id))) {
            frames.append(floating.canvasFrame)
        }
        return frames
    }

    /// Puts things where their top-left corners are given, in canvas points. Elements and
    /// screens land on whole points of their own, so that those that started on whole
    /// points keep their places relative to each other; a drawing, whose ink lies where
    /// it was drawn, goes exactly where it is put. Whatever is locked or gone stays.
    func position(_ origins: [CanvasSelection: CGPoint]) {
        // Worked out first: the design can't be read while it is being changed.
        var elements: [DesignElement.ID: CGPoint] = [:]
        var screens: [DesignScreen.ID: CGPoint] = [:]
        for (thing, origin) in origins where !isLocked(thing) {
            switch thing {
            case .element(let ref):
                guard let (element, placement) = resolve(ref) else { continue }
                let local = placement.localPoint(for: origin)
                elements[ref.element] = element.kind == .drawing ? local : CGPoint(x: local.x.rounded(), y: local.y.rounded())
            case .screen(let id):
                guard screen(id) != nil else { continue }
                screens[id] = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
            case .several:
                continue
            }
        }
        guard !elements.isEmpty || !screens.isEmpty else { return }
        apply { content in
            for (id, origin) in elements { content.update(id) { $0.frame.origin = origin } }
            for (id, origin) in screens { content.updateScreen(id) { $0.origin = origin } }
        }
    }

    /// Lines several things up with one another: by an edge, or through the middle, of
    /// the area they cover together. A locked thing stays where it is and the others line
    /// up with it all the same.
    func align(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) {
        arrange(selection) { ElementLayout.aligned($0, alignment) }
    }

    /// Spaces three or more things evenly, across or down, between the two furthest apart.
    func distribute(_ selection: CanvasSelection, _ distribution: ElementLayout.Distribution) {
        arrange(selection) { ElementLayout.distributed($0, distribution) }
    }

    private func arrange(_ selection: CanvasSelection, _ rule: ([CGRect]) -> [CGRect]) {
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
    /// `rehost(_:)`. Returns the selection as it now stands.
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

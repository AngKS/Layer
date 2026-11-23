import CoreGraphics

/// What a loop drawn on the canvas goes round: the lasso's loop, or the corners of a box
/// dragged out with a finger. The loop is closed by joining its end to its start.
enum Enclosure {
    /// How much of a thing a loop has to go round to pick it.
    static let share: CGFloat = 0.5
    /// How much of a screen a loop has to go round to pick the screen itself. Short of
    /// that, it picks the elements on the screen that it goes round.
    static let screenShare: CGFloat = 0.9

    /// Whether a point is inside a loop. A point on the loop itself may fall either way.
    static func contains(_ loop: [CGPoint], _ point: CGPoint) -> Bool {
        guard loop.count >= 3 else { return false }
        var isInside = false
        var previous = loop[loop.count - 1]
        for current in loop {
            // Each side of the loop that a line running right from the point crosses
            // takes the point from outside to inside, or back.
            if (current.y > point.y) != (previous.y > point.y) {
                let crossing = current.x + (point.y - current.y) / (previous.y - current.y) * (previous.x - current.x)
                if point.x < crossing { isInside.toggle() }
            }
            previous = current
        }
        return isInside
    }

    /// The area a loop covers at its widest and tallest. Nil for a loop that covers none.
    static func bounds(of loop: [CGPoint]) -> CGRect? {
        guard loop.count >= 3, let first = loop.first else { return nil }
        var (minX, maxX, minY, maxY) = (first.x, first.x, first.y, first.y)
        for point in loop.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
    }

    /// How much of an area lies inside a loop, from 0 to 1, measured at a grid of points
    /// `across` each way. The answer is out by at most about one part in `across`.
    static func coverage(of rect: CGRect, by loop: [CGPoint], across: Int = 8) -> CGFloat {
        guard let bounds = bounds(of: loop), bounds.intersects(rect) else { return 0 }
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY),
        ]
        var samples = corners
        for row in 0..<across {
            for column in 0..<across {
                samples.append(CGPoint(
                    x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(across),
                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(across)
                ))
            }
        }
        // The corners settle the two plain cases exactly; between them the grid measures.
        let inside = samples.map { contains(loop, $0) }
        if inside.allSatisfy({ $0 }) { return 1 }
        if !inside.contains(true) { return 0 }
        return CGFloat(inside.dropFirst(corners.count).filter { $0 }.count) / CGFloat(across * across)
    }

    /// The same for a turned box: the samples are laid over the box before it is turned,
    /// and turned about its centre with it.
    static func coverage(of shape: TurnedRect, by loop: [CGPoint], across: Int = 8) -> CGFloat {
        guard shape.degrees != 0 else { return coverage(of: shape.rect, by: loop, across: across) }
        guard let bounds = bounds(of: loop), bounds.intersects(shape.bounds) else { return 0 }
        let rect = shape.rect
        let corners = shape.corners
        var samples = corners
        for row in 0..<across {
            for column in 0..<across {
                let point = CGPoint(
                    x: rect.minX + rect.width * (CGFloat(column) + 0.5) / CGFloat(across),
                    y: rect.minY + rect.height * (CGFloat(row) + 0.5) / CGFloat(across)
                )
                samples.append(Rotation.rotate(point, about: shape.centre, by: shape.degrees))
            }
        }
        let inside = samples.map { contains(loop, $0) }
        if inside.allSatisfy({ $0 }) { return 1 }
        if !inside.contains(true) { return 0 }
        return CGFloat(inside.dropFirst(corners.count).filter { $0 }.count) / CGFloat(across * across)
    }

    /// How many of some points lie inside a loop, from 0 to 1: for ink, which is picked
    /// by where its strokes run, not by the box round them.
    static func coverage(of points: [CGPoint], by loop: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, bounds(of: loop) != nil else { return 0 }
        return CGFloat(points.filter { contains(loop, $0) }.count) / CGFloat(points.count)
    }
}

extension DesignStore {
    /// The things a loop drawn on the canvas goes round, in canvas points: every element
    /// that at least half lies inside it, and every screen that all but lies inside it. A
    /// screen picked this way stands for what is on it. A group is picked whole, by its box,
    /// as an element is; what is in a group is never picked on its own. Locked and hidden
    /// things are left alone.
    func things(enclosedBy loop: [CGPoint]) -> [CanvasSelection] {
        guard let bounds = Enclosure.bounds(of: loop) else { return [] }
        var found: [CanvasSelection] = []

        func isPicked(_ element: DesignElement, _ placement: Placement) -> Bool {
            guard !element.isLocked, !element.isHidden else { return false }
            let shape = TurnedRect(rect: placement.canvasRect(for: element.frame), degrees: element.resolvedRotation)
            guard shape.bounds.intersects(bounds) else { return false }
            if element.kind == .drawing {
                let ink = element.sketchStrokes.flatMap(\.points).map(placement.canvasPoint(for:))
                if !ink.isEmpty { return Enclosure.coverage(of: ink, by: loop) >= Enclosure.share }
            }
            return Enclosure.coverage(of: shape, by: loop) >= Enclosure.share
        }

        // The screens not picked themselves, whose things may be.
        var placements: [DesignScreen.ID: Placement] = [:]
        for screen in screens {
            // Measured finely: all but all of a screen is a close call.
            if screen.isLocked != true, Enclosure.coverage(of: screen.canvasFrame, by: loop, across: 32) >= Enclosure.screenShare {
                found.append(.screen(screen.id))
            } else {
                placements[screen.id] = screen.placement
            }
        }
        // The list itself, group items in it: only what is in no group is picked, a group
        // standing for everything in it. Its own lock and hide are then all it has.
        for element in projection.elements where element.group == nil {
            let placement: Placement
            if let parent = element.parent {
                guard let onScreen = placements[parent] else { continue }
                placement = onScreen
            } else {
                placement = Placement(origin: .zero, scale: element.scale ?? 1)
            }
            guard isPicked(element, placement) else { continue }
            found.append(.element(ElementRef(host: element.parent.map { .screen($0) } ?? .canvas, element: element.id)))
        }
        return found
    }
}

import CoreGraphics

/// Turns rough sketch positions into tidy element frames, and keeps frames tidy while the
/// user moves and resizes them. Frames here are in a screen's logical points.
enum ElementLayout {
    enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// The corner diagonally across.
        var opposite: Corner {
            switch self {
            case .topLeft: .bottomRight
            case .topRight: .bottomLeft
            case .bottomLeft: .topRight
            case .bottomRight: .topLeft
            }
        }
    }

    /// The size an element starts at, on the standard phone.
    static func size(for kind: ElementKind, sketch: CGRect) -> CGSize {
        kind.spec.size.size(sketched: sketch)
    }

    /// Small elements stay where they were drawn across the screen; the rest are centred.
    static func keepsSketchedPosition(_ kind: ElementKind) -> Bool {
        kind.spec.keepsSketchedPosition
    }

    /// Kinds that usually run across the screen, and keep their side margins on other devices.
    static func runsAcross(_ kind: ElementKind) -> Bool {
        kind.spec.runsAcross
    }

    /// A new element takes its kind's standard size, sits centred across the screen, and
    /// keeps the height at which it was sketched. Elements that run edge to edge keep
    /// their side margins on wider and narrower devices.
    static func frame(for kind: ElementKind, sketch: CGRect, on device: DeviceFrame = .iPhone) -> CGRect {
        var size = size(for: kind, sketch: sketch)
        if runsAcross(kind) {
            size.width += device.size.width - DeviceFrame.iPhone.size.width
        }
        let top = device.safeTop + 8
        let bottom = device.size.height - device.safeBottom - 8 - size.height
        let y = min(max(snap(sketch.midY - size.height / 2, to: 4), top), max(top, bottom))
        var x = (device.size.width - size.width) / 2
        if keepsSketchedPosition(kind) {
            x = min(max(snap(sketch.midX - size.width / 2, to: 4), 16), max(16, device.size.width - 16 - size.width))
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The side margin of text that is aligned to the leading edge.
    static let margin: CGFloat = 20
    /// The gap between two elements side by side.
    static let gutter: CGFloat = 12
    /// The gaps between one element and the next that a sketched element snaps to.
    static let rhythm: [CGFloat] = DesignTokens.standard.rhythm

    /// A new element drawn with the Magic Pen. It starts from `frame(for:sketch:on:)` and
    /// keeps more of what was drawn: the width of a box drawn clearly narrower than the
    /// screen (half a screen wide becomes one of two columns), text drawn against the
    /// leading edge as leading-aligned, a title's size from how tall it was drawn, and a
    /// gap to the element above, or a row with the one beside it, that is tidy.
    ///
    /// `others` are the frames already on the screen. Returns the frame and, for text
    /// that should not be centred, its alignment.
    static func sketched(_ kind: ElementKind, sketch: CGRect, on device: DeviceFrame = .iPhone, among others: [CGRect] = []) -> (frame: CGRect, alignment: TextAlignmentChoice?) {
        var frame = Self.frame(for: kind, sketch: sketch, on: device)
        var alignment: TextAlignmentChoice?
        let width = device.size.width
        let isDrawnLeading = sketch.minX < margin + (width - margin * 2) * 0.15 && width / 2 - sketch.midX > width * 0.08

        switch kind.spec.sketchFit {
        case .words(let sizedByHeight):
            if sizedByHeight {
                // Bigger scribbles are bigger titles: Title 2, Title, or Large Title.
                let height: CGFloat = sketch.height < 34 ? 32 : sketch.height <= 52 ? 40 : 48
                frame.origin.y += (frame.height - height) / 2
                frame.size.height = height
            }
            // Text drawn beside something on its left, such as a checkbox, starts after it.
            let rowStart = others
                .filter { $0.minY < sketch.maxY && sketch.minY < $0.maxY && $0.maxX <= sketch.minX + 8 }
                .map(\.maxX).max()
            if let rowStart, width - margin - (rowStart + gutter) >= 60 {
                frame.origin.x = rowStart + gutter
                frame.size.width = width - margin - frame.origin.x
                alignment = .leading
            } else if isDrawnLeading {
                frame.origin.x = margin
                frame.size.width = width - margin * 2
                alignment = .leading
            }
        case .box(let minimum):
            let full = frame.width
            if sketch.width < full * 0.7, sketch.width > 0 {
                let left = (width - full) / 2
                if sketch.width >= full * 0.3 {
                    // One of two columns.
                    let half = ((full - gutter) / 2).rounded(.down)
                    frame.size.width = half
                    frame.origin.x = sketch.midX < width / 2 ? left : left + full - half
                } else {
                    frame.size.width = max(snap(sketch.width, to: 4), minimum)
                    frame.origin.x = abs(sketch.midX - width / 2) < width * 0.06
                        ? ((width - frame.width) / 2).rounded()
                        : min(max(snap(sketch.midX - frame.width / 2, to: 4), left), width - left - frame.width)
                }
            }
        case .standard:
            break
        }

        // Line up with what is already there: centred in a row with an element beside it,
        // or a tidy gap below the element above.
        let beside = others.filter { abs($0.midY - frame.midY) < max(12, min($0.height, frame.height) / 2) && !overlapsAcross($0, frame) }
        if let neighbour = beside.min(by: { abs($0.midY - frame.midY) < abs($1.midY - frame.midY) }) {
            frame.origin.y = (neighbour.midY - frame.height / 2).rounded()
        } else if let above = others.filter({ $0.maxY <= frame.minY + 4 && overlapsAcross($0, frame) }).max(by: { $0.maxY < $1.maxY }) {
            let gap = frame.minY - above.maxY
            if let tidy = rhythm.min(by: { abs($0 - gap) < abs($1 - gap) }), abs(tidy - gap) <= 6 {
                frame.origin.y = above.maxY + tidy
            }
        }
        // Small controls and narrow boxes drawn near an existing leading edge share it.
        if !isCentered(frame, in: width), let edge = others.map(\.minX).min(by: { abs($0 - frame.minX) < abs($1 - frame.minX) }),
           abs(edge - frame.minX) <= 8 {
            frame.origin.x = edge
        }
        return (frame, alignment)
    }

    /// Whether two frames share any of the screen's width.
    private static func overlapsAcross(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX
    }

    /// Where a new screen goes: centred on the sketch and as tall as it was drawn.
    static func screenPlacement(for sketch: CGRect, device: DeviceFrame = .iPhone) -> Placement {
        let scale = min(max(sketch.height / device.size.height, 0.15), 3)
        let size = CGSize(width: device.size.width * scale, height: device.size.height * scale)
        return Placement(
            origin: CGPoint(x: (sketch.midX - size.width / 2).rounded(), y: (sketch.midY - size.height / 2).rounded()),
            scale: scale
        )
    }

    /// Moves a frame. On a screen of `screen` size its centre can snap to the screen's
    /// centre line when close; it is free to leave the screen altogether.
    static func moved(_ frame: CGRect, by translation: CGSize, snapsToCenter: Bool, in screen: CGSize = DeviceFrame.iPhone.size) -> CGRect {
        var result = frame.offsetBy(dx: translation.width, dy: translation.height)
        result.origin.x.round()
        result.origin.y.round()
        // The exact centre can fall on a half point, so snap after rounding.
        if snapsToCenter, abs(result.midX - screen.width / 2) < 5, result.midY > 0, result.midY < screen.height {
            result.origin.x = (screen.width - result.width) / 2
        }
        return result
    }

    static func resized(_ frame: CGRect, from corner: Corner, by translation: CGSize, kind: ElementKind) -> CGRect {
        let minimum = kind.spec.minimumSize
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        switch corner {
        case .topLeft, .bottomLeft: minX = min(frame.minX + translation.width, maxX - minimum.width)
        case .topRight, .bottomRight: maxX = max(frame.maxX + translation.width, minX + minimum.width)
        }
        if !kind.spec.hasFixedHeight {
            switch corner {
            case .topLeft, .topRight: minY = min(frame.minY + translation.height, maxY - minimum.height)
            case .bottomLeft, .bottomRight: maxY = max(frame.maxY + translation.height, minY + minimum.height)
            }
        }
        return CGRect(
            x: minX.rounded(),
            y: minY.rounded(),
            width: (maxX - minX).rounded(),
            height: max((maxY - minY).rounded(), minimum.height)
        )
    }

    /// Resizing an avatar or a radio button keeps it round.
    static func resizedKeepingShape(_ frame: CGRect, from corner: Corner, by translation: CGSize, kind: ElementKind) -> CGRect {
        var result = resized(frame, from: corner, by: translation, kind: kind)
        guard kind.spec.staysSquare else { return result }
        let side = max(result.width, result.height)
        if corner == .topLeft || corner == .bottomLeft { result.origin.x = result.maxX - side }
        if corner == .topLeft || corner == .topRight { result.origin.y = result.maxY - side }
        result.size = CGSize(width: side, height: side)
        return result
    }

    /// Resizing a turned element, in its own axes. `translation` is the drag as it went
    /// across the glass, in the frame's points; turned back by the element's angle, it
    /// resizes the upright frame as `resizedKeepingShape` does. The frame then moves so
    /// that the corner opposite the one dragged stays where it was on the canvas. Upright,
    /// it is `resizedKeepingShape` exactly, whole points and all.
    static func resizedTurned(_ frame: CGRect, degrees: Double, from corner: Corner, by translation: CGSize, kind: ElementKind) -> CGRect {
        guard Rotation.normalized(degrees) != 0 else {
            return resizedKeepingShape(frame, from: corner, by: translation, kind: kind)
        }
        let along = Rotation.rotate(CGPoint(x: translation.width, y: translation.height), about: .zero, by: -degrees)
        let sized = resizedKeepingShape(frame, from: corner, by: CGSize(width: along.x, height: along.y), kind: kind)
        let fixed = TurnedRect(rect: frame, degrees: degrees).corner(corner.opposite)
        let resized = TurnedRect(rect: sized, degrees: degrees)
        let reach = resized.corner(corner.opposite)
        let centre = CGPoint(x: fixed.x - (reach.x - resized.centre.x), y: fixed.y - (reach.y - resized.centre.y))
        return CGRect(x: centre.x - sized.width / 2, y: centre.y - sized.height / 2, width: sized.width, height: sized.height)
    }

    /// Resizing a group by a corner, as `resizedTurned` does an element, but in proportion:
    /// the drag, turned back into the frame's own axes, would scale its width and its height
    /// each by some factor, and both are scaled by the one that changes more, growing or
    /// shrinking alike, with no side under 8 points. The corner across from the one dragged
    /// stays where it was on the canvas. Its members scale with it alike, so that one turned
    /// in it is never sheared.
    static func resizedProportionally(_ frame: CGRect, degrees: Double, from corner: Corner, by translation: CGSize) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let along = Rotation.rotate(CGPoint(x: translation.width, y: translation.height), about: .zero, by: -degrees)
        // How much longer each side gets, as the corner dragged moves away from the one across.
        let wider = corner == .topLeft || corner == .bottomLeft ? -along.x : along.x
        let taller = corner == .topLeft || corner == .topRight ? -along.y : along.y
        let across = (frame.width + wider) / frame.width, down = (frame.height + taller) / frame.height
        // Taking the larger, a drag inwards across lagged the finger until it came in down too.
        let scale = max(abs(across - 1) >= abs(down - 1) ? across : down, 8 / min(frame.width, frame.height))
        // Not resized at all, it stays exactly as it is.
        guard scale != 1 else { return frame }
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        let fixed = TurnedRect(rect: frame, degrees: degrees).corner(corner.opposite)
        let resized = TurnedRect(rect: CGRect(origin: .zero, size: size), degrees: degrees)
        let reach = resized.corner(corner.opposite)
        let centre = CGPoint(x: fixed.x - (reach.x - resized.centre.x), y: fixed.y - (reach.y - resized.centre.y))
        return CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: Snapping

    /// Lines up a frame being dragged with what is around it, as smart guides do: its
    /// edges and centre snap to those of `others` and of `container` when within
    /// `threshold`. Returns the snapped frame and the guides to show for it.
    static func snapped(_ frame: CGRect, to others: [CGRect], in container: CGRect?, threshold: CGFloat) -> (frame: CGRect, guides: [SnapGuide]) {
        let targets = others + (container.map { [$0] } ?? [])
        var result = frame
        var guides: [SnapGuide] = []

        func lines(_ rect: CGRect, _ axis: SnapGuide.Axis) -> [CGFloat] {
            axis == .vertical ? [rect.minX, rect.midX, rect.maxX] : [rect.minY, rect.midY, rect.maxY]
        }

        for axis in [SnapGuide.Axis.vertical, .horizontal] {
            var best: (delta: CGFloat, position: CGFloat)?
            for target in targets {
                for line in lines(target, axis) {
                    for own in lines(frame, axis) {
                        let delta = line - own
                        if abs(delta) <= threshold, abs(delta) < abs(best?.delta ?? .infinity) {
                            best = (delta, line)
                        }
                    }
                }
            }
            guard let best else { continue }
            if axis == .vertical { result.origin.x += best.delta } else { result.origin.y += best.delta }
            // Every target that now shares the line is shown along it.
            let sharing = targets.filter { lines($0, axis).contains { abs($0 - best.position) < 0.5 } }
            let span = sharing.reduce(result) { $0.union($1) }
            guides.append(axis == .vertical
                ? SnapGuide(axis: .vertical, position: best.position, start: span.minY, end: span.maxY)
                : SnapGuide(axis: .horizontal, position: best.position, start: span.minX, end: span.maxX))
        }
        return (result, guides)
    }

    /// Moves a frame's origin onto the nearest grid mark. The grid is laid out in canvas
    /// points, every `spacing` of them, and `placement` turns the frame into canvas points.
    static func snappedToGrid(_ frame: CGRect, spacing: CGFloat, placement: Placement) -> CGRect {
        guard spacing > 0 else { return frame }
        let canvas = placement.canvasRect(for: frame)
        let origin = CGPoint(x: (canvas.minX / spacing).rounded() * spacing, y: (canvas.minY / spacing).rounded() * spacing)
        var result = frame
        result.origin = placement.localPoint(for: origin)
        result.origin.x = (result.origin.x * 10).rounded() / 10
        result.origin.y = (result.origin.y * 10).rounded() / 10
        return result
    }

    /// Where a frame goes when aligned to an edge or the middle of its screen.
    static func aligned(_ frame: CGRect, _ alignment: Alignment, in screen: CGSize) -> CGRect {
        var result = frame
        switch alignment {
        case .left: result.origin.x = 0
        case .centerX: result.origin.x = ((screen.width - frame.width) / 2).rounded()
        case .right: result.origin.x = screen.width - frame.width
        case .top: result.origin.y = 0
        case .centerY: result.origin.y = ((screen.height - frame.height) / 2).rounded()
        case .bottom: result.origin.y = screen.height - frame.height
        }
        return result
    }

    /// Lines several frames up with one another: each takes the edge, or the middle, of
    /// the area they cover together. Sizes are kept, and so is where each frame is the
    /// other way: lining up across leaves each at its own height.
    static func aligned(_ frames: [CGRect], _ alignment: Alignment) -> [CGRect] {
        guard let area = frames.dropFirst().reduce(frames.first, { $0?.union($1) }) else { return frames }
        return frames.map { frame in
            var result = frame
            switch alignment {
            case .left: result.origin.x = area.minX
            case .centerX: result.origin.x = area.midX - frame.width / 2
            case .right: result.origin.x = area.maxX - frame.width
            case .top: result.origin.y = area.minY
            case .centerY: result.origin.y = area.midY - frame.height / 2
            case .bottom: result.origin.y = area.maxY - frame.height
            }
            return result
        }
    }

    /// Spaces three or more frames evenly along a line: the two at the ends stay where
    /// they are and those between are moved so that every gap is the same. The frames
    /// come back in the order they were given.
    static func distributed(_ frames: [CGRect], _ distribution: Distribution) -> [CGRect] {
        guard frames.count >= 3 else { return frames }
        func start(_ frame: CGRect) -> CGFloat { distribution == .horizontal ? frame.minX : frame.minY }
        func length(_ frame: CGRect) -> CGFloat { distribution == .horizontal ? frame.width : frame.height }

        let order = frames.indices.sorted { start(frames[$0]) < start(frames[$1]) }
        guard let first = order.first, let last = order.last else { return frames }
        let span = start(frames[last]) + length(frames[last]) - start(frames[first])
        let gap = (span - frames.map(length).reduce(0, +)) / CGFloat(frames.count - 1)

        var result = frames
        var next = start(frames[first])
        for index in order {
            if distribution == .horizontal { result[index].origin.x = next } else { result[index].origin.y = next }
            next += length(frames[index]) + gap
        }
        return result
    }

    enum Distribution: CaseIterable, Sendable {
        case horizontal, vertical

        var name: String {
            switch self {
            case .horizontal: "Distribute Horizontally"
            case .vertical: "Distribute Vertically"
            }
        }

        var symbol: String {
            switch self {
            case .horizontal: "distribute.horizontal.center"
            case .vertical: "distribute.vertical.center"
            }
        }
    }

    enum Alignment: CaseIterable, Sendable {
        case left, centerX, right, top, centerY, bottom

        var name: String {
            switch self {
            case .left: "Align Left"
            case .centerX: "Align Centres"
            case .right: "Align Right"
            case .top: "Align Top"
            case .centerY: "Align Middles"
            case .bottom: "Align Bottom"
            }
        }

        var symbol: String {
            switch self {
            case .left: "align.horizontal.left"
            case .centerX: "align.horizontal.center"
            case .right: "align.horizontal.right"
            case .top: "align.vertical.top"
            case .centerY: "align.vertical.center"
            case .bottom: "align.vertical.bottom"
            }
        }
    }

    static func isCentered(_ frame: CGRect, in width: CGFloat = DeviceFrame.iPhone.size.width) -> Bool {
        abs(frame.midX - width / 2) <= 1
    }

    private static func snap(_ value: CGFloat, to step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }
}

/// A line something being dragged has snapped to, in its host's points: a vertical line at
/// `position` across, running from `start` to `end` down, or a horizontal one the other way.
struct SnapGuide: Equatable, Sendable {
    enum Axis: Sendable { case vertical, horizontal }
    var axis: Axis
    var position: CGFloat
    var start: CGFloat
    var end: CGFloat
}

/// The gaps between an element and whatever sits next to it on each side: the nearest
/// element in that direction, or the screen edge.
struct SpacingGuides: Equatable, Sendable {
    struct Gap: Equatable, Sendable {
        var start: CGPoint
        var end: CGPoint
        var distance: CGFloat { (abs(end.x - start.x) + abs(end.y - start.y)).rounded() }
    }

    var top: Gap
    var left: Gap
    var bottom: Gap
    var right: Gap
    var isCentered: Bool

    var gaps: [Gap] { [top, left, bottom, right] }

    static func measure(_ element: DesignElement, in screen: DesignScreen) -> SpacingGuides {
        let frame = element.shapeBounds
        let others = screen.elements.filter { $0.id != element.id && !$0.isHidden }.map(\.shapeBounds)
        let beside = others.filter { $0.maxY > frame.minY && $0.minY < frame.maxY }
        let stacked = others.filter { $0.maxX > frame.minX && $0.minX < frame.maxX }

        let above = stacked.filter { $0.maxY <= frame.minY }.map(\.maxY).max() ?? 0
        let below = stacked.filter { $0.minY >= frame.maxY }.map(\.minY).min() ?? screen.size.height
        let before = beside.filter { $0.maxX <= frame.minX }.map(\.maxX).max() ?? 0
        let after = beside.filter { $0.minX >= frame.maxX }.map(\.minX).min() ?? screen.size.width

        return SpacingGuides(
            top: Gap(start: CGPoint(x: frame.midX, y: above), end: CGPoint(x: frame.midX, y: frame.minY)),
            left: Gap(start: CGPoint(x: before, y: frame.midY), end: CGPoint(x: frame.minX, y: frame.midY)),
            bottom: Gap(start: CGPoint(x: frame.midX, y: frame.maxY), end: CGPoint(x: frame.midX, y: below)),
            right: Gap(start: CGPoint(x: frame.maxX, y: frame.midY), end: CGPoint(x: after, y: frame.midY)),
            isCentered: ElementLayout.isCentered(frame, in: screen.size.width)
        )
    }
}

import CoreGraphics

/// Turns rough sketch positions into tidy element frames, and keeps frames tidy while the
/// user moves and resizes them. Frames here are in a screen's logical points.
enum ElementLayout {
    enum Corner: CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// The size an element starts at, on the standard phone.
    static func size(for kind: ElementKind, sketch: CGRect) -> CGSize {
        switch kind {
        case .title: CGSize(width: 228, height: 40)
        case .body: CGSize(width: 297, height: 44)
        case .button: CGSize(width: 353, height: 50)
        case .textField: CGSize(width: 333, height: 48)
        case .divider: CGSize(width: 333, height: 1)
        case .image: CGSize(width: 333, height: snap(min(max(sketch.height, 120), 520), to: 8))
        case .symbol: CGSize(width: 44, height: 44)
        case .text: CGSize(width: 200, height: 24)
        case .stickyNote: CGSize(width: 150, height: 150)
        case .toggle: CGSize(width: 51, height: 31)
        case .checkbox, .radio: CGSize(width: 24, height: 24)
        case .progress: CGSize(width: 333, height: 6)
        case .avatar:
            // As large as it was drawn, within reason.
            CGSize(width: snap(min(max(sketch.width, 40), 160), to: 4), height: snap(min(max(sketch.width, 40), 160), to: 4))
        }
    }

    /// Small elements stay where they were drawn across the screen; the rest are centred.
    static func keepsSketchedPosition(_ kind: ElementKind) -> Bool {
        kind == .toggle || kind == .avatar || kind == .symbol || kind == .checkbox || kind == .radio
    }

    /// Kinds that usually run across the screen, and keep their side margins on other devices.
    static func runsAcross(_ kind: ElementKind) -> Bool {
        kind == .button || kind == .textField || kind == .divider || kind == .image || kind == .progress
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
    static let rhythm: [CGFloat] = [8, 12, 16, 24, 32]

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

        switch kind {
        case .title, .body:
            if kind == .title {
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
        case _ where runsAcross(kind) && kind != .divider:
            let full = frame.width
            let minimum: CGFloat = switch kind {
            case .button: 88
            case .textField: 120
            case .progress: 60
            default: 44
            }
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
        default:
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
        let small = kind == .symbol || kind == .checkbox || kind == .radio
        let minimum = CGSize(width: small ? 12 : 32, height: kind == .divider || kind == .progress ? 1 : small ? 12 : 16)
        var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
        switch corner {
        case .topLeft, .bottomLeft: minX = min(frame.minX + translation.width, maxX - minimum.width)
        case .topRight, .bottomRight: maxX = max(frame.maxX + translation.width, minX + minimum.width)
        }
        if kind != .divider {
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
        guard kind == .avatar || kind == .radio else { return result }
        let side = max(result.width, result.height)
        if corner == .topLeft || corner == .bottomLeft { result.origin.x = result.maxX - side }
        if corner == .topLeft || corner == .topRight { result.origin.y = result.maxY - side }
        result.size = CGSize(width: side, height: side)
        return result
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
        let frame = element.frame
        let others = screen.elements.filter { $0.id != element.id && !$0.isHidden }.map(\.frame)
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

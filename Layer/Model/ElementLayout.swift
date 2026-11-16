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
        }
    }

    /// A new element takes its kind's standard size, sits centred across the screen, and
    /// keeps the height at which it was sketched. Elements that run edge to edge keep
    /// their side margins on wider and narrower devices.
    static func frame(for kind: ElementKind, sketch: CGRect, on device: DeviceFrame = .iPhone) -> CGRect {
        var size = size(for: kind, sketch: sketch)
        if kind == .button || kind == .textField || kind == .divider || kind == .image {
            size.width += device.size.width - DeviceFrame.iPhone.size.width
        }
        let top = device.safeTop + 8
        let bottom = device.size.height - device.safeBottom - 8 - size.height
        let y = min(max(snap(sketch.midY - size.height / 2, to: 4), top), max(top, bottom))
        return CGRect(x: (device.size.width - size.width) / 2, y: y, width: size.width, height: size.height)
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
        let minimum = CGSize(width: kind == .symbol ? 12 : 32, height: kind == .divider ? 1 : kind == .symbol ? 12 : 16)
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

    static func isCentered(_ frame: CGRect, in width: CGFloat = DeviceFrame.iPhone.size.width) -> Bool {
        abs(frame.midX - width / 2) <= 1
    }

    private static func snap(_ value: CGFloat, to step: CGFloat) -> CGFloat {
        (value / step).rounded() * step
    }
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
        let others = screen.elements.filter { $0.id != element.id }.map(\.frame)
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

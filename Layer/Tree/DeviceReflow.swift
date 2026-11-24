import CoreGraphics
import Foundation

/// Where a free screen's things go when the screen changes device (spec §5, plan 5's call 9). Each keeps its placement
/// intent: the one saved with its sketch, else the one its frame reads as on the old device (`PlacementIntent.of`).
/// W and W′ are the old and new widths.
///
/// - leading keeps its x, and so its left inset;
/// - trailing keeps its right inset: x = W′ − (W − maxX) − width;
/// - centred keeps its offset from the middle: x = (W′ − width) / 2 + (midX − W / 2);
/// - proportional scales its x and its width by W′ / W when it is upright and fixed across; a turned or fitting one
///   moves its centre by that ratio and keeps its size;
/// - fixed, and anything locked, stays put, and may overhang.
///
/// y is kept. Anything that isn't fixed is then kept inside the new screen by its turned shape's bounds, the leading
/// and top edges winning when it can't fit. Only the root's own children move: a container carries what it holds.
/// What a rule works out is in whole points, a half point rounded to even, so that a round trip between two widths
/// of different parity (the iPhone's 393 and the iPad's 820) leaves a centred node where it was.
///
/// A device with the same room, its size and safe areas, moves nothing, whatever its margin: a screen saved as a
/// device of its own, or a device renamed or saved again, isn't asking for anything to move.
enum DeviceReflow {
    /// New frames for a free root's children when its screen goes from `old` to `new` (§5, call 9). Unmoved ones aren't listed.
    static func frames(for root: LayerNode, from old: DeviceFrame, to new: DeviceFrame) -> [UUID: CGRect] {
        guard root.resolvedLayout == .free, !hasTheSameRoom(old, new), isLength(old.size.width), isLength(new.size.width),
              isLength(new.size.height)
        else { return [:] }
        var frames: [UUID: CGRect] = [:]
        for child in root.children where !child.isLocked {
            guard let moved = frame(of: child, from: old, to: new), moved != child.frame else { continue }
            frames[child.id] = moved
        }
        return frames
    }

    /// Where `node` goes; nil when it stays put, or its frame isn't one a rule can work from.
    private static func frame(of node: LayerNode, from old: DeviceFrame, to new: DeviceFrame) -> CGRect? {
        let frame = node.frame
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        let width = old.size.width, newWidth = new.size.width
        let degrees = Rotation.normalized(node.rotation ?? 0)
        var moved = frame
        switch node.sketch?.placement ?? .of(frame, screenWidth: width, margin: old.margin) {
        case .fixed:
            return nil
        case .leading:
            break
        case .trailing:
            moved.origin.x = whole(newWidth - (width - frame.maxX) - frame.width)
        case .centered:
            moved.origin.x = whole((newWidth - frame.width) / 2 + (frame.midX - width / 2))
        case .proportional:
            let ratio = newWidth / width
            if degrees == 0, node.width.mode == .fixed {
                moved.origin.x = whole(frame.minX * ratio)
                moved.size.width = whole(frame.width * ratio)
            } else {
                moved.origin.x = whole(frame.midX * ratio - frame.width / 2)
            }
        }
        return kept(moved, turnedBy: degrees, inside: new.size)
    }

    /// `frame` moved so that its shape, turned by `degrees`, lies inside 0…size on each axis, the leading and top
    /// edges winning when it can't fit. A coordinate it moves is a whole number, rounded inwards.
    private static func kept(_ frame: CGRect, turnedBy degrees: Double, inside size: CGSize) -> CGRect {
        let shape = degrees == 0 ? frame : TurnedRect(rect: frame, degrees: degrees).bounds
        // How far the shape's leading and top edges are from the frame's.
        let dx = shape.minX - frame.minX, dy = shape.minY - frame.minY
        var kept = frame
        if shape.maxX > size.width + slack { kept.origin.x = (size.width - shape.width - dx).rounded(.down) }
        if kept.minX + dx < -slack { kept.origin.x = (-dx).rounded(.up) }
        if shape.maxY > size.height + slack { kept.origin.y = (size.height - shape.height - dy).rounded(.down) }
        if kept.minY + dy < -slack { kept.origin.y = (-dy).rounded(.up) }
        return kept
    }

    /// What a turned shape's edges may stray by in floating point and still be inside.
    private static let slack: CGFloat = 0.001

    private static func isLength(_ value: CGFloat) -> Bool { value.isFinite && value > 0 }

    /// A number a rule works out, in whole points: a half rounds to even, so it doesn't creep one way.
    private static func whole(_ value: CGFloat) -> CGFloat { value.rounded(.toNearestOrEven) }

    /// Whether a screen has the same room on both: the same size and safe areas. The margin doesn't count.
    private static func hasTheSameRoom(_ old: DeviceFrame, _ new: DeviceFrame) -> Bool {
        old.size == new.size && old.safeTop == new.safeTop && old.safeBottom == new.safeBottom
            && old.safeLeading == new.safeLeading && old.safeTrailing == new.safeTrailing
    }
}

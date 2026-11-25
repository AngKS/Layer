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
/// y is kept. A node upright and fixed on an axis that reaches across the whole old screen on it, a background or a
/// bleed, reaches across the new one, as far past each edge as it was (plan 5's final review, A5): a full-screen
/// background covers the new screen. A row, column or grid the pass made whose every member is proportional fills the
/// new width as they would loose (A3). Anything that isn't fixed is then kept inside the new screen by its turned
/// shape's bounds, the leading and top edges winning when it can't fit; past an edge only as far as it was already
/// (Task 4's M3), so that a deliberate bleed keeps its overhang. Only the root's own children move, and the members of
/// such a row, column or grid: a container carries what it holds. What a rule works out is in whole points, a half
/// point rounded to even, so that a round trip between two widths of different parity (the iPhone's 393 and the
/// iPad's 820) leaves a centred node where it was.
///
/// A device of the same size moves nothing, whatever its margin or safe areas, since a free root is inset by neither:
/// a screen saved as a device of its own, or a device renamed or saved again, isn't asking for anything to move.
enum DeviceReflow {
    /// New frames for a free root's children, and for the members of a row, column or grid of them the pass made that
    /// scales (A3), when its screen goes from `old` to `new` (§5, call 9). `tokens` are the design's, which that row,
    /// column or grid is fitted with. Unmoved ones aren't listed.
    static func frames(for root: LayerNode, from old: DeviceFrame, to new: DeviceFrame,
                       tokens: DesignTokens = .standard) -> [UUID: CGRect] {
        guard root.resolvedLayout == .free, old.size != new.size, isLength(old.size.width), isLength(old.size.height),
              isLength(new.size.width), isLength(new.size.height)
        else { return [:] }
        var frames: [UUID: CGRect] = [:]
        for child in root.children where !child.isLocked {
            if let scaled = scaled(child, from: old, to: new, tokens: tokens) {
                frames.merge(scaled) { _, scaled in scaled }
                continue
            }
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
        let placement = node.sketch?.placement ?? .of(frame, screenWidth: width, margin: old.margin)
        if placement == .fixed { return nil }
        if degrees == 0, node.width.mode == .fixed, frame.minX <= 0, frame.maxX >= width {
            // Across the whole screen: across the new one, as far past each edge.
            moved.size.width = whole(newWidth + (frame.maxX - width) - frame.minX)
        } else {
            switch placement {
            case .fixed, .leading:
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
        }
        if degrees == 0, node.height.mode == .fixed, frame.minY <= 0, frame.maxY >= old.size.height {
            // Down the whole screen: down the new one, as far past each edge.
            moved.size.height = whole(new.size.height + (frame.maxY - old.size.height) - frame.minY)
        }
        return kept(moved, turnedBy: degrees, inside: new.size, past: overhang(of: frame, turnedBy: degrees, on: old.size))
    }

    /// A row, column or grid the pass made whose every visible member is proportional, by its saved intent or else by
    /// where it is on the old screen (A3): each member upright, unlocked and fixed across scales its width by W′ / W, the
    /// container its x, and the engine fits the container round them, as it will lay it out; it is then kept inside
    /// the new screen. Its frame and each member's that changes; nil for anything else, which moves by its own intent.
    private static func scaled(_ node: LayerNode, from old: DeviceFrame, to new: DeviceFrame,
                               tokens: DesignTokens) -> [UUID: CGRect]? {
        let frame = node.frame
        guard node.kind == .group, node.sketch?.decidedBy == .structure, Rotation.normalized(node.rotation ?? 0) == 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite) else { return nil }
        switch node.resolvedLayout {
        case .stack, .grid: break
        case .free, .overlay: return nil
        }
        let shown = node.children.filter { !$0.isHidden }
        guard !shown.isEmpty, shown.allSatisfy({ member in
            let onScreen = member.frame.offsetBy(dx: frame.minX, dy: frame.minY)
            return (member.sketch?.placement ?? .of(onScreen, screenWidth: old.size.width, margin: old.margin)) == .proportional
        }) else { return nil }
        let ratio = new.size.width / old.size.width
        var frames: [UUID: CGRect] = [:]
        var container = node
        for index in container.children.indices {
            let member = container.children[index]
            guard member.width.mode == .fixed, !member.isLocked, Rotation.normalized(member.rotation ?? 0) == 0,
                  member.frame.width.isFinite else { continue }
            container.children[index].frame.size.width = whole(member.frame.width * ratio)
            if container.children[index].frame != member.frame { frames[member.id] = container.children[index].frame }
        }
        container.frame.origin.x = whole(frame.minX * ratio)
        if container.width.mode == .fixed { container.frame.size.width = whole(frame.width * ratio) }
        // Fitted as the engine will fit it in the free root: its top-left corner kept.
        var scratch = LayerNode(kind: .group)
        scratch.children = [container]
        var diagnostics: [LayoutDiagnostic] = []
        LayoutEngine.layOut(&scratch, previous: nil, measure: .shared, tokens: tokens, diagnostics: &diagnostics)
        let moved = kept(scratch.children[0].frame, turnedBy: 0, inside: new.size,
                         past: overhang(of: frame, turnedBy: 0, on: old.size))
        if moved != frame { frames[node.id] = moved }
        return frames
    }

    /// How far a shape lies past each edge of a screen.
    private struct Overhang {
        var leading: CGFloat = 0, top: CGFloat = 0, trailing: CGFloat = 0, bottom: CGFloat = 0
    }

    /// How far `frame`, turned by `degrees`, lies past each edge of a screen of `size`.
    private static func overhang(of frame: CGRect, turnedBy degrees: Double, on size: CGSize) -> Overhang {
        let shape = degrees == 0 ? frame : TurnedRect(rect: frame, degrees: degrees).bounds
        return Overhang(leading: max(0, -shape.minX), top: max(0, -shape.minY), trailing: max(0, shape.maxX - size.width),
                        bottom: max(0, shape.maxY - size.height))
    }

    /// `frame` moved so that its shape, turned by `degrees`, lies inside 0…size on each axis, or no further past an edge
    /// than `past` allows, the leading and top edges winning when it can't fit. A coordinate it moves is a whole
    /// number, rounded inwards.
    private static func kept(_ frame: CGRect, turnedBy degrees: Double, inside size: CGSize, past: Overhang) -> CGRect {
        let shape = degrees == 0 ? frame : TurnedRect(rect: frame, degrees: degrees).bounds
        // How far the shape's leading and top edges are from the frame's.
        let dx = shape.minX - frame.minX, dy = shape.minY - frame.minY
        let right = size.width + past.trailing, bottom = size.height + past.bottom
        var kept = frame
        if shape.maxX > right + slack { kept.origin.x = (right - shape.width - dx).rounded(.down) }
        if kept.minX + dx < -past.leading - slack { kept.origin.x = (-past.leading - dx).rounded(.up) }
        if shape.maxY > bottom + slack { kept.origin.y = (bottom - shape.height - dy).rounded(.down) }
        if kept.minY + dy < -past.top - slack { kept.origin.y = (-past.top - dy).rounded(.up) }
        return kept
    }

    /// What a turned shape's edges may stray by in floating point and still be inside.
    private static let slack: CGFloat = 0.001

    private static func isLength(_ value: CGFloat) -> Bool { value.isFinite && value > 0 }

    /// A number a rule works out, in whole points: a half rounds to even, so it doesn't creep one way.
    private static func whole(_ value: CGFloat) -> CGFloat { value.rounded(.toNearestOrEven) }
}

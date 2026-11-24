import SwiftUI

/// What a drag in a row, column or grid shows (plan 4, call 3): the thing lifted, as a translucent copy that follows
/// the finger while the thing itself stays where it is, and the insertion line where any one thing dragged would go if
/// it were let go now. In the view's points, so that the line is 2 points across at any zoom. It takes no touches.
///
/// Only this reads the lift as it goes, so that a lift's frames draw nothing else again. The copy is a node view,
/// compared by value: following the finger moves it without drawing it again.
struct LayoutDrag: View {
    @Environment(AppModel.self) private var model
    let drags: CanvasDrags

    /// How far across the insertion line is, in the view's points.
    private static let lineWidth: CGFloat = 2

    var body: some View {
        let viewport = model.viewport
        ZStack(alignment: .topLeading) {
            if let lift = drags.lift, let placed = model.store.placed(lift.ref) {
                let frame = lift.start.offsetBy(dx: lift.translation.width, dy: lift.translation.height)
                let shape = viewport.viewShape(for: TurnedRect(rect: placed.placement.canvasRect(for: frame), degrees: placed.degrees))
                let scale = placed.placement.scale * viewport.scale
                NodeView(node: placed.node, isLaidOut: placed.isLaidOut, tokens: model.store.tree.settings.tokens)
                    .equatable()
                    .frame(width: frame.width, height: frame.height)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: frame.width * scale, height: frame.height * scale, alignment: .topLeading)
                    .rotationEffect(.degrees(shape.degrees))
                    .opacity(0.7)
                    .position(shape.centre)
            }
            if case .insert(_, _, let line)? = drags.dropTarget, !line.rect.isEmpty {
                let shape = viewport.viewShape(for: line)
                // The line runs along its longer side, which the zoom draws to scale, and is two points across.
                let isUpright = shape.rect.height >= shape.rect.width
                Capsule()
                    .fill(Theme.accent.color)
                    .frame(width: isUpright ? Self.lineWidth : shape.rect.width, height: isUpright ? shape.rect.height : Self.lineWidth)
                    .rotationEffect(.degrees(shape.degrees))
                    .position(shape.centre)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

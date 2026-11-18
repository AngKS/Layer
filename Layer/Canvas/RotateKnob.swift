import SwiftUI

/// The knob that turns what is selected: a round handle on a short stem, below the middle
/// of the selection's bottom edge in its own axes, so that it goes round as the selection
/// turns. Dragged, the selection turns about its centre and the knob follows the finger,
/// snapping to the 45s on the way; the angle shows beside it while it turns. A double tap
/// stands the selection upright again.
///
/// Drawn in the view's own points over the whole canvas, as the rest of the selection layer
/// is. It isn't there while the selection is being moved or resized.
struct RotateKnob: View {
    @Environment(AppModel.self) private var model
    /// The turn under way, from the first move of the drag.
    @State private var turn: Turn?
    /// True while the drag is under way. It goes back however the drag finishes, ended or
    /// cancelled, where `onEnded` only hears of the first.
    @GestureState private var isDragging = false

    private struct Turn {
        /// What the selection turns about, in the view: its centre when the drag began.
        var pivot: CGPoint
        /// The finger's direction from the pivot when it last moved, in degrees.
        var angle: Double
        /// How far the finger has gone round since the drag began. Each move adds the short
        /// way round from the last, so it can pass a half turn and go on.
        var total: Double
        /// Whether this drag began the model's turn. One already under way, such as two
        /// fingers twisting, isn't the knob's to change or end.
        var isOwn: Bool
    }

    private static let space = "RotateKnob"

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let knob = model.knobViewPoint, let canvas = model.selectionShape, !model.isAdjusting || model.isTurning {
                let shape = model.viewport.viewShape(for: canvas)
                let half = shape.rect.height / 2
                Path { path in
                    path.move(to: CGPoint(x: shape.centre.x + shape.down.dx * half, y: shape.centre.y + shape.down.dy * half))
                    path.addLine(to: knob)
                }
                .stroke(Theme.accent.color, lineWidth: 1.5)
                .allowsHitTesting(false)

                Circle()
                    .fill(Theme.chrome)
                    .overlay { Circle().strokeBorder(Theme.accent.color, lineWidth: 1.5) }
                    .frame(width: 13, height: 13)
                    .frame(width: AppModel.knobTarget, height: AppModel.knobTarget)
                    .contentShape(Circle())
                    .accessibilityElement()
                    .accessibilityLabel("Rotate")
                    .accessibilityIdentifier("Rotate")
                    .position(knob)
                    .onTapGesture(count: 2) { model.resetSelectionTurn() }
                    .gesture(drag)

                if model.isTurning, let degrees = model.selectionTurn {
                    // Beside the knob, on the side away from the selection's middle, so that
                    // it never covers the selection; to the left when the knob is straight below.
                    let side: CGFloat = knob.x > shape.centre.x + 1 ? 1 : -1
                    readout(degrees)
                        .position(x: knob.x + side * AppModel.knobTarget, y: knob.y)
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: isDragging) { _, isDragging in
            if !isDragging { finish() }
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                if turn == nil {
                    guard let canvas = model.selectionShape else { return }
                    let pivot = model.viewport.viewShape(for: canvas).centre
                    let angle = Self.direction(of: value.startLocation, from: pivot)
                    turn = Turn(pivot: pivot, angle: angle, total: 0, isOwn: model.beginTurn())
                }
                guard var current = turn, current.isOwn else { return }
                let angle = Self.direction(of: value.location, from: current.pivot)
                current.total += Rotation.shortestTurn(from: current.angle, to: angle)
                current.angle = angle
                turn = current
                model.turnSelection(by: current.total, snaps: true)
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        guard let finished = turn else { return }
        turn = nil
        if finished.isOwn { model.endTurn() }
    }

    /// The way from `pivot` to `point`, in degrees clockwise from pointing right.
    private static func direction(of point: CGPoint, from pivot: CGPoint) -> Double {
        atan2(point.y - pivot.y, point.x - pivot.x) * 180 / .pi
    }

    /// The angle in whole degrees, from 0 to 359.
    private func readout(_ degrees: Double) -> some View {
        Text("\(Int(Rotation.normalized(degrees.rounded())))°")
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accent.color, in: .capsule)
            .fixedSize()
            .allowsHitTesting(false)
    }
}

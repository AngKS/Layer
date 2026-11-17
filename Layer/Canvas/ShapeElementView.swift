import SwiftUI

/// A polygon given in unit points (see `ShapeKind.polygon`), stretched over its frame.
struct UnitPolygon: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines(points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            path.closeSubpath()
        }
    }
}

/// A shape element: filled with its colour, or outlined in it.
struct ShapeElementView: View {
    let kind: ShapeKind
    let color: Color
    let isFilled: Bool
    let cornerRadius: CGFloat

    var body: some View {
        switch kind {
        case .rectangle: insettable(Rectangle())
        case .roundedRectangle: insettable(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        case .ellipse: insettable(Ellipse())
        case .capsule: insettable(Capsule())
        default:
            let polygon = UnitPolygon(points: kind.polygon ?? [])
            if isFilled {
                polygon.fill(color)
            } else {
                // Kept inside the frame, as an inset border would be.
                polygon
                    .stroke(color, style: StrokeStyle(lineWidth: ShapeKind.outlineWidth, lineJoin: .round))
                    .padding(ShapeKind.outlineWidth / 2)
            }
        }
    }

    @ViewBuilder
    private func insettable(_ shape: some InsettableShape) -> some View {
        if isFilled {
            shape.fill(color)
        } else {
            shape.strokeBorder(color, lineWidth: ShapeKind.outlineWidth)
        }
    }
}

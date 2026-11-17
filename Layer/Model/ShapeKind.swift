import CoreGraphics

/// What a shape element is drawn as. Shapes stretch to fill their frame, unlike symbols,
/// which keep their proportions, so a rectangle can be any rectangle and an arrow any length.
///
/// The outline of every shape that isn't one of SwiftUI's own is a polygon in unit
/// points, (0, 0) the top-left corner of the frame and (1, 1) the bottom-right. The canvas
/// draws it and the code generator writes it out from the same points, so the two agree.
enum ShapeKind: String, CaseIterable, Codable, Sendable {
    case rectangle, roundedRectangle, ellipse, capsule
    case triangle, diamond, hexagon, star
    case arrowRight, arrowLeft, arrowUp, arrowDown, doubleArrow

    /// How thick an outlined shape's line is, in the element's own points.
    static let outlineWidth: CGFloat = 3

    var name: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .ellipse: "Circle"
        case .capsule: "Capsule"
        case .triangle: "Triangle"
        case .diamond: "Diamond"
        case .hexagon: "Hexagon"
        case .star: "Star"
        case .arrowRight: "Arrow Right"
        case .arrowLeft: "Arrow Left"
        case .arrowUp: "Arrow Up"
        case .arrowDown: "Arrow Down"
        case .doubleArrow: "Double Arrow"
        }
    }

    /// Words that find it in a search, beyond its name.
    var keywords: [String] {
        switch self {
        case .rectangle: ["square", "box", "rect"]
        case .roundedRectangle: ["square", "box", "card", "rounded", "rect"]
        case .ellipse: ["circle", "oval", "round", "dot", "ellipse"]
        case .capsule: ["pill", "lozenge", "rounded"]
        case .triangle: ["play", "pointer", "warning"]
        case .diamond: ["rhombus", "decision", "lozenge"]
        case .hexagon: ["polygon", "honeycomb"]
        case .star: ["favourite", "favorite", "rating"]
        case .arrowRight, .arrowLeft, .arrowUp, .arrowDown: ["arrow", "direction", "pointer", "next", "back"]
        case .doubleArrow: ["arrow", "swap", "both", "exchange"]
        }
    }

    /// The size a new one starts at, in screen points.
    var size: CGSize {
        switch self {
        case .arrowRight, .arrowLeft, .doubleArrow: CGSize(width: 120, height: 60)
        case .arrowUp, .arrowDown: CGSize(width: 60, height: 120)
        case .capsule: CGSize(width: 140, height: 56)
        case .rectangle, .roundedRectangle: CGSize(width: 140, height: 100)
        default: CGSize(width: 100, height: 100)
        }
    }

    /// The outline in unit points, or nil for SwiftUI's own shapes.
    var polygon: [CGPoint]? {
        func points(_ pairs: [(CGFloat, CGFloat)]) -> [CGPoint] { pairs.map { CGPoint(x: $0.0, y: $0.1) } }
        // Pointing right: a shaft a third of the height, a head the last 40% of the length.
        let right = points([(0, 0.33), (0.6, 0.33), (0.6, 0), (1, 0.5), (0.6, 1), (0.6, 0.67), (0, 0.67)])
        switch self {
        case .rectangle, .roundedRectangle, .ellipse, .capsule:
            return nil
        case .triangle:
            return points([(0.5, 0), (1, 1), (0, 1)])
        case .diamond:
            return points([(0.5, 0), (1, 0.5), (0.5, 1), (0, 0.5)])
        case .hexagon:
            return points([(0.25, 0), (0.75, 0), (1, 0.5), (0.75, 1), (0.25, 1), (0, 0.5)])
        case .star:
            return (0..<10).map { index in
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let radius: CGFloat = index.isMultiple(of: 2) ? 0.5 : 0.2
                // Lowered a little, so the star sits in the middle of its frame by eye: its
                // lowest points are short of the bottom edge.
                return CGPoint(x: 0.5 + cos(angle) * radius, y: 0.55 + sin(angle) * radius)
            }
        case .arrowRight:
            return right
        case .arrowLeft:
            return right.map { CGPoint(x: 1 - $0.x, y: $0.y) }
        case .arrowDown:
            return right.map { CGPoint(x: $0.y, y: $0.x) }
        case .arrowUp:
            return right.map { CGPoint(x: $0.y, y: 1 - $0.x) }
        case .doubleArrow:
            return points([(0, 0.5), (0.3, 0), (0.3, 0.33), (0.7, 0.33), (0.7, 0), (1, 0.5), (0.7, 1), (0.7, 0.67), (0.3, 0.67), (0.3, 1)])
        }
    }

    /// The polygon stretched over a frame of `size`.
    func polygon(in size: CGSize) -> [CGPoint]? {
        polygon?.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }
}

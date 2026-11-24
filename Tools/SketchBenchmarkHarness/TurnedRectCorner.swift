import CoreGraphics

// `TurnedRect.corner(_:)`, copied unchanged from Layer/Model/Rotation.swift for ElementLayout.swift, which this
// harness compiles; keep it in step. It isn't in Tools/Shared/TurnedRectStub.swift because the screen harness copies
// every file there and doesn't compile ElementLayout.swift, whose `Corner` it takes.
extension TurnedRect {
    func corner(_ corner: ElementLayout.Corner) -> CGPoint {
        switch corner {
        case .topLeft: corners[0]
        case .topRight: corners[1]
        case .bottomRight: corners[2]
        case .bottomLeft: corners[3]
        }
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct SketchIntentTests {
    @Test func theConventionsAreTheSpecs() {
        typealias C = StructureConventions
        #expect(C.rowCentreTolerance == 6)
        #expect(C.rowEdgeTolerance == 4)
        #expect(C.rowHeightRatio == 2)
        #expect(C.rowLargestGap == 32)
        #expect(C.columnLeast == 3)
        #expect(C.columnEdgeTolerance == 4)
        #expect(C.columnGapVariation == 4)
        #expect(C.gridLeastRows == 2)
        #expect(C.gridLeastColumns == 2)
        #expect(C.gridEdgeTolerance == 4)
        #expect(C.gridCellSizeVariation == 0.2)
        #expect(C.enclosedShare == 0.9)
        #expect(C.automatic == 0.8)
        #expect(C.offered == 0.5)
        #expect(C.furthestAutomaticMove == 8)
        #expect(C.offerLifetime == .seconds(8))
    }

    @Test func placementFollowsTheRulesInOrder() {
        func placement(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> LayerNode.PlacementIntent {
            .of(CGRect(x: x, y: y, width: w, height: h), screenWidth: 393, margin: 20)
        }
        #expect(placement(20, 300, 170, 120) == .leading)
        #expect(placement(203, 300, 170, 120) == .trailing)
        #expect(placement(96, 80, 200, 40) == .centered)
        #expect(placement(30, 700, 330, 50) == .proportional)
        #expect(placement(230, 400, 51, 31) == .fixed)
        #expect(placement(60, 400, 100, 30) == .leading)
    }

    @Test func onAnIPadTheZonesWiden() {
        #expect(LayerNode.PlacementIntent.of(CGRect(x: 100, y: 0, width: 100, height: 50), screenWidth: 820, margin: 32) == .leading)
        #expect(LayerNode.PlacementIntent.of(CGRect(x: 500, y: 300, width: 100, height: 100), screenWidth: 820, margin: 32) == .fixed)
    }

    @Test func anIntentRemembersTheSketch() {
        let bounds = CGRect(x: 39.3, y: 85.2, width: 196.5, height: 42.6)
        let intent = LayerNode.SketchIntent(
            sketched: bounds, on: CGSize(width: 393, height: 852), margin: 20, confidence: 0.73, decidedBy: .model)
        let n = intent.normalizedBounds
        #expect(abs(n.minX - 0.1) < 1e-9 && abs(n.minY - 0.1) < 1e-9)
        #expect(abs(n.width - 0.5) < 1e-9 && abs(n.height - 0.05) < 1e-9)
        #expect(intent.originalBounds == bounds)
        #expect(intent.confidence == 0.73)
        #expect(intent.decidedBy == .model)
        #expect(intent.structureDeclined == false)
    }

    @Test func onTheCanvasThereIsNoScreen() {
        let intent = LayerNode.SketchIntent(
            sketched: CGRect(x: 10, y: 10, width: 400, height: 40), on: nil, margin: 20, confidence: 0.9, decidedBy: .rules)
        #expect(intent.normalizedBounds == .zero)
        #expect(intent.placement == .fixed)
    }

    @Test func whatThePassMayTake() {
        let text = LayerNode(kind: .text)
        #expect(text.isArrangeable)
        var locked = text; locked.isLocked = true
        var hidden = text; hidden.isHidden = true
        var turned = text; turned.rotation = 10
        var declined = text
        declined.sketch = .init(sketched: .zero, on: nil, margin: 20, confidence: 1, decidedBy: .rules)
        declined.sketch?.structureDeclined = true
        #expect(!locked.isArrangeable && !hidden.isArrangeable && !turned.isArrangeable && !declined.isArrangeable)
        #expect(!LayerNode(kind: .drawing).isArrangeable)

        var group = LayerNode(kind: .group)
        #expect(!group.isArrangeable)
        group.sketch = .init(sketched: .zero, on: nil, margin: 20, confidence: 1, decidedBy: .structure)
        #expect(group.isArrangeable)

        var card = LayerNode(kind: .card)
        #expect(!card.isArrangeable)
        card.sketch = .init(sketched: .zero, on: nil, margin: 20, confidence: 0.9, decidedBy: .rules)
        #expect(card.isArrangeable)
    }
}

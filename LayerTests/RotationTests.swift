import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Rotation geometry")
struct RotationGeometryTests {
    private func element() -> DesignElement {
        DesignElement(kind: .button, frame: CGRect(x: 20, y: 40, width: 100, height: 30), text: "Go", tint: Theme.accent)
    }

    @Test func anglesAreKeptBetweenZeroAnd360() {
        #expect(Rotation.normalized(-90) == 270)
        #expect(Rotation.normalized(450) == 90)
        #expect(Rotation.normalized(360) == 0)
        #expect(Rotation.normalized(0) == 0)
    }

    @Test func anAngleOfZeroIsNotSaved() {
        var item = element()
        item.setRotation(360)
        #expect(item.rotation == nil)
        item.setRotation(-30)
        #expect(item.rotation == 330)
    }

    @Test func anAngleSnapsToThe45sWhenClose() {
        #expect(Rotation.snapped(43) == (45, true))
        #expect(Rotation.snapped(40) == (40, false))
        #expect(Rotation.snapped(358) == (0, true))
        #expect(Rotation.snapped(-3) == (0, true))
    }

    @Test func aTurnedBoxHoldsItsMiddleButNotItsEmptyCorners() {
        let shape = TurnedRect(rect: CGRect(x: 0, y: 0, width: 100, height: 20), degrees: 45)
        #expect(shape.contains(CGPoint(x: 50, y: 10)))
        #expect(!shape.contains(CGPoint(x: 2, y: 2)))
    }

    @Test func aQuarterTurnStandsABoxOnItsEnd() {
        let shape = TurnedRect(rect: CGRect(x: 0, y: 0, width: 100, height: 20), degrees: 90)
        let bounds = shape.bounds
        #expect(abs(bounds.minX - 40) < 0.001 && abs(bounds.minY + 40) < 0.001)
        #expect(abs(bounds.width - 20) < 0.001 && abs(bounds.height - 100) < 0.001)
        #expect(abs(shape.down.dx + 1) < 0.001 && abs(shape.down.dy) < 0.001)
    }

    @Test func theBoxRoundTurnedBoxesAtTheirAngleHoldsThemAll() throws {
        let first = TurnedRect(rect: CGRect(x: 0, y: 0, width: 80, height: 30), degrees: 30)
        let second = TurnedRect(rect: CGRect(x: 120, y: 90, width: 50, height: 60), degrees: 30)
        let box = try #require(TurnedRect.enclosing([first, second], at: 30))
        #expect(box.degrees == 30)
        for point in first.corners + second.corners {
            #expect(box.contains(point))
        }
        #expect(TurnedRect.enclosing([], at: 30) == nil)
    }

    @Test func anAngleIsSavedAndReadBackAndAnUprightOneIsNotWritten() throws {
        var turned = element()
        turned.setRotation(30)
        let back = try JSONDecoder().decode(DesignElement.self, from: JSONEncoder().encode(turned))
        #expect(back.rotation == 30)

        let upright = try JSONEncoder().encode(element())
        #expect(!String(decoding: upright, as: UTF8.self).contains("\"rotation\""))
        #expect(try JSONDecoder().decode(DesignElement.self, from: upright).rotation == nil)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import Layer

private func leaf(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.frame = frame
    return node
}

private func leaf(_ frame: CGRect) -> LayerNode { leaf(.text, frame) }

private func container(_ kind: ElementKind, _ layout: LayerNode.Layout?, _ frame: CGRect,
                       _ children: [LayerNode] = []) -> LayerNode {
    var node = LayerNode(kind: kind)
    node.layout = layout
    node.frame = frame
    node.children = children
    return node
}

private let row = LayerNode.Layout.stack(LayerNode.Stack(axis: .horizontal, spacing: 12))
private let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 18))

/// One iPhone screen at the canvas's origin, drawn at its own size, so that its points are the canvas's.
private func design(_ children: [LayerNode], at origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeContent {
    var screen = TreeScreen(name: "Screen", origin: origin, scale: scale, deviceID: nil)
    screen.root.children = children
    var content = TreeContent()
    content.screens = [screen]
    return content
}

private func landing(_ sketch: CGRect, in content: TreeContent, forCard: Bool = false) -> SketchLanding? {
    SketchLanding.of(sketch, in: content, index: TreeIndex(content), forCard: forCard)
}

/// A rect centred on a point.
private func centred(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.000_001) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// Where a reading lands (spec §5, plan 5's call 7): the deepest visible, unlocked container under its centre on the
/// topmost screen there, in that container's own space, at the slot nearest its centre when it lays things out.
@Suite struct SketchLandingTests {
    @Test func aSketchOnAFreeScreenLandsOnItsRoot() throws {
        let content = design([leaf(CGRect(x: 20, y: 100, width: 353, height: 40))])
        let sketch = CGRect(x: 30, y: 300, width: 200, height: 40)

        let landed = try #require(landing(sketch, in: content))

        #expect(landed.screen == content.screens[0].id)
        #expect(landed.parent == content.screens[0].root.id)
        #expect(landed.local == sketch)
        #expect(!landed.isLaidOut)
        #expect(landed.index == nil)
    }

    @Test func itLandsInTheDeepestContainerUnderItsCentre() throws {
        let group = container(.group, nil, CGRect(x: 20, y: 20, width: 200, height: 100))
        let card = container(.card, nil, CGRect(x: 20, y: 100, width: 353, height: 200), [group])
        let content = design([card])

        let landed = try #require(landing(centred(100, 150, 40, 20), in: content))

        #expect(landed.parent == group.id)
        #expect(landed.local == CGRect(x: 40, y: 20, width: 40, height: 20))
        #expect(!landed.isLaidOut)
        #expect(landed.index == nil)
    }

    @Test func aSketchAcrossAnEdgeLandsWhereItsCentreIs() throws {
        let card = container(.card, nil, CGRect(x: 20, y: 100, width: 353, height: 200))
        let content = design([card])

        // Over the card's top edge, its centre just above it.
        let above = try #require(landing(centred(196, 98, 80, 20), in: content))
        #expect(above.parent == content.screens[0].root.id)
        #expect(above.local == centred(196, 98, 80, 20))

        // Over the same edge, its centre just inside.
        let inside = try #require(landing(centred(196, 102, 80, 20), in: content))
        #expect(inside.parent == card.id)
        #expect(inside.local == centred(176, 2, 80, 20))
    }

    @Test func aLockedOrHiddenContainerHandsItOn() throws {
        var lockedGroup = container(.group, nil, CGRect(x: 20, y: 20, width: 200, height: 100))
        lockedGroup.isLocked = true
        let card = container(.card, nil, CGRect(x: 20, y: 100, width: 353, height: 200), [lockedGroup])
        let locked = try #require(landing(centred(100, 150, 40, 20), in: design([card])))
        #expect(locked.parent == card.id)
        #expect(locked.local == CGRect(x: 60, y: 40, width: 40, height: 20))

        var hiddenCard = container(.card, nil, CGRect(x: 20, y: 100, width: 353, height: 200),
                                   [container(.group, nil, CGRect(x: 20, y: 20, width: 200, height: 100))])
        hiddenCard.isHidden = true
        let content = design([hiddenCard])
        let hidden = try #require(landing(centred(100, 150, 40, 20), in: content))
        #expect(hidden.parent == content.screens[0].root.id)
        #expect(hidden.local == centred(100, 150, 40, 20))
    }

    @Test func aTurnedContainerMapsTheCentre() throws {
        var group = container(.group, nil, CGRect(x: 100, y: 100, width: 200, height: 100))
        group.rotation = 90
        let content = design([group])

        let landed = try #require(landing(centred(240, 60, 20, 20), in: content))

        #expect(landed.parent == group.id)
        // The same size, its centre carried into the group's own axes.
        #expect(close(landed.local, CGRect(x: 0, y: 0, width: 20, height: 20)))
    }

    @Test func aRowGivesTheSlotNearestTheCentre() throws {
        let cells = [0, 112, 224].map { leaf(.button, CGRect(x: $0, y: 0, width: 100, height: 44)) }
        let theRow = container(.group, row, CGRect(x: 20, y: 300, width: 324, height: 44), cells)
        let inRow = try #require(landing(centred(190, 322, 40, 30), in: design([theRow])))
        #expect(inRow.parent == theRow.id)
        #expect(inRow.isLaidOut)
        #expect(inRow.index == 2)
        #expect(inRow.local == centred(170, 22, 40, 30))

        // A column by y: the children's middles are at 22, 84 and 146, and the sketch's at 100.
        let stacked = [0, 62, 124].map { leaf(.button, CGRect(x: 0, y: $0, width: 200, height: 44)) }
        let theColumn = container(.group, column, CGRect(x: 20, y: 300, width: 200, height: 168), stacked)
        let inColumn = try #require(landing(centred(100, 400, 60, 30), in: design([theColumn])))
        #expect(inColumn.parent == theColumn.id)
        #expect(inColumn.index == 2)

        // A grid in reading order: the second row, after its first cell.
        let gridCells = [(0, 0), (112, 0), (0, 56), (112, 56)].map {
            leaf(.image, CGRect(x: CGFloat($0.0), y: CGFloat($0.1), width: 100, height: 44))
        }
        let grid = LayerNode.Layout.grid(LayerNode.Grid(columns: 2, columnSpacing: 12, rowSpacing: 12))
        let theGrid = container(.group, grid, CGRect(x: 20, y: 300, width: 212, height: 100), gridCells)
        let inGrid = try #require(landing(centred(80, 370, 20, 20), in: design([theGrid])))
        #expect(inGrid.parent == theGrid.id)
        #expect(inGrid.index == 3)
        let first = try #require(landing(centred(50, 320, 20, 20), in: design([theGrid])))
        #expect(first.index == 0)
    }

    @Test func onlyACentreInsideTheRowGoesIn() throws {
        let cells = [0, 112, 224].map { leaf(.button, CGRect(x: $0, y: 0, width: 100, height: 44)) }
        let theRow = container(.group, row, CGRect(x: 20, y: 300, width: 324, height: 44), cells)
        let content = design([theRow])

        // The row ends at 344; the sketch's centre is 4 pt below it, though it overlaps the row.
        let landed = try #require(landing(centred(190, 348, 40, 30), in: content))

        #expect(landed.parent == content.screens[0].root.id)
        #expect(!landed.isLaidOut)
        #expect(landed.index == nil)
    }

    @Test func offEveryScreenThereIsNoLanding() {
        let content = design([leaf(CGRect(x: 20, y: 100, width: 353, height: 40))])
        #expect(landing(CGRect(x: 2000, y: 2000, width: 60, height: 40), in: content) == nil)
        #expect(landing(CGRect(x: 2000, y: 2000, width: 60, height: 40), in: TreeContent()) == nil)
    }

    @Test func theTopmostScreenUnderItsCentreTakesIt() throws {
        var content = design([])
        var front = TreeScreen(name: "Front", origin: CGPoint(x: 200, y: 0), scale: 0.5, deviceID: nil)
        front.root.children = []
        content.screens.append(front)

        let landed = try #require(landing(CGRect(x: 230, y: 100, width: 40, height: 20), in: content))

        #expect(landed.screen == front.id)
        #expect(landed.parent == front.root.id)
        // In the screen's own points.
        #expect(landed.local == CGRect(x: 60, y: 200, width: 80, height: 40))
    }

    @Test func aCardSkipsWhatItEncloses() throws {
        let group = container(.group, nil, CGRect(x: 20, y: 110, width: 353, height: 100),
                              [leaf(CGRect(x: 0, y: 0, width: 200, height: 40))])
        let content = design([group])
        let sketch = CGRect(x: 10, y: 100, width: 373, height: 140)

        let card = try #require(landing(sketch, in: content, forCard: true))
        #expect(card.parent == content.screens[0].root.id)
        #expect(card.local == sketch)
        // The person's group becomes the card's.
        #expect(SketchLanding.enclosed(by: card.local, in: content.screens[0].root) == [group.id])

        // Anything else drawn there goes into the group.
        let other = try #require(landing(sketch, in: content))
        #expect(other.parent == group.id)
    }

    @Test func whatACardEnclosesIsMostlyInsideAndCanBeTaken() {
        let inside = leaf(CGRect(x: 20, y: 110, width: 100, height: 40))
        let mostly = leaf(CGRect(x: 20, y: 195, width: 100, height: 40))   // 37 of 40 tall inside
        let partly = leaf(CGRect(x: 300, y: 110, width: 100, height: 40))   // 83 of 100 wide inside
        var locked = leaf(CGRect(x: 140, y: 110, width: 100, height: 40))
        locked.isLocked = true
        var hidden = leaf(CGRect(x: 140, y: 160, width: 100, height: 40))
        hidden.isHidden = true
        var turned = leaf(CGRect(x: 250, y: 160, width: 40, height: 40))
        turned.rotation = 30
        let persons = container(.group, nil, CGRect(x: 30, y: 210, width: 60, height: 20),
                                [leaf(CGRect(x: 0, y: 0, width: 60, height: 20))])
        var sketched = container(.card, nil, CGRect(x: 100, y: 210, width: 60, height: 20))
        sketched.sketch = LayerNode.SketchIntent(sketched: sketched.frame, on: CGSize(width: 393, height: 852), margin: 20,
                                                 confidence: 0.95, decidedBy: .rules)
        var declined = leaf(CGRect(x: 170, y: 210, width: 60, height: 20))
        declined.sketch = LayerNode.SketchIntent(sketched: declined.frame, on: CGSize(width: 393, height: 852), margin: 20,
                                                 confidence: 1, decidedBy: .structure)
        declined.sketch?.structureDeclined = true
        let parent = container(.group, nil, CGRect(x: 0, y: 0, width: 393, height: 852),
                               [inside, mostly, partly, locked, hidden, turned, persons, sketched, declined])
        let rect = CGRect(x: 10, y: 100, width: 373, height: 132)

        // What a card drawn there would hold: the person's own group and a thing the structure pass may not take
        // included, but nothing locked, hidden or turned, which stays where it is.
        #expect(SketchLanding.enclosed(by: rect, in: parent) == [inside.id, mostly.id, persons.id, sketched.id, declined.id])
        #expect(SketchLanding.covered(by: rect, in: parent)
            == [inside.id, mostly.id, locked.id, hidden.id, turned.id, persons.id, sketched.id, declined.id])
    }

    @Test func aSketchPastDepth32LandsInItsParent() throws {
        // Free cards one inside the next, the deepest at depth 32 and empty: its child would sit at 33.
        var chain: [LayerNode] = []
        var deepest = container(.card, nil, CGRect(x: 0, y: 0, width: 393, height: 852))
        chain.append(deepest)
        for _ in 1..<32 {
            deepest = container(.card, nil, CGRect(x: 0, y: 0, width: 393, height: 852), [deepest])
            chain.append(deepest)
        }
        let content = design([deepest])
        let index = TreeIndex(content)
        let atThirtyTwo = chain[0], atThirtyOne = chain[1]
        #expect(index[atThirtyTwo.id]?.depth == 32)

        let landed = try #require(landing(CGRect(x: 100, y: 100, width: 40, height: 20), in: content))

        #expect(landed.parent == atThirtyOne.id)
        #expect(index[landed.parent]?.depth == 31)
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct TreeRulesTests {
    // MARK: - Building designs

    private static func node(_ kind: ElementKind, _ frame: CGRect, turned degrees: Double? = nil,
                             children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.rotation = degrees
        node.children = children
        return node
    }

    /// A node as generation makes one: its words, and its kind's starting sizing.
    private static func generated(_ kind: ElementKind, _ words: String = "") -> LayerNode {
        var node = LayerNode(kind: kind)
        node.content.text = words
        (node.width, node.height) = NaturalSize.defaultSizing(for: kind)
        return node
    }

    /// A free group sized to fit, as Group makes one.
    private static func group(_ frame: CGRect, turned degrees: Double? = nil, _ children: [LayerNode]) -> LayerNode {
        var group = node(.group, frame, turned: degrees, children: children)
        group.layout = .free
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        return group
    }

    /// A group that lays its children out, sized to fit.
    private static func laidOut(_ layout: LayerNode.Layout, _ children: [LayerNode]) -> LayerNode {
        var group = node(.group, .zero, children: children)
        group.layout = layout
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        return group
    }

    private static let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill))
    private static let row = LayerNode.Layout.stack(LayerNode.Stack(axis: .horizontal, spacing: 8, alignment: .center))

    private static func screen(device: String? = nil, origin: CGPoint = .zero, scale: CGFloat = 1,
                               layout: LayerNode.Layout? = nil, _ children: [LayerNode]) -> TreeScreen {
        var screen = TreeScreen(name: "Screen", origin: origin, scale: scale, deviceID: device)
        screen.root.layout = layout
        screen.root.children = children
        return screen
    }

    private static func design(screens: [TreeScreen] = [], canvas: [LayerNode] = []) -> TreeContent {
        var content = TreeContent()
        content.screens = screens
        content.canvas = canvas
        return content
    }

    private static func applied(_ content: TreeContent, after previous: TreeContent? = nil) -> TreeContent {
        var content = content
        TreeRules.apply(to: &content, after: previous)
        return content
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private static func containers(in node: LayerNode) -> [UUID] {
        guard node.isContainer else { return [] }
        return [node.id] + node.children.flatMap(containers)
    }

    // MARK: - Structure

    @Test func aDrawingInsideAContainerGoesToTheCanvasWhereItWas() throws {
        // In a turned card on a screen drawn at half size.
        let onScreen = Self.node(.drawing, CGRect(x: 20, y: 30, width: 80, height: 40), turned: 10)
        let body = Self.node(.body, CGRect(x: 16, y: 80, width: 100, height: 20))
        let card = Self.node(.card, CGRect(x: 40, y: 200, width: 200, height: 120), turned: 30, children: [onScreen, body])
        // In a turned card on the canvas drawn at twice its size.
        let onCanvas = Self.node(.drawing, CGRect(x: 10, y: 10, width: 50, height: 50))
        var canvasCard = Self.node(.card, CGRect(x: 300, y: 400, width: 200, height: 200), turned: -20, children: [onCanvas])
        canvasCard.scale = 2
        let before = Self.design(screens: [Self.screen(origin: CGPoint(x: 1000, y: 200), scale: 0.5, [card])],
                                 canvas: [canvasCard])

        let after = Self.applied(before)
        let was = TreeIndex(before), now = TreeIndex(after)
        for (drawing, scale) in [(onScreen, CGFloat(0.5)), (onCanvas, CGFloat(2))] {
            let entry = try #require(now[drawing.id])
            #expect(entry.host == .canvas)
            #expect(entry.depth == 0)
            let lifted = try #require(now.node(drawing.id, in: after))
            // A screen's drawing takes the screen's scale, a canvas node's its top-level node's.
            #expect(lifted.scale == scale)
            #expect(lifted.frame.size == drawing.frame.size)
            let old = try #require(was.canvasShape(of: drawing.id, in: before))
            let new = try #require(now.canvasShape(of: drawing.id, in: after))
            #expect(Self.distance(old.centre, new.centre) < 0.001)
            #expect(abs(old.rect.width - new.rect.width) < 0.001 && abs(old.rect.height - new.rect.height) < 0.001)
            #expect(abs(old.degrees - new.degrees) < 0.001)
        }
        // The cards keep everything else, where it was.
        #expect(after.screens[0].root.children.map(\.id) == [card.id])
        #expect(after.screens[0].root.children[0].children == [body])
        #expect(after.canvas.map(\.id) == [canvasCard.id, onScreen.id, onCanvas.id])
        #expect(after.canvas[0].children.isEmpty)
    }

    @Test func aStickyNoteOnAScreenGoesToTheCanvas() throws {
        let note = Self.node(.stickyNote, CGRect(x: 20, y: 40, width: 150, height: 150))
        let button = Self.node(.button, CGRect(x: 20, y: 700, width: 353, height: 50))
        // One on the canvas stays, even inside a group there.
        let staying = Self.node(.stickyNote, CGRect(x: 0, y: 0, width: 150, height: 150))
        let shape = Self.node(.shape, CGRect(x: 200, y: 0, width: 100, height: 100))
        let canvasGroup = Self.group(CGRect(x: 0, y: 0, width: 300, height: 150), [staying, shape])
        let before = Self.design(screens: [Self.screen(origin: CGPoint(x: 1000, y: 0), scale: 0.5, [note, button])],
                                 canvas: [canvasGroup])

        let after = Self.applied(before)
        #expect(after.screens[0].root.children == [button])
        let lifted = try #require(after.canvas.first { $0.id == note.id })
        // In the canvas's points, with the screen's scale: the same size in its own points.
        #expect(lifted.scale == 0.5)
        #expect(lifted.frame == CGRect(x: 2020, y: 40, width: 150, height: 150))
        #expect(TreeIndex(after).canvasShape(of: note.id, in: after)?.rect == CGRect(x: 1010, y: 20, width: 75, height: 75))
        #expect(after.canvas.first?.children.map(\.id) == [staying.id, shape.id])
    }

    @Test func anEmptyFreeGroupGoesButEmptyLaidOutGroupsAndCardsStay() {
        let emptyGroup = Self.group(CGRect(x: 20, y: 100, width: 50, height: 50), [])
        // Left empty once the group inside it has gone, so it goes too.
        let holdingAnEmptyGroup = Self.group(CGRect(x: 20, y: 200, width: 50, height: 50),
                                             [Self.group(CGRect(x: 0, y: 0, width: 10, height: 10), [])])
        // A group that lays its children out stays with none, as a card does (Ruling: empty
        // laid-out groups), even once an empty free group inside it has gone.
        let emptyColumn = Self.laidOut(Self.column, [])
        let emptyRow = Self.laidOut(Self.row, [Self.group(CGRect(x: 0, y: 0, width: 10, height: 10), [])])
        let emptyGrid = Self.laidOut(.grid(LayerNode.Grid(columns: 2)), [])
        let emptyOverlay = Self.laidOut(.overlay(LayerNode.Alignment()), [])
        let emptyCard = Self.node(.card, CGRect(x: 20, y: 300, width: 200, height: 100))
        let button = Self.node(.button, CGRect(x: 20, y: 700, width: 353, height: 50))
        let onCanvasGroup = Self.group(CGRect(x: 0, y: 0, width: 50, height: 50), [])
        let onCanvasCard = Self.node(.card, CGRect(x: 100, y: 0, width: 50, height: 50))
        var onCanvasRow = Self.laidOut(Self.row, [])
        onCanvasRow.frame.origin = CGPoint(x: 200, y: 0)
        let emptyScreen = Self.screen([])
        let before = Self.design(
            screens: [Self.screen([emptyGroup, emptyColumn, emptyRow, emptyGrid, emptyOverlay, holdingAnEmptyGroup,
                                   emptyCard, button]), emptyScreen],
            canvas: [onCanvasGroup, onCanvasCard, onCanvasRow])

        let after = Self.applied(before)
        #expect(after.screens[0].root.children.map(\.id)
            == [emptyColumn.id, emptyRow.id, emptyGrid.id, emptyOverlay.id, emptyCard.id, button.id])
        #expect(after.screens[0].root.children[1].children.isEmpty)
        #expect(after.canvas.map(\.id) == [onCanvasCard.id, onCanvasRow.id])
        // A screen's root is never taken away, however empty.
        #expect(after.screens[1].root.id == emptyScreen.root.id)
        // Applying again changes nothing.
        #expect(Self.applied(after, after: after) == after)
    }

    @Test func aDissolvedGroupsAngleIsKeptAsAnElementKeepsIt() {
        let child = Self.node(.shape, CGRect(x: 0, y: 0, width: 40, height: 40), turned: 20)
        let turned = Self.group(CGRect(x: 100, y: 100, width: 40, height: 40), turned: 350, [child])
        let upright = Self.node(.shape, CGRect(x: 0, y: 0, width: 40, height: 40), turned: 45)
        let undone = Self.group(CGRect(x: 100, y: 300, width: 40, height: 40), turned: -45, [upright])
        let after = Self.applied(Self.design(screens: [Self.screen([turned, undone])]))
        let children = after.screens[0].root.children
        #expect(children.map(\.id) == [child.id, upright.id])
        // From 0 up to 360, and nothing when upright, as `Rotation.kept` keeps an element's angle.
        #expect(children[0].rotation.map { abs($0 - 10) < 0.000_1 } == true, "\(String(describing: children[0].rotation))")
        #expect(children[1].rotation == nil)
    }

    @Test func aFreeGroupOfOneDissolvesWithoutMovingAndHandsDownLockAndHide() throws {
        let child = Self.node(.button, CGRect(x: 10, y: 20, width: 120, height: 50), turned: 10)
        var turned = Self.group(CGRect(x: 60, y: 100, width: 200, height: 120), turned: 45, [child])
        turned.isLocked = true
        let hiddenChild = Self.node(.body, CGRect(x: 0, y: 0, width: 100, height: 20))
        var hidden = Self.group(CGRect(x: 40, y: 500, width: 100, height: 20), [hiddenChild])
        hidden.isHidden = true
        let before = Self.design(screens: [Self.screen([turned, hidden])])

        let after = Self.applied(before)
        let root = after.screens[0].root
        #expect(root.children.map(\.id) == [child.id, hiddenChild.id])
        let was = try #require(TreeIndex(before)[child.id]), now = try #require(TreeIndex(after)[child.id])
        #expect(Self.distance(was.hostShape.centre, now.hostShape.centre) < 0.001)
        #expect(root.children[0].frame.size == child.frame.size)
        #expect(root.children[0].rotation == 55)
        #expect(root.children[0].isLocked)
        #expect(!root.children[0].isHidden)
        #expect(root.children[1].frame == CGRect(x: 40, y: 500, width: 100, height: 20))
        #expect(root.children[1].isHidden)
        #expect(!root.children[1].isLocked)

        // A group of one inside another: both go. On the canvas's top level, the child takes
        // the group's scale with its place.
        let shape = Self.node(.shape, CGRect(x: 5, y: 5, width: 40, height: 40))
        var outer = Self.group(CGRect(x: 100, y: 100, width: 60, height: 60), turned: 90,
                               [Self.group(CGRect(x: 10, y: 10, width: 50, height: 50), [shape])])
        outer.scale = 0.5
        let canvasBefore = Self.design(canvas: [outer])
        let canvasAfter = Self.applied(canvasBefore)
        #expect(canvasAfter.canvas.map(\.id) == [shape.id])
        #expect(canvasAfter.canvas[0].scale == 0.5)
        #expect(canvasAfter.canvas[0].rotation == 90)
        let old = try #require(TreeIndex(canvasBefore).canvasShape(of: shape.id, in: canvasBefore))
        let new = try #require(TreeIndex(canvasAfter).canvasShape(of: shape.id, in: canvasAfter))
        #expect(Self.distance(old.centre, new.centre) < 0.001)
    }

    @Test func aRowOfOneStays() {
        let kept: [LayerNode] = [
            Self.laidOut(Self.row, [Self.generated(.text, "Row")]),
            Self.laidOut(Self.column, [Self.generated(.text, "Column")]),
            Self.laidOut(.grid(LayerNode.Grid(columns: 2)), [Self.generated(.text, "Grid")]),
            Self.laidOut(.overlay(LayerNode.Alignment()), [Self.generated(.text, "Overlay")]),
            Self.node(.card, CGRect(x: 20, y: 400, width: 200, height: 100),
                      children: [Self.node(.body, CGRect(x: 16, y: 16, width: 100, height: 20))]),
        ]
        // Beside them, a free group of one dissolves.
        let alone = Self.node(.shape, CGRect(x: 0, y: 0, width: 40, height: 40))
        let freeGroup = Self.group(CGRect(x: 20, y: 600, width: 40, height: 40), [alone])
        let after = Self.applied(Self.design(screens: [Self.screen(kept + [freeGroup])]))

        let children = after.screens[0].root.children
        #expect(children.map(\.id) == kept.map(\.id) + [alone.id])
        #expect(children.prefix(kept.count).allSatisfy { $0.children.count == 1 })
    }

    @Test func whatThisBuildCantReadKeepsItsPlace() {
        let unread = JSONValue.object(["kind": .string("hologram")])
        // A card holding a drawing, something from a newer Layer, and a text.
        let drawing = Self.node(.drawing, CGRect(x: 0, y: 0, width: 40, height: 40))
        let body = Self.node(.body, CGRect(x: 16, y: 60, width: 100, height: 20))
        var card = Self.node(.card, CGRect(x: 20, y: 100, width: 200, height: 100), children: [drawing, body])
        card.unreadChildren = [LayerNode.UnreadChild(index: 1, raw: unread)]
        // A group holding nothing it can read isn't empty, and one holding one thing it can read
        // and one it can't isn't a group of one.
        var unreadOnly = Self.group(CGRect(x: 20, y: 300, width: 50, height: 50), [])
        unreadOnly.unreadChildren = [LayerNode.UnreadChild(index: 0, raw: unread)]
        var oneOfEach = Self.group(CGRect(x: 20, y: 400, width: 50, height: 50),
                                   [Self.node(.shape, CGRect(x: 0, y: 0, width: 50, height: 50))])
        oneOfEach.unreadChildren = [LayerNode.UnreadChild(index: 1, raw: unread)]

        let after = Self.applied(Self.design(screens: [Self.screen([card, unreadOnly, oneOfEach])]))
        let children = after.screens[0].root.children
        #expect(children.map(\.id) == [card.id, unreadOnly.id, oneOfEach.id])
        // With the drawing gone, what it can't read comes first, before the text, as it did.
        #expect(children[0].children == [body])
        #expect(children[0].unreadChildren == [LayerNode.UnreadChild(index: 0, raw: unread)])
        #expect(children[1].unreadChildren == unreadOnly.unreadChildren)
        #expect(children[2].children.count == 1 && children[2].unreadChildren == oneOfEach.unreadChildren)
    }

    @Test func aScreensRootIsKeptToItsDevice() {
        var screen = Self.screen(device: "ipad", [Self.node(.button, CGRect(x: 20, y: 700, width: 300, height: 50))])
        screen.root.kind = .card
        screen.root.frame = CGRect(x: 10, y: 20, width: 300, height: 300)
        screen.root.width = LayerNode.Sizing(.fit)
        screen.root.height = LayerNode.Sizing(.fill(weight: 1))
        screen.root.rotation = 30
        screen.root.padding = LayerNode.Padding(all: 12)
        let after = Self.applied(Self.design(screens: [screen]))

        let root = after.screens[0].root
        #expect(root.id == screen.root.id)
        #expect(root.kind == .group)
        #expect(root.frame == CGRect(x: 0, y: 0, width: 820, height: 1180))
        #expect(root.width == LayerNode.Sizing(.fixed) && root.height == LayerNode.Sizing(.fixed))
        #expect(root.rotation == nil)
        // A free root leaves its children where they were put, so nothing insets it.
        #expect(root.padding == LayerNode.Padding())
        #expect(root.children == screen.root.children)

        // Given another device, it takes that one's size.
        var moved = after
        moved.screens[0].deviceID = "iphone"
        let again = Self.applied(moved, after: after)
        #expect(again.screens[0].root.frame == CGRect(x: 0, y: 0, width: 393, height: 852))
    }

    @Test func aColumnRootIsInsetBySafeAreasAndMargin() throws {
        #expect(TreeRules.margin(for: .iPhone) == 20)
        #expect(TreeRules.margin(for: .named("ipad")) == 32)
        #expect(TreeRules.margin(for: .named("macbook-air")) == 48)

        let phone = DeviceFrame.iPhone
        let title = Self.generated(.title, "Settings")
        let after = Self.applied(Self.design(screens: [
            Self.screen(layout: Self.column, [title, Self.generated(.body, "Choose what Layer shows you.")]),
        ]))
        let root = after.screens[0].root
        #expect(root.padding == LayerNode.Padding(top: phone.safeTop + 20, leading: 20,
                                                  bottom: phone.safeBottom + 20, trailing: 20))
        let first = try #require(root.children.first)
        #expect(first.id == title.id)
        #expect(first.frame.minY == phone.safeTop + 20)
        #expect(first.frame.minX == 20)
        #expect(first.frame.maxX == phone.size.width - 20)

        // On a desktop, the column is at most 1080 wide, in the middle.
        let desktop = DeviceFrame.named("macbook-air")
        let wide = Self.applied(Self.design(screens: [
            Self.screen(device: desktop.id, layout: Self.column, [Self.generated(.body, "A paragraph as wide as it is let be.")]),
        ]))
        let paragraph = try #require(wide.screens[0].root.children.first).frame
        #expect(paragraph.width <= 1080)
        #expect(paragraph.width > desktop.size.width / 2)
        #expect(abs(paragraph.minX - (desktop.size.width - paragraph.maxX)) <= 0.5)
        #expect(paragraph.minY == desktop.safeTop + 48)
    }

    // MARK: - Layout

    /// A column screen of `rows` rows, each of a text, a body, a toggle and a divider.
    private static func listScreen(rows: Int) -> TreeScreen {
        let items = (0..<rows).map { index in
            var item = laidOut(row, [generated(.text, "Label \(index)"), generated(.body, "What setting \(index) does"),
                                     generated(.toggle), generated(.divider)])
            item.width = LayerNode.Sizing(.fill(weight: 1))
            return item
        }
        return screen(layout: column, items)
    }

    @Test func onlyScreensThatChangedAreLaidOut() throws {
        let first = Self.applied(Self.design(screens: [Self.listScreen(rows: 3), Self.listScreen(rows: 3)]))
        let a = first.screens[0].root, b = first.screens[1].root
        // Counted for each container, since suites that run alongside lay out containers of their own.
        let ids = Self.containers(in: a) + Self.containers(in: b)
        #expect(ids.count == 8)
        let before = ids.map(LayoutEngine.timesLaidOut)
        let total = LayoutEngine.containersLaidOut

        var edited = first
        edited.screens[0].root.children[1].children[0].content.text = "The second label"
        let after = Self.applied(edited, after: first)
        let laid = zip(ids.map(LayoutEngine.timesLaidOut), before).map(-)
        // A's root and its second row; A's other rows and all of B are left as they were.
        #expect(laid == [1, 0, 1, 0, 0, 0, 0, 0])
        #expect(LayoutEngine.containersLaidOut - total >= 2)
        #expect(after.screens[1] == first.screens[1])
        // What is left alone is what laying it all out again would give.
        #expect(after == Self.applied(edited))
    }

    @Test func aFittingCanvasRowTakesItsContentsSize() {
        func fittingRow(turned degrees: Double? = nil) -> LayerNode {
            var row = Self.node(.group, CGRect(x: 100, y: 100, width: 999, height: 999), turned: degrees,
                                children: [Self.node(.shape, CGRect(x: 0, y: 0, width: 50, height: 20)),
                                           Self.node(.shape, CGRect(x: 0, y: 0, width: 50, height: 20))])
            row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 10))
            row.width = LayerNode.Sizing(.fit)
            row.height = LayerNode.Sizing(.fit)
            return row
        }
        let once = Self.applied(Self.design(canvas: [fittingRow()]))
        #expect(once.canvas[0].frame == CGRect(x: 100, y: 100, width: 110, height: 20))
        #expect(once.canvas[0].children.map(\.frame)
            == [CGRect(x: 0, y: 0, width: 50, height: 20), CGRect(x: 60, y: 0, width: 50, height: 20)])
        #expect(Self.applied(once, after: once) == once)
        #expect(Self.applied(once) == once)

        // Turned, it keeps its top-left corner where it was, as the same row does in a free screen.
        let turned = fittingRow(turned: 30)
        let onCanvas = Self.applied(Self.design(canvas: [turned]))
        let onScreen = Self.applied(Self.design(screens: [Self.screen([turned])]))
        #expect(onCanvas.canvas[0].frame.size == CGSize(width: 110, height: 20))
        #expect(onCanvas.canvas[0].frame == onScreen.screens[0].root.children[0].frame)
    }

    /// A screen in a column, a free one turned and scaled, and canvas containers, each with
    /// something the rules change.
    private static func messyDesign() -> TreeContent {
        var card = node(.card, .zero, children: [generated(.body, "Inside a card"),
                                                 node(.drawing, CGRect(x: 0, y: 0, width: 30, height: 30))])
        card.layout = column
        card.padding = LayerNode.Padding(all: 16)
        (card.width, card.height) = NaturalSize.defaultSizing(for: .card)
        var listRow = laidOut(row, [generated(.text, "Wi-Fi"), generated(.toggle)])
        listRow.width = LayerNode.Sizing(.fill(weight: 1))
        let columnScreen = screen(layout: column, [
            generated(.title, "Settings"), listRow, card,
            group(CGRect(x: 0, y: 0, width: 10, height: 10), [generated(.text, "Alone in a group")]),
            group(CGRect(x: 0, y: 0, width: 10, height: 10), []),
        ])
        let freeScreen = screen(device: "ipad", origin: CGPoint(x: 600, y: 0), scale: 0.5, [
            node(.stickyNote, CGRect(x: 40, y: 40, width: 150, height: 150)),
            group(CGRect(x: 100, y: 300, width: 10, height: 10), turned: 20,
                  [node(.shape, CGRect(x: 0, y: 0, width: 60, height: 40)), node(.shape, CGRect(x: 80, y: 20, width: 40, height: 40))]),
            laidOut(row, [node(.shape, CGRect(x: 0, y: 0, width: 50, height: 30)), node(.shape, CGRect(x: 0, y: 0, width: 60, height: 30))]),
        ])
        var canvasGroup = group(CGRect(x: 2000, y: 0, width: 10, height: 10),
                                [node(.shape, CGRect(x: 0, y: 0, width: 50, height: 50)),
                                 node(.drawing, CGRect(x: 60, y: 0, width: 50, height: 50))])
        canvasGroup.scale = 0.5
        var canvasRow = node(.group, CGRect(x: 2000, y: 400, width: 300, height: 44),
                             children: [generated(.text, "One"), generated(.text, "Two")])
        canvasRow.layout = row
        return design(screens: [columnScreen, freeScreen], canvas: [canvasGroup, canvasRow])
    }

    @Test func applyingTwiceChangesNothing() {
        let messy = Self.messyDesign()
        let once = Self.applied(messy)
        // The rules had work to do.
        #expect(once != messy)
        // Two drawings and a sticky note have come to the canvas.
        #expect(once.canvas.count == 5)
        // Once more, after itself or from nothing, changes nothing.
        #expect(Self.applied(once, after: once) == once)
        #expect(Self.applied(once) == once)
    }

    @Test func oneEditOnAHundredNodeScreenIsQuick() {
        var current = Self.applied(Self.design(screens: [Self.listScreen(rows: 25)]))
        #expect(current.screens[0].root.children.reduce(0) { $0 + $1.children.count } == 100)
        let edited = current.screens[0].root.children[12].id
        let laidOutBefore = LayoutEngine.timesLaidOut(edited)
        var times: [Duration] = []
        for edit in 0..<50 {
            var next = current
            next.screens[0].root.children[12].children[0].content.text = "Label edited \(edit) times"
            let start = ContinuousClock.now
            TreeRules.apply(to: &next, after: current)
            times.append(ContinuousClock.now - start)
            current = next
        }
        let sorted = times.sorted()
        let p50 = sorted[sorted.count / 2], p95 = sorted[Int((Double(sorted.count) * 0.95).rounded(.up)) - 1]
        func milliseconds(_ duration: Duration) -> String {
            String(format: "%.3f", Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1e3)
        }
        print("TreeRules, one text edit on a screen of 100 nodes in 25 rows: p50 \(milliseconds(p50)) ms, p95 \(milliseconds(p95)) ms")
        print("BENCH rules edit p50=\(milliseconds(p50)) p95=\(milliseconds(p95))")
        // Each edit was laid out: the row it is in, every time.
        #expect(LayoutEngine.timesLaidOut(edited) - laidOutBefore == 50)
        #expect(p95 < .milliseconds(16))
    }

    // MARK: - A change to a design that follows the rules

    /// The changes `lookingOnlyAtWhatChangedGivesWhatLookingAtEverythingGives` makes to `messyDesign` once it follows
    /// the rules, each for the structure passes or the layout to find something to do, or nothing.
    private static func changes() -> [(String, (inout TreeContent) -> Void)] { [
        ("a text edited on a column screen", { $0.screens[0].root.children[0].content.text += " and more words than before" }),
        ("a drawing put on a free screen", { $0.screens[1].root.children.append(node(.drawing, CGRect(x: 10, y: 10, width: 40, height: 40))) }),
        ("a sticky note put in a row", { $0.screens[0].root.children[1].children.append(node(.stickyNote, CGRect(x: 0, y: 0, width: 150, height: 150))) }),
        ("a free group of one put on a screen", {
            $0.screens[1].root.children.append(group(CGRect(x: 50, y: 500, width: 10, height: 10), [node(.shape, CGRect(x: 0, y: 0, width: 30, height: 30))]))
        }),
        ("an empty group put on the canvas", { $0.canvas.append(group(CGRect(x: 3000, y: 0, width: 10, height: 10), [])) }),
        ("a drawing put in a canvas row", { $0.canvas[1].children.append(node(.drawing, CGRect(x: 0, y: 0, width: 20, height: 20))) }),
        ("a screen's device changed", { $0.screens[1].deviceID = nil }),
        ("a screen added holding a sticky note", {
            $0.screens.append(screen(origin: CGPoint(x: 1500, y: 0), [node(.stickyNote, CGRect(x: 0, y: 0, width: 150, height: 150)),
                                                                       generated(.text, "Beside it")]))
        }),
        ("a look changed", { $0.screens[0].root.children[1].children[1].style.tint = RGBColor(hex: 0xFF3B30) }),
        ("a container hidden", { $0.screens[0].root.children[1].isHidden = true }),
        ("a node locked and named", {
            $0.screens[1].root.children[0].isLocked = true
            $0.screens[1].root.children[0].name = "Named"
        }),
        ("the title's size changed", { $0.settings.tokens.textSizes.title += 4 }),
        ("the body's size changed", { $0.settings.tokens.textSizes.body += 2 }),
        ("the card's radius changed", { $0.settings.tokens.card.radius += 4 }),
        ("the rhythm changed", { $0.settings.tokens.rhythm = [4, 8, 16] }),
        ("a canvas node moved", { $0.canvas[0].frame.origin.x += 10 }),
        ("a canvas row restyled", { $0.canvas[1].children[0].style.textColor = RGBColor(hex: 0x34C759) }),
        ("a screen taken away", { $0.screens.removeFirst() }),
        ("the canvas reordered", { $0.canvas.reverse() }),
        ("nothing", { _ in }),
    ] }

    /// For a change to a design that follows every rule, laid out in full, looking only at what changed
    /// (`apply(to:after:kept:)`, as the store applies the rules) gives what looking at everything gives.
    @Test func lookingOnlyAtWhatChangedGivesWhatLookingAtEverythingGives() {
        let kept = Self.applied(Self.messyDesign())
        #expect(Self.applied(kept) == kept, "the design follows the rules")
        for (what, change) in Self.changes() {
            var edited = kept
            change(&edited)
            var everything = edited, onlyWhatChanged = edited
            TreeRules.apply(to: &everything, after: kept)
            TreeRules.apply(to: &onlyWhatChanged, after: kept, kept: kept)
            #expect(onlyWhatChanged == everything, "after \(what)")
            #expect(Self.applied(onlyWhatChanged) == onlyWhatChanged, "after \(what), the design still follows the rules in full")
        }
    }

    /// A store whose design follows the rules keeps it so through a run of changes, undo and redo among them, each
    /// looking only at what it changed: laying the whole design out again changes nothing after any of them.
    @MainActor
    @Test func aStoresDesignFollowsTheRulesInFullAfterEveryChange() throws {
        let store = DesignStore(content: Self.applied(Self.messyDesign()))
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let column = store.tree.screens[0].root, free = store.tree.screens[1].root
        let listRow = column.children[1], card = column.children[2]
        var checked = 0
        func check(_ what: String) {
            #expect(Self.applied(store.tree) == store.tree, "after \(what)")
            checked += 1
        }
        store.update(listRow.children[0].id) { $0.content.text = "A much longer label, wrapping now" }
        check("a text in a row")
        store.update(card.id) { $0.padding = LayerNode.Padding(all: 24) }
        check("a card's padding")
        store.update(listRow.children[1].id) { $0.style.tint = RGBColor(hex: 0xFF3B30) }
        check("a look")
        store.update(free.children[1].id) { $0.rotation = 45 }
        check("a row turned")
        #expect(store.add(Self.generated(.body, "Added"), to: .node(card.id), at: 0))
        check("an add to a card")
        store.delete(nodes: [listRow.children[1].id])
        check("a delete from a row")
        store.updateCanvas { $0.tokens.textSizes.title = 34 }
        check("the title's size")
        store.updateCanvas { $0.tokens.card.radius = 4 }
        check("the card's radius")
        store.update(card.id) { $0.isHidden = true }
        check("a card hidden")
        undo.undo()
        check("an undo")
        undo.undo()
        check("another undo")
        undo.redo()
        check("a redo")
        #expect(checked == 12)
    }

    #if DEBUG
    /// A look changed through the store, a fill, a radius or a shadow, lays nothing out: the screen it is on, laid out
    /// alike, has the frames the engine would give it (sweep item 4). Counted for each container, since suites that
    /// run alongside lay out containers of their own.
    @MainActor
    @Test func aLookChangedThroughTheStoreLaysNothingOut() throws {
        let store = DesignStore(content: Self.applied(Self.design(screens: [Self.listScreen(rows: 3), Self.listScreen(rows: 3)])))
        let containers = store.tree.screens.flatMap { Self.containers(in: $0.root) }
        #expect(containers.count == 8)
        let toggle = store.tree.screens[0].root.children[1].children[2].id
        let before = containers.map(LayoutEngine.timesLaidOut)

        store.update(toggle) { $0.style.tint = RGBColor(hex: 0xFF3B30) }
        store.update(toggle) { $0.style.cornerRadius = 6 }
        store.update(toggle) { $0.style.hasShadow = true }

        #expect(store.node(toggle)?.style.hasShadow == true)
        #expect(zip(containers.map(LayoutEngine.timesLaidOut), before).map(-) == containers.map { _ in 0 })
    }

    /// A design token a scrub changes lays out only what it measures (sweep item 5): a card's radius or the rhythm lays
    /// nothing out, and the title's size only the screen that holds a title, from scratch as before. Counted for each
    /// container.
    @MainActor
    @Test func aTokenChangedLaysOutOnlyWhatItMeasures() throws {
        let titled = Self.screen(origin: CGPoint(x: 600, y: 0), layout: Self.column, [
            Self.generated(.title, "Welcome"),
            Self.laidOut(Self.row, [Self.node(.shape, CGRect(x: 0, y: 0, width: 40, height: 40)),
                                    Self.node(.shape, CGRect(x: 0, y: 0, width: 40, height: 40))]),
        ])
        let store = DesignStore(content: Self.applied(Self.design(screens: [Self.listScreen(rows: 2), titled])))
        let list = Self.containers(in: store.tree.screens[0].root), withTitle = Self.containers(in: store.tree.screens[1].root)
        #expect((list.count, withTitle.count) == (3, 2))
        var before = (list + withTitle).map(LayoutEngine.timesLaidOut)
        func laid() -> [Int] { zip((list + withTitle).map(LayoutEngine.timesLaidOut), before).map(-) }

        store.updateCanvas { $0.tokens.card.radius = 4 }
        store.updateCanvas { $0.tokens.rhythm = [4, 8, 16] }
        #expect(laid() == [0, 0, 0, 0, 0])

        before = (list + withTitle).map(LayoutEngine.timesLaidOut)
        store.updateCanvas { $0.tokens.textSizes.title = 34 }
        #expect(laid() == [0, 0, 0, 1, 1])
        #expect(Self.applied(store.tree) == store.tree, "laid out as laying it all out again would")
    }
    #endif
}

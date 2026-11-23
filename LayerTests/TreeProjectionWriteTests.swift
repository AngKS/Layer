import CoreGraphics
import Foundation
import Testing
@testable import Layer

// PROJECTION: deleted in plan 6
/// Flat writes turned back into tree edits: a field or geometry update goes to the one node, and
/// a structural edit lowers the host, runs today's list operation on it and lifts it back, with
/// pointers the tree can't hold yet kept until the change ends. Leaves are fixed unless a test
/// says otherwise.
@Suite struct TreeProjectionWriteTests {
    // MARK: Building trees

    private static func node(_ kind: ElementKind, _ frame: CGRect, _ children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.children = children
        return node
    }

    /// A free group sized to fit, as a group made on the canvas is.
    private static func group(_ frame: CGRect, _ children: [LayerNode]) -> LayerNode {
        var group = node(.group, frame, children)
        group.width = LayerNode.Sizing(.fit)
        group.height = LayerNode.Sizing(.fit)
        return group
    }

    private static func row(_ frame: CGRect, _ children: [LayerNode]) -> LayerNode {
        var row = group(frame, children)
        row.layout = .stack(LayerNode.Stack(axis: .horizontal, spacing: 8))
        return row
    }

    private static let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 12))

    private static func screen(_ children: [LayerNode], layout: LayerNode.Layout? = nil) -> TreeScreen {
        var screen = TreeScreen(name: "S", origin: CGPoint(x: 400, y: 100), scale: 0.5, deviceID: nil)
        screen.root.layout = layout
        screen.root.children = children
        return screen
    }

    private static func content(screens: [TreeScreen] = [], canvas: [LayerNode] = []) -> TreeContent {
        var content = TreeContent()
        content.screens = screens
        content.canvas = canvas
        return content
    }

    private static func element(_ kind: ElementKind, _ frame: CGRect) -> DesignElement {
        DesignElement(kind: kind, frame: frame, text: kind.placeholder, tint: Theme.accent)
    }

    // MARK: Reading them back

    private static func node(_ id: UUID, in content: TreeContent) throws -> LayerNode {
        try #require(TreeIndex(content).node(id, in: content))
    }

    private static func parent(of id: UUID, in content: TreeContent) -> UUID? {
        TreeIndex(content)[id]?.parent
    }

    private static func lowered(_ id: UUID, in content: TreeContent) throws -> DesignElement {
        try #require(TreeProjection.lower(content).elements.first { $0.id == id })
    }

    private static func ids(on host: TreeIndex.Host, in content: TreeContent) -> [UUID] {
        TreeProjection.lowerHost(host, in: content).map(\.id)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-9 && abs(a.minY - b.minY) < 1e-9
            && abs(a.width - b.width) < 1e-9 && abs(a.height - b.height) < 1e-9
    }

    private static func close(_ a: Double?, _ b: Double?) -> Bool {
        abs(Rotation.shortestTurn(from: a ?? 0, to: b ?? 0)) < 1e-9
    }

    // MARK: W1 and W2: one node written

    #if DEBUG
    @MainActor @Test func writingAFieldWritesOnlyThatNode() throws {
        var text = Self.node(.text, CGRect(x: 20, y: 40, width: 120, height: 20))
        text.content.text = "Old"
        text.width = LayerNode.Sizing(.fit)
        text.sketch = LayerNode.SketchIntent(originalBounds: CGRect(x: 18, y: 37, width: 126, height: 25),
                                             normalizedBounds: CGRect(x: 20, y: 40, width: 120, height: 20),
                                             confidence: 0.8, decidedBy: .handwriting, placement: .leading)
        text.source = LayerNode.Source(origin: .sketch, key: "sketch-1")
        let other = Self.node(.button, CGRect(x: 20, y: 80, width: 120, height: 44))
        var content = Self.content(screens: [Self.screen([text, other])])
        var pending: [UUID: UUID] = [:]

        let start = ListWork.elementsWritten
        content.projectedUpdate(text.id, pending: &pending) { $0.text = "New" }
        #expect(ListWork.elementsWritten - start == 1)

        let written = try Self.node(text.id, in: content)
        #expect(written.content.text == "New")
        #expect(written.width == text.width)
        #expect(written.sketch == text.sketch)
        #expect(written.source == text.source)
        var expected = text
        expected.content.text = "New"
        #expect(written == expected)
        #expect(try Self.node(other.id, in: content) == other)

        // Written as it is, nothing is written: what it is on, its scale and its identifier stay theirs.
        let unchanged = content
        let again = ListWork.elementsWritten
        content.projectedUpdate(text.id, pending: &pending) {
            $0.text = "New"
            $0.parent = UUID()
            $0.scale = 3
        }
        #expect(ListWork.elementsWritten - again == 0)
        #expect(content == unchanged)
        #expect(pending.isEmpty)
    }
    #endif

    @Test func writingAMembersFrameMovesOnlyIt() throws {
        let x = Self.node(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        let y = Self.node(.text, CGRect(x: 100, y: 120, width: 40, height: 30))
        let g = Self.group(CGRect(x: 100, y: 200, width: 200, height: 200), [x, y])
        var content = Self.content(screens: [Self.screen([g])])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(x.id, pending: &pending) { $0.frame = CGRect(x: 130, y: 250, width: 30, height: 40) }

        #expect(try Self.node(x.id, in: content).frame == CGRect(x: 30, y: 50, width: 30, height: 40))
        #expect(try Self.node(y.id, in: content) == y)
        let container = try Self.node(g.id, in: content)
        #expect(container.frame == g.frame)
        #expect(container.rotation == nil)
        #expect(container.children.map(\.id) == [x.id, y.id])
    }

    @Test func aFreeContainersTurnKeepsItsChildrenWhereTheyAre() throws {
        let x = Self.node(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        var y = Self.node(.image, CGRect(x: 110, y: 90, width: 60, height: 50))
        y.rotation = 15
        let g = Self.group(CGRect(x: 100, y: 200, width: 200, height: 200), [x, y])
        var content = Self.content(screens: [Self.screen([g])])
        let before = TreeProjection.lower(content)
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(g.id, pending: &pending) { $0.rotation = 30 }

        #expect(try Self.node(g.id, in: content).rotation == 30)
        let after = TreeProjection.lower(content)
        for id in [x.id, y.id] {
            let was = try #require(before.elements.first { $0.id == id })
            let now = try #require(after.elements.first { $0.id == id })
            #expect(Self.close(now.frame, was.frame), "\(now.frame) was \(was.frame)")
            #expect(Self.close(now.rotation, was.rotation), "\(String(describing: now.rotation)) was \(String(describing: was.rotation))")
        }
    }

    @Test func aLaidOutContainerMovesWithItsChildren() throws {
        let a = Self.node(.button, CGRect(x: 0, y: 0, width: 80, height: 44))
        let b = Self.node(.button, CGRect(x: 88, y: 0, width: 80, height: 44))
        let row = Self.row(CGRect(x: 40, y: 200, width: 168, height: 44), [a, b])
        var content = Self.content(screens: [Self.screen([row])])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(row.id, pending: &pending) { $0.frame.origin = CGPoint(x: 60, y: 200) }

        let moved = try Self.node(row.id, in: content)
        #expect(moved.frame.origin == CGPoint(x: 60, y: 200))
        #expect(moved.children.map(\.frame) == [a.frame, b.frame])
        #expect(moved.width == row.width)
        #expect(moved.height == row.height)
    }

    @Test func aChildWrittenInATurnedContainerLandsWhereItWasWritten() throws {
        let x = Self.node(.text, CGRect(x: 10, y: 20, width: 30, height: 40))
        var g = Self.group(CGRect(x: 100, y: 200, width: 200, height: 100), [x, Self.node(.image, CGRect(x: 120, y: 40, width: 60, height: 50))])
        g.rotation = 30
        var content = Self.content(screens: [Self.screen([g])])
        var pending: [UUID: UUID] = [:]
        let written = CGRect(x: 150.5, y: 240.25, width: 36, height: 44)

        content.projectedUpdate(x.id, pending: &pending) {
            $0.frame = written
            $0.rotation = 75
        }

        let landed = try Self.lowered(x.id, in: content)
        #expect(Self.close(landed.frame, written), "\(landed.frame)")
        #expect(Self.close(landed.rotation, 75))
        #expect(Self.close(try Self.node(x.id, in: content).rotation, 45))
        #expect(Self.parent(of: x.id, in: content) == g.id)
    }

    // MARK: W3: a laid-out parent (My call 20)

    @Test func aSizeWrittenToARowChildFixesThatAxis() throws {
        var a = Self.node(.text, CGRect(x: 0, y: 0, width: 60, height: 20))
        a.width = LayerNode.Sizing(.fit)
        a.height = LayerNode.Sizing(.fit)
        let b = Self.node(.button, CGRect(x: 68, y: 0, width: 80, height: 44))
        let row = Self.row(CGRect(x: 40, y: 200, width: 148, height: 44), [a, b])
        var content = Self.content(screens: [Self.screen([row])])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(a.id, pending: &pending) { $0.frame = CGRect(x: 40, y: 200, width: 120, height: 20) }

        let written = try Self.node(a.id, in: content)
        #expect(written.width.mode == .fixed)
        #expect(written.frame.width == 120)
        #expect(written.height.mode == .fit)
        #expect(written.frame.origin == a.frame.origin)
        #expect(Self.parent(of: a.id, in: content) == row.id)
    }

    @Test func aPositionWrittenToARowChildTakesItOut() throws {
        var a = Self.node(.text, CGRect(x: 0, y: 0, width: 60, height: 20))
        a.width = LayerNode.Sizing(.fit)
        a.height = LayerNode.Sizing(.fit)
        let b = Self.node(.button, CGRect(x: 68, y: 0, width: 80, height: 44))
        let row = Self.row(CGRect(x: 40, y: 200, width: 148, height: 44), [a, b])
        let after = Self.node(.image, CGRect(x: 20, y: 300, width: 100, height: 80))
        var content = Self.content(screens: [Self.screen([row, after])])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(a.id, pending: &pending) { $0.frame.origin = CGPoint(x: 5, y: 5) }

        let root = content.screens[0].root
        #expect(Self.parent(of: a.id, in: content) == root.id)
        #expect(root.children.map(\.id) == [row.id, after.id, a.id])
        #expect(try Self.lowered(a.id, in: content).frame == CGRect(x: 5, y: 5, width: 60, height: 20))
        let out = try Self.node(a.id, in: content)
        #expect(out.width.mode == .fixed)
        #expect(out.height.mode == .fixed)
        #expect(try Self.node(row.id, in: content).children.map(\.id) == [b.id])
    }

    @Test func aPositionWrittenToAColumnRootsChildIsLaidBack() throws {
        let title = Self.node(.title, CGRect(x: 0, y: 0, width: 200, height: 40))
        let button = Self.node(.button, CGRect(x: 0, y: 0, width: 200, height: 50))
        var content = Self.content(screens: [Self.screen([title, button], layout: Self.column)])
        TreeRules.apply(to: &content, after: nil)
        let laidOut = try Self.node(button.id, in: content).frame
        let before = content
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(button.id, pending: &pending) { $0.frame.origin = CGPoint(x: 5, y: 5) }
        TreeRules.apply(to: &content, after: before)

        #expect(Self.parent(of: button.id, in: content) == content.screens[0].root.id)
        #expect(try Self.node(button.id, in: content).frame == laidOut)
    }

    @Test func aPositionWrittenToARowChildInAColumnRootStaysInTheRow() throws {
        let text = Self.node(.text, CGRect(x: 0, y: 0, width: 120, height: 20))
        let other = Self.node(.button, CGRect(x: 0, y: 0, width: 80, height: 44))
        let row = Self.row(.zero, [text, other])
        var content = Self.content(screens: [Self.screen([row], layout: Self.column)])
        TreeRules.apply(to: &content, after: nil)
        let laidOut = try Self.node(text.id, in: content).frame
        let before = content
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(text.id, pending: &pending) { $0.frame.origin = CGPoint(x: 5, y: 5) }
        TreeRules.apply(to: &content, after: before)

        #expect(Self.parent(of: text.id, in: content) == row.id)
        #expect(try Self.node(text.id, in: content).frame == laidOut)
    }

    // MARK: W4 to W6: pointers, structural edits and the lift

    @Test func aDrawingKeepsItsPlaceThroughTheLift() throws {
        var note = Self.node(.stickyNote, CGRect(x: 0, y: 0, width: 160, height: 160))
        note.scale = 1
        var drawing = Self.node(.drawing, CGRect(x: 200, y: 0, width: 100, height: 100))
        drawing.scale = 1
        let a = Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = Self.node(.text, CGRect(x: 0, y: 40, width: 40, height: 20))
        var g = Self.group(CGRect(x: 400, y: 0, width: 40, height: 60), [a, b])
        g.scale = 1
        var content = Self.content(canvas: [note, drawing, g])
        var pending: [UUID: UUID] = [:]

        content.projectedSetHost(nil, to: TreeProjection.lowerHost(.canvas, in: content), pending: &pending)

        #expect(content.canvas.map(\.id) == [note.id, drawing.id, g.id])
        #expect(content.canvas[1].id == drawing.id)
        #expect(content.canvas[2].children.map(\.id) == [a.id, b.id])
    }

    @Test func aGroupPointerWriteGathersAsTheListDid() throws {
        let leaves = (0..<5).map { Self.node(.text, CGRect(x: 20, y: 40 + 30 * CGFloat($0), width: 100, height: 20)) }
        let (a, b, c, d, e) = (leaves[0], leaves[1], leaves[2], leaves[3], leaves[4])
        let screen = Self.screen(leaves)
        var content = Self.content(screens: [screen])
        let framesBefore = try [b.id, d.id].map { try Self.lowered($0, in: content).frame }
        var pending: [UUID: UUID] = [:]

        let g = Self.element(.group, CGRect(x: 20, y: 70, width: 100, height: 80))
        content.projectedAdd(g, to: screen.id, scale: nil, pending: &pending)
        content.projectedUpdate(b.id, pending: &pending) { $0.group = g.id }
        content.projectedUpdate(d.id, pending: &pending) { $0.group = g.id }

        #expect(Self.ids(on: .screen(screen.id), in: content) == [a.id, c.id, b.id, d.id, g.id, e.id])
        #expect(try Self.node(g.id, in: content).children.map(\.id) == [b.id, d.id])
        #expect(try [b.id, d.id].map { try Self.lowered($0, in: content).frame } == framesBefore)
        #expect(pending.isEmpty)
    }

    /// An element added pointing at a group already on its host goes on top inside it: added at the
    /// end of the host and gathered at once, it would take the group to the top of the host with it
    /// before the rest of the change (a copy put just in front of its original) had put it in place.
    @Test func anElementAddedIntoAGroupOnItsHostGoesOnTopInsideIt() throws {
        let a = Self.node(.text, CGRect(x: 20, y: 40, width: 100, height: 20))
        let b = Self.node(.text, CGRect(x: 0, y: 0, width: 100, height: 20))
        let d = Self.node(.text, CGRect(x: 0, y: 30, width: 100, height: 20))
        let e = Self.node(.text, CGRect(x: 20, y: 130, width: 100, height: 20))
        let g = Self.group(CGRect(x: 20, y: 70, width: 100, height: 50), [b, d])
        let screen = Self.screen([a, g, e])
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]
        var copy = Self.element(.text, CGRect(x: 36, y: 86, width: 100, height: 20))
        copy.group = g.id

        content.projectedAdd(copy, to: screen.id, scale: nil, pending: &pending)

        #expect(content.screens[0].root.children.map(\.id) == [a.id, g.id, e.id])
        #expect(try Self.node(g.id, in: content).children.map(\.id) == [b.id, d.id, copy.id])
        #expect(try Self.lowered(copy.id, in: content).frame == copy.frame)
        #expect(pending.isEmpty)
    }

    /// A list written as the design keeps it, each element with its own flags, writes each flag that
    /// differs from the node's own, though it matches what a container above shows: a member taken
    /// out of a hidden group, hidden as the group was, stays hidden on its own. A list written as the
    /// views show it keeps the node's own flag where the view's matches the container's.
    @Test func aFlagWrittenAsKeptIsTheNodesOwnThoughItsContainerShowsIt() throws {
        let b = Self.node(.text, CGRect(x: 0, y: 0, width: 100, height: 20))
        let d = Self.node(.text, CGRect(x: 0, y: 30, width: 100, height: 20))
        var g = Self.group(CGRect(x: 20, y: 70, width: 100, height: 50), [b, d])
        g.isHidden = true
        let screen = Self.screen([g])
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(b.id, pending: &pending) {
            $0.group = nil
            $0.isHidden = true
        }
        #expect(content.screens[0].root.children.map(\.id) == [b.id, g.id])
        #expect(try Self.node(b.id, in: content).isHidden)

        let shown = try #require(TreeProjection.lower(content).screens.first?.elements.first { $0.id == d.id })
        #expect(shown.isHidden)
        var kept = TreeProjection.lowerHost(.screen(screen.id), in: content)
        let index = try #require(kept.firstIndex { $0.id == d.id })
        kept[index].isHidden = true
        var asShown = content
        asShown.projectedSetHost(screen.id, to: kept.map { $0.id == d.id ? shown : $0 }, pending: &pending)
        #expect(try !Self.node(d.id, in: asShown).isHidden)
        content.projectedSetHost(screen.id, to: kept, asKept: true, pending: &pending)
        #expect(try Self.node(d.id, in: content).isHidden)
    }

    @Test func membersAddedBeforeTheirGroupJoinItWhenItComes() throws {
        let screen = Self.screen([Self.node(.image, CGRect(x: 20, y: 300, width: 100, height: 80))])
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]
        var groupCopy = Self.element(.group, CGRect(x: 20, y: 40, width: 100, height: 80))
        groupCopy.id = UUID()
        var b = Self.element(.text, CGRect(x: 20, y: 40, width: 100, height: 20))
        b.group = groupCopy.id
        var d = Self.element(.text, CGRect(x: 20, y: 100, width: 100, height: 20))
        d.group = groupCopy.id

        content.projectedAdd(b, to: screen.id, scale: nil, pending: &pending)
        content.projectedAdd(d, to: screen.id, scale: nil, pending: &pending)
        #expect(pending == [b.id: groupCopy.id, d.id: groupCopy.id])
        // Waiting, each is lowered pointing at the group it waits for.
        #expect(try Self.lowered(b.id, in: content).group == nil)
        #expect(TreeProjection.lowerHost(.screen(screen.id), in: content, pending: pending).first { $0.id == b.id }?.group == groupCopy.id)

        content.projectedAdd(groupCopy, to: screen.id, scale: nil, pending: &pending)

        #expect(try Self.node(groupCopy.id, in: content).children.map(\.id) == [b.id, d.id])
        #expect(pending.isEmpty)
        #expect(try Self.lowered(b.id, in: content).frame == b.frame)
        #expect(try Self.lowered(d.id, in: content).frame == d.frame)
    }

    @Test func aClearedPointerTakesTheFrontmostOutInFront() throws {
        let b = Self.node(.text, CGRect(x: 10, y: 10, width: 40, height: 20))
        let d = Self.node(.text, CGRect(x: 10, y: 50, width: 40, height: 20))
        let g = Self.group(CGRect(x: 100, y: 100, width: 60, height: 70), [b, d])
        let screen = Self.screen([g])
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(d.id, pending: &pending) { $0.group = nil }

        #expect(Self.ids(on: .screen(screen.id), in: content) == [b.id, g.id, d.id])
        #expect(try Self.lowered(d.id, in: content).frame == CGRect(x: 110, y: 150, width: 40, height: 20))
        #expect(pending.isEmpty)
    }

    @Test func pointersTheTreeCantHoldWait() throws {
        let leaf = Self.node(.text, CGRect(x: 20, y: 40, width: 100, height: 20))
        let x = Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let y = Self.node(.text, CGRect(x: 0, y: 40, width: 40, height: 20))
        let g = Self.group(CGRect(x: 20, y: 100, width: 40, height: 60), [x, y])
        let elsewhere = Self.group(CGRect(x: 20, y: 100, width: 40, height: 60),
                                   [Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 20)),
                                    Self.node(.text, CGRect(x: 0, y: 40, width: 40, height: 20))])
        let first = Self.screen([leaf, g]), second = Self.screen([elsewhere])
        var content = Self.content(screens: [first, second])

        var missing = Self.element(.text, CGRect(x: 20, y: 200, width: 100, height: 20))
        missing.group = UUID()
        var toALeaf = Self.element(.text, CGRect(x: 20, y: 230, width: 100, height: 20))
        toALeaf.group = leaf.id
        var toAnotherHost = Self.element(.text, CGRect(x: 20, y: 260, width: 100, height: 20))
        toAnotherHost.group = elsewhere.id
        var p = Self.element(.group, CGRect(x: 20, y: 300, width: 100, height: 20))
        var q = Self.element(.group, CGRect(x: 20, y: 330, width: 100, height: 20))
        p.group = q.id
        q.group = p.id
        var drawing = Self.element(.drawing, CGRect(x: 20, y: 400, width: 100, height: 100))
        drawing.group = g.id
        let added = [missing, toALeaf, toAnotherHost, p, q, drawing]
        var pending: [UUID: UUID] = [:]

        content.projectedSetHost(first.id, to: TreeProjection.lowerHost(.screen(first.id), in: content) + added,
                                 pending: &pending)

        let root = content.screens[0].root.id
        for element in added { #expect(Self.parent(of: element.id, in: content) == root, "\(element.kind)") }
        #expect(pending == [missing.id: try #require(missing.group), toALeaf.id: leaf.id,
                            toAnotherHost.id: elsewhere.id, p.id: q.id, q.id: p.id])
        #expect(pending[drawing.id] == nil)
        #expect(try Self.node(g.id, in: content).children.map(\.id) == [x.id, y.id])

        // Written one at a time, the same: the member leaves its group and waits at the top level.
        content.projectedUpdate(x.id, pending: &pending) { $0.group = leaf.id }
        #expect(Self.parent(of: x.id, in: content) == root)
        #expect(pending[x.id] == leaf.id)
        content.projectedUpdate(drawing.id, pending: &pending) { $0.group = g.id }
        #expect(Self.parent(of: drawing.id, in: content) == root)
        #expect(pending[drawing.id] == nil)
    }

    @Test func removingAContainerThroughTheListLeavesItsChildren() throws {
        let a = Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = Self.node(.text, CGRect(x: 10, y: 10, width: 20, height: 20))
        let d = Self.node(.text, CGRect(x: 50, y: 50, width: 20, height: 20))
        let g = Self.group(CGRect(x: 100, y: 100, width: 70, height: 70), [b, d])
        let e = Self.node(.text, CGRect(x: 0, y: 300, width: 40, height: 20))
        var content = Self.content(screens: [Self.screen([a, g, e])])
        var pending: [UUID: UUID] = [:]

        content.projectedRemove([g.id], pending: &pending)

        #expect(content.screens[0].root.children.map(\.id) == [a.id, b.id, d.id, e.id])
        #expect(try Self.lowered(b.id, in: content).frame == CGRect(x: 110, y: 110, width: 20, height: 20))
        #expect(try Self.lowered(d.id, in: content).frame == CGRect(x: 150, y: 150, width: 20, height: 20))
        #expect(pending == [b.id: g.id, d.id: g.id])
    }

    @Test func aHostSetWholeAsItIsChangesNothing() throws {
        var sketched = Self.node(.button, CGRect(x: 30, y: 20, width: 120, height: 44))
        sketched.sketch = LayerNode.SketchIntent(originalBounds: CGRect(x: 28, y: 18, width: 125, height: 47),
                                                 normalizedBounds: CGRect(x: 30, y: 20, width: 120, height: 44),
                                                 confidence: 0.9, decidedBy: .rules, placement: .centered)
        sketched.source = LayerNode.Source(origin: .sketch, key: nil)
        var turnedLeaf = Self.node(.text, CGRect(x: 12.5, y: 7.25, width: 80, height: 20))
        turnedLeaf.rotation = 12
        turnedLeaf.isHidden = true
        var tinted = Self.node(.image, CGRect(x: 0, y: 0, width: 60, height: 40))
        tinted.style.tint = ElementKind.image.spec.tint
        tinted.unknownKeys["future"] = .string("kept")
        let inner = Self.group(CGRect(x: 40, y: 60, width: 120, height: 90), [tinted, turnedLeaf])
        var outer = Self.group(CGRect(x: 20.5, y: 100, width: 240, height: 220), [sketched, inner])
        outer.rotation = 30
        outer.isLocked = true
        var fill = Self.node(.button, CGRect(x: 4, y: 4, width: 100, height: 44))
        fill.width = LayerNode.Sizing(.fill(weight: 1), minimum: 40)
        var row = Self.row(CGRect(x: 16, y: 400, width: 300, height: 52), [fill, Self.node(.text, CGRect(x: 112, y: 16, width: 60, height: 20))])
        row.padding = LayerNode.Padding(all: 4)
        var card = Self.node(.card, CGRect(x: 16, y: 500, width: 200, height: 120), [Self.node(.text, CGRect(x: 16, y: 16, width: 100, height: 20))])
        card.name = "Card"
        card.accessibility = LayerNode.Accessibility(label: "A card", hint: nil)
        let screen = Self.screen([outer, row, card, Self.node(.title, CGRect(x: 20, y: 40, width: 200, height: 40))])

        var canvasGroup = Self.group(CGRect(x: 10, y: 10, width: 300, height: 200),
                                     [Self.node(.text, CGRect(x: 0, y: 0, width: 100, height: 20)),
                                      Self.node(.shape, CGRect(x: 120.75, y: 60, width: 80, height: 80))])
        canvasGroup.scale = 0.5
        canvasGroup.rotation = 45
        var drawing = Self.node(.drawing, CGRect(x: 400, y: 0, width: 100, height: 100))
        drawing.scale = 2
        drawing.content.ink = Data([1, 2, 3])
        let note = Self.node(.stickyNote, CGRect(x: 0, y: 300, width: 160, height: 160))
        let content = Self.content(screens: [screen], canvas: [note, canvasGroup, drawing])
        var lifted = content
        var pending: [UUID: UUID] = [:]

        lifted.projectedSetHost(screen.id, to: TreeProjection.lowerHost(.screen(screen.id), in: content), pending: &pending)
        lifted.projectedSetHost(nil, to: TreeProjection.lowerHost(.canvas, in: content), pending: &pending)

        #expect(lifted == content)
        #expect(pending.isEmpty)
        // As the views show it, too: a member of a locked group, shown locked, keeps its own lock off.
        var shown = lifted
        shown.projectedSetHost(screen.id, to: TreeProjection.lower(lifted).screens[0].elements
            + TreeProjection.lowerHost(.screen(screen.id), in: lifted).filter { $0.kind == .group }, pending: &pending)
        #expect(try Self.node(sketched.id, in: shown).isLocked == false)
        #expect(shown == content)
    }

    @Test func aMemberAtAnotherScaleJoinsAtItsGroupsScale() throws {
        var g = Self.group(CGRect(x: 0, y: 0, width: 400, height: 400),
                           [Self.node(.text, CGRect(x: 0, y: 0, width: 100, height: 40)),
                            Self.node(.text, CGRect(x: 0, y: 100, width: 100, height: 40))])
        g.scale = 0.5
        var member = Self.node(.image, CGRect(x: 0, y: 0, width: 100, height: 100))
        member.scale = 1
        var content = Self.content(canvas: [g, member])
        var pending: [UUID: UUID] = [:]

        content.projectedUpdate(member.id, pending: &pending) { $0.group = g.id }

        #expect(Self.parent(of: member.id, in: content) == g.id)
        let joined = try Self.node(member.id, in: content)
        #expect(joined.frame.size == CGSize(width: 200, height: 200))
        #expect(joined.scale == nil)
        let element = try Self.lowered(member.id, in: content)
        #expect(element.scale == 0.5)
        let onCanvas = FloatingElement(element: element, scale: element.scale ?? 1).canvasFrame
        #expect(onCanvas.size == CGSize(width: 100, height: 100))
    }

    @Test func aMoveTakesTheNodeAsItIsOnTopOfTheOtherHost() throws {
        var sketched = Self.node(.button, CGRect(x: 30, y: 20, width: 120, height: 44))
        sketched.width = LayerNode.Sizing(.fit)
        sketched.source = LayerNode.Source(origin: .sketch, key: "k")
        let screen = Self.screen([sketched, Self.node(.text, CGRect(x: 20, y: 80, width: 100, height: 20))])
        var note = Self.node(.stickyNote, CGRect(x: 0, y: 0, width: 160, height: 160))
        note.scale = 1
        var content = Self.content(screens: [screen], canvas: [note])
        var pending: [UUID: UUID] = [:]
        let landing = CGRect(x: 500, y: 40, width: 120, height: 44)

        content.projectedMove(sketched.id, to: nil, scale: 0.5, frame: landing, pending: &pending)

        #expect(content.canvas.map(\.id) == [note.id, sketched.id])
        let moved = try Self.node(sketched.id, in: content)
        #expect(moved.frame == landing)
        #expect(moved.scale == 0.5)
        #expect(moved.width == sketched.width)
        #expect(moved.source == sketched.source)
        #expect(!content.screens[0].root.children.contains { $0.id == sketched.id })
    }

    @Test func anUnreadChildKeepsItsPlaceWhenAReadOneBeforeItGoes() throws {
        let a = Self.node(.text, CGRect(x: 0, y: 0, width: 40, height: 20))
        let b = Self.node(.text, CGRect(x: 0, y: 30, width: 40, height: 20))
        let c = Self.node(.text, CGRect(x: 0, y: 60, width: 40, height: 20))
        var g = Self.group(CGRect(x: 20, y: 40, width: 40, height: 80), [a, b, c])
        // a, b, the unread child, then c.
        g.unreadChildren = [LayerNode.UnreadChild(index: 2, raw: .string("future"))]
        var content = Self.content(screens: [Self.screen([g])])
        var pending: [UUID: UUID] = [:]

        content.projectedRemove([b.id], pending: &pending)

        let kept = try Self.node(g.id, in: content)
        #expect(kept.children.map(\.id) == [a.id, c.id])
        #expect(kept.unreadChildren == [LayerNode.UnreadChild(index: 1, raw: .string("future"))])
    }

    // MARK: What is counted

    #if DEBUG
    @MainActor @Test func aStructuralEditCountsAsTheListDid() throws {
        let leaves = (0..<4).map { Self.node(.text, CGRect(x: 20, y: 40 + 30 * CGFloat($0), width: 100, height: 20)) }
        let screen = Self.screen(leaves)
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]

        let removing = ListWork.elementsWritten
        content.projectedRemove([leaves[0].id, leaves[2].id], pending: &pending)
        #expect(ListWork.elementsWritten - removing == 2)

        let setting = ListWork.elementsWritten
        content.projectedSetHost(screen.id, to: TreeProjection.lowerHost(.screen(screen.id), in: content).reversed(),
                                 pending: &pending)
        #expect(ListWork.elementsWritten - setting == 0)
        #expect(content.screens[0].root.children.map(\.id) == [leaves[3].id, leaves[1].id])
    }

    @MainActor @Test func aReorderWritesOnlyTheSlotsItChanges() throws {
        let leaves = (0..<4).map { Self.node(.text, CGRect(x: 20, y: 40 + 30 * CGFloat($0), width: 100, height: 20)) }
        let screen = Self.screen(leaves)
        var content = Self.content(screens: [screen])
        var pending: [UUID: UUID] = [:]

        let start = ListWork.elementsWritten
        content.projectedReorder(screen.id, to: [leaves[0].id, leaves[2].id, leaves[1].id, leaves[3].id], pending: &pending)
        #expect(ListWork.elementsWritten - start == 2)
        #expect(Self.ids(on: .screen(screen.id), in: content) == [leaves[0].id, leaves[2].id, leaves[1].id, leaves[3].id])

        // An order that doesn't hold exactly what is there changes nothing.
        let unchanged = content
        let refused = ListWork.elementsWritten
        content.projectedReorder(screen.id, to: [leaves[3].id, leaves[0].id], pending: &pending)
        #expect(ListWork.elementsWritten - refused == 0)
        #expect(content == unchanged)
    }
    #endif
}

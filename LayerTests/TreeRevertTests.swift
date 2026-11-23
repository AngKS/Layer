import CoreGraphics
import Foundation
import Testing
@testable import Layer

/// Undo on the tree: a step takes back only its own changes, among changes made since by
/// others, node by node and field by field, wherever in the tree the nodes have gone.
@Suite struct TreeRevertTests {
    // MARK: - Building designs

    private static func node(_ kind: ElementKind = .body, _ frame: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10),
                             text: String = "", children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.content.text = text
        node.children = children
        return node
    }

    /// A design of one free screen holding `children`. Its versions are made from it, so that
    /// they share the screen.
    private static func design(_ children: [LayerNode], origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeContent {
        var screen = TreeScreen(name: "S", origin: origin, scale: scale, deviceID: nil)
        screen.root.children = children
        var content = TreeContent()
        content.screens = [screen]
        return content
    }

    private static func find(_ id: UUID, in content: TreeContent) -> LayerNode? {
        TreeIndex(content).node(id, in: content)
    }

    /// Changes the node `id`, wherever it is.
    private static func edit(_ content: inout TreeContent, _ id: UUID, _ body: (inout LayerNode) -> Void) {
        func visit(_ node: inout LayerNode) -> Bool {
            if node.id == id {
                body(&node)
                return true
            }
            for index in node.children.indices {
                if visit(&node.children[index]) { return true }
            }
            return false
        }
        for index in content.screens.indices {
            if visit(&content.screens[index].root) { return }
        }
        for index in content.canvas.indices {
            if visit(&content.canvas[index]) { return }
        }
    }

    /// Every node in the design, each time it appears.
    private static func allIDs(_ content: TreeContent) -> [UUID] {
        func ids(_ node: LayerNode) -> [UUID] { [node.id] + node.children.flatMap(ids) }
        return content.screens.flatMap { ids($0.root) } + content.canvas.flatMap(ids)
    }

    // MARK: - Fields

    /// A container whose every field is set to something other than its default.
    private static func everyFieldSet() -> LayerNode {
        var full = LayerNode(kind: .group)
        full.children = [node()]
        full.unreadChildren = [LayerNode.UnreadChild(index: 1, raw: .string("unread"))]
        full.layout = .grid(LayerNode.Grid(columns: 2))
        full.padding = LayerNode.Padding(all: 4)
        full.width = LayerNode.Sizing(.fit)
        full.height = LayerNode.Sizing(.fit, minimum: 10)
        full.frame = CGRect(x: 10, y: 20, width: 100, height: 80)
        full.rotation = 30
        full.scale = 2
        full.content = LayerNode.Content(text: "Text", symbol: "star", shape: .ellipse, imageID: UUID(), isOn: false,
                                         value: 0.25, buttonLook: .bordered, ink: Data([1, 2, 3]))
        full.style = LayerNode.Style(tint: RGBColor(red: 1, green: 0, blue: 0), fontSize: 17, fontWeight: .bold,
                                     textColor: RGBColor(red: 0, green: 1, blue: 0), textAlignment: .center,
                                     cornerRadius: 8, opacity: 0.5, borderColor: RGBColor(red: 0, green: 0, blue: 1),
                                     borderWidth: 2, hasShadow: true)
        full.name = "Every field"
        full.isLocked = true
        full.isHidden = true
        full.accessibility = LayerNode.Accessibility(label: "Label", hint: "Hint")
        full.sketch = LayerNode.SketchIntent(originalBounds: CGRect(x: 1, y: 2, width: 3, height: 4),
                                             normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                             confidence: 0.9, decidedBy: .rules, placement: .leading, structureDeclined: true)
        full.source = LayerNode.Source(origin: .generated, key: "key")
        full.interaction = .object(["tap": .string("next")])
        full.unknownKeys["future"] = .bool(true)
        return full
    }

    /// For each field, as `Mirror` names it, a change to it alone.
    private static let changes: [String: @Sendable (inout LayerNode) -> Void] = [
        "kind": { $0.kind = .card },
        "unreadChildren": { $0.unreadChildren = [] },
        "layout": { $0.layout = .stack(LayerNode.Stack(axis: .vertical)) },
        "padding": { $0.padding = LayerNode.Padding(all: 16) },
        "width": { $0.width = LayerNode.Sizing(.fill(weight: 1)) },
        "height": { $0.height.minimum = 20 },
        "frame": { $0.frame.origin.x += 7 },
        "rotation": { $0.rotation = 45 },
        "scale": { $0.scale = 0.5 },
        "content.text": { $0.content.text = "Other" },
        "content.symbol": { $0.content.symbol = "heart" },
        "content.shape": { $0.content.shape = .star },
        "content.imageID": { $0.content.imageID = UUID() },
        "content.isOn": { $0.content.isOn.toggle() },
        "content.value": { $0.content.value = 0.75 },
        "content.buttonLook": { $0.content.buttonLook = .plain },
        "content.ink": { $0.content.ink = Data([9]) },
        "style.tint": { $0.style.tint = RGBColor(red: 0.5, green: 0.5, blue: 0.5) },
        "style.fontSize": { $0.style.fontSize = 34 },
        "style.fontWeight": { $0.style.fontWeight = .regular },
        "style.textColor": { $0.style.textColor = nil },
        "style.textAlignment": { $0.style.textAlignment = .trailing },
        "style.cornerRadius": { $0.style.cornerRadius = 16 },
        "style.opacity": { $0.style.opacity = 1 },
        "style.borderColor": { $0.style.borderColor = nil },
        "style.borderWidth": { $0.style.borderWidth = 4 },
        "style.hasShadow": { $0.style.hasShadow.toggle() },
        "name": { $0.name = "Named by the step" },
        "isLocked": { $0.isLocked.toggle() },
        "isHidden": { $0.isHidden.toggle() },
        "accessibility": { $0.accessibility?.hint = "Other" },
        "sketch": { $0.sketch?.confidence = 0.1 },
        "source": { $0.source?.key = "other" },
        "interaction": { $0.interaction = .null },
        "unknownKeys": { $0.unknownKeys["future"] = .bool(false) },
    ]

    /// Every field `Mirror` finds, `content`'s and `style`'s by theirs, without `children`.
    private static func fieldLabels(of node: LayerNode) -> [String] {
        var labels: [String] = []
        for case let label? in Mirror(reflecting: node).children.map(\.label) where label != "children" {
            switch label {
            case "content": labels += Mirror(reflecting: node.content).children.compactMap(\.label).map { "content.\($0)" }
            case "style": labels += Mirror(reflecting: node.style).children.compactMap(\.label).map { "style.\($0)" }
            default: labels.append(label)
            }
        }
        return labels
    }

    @Test func fieldListNamesEveryField() {
        let full = Self.everyFieldSet()
        let labels = Self.fieldLabels(of: full)
        #expect(labels.contains("id") && labels.contains("name") && labels.contains("content.text") && labels.contains("style.tint"))
        #expect(!labels.contains("children"))
        for label in labels {
            #expect(LayerNode.revertedFields.contains(label), "\(label) is missing from LayerNode.revertedFields")
        }

        // A changed id is a removal and an addition, so it isn't one of these.
        for label in labels where label != "id" {
            guard let change = Self.changes[label] else {
                Issue.record("No change is written here for \(label)")
                continue
            }
            var before = TreeContent()
            before.canvas = [full]
            var after = before
            change(&after.canvas[0])
            guard after != before else {
                Issue.record("The change written here for \(label) changes nothing")
                continue
            }
            // Another edit since: the name, or when the step's field is the name, the hide.
            let since: (inout LayerNode) -> Void = label == "name" ? { $0.isHidden.toggle() } : { $0.name = "Renamed since" }
            var current = after
            since(&current.canvas[0])
            var expected = full
            since(&expected)

            let reverted = current.reverting(after, to: before)

            #expect(reverted.canvas == [expected], "Undoing a change to \(label) didn't take back that field alone")
        }
    }

    @Test func aStepsOwnFieldGoesBackAndAnothersStays() throws {
        let a = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10), text: "A")
        let before = Self.design([a])
        var after = before
        Self.edit(&after, a.id) { $0.content.text = "B" }
        var current = after
        Self.edit(&current, a.id) { $0.frame = CGRect(x: 5, y: 5, width: 10, height: 10) }

        let reverted = try #require(Self.find(a.id, in: current.reverting(after, to: before)))

        #expect(reverted.content.text == "A")
        #expect(reverted.frame == CGRect(x: 5, y: 5, width: 10, height: 10))
    }

    // MARK: - Order

    @Test func anAddedNodeGoesAndARemovedOneComesBackWhereItWas() {
        let a = Self.node(text: "A"), b = Self.node(text: "B"), c = Self.node(text: "C"), d = Self.node(text: "D"), e = Self.node(text: "E")
        let before = Self.design([a, b, c])
        var after = before
        after.screens[0].root.children = [a, c, d]
        var current = after
        current.screens[0].root.children = [a, c, d, e]

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens[0].root.children == [a, b, c, e])
    }

    @Test func aReorderGoesBackAmongWhatWasAddedSince() {
        let a = Self.node(text: "A"), b = Self.node(text: "B"), c = Self.node(text: "C"), d = Self.node(text: "D")
        let before = Self.design([a, b, c])
        var after = before
        after.screens[0].root.children = [c, a, b]
        var current = after
        current.screens[0].root.children = [c, a, b, d]

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens[0].root.children.map(\.id) == [a, b, c, d].map(\.id))
    }

    // MARK: - Moving between parents

    @Test func aReparentGoesBackToWhereAnotherEditLeftIt() throws {
        let x = Self.node(.body, CGRect(x: 50, y: 50, width: 10, height: 10))
        let y = Self.node(.body, CGRect(x: 0, y: 0, width: 5, height: 5))
        var g = Self.node(.group, CGRect(x: 40, y: 40, width: 30, height: 30), children: [y])
        let before = Self.design([x, g])
        // The step puts X into G, where it was on screen: (10, 10) in G's space.
        var after = before
        var inG = x
        inG.frame = CGRect(x: 10, y: 10, width: 10, height: 10)
        g.children = [y, inG]
        after.screens[0].root.children = [g]
        // Another edit then drags it, in G, to (20, 20): (60, 60) on screen.
        var current = after
        Self.edit(&current, x.id) { $0.frame = CGRect(x: 20, y: 20, width: 10, height: 10) }

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens[0].root.children.map(\.id) == [x.id, g.id])
        #expect(Self.find(x.id, in: reverted)?.frame == CGRect(x: 60, y: 60, width: 10, height: 10))
        #expect(Self.find(g.id, in: reverted)?.children.map(\.id) == [y.id])
    }

    @Test func aNodeWhoseParentIsGoneLandsOnTheCanvasWhereItWas() throws {
        let note = Self.node(.stickyNote, CGRect(x: 0, y: 0, width: 100, height: 100))
        var before = TreeContent()
        before.canvas = [note]
        // The step adds screen S; another edit then puts N on it.
        var after = before
        after.screens = [TreeScreen(name: "S", origin: CGPoint(x: 1000, y: 0), scale: 0.5, deviceID: nil)]
        let n = Self.node(.body, CGRect(x: 10, y: 10, width: 20, height: 20))
        var current = after
        current.screens[0].root.children = [n]

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens.isEmpty)
        #expect(reverted.canvas.map(\.id) == [note.id, n.id])
        let landed = try #require(reverted.canvas.last)
        #expect(landed.frame == CGRect(x: 2010, y: 10, width: 20, height: 20))
        #expect(landed.scale == 0.5)
    }

    @Test func revertingWithNothingElseChangedGivesBefore() {
        // A step that edits, removes, adds, reorders and takes a node out of a turned group.
        let a = Self.node(text: "x"), b = Self.node(text: "B"), c = Self.node(text: "C")
        let l1 = Self.node(.body, CGRect(x: 10, y: 10, width: 20, height: 20)), l2 = Self.node(.body, CGRect(x: 50, y: 50, width: 20, height: 20))
        var turned = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100), children: [l1, l2])
        turned.rotation = 30
        let note = Self.node(.stickyNote, CGRect(x: 0, y: 0, width: 80, height: 80), text: "Note")
        var before = Self.design([a, b, turned])
        before.canvas = [note]

        var after = before
        var out = l1
        let centre = CGPoint(x: 20, y: 20).applying(turned.transformToParent)
        out.frame = CGRect(x: centre.x - 10, y: centre.y - 10, width: 20, height: 20)
        out.rotation = 30
        var left = turned
        left.children = [l2]
        var edited = a
        edited.content.text = "y"
        after.screens[0].root.children = [left, out, c, edited]
        after.canvas[0].content.text = "Changed"

        #expect(after.reverting(after, to: before) == before)

        // The same through the whole of the revert: something else, the board's name, changed since.
        var renamed = after
        renamed.title = "Renamed since"
        var expected = before
        expected.title = "Renamed since"
        #expect(renamed.reverting(after, to: before) == expected)
    }

    @Test func twoParentsRevertedIntoEachOtherMakeNoLoop() throws {
        let l1 = Self.node(.body), l2 = Self.node(.body, CGRect(x: 60, y: 60, width: 10, height: 10))
        let a = Self.node(.group, CGRect(x: 0, y: 0, width: 50, height: 50), children: [l1])
        let b = Self.node(.group, CGRect(x: 100, y: 100, width: 100, height: 100), children: [a, l2])
        let before = Self.design([b])
        // The step takes A out of B; another edit then puts B into A. Taken back, A would go
        // into B again, and B is in A.
        var after = before
        var bAlone = b
        bAlone.children = [l2]
        var aOut = a
        aOut.frame.origin = CGPoint(x: 100, y: 100)
        after.screens[0].root.children = [bAlone, aOut]
        var current = after
        var bIn = bAlone
        bIn.frame.origin = CGPoint(x: 0, y: 0)
        var aHolding = aOut
        aHolding.children = [l1, bIn]
        current.screens[0].root.children = [aHolding]

        let reverted = current.reverting(after, to: before)

        let ids = Self.allIDs(reverted)
        let index = TreeIndex(reverted)
        #expect(ids.count == 5)
        #expect(Set(ids).count == ids.count)
        #expect(index.count == ids.count)
        for id in ids {
            #expect(!index.ancestors(of: id).contains(id))
        }
        // A, later in the order before, is the one taken out of the loop: onto the canvas, holding B.
        #expect(reverted.canvas.map(\.id) == [a.id])
        #expect(index[b.id]?.parent == a.id)
    }

    // MARK: - Screens

    @Test func aScreenRootsLayoutGoesBackWithItsScreen() {
        let a = Self.node(text: "A"), b = Self.node(text: "B")
        let before = Self.design([a])
        var after = before
        after.screens[0].root.layout = .stack(LayerNode.Stack(axis: .vertical))
        var current = after
        current.screens[0].root.children.append(b)

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens[0].root.layout == nil)
        #expect(reverted.screens[0].root.children.map(\.id) == [a.id, b.id])
    }

    // MARK: - Siri's late undo

    @Test func takingBackLeavesWhatChangedSince() throws {
        let a = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10), text: "x")
        let e = Self.node(.body, CGRect(x: 0, y: 40, width: 10, height: 10), text: "E")
        let before = Self.design([a, e])
        let b = Self.node(text: "B"), c = Self.node(text: "C")
        var after = before
        var changedA = a
        changedA.content.text = "y"
        after.screens[0].root.children = [changedA, b]
        var current = after
        current.screens[0].root.children.append(c)
        Self.edit(&current, a.id) { $0.frame.origin.x = 30 }

        var taken = current
        taken.takeBack(after, to: before)

        #expect(taken.screens[0].root.children.map(\.id) == [a.id, e.id, c.id])
        let left = try #require(Self.find(a.id, in: taken))
        #expect(left.content.text == "y")
        #expect(left.frame.origin.x == 30)
        #expect(Self.find(e.id, in: taken) == e)
    }

    // MARK: - What a change touched

    @Test func touchedNamesNodesScreensAndTheBoard() throws {
        let n = Self.node(text: "N")
        var before = Self.design([n])
        before.screens.append(TreeScreen(name: "T", origin: CGPoint(x: 1000, y: 0), scale: 1, deviceID: nil))
        let s = before.screens[0].id, t = before.screens[1].id

        var written = before
        Self.edit(&written, n.id) { $0.content.text = "Changed" }
        let edit = TreeChange(from: before, to: written)
        #expect(edit.nodes == [n.id])
        #expect(edit.screens.isEmpty)
        #expect(!edit.board)

        var moved = before
        moved.screens[0].root.children = []
        moved.screens[1].root.children = [n]
        let move = TreeChange(from: before, to: moved)
        #expect(move.nodes == [n.id])
        #expect(move.screens == [s, t])
        #expect(!move.board)

        var renamed = before
        renamed.title = "Board"
        let rename = TreeChange(from: before, to: renamed)
        #expect(rename.board)
        #expect(rename.nodes.isEmpty && rename.screens.isEmpty)
    }

    @Test func aReorderAloneTouchesNothing() {
        let a = Self.node(text: "A"), b = Self.node(text: "B"), c = Self.node(text: "C")
        let before = Self.design([a, b, c])
        var after = before
        after.screens[0].root.children = [c, a, b]

        let change = TreeChange(from: before, to: after)

        #expect(after != before)
        #expect(change.nodes.isEmpty)
        #expect(change.screens.isEmpty)
        #expect(!change.board)
    }
}

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

    /// For each of a screen's own fields, as `Mirror` names it, a change to it alone.
    private static let screenChanges: [String: @Sendable (inout TreeScreen) -> Void] = [
        "name": { $0.name = "Renamed by the step" },
        "origin": { $0.origin.x += 100 },
        "scale": { $0.scale = 0.25 },
        "deviceID": { $0.deviceID = "ipad-pro-11" },
        "isLocked": { $0.isLocked = true },
        "unknownKeys": { $0.unknownKeys["future"] = .bool(false) },
        "root": { $0.root.name = "Root named by the step" },
    ]

    /// A field a screen gains must be put in `TreeScreen.reverting`'s list, or undo takes the
    /// whole screen back, another edit's changes to it since included.
    @Test func screenFieldListNamesEveryField() {
        var full = TreeScreen(name: "Every field", origin: CGPoint(x: 10, y: 20), scale: 0.5, deviceID: "iphone-17-pro-max")
        full.isLocked = false
        full.unknownKeys["future"] = .bool(true)
        full.root.children = [Self.node()]
        let labels = Mirror(reflecting: full).children.compactMap(\.label)
        #expect(labels.contains("name") && labels.contains("root"))
        for label in labels {
            #expect(TreeScreen.revertedFields.contains(label), "\(label) is missing from TreeScreen.revertedFields")
        }

        // A changed id is a removal and an addition, so it isn't one of these.
        for label in labels where label != "id" {
            guard let change = Self.screenChanges[label] else {
                Issue.record("No change is written here for \(label)")
                continue
            }
            var before = TreeContent()
            before.screens = [full]
            var after = before
            change(&after.screens[0])
            guard after != before else {
                Issue.record("The change written here for \(label) changes nothing")
                continue
            }
            let since: (inout TreeScreen) -> Void = label == "name" ? { $0.origin.y += 5 } : { $0.name = "Renamed since" }
            var current = after
            since(&current.screens[0])
            var expected = full
            since(&expected)

            let reverted = current.reverting(after, to: before)

            #expect(reverted.screens == [expected], "Undoing a change to \(label) didn't take back that field alone")
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

    /// Step A makes a group K on screen S; step H, by hand, then puts X, already on S, into K.
    /// Undoing both, in either order, gives the design they started from: X never leaves its
    /// screen, though K, which A made, goes. Each order is also run with A's later change
    /// taking H's in at its run's start, as the history merges two edits that don't meet.
    @Test(arguments: [true, false], [true, false])
    func aNodePutInAContainerAnotherStepMadeStaysOnItsScreen(containerStepFirst: Bool, merged: Bool) throws {
        let x = Self.node(.body, CGRect(x: 40, y: 300, width: 60, height: 40), text: "X")
        let start = Self.design([x], origin: CGPoint(x: 400, y: 0), scale: 0.5)
        let y1 = Self.node(.body, CGRect(x: 0, y: 0, width: 30, height: 30), text: "Y1")
        let y2 = Self.node(.body, CGRect(x: 130, y: 150, width: 30, height: 30), text: "Y2")
        let k = Self.node(.group, CGRect(x: 20, y: 250, width: 160, height: 180), children: [y1, y2])
        // A: K is made, round where X is.
        var made = start
        made.screens[0].root.children = [x, k]
        // H: X into K, where it was on the screen.
        var putIn = made
        var inK = x
        inK.frame.origin = CGPoint(x: 20, y: 50)
        putIn.screens[0].root.children = [k]
        putIn.screens[0].root.children[0].children = [y1, y2, inK]
        // A again: Y1 renamed.
        var renamed = putIn
        Self.edit(&renamed, y1.id) { $0.content.text = "Renamed" }

        // A's runs, as the history keeps them: merged, its start takes H's change in.
        let aRuns: [(before: TreeContent, after: TreeContent)]
        if merged {
            let mergedStart = start.reverting(made, to: putIn)
            #expect(mergedStart == start, "Taking H in at A's start took X off its screen")
            aRuns = [(mergedStart, renamed)]
        } else {
            aRuns = [(start, made), (putIn, renamed)]
        }
        func undoA(_ content: TreeContent) -> TreeContent {
            aRuns.reversed().reduce(content) { $0.reverting($1.after, to: $1.before) }
        }
        func undoH(_ content: TreeContent) -> TreeContent { content.reverting(putIn, to: made) }

        let once = containerStepFirst ? undoA(renamed) : undoH(renamed)
        if containerStepFirst {
            // K is gone, and X is on its screen where it was, not on the canvas.
            #expect(once.canvas.isEmpty)
            #expect(once.screens[0].root.children == [x])
        }
        let both = containerStepFirst ? undoH(once) : undoA(once)

        #expect(both == start)
    }

    /// Of several things in a container that goes, each lands on the screen in the container's
    /// place among what is there, in their order.
    @Test func whatWasInAContainerThatGoesTakesItsPlace() throws {
        let a = Self.node(text: "A"), b = Self.node(text: "B")
        let start = Self.design([a, b])
        // The step makes K between A and B; another edit then puts X and Z in it.
        let y1 = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10)), y2 = Self.node(.body, CGRect(x: 50, y: 50, width: 10, height: 10))
        let k = Self.node(.group, CGRect(x: 100, y: 100, width: 60, height: 60), children: [y1, y2])
        var made = start
        made.screens[0].root.children = [a, k, b]
        let x = Self.node(.body, CGRect(x: 10, y: 10, width: 10, height: 10), text: "X")
        let z = Self.node(.body, CGRect(x: 20, y: 20, width: 10, height: 10), text: "Z")
        var current = made
        Self.edit(&current, k.id) { $0.children += [x, z] }

        let reverted = current.reverting(made, to: start)

        #expect(reverted.screens[0].root.children.map(\.id) == [a.id, x.id, z.id, b.id])
        #expect(Self.find(x.id, in: reverted)?.frame == CGRect(x: 110, y: 110, width: 10, height: 10))
        #expect(Self.find(z.id, in: reverted)?.frame == CGRect(x: 120, y: 120, width: 10, height: 10))
        #expect(reverted.canvas.isEmpty)
    }

    /// A step put X into group K on screen S; another edit then moved X to screen T. Taken
    /// back, X goes back to S's root, as the step changed what holds it, and stays where it is
    /// on the canvas, at its size in its own points, as the step didn't move it: its place on T
    /// is carried into S's points through the canvas, not read as S's.
    @Test func aPlaceKeptAcrossScreensIsCarriedThroughTheCanvas() throws {
        let x = Self.node(.body, CGRect(x: 10, y: 10, width: 40, height: 20), text: "X")
        let y1 = Self.node(.body, CGRect(x: 0, y: 0, width: 20, height: 20)), y2 = Self.node(.body, CGRect(x: 80, y: 80, width: 20, height: 20))
        let k = Self.node(.group, CGRect(x: 100, y: 100, width: 100, height: 100), children: [y1, y2])
        var before = Self.design([x, k])
        before.screens.append(TreeScreen(name: "T", origin: CGPoint(x: 1000, y: 0), scale: 0.5, deviceID: nil))
        var after = before
        var inK = x
        inK.frame.origin = CGPoint(x: -90, y: -90)
        after.screens[0].root.children = [k]
        after.screens[0].root.children[0].children = [y1, y2, inK]

        // Moved to T, at T's (40, 60): its centre is at (1030, 35) on the canvas.
        var onT = after
        onT.screens[0].root.children[0].children = [y1, y2]
        var movedToT = x
        movedToT.frame.origin = CGPoint(x: 40, y: 60)
        onT.screens[1].root.children = [movedToT]
        let fromT = onT.reverting(after, to: before)
        #expect(fromT.screens[0].root.children.map(\.id) == [x.id, k.id])
        #expect(fromT.screens[1].root.children.isEmpty)
        #expect(Self.find(x.id, in: fromT)?.frame == CGRect(x: 1010, y: 25, width: 40, height: 20))

        // Moved to the canvas, drawn at half its size: its centre is at (1010, 30) there.
        var onCanvas = after
        onCanvas.screens[0].root.children[0].children = [y1, y2]
        var movedOut = x
        movedOut.frame.origin = CGPoint(x: 2000, y: 50)
        movedOut.scale = 0.5
        onCanvas.canvas = [movedOut]
        let fromCanvas = onCanvas.reverting(after, to: before)
        #expect(fromCanvas.canvas.isEmpty)
        let back = try #require(Self.find(x.id, in: fromCanvas))
        #expect(back.frame == CGRect(x: 990, y: 20, width: 40, height: 20))
        #expect(back.scale == nil)
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

    /// An undo that sends a node to the canvas gives it its screen's scale there. A later undo
    /// that puts it back on a screen takes that scale off again, as today's rehost did.
    @Test func anOrphanPutBackOnAScreenLosesItsCanvasScale() throws {
        let n = Self.node(.button, CGRect(x: 20, y: 700, width: 353, height: 50), text: "Go")
        let start = Self.design([n])
        // Step B adds screen G; step A then moves N onto it.
        var added = start
        added.screens.append(TreeScreen(name: "G", origin: CGPoint(x: 1000, y: 0), scale: 0.5, deviceID: nil))
        var moved = added
        var onG = n
        onG.frame.origin = CGPoint(x: 20, y: 400)
        moved.screens[0].root.children = []
        moved.screens[1].root.children = [onG]

        // B is undone first: G goes, and N lands on the canvas at G's scale.
        let withoutG = moved.reverting(added, to: start)
        #expect(withoutG.screens.map(\.id) == [start.screens[0].id])
        #expect(withoutG.canvas.map(\.id) == [n.id])
        #expect(withoutG.canvas.first?.scale == 0.5)

        // Then A: N goes back where it was on its screen, with no scale of its own.
        let undone = withoutG.reverting(moved, to: added)
        #expect(Self.find(n.id, in: undone)?.scale == nil)
        #expect(undone == start)
    }

    // MARK: - Nodes that share an id

    private static func encoded(_ nodes: [LayerNode]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(nodes)
    }

    /// Only a damaged design has two nodes of one id. An undo of something else leaves them,
    /// and all they hold, as they are.
    @Test func aDuplicatedIDOnAnUntouchedCanvasComesBackByteEqual() throws {
        let child = Self.node(.body, CGRect(x: 10, y: 10, width: 20, height: 20), text: "Child")
        let first = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), children: [child])
        var second = Self.node(.stickyNote, CGRect(x: 200, y: 0, width: 100, height: 100), text: "Same id")
        second.id = first.id
        let a = Self.node(text: "A"), b = Self.node(text: "B")
        var before = Self.design([a, b])
        before.canvas = [first, second]
        // The step changes A on the screen; another edit then moves B, so the undo runs in full.
        var after = before
        Self.edit(&after, a.id) { $0.content.text = "Changed" }
        var current = after
        Self.edit(&current, b.id) { $0.frame.origin.x = 40 }

        let reverted = current.reverting(after, to: before)
        #expect(reverted.canvas == before.canvas)
        #expect(try Self.encoded(reverted.canvas) == Self.encoded(before.canvas))
        #expect(Self.find(a.id, in: reverted)?.content.text == "A")
        #expect(Self.find(b.id, in: reverted)?.frame.origin.x == 40)

        var taken = current
        taken.takeBack(after, to: before)
        #expect(taken.canvas == before.canvas)
        #expect(try Self.encoded(taken.canvas) == Self.encoded(before.canvas))
        #expect(Self.find(a.id, in: taken)?.content.text == "A")
    }

    /// When the canvas is taken apart because the step changed something on it, nodes that
    /// share an id stay, each where it was and with what it holds.
    @Test func nodesThatShareAnIDStayWhenTheirHostIsTakenApart() throws {
        let k = Self.node(.stickyNote, CGRect(x: 0, y: 300, width: 80, height: 80), text: "k")
        let c1 = Self.node(.body, CGRect(x: 0, y: 0, width: 20, height: 20), text: "One")
        let c2 = Self.node(.body, CGRect(x: 0, y: 0, width: 20, height: 20), text: "Two")
        let first = Self.node(.group, CGRect(x: 0, y: 0, width: 100, height: 100), children: [c1])
        var second = Self.node(.group, CGRect(x: 200, y: 0, width: 100, height: 100), children: [c2])
        second.id = first.id
        let b = Self.node(text: "B")
        var before = Self.design([b])
        before.canvas = [k, first, second]
        var after = before
        after.canvas[0].content.text = "Changed"
        var current = after
        Self.edit(&current, b.id) { $0.frame.origin.x = 40 }

        let reverted = current.reverting(after, to: before)
        #expect(reverted.canvas == before.canvas)
        #expect(try Self.encoded(reverted.canvas) == Self.encoded(before.canvas))

        var taken = current
        taken.takeBack(after, to: before)
        #expect(taken.canvas == before.canvas)
        #expect(try Self.encoded(taken.canvas) == Self.encoded(before.canvas))
    }

    /// One whose parent an undo takes away lands on the canvas where it was, as any node does.
    @Test func aNodeThatSharesAnIDLandsOnTheCanvasWhenItsParentGoes() throws {
        let x = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10), text: "X")
        let before = Self.design([x])
        // The step adds group G; another edit then puts in it a node of X's id, holding one.
        let y = Self.node(.body, CGRect(x: 0, y: 0, width: 5, height: 5))
        let inside = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        let g = Self.node(.group, CGRect(x: 100, y: 100, width: 50, height: 50), children: [y])
        var after = before
        after.screens[0].root.children = [x, g]
        var current = after
        var copy = Self.node(.group, CGRect(x: 10, y: 10, width: 20, height: 20), children: [inside])
        copy.id = x.id
        Self.edit(&current, g.id) { $0.children.append(copy) }

        let reverted = current.reverting(after, to: before)

        #expect(reverted.screens[0].root.children == [x])
        var landed = copy
        landed.frame = CGRect(x: 110, y: 110, width: 20, height: 20)
        landed.scale = 1
        #expect(reverted.canvas == [landed])
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

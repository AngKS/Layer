import CoreGraphics
import Foundation
import Testing
@testable import Layer

// MARK: - Trees for the tests

private func outline(_ text: String) -> LayerNode { Outline.parse(text, isComplete: true) }

/// A merged root as the store commits it: laid out on the iPhone, over the screen's root as it was.
private func commit(_ merge: TreeReconciler.Merge, over current: LayerNode,
                    by reconciler: inout TreeReconciler) -> LayerNode {
    let committed = TreeRules.laidOut(merge.root, deviceID: "iphone", settings: CanvasSettings(), previous: current)
    reconciler.record(merge, committed: committed)
    return committed
}

/// `generated` merged over `current` and committed.
private func update(_ generated: LayerNode, over current: LayerNode,
                    by reconciler: inout TreeReconciler) -> (merge: TreeReconciler.Merge, committed: LayerNode) {
    let merge = reconciler.merged(generated, over: current)
    return (merge, commit(merge, over: current, by: &reconciler))
}

/// A new screen's root: empty and free, laid out on the iPhone.
private func emptyRoot() -> LayerNode {
    TreeRules.laidOut(LayerNode(kind: .group), deviceID: "iphone", settings: CanvasSettings(), previous: nil)
}

private let column = LayerNode.Layout.stack(LayerNode.Stack(axis: .vertical, spacing: 12))

/// A leaf keyed as the importer keys an A2UI component, by its id.
private func keyed(_ key: String, text: String? = nil, frame: CGRect = .zero) -> LayerNode {
    var node = LayerNode(kind: .text)
    (node.width, node.height) = NaturalSize.defaultSizing(for: .text)
    node.content.text = text ?? key.uppercased()
    node.frame = frame
    node.source = LayerNode.Source(origin: .imported, key: key)
    return node
}

/// A group keyed by its id, laid out by `layout` (free when nil), sized as the outline sizes its containers.
private func keyedGroup(_ key: String, _ layout: LayerNode.Layout?, _ children: [LayerNode]) -> LayerNode {
    var node = LayerNode(kind: .group)
    node.layout = layout
    node.width = LayerNode.Sizing(.fill(weight: 1))
    node.height = LayerNode.Sizing(.fit)
    node.children = children
    node.source = LayerNode.Source(origin: .imported, key: key)
    return node
}

/// A generated screen root, keyed as the outline keys its root.
private func generatedRoot(_ children: [LayerNode], layout: LayerNode.Layout? = column) -> LayerNode {
    var root = LayerNode(kind: .group)
    root.layout = layout
    root.children = children
    root.source = LayerNode.Source(origin: .generated, key: TreeReconciler.rootKey)
    return root
}

/// A text the person added by hand: it has no key.
private func handText(_ text: String) -> LayerNode {
    var node = LayerNode(kind: .text)
    node.content.text = text
    node.frame = CGRect(x: 0, y: 0, width: 120, height: 20)
    return node
}

private func all(_ node: LayerNode) -> [LayerNode] { [node] + node.children.flatMap(all) }

/// The nodes that aren't containers, in reading order.
private func leaves(_ node: LayerNode) -> [LayerNode] {
    node.children.flatMap { $0.isContainer ? leaves($0) : [$0] }
}

private func node(_ key: String, in root: LayerNode) -> LayerNode? {
    all(root).first { $0.source?.key == key }
}

/// Every keyed node's id, by its key.
private func ids(byKey root: LayerNode) -> [String: UUID] {
    Dictionary(all(root).compactMap { node in node.source?.key.map { ($0, node.id) } }, uniquingKeysWith: { first, _ in first })
}

/// `root` with the node of `key` changed, as the person changes it.
private func editing(_ root: LayerNode, _ key: String, _ body: (inout LayerNode) -> Void) -> LayerNode {
    func walk(_ node: inout LayerNode) -> Bool {
        if node.source?.key == key {
            body(&node)
            return true
        }
        for index in node.children.indices where walk(&node.children[index]) { return true }
        return false
    }
    var root = root
    _ = walk(&root)
    return root
}

/// `root` without the node of `key`, as the person deletes it.
private func deleting(_ key: String, from root: LayerNode) -> LayerNode {
    func walk(_ node: inout LayerNode) {
        node.children.removeAll { $0.source?.key == key }
        for index in node.children.indices { walk(&node.children[index]) }
    }
    var root = root
    walk(&root)
    return root
}

/// Generated trees merged into a screen by key: ids kept, the person's changes and hand-added nodes left alone
/// (plan 3, Task 1).
@Suite("The reconciler")
struct TreeReconcilerTests {
    @Test func aFirstWriteTakesTheGeneratedTreeAndKeepsTheScreensRoot() {
        let current = emptyRoot()
        let generated = outline("title: Settings\nbutton: Save")

        let merge = TreeReconciler().merged(generated, over: current)

        #expect(merge.root.id == current.id)
        #expect(merge.root.layout == generated.layout)
        #expect(leaves(merge.root).map(\.id) == leaves(generated).map(\.id))
        #expect(leaves(merge.root).map(\.source?.key) == ["group:0/title:0", "group:0/button:0"])
    }

    @Test func idsOfUnchangedNodesSurviveEveryUpdate() {
        let lines = [
            "title: Settings",
            "card:",
            "  text: Wi-Fi",
            "  body: Connected",
            "row: text: Bluetooth | toggle [on]",
            "grid 2:",
            "  text: 24 Projects",
            "  text: 8 Teams",
        ]
        var reconciler = TreeReconciler()
        var current = emptyRoot()
        var given: [String: UUID] = [:]
        var before: [String: UUID] = [:]
        var shares: [Double] = []

        for count in 1...lines.count {
            // Each parse gives every node a fresh id.
            let generated = outline(lines.prefix(count).joined(separator: "\n"))
            for (key, id) in ids(byKey: generated) where given[key] == nil { given[key] = id }
            current = update(generated, over: current, by: &reconciler).committed
            let after = ids(byKey: current)
            if count > 1 {
                let carried = before.filter { after[$0.key] == $0.value }.count
                shares.append(Double(carried) / Double(before.count))
            }
            before = after
        }

        #expect(shares == Array(repeating: 1.0, count: 7))
        let final = leaves(current)
        #expect(final.count == 7)
        #expect(final.allSatisfy { leaf in leaf.source?.key.flatMap { given[$0] } == leaf.id })
    }

    @Test func aChangedNodeIsLeftAsTheUserLeftIt() throws {
        var reconciler = TreeReconciler()
        var current = update(outline("title: Settings"), over: emptyRoot(), by: &reconciler).committed
        current = editing(current, "group:0/title:0") { $0.content.text = "Mine" }
        let title = try #require(node("group:0/title:0", in: current))

        let merge = reconciler.merged(outline("title: Notifications\nbutton: Save"), over: current)

        let merged = try #require(node("group:0/title:0", in: merge.root))
        #expect(merged.id == title.id)
        #expect(merged.content.text == "Mine")
        #expect(node("group:0/button:0", in: merge.root)?.content.text == "Save")
    }

    @Test func aChangedNodeStaysThePersonsThroughLaterUpdates() throws {
        var reconciler = TreeReconciler()
        var current = update(outline("title: Settings"), over: emptyRoot(), by: &reconciler).committed
        current = editing(current, "group:0/title:0") { $0.content.text = "Mine" }
        current = update(outline("title: Settings\nbutton: Save"), over: current, by: &reconciler).committed

        let merge = reconciler.merged(outline("title: Notifications\nbutton: Save\ntext: More"), over: current)

        #expect(node("group:0/title:0", in: merge.root)?.content.text == "Mine")
        #expect(leaves(merge.root).map(\.kind) == [.title, .button, .text])
    }

    @Test func aContainerThePersonMovedStillTakesWhatTheGeneratorAdds() throws {
        func written(_ inFirst: [String]) -> LayerNode {
            generatedRoot([keyedGroup("k1", column, inFirst.map { keyed($0) }), keyedGroup("k2", column, [])])
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a"]), over: emptyRoot(), by: &reconciler).committed
        let moved = try #require(node("k1", in: current))
        current.children.removeAll { $0.id == moved.id }
        current = editing(current, "k2") { $0.children.append(moved) }

        let merge = reconciler.merged(written(["a", "b"]), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["k2"])
        #expect(node("k2", in: merge.root)?.children.map(\.id) == [moved.id])
        #expect(node("k1", in: merge.root)?.children.map(\.source?.key) == ["a", "b"])
        #expect(node("a", in: merge.root)?.id == node("a", in: current)?.id)
    }

    @Test func aDroppedContainerKeepsWhatWasAddedByHand() throws {
        var reconciler = TreeReconciler()
        var current = update(generatedRoot([keyedGroup("k", column, [keyed("a")]), keyed("b")]), over: emptyRoot(),
                             by: &reconciler).committed
        let hand = handText("Mine")
        current = editing(current, "k") { $0.children.append(hand) }

        let merge = reconciler.merged(generatedRoot([keyed("b")]), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["k", "b"])
        #expect(node("k", in: merge.root)?.children == [hand])
        #expect(merge.dropped == ["a"])
    }

    @Test func whatADroppedContainerHeldCanBeWrittenAgain() throws {
        func written(withK: Bool) -> LayerNode {
            generatedRoot((withK ? [keyedGroup("k", column, [keyed("a")])] : []) + [keyed("b")])
        }
        var reconciler = TreeReconciler()
        let first = update(written(withK: true), over: emptyRoot(), by: &reconciler).committed

        let (drop, second) = update(written(withK: false), over: first, by: &reconciler)
        #expect(drop.dropped == ["k", "a"])
        #expect(drop.root.children.map(\.source?.key) == ["b"])

        let merge = reconciler.merged(written(withK: true), over: second)
        #expect(merge.deletedByUser.isEmpty)
        #expect(merge.root.children.map(\.source?.key) == ["k", "b"])
        #expect(node("k", in: merge.root)?.children.map(\.source?.key) == ["a"])
    }

    @Test func aDragOfAContainerSizedToFitInAFreeParentIsAnEdit() throws {
        func written(text: String) -> LayerNode {
            var line = keyedGroup("r", .stack(LayerNode.Stack(axis: .horizontal, spacing: 8)), [keyed("t", text: text)])
            line.width = LayerNode.Sizing(.fit)
            line.height = LayerNode.Sizing(.fit)
            line.frame = CGRect(x: 20, y: 100, width: 0, height: 0)
            return generatedRoot([line], layout: nil)
        }
        var reconciler = TreeReconciler()
        var current = update(written(text: "Old"), over: emptyRoot(), by: &reconciler).committed
        let size = try #require(node("r", in: current)?.frame.size)
        current = editing(current, "r") { $0.frame.origin = CGPoint(x: 60, y: 200) }

        let merge = reconciler.merged(written(text: "New"), over: current)

        #expect(node("r", in: merge.root)?.frame == CGRect(origin: CGPoint(x: 60, y: 200), size: size))
        #expect(node("t", in: merge.root)?.content.text == "New")
    }

    @Test func aNodeMovedUnderADeletedNodeStaysWhereItWas() throws {
        func written(xInFirst: Bool) -> LayerNode {
            let x = keyed("x")
            return generatedRoot([keyedGroup("c1", column, xInFirst ? [x] : []),
                                  keyedGroup("c2", column, xInFirst ? [] : [x])])
        }
        var reconciler = TreeReconciler()
        var current = update(written(xInFirst: true), over: emptyRoot(), by: &reconciler).committed
        let x = try #require(node("x", in: current))
        current = deleting("c2", from: current)

        let (merge, committed) = update(written(xInFirst: false), over: current, by: &reconciler)

        #expect(node("c1", in: merge.root)?.children.map(\.id) == [x.id])
        #expect(merge.deletedByUser == ["c2"])
        let again = reconciler.merged(written(xInFirst: false), over: committed)
        #expect(node("c1", in: again.root)?.children.map(\.id) == [x.id])
        #expect(again.deletedByUser.isEmpty)
    }

    @Test func aNodeMovedUnderARepeatedKeyIsNeverLost() throws {
        var reconciler = TreeReconciler()
        let first = generatedRoot([keyedGroup("d", column, []), keyedGroup("t", column, []),
                                   keyedGroup("c1", column, [keyed("x")])])
        var current = update(first, over: emptyRoot(), by: &reconciler).committed
        let x = try #require(node("x", in: current))
        let moved = try #require(node("t", in: current))
        // The person deletes d and moves t into c1, after x.
        current = deleting("d", from: deleting("t", from: current))
        current = editing(current, "c1") { $0.children.append(moved) }

        // The generator lists t twice: under d, which is gone, and again holding x.
        let merge = reconciler.merged(generatedRoot([keyedGroup("d", column, [keyedGroup("t", column, [])]),
                                                     keyedGroup("c1", column, []),
                                                     keyedGroup("t", column, [keyed("x")])]), over: current)

        #expect(all(merge.root).filter { $0.id == x.id }.count == 1)
        #expect(merge.deletedByUser == ["d"])
    }

    @Test func aDeletedNodeIsNeverBroughtBack() {
        var reconciler = TreeReconciler()
        var current = update(outline("title: A\nbutton: Go"), over: emptyRoot(), by: &reconciler).committed
        current = deleting("group:0/button:0", from: current)

        let (merge, committed) = update(outline("title: A\nbutton: Go\ntext: More"), over: current, by: &reconciler)

        #expect(leaves(merge.root).map(\.kind) == [.title, .text])
        #expect(merge.deletedByUser == ["group:0/button:0"])
        let again = reconciler.merged(outline("title: A\nbutton: Go\ntext: More"), over: committed)
        #expect(leaves(again.root).map(\.kind) == [.title, .text])
    }

    @Test func aDeletedContainersChildrenStayGone() {
        let card = "card:\n  text: A\n  body: B"
        var reconciler = TreeReconciler()
        var current = update(outline(card), over: emptyRoot(), by: &reconciler).committed
        current = deleting("card:0", from: current)

        let merge = reconciler.merged(outline(card + "\nbutton: Go"), over: current)

        #expect(leaves(merge.root).map(\.kind) == [.button])
    }

    @Test func handAddedNodesAreNeverTouchedOrMoved() throws {
        var reconciler = TreeReconciler()
        var current = update(outline("title: A"), over: emptyRoot(), by: &reconciler).committed
        let hand = handText("Mine")
        current.children.append(hand)
        let section = try #require(node("group:0", in: current))

        let merge = reconciler.merged(outline("title: A\nbutton: Go"), over: current)

        #expect(merge.root.children.map(\.id) == [section.id, hand.id])
        #expect(merge.root.children.last == hand)
        #expect(merge.root.children.first?.children.map(\.kind) == [.title, .button])
    }

    @Test func surplusWrittenNodesGoUnlessChanged() throws {
        func written(_ keys: [String]) -> LayerNode { generatedRoot(keys.map { keyed($0) }) }

        var reconciler = TreeReconciler()
        let committed = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let first = committed.children.map(\.id)
        try #require(first.count == 3)
        let merge = reconciler.merged(written(["a", "c"]), over: committed)
        #expect(merge.root.children.map(\.id) == [first[0], first[2]])
        #expect(merge.dropped == ["b"])

        var again = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &again).committed
        current = editing(current, "b") { $0.content.text = "Mine" }
        let kept = again.merged(written(["a", "c"]), over: current)
        #expect(kept.root.children.map(\.id) == current.children.map(\.id))
        #expect(node("b", in: kept.root)?.content.text == "Mine")
        #expect(kept.dropped.isEmpty)
    }

    @Test func aLaidOutFrameIsNotAnEdit() {
        var reconciler = TreeReconciler()
        var current = update(outline("title: A\nbutton: Go"), over: emptyRoot(), by: &reconciler).committed
        current = editing(current, "group:0/title:0") { $0.frame = CGRect(x: 0, y: 0, width: 10, height: 10) }

        let merge = reconciler.merged(outline("title: B\nbutton: Go"), over: current)

        #expect(node("group:0/title:0", in: merge.root)?.content.text == "B")
    }

    @Test func aFrameInAFreeContainerIsAnEdit() throws {
        func written(x text: String) -> LayerNode {
            var free = keyedGroup("f", nil, [keyed("x", text: text, frame: CGRect(x: 10, y: 10, width: 50, height: 20)),
                                             keyed("y", frame: CGRect(x: 80, y: 10, width: 50, height: 20))])
            free.frame = CGRect(x: 20, y: 100, width: 200, height: 60)
            free.width = LayerNode.Sizing(.fixed)
            free.height = LayerNode.Sizing(.fixed)
            for index in free.children.indices {
                free.children[index].width = LayerNode.Sizing(.fixed)
                free.children[index].height = LayerNode.Sizing(.fixed)
            }
            return generatedRoot([free], layout: nil)
        }
        var reconciler = TreeReconciler()
        var current = update(written(x: "Old"), over: emptyRoot(), by: &reconciler).committed
        try #require(node("f", in: current)?.children.count == 2)
        current = editing(current, "x") { $0.frame = CGRect(x: 30, y: 10, width: 50, height: 20) }

        let merge = reconciler.merged(written(x: "New"), over: current)

        let x = try #require(node("x", in: merge.root))
        #expect(x.frame == CGRect(x: 30, y: 10, width: 50, height: 20))
        #expect(x.content.text == "Old")
    }

    @Test func theGeneratorsOrderIsKeptAndHandNodesKeepTheirPlace() throws {
        var reconciler = TreeReconciler()
        var current = update(generatedRoot([keyed("a"), keyed("b")]), over: emptyRoot(), by: &reconciler).committed
        let (a, b) = (try #require(node("a", in: current)), try #require(node("b", in: current)))
        let hand = handText("Mine")
        current.children.insert(hand, at: 1)

        let merge = reconciler.merged(generatedRoot([keyed("b"), keyed("a")]), over: current)

        #expect(merge.root.children.map(\.id) == [b.id, a.id, hand.id])
    }

    @Test func aNodeTheGeneratorMovesGoesWithItUnlessChanged() throws {
        func written(xInFirst: Bool) -> LayerNode {
            let x = keyed("x")
            return generatedRoot([keyedGroup("c1", column, xInFirst ? [x] : []),
                                  keyedGroup("c2", column, xInFirst ? [] : [x])])
        }
        var reconciler = TreeReconciler()
        let first = update(written(xInFirst: true), over: emptyRoot(), by: &reconciler).committed
        let x = try #require(node("x", in: first))

        let merge = reconciler.merged(written(xInFirst: false), over: first)
        #expect(node("c1", in: merge.root)?.children.isEmpty == true)
        #expect(node("c2", in: merge.root)?.children.map(\.id) == [x.id])
        #expect(merge.dropped.isEmpty)

        let second = commit(merge, over: first, by: &reconciler)
        let again = reconciler.merged(written(xInFirst: false), over: second)
        #expect(node("c2", in: again.root)?.children.map(\.id) == [x.id])
        #expect(all(again.root).filter { $0.source?.key == "x" }.count == 1)

        var other = TreeReconciler()
        var current = update(written(xInFirst: true), over: emptyRoot(), by: &other).committed
        current = editing(current, "x") { $0.content.text = "Mine" }
        let changed = try #require(node("x", in: current))
        let kept = other.merged(written(xInFirst: false), over: current)
        #expect(node("c1", in: kept.root)?.children == [changed])
        #expect(node("c2", in: kept.root)?.children.isEmpty == true)
    }

    @Test func aRepeatedKeyIsWrittenOnce() {
        let first = keyed("k", text: "First"), second = keyed("k", text: "Second")

        let merge = TreeReconciler().merged(generatedRoot([first, second]), over: emptyRoot())

        #expect(merge.root.children.map(\.id) == [first.id])
        #expect(merge.root.children.map(\.content.text) == ["First"])
    }

    @Test func aNodeTheRulesRemovedIsWrittenAgainWithItsID() throws {
        func written() -> LayerNode {
            generatedRoot([keyedGroup("g", nil, [keyed("x", frame: CGRect(x: 20, y: 100, width: 80, height: 20))])],
                          layout: nil)
        }
        var reconciler = TreeReconciler()
        let current = emptyRoot()
        let merge = reconciler.merged(written(), over: current)
        let group = try #require(node("g", in: merge.root))

        let committed = commit(merge, over: current, by: &reconciler)

        #expect(node("g", in: committed) == nil)
        #expect(reconciler.written["g"] == .removedByRules(id: group.id))
        let next = reconciler.merged(written(), over: committed)
        #expect(node("g", in: next.root)?.id == group.id)
        #expect(node("x", in: next.root)?.id == node("x", in: committed)?.id)
    }

    @Test func adoptingAScreenCountsItsKeyedNodesAsWritten() throws {
        var current = TreeRules.laidOut(outline("title: A\nbutton: Go"), deviceID: "iphone", settings: CanvasSettings(),
                                        previous: nil)
        let hand = handText("Mine")
        current.children.append(hand)
        let title = try #require(node("group:0/title:0", in: current))
        let button = try #require(node("group:0/button:0", in: current))

        let merge = TreeReconciler(adopting: current).merged(outline("title: B\nbutton: Go\ntext: More"), over: current)

        let newTitle = try #require(node("group:0/title:0", in: merge.root))
        #expect(newTitle.id == title.id)
        #expect(newTitle.content.text == "B")
        #expect(node("group:0/button:0", in: merge.root)?.id == button.id)
        #expect(node("group:0/text:0", in: merge.root)?.content.text == "More")
        #expect(merge.root.children.last == hand)
    }

    @Test func onlyTheRootsLayoutIsTheGenerators() {
        var current = LayerNode(kind: .group)
        current.name = "Mine"
        current.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let generated = outline("title: A")

        let merge = TreeReconciler().merged(generated, over: current)

        #expect(merge.root.id == current.id)
        #expect(merge.root.name == "Mine")
        #expect(merge.root.frame == CGRect(x: 0, y: 0, width: 393, height: 852))
        #expect(merge.root.layout == generated.layout)
        #expect(merge.root.source == generated.source)
    }

    /// A person's reorder within a laid-out parent is theirs: what they moved stays where they put it, and the
    /// generator's new nodes go round it, in this update and the ones after it (final review A-I1).
    @Test func aReorderMadeWhileAGenerationStreamsIsKept() throws {
        func written(_ keys: [String]) -> LayerNode { generatedRoot(keys.map { keyed($0) }) }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let before = ids(byKey: current)
        let c = current.children.removeLast()
        current.children.insert(c, at: 0)

        let (merge, committed) = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler)

        #expect(merge.root.children.map(\.source?.key) == ["c", "a", "b", "d"])
        #expect(["a", "b", "c"].allSatisfy { node($0, in: merge.root)?.id == before[$0] })
        let again = reconciler.merged(written(["a", "b", "c", "d", "e"]), over: committed)
        #expect(again.root.children.map(\.source?.key) == ["c", "a", "b", "d", "e"])
    }

    /// With no reorder by the person, each update takes the generator's order, as it always has.
    @Test func withoutAReorderEachUpdateTakesTheGeneratorsOrder() {
        func written(_ keys: [String]) -> LayerNode { generatedRoot(keys.map { keyed($0) }) }
        var reconciler = TreeReconciler()
        let current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed

        let (merge, committed) = update(written(["b", "a", "d", "c"]), over: current, by: &reconciler)
        #expect(merge.root.children.map(\.source?.key) == ["b", "a", "d", "c"])

        let again = reconciler.merged(written(["c", "d", "a", "b", "e"]), over: committed)
        #expect(again.root.children.map(\.source?.key) == ["c", "d", "a", "b", "e"])
    }

    /// A node whose neighbour the person deleted, or moved into another container, hasn't been moved itself: it is
    /// still the generator's to write.
    @Test func aNeighbourDeletedOrMovedOutLeavesANodeTheGenerators() throws {
        func written(_ text: String) -> LayerNode {
            generatedRoot([keyedGroup("k", column, []), keyed("a"), keyed("b"), keyed("c", text: text), keyed("d")])
        }
        var reconciler = TreeReconciler()
        var current = update(written("Old"), over: emptyRoot(), by: &reconciler).committed
        let b = try #require(node("b", in: current))
        current = deleting("a", from: deleting("b", from: current))
        current = editing(current, "k") { $0.children.append(b) }

        let merge = reconciler.merged(written("New"), over: current)

        #expect(node("c", in: merge.root)?.content.text == "New")
        #expect(merge.root.children.map(\.source?.key) == ["k", "c", "d"])
        #expect(node("k", in: merge.root)?.children.map(\.id) == [b.id])
    }

    /// A reorder stays the person's after the node the moved one followed is deleted: it can't be followed any more,
    /// and that is no reason to give the moved node back to the generator (plan 3's final re-review, S4).
    @Test func aReorderSurvivesItsOldNeighbourBeingDeleted() throws {
        func written(_ keys: [String], c text: String = "C") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "c" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let c = current.children.removeLast()
        current.children.insert(c, at: 0)
        current = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler).committed
        try #require(current.children.map(\.source?.key) == ["c", "a", "b", "d"])

        current = deleting("b", from: current)
        current = update(written(["a", "b", "c", "d"], c: "GENERATOR"), over: current, by: &reconciler).committed
        let merge = reconciler.merged(written(["a", "b", "c", "d"], c: "GENERATOR"), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["c", "a", "d"])
        #expect(node("c", in: merge.root)?.id == c.id)
        #expect(node("c", in: merge.root)?.content.text == "C")
    }

    /// The same when the generator stops listing the node the moved one followed, so that it is dropped: the stream
    /// alone mustn't undo the person's one reorder (S2).
    @Test func aReorderSurvivesTheGeneratorDroppingItsAnchor() throws {
        func written(_ keys: [String], b text: String = "B") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "b" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c", "d"]), over: emptyRoot(), by: &reconciler).committed
        // The person moves b to the end.
        let b = current.children.remove(at: 1)
        current.children.append(b)
        current = update(written(["a", "b", "c", "d", "e"]), over: current, by: &reconciler).committed
        try #require(current.children.map(\.source?.key) == ["a", "c", "d", "b", "e"])

        // The generator no longer lists a, which b followed when it was written.
        let (dropping, committed) = update(written(["b", "c", "d", "e", "f"]), over: current, by: &reconciler)
        try #require(dropping.dropped == ["a"])
        try #require(committed.children.map(\.source?.key) == ["c", "d", "b", "e", "f"])
        let merge = reconciler.merged(written(["b", "c", "d", "e", "f", "g"], b: "GENERATOR"), over: committed)

        #expect(merge.root.children.map(\.source?.key) == ["c", "d", "b", "e", "f", "g"])
        #expect(node("b", in: merge.root)?.id == b.id)
        #expect(node("b", in: merge.root)?.content.text == "B")
    }

    /// A node whose words the person changed, but which they didn't move, goes on following the generator's order:
    /// after the generator reorders round it once, and again (S3).
    @Test func aWordEditedNodeKeepsItsPlaceAfterTheGeneratorReorders() throws {
        func written(_ keys: [String]) -> LayerNode { generatedRoot(keys.map { keyed($0) }) }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "w", "n"]), over: emptyRoot(), by: &reconciler).committed
        current = editing(current, "w") { $0.content.text = "Mine" }
        current = update(written(["w", "a", "n"]), over: current, by: &reconciler).committed
        try #require(current.children.map(\.source?.key) == ["w", "a", "n"])

        let merge = reconciler.merged(written(["a", "n", "w"]), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["a", "n", "w"])
        #expect(node("w", in: merge.root)?.content.text == "Mine")
    }

    /// A node the person moved up past the node it followed stays theirs, its words and its place, once that node is
    /// deleted or moved out: a person's move is kept for the rest of the generation (plan 4 Task 4, review I1).
    @Test(arguments: [false, true])
    func aNodeMovedUpPastItsNeighbourStaysThePersonsOnceTheNeighbourGoes(movingItOut: Bool) throws {
        func written(_ keys: [String], c text: String = "C") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "c" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let c = current.children.remove(at: 2)
        current.children.insert(c, at: 1)
        current = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler).committed
        try #require(current.children.map(\.source?.key) == ["a", "c", "b", "d"])

        let b = try #require(node("b", in: current))
        current = deleting("b", from: current)
        if movingItOut {
            // Into a group of the person's own, beside something they added.
            var box = LayerNode(kind: .group)
            box.children = [b, handText("Mine")]
            current.children.append(box)
        }
        current = update(written(["a", "b", "c", "d"], c: "GENERATOR"), over: current, by: &reconciler).committed
        #expect(node("c", in: current)?.content.text == "C")
        let merge = reconciler.merged(written(["c", "a", "b", "d"], c: "GENERATOR 2"), over: current)

        #expect(node("c", in: merge.root)?.id == c.id)
        #expect(node("c", in: merge.root)?.content.text == "C")
        #expect(Array(merge.root.children.prefix(2).map(\.source?.key)) == ["a", "c"], "where the person put it")
    }

    /// A node the person didn't touch stays the generator's beside one they moved: its words take each update, and the
    /// generator's reorders land as they did before any move was kept (plan 4 Task 4, review I2).
    @Test func anUntouchedNeighbourOfAMovedNodeStaysTheGenerators() throws {
        func written(_ keys: [String], d text: String = "D") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "d" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let c = current.children.remove(at: 2)
        current.children.insert(c, at: 1)
        current = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler).committed
        current = deleting("b", from: current)
        current = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler).committed

        var words: [String?] = []
        for version in 1...3 {
            current = update(written(["a", "b", "c", "d", "e"], d: "D v\(version)"), over: current, by: &reconciler).committed
            words.append(node("d", in: current)?.content.text)
        }
        let merge = reconciler.merged(written(["d", "a", "b", "c", "e"], d: "D v3"), over: current)

        #expect(words == ["D v1", "D v2", "D v3"])
        #expect(merge.root.children.map(\.source?.key) == ["d", "a", "c", "e"])
    }

    /// Of two neighbours swapped, order alone can't tell which the person moved, so both are theirs: each keeps its
    /// words and its place, and the rest still take the generator's (plan 4 Task 4, fix round 2, N1).
    @Test func aSwapMakesBothThePersons() throws {
        func written(_ keys: [String], version: String = "") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0.uppercased() + version) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        current.children.swapAt(0, 1)

        let merge = reconciler.merged(written(["a", "b", "c"], version: " v2"), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["b", "a", "c"])
        #expect(merge.root.children.map(\.content.text) == ["B", "A", "C v2"])
    }

    /// A node the person drags down one place keeps its words through the updates after (review N1, XD2).
    @Test func aNodeMovedDownOnePlaceKeepsItsWords() throws {
        func written(_ keys: [String], a text: String = "A") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "a" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let a = current.children.remove(at: 0)
        current.children.insert(a, at: 1)

        current = update(written(["a", "b", "c", "d"], a: "A v1"), over: current, by: &reconciler).committed
        let merge = reconciler.merged(written(["a", "b", "c", "d"], a: "A v2"), over: current)

        #expect(node("a", in: current)?.content.text == "A")
        #expect(node("a", in: merge.root)?.content.text == "A")
        #expect(merge.root.children.map(\.source?.key) == ["b", "a", "c", "d"])
    }

    /// A node dragged down one place stays there when the generator then puts it back above (review N1, SD).
    @Test func aMoveDownOnePlaceSurvivesTheGeneratorsReorder() {
        func written(_ keys: [String]) -> LayerNode { generatedRoot(keys.map { keyed($0) }) }
        var reconciler = TreeReconciler()
        var current = update(written(["x", "a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let a = current.children.remove(at: 1)
        current.children.insert(a, at: 2)

        let merge = reconciler.merged(written(["a", "x", "b", "c"]), over: current)

        #expect(merge.root.children.map(\.source?.key) == ["x", "b", "a", "c"])
    }

    /// The MUST-FIX's case the other way round: a node dragged down past the node after it stays the person's, its
    /// words and its place, once that node is deleted (review N1, XD).
    @Test func aNodeMovedDownPastItsNeighbourStaysThePersonsOnceTheNeighbourIsDeleted() throws {
        func written(_ keys: [String], a text: String = "A") -> LayerNode {
            generatedRoot(keys.map { keyed($0, text: $0 == "a" ? text : nil) })
        }
        var reconciler = TreeReconciler()
        var current = update(written(["a", "b", "c"]), over: emptyRoot(), by: &reconciler).committed
        let a = current.children.remove(at: 0)
        current.children.insert(a, at: 1)
        current = update(written(["a", "b", "c", "d"]), over: current, by: &reconciler).committed
        try #require(current.children.map(\.source?.key) == ["b", "a", "c", "d"])

        current = deleting("b", from: current)
        current = update(written(["a", "b", "c", "d"], a: "GENERATOR"), over: current, by: &reconciler).committed
        let merge = reconciler.merged(written(["c", "a", "b", "d"], a: "GENERATOR 2"), over: current)

        #expect(node("a", in: current)?.content.text == "A")
        #expect(node("a", in: merge.root)?.id == a.id)
        #expect(node("a", in: merge.root)?.content.text == "A")
        #expect(merge.root.children.first?.source?.key == "a", "first, where the person left it")
    }

    /// What a newer Layer saved on a node Build Screen adopts stays on it when the generator rewrites it (final review
    /// A-M6).
    @Test func aRewrittenNodeKeepsWhatANewerLayerSavedOnIt() throws {
        var current = TreeRules.laidOut(outline("title: A\nbutton: Go"), deviceID: "iphone", settings: CanvasSettings(),
                                        previous: nil)
        let unread = LayerNode.UnreadChild(index: 2, raw: .object(["kind": .string("hologram")]))
        current = editing(current, "group:0") { $0.unreadChildren = [unread] }
        current = editing(current, "group:0/title:0") { title in
            title.unknownKeys["glow"] = .string("soft")
            var style = UnknownKeys()
            style["blur"] = .number(4)
            title.unknownPartKeys["style"] = style
        }

        let merge = TreeReconciler(adopting: current).merged(outline("title: B\nbutton: Go"), over: current)

        let title = try #require(node("group:0/title:0", in: merge.root))
        #expect(title.content.text == "B")
        #expect(title.unknownKeys["glow"] == .string("soft"))
        #expect(title.unknownPartKeys["style"]?["blur"] == .number(4))
        #expect(node("group:0", in: merge.root)?.unreadChildren == [unread])
    }

    @Test func leavesAreCountedThroughContainers() {
        var hidden = LayerNode(kind: .text)
        hidden.isHidden = true
        var root = outline("title: A\ncard:\n  text: B\n  body: C\nrow: text: D | toggle")
        root.children.append(hidden)

        #expect(root.leafCount == 6)
        #expect(LayerNode(kind: .group).leafCount == 0)
    }
}

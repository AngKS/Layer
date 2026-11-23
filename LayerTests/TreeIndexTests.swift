import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Tree index")
struct TreeIndexTests {
    private static func profile() throws -> TreeContent {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "design-profile", withExtension: "json"))
        return try TreeManifest.decode(try Data(contentsOf: url)).content
    }

    private static func count(_ node: LayerNode) -> Int {
        1 + node.children.reduce(0) { $0 + count($1) }
    }

    private static func ids(_ node: LayerNode) -> [UUID] {
        [node.id] + node.children.flatMap(ids)
    }

    private static func node(_ kind: ElementKind, _ frame: CGRect) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        return node
    }

    private static func screenContent(_ root: (inout LayerNode) -> Void, origin: CGPoint = .zero, scale: CGFloat = 1) -> (TreeContent, TreeScreen) {
        var screen = TreeScreen(name: "S", origin: origin, scale: scale, deviceID: nil)
        root(&screen.root)
        var content = TreeContent()
        content.screens = [screen]
        return (content, screen)
    }

    @Test func everyNodeHasAnEntry() throws {
        let content = try Self.profile()
        let index = TreeIndex(content)
        let all = content.screens.flatMap { Self.ids($0.root) } + content.canvas.flatMap(Self.ids)
        #expect(index.count == all.count)
        #expect(index.count == content.screens.reduce(0) { $0 + Self.count($1.root) } + content.canvas.reduce(0) { $0 + Self.count($1) })
        for id in all {
            #expect(index.node(id, in: content)?.id == id)
        }
    }

    @Test func aScreensRootIsAtDepthZero() throws {
        let content = try Self.profile()
        let index = TreeIndex(content)
        let screen = try #require(content.screens.first)
        let root = try #require(index[screen.root.id])
        #expect(root.host == .screen(screen.id))
        #expect(root.parent == nil)
        #expect(root.depth == 0)
        #expect(root.path.isEmpty)
    }

    @Test func aChildOfATurnedContainerHasItsTurnedPose() {
        var child = Self.node(.body, CGRect(x: 0, y: 0, width: 20, height: 20))
        child.id = UUID()
        var group = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100))
        group.rotation = 90
        group.children = [child]
        let (content, _) = Self.screenContent { $0.children = [group] }
        let index = TreeIndex(content)
        let entry = index[child.id]
        #expect(entry?.hostShape.degrees == 90)
        let centre = entry?.hostShape.centre ?? .zero
        #expect(abs(centre.x - 240) < 0.001 && abs(centre.y - 60) < 0.001)
        #expect(entry?.depth == 2)
        #expect(entry?.parent == group.id)
    }

    @Test func lockAndHideComeFromAncestors() {
        let grandchild = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var child = Self.node(.group, CGRect(x: 0, y: 0, width: 50, height: 50))
        child.children = [grandchild]
        var card = Self.node(.card, CGRect(x: 0, y: 0, width: 100, height: 100))
        card.isLocked = true
        card.children = [child]
        let hiddenChild = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var row = Self.node(.group, CGRect(x: 0, y: 200, width: 100, height: 50))
        row.isHidden = true
        row.children = [hiddenChild]
        let (content, _) = Self.screenContent { $0.children = [card, row] }
        let index = TreeIndex(content)
        #expect(index[grandchild.id]?.isLockedWithAncestors == true)
        #expect(index[grandchild.id]?.isHiddenWithAncestors == false)
        #expect(index[hiddenChild.id]?.isHiddenWithAncestors == true)
        #expect(index[hiddenChild.id]?.isLockedWithAncestors == false)
    }

    @Test func canvasNodesUseTheirScale() {
        var note = Self.node(.stickyNote, CGRect(x: 100, y: 100, width: 150, height: 150))
        note.scale = 0.5
        var content = TreeContent()
        content.canvas = [note]
        let index = TreeIndex(content)
        #expect(index[note.id]?.hostShape.rect == CGRect(x: 50, y: 50, width: 75, height: 75))
        #expect(index[note.id]?.host == .canvas)
        #expect(index[note.id]?.depth == 0)
        #expect(index.node(note.id, in: content)?.id == note.id)
    }

    @Test func aScreenNodesCanvasShapeGoesThroughTheScreen() {
        let node = Self.node(.body, CGRect(x: 20, y: 40, width: 100, height: 50))
        let (content, _) = Self.screenContent({ $0.children = [node] }, origin: CGPoint(x: 1000, y: 0), scale: 0.5)
        let index = TreeIndex(content)
        let shape = index.canvasShape(of: node.id, in: content)
        #expect(shape?.rect == CGRect(x: 1010, y: 20, width: 50, height: 25))
        #expect(index.canvasShape(of: UUID(), in: content) == nil)
    }

    @Test func ancestorsAreNearestFirst() {
        let leaf = Self.node(.body, CGRect(x: 0, y: 0, width: 10, height: 10))
        var inner = Self.node(.group, CGRect(x: 0, y: 0, width: 50, height: 50))
        inner.children = [leaf]
        var outer = Self.node(.card, CGRect(x: 0, y: 0, width: 100, height: 100))
        outer.children = [inner]
        let (content, screen) = Self.screenContent { $0.children = [outer] }
        let index = TreeIndex(content)
        #expect(index.ancestors(of: leaf.id) == [inner.id, outer.id, screen.root.id])
        #expect(index.ancestors(of: screen.root.id).isEmpty)
        #expect(index.ancestors(of: UUID()).isEmpty)
    }

    @Test func aLargeDesignIsIndexedQuickly() {
        var content = TreeContent()
        for s in 0..<10 {
            var cards: [LayerNode] = []
            for c in 0..<50 {
                var card = Self.node(.card, CGRect(x: 0, y: CGFloat(c) * 10, width: 300, height: 10))
                card.children = (0..<9).map { Self.node(.body, CGRect(x: CGFloat($0), y: 0, width: 10, height: 10)) }
                cards.append(card)
            }
            var screen = TreeScreen(name: "S\(s)", origin: CGPoint(x: CGFloat(s) * 500, y: 0), scale: 0.5, deviceID: nil)
            screen.root.children = cards
            content.screens.append(screen)
        }
        // 10 screens x (1 root + 50 cards + 450 leaves) = 5,010 nodes
        var times: [Duration] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let index = TreeIndex(content)
            times.append(ContinuousClock.now - start)
            #expect(index.count == 5010)
        }
        #expect(times.sorted()[2] < .milliseconds(50))
    }
}

private final class BundleMarker {}

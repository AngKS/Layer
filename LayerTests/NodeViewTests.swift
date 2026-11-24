import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Layer

/// A picture of a view, made at scale 1, read pixel by pixel.
@MainActor
private struct Picture {
    let width: Int
    let height: Int
    private let pixels: [UInt8]

    init(of view: some View) throws {
        let renderer = ImageRenderer(content: view.environment(ImageLibrary()))
        renderer.scale = 1
        try self.init(try #require(renderer.cgImage))
    }

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.pixels = pixels
    }

    /// Red, green and blue at a point, each 0–255.
    func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
        let at = (Int(y) * width + Int(x)) * 4
        return (0..<3).map { Int(pixels[at + $0]) }
    }

    /// Whether the point is `hex`, each channel within 2/255.
    func shows(_ hex: Int, at x: CGFloat, _ y: CGFloat) -> Bool {
        let got = pixel(x, y)
        return [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255].enumerated().allSatisfy { abs(got[$0.offset] - $0.element) <= 2 }
    }

    /// Whether anything dark is drawn along the rows from `top` up to `bottom`, between `left` and `right`.
    func hasInk(rows top: CGFloat, _ bottom: CGFloat, columns left: CGFloat, _ right: CGFloat) -> Bool {
        stride(from: Int(top), to: Int(bottom), by: 1).contains { y in
            stride(from: Int(left), to: Int(right), by: 1).contains { x in pixel(CGFloat(x), CGFloat(y))[0] < 128 }
        }
    }

    /// How many rows, from the first with anything dark in `rect` to the last, its ink spans: 0 for none.
    func inkHeight(in rect: CGRect) -> Int {
        let rows = stride(from: Int(rect.minY), to: Int(rect.maxY), by: 1).filter { y in
            stride(from: Int(rect.minX), to: Int(rect.maxX), by: 1).contains { x in pixel(CGFloat(x), CGFloat(y))[0] < 128 }
        }
        guard let first = rows.first, let last = rows.last else { return 0 }
        return last - first + 1
    }
}

/// The tree drawn: each screen's root through recursive node views, the open canvas's nodes at their scale, and the
/// board's picture through the same views. Ported from plan 3's `CardDrawingTests`, whose cases that asserted
/// the screen drawing's own data retired with it under clause (l): `aScreensCardsComeWithItsView` beside
/// `aCardDrawsItsLookUnderWhatItHolds` (a card drawn under what it holds, in order),
/// `nestedCardsComeOutermostFirstAndHiddenOnesNot` beside `hiddenNodesAreNotDrawnAndNothingClips` and
/// `aChildIsDrawnFrameThenTurnThenOffsetInItsParent`, and `laidOutLeavesAreMarked` beside
/// `laidOutTextIsDrawnWholeAndTopAligned`.
@MainActor @Suite struct NodeViewTests {
    static let red = 0xFF0000

    private static func node(_ kind: ElementKind, _ frame: CGRect, _ children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.children = children
        return node
    }

    /// A filled red square-cornered rectangle.
    private static func square(_ frame: CGRect) -> LayerNode {
        var square = node(.shape, frame)
        square.content.shape = .rectangle
        square.content.isOn = true
        square.style.tint = RGBColor(hex: UInt32(red))
        square.style.cornerRadius = 0
        return square
    }

    private static func screen(_ children: [LayerNode], layout: LayerNode.Layout? = nil) -> TreeScreen {
        var screen = TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: nil)
        screen.root.children = children
        screen.root.layout = layout
        return screen
    }

    /// The screen as the canvas draws it, without its name, in a picture `width` wide, or as wide as the screen.
    private static func picture(of screen: TreeScreen, tokens: DesignTokens = .standard, width: CGFloat? = nil) throws -> Picture {
        let device = screen.device
        let view = ScreenView(screen: screen, device: device, tokens: tokens, showsName: false)
            .frame(width: width ?? device.size.width, height: device.size.height, alignment: .topLeading)
        return try Picture(of: view)
    }

    // MARK: Drawn where the tree puts it

    @Test func aChildIsDrawnFrameThenTurnThenOffsetInItsParent() throws {
        var g = Self.node(.group, CGRect(x: 100, y: 100, width: 200, height: 100), [Self.square(CGRect(x: 0, y: 0, width: 20, height: 20))])
        g.rotation = 90
        var card = Self.node(.card, CGRect(x: 100, y: 400, width: 200, height: 40))
        card.rotation = 90
        let picture = try Self.picture(of: Self.screen([g, card]))
        // The square's centre, 10 in from G's corner, is (-90, -40) from G's centre (200, 150); turned a quarter
        // clockwise that is (40, -90).
        #expect(picture.shows(Self.red, at: 240, 60), "\(picture.pixel(240, 60))")
        #expect(!picture.shows(Self.red, at: 110, 110), "drawn unturned: \(picture.pixel(110, 110))")
        // A card's look turns with it: upright about its centre (200, 420) it runs from y 320 to 520.
        #expect(picture.shows(0xF2F2F7, at: 200, 330), "\(picture.pixel(200, 330))")
        #expect(picture.shows(0xFFFFFF, at: 110, 420), "drawn unturned: \(picture.pixel(110, 420))")
    }

    @Test func aCardDrawsItsLookUnderWhatItHolds() throws {
        let card = Self.node(.card, CGRect(x: 40, y: 300, width: 200, height: 100), [
            Self.node(.text, CGRect(x: 16, y: 16, width: 100, height: 20)),
            Self.square(CGRect(x: 160, y: 40, width: 20, height: 20)),
        ])
        let picture = try Self.picture(of: Self.screen([card]))
        let frame = card.frame
        #expect(picture.shows(0xF2F2F7, at: frame.minX + 4, frame.midY), "\(picture.pixel(frame.minX + 4, frame.midY))")
        #expect(picture.shows(0xFFFFFF, at: frame.minX - 4, frame.midY), "\(picture.pixel(frame.minX - 4, frame.midY))")
        #expect(picture.shows(Self.red, at: frame.minX + 170, frame.minY + 50), "what it holds is over its fill")
    }

    @Test func aCardWithoutItsOwnFillTakesTheDesignsTokens() throws {
        var tokens = DesignTokens.standard
        tokens.card.fill = RGBColor(hex: 0x112233)
        tokens.card.radius = 20
        let plain = Self.node(.card, CGRect(x: 20, y: 200, width: 200, height: 100))
        var own = Self.node(.card, CGRect(x: 20, y: 320, width: 200, height: 80))
        own.style.tint = RGBColor(hex: 0xAA0000)
        own.style.cornerRadius = 4
        let picture = try Self.picture(of: Self.screen([plain, own]), tokens: tokens)
        #expect(picture.shows(0x112233, at: 24, 250), "\(picture.pixel(24, 250))")
        #expect(picture.shows(0xAA0000, at: 24, 360), "a card of its own fill keeps it: \(picture.pixel(24, 360))")
        #expect(plain.resolvedFill(tokens: tokens) == RGBColor(hex: 0x112233))
        #expect(plain.resolvedCornerRadius(tokens: tokens) == 20)
        #expect(own.resolvedCornerRadius(tokens: tokens) == 4)
    }

    @Test func hiddenNodesAreNotDrawnAndNothingClips() throws {
        var hidden = Self.square(CGRect(x: 100, y: 200, width: 40, height: 40))
        hidden.isHidden = true
        var shell = Self.node(.group, CGRect(x: 100, y: 500, width: 40, height: 40), [Self.square(CGRect(x: 0, y: 0, width: 40, height: 40))])
        shell.isHidden = true
        let past = Self.square(CGRect(x: 380, y: 300, width: 20, height: 20))
        let picture = try Self.picture(of: Self.screen([hidden, shell, past]), width: 420)
        #expect(picture.width == 420)
        #expect(picture.shows(0xFFFFFF, at: 120, 220), "a hidden node: \(picture.pixel(120, 220))")
        #expect(picture.shows(0xFFFFFF, at: 120, 520), "inside a hidden container: \(picture.pixel(120, 520))")
        #expect(picture.shows(Self.red, at: 395, 310), "past the screen's edge: \(picture.pixel(395, 310))")
    }

    @Test func canvasNodesDrawAtTheirScale() throws {
        var square = Self.square(CGRect(x: 100, y: 100, width: 100, height: 100))
        square.scale = 0.5
        let picture = try Picture(of: CanvasNodeView(node: square, tokens: .standard)
            .frame(width: 200, height: 200, alignment: .topLeading))
        #expect(picture.shows(Self.red, at: 75, 75), "\(picture.pixel(75, 75))")
        #expect(!picture.shows(Self.red, at: 125, 125), "drawn at its own size: \(picture.pixel(125, 125))")
    }

    // MARK: Drawn as it looks

    @Test func laidOutTextIsDrawnWholeAndTopAligned() throws {
        #expect(ElementView.textFit(for: .title, isLaidOut: true)
            == ElementView.TextFit(lineLimit: nil, shrinks: false, vertical: .top))
        #expect(ElementView.textFit(for: .title, isLaidOut: false)
            == ElementView.TextFit(lineLimit: 1, shrinks: true, vertical: .center))
        for kind in [ElementKind.title, .body, .text] {
            #expect(ElementView(node: LayerNode(kind: kind), isLaidOut: true).textFit
                == ElementView.TextFit(lineLimit: nil, shrinks: false, vertical: .top), "\(kind)")
            #expect(ElementView(node: LayerNode(kind: kind), isLaidOut: false).textFit
                == ElementView.textFit(for: kind, isLaidOut: false), "\(kind)")
        }

        // A column's title is drawn at the top of its frame, a free root's in its middle.
        var title = Self.node(.title, CGRect(x: 20, y: 200, width: 300, height: 200))
        title.content.text = "Hello"
        let laidOut = try Self.picture(of: Self.screen([title], layout: .stack(.init(axis: .vertical))))
        let free = try Self.picture(of: Self.screen([title]))
        #expect(laidOut.hasInk(rows: 200, 250, columns: 20, 320))
        #expect(!laidOut.hasInk(rows: 270, 330, columns: 20, 320))
        #expect(!free.hasInk(rows: 200, 250, columns: 20, 320))
        #expect(free.hasInk(rows: 270, 330, columns: 20, 320))
    }

    /// Every look a node resolves is the one the element it was made from resolves, for each leaf kind: fully
    /// styled, and as the kind comes, at its usual size.
    @Test func nodeLooksAreElementLooks() {
        for kind in ElementKind.allCases where kind != .group && kind != .card {
            var styled = DesignStore.newElement(kind)
            styled.tint = RGBColor(hex: 0x123456)
            styled.fontSize = 21
            styled.fontWeight = .semibold
            styled.textColor = RGBColor(hex: 0x654321)
            styled.textAlignment = .trailing
            styled.cornerRadius = 7
            styled.opacity = 0.4
            styled.borderColor = RGBColor(hex: 0x00FF00)
            styled.borderWidth = 3
            styled.hasShadow = true
            styled.buttonLook = .bordered
            styled.value = 0.3
            var plain = DesignStore.newElement(kind)
            if case .fixed(let size) = kind.spec.size { plain.frame.size = size }
            for element in [styled, plain] {
                let node = LayerNode(element: element)
                let tokens = DesignTokens.standard
                #expect(node.resolvedTint == element.tint, "\(kind)")
                #expect(node.resolvedFontSize(tokens: tokens) == element.resolvedFontSize, "\(kind)")
                #expect(node.resolvedFontWeight == element.resolvedFontWeight, "\(kind)")
                #expect(node.resolvedTextColor == element.resolvedTextColor, "\(kind)")
                #expect(node.resolvedCornerRadius(tokens: tokens) == element.resolvedCornerRadius, "\(kind)")
                #expect(node.resolvedOpacity == element.resolvedOpacity, "\(kind)")
                #expect(node.resolvedButtonLook == element.resolvedButtonLook, "\(kind)")
                #expect(node.resolvedValue == element.resolvedValue, "\(kind)")
                #expect(node.resolvedTextAlignment == element.resolvedTextAlignment, "\(kind)")
                #expect(node.resolvedBorderWidth == element.resolvedBorderWidth, "\(kind)")
                #expect(node.resolvedBorderColor == element.resolvedBorderColor, "\(kind)")
                #expect(node.hasFill == element.hasFill, "\(kind)")
                #expect(node.hasCornerRadius == element.hasCornerRadius, "\(kind)")
                #expect(node.hasBorder == element.hasBorder, "\(kind)")
                #expect(node.style.hasShadow == element.hasShadow, "\(kind)")
            }
        }
    }

    @Test func theDesignsTextSizesAreDrawn() {
        var tokens = DesignTokens.standard
        tokens.textSizes.title = 34
        tokens.textSizes.body = 13
        tokens.textSizes.text = 19
        #expect(LayerNode(kind: .title).resolvedFontSize(tokens: tokens) == 34)
        #expect(LayerNode(kind: .body).resolvedFontSize(tokens: tokens) == 13)
        #expect(LayerNode(kind: .text).resolvedFontSize(tokens: tokens) == 19)
        var sized = LayerNode(kind: .title)
        sized.style.fontSize = 20
        #expect(sized.resolvedFontSize(tokens: tokens) == 20)
        for kind in ElementKind.allCases where kind != .group && kind != .card {
            var node = LayerNode(kind: kind)
            node.frame = CGRect(x: 0, y: 0, width: 120, height: 48)
            #expect(NaturalSize.fontSize(of: node, tokens: tokens) == node.resolvedFontSize(tokens: tokens), "\(kind)")
            #expect(NaturalSize.fontSize(of: node) == NaturalSize.fontSize(of: node, tokens: .standard), "\(kind)")
        }
    }

    /// The Magic Pen's titles drawn small, as usual and large (32, 40 and 48 tall) are drawn at Title 2's, the design's
    /// title and Large Title's sizes: 22, 28 and 34. Each carries the size it isn't given by the tokens as its own.
    @Test func aSketchedTitleIsDrawnAtTheSizeItWasDrawn() throws {
        let (store, ids) = sketchedTitles()
        let tree = store.tree
        let titles = try ids.map { try #require(store.node($0)) }
        try #require(titles.count == 3)
        #expect(titles.map(\.frame.height) == [32, 40, 48])
        #expect(titles.map(\.style.fontSize) == [22, nil, 34])
        #expect(titles.map { $0.resolvedFontSize(tokens: tree.settings.tokens) } == [22, 28, 34])

        let screen = try #require(tree.screens.first)
        let picture = try Self.picture(of: screen)
        let heights = titles.map { picture.inkHeight(in: $0.frame) }
        #expect(heights[0] > 0 && heights[0] < heights[1] && heights[1] < heights[2], "the titles' ink, top to bottom: \(heights)")
    }

    /// F7: what a container is called where it has no name of its own.
    @Test func aContainerIsNamedByWhatItIs() {
        func group(_ layout: LayerNode.Layout?) -> LayerNode {
            var group = LayerNode(kind: .group)
            group.layout = layout
            return group
        }
        #expect(LayerNode(kind: .card).displayName == "Card")
        #expect(group(.stack(.init(axis: .horizontal))).displayName == "Row")
        #expect(group(.stack(.init(axis: .vertical))).displayName == "Column")
        #expect(group(.grid(.init(columns: 2))).displayName == "Grid")
        #expect(group(.overlay(.init())).displayName == "Overlay")
        #expect(group(.free).displayName == "Group")
        #expect(group(nil).displayName == "Group")
        #expect(LayerNode(kind: .title).displayName == "Title")

        var named = group(.stack(.init(axis: .horizontal)))
        named.name = "Toolbar"
        #expect(named.displayName == "Toolbar")
        var card = LayerNode(kind: .card)
        card.name = "Profile"
        #expect(card.displayName == "Profile")
        card.name = "  "
        #expect(card.displayName == "Card", "a name of spaces alone is none")
    }

    // MARK: The board's picture

    @Test func theBoardSnapshotDrawsTheTree() throws {
        let model = AppModel(document: LayerDocument())
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 0.5))
        let card = Self.node(.card, CGRect(x: 40, y: 300, width: 200, height: 100))
        try #require(model.store.add(card, to: .screen(screen.id)))
        let parts = try #require(BoardSnapshot.thumbnailParts(of: model))
        let picture = try Picture(try #require(parts.design.cgImage))
        func drawn(_ local: CGPoint) -> CGPoint {
            let canvas = screen.placement.canvasPoint(for: local)
            return CGPoint(x: (canvas.x - parts.area.minX) * parts.scale, y: (canvas.y - parts.area.minY) * parts.scale)
        }
        let middle = drawn(CGPoint(x: card.frame.midX, y: card.frame.midY))
        let beside = drawn(CGPoint(x: card.frame.minX - 16, y: card.frame.midY))
        #expect(picture.shows(0xF2F2F7, at: middle.x, middle.y), "\(picture.pixel(middle.x, middle.y))")
        #expect(picture.shows(0xFFFFFF, at: beside.x, beside.y), "\(picture.pixel(beside.x, beside.y))")
    }
}

extension HostedWindowSuites {
    /// One edit draws again only the node views on its path: the node changed and the containers above it. The
    /// rest of the screen's views are compared by value and left as they were.
    @MainActor
    @Suite("Node views drawn again on an edit", .serialized)
    struct NodeViewWorkTests {
        /// A free root holding G, which holds B and C, and 40 lines.
        @MainActor
        private struct Board {
            let store: DesignStore
            let root: UUID
            let g: UUID
            let b: UUID
            let c: UUID
            let lines: [UUID]

            init() {
                var screen = TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: nil)
                var b = LayerNode(kind: .text)
                b.frame = CGRect(x: 0, y: 0, width: 200, height: 16)
                b.content.text = "B"
                var c = b
                c.id = UUID()
                c.frame.origin.y = 20
                c.content.text = "C"
                var g = LayerNode(kind: .group)
                g.frame = CGRect(x: 20, y: 60, width: 200, height: 36)
                g.children = [b, c]
                let lines = (0..<40).map { index in
                    var line = LayerNode(kind: .text)
                    line.frame = CGRect(x: 20, y: 100 + CGFloat(index) * 18, width: 200, height: 16)
                    line.content.text = "Line \(index)"
                    return line
                }
                screen.root.children = [g] + lines
                var tree = TreeContent()
                tree.screens = [screen]
                store = DesignStore(content: DesignContent(tree: tree))
                root = screen.root.id
                (self.g, self.b, self.c) = (g.id, b.id, c.id)
                self.lines = lines.map(\.id)
            }
        }

        /// The board's screen as the canvas draws it, from the store.
        private struct Shown: View {
            let store: DesignStore

            var body: some View {
                let tree = store.tree
                if let screen = tree.screens.first {
                    ScreenView(screen: screen, device: tree.device(of: screen), tokens: tree.settings.tokens, showsName: false)
                        .equatable()
                }
            }
        }

        private func built(_ ids: [UUID]) -> Int {
            ids.reduce(0) { $0 + CanvasWork.nodeViewsBuilt(of: $1) }
        }

        /// Lets SwiftUI catch up with what has changed.
        private func settle(_ view: UIView, for duration: Duration = .milliseconds(100)) async throws {
            try await Task.sleep(for: duration)
            view.layoutIfNeeded()
        }

        /// Edits B now and then until an edit draws none of the lines again. For a while after a window first
        /// shows, SwiftUI builds every view on every update whatever it is given (see `LayersPanelWorkTests`).
        private func waitForViewsToSettle(_ board: Board, view: UIView) async throws {
            for step in 0..<40 {
                let before = built(board.lines)
                board.store.update(board.b) { $0.content.text = "B \(step)" }
                try await Task.sleep(for: .milliseconds(50))
                view.layoutIfNeeded()
                if built(board.lines) == before { return }
            }
        }

        @Test func oneEditRebuildsOnlyTheViewsOnItsPath() async throws {
            let board = Board()
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
            let host = UIHostingController(rootView: Shown(store: board.store).environment(ImageLibrary()))
            window.rootViewController = host
            // Shown without being made key, as `CanvasTargetsWorkTests` shows its window.
            window.isHidden = false
            defer { window.isHidden = true }
            func everyLineIsDrawn() -> Bool { board.lines.allSatisfy { CanvasWork.nodeViewsBuilt(of: $0) >= 1 } }
            for _ in 0..<20 where !everyLineIsDrawn() { try await settle(host.view) }
            #expect(everyLineIsDrawn(), "every line is drawn as the screen shows")

            // Measured again, up to three times, while something outside has SwiftUI building every view whatever
            // it is given. Views as they were were all built on every edit each time, so they can't pass by a retry.
            let path = [board.root, board.g, board.c]
            var rose = Int.max
            var linesRose = [Int](repeating: Int.max, count: board.lines.count)
            for _ in 0..<3 where rose > 20 * 3 + 10 || linesRose.contains(where: { $0 > 0 }) {
                try await waitForViewsToSettle(board, view: host.view)
                let start = built(path)
                let linesAtStart = board.lines.map(CanvasWork.nodeViewsBuilt(of:))
                for edit in 1...20 {
                    board.store.update(board.c) { $0.content.text = "C \(edit)" }
                    try await settle(host.view)
                }
                rose = built(path) - start
                linesRose = zip(board.lines, linesAtStart).map { CanvasWork.nodeViewsBuilt(of: $0) - $1 }
            }
            print("BENCH node views edits=20 path=\(rose) lines=\(linesRose.reduce(0, +))")
            #expect(rose >= 1, "the views on C's path are drawn again")
            #expect(rose <= 20 * 3 + 10, "root, G and C built over 20 edits: \(rose)")
            #expect(linesRose.allSatisfy { $0 == 0 }, "lines built over 20 edits of C: \(linesRose.reduce(0, +))")
        }
    }
}

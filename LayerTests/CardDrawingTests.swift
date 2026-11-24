import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Layer

/// Cards are drawn under what they hold, and laid-out text is drawn whole where the engine put it.
@MainActor @Suite struct CardDrawingTests {
    private static func node(_ kind: ElementKind, _ frame: CGRect, _ children: [LayerNode] = []) -> LayerNode {
        var node = LayerNode(kind: kind)
        node.frame = frame
        node.children = children
        return node
    }

    private static func store(root children: [LayerNode], layout: LayerNode.Layout? = nil,
                              tokens: DesignTokens? = nil) -> DesignStore {
        var screen = TreeScreen(name: "S", origin: .zero, scale: 1, deviceID: nil)
        screen.root.children = children
        screen.root.layout = layout
        var tree = TreeContent()
        tree.screens = [screen]
        if let tokens { tree.settings.tokens = tokens }
        return DesignStore(content: DesignContent(tree: tree))
    }

    private static let column = LayerNode.Layout.stack(.init(axis: .vertical))

    @Test func aScreensCardsComeWithItsView() throws {
        let text = Self.node(.text, CGRect(x: 16, y: 16, width: 100, height: 20))
        let card = Self.node(.card, CGRect(x: 20, y: 200, width: 200, height: 100), [text])
        let store = Self.store(root: [card], layout: Self.column)
        let drawn = try #require(store.screens[0].drawing.cards.first)
        #expect(store.screens[0].drawing.cards.map(\.id) == [card.id])
        #expect(drawn.kind == .card)
        #expect(drawn.frame == TreeProjection.pose(of: card.id, in: store.tree)?.frame)
        #expect(drawn.tint == RGBColor(hex: 0xF2F2F7))
        #expect(drawn.cornerRadius == 16)
    }

    @Test func aDesignsCardTokensColourItsCards() throws {
        var tokens = DesignTokens.standard
        tokens.card.fill = RGBColor(hex: 0x112233)
        tokens.card.radius = 20
        var own = Self.node(.card, CGRect(x: 20, y: 320, width: 200, height: 80))
        own.style.tint = RGBColor(hex: 0xAA0000)
        let plain = Self.node(.card, CGRect(x: 20, y: 200, width: 200, height: 100))
        let store = Self.store(root: [plain, own], tokens: tokens)
        let cards = store.screens[0].drawing.cards
        try #require(cards.count == 2)
        #expect(cards[0].tint == RGBColor(hex: 0x112233))
        #expect(cards[0].cornerRadius == 20)
        #expect(cards[1].tint == RGBColor(hex: 0xAA0000))
    }

    @Test func nestedCardsComeOutermostFirstAndHiddenOnesNot() {
        let inner = Self.node(.card, CGRect(x: 10, y: 10, width: 80, height: 40))
        let outer = Self.node(.card, CGRect(x: 20, y: 200, width: 200, height: 100), [inner])
        var hidden = Self.node(.card, CGRect(x: 20, y: 320, width: 100, height: 50))
        hidden.isHidden = true
        var shell = Self.node(.group, CGRect(x: 0, y: 400, width: 200, height: 100),
                              [Self.node(.card, CGRect(x: 0, y: 0, width: 50, height: 50))])
        shell.isHidden = true
        let store = Self.store(root: [outer, hidden, shell])
        let cards = store.screens[0].drawing.cards
        #expect(cards.map(\.id) == [outer.id, inner.id])
        guard cards.count == 2 else { return }
        #expect(cards[1].frame.origin == CGPoint(x: 30, y: 210))
    }

    @Test func laidOutLeavesAreMarked() {
        let a = Self.node(.text, CGRect(x: 0, y: 0, width: 50, height: 20))
        let b = Self.node(.title, CGRect(x: 0, y: 30, width: 50, height: 20))
        let laid = Self.store(root: [a, b], layout: Self.column).screens[0].drawing
        #expect(laid.laidOut == [a.id, b.id])
        let free = Self.store(root: [a, b]).screens[0].drawing
        #expect(free.laidOut.isEmpty)
    }

    @Test func aCardsFillIsDrawnUnderItsText() throws {
        let text = Self.node(.text, CGRect(x: 16, y: 16, width: 100, height: 20))
        let card = Self.node(.card, CGRect(x: 40, y: 300, width: 200, height: 100), [text])
        let screen = Self.store(root: [card]).screens[0]
        let frame = try #require(screen.drawing.cards.first).frame
        let renderer = ImageRenderer(content: PhoneScreenView(screen: screen, showsName: false).environment(ImageLibrary()))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: CGFloat, _ y: CGFloat) -> [Int] {
            let at = (Int(y) * width + Int(x)) * 4
            return (0..<3).map { Int(pixels[at + $0]) }
        }
        func matches(_ got: [Int], _ hex: Int) -> Bool {
            [(hex >> 16) & 255, (hex >> 8) & 255, hex & 255].enumerated().allSatisfy { abs(got[$0.offset] - $0.element) <= 2 }
        }
        #expect(matches(pixel(frame.minX + 4, frame.midY), 0xF2F2F7), "\(pixel(frame.minX + 4, frame.midY))")
        #expect(matches(pixel(frame.minX - 4, frame.midY), 0xFFFFFF), "\(pixel(frame.minX - 4, frame.midY))")
    }

    @Test func laidOutTextIsDrawnWholeAndTopAligned() {
        #expect(ElementView.textFit(for: .title, isLaidOut: true)
            == ElementView.TextFit(lineLimit: nil, shrinks: false, vertical: .top))
        #expect(ElementView.textFit(for: .title, isLaidOut: false)
            == ElementView.TextFit(lineLimit: 1, shrinks: true, vertical: .center))
    }
}

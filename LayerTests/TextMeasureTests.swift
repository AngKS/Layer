import CoreGraphics
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Layer

@Suite(.serialized) struct TextMeasureTests {
    private let measure = TextMeasure.shared

    @Test func emptyTextIsOneLineHigh() {
        let empty = measure.size(of: "", fontSize: 15, weight: .regular, width: nil)
        let one = measure.size(of: "A", fontSize: 15, weight: .regular, width: nil)
        #expect(empty.width == 0)
        #expect(empty.height == one.height)
        #expect(one.height > 0)
    }

    @Test func longTextWrapsWithinTheWidth() {
        let text = Array(repeating: "word", count: 200).joined(separator: " ")
        let one = measure.size(of: "word", fontSize: 15, weight: .regular, width: nil)
        let wrapped = measure.size(of: text, fontSize: 15, weight: .regular, width: 300)
        #expect(wrapped.width <= 300)
        #expect(wrapped.height > 5 * one.height)
    }

    @Test func awkwardTextMeasuresSafely() {
        let inputs = [String(repeating: "x", count: 400), "a\nb\nc", "🙂👋🏽", "日本語のテキスト"]
        let one = measure.size(of: "A", fontSize: 15, weight: .regular, width: nil)
        for text in inputs {
            for width in [nil, CGFloat(120)] {
                let size = measure.size(of: text, fontSize: 15, weight: .regular, width: width)
                #expect(size.width.isFinite && size.height.isFinite)
                #expect(size.width == size.width.rounded(.up))
                #expect(size.height == size.height.rounded(.up))
                if let width { #expect(size.width <= width) }
            }
        }
        let lines = measure.size(of: "a\nb\nc", fontSize: 15, weight: .regular, width: 120)
        #expect(lines.height >= 3 * one.height)
    }

    @Test func badWidthsReadAsNil() {
        let free = measure.size(of: "Hello there", fontSize: 15, weight: .regular, width: nil)
        for width in [CGFloat.nan, .infinity, 0, -5] {
            #expect(measure.size(of: "Hello there", fontSize: 15, weight: .regular, width: width) == free)
        }
    }

    #if DEBUG
    @Test func measuringAgainUsesTheCache() {
        let text = "cache probe \(UUID().uuidString)"
        let before = measure.misses
        _ = measure.size(of: text, fontSize: 15, weight: .regular, width: 200)
        _ = measure.size(of: text, fontSize: 15, weight: .regular, width: 200)
        #expect(measure.misses == before + 1)
    }
    #endif

    @MainActor @Test func coreTextAgreesWithSwiftUI() {
        let strings = [
            "Hi", "Hello world", "A somewhat longer line of text that wraps in three hundred points of width.",
            String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6),
            "One\nTwo\nThree", "Settings", "Order summary for your recent purchase",
            String(repeating: "Lorem ipsum dolor sit amet ", count: 12), "Short title here", "Wrap me please, wrap me again, and again"
        ]
        let cases: [(CGFloat, FontWeightChoice, Font.Weight)] = [(15, .regular, .regular), (28, .bold, .bold)]
        for (size, weight, swiftUIWeight) in cases {
            for s in strings {
                let mine = measure.size(of: s, fontSize: size, weight: weight, width: 300)
                let host = UIHostingController(rootView: Text(s).font(.system(size: size, weight: swiftUIWeight)))
                let theirs = host.sizeThatFits(in: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
                #expect(abs(mine.height - theirs.height) <= 1, "\(String(s.prefix(20))) at \(size): \(mine.height) vs \(theirs.height)")
            }
        }
    }

    @Test func naturalSizesFollowTheTable() {
        func natural(_ kind: ElementKind, width: CGFloat? = nil) -> CGSize {
            NaturalSize.of(LayerNode(kind: kind), width: width, measure: measure)
        }
        #expect(natural(.textField) == CGSize(width: 280, height: 48))
        #expect(natural(.textField, width: 200) == CGSize(width: 200, height: 48))
        #expect(natural(.divider) == CGSize(width: 1, height: 1))
        #expect(natural(.divider, width: 300) == CGSize(width: 300, height: 1))
        #expect(natural(.progress) == CGSize(width: 333, height: 6))
        #expect(natural(.image) == CGSize(width: 333, height: 200))
        #expect(natural(.image, width: 250) == CGSize(width: 250, height: 200))
        #expect(natural(.symbol) == CGSize(width: 44, height: 44))
        #expect(natural(.toggle) == CGSize(width: 51, height: 31))
        #expect(natural(.checkbox) == CGSize(width: 24, height: 24))
        #expect(natural(.radio) == CGSize(width: 24, height: 24))
        #expect(natural(.avatar) == CGSize(width: 48, height: 48))
        #expect(natural(.shape) == CGSize(width: 100, height: 100))
        #expect(natural(.stickyNote) == CGSize(width: 150, height: 150))

        var drawing = LayerNode(kind: .drawing)
        drawing.frame = CGRect(x: 5, y: 6, width: 77, height: 33)
        #expect(NaturalSize.of(drawing, width: nil, measure: measure) == CGSize(width: 77, height: 33))

        var button = LayerNode(kind: .button)
        button.content.text = "Continue"
        let label = measure.size(of: "Continue", fontSize: 17, weight: .semibold, width: nil)
        let size = NaturalSize.of(button, width: nil, measure: measure)
        #expect(size.width == max(label.width + 40, 44))
        #expect(size.width == label.width + 40)
        #expect(size.height == 50)
        button.content.text = ""
        #expect(NaturalSize.of(button, width: nil, measure: measure).width == 44)

        var title = LayerNode(kind: .title)
        title.content.text = "Welcome"
        #expect(NaturalSize.of(title, width: nil, measure: measure)
            == measure.size(of: "Welcome", fontSize: 28, weight: .bold, width: nil))
    }

    @Test func fontsFollowTheKindUnlessStyled() {
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .title)) == 28)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .body)) == 15)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .text)) == 17)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .button)) == 17)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .textField)) == 16)
        #expect(NaturalSize.fontWeight(of: LayerNode(kind: .title)) == .bold)
        #expect(NaturalSize.fontWeight(of: LayerNode(kind: .button)) == .semibold)
        var styled = LayerNode(kind: .body)
        styled.style.fontSize = 20
        styled.style.fontWeight = .medium
        #expect(NaturalSize.fontSize(of: styled) == 20)
        #expect(NaturalSize.fontWeight(of: styled) == .medium)
    }

    @Test func generatedNodesStartWithTheKindsSizing() {
        #expect(NaturalSize.defaultSizing(for: .body).width.mode == .fill(weight: 1))
        #expect(NaturalSize.defaultSizing(for: .title).width.mode == .fit)
        #expect(NaturalSize.defaultSizing(for: .button).width.mode == .fill(weight: 1))
        #expect(NaturalSize.defaultSizing(for: .card).width.mode == .fill(weight: 1))
        #expect(NaturalSize.defaultSizing(for: .card).height.mode == .fit)
        for kind in ElementKind.allCases { #expect(NaturalSize.defaultSizing(for: kind).height.mode == .fit) }
    }
}

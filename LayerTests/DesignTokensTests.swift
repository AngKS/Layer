import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite struct DesignTokensTests {
    private static func roundTrip(_ content: TreeContent) throws -> TreeContent {
        try TreeManifest.decode(TreeManifest.encode(content, fileName: nil)).content
    }

    /// A design's file with `tokens` as given JSON in its settings.
    private static func file(tokens: [String: Any]?) throws -> Data {
        let data = try TreeManifest.encode(TreeContent(), fileName: nil)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var inner = try #require(json["content"] as? [String: Any])
        var settings = inner["settings"] as? [String: Any] ?? [:]
        settings["tokens"] = tokens
        inner["settings"] = settings
        json["content"] = inner
        return try JSONSerialization.data(withJSONObject: json)
    }

    @Test func theStandardTokensAreTodaysNumbers() {
        let standard = DesignTokens.standard
        #expect(standard.rhythm == [8, 12, 16, 24, 32])
        #expect(standard.cornerRadii == DesignTokens.CornerRadii(small: 8, medium: 12, large: 16))
        #expect(standard.card == DesignTokens.Card(padding: 16, radius: 16, fill: RGBColor(hex: 0xF2F2F7)))
        #expect(standard.textSizes == DesignTokens.TextSizes(title: 28, body: 15, text: 17))
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .title)) == standard.textSizes.title)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .body)) == standard.textSizes.body)
        #expect(NaturalSize.fontSize(of: LayerNode(kind: .text)) == standard.textSizes.text)
        guard case .points(let radius) = ElementKind.card.spec.cornerRadius else { Issue.record("not points"); return }
        #expect(radius == 16)
        #expect(ElementKind.card.spec.tint == standard.card.fill)
        #expect(ElementLayout.rhythm == standard.rhythm)
    }

    @Test func tokensRoundTripInTheDesign() throws {
        var content = TreeContent()
        content.settings.tokens.rhythm = [4, 8]
        content.settings.tokens.card.padding = 20
        let back = try Self.roundTrip(content)
        #expect(back.settings.tokens.rhythm == [4, 8])
        #expect(back.settings.tokens.card.padding == 20)
        #expect(back.settings == content.settings)
    }

    @Test func aDesignWithoutTokensGetsTheStandardOnes() throws {
        let plain = try TreeManifest.encode(TreeContent(), fileName: nil)
        #expect(!String(decoding: plain, as: UTF8.self).contains("tokens"))
        #expect(try TreeManifest.decode(plain).content.settings.tokens == .standard)
        let nulled = try TreeManifest.decode(Self.file(tokens: nil)).content
        #expect(nulled.settings.tokens == .standard)
    }

    @Test func badTokenNumbersReadAsTheStandardOnes() throws {
        let bad: [String: Any] = [
            "rhythm": [16, 8, 8, -2],
            "card": ["padding": -1, "radius": 0],
            "textSizes": ["title": -28],
            "cornerRadii": ["small": -3],
        ]
        let tokens = try TreeManifest.decode(Self.file(tokens: bad)).content.settings.tokens
        #expect(tokens.rhythm == [8, 16])
        #expect(tokens.card.padding == 16)
        #expect(tokens.card.radius == 16)
        #expect(tokens.textSizes.title == 28)
        #expect(tokens.cornerRadii.small == 8)
        let empty = try TreeManifest.decode(Self.file(tokens: ["rhythm": [Double]()])).content.settings.tokens
        #expect(empty.rhythm == DesignTokens.standard.rhythm)
        let allBad = try TreeManifest.decode(Self.file(tokens: ["rhythm": [0, -4]])).content.settings.tokens
        #expect(allBad.rhythm == DesignTokens.standard.rhythm)
    }

    @Test func nonFiniteNumbersReadAsTheStandardOnes() throws {
        let json = #"{"rhythm":[1e999,8],"card":{"padding":1e999}}"#.data(using: .utf8)!
        let tokens = (try? JSONDecoder().decode(DesignTokens.self, from: json)) ?? .standard
        #expect(tokens.rhythm.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(tokens.card.padding == 16)
    }

    @Test func unknownTokenKeysSurvive() throws {
        let odd: [String: Any] = ["rhythm": [4, 8], "future": ["x": 1]]
        let content = try TreeManifest.decode(Self.file(tokens: odd)).content
        #expect(content.settings.tokens.unknownKeys["future"] == .object(["x": .number(1)]))
        let again = try Self.roundTrip(content)
        #expect(again.settings.tokens == content.settings.tokens)
        #expect(again.settings.tokens.unknownKeys["future"] == .object(["x": .number(1)]))
    }
}

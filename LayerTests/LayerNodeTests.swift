import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Layer

@Suite struct LayerNodeTests {
    private func decode(_ json: String) throws -> LayerNode {
        try JSONDecoder().decode(LayerNode.self, from: Data(json.utf8))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aNodeRoundTripsEveryField() throws {
        var text = LayerNode(kind: .text)
        text.content.text = "Hello"
        text.content.symbol = "star"
        text.content.value = 0.5
        text.content.isOn = false
        text.style = LayerNode.Style(
            tint: RGBColor(hex: 0x112233), fontSize: 17, fontWeight: .bold, textColor: RGBColor(hex: 0x445566),
            textAlignment: .center, cornerRadius: 8, opacity: 0.5, borderColor: RGBColor(hex: 0x778899),
            borderWidth: 2, hasShadow: true)
        text.sketch = LayerNode.SketchIntent(
            originalBounds: CGRect(x: 1, y: 2, width: 3, height: 4), normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.75, decidedBy: .handwriting, placement: .leading, structureDeclined: true)
        text.source = LayerNode.Source(origin: .sketch, key: "k")
        text.accessibility = LayerNode.Accessibility(label: "Greeting", hint: "Says hello")
        text.interaction = .object(["future": .bool(true)])
        text.rotation = 30
        text.width = LayerNode.Sizing(.fill(weight: 2), minimum: 40, maximum: 300)
        text.height = LayerNode.Sizing(.fit)
        text.name = "Hello"
        text.isLocked = true
        text.isHidden = true
        text.scale = 0.5
        text.frame = CGRect(x: 4, y: 5, width: 60, height: 20)

        var grid = LayerNode(kind: .group)
        grid.layout = .grid(LayerNode.Grid(
            columns: 3, columnSpacing: 4, rowSpacing: 6, alignment: LayerNode.Alignment(horizontal: .end, vertical: .start)))

        var node = LayerNode(kind: .card)
        node.layout = .stack(LayerNode.Stack(axis: .vertical, spacing: 12, alignment: .fill, justify: .spaceBetween))
        node.padding = LayerNode.Padding(all: 16)
        node.children = [text, grid]

        let decoded = try JSONDecoder().decode(LayerNode.self, from: JSONEncoder().encode(node))
        #expect(decoded == node)

        var overlay = LayerNode(kind: .group)
        overlay.layout = .overlay(LayerNode.Alignment(horizontal: .start, vertical: .end))
        #expect(try JSONDecoder().decode(LayerNode.self, from: JSONEncoder().encode(overlay)) == overlay)
    }

    @Test func inkIsNeverWritten() throws {
        var node = LayerNode(kind: .drawing)
        node.content.ink = Data([1, 2, 3])
        let data = try JSONEncoder().encode(node)
        let written = try #require(String(data: data, encoding: .utf8))
        #expect(!written.contains("ink"))
        #expect(!written.contains("AQID"))
        #expect(try JSONDecoder().decode(LayerNode.self, from: data).content.ink == nil)
    }

    @Test func unknownKeysOnANodeSurviveARoundTrip() throws {
        let node = try decode(#"{"id":"\#(UUID())","kind":"text","hologram":{"x":1}}"#)
        let written = try object(JSONEncoder().encode(node))
        #expect((written["hologram"] as? [String: Int]) == ["x": 1])
        let wrapped = try object(JSONEncoder().encode(WithUnknownKeys(node)))
        #expect((wrapped["hologram"] as? [String: Int]) == ["x": 1])
    }

    @Test func aChildOfAnUnknownKindIsKeptAtItsPlace() throws {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let json = #"""
        {"id":"\#(UUID())","kind":"group","children":[
          {"id":"\#(a)","kind":"text"},
          {"id":"\#(b)","kind":"hologram"},
          {"id":"\#(c)","kind":"button"}]}
        """#
        let node = try decode(json)
        #expect(node.children.map(\.kind) == [.text, .button])
        let raw = JSONValue.object(["id": .string(b.uuidString), "kind": .string("hologram")])
        #expect(node.unreadChildren == [LayerNode.UnreadChild(index: 1, raw: raw)])

        let written = try #require(try object(JSONEncoder().encode(node))["children"] as? [[String: Any]])
        #expect(written.map { $0["kind"] as? String } == ["text", "hologram", "button"])
        #expect(written.map { $0["id"] as? String } == [a.uuidString, b.uuidString, c.uuidString])
    }

    @Test func missingFieldsTakeTheirDefaults() throws {
        let node = try decode(#"{"id":"\#(UUID())","kind":"text"}"#)
        #expect(node.width == LayerNode.Sizing(.fixed))
        #expect(node.height == LayerNode.Sizing(.fixed))
        #expect(node.layout == nil)
        #expect(node.resolvedLayout == .free)
        #expect(node.frame == .zero)
        #expect(node.children == [])
        #expect(node.isLocked == false)
        #expect(node.content.isOn)
    }

    @Test func onlyGroupsAndCardsAreContainers() {
        #expect(ElementKind.allCases.filter { LayerNode(kind: $0).isContainer } == [.group, .card])
    }

    @Test func theCardHasAQuietCatalogueEntry() {
        let spec = ElementKind.card.spec
        #expect(spec.name == "Card")
        #expect(spec.writtenNames == [])
        #expect(spec.isAskedForOnScreens == false)
        guard case .points(let radius) = spec.cornerRadius else {
            Issue.record("the card's corner radius should be in points")
            return
        }
        #expect(radius == 16)
        #expect(spec.tint == RGBColor(hex: 0xF2F2F7))
        #expect(UIImage(systemName: ElementKind.card.symbol) != nil)
    }
}

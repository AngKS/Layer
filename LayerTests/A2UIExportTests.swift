import A2UICore
import CoreGraphics
import Foundation
import OrderedJSON
import Testing
@testable import Layer

@Suite struct A2UIExportTests {
    // MARK: - The export

    @Test func everyExportedComponentValidates() throws {
        let profile = try Self.screen("design-profile")
        let messages = A2UIExporter.messages(for: profile, surfaceID: "profile")
        #expect(messages.count == 2)

        let validator = PayloadValidator(catalog: LayerCatalog.catalog, config: ValidationConfig(protocolVersion: .v10))
        let components = Self.components(in: messages)
        #expect(components.count > 15)
        for component in components {
            #expect(throws: Never.self, "\(component["id"]?.string ?? "?")") {
                try validator.validateComponent(component)
            }
        }
        for message in messages {
            #expect(throws: Never.self) { _ = try AgentToRendererMessage.parseAll(message, protocolVersion: .v10) }
        }

        // Ids: root, then "n_" and the node's UUID in lower-case hex without dashes.
        let ids = components.compactMap { $0["id"]?.string }
        #expect(ids.contains("root"))
        #expect(Set(ids).count == ids.count)
        let hex = profile.children[0].id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        #expect(ids.contains("n_" + hex))
    }

    @Test func theRoundTripKeepsTheTree() throws {
        let profile = try Self.screen("design-profile")
        let result = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: profile, surfaceID: "profile").utf8))
        #expect(result.screens.count == 1)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let root = try #require(result.screens.first?.root)
        // A screen root's padding is written by TreeRules from its device, not by an import.
        Self.expectSame(root, profile, isRoot: true)
    }

    @Test func aFreeSketchRoundTripsItsPlaces() throws {
        let sketch = try Self.screen("design-sketch")
        #expect(sketch.resolvedLayout == .free)
        let lines = A2UIExporter.jsonLines(for: sketch, surfaceID: "sketch")
        let result = A2UIImporter.importJSON(Data(lines.utf8))
        let root = try #require(result.screens.first?.root)
        #expect(root.resolvedLayout == .free)
        #expect(root.children.count == sketch.children.count)
        #expect(root.children.map(\.frame) == sketch.children.map(\.frame))
        Self.expectSame(root, sketch, isRoot: true)
        // A free screen root is a LayerFree, with the children's places in Layer's look.
        #expect(Self.components(in: A2UIExporter.messages(for: sketch, surfaceID: "sketch")).first?["component"]?.string == "LayerFree")
    }

    @Test func semanticNodesUseBasicComponents() throws {
        var root = LayerNode(kind: .group)
        root.layout = .stack(.init(axis: .vertical, spacing: 24))
        var title = LayerNode(kind: .title); title.content.text = "Hello"
        var row = LayerNode(kind: .group); row.layout = .stack(.init(axis: .horizontal, spacing: 12, alignment: .center, justify: .spaceBetween))
        var text = LayerNode(kind: .text); text.content.text = "Body"
        var weighted = LayerNode(kind: .text); weighted.content.text = "Wide"; weighted.width = .init(.fill(weight: 2))
        row.children = [text, weighted]
        var card = LayerNode(kind: .card); card.layout = .stack(.init(axis: .vertical, spacing: 8)); card.padding = .init(all: 16)
        var go = LayerNode(kind: .button); go.content.text = "Go"; go.content.buttonLook = .filled; go.height = .init(.fit)
        card.children = [go]
        root.children = [title, row, card]

        let components = Self.components(in: A2UIExporter.messages(for: root, surfaceID: "s"))
        func type(_ node: LayerNode) -> String? {
            let id = "n_" + node.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            return components.first { $0["id"]?.string == id }?["component"]?.string
        }
        #expect(components.first?["id"]?.string == "root")
        #expect(components.first?["component"]?.string == "Column")
        #expect(type(title) == "Text")
        #expect(type(row) == "Row")
        #expect(type(text) == "Text")
        #expect(type(card) == "Card")
        #expect(type(go) == "Button")
        let titleComponent = components.first { $0["id"]?.string == "n_" + title.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        #expect(titleComponent?["text"]?.string == "# Hello")
        let rowComponent = components.first { $0["component"]?.string == "Row" }
        #expect(rowComponent?["justify"]?.string == "spaceBetween")
        #expect(rowComponent?["align"]?.string == "center")
        let wide = components.first { $0["text"]?.string == "Wide" }
        #expect(wide?["weight"]?.numeric == 2)
        // The card's child is a Column holding the card's children, and the button says Go in a Text child.
        let cardComponent = try #require(components.first { $0["component"]?.string == "Card" })
        let inner = try #require(components.first { $0["id"]?.string == cardComponent["child"]?.string })
        #expect(inner["component"]?.string == "Column")
        #expect(inner["children"]?.array?.count == 1)
        let button = try #require(components.first { $0["component"]?.string == "Button" })
        #expect(button["variant"]?.string == "primary")
        #expect(button["action"]?.object?["event"]?.object?["name"]?.string == A2UIImporter.layerActionName)
        let label = components.first { $0["id"]?.string == button["child"]?.string }
        #expect(label?["component"]?.string == "Text")
        #expect(label?["text"]?.string == "Go")
        // Every component carries Layer's look.
        for component in components {
            let look = component["@metadata"]?.object?["extensions"]?.object?["layer"]
            #expect(look != nil || component["id"]?.string?.hasSuffix("_label") == true || component["id"]?.string?.hasSuffix("_layout") == true)
        }
        let result = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: root, surfaceID: "s").utf8))
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
        Self.expectSame(try #require(result.screens.first?.root), root, isRoot: true)
    }

    @Test func hiddenNodesAndDrawingsAreLeftOut() throws {
        var root = LayerNode(kind: .group)
        root.layout = .stack(.init(axis: .vertical))
        var shown = LayerNode(kind: .text); shown.content.text = "Shown"
        var hidden = LayerNode(kind: .text); hidden.content.text = "Hidden"; hidden.isHidden = true
        let drawing = LayerNode(kind: .drawing)
        var card = LayerNode(kind: .card); card.layout = .stack(.init(axis: .vertical))
        var inCard = LayerNode(kind: .text); inCard.content.text = "Gone"; inCard.isHidden = true
        var stays = LayerNode(kind: .text); stays.content.text = "Stays"
        card.children = [inCard, stays]
        root.children = [shown, hidden, drawing, card]

        let components = Self.components(in: A2UIExporter.messages(for: root, surfaceID: "s"))
        let texts = components.compactMap { $0["text"]?.string }
        #expect(texts == ["Shown", "Stays"])
        let rootChildren = components.first?["children"]?.array?.count
        #expect(rootChildren == 2)
        let result = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: root, surfaceID: "s").utf8))
        #expect(result.screens.first?.root.children.count == 2)
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    @Test func everyKindAndLayoutRoundTrips() throws {
        func leaf(_ kind: ElementKind, _ edit: (inout LayerNode) -> Void = { _ in }) -> LayerNode {
            var node = LayerNode(kind: kind)
            (node.width, node.height) = (.init(.fit), .init(.fit))
            edit(&node)
            return node
        }
        var grid = LayerNode(kind: .group)
        grid.layout = .grid(.init(columns: 3, columnSpacing: 4, rowSpacing: 6, alignment: .init(horizontal: .end, vertical: .center)))
        grid.children = [leaf(.text) { $0.content.text = "A" }, leaf(.text) { $0.content.text = "B" }]
        var overlay = LayerNode(kind: .group)
        overlay.layout = .overlay(.init(horizontal: .start, vertical: .end))
        overlay.children = [leaf(.shape) { $0.content.shape = .star; $0.content.isOn = false }]
        var card = LayerNode(kind: .card)
        card.layout = .free
        card.padding = .init(top: 1, leading: 2, bottom: 3, trailing: 4)
        card.style.cornerRadius = 9
        card.children = [leaf(.avatar) { $0.name = "Alex"; $0.frame = CGRect(x: 5, y: 6, width: 40, height: 40); $0.rotation = 30 }]
        var root = LayerNode(kind: .group)
        root.layout = .stack(.init(axis: .vertical, spacing: 7, alignment: .center, justify: .spaceEvenly))
        root.children = [
            grid, overlay, card,
            leaf(.toggle) { $0.name = "Wi-Fi"; $0.content.isOn = false },
            leaf(.radio) { $0.content.isOn = true },
            leaf(.checkbox) { $0.content.isOn = false },
            leaf(.progress) { $0.content.value = 0.25 },
            leaf(.symbol) { $0.content.symbol = "heart.fill" },
            leaf(.image) { $0.name = "Cover" },
            leaf(.divider),
            leaf(.textField) { $0.content.text = "Email" },
            leaf(.body) { $0.content.text = "One\nTwo **kept**" },
            leaf(.stickyNote) { $0.content.text = "Note"; $0.style.hasShadow = true },
            leaf(.button) { $0.content.text = "Go"; $0.content.buttonLook = .plain },
        ]
        let components = Self.components(in: A2UIExporter.messages(for: root, surfaceID: "s"))
        let validator = PayloadValidator(catalog: LayerCatalog.catalog, config: ValidationConfig(protocolVersion: .v10))
        for component in components {
            #expect(throws: Never.self, "\(component["id"]?.string ?? "?")") { try validator.validateComponent(component) }
        }
        let result = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: root, surfaceID: "s").utf8))
        #expect(!result.diagnostics.contains { $0.reason == .invalidComponent || $0.reason == .parseFailed }, "\(result.diagnostics)")
        Self.expectSame(try #require(result.screens.first?.root), root, isRoot: true)
    }

    @Test func aDefaultButtonIsWrittenAsThePrimaryAction() throws {
        func button(_ words: String, _ look: ButtonLook?) -> LayerNode {
            var node = LayerNode(kind: .button)
            node.content.text = words
            node.content.buttonLook = look
            return node
        }
        // A button with no look is filled: the screen's primary action.
        var root = LayerNode(kind: .group)
        root.layout = .stack(.init(axis: .vertical))
        root.children = [button("Go", nil), button("Back", .bordered), button("Skip", .plain), button("Buy", .filled)]
        let messages = A2UIExporter.messages(for: root, surfaceID: "s")
        let variants = Self.components(in: messages).filter { $0["component"]?.string == "Button" }.compactMap { $0["variant"]?.string }
        #expect(variants == ["primary", "default", "borderless", "primary"])

        // Back through Layer's look it is the same button; read as plain A2UI, primary is filled.
        let lines = A2UIExporter.jsonLines(for: root, surfaceID: "s")
        let same = try #require(A2UIImporter.importJSON(Data(lines.utf8)).screens.first?.root)
        #expect(same.children.map(\.content.buttonLook) == [nil, .bordered, .plain, .filled])
        let plain = try lines.split(separator: "\n").map { line -> String in
            var message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            if var update = message["updateComponents"] as? [String: Any], let components = update["components"] as? [[String: Any]] {
                update["components"] = components.map { $0.filter { $0.key != "@metadata" } }
                message["updateComponents"] = update
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        }.joined(separator: "\n")
        let read = try #require(A2UIImporter.importJSON(Data(plain.utf8)).screens.first?.root)
        #expect(read.children.map(\.content.buttonLook) == [.filled, .bordered, .plain, .filled])
    }

    @Test func aScreensNameAndDeviceRoundTrip() throws {
        // Ruling M2: in createSurface.metadata.extensions.layer.
        var title = LayerNode(kind: .title)
        title.content.text = "Checkout"
        var screen = TreeScreen(name: "Checkout", origin: .zero, scale: 1, deviceID: "ipad-mini")
        screen.root.layout = .stack(.init(axis: .vertical, spacing: 24))
        screen.root.children = [title]

        let messages = A2UIExporter.messages(for: screen, surfaceID: "checkout")
        let create = try #require(messages.first?.object?["createSurface"]?.object)
        let layer = create["metadata"]?.object?["extensions"]?.object?["layer"]?.object
        #expect(layer?["name"]?.string == "Checkout")
        #expect(layer?["deviceID"]?.string == "ipad-mini")
        for message in messages {
            #expect(throws: Never.self) { _ = try AgentToRendererMessage.parseAll(message, protocolVersion: .v10) }
        }

        let result = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: screen, surfaceID: "checkout").utf8))
        #expect(result.diagnostics.isEmpty, "\(result.diagnostics)")
        let imported = try #require(result.screens.first)
        #expect(imported.name == "Checkout")
        #expect(imported.deviceID == "ipad-mini")
        Self.expectSame(imported.root, screen.root, isRoot: true)

        // A surface that doesn't say leaves both to the importer's caller.
        let plain = A2UIImporter.importJSON(Data(A2UIExporter.jsonLines(for: screen.root, surfaceID: "s").utf8))
        #expect(plain.screens.first?.name == nil)
        #expect(plain.screens.first?.deviceID == nil)
    }

    // MARK: - Helpers

    /// The components of the `updateComponents` message.
    private static func components(in messages: [OrderedJSON.JSONValue]) -> [[String: OrderedJSON.JSONValue]] {
        messages.compactMap { $0.object?["updateComponents"]?.object?["components"]?.array }.flatMap { $0 }
            .compactMap(\.object).map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key, $0.value) }) }
    }

    private static func screen(_ name: String) throws -> LayerNode {
        let url = try #require(Bundle(for: ExportBundleMarker.self).url(forResource: name, withExtension: "json"))
        let (content, _) = try TreeManifest.decode(try Data(contentsOf: url))
        return try #require(content.screens.first).root
    }

    /// Both trees the same in every node's kind, layout, padding, sizing, content, style and name,
    /// and in the frames of the children of free containers. Ids and `source` are ignored.
    private static func expectSame(_ got: LayerNode, _ want: LayerNode, isRoot: Bool = false, path: String = "root") {
        #expect(got.kind == want.kind, "\(path) kind")
        #expect(got.resolvedLayout == want.resolvedLayout, "\(path) layout")
        if !isRoot { #expect(got.padding == want.padding, "\(path) padding") }
        #expect(got.width == want.width, "\(path) width")
        #expect(got.height == want.height, "\(path) height")
        #expect(got.content == want.content, "\(path) content")
        #expect(got.style == want.style, "\(path) style")
        #expect(got.name == want.name, "\(path) name")
        let visible = want.children.filter { !$0.isHidden && $0.kind != .drawing }
        #expect(got.children.count == visible.count, "\(path) children")
        for (index, (a, b)) in zip(got.children, visible).enumerated() {
            if want.resolvedLayout == .free {
                #expect(a.frame == b.frame, "\(path)/\(index) frame")
                #expect(a.rotation == b.rotation, "\(path)/\(index) rotation")
            }
            expectSame(a, b, path: "\(path)/\(index)")
        }
    }
}

private final class ExportBundleMarker {}

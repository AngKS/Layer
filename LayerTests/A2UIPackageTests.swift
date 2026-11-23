import A2UICore
import BasicCatalog
import Foundation
import OrderedJSON
import Testing
@testable import Layer

@Suite("A2UI package")
struct A2UIPackageTests {
    /// Strict A2UI 1.0: no unknown component or property passes.
    private static let strict = ValidationConfig(protocolVersion: .v10)

    private static let basicNames: Set<String> = [
        "Text", "Image", "Icon", "Video", "AudioPlayer", "Row", "Column", "List", "Card", "Tabs",
        "Modal", "Divider", "Button", "TextField", "CheckBox", "ChoicePicker", "Slider", "DateTimeInput",
    ]

    /// One valid component of each of Layer's own types, carrying Layer's look as A2UI metadata.
    private static let layerSamples: [[String: OrderedJSON.JSONValue]] = [
        ["id": "grid", "component": "LayerGrid", "children": ["a", "b", "c"], "columns": 2,
         "columnSpacing": 12, "rowSpacing": 8, "weight": 1,
         "@metadata": ["extensions": ["layer": ["kind": "group", "name": "Gallery"]]],
         "@accessibility": ["label": "Gallery"]],
        ["id": "overlay", "component": "LayerOverlay", "children": ["a", "b"], "horizontal": "start",
         "vertical": "end"],
        ["id": "free", "component": "LayerFree", "children": ["a"]],
        ["id": "toggle", "component": "LayerToggle", "label": "Wi-Fi", "value": true],
        ["id": "radio", "component": "LayerRadio", "label": "Small", "value": ["@path": "/size/small"]],
        ["id": "progress", "component": "LayerProgress", "value": 0.4],
        ["id": "symbol", "component": "LayerSymbol", "name": "star.fill"],
        ["id": "shape", "component": "LayerShape", "shape": "roundedRectangle", "filled": true],
    ]

    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    @Test func theOfficialLoginExampleParsesAndValidates() throws {
        let file = try JSONDecoder().decode(
            OrderedJSON.JSONValue.self, from: try Self.fixture("a2ui-scaffold-simple-login-form"))
        let messages = try #require(file.objectValue?["messages"])
        let parsed = try AgentToRendererMessage.parseAll(
            from: try JSONEncoder().encode(messages), protocolVersion: .v10)

        #expect(parsed.count == 2)
        guard case .createSurface(let create) = parsed.first,
              case .updateComponents(let update) = parsed.last else {
            Issue.record("Expected a createSurface then an updateComponents, got \(parsed)")
            return
        }
        #expect(create.catalogID == LayerCatalog.basicID)
        #expect(update.surfaceID == create.surfaceID)
        #expect(update.components.count == 6)

        let validator = PayloadValidator(catalog: LayerCatalog.catalog, config: Self.strict)
        for component in update.components {
            #expect(throws: Never.self, "\(component["id"] ?? "no id")") {
                try validator.validateComponent(component)
            }
        }
    }

    @Test func layersCatalogHasItsComponents() throws {
        let catalog = LayerCatalog.catalog
        let names = Set(catalog.components.keys)

        #expect(catalog.id == "urn:layer:a2ui:catalog:1")
        #expect(catalog.protocolVersion == A2UIProtocolVersion.v10.rawValue)
        #expect(LayerCatalog.basicID == "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json")
        #expect(Set(BasicCatalog.makeCatalog(version: .v10).components.keys) == Self.basicNames)
        #expect(Self.basicNames.isSubset(of: names))
        #expect(Set(LayerCatalog.componentNames).isSubset(of: names))
        #expect(names.count == 18 + 8)
        // The Basic Catalog's functions stay, so components that call them still validate.
        #expect(catalog.functions["formatString"] != nil)

        for name in LayerCatalog.componentNames {
            let schema = try #require(catalog.components[name]?.schema.jsonValue)
            #expect(schema["/type"] == "object", "\(name)")
            #expect(schema["/properties/component/const"] == .string(name), "\(name)")
            #expect(schema["/unevaluatedProperties"] == false, "\(name)")
        }
    }

    @Test func aLayerGridsChildrenAreFound() {
        for type in ["LayerGrid", "LayerOverlay", "LayerFree"] {
            let container: [String: OrderedJSON.JSONValue] = [
                "id": "box", "component": .string(type), "children": ["first", "second", "third"],
            ]
            let schema = LayerCatalog.catalog.components[type]?.schema.jsonValue
            let references = GraphTopologyValidator.extractReferences(from: container, schema: schema)
            #expect(references.map(\.referenceID) == ["first", "second", "third"], "\(type)")
            #expect(references.map(\.field) == ["children[0]", "children[1]", "children[2]"], "\(type)")
        }
    }

    @Test func anUnknownPropertyFailsStrictValidation() throws {
        let validator = PayloadValidator(catalog: LayerCatalog.catalog, config: Self.strict)
        var grid = Self.layerSamples[0]
        try validator.validateComponent(grid)

        grid["colour"] = "red"
        let error = #expect(throws: A2UIValidationError.self) {
            try validator.validateComponent(grid)
        }
        #expect(error?.details.map(\.path) == ["colour"])
    }

    @Test func valuesOutsideTheirRangesFailStrictValidation() {
        let validator = PayloadValidator(catalog: LayerCatalog.catalog, config: Self.strict)
        // Each with the property the validator should name.
        let invalid: [(String, [String: OrderedJSON.JSONValue])] = [
            ("columns", ["id": "g", "component": "LayerGrid", "children": [], "columns": 0]),
            ("columns", ["id": "g", "component": "LayerGrid", "children": [], "columns": 13]),
            ("columns", ["id": "g", "component": "LayerGrid", "children": [], "columns": 2.5]),
            ("rowSpacing", ["id": "g", "component": "LayerGrid", "children": [], "columns": 2, "rowSpacing": -1]),
            ("vertical", ["id": "o", "component": "LayerOverlay", "children": [], "vertical": "middle"]),
            ("value", ["id": "p", "component": "LayerProgress", "value": 1.5]),
            ("shape", ["id": "s", "component": "LayerShape", "shape": "blob"]),
            ("value", ["id": "t", "component": "LayerToggle", "label": "On"]),
        ]
        for (path, component) in invalid {
            let error = #expect(throws: A2UIValidationError.self, "\(component)") {
                try validator.validateComponent(component)
            }
            #expect(error?.details.map(\.path) == [path], "\(component)")
        }
    }

    @Test func theCatalogIsSendable() async {
        let catalog = LayerCatalog.catalog
        let components: [[String: OrderedJSON.JSONValue]] = (0..<100).map { index in
            var component = Self.layerSamples[index % Self.layerSamples.count]
            component["id"] = .string("component_\(index)")
            return component
        }
        let config = Self.strict
        // Each task returns what failed: a detached task doesn't carry the test's context for Issue.record.
        let tasks = (0..<4).map { _ in
            Task.detached { () -> (valid: Int, failures: [String]) in
                let validator = PayloadValidator(catalog: catalog, config: config)
                var valid = 0
                var failures: [String] = []
                for component in components {
                    do {
                        try validator.validateComponent(component)
                        valid += 1
                    } catch {
                        failures.append("\(component["id"] ?? "no id"): \(error)")
                    }
                }
                return (valid, failures)
            }
        }
        for task in tasks {
            let result = await task.value
            #expect(result.valid == 100)
            #expect(result.failures.isEmpty, "\(result.failures.joined(separator: "; "))")
        }
    }
}

private final class BundleMarker {}

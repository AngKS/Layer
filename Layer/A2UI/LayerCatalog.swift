import A2UICore
import A2UIJSON
import BasicCatalog
import JSONSchema

/// Layer's A2UI catalogue, used only where designs are imported and exported as A2UI 1.0.
///
/// It is the Basic Catalog 1.0, which every A2UI renderer can show, with Layer's own components
/// added for what the Basic Catalog has none for: grids, overlays, free placement, toggles,
/// radio buttons, progress bars, symbols and shapes. Other renderers can't show those, so a
/// Basic component is used wherever one fits. Layer's own look travels in each component's
/// `@metadata.extensions.layer`, which needs nothing here: the validator checks metadata itself.
enum LayerCatalog {
    static let id = "urn:layer:a2ui:catalog:1"

    /// The Basic Catalog 1.0's id, which the official examples and other agents name.
    static var basicID: String { BasicCatalog.catalogURI(version: .v10) }

    static let componentNames = ["LayerGrid", "LayerOverlay", "LayerFree", "LayerToggle",
                                 "LayerRadio", "LayerProgress", "LayerSymbol", "LayerShape"]

    /// The Basic Catalog 1.0 with Layer's components added; built once, Sendable.
    static let catalog: AnyCatalog = {
        let basic = BasicCatalog.makeCatalog(version: .v10)
        let kept = basic.components.keys.map { DerivedCatalogEntry<AnyComponentAPI>.keep($0) }
        do {
            // Every Basic component and function is kept, so anything the Basic Catalog accepts
            // is accepted here too. The functions are there to be validated, never called: this
            // shared Basic Catalog has no URL handler, so even its openUrl can't open anything.
            return try basic.derive(id: id, components: kept + layerComponents.map { .add($0) })
        } catch {
            preconditionFailure("Layer's A2UI catalogue can't be built: \(error)")
        }
    }()

    private static let layerComponents = [
        component("LayerGrid", "Children in a grid of equal columns, filled row by row.",
                  required: ["children", "columns"], properties: """
            "children": { "$ref": "\(ref("ChildList"))" },
            "columns": { "type": "integer", "minimum": 1, "maximum": 12 },
            "columnSpacing": { "type": "number", "minimum": 0 },
            "rowSpacing": { "type": "number", "minimum": 0 }
            """),
        component("LayerOverlay", "Children stacked back to front, each aligned in the overlay.",
                  required: ["children"], properties: """
            "children": { "$ref": "\(ref("ChildList"))" },
            "horizontal": { "type": "string", "enum": ["start", "center", "end"], "default": "center" },
            "vertical": { "type": "string", "enum": ["start", "center", "end"], "default": "center" }
            """),
        component("LayerFree", "Children placed where they were put, as in a sketch.",
                  required: ["children"], properties: """
            "children": { "$ref": "\(ref("ChildList"))" }
            """),
        component("LayerToggle", "An on/off switch with a label.",
                  required: ["label", "value"], properties: """
            "label": { "$ref": "\(ref("DynamicString"))" },
            "value": { "$ref": "\(ref("DynamicBoolean"))" }
            """),
        component("LayerRadio", "A radio button with a label: one choice of several.",
                  required: ["label", "value"], properties: """
            "label": { "$ref": "\(ref("DynamicString"))" },
            "value": { "$ref": "\(ref("DynamicBoolean"))" }
            """),
        component("LayerProgress", "A progress bar, from 0 (none) to 1 (done).",
                  required: ["value"], properties: """
            "value": { "type": "number", "minimum": 0, "maximum": 1 }
            """),
        component("LayerSymbol", "An SF Symbol, by name.",
                  required: ["name"], properties: """
            "name": { "type": "string" }
            """),
        component("LayerShape", "A shape that stretches to fill its frame.",
                  required: ["shape"], properties: """
            "shape": { "type": "string", "enum": [\(quoted(ShapeKind.allCases.map(\.rawValue)))] },
            "filled": { "type": "boolean" }
            """),
    ]

    /// A flat component schema: `component` names it, `weight` is taken as by every Basic
    /// component, and any other property is refused. `id` and the `@` mixins are checked by the
    /// validator itself, so they aren't declared.
    private static func component(
        _ name: String, _ description: String, required: [String], properties: String
    ) -> AnyComponentAPI {
        let schema = """
            {
              "type": "object",
              "description": "\(description)",
              "properties": {
                "component": { "const": "\(name)" },
                \(properties),
                "weight": { "type": "number" }
              },
              "required": [\(quoted(["component"] + required))],
              "unevaluatedProperties": false
            }
            """
        do {
            return AnyComponentAPI(
                name: name, schema: try Schema(instance: schema, remoteSchemas: A2UICommonSchema.allSchemas))
        } catch {
            preconditionFailure("The \(name) schema can't be read: \(error)")
        }
    }

    /// A type from the A2UI 1.0 common types. Child slots must be declared through these, or
    /// `GraphTopologyValidator.extractReferences` won't find the children.
    private static func ref(_ name: String) -> String {
        A2UICommonSchema.v10URI(for: name)
    }

    private static func quoted(_ strings: [String]) -> String {
        strings.map { "\"\($0)\"" }.joined(separator: ", ")
    }
}

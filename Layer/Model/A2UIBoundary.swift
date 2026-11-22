import Foundation
import CoreGraphics

/// Import-only boundary for official A2UI v1.0 documents.
/// Agent actions and RPC are deliberately not executed. Imports are converted to the
/// canonical LayerNode model before anything reaches the editor hot path.
enum A2UIBoundary {
    struct Diagnostic: Equatable, Sendable {
        var message: String
    }

    struct ImportResult: Equatable, Sendable {
        var roots: [LayerNode]
        var diagnostics: [Diagnostic]
    }

    static func importJSON(_ data: Data) -> ImportResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ImportResult(roots: [], diagnostics: [Diagnostic(message: "Invalid JSON")])
        }
        var diagnostics: [Diagnostic] = []
        let roots = findComponentArrays(in: object).flatMap { array in
            array.enumerated().compactMap { _, value in
                mapComponent(value as? [String: Any] ?? [:], diagnostics: &diagnostics)
            }
        }
        if roots.isEmpty, diagnostics.isEmpty {
            diagnostics.append(Diagnostic(message: "No supported A2UI components found"))
        }
        return ImportResult(roots: roots, diagnostics: diagnostics)
    }

    private static func findComponentArrays(in object: [String: Any]) -> [[Any]] {
        var found: [[Any]] = []
        for (key, value) in object where key == "components" || key == "children" {
            if let array = value as? [Any] { found.append(array) }
        }
        for value in object.values {
            if let nested = value as? [String: Any] {
                found += findComponentArrays(in: nested)
            } else if let array = value as? [[String: Any]] {
                for item in array {
                    found += findComponentArrays(in: item)
                }
            }
        }
        return found
    }

    private static func mapComponent(_ component: [String: Any], diagnostics: inout [Diagnostic]) -> LayerNode? {
        let name = (component["component"] as? String)
            ?? (component["type"] as? String)
            ?? ""
        let kind: LayerNode.Kind
        let layoutKind: LayerNode.LayoutKind
        switch name {
        case "Text", "text": kind = .text; layoutKind = .leaf
        case "Button", "button": kind = .button; layoutKind = .leaf
        case "TextField", "textField": kind = .textField; layoutKind = .leaf
        case "Image", "image": kind = .image; layoutKind = .leaf
        case "Icon", "icon": kind = .icon; layoutKind = .leaf
        case "Divider", "divider": kind = .divider; layoutKind = .leaf
        case "Row", "row": kind = .row; layoutKind = .row
        case "Column", "column": kind = .column; layoutKind = .column
        case "Card", "card": kind = .card; layoutKind = .card
        case "Grid", "LayerGrid": kind = .grid; layoutKind = .grid
        case "Overlay", "LayerOverlay": kind = .overlay; layoutKind = .overlay
        default:
            diagnostics.append(Diagnostic(message: "Unsupported A2UI component: \(name.isEmpty ? "<missing>" : name)"))
            return nil
        }

        var props = LayerNode.Props()
        props.text = (component["text"] as? String) ?? (component["value"] as? String)
        props.placeholder = component["placeholder"] as? String
        props.symbolName = component["icon"] as? String
        var children: [LayerNode] = []
        if let nested = component["children"] as? [Any] {
            for value in nested {
                if let child = mapComponent(value as? [String: Any] ?? [:], diagnostics: &diagnostics) {
                    children.append(child)
                }
            }
        }
        let columns = (component["columns"] as? Int) ?? 1
        let spacing = (component["spacing"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 12
        let layout = LayerNode.LayoutSpec(
            kind: layoutKind,
            width: .init(sizing: .fill),
            height: .init(sizing: .intrinsic),
            spacing: spacing,
            columns: columns
        )
        return LayerNode(
            kind: kind,
            role: kind == .button ? "button" : nil,
            accessibilityLabel: props.text,
            name: component["id"] as? String,
            children: children,
            props: props,
            layout: layout
        )
    }
}

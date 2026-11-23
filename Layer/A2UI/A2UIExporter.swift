import CoreGraphics
import Foundation
import OrderedJSON
import os

/// Writes a screen's tree as A2UI 1.0 (spec §6, "A2UI export"): the import table read backwards.
///
/// - A node becomes a Basic Catalog component wherever one fits, so another A2UI renderer can
///   show the screen: Column, Row, Card, Text, Button, TextField, CheckBox, Image and Divider.
///   Layer's own components (`LayerGrid`, `LayerOverlay`, `LayerFree`, `LayerToggle`, `LayerRadio`,
///   `LayerProgress`, `LayerSymbol`, `LayerShape`) cover what the Basic Catalog has none for.
/// - A card is a `Card` whose `child` is the container for its own layout, holding the card's
///   children: one extra component, but no extra node, and the importer reads it back as one card.
/// - A free screen root is a `LayerFree`, and any other root a `Column`, which the importer reads
///   as the screen root; a root that is a grid or an overlay is a Column whose `layout` says so.
/// - Layer's own look is in every component's `@metadata.extensions.layer`, in the shapes
///   `LayerNode` is saved in. A Column or Row has no spacing, so a container's `layout` is there
///   too, and a node's `frame` (as `[x, y, width, height]`) and `rotation` when its parent is free.
/// - Hidden nodes and drawings are left out. A button's action is an inert event that is never run.
/// - A screen's name and device, when given, are in `createSurface.metadata.extensions.layer`,
///   which the importer reads back.
///
/// It is plain values, so it runs off the main actor.
enum A2UIExporter {
    /// `createSurface` (catalogue `LayerCatalog.id`, and the screen's `name` and `deviceID` in its
    /// metadata when given), then one `updateComponents` holding every component.
    static func messages(for root: LayerNode, surfaceID: String, name: String? = nil,
                         deviceID: String? = nil) -> [OrderedJSON.JSONValue] {
        var writer = Writer()
        writer.write(root, id: "root", parent: nil)
        var surface: [String: Any] = ["surfaceId": surfaceID, "catalogId": LayerCatalog.id]
        var screen: [String: Any] = [:]
        if let name { screen["name"] = name }
        if let deviceID { screen["deviceID"] = deviceID }
        if !screen.isEmpty { surface["metadata"] = ["extensions": ["layer": screen]] }
        let created: [String: Any] = ["version": "1.0", "createSurface": surface]
        let updated: [String: Any] = [
            "version": "1.0",
            "updateComponents": ["surfaceId": surfaceID, "components": writer.components] as [String: Any],
        ]
        return [created, updated].map(Self.value)
    }

    /// A screen's messages: its root, with its name and device.
    static func messages(for screen: TreeScreen, surfaceID: String) -> [OrderedJSON.JSONValue] {
        messages(for: screen.root, surfaceID: surfaceID, name: screen.name, deviceID: screen.deviceID)
    }

    /// The same messages, one on each line.
    static func jsonLines(for root: LayerNode, surfaceID: String, name: String? = nil, deviceID: String? = nil) -> String {
        lines(messages(for: root, surfaceID: surfaceID, name: name, deviceID: deviceID))
    }

    /// A screen's messages, one on each line.
    static func jsonLines(for screen: TreeScreen, surfaceID: String) -> String {
        lines(messages(for: screen, surfaceID: surfaceID))
    }

    /// The screen's messages as one JSON array, pretty-printed: a file the importer, and other A2UI tools,
    /// read whole. It carries the screen's name and deviceID.
    static func document(for screen: TreeScreen, surfaceID: String) -> Data {
        #if DEBUG
        written.withLock { $0[surfaceID, default: 0] += 1 }
        #endif
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return (try? encoder.encode(OrderedJSON.JSONValue.array(messages(for: screen, surfaceID: surfaceID)))) ?? Data("[]".utf8)
    }

    #if DEBUG
    /// Documents written for this surface id, counted under a lock: tests count per surface.
    static func documentsWritten(for surfaceID: String) -> Int { written.withLock { $0[surfaceID] ?? 0 } }

    private static let written = OSAllocatedUnfairLock(initialState: [String: Int]())
    #endif

    private static func lines(_ messages: [OrderedJSON.JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return messages
            .compactMap { try? encoder.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) }
            .joined(separator: "\n")
    }

    /// Plain Foundation JSON as the SDK's value, read back as every A2UI text is read
    /// (`A2UIImporter.decodeJSON`). Every number put in is finite, so this can't fail.
    private static func value(_ object: [String: Any]) -> OrderedJSON.JSONValue {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              case .value(let value) = A2UIImporter.decodeJSON(data) else { return .null }
        return value
    }

    /// The id of every component but the root: "n_" and the node's UUID in lower-case hex.
    fileprivate static func id(of node: LayerNode) -> String {
        "n_" + node.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private typealias JSONObject = [String: Any]

private struct Writer {
    /// In the order they are written: each node's component, then what it holds.
    var components: [JSONObject] = []

    /// What a parent tells its child: where it is placed, and along which axis a weight counts.
    struct Parent {
        var isFree: Bool
        var axis: LayerNode.Axis?
    }

    mutating func write(_ node: LayerNode, id: String, parent: Parent?) {
        let children = node.children.filter { !$0.isHidden && $0.kind != .drawing }
        var component = self.component(for: node, id: id, children: children, parent: parent)
        let layout = node.resolvedLayout
        let own = Parent(isFree: layout == .free, axis: layout.axis)
        var extra: [JSONObject] = []
        if node.kind == .card {
            // The card's layout is its child's component, which holds the card's children.
            let inner = id + "_layout"
            component["child"] = inner
            extra.append(container(layout, id: inner, children: children))
        }
        if node.kind == .button {
            // The words are a Text child's, as the Basic Catalog's Button has it.
            extra.append(text(node.content.text, id: id + "_label"))
        }
        components.append(component)
        components += extra
        for child in children {
            write(child, id: A2UIExporter.id(of: child), parent: own)
        }
    }

    // MARK: Components

    private func component(for node: LayerNode, id: String, children: [LayerNode], parent: Parent?) -> JSONObject {
        var component: JSONObject
        switch node.kind {
        case .group:
            // A screen root is a Column or a LayerFree, which the importer reads as the screen root.
            let layout = node.resolvedLayout
            if parent == nil, !layout.isFree, layout.axis == nil {
                component = container(.stack(.init(axis: .vertical)), id: id, children: children)
            } else {
                component = container(layout, id: id, children: children)
            }
        case .card:
            component = ["id": id, "component": "Card"]
        case .title:
            component = text("# " + node.content.text, id: id)
        case .body, .text, .stickyNote:
            component = text(node.content.text, id: id)
        case .button:
            let label = id + "_label"
            component = ["id": id, "component": "Button", "child": label,
                         "variant": variant(of: node.content.buttonLook),
                         "action": ["event": ["name": A2UIImporter.layerActionName]]]
        case .textField:
            component = ["id": id, "component": "TextField", "label": node.content.text, "value": ""]
        case .checkbox:
            component = ["id": id, "component": "CheckBox", "label": node.name ?? "", "value": node.content.isOn]
        case .toggle, .radio:
            component = ["id": id, "component": node.kind == .toggle ? "LayerToggle" : "LayerRadio",
                         "label": node.name ?? "", "value": node.content.isOn]
        case .progress:
            component = ["id": id, "component": "LayerProgress", "value": Self.fraction(node.content.value)]
        case .symbol:
            component = ["id": id, "component": "LayerSymbol", "name": node.content.symbol ?? SystemSymbol.placeholder]
        case .shape:
            component = ["id": id, "component": "LayerShape",
                         "shape": (node.content.shape ?? .rectangle).rawValue, "filled": node.content.isOn]
        case .image, .avatar:
            component = ["id": id, "component": "Image", "url": ""]
            if node.kind == .avatar { component["variant"] = "avatar" }
            if let name = node.name, !name.isEmpty { component["description"] = name }
        case .divider:
            component = ["id": id, "component": "Divider"]
        case .drawing:
            // Never written: drawings are filtered out. A node in its place keeps this total.
            component = ["id": id, "component": "Divider"]
        }
        if let weight = weight(of: node, in: parent) { component["weight"] = weight }
        component["@metadata"] = ["extensions": ["layer": look(of: node, parent: parent)]]
        return component
    }

    /// The component a layout is written as, holding `children`.
    private func container(_ layout: LayerNode.Layout, id: String, children: [LayerNode]) -> JSONObject {
        let ids = children.map(A2UIExporter.id(of:))
        switch layout {
        case .stack(let stack):
            return ["id": id, "component": stack.axis == .horizontal ? "Row" : "Column", "children": ids,
                    "justify": stack.justify.rawValue, "align": stack.alignment == .fill ? "stretch" : stack.alignment.rawValue]
        case .grid(let grid):
            return ["id": id, "component": "LayerGrid", "children": ids, "columns": min(max(grid.columns, 1), 12),
                    "columnSpacing": Self.length(grid.columnSpacing), "rowSpacing": Self.length(grid.rowSpacing)]
        case .overlay(let alignment):
            return ["id": id, "component": "LayerOverlay", "children": ids,
                    "horizontal": alignment.horizontal.rawValue, "vertical": alignment.vertical.rawValue]
        case .free:
            return ["id": id, "component": "LayerFree", "children": ids]
        }
    }

    private func text(_ words: String, id: String) -> JSONObject {
        ["id": id, "component": "Text", "text": words]
    }

    /// A button's variant. A button with no look is filled, the screen's primary action, so it is
    /// `primary` too.
    private func variant(of look: ButtonLook?) -> String {
        switch look {
        case .filled, nil: "primary"
        case .bordered: "default"
        case .plain: "borderless"
        }
    }

    /// A child's weight in a row or column: its share along the axis, when it fills.
    private func weight(of node: LayerNode, in parent: Parent?) -> Double? {
        guard let axis = parent?.axis else { return nil }
        let sizing = axis == .horizontal ? node.width : node.height
        if case .fill(let weight) = sizing.mode, weight.isFinite, weight > 0 { return Double(weight) }
        return nil
    }

    // MARK: Layer's look

    /// `@metadata.extensions.layer`, in the shapes `LayerNode` is saved in. A value that can't be
    /// written as JSON (a number that isn't finite) is left out, and the importer's default stands.
    private func look(of node: LayerNode, parent: Parent?) -> JSONObject {
        var look: JSONObject = ["kind": node.kind.rawValue, "content": content(of: node.content)]
        if let name = node.name { look["name"] = name }
        look["style"] = Self.json(node.style)
        look["width"] = Self.json(node.width)
        look["height"] = Self.json(node.height)
        look["padding"] = Self.json(node.padding)
        if node.isContainer { look["layout"] = Self.json(node.resolvedLayout) }
        if parent?.isFree == true {
            let frame = node.frame
            let numbers = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
            if numbers.allSatisfy(\.isFinite) { look["frame"] = numbers.map(Double.init) }
            if let rotation = node.rotation, rotation.isFinite { look["rotation"] = rotation }
        }
        return look.filter { !($0.value is NSNull) }
    }

    /// A node's content under the keys a design saves it with, leaving out what is the default.
    private func content(of content: LayerNode.Content) -> JSONObject {
        var written: JSONObject = [:]
        if !content.text.isEmpty { written["text"] = content.text }
        if let symbol = content.symbol { written["symbol"] = symbol }
        if let shape = content.shape { written["shape"] = shape.rawValue }
        if let imageID = content.imageID { written["imageID"] = imageID.uuidString }
        if !content.isOn { written["isOn"] = false }
        if let value = content.value, value.isFinite { written["value"] = value }
        if let look = content.buttonLook { written["buttonLook"] = look.rawValue }
        return written
    }

    private static func json<Value: Encodable>(_ value: Value) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return NSNull() }
        return object
    }

    /// A spacing that is a number and not negative; anything else is 0.
    private static func length(_ value: CGFloat) -> Double {
        value.isFinite ? max(Double(value), 0) : 0
    }

    private static func fraction(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

private extension LayerNode.Layout {
    var isFree: Bool { self == .free }

    /// The axis of a row or column; nil for grids, overlays and free groups.
    var axis: LayerNode.Axis? {
        if case .stack(let stack) = self { return stack.axis }
        return nil
    }
}

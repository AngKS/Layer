import Foundation
import CoreGraphics
import A2UICore

/// Import-only bridge for official A2UI v1.0 envelopes.
/// It intentionally has no action handler, outbound listener, or RPC execution.
enum A2UIBoundary {
    struct Diagnostic: Equatable, Sendable {
        var message: String
    }

    struct ImportResult: Equatable, Sendable {
        var roots: [LayerNode]
        var diagnostics: [Diagnostic]
    }

    static func importJSON(_ data: Data) -> ImportResult {
        var diagnostics: [Diagnostic] = []

        // Invoke the official decoder before applying the Layer-specific graph mapping.
        // MessageParser validates the A2UI envelope shape; it is never given an action handler.
        do {
            _ = try MessageParser().decode(jsonData: data)
        } catch {
            diagnostics.append(Diagnostic(message: "Official A2UI envelope validation failed: \(error.localizedDescription)"))
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ImportResult(roots: [], diagnostics: diagnostics + [Diagnostic(message: "Invalid JSON")])
        }
        let messageKeys = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface", "callRendererFunction", "agentFunctionResponse"]
        let present = messageKeys.filter { envelope[$0] != nil }
        guard present.count == 1, let payload = envelope[present[0]] as? [String: Any] else {
            diagnostics.append(Diagnostic(message: "Envelope must contain exactly one supported v1.0 message"))
            return ImportResult(roots: [], diagnostics: diagnostics)
        }

        switch present[0] {
        case "createSurface", "updateComponents":
            return mapEnvelope(payload, diagnostics: diagnostics)
        default:
            diagnostics.append(Diagnostic(message: "A2UI import ignores \(present[0]); no agent actions or RPC are executed"))
            return ImportResult(roots: [], diagnostics: diagnostics)
        }
    }

    private static func mapEnvelope(_ payload: [String: Any], diagnostics: [Diagnostic]) -> ImportResult {
        var diagnostics = diagnostics
        guard let components = payload["components"] as? [[String: Any]] else {
            diagnostics.append(Diagnostic(message: "V1.0 envelope is missing the flat components adjacency list"))
            return ImportResult(roots: [], diagnostics: diagnostics)
        }

        var byID: [String: [String: Any]] = [:]
        var duplicateIDs: Set<String> = []
        for component in components {
            guard let id = component["id"] as? String, !id.isEmpty else {
                diagnostics.append(Diagnostic(message: "A2UI component is missing a string id"))
                continue
            }
            if byID[id] != nil { duplicateIDs.insert(id) }
            byID[id] = component
        }
        for id in duplicateIDs.sorted() {
            diagnostics.append(Diagnostic(message: "Duplicate A2UI component id: \(id)"))
        }
        guard byID["root"] != nil else {
            diagnostics.append(Diagnostic(message: "Missing A2UI component with id \"root\""))
            return ImportResult(roots: [], diagnostics: diagnostics)
        }

        var visiting = Set<String>()
        var visited = Set<String>()
        var cache: [String: LayerNode] = [:]
        func resolve(_ id: String) -> LayerNode? {
            if let cached = cache[id] { return cached }
            guard let component = byID[id] else {
                diagnostics.append(Diagnostic(message: "Unresolved A2UI component reference: \(id)"))
                return nil
            }
            if visiting.contains(id) {
                diagnostics.append(Diagnostic(message: "A2UI component graph cycle at: \(id)"))
                return nil
            }
            visiting.insert(id)
            defer {
                visiting.remove(id)
                visited.insert(id)
            }
            let node = mapComponent(component, id: id, resolve: resolve, diagnostics: &diagnostics)
            cache[id] = node
            return node
        }
        let root = resolve("root")
        let rootNode = root.map { [$0] } ?? []
        if visited.count != byID.count {
            for id in byID.keys.sorted() where !visited.contains(id) {
                diagnostics.append(Diagnostic(message: "A2UI component is unreachable from root: \(id)"))
            }
        }
        return ImportResult(roots: rootNode, diagnostics: diagnostics)
    }

    private static func mapComponent(
        _ component: [String: Any],
        id: String,
        resolve: (String) -> LayerNode?,
        diagnostics: inout [Diagnostic]
    ) -> LayerNode? {
        let name = (component["component"] as? String) ?? ""
        let kind: LayerNode.Kind
        let layoutKind: LayerNode.LayoutKind
        switch name {
        case "Text": kind = .text; layoutKind = .leaf
        case "Button": kind = .button; layoutKind = .leaf
        case "TextField": kind = .textField; layoutKind = .leaf
        case "Image": kind = .image; layoutKind = .leaf
        case "Icon": kind = .icon; layoutKind = .leaf
        case "Divider": kind = .divider; layoutKind = .leaf
        case "Row": kind = .row; layoutKind = .row
        case "Column": kind = .column; layoutKind = .column
        case "Card": kind = .card; layoutKind = .card
        case "Grid", "LayerGrid": kind = .grid; layoutKind = .grid
        case "Overlay", "LayerOverlay": kind = .overlay; layoutKind = .overlay
        default:
            diagnostics.append(Diagnostic(message: "Unsupported A2UI component: \(name.isEmpty ? "<missing>" : name)"))
            return nil
        }

        var props = LayerNode.Props()
        if let text = component["text"] as? String {
            props.text = text
        } else if let textBinding = component["text"] as? [String: Any] {
            if let literal = textBinding["literal"] as? String { props.text = literal }
            else { diagnostics.append(Diagnostic(message: "Dynamic A2UI text binding is not executed: \(id)")) }
        }
        props.placeholder = component["placeholder"] as? String
        props.symbolName = component["icon"] as? String

        var childIDs: [String] = []
        if let child = component["child"] as? String {
            childIDs = [child]
        } else if let children = component["children"] as? [Any] {
            for item in children {
                if let childID = item as? String { childIDs.append(childID) }
                else {
                    diagnostics.append(Diagnostic(message: "A2UI template/object children are unsupported: \(id)"))
                }
            }
        }

        let children = childIDs.compactMap(resolve)
        let columns = (component["columns"] as? Int) ?? 1
        let spacing = (component["spacing"] as? NSNumber).map { CGFloat(truncating: $0) } ?? 12
        let layout = LayerNode.LayoutSpec(
            kind: layoutKind,
            width: .init(sizing: .fill),
            height: .init(sizing: .intrinsic),
            spacing: spacing,
            columns: max(1, columns)
        )
        var style = LayerNode.Style()
        if let corner = component["cornerRadius"] as? NSNumber {
            style.cornerRadius = CGFloat(truncating: corner)
        }
        let label = (component["@accessibility"] as? [String: Any])?["label"] as? String
        return LayerNode(
            id: stableUUID(id),
            kind: kind,
            role: kind == .button ? "button" : nil,
            accessibilityLabel: label ?? props.text,
            name: id,
            externalID: id,
            children: children,
            props: props,
            style: style,
            layout: layout
        )
    }

    private static func stableUUID(_ value: String) -> UUID {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        var bytes = withUnsafeBytes(of: hash.bigEndian) { Array($0) }
        while bytes.count < 16 { bytes.append(contentsOf: bytes.prefix(min(16 - bytes.count, bytes.count))) }
        bytes = Array(bytes.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x40
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.dropFirst(20).prefix(12))
        return UUID(uuidString: "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)") ?? UUID()
    }
}

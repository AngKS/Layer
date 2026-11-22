import CoreGraphics
import Foundation

/// A semantic UI node. Frames are resolved snapshots; hierarchy and layout constraints
/// are the document truth. This type is intentionally independent of A2UI messages.
struct LayerNode: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case text, title, body, button, textField, image, icon, divider
        case row, column, card, grid, overlay
        case shape, drawing, freeform
    }

    enum LayoutKind: String, Codable, Sendable {
        case leaf, column, row, card, grid, overlay
    }

    enum Sizing: String, Codable, Sendable {
        case intrinsic, fill, fixed, fractional
    }

    enum Alignment: String, Codable, Sendable {
        case leading, center, trailing, top, bottom, fill
    }

    struct SizeSpec: Equatable, Codable, Sendable {
        var sizing: Sizing = .intrinsic
        var value: CGFloat?
        var fraction: CGFloat?
        var minimum: CGFloat?
        var maximum: CGFloat?
    }

    struct LayoutSpec: Equatable, Codable, Sendable {
        var kind: LayoutKind = .leaf
        var width = SizeSpec()
        var height = SizeSpec()
        var alignment: Alignment = .leading
        var padding = CGFloat.zero
        var spacing = CGFloat.zero
        var columns = 1
        var safeArea = true
        var scrolls = false
    }

    struct SketchIntent: Equatable, Codable, Sendable {
        var originalBounds: CGRect?
        var normalizedBounds: CGRect?
        var provenance: String
        var confidence: Double
        var placementIsAuthoritative: Bool
    }

    struct Props: Equatable, Codable, Sendable {
        var text: String?
        var placeholder: String?
        var symbolName: String?
        var imageID: UUID?
        var buttonStyle: String?
        var value: Double?
    }

    struct Style: Equatable, Codable, Sendable {
        var tint: RGBColor?
        var textColor: RGBColor?
        var fontSize: CGFloat?
        var cornerRadius: CGFloat?
        var opacity: Double?
        var borderWidth: CGFloat?
    }

    var id: UUID
    var kind: Kind
    var role: String?
    var accessibilityLabel: String?
    var name: String?
    var children: [LayerNode]
    var props: Props
    var style: Style
    var layout: LayoutSpec
    var sketchIntent: SketchIntent?
    var resolvedFrame: CGRect?
    var isLocked = false
    var zIndex: Int

    init(
        id: UUID = UUID(),
        kind: Kind,
        role: String? = nil,
        accessibilityLabel: String? = nil,
        name: String? = nil,
        children: [LayerNode] = [],
        props: Props = Props(),
        style: Style = Style(),
        layout: LayoutSpec = LayoutSpec(),
        sketchIntent: SketchIntent? = nil,
        resolvedFrame: CGRect? = nil,
        isLocked: Bool = false,
        zIndex: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.role = role
        self.accessibilityLabel = accessibilityLabel
        self.name = name
        self.children = children
        self.props = props
        self.style = style
        self.layout = layout
        self.sketchIntent = sketchIntent
        self.resolvedFrame = resolvedFrame
        self.isLocked = isLocked
        self.zIndex = zIndex
    }

    var isContainer: Bool {
        switch kind {
        case .row, .column, .card, .grid, .overlay: true
        default: false
        }
    }
}

extension LayerNode {
    /// Converts existing flat editor elements without changing their IDs or user-authored frames.
    static func fromLegacy(_ element: DesignElement, screen: DesignScreen, provenance: String = "legacy") -> LayerNode {
        let kind: Kind = switch element.kind {
        case .title: .title
        case .body, .text: .text
        case .button: .button
        case .textField: .textField
        case .image, .avatar: .image
        case .symbol: .icon
        case .divider: .divider
        case .shape: .shape
        case .drawing: .drawing
        default: .freeform
        }
        let normalized = CGRect(
            x: element.frame.minX / screen.size.width,
            y: element.frame.minY / screen.size.height,
            width: element.frame.width / screen.size.width,
            height: element.frame.height / screen.size.height
        )
        var props = Props()
        props.text = element.text
        props.placeholder = element.kind.placeholder
        props.symbolName = element.symbol
        props.imageID = element.imageID
        props.buttonStyle = element.buttonLook?.rawValue
        props.value = element.value
        var style = Style()
        style.tint = element.tint
        style.textColor = element.textColor
        style.fontSize = element.fontSize
        style.cornerRadius = element.cornerRadius
        style.opacity = element.opacity
        style.borderWidth = element.borderWidth
        return LayerNode(
            id: element.id,
            kind: kind,
            role: kind == .button ? "button" : nil,
            accessibilityLabel: element.text.isEmpty ? nil : element.text,
            name: element.name,
            props: props,
            style: style,
            layout: LayoutSpec(
                kind: kind == .overlay ? .overlay : .leaf,
                width: SizeSpec(sizing: .fixed, value: element.frame.width),
                height: SizeSpec(sizing: .fixed, value: element.frame.height)
            ),
            sketchIntent: SketchIntent(
                originalBounds: element.frame,
                normalizedBounds: normalized,
                provenance: provenance,
                confidence: 1,
                placementIsAuthoritative: true
            ),
            resolvedFrame: element.frame,
            isLocked: element.isLocked
        )
    }

    /// Stable-ID reconcile for streamed/whole-screen generation. Existing nodes keep IDs;
    /// user-edited nodes are left untouched by late updates.
    static func reconcile(existing: [LayerNode], generated: [LayerNode]) -> [LayerNode] {
        var reusable: [String: [LayerNode]] = [:]
        for node in existing {
            reusable[reconcileKey(node), default: []].append(node)
        }
        var used = Set<UUID>()
        return generated.map { newNode in
            let key = reconcileKey(newNode)
            if let match = reusable[key]?.first(where: { !used.contains($0.id) }) {
                used.insert(match.id)
                var merged = newNode
                merged.id = match.id
                if match.isLocked { merged.isLocked = true }
                return merged
            }
            return newNode
        }
    }

    private static func reconcileKey(_ node: LayerNode) -> String {
        "\(node.kind.rawValue)|\(node.name ?? "")|\(node.props.text ?? node.props.symbolName ?? "")"
    }
}

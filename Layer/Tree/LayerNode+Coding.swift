import CoreGraphics
import Foundation

// How a node is saved. It reads every key but `id` and `kind` as optional, so a node written before a field existed still opens; keeps the keys it
// doesn't know, its own and those inside its parts (its style, layout, padding, sizing,
// accessibility, sketch and source); and reads its children one at a time, so one this
// version can't read doesn't stop the rest from opening. Optionals are left out when nil.
// A node's content is written among its own keys, apart from `ink`, which is saved apart.

extension LayerNode: KeepsUnknownKeys {
    enum CodingKeys: String, CodingKey {
        case id, kind, children, layout, padding, width, height, frame, rotation, scale
        case text, symbol, shape, imageID, isOn, value, buttonLook
        case style, name, isLocked, isHidden, accessibility, sketch, source, interaction
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(ElementKind.self, forKey: .kind)
        if container.contains(.children) {
            (children, unreadChildren) = try Self.readChildren(in: container)
        }
        layout = try container.decodeIfPresent(Layout.self, forKey: .layout)
        padding = try container.decodeIfPresent(Padding.self, forKey: .padding) ?? Padding()
        width = try container.decodeIfPresent(Sizing.self, forKey: .width) ?? Sizing(.fixed)
        height = try container.decodeIfPresent(Sizing.self, forKey: .height) ?? Sizing(.fixed)
        frame = try container.decodeIfPresent(CGRect.self, forKey: .frame) ?? .zero
        // Kept as any angle set here is: from 0 up to 360, none when upright or not a number.
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation).flatMap(Rotation.kept)
        scale = try container.decodeIfPresent(CGFloat.self, forKey: .scale)
        content.text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        content.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        content.shape = try container.decodeIfPresent(ShapeKind.self, forKey: .shape)
        content.imageID = try container.decodeIfPresent(UUID.self, forKey: .imageID)
        content.isOn = try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        content.value = try container.decodeIfPresent(Double.self, forKey: .value)
        content.buttonLook = try container.decodeIfPresent(ButtonLook.self, forKey: .buttonLook)
        style = try container.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        accessibility = try container.decodeIfPresent(Accessibility.self, forKey: .accessibility)
        sketch = try container.decodeIfPresent(SketchIntent.self, forKey: .sketch)
        source = try container.decodeIfPresent(Source.self, forKey: .source)
        interaction = try container.decodeIfPresent(JSONValue.self, forKey: .interaction)
        unknownKeys = try UnknownKeys(from: decoder, besides: CodingKeys.self)
        for part in Self.parts where container.contains(part) {
            guard let known = Self.keys(readIn: part, layout: layout),
                  let keys = try? UnknownKeys(from: container.superDecoder(forKey: part), besidesNamed: known),
                  !keys.values.isEmpty else { continue }
            unknownPartKeys[part.stringValue] = keys
        }
    }

    func encode(to encoder: any Encoder) throws {
        // The unknown keys go first, so that one the node now has a value for is replaced.
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        if !children.isEmpty || !unreadChildren.isEmpty {
            var list = container.nestedUnkeyedContainer(forKey: .children)
            try Self.write(children, with: unreadChildren, to: &list)
        }
        if let layout { try container.encode(part(layout, .layout), forKey: .layout) }
        if padding != Padding() || has(.padding) { try container.encode(part(padding, .padding), forKey: .padding) }
        if width != Sizing(.fixed) || has(.width) { try container.encode(part(width, .width), forKey: .width) }
        if height != Sizing(.fixed) || has(.height) { try container.encode(part(height, .height), forKey: .height) }
        if frame != .zero { try container.encode(frame, forKey: .frame) }
        try container.encodeIfPresent(rotation, forKey: .rotation)
        try container.encodeIfPresent(scale, forKey: .scale)
        if !content.text.isEmpty { try container.encode(content.text, forKey: .text) }
        try container.encodeIfPresent(content.symbol, forKey: .symbol)
        try container.encodeIfPresent(content.shape, forKey: .shape)
        try container.encodeIfPresent(content.imageID, forKey: .imageID)
        if !content.isOn { try container.encode(false, forKey: .isOn) }
        try container.encodeIfPresent(content.value, forKey: .value)
        try container.encodeIfPresent(content.buttonLook, forKey: .buttonLook)
        if style != Style() || has(.style) { try container.encode(part(style, .style), forKey: .style) }
        try container.encodeIfPresent(name, forKey: .name)
        if isLocked { try container.encode(true, forKey: .isLocked) }
        if isHidden { try container.encode(true, forKey: .isHidden) }
        if let accessibility { try container.encode(part(accessibility, .accessibility), forKey: .accessibility) }
        if let sketch { try container.encode(part(sketch, .sketch), forKey: .sketch) }
        if let source { try container.encode(part(source, .source), forKey: .source) }
        try container.encodeIfPresent(interaction, forKey: .interaction)
    }

    // MARK: What a newer Layer saved inside the parts

    /// The node's parts that are objects of their own, whose keys this version doesn't know are kept.
    private static let parts: [CodingKeys] = [.layout, .padding, .width, .height, .style, .accessibility, .sketch, .source]

    /// The keys this version reads in `part`: a layout's are its type's. Nil for a part that isn't one.
    private static func keys(readIn part: CodingKeys, layout: Layout?) -> Set<String>? {
        switch part {
        case .layout:
            switch layout {
            case .free?: ["type"]
            case .stack?: ["type", "axis", "spacing", "alignment", "justify"]
            case .grid?: ["type", "columns", "columnSpacing", "rowSpacing", "horizontal", "vertical"]
            case .overlay?: ["type", "horizontal", "vertical"]
            case nil: nil
            }
        case .padding: ["top", "leading", "bottom", "trailing"]
        case .width, .height: ["mode", "weight", "min", "max"]
        case .style:
            ["tint", "fontSize", "fontWeight", "textColor", "textAlignment", "cornerRadius", "opacity", "borderColor",
             "borderWidth", "hasShadow"]
        case .accessibility: ["label", "hint"]
        case .sketch: ["originalBounds", "normalizedBounds", "confidence", "decidedBy", "placement", "structureDeclined"]
        case .source: ["origin", "key"]
        default: nil
        }
    }

    /// Whether `part` held keys this version doesn't know.
    private func has(_ part: CodingKeys) -> Bool { unknownPartKeys[part.stringValue] != nil }

    /// `value` as `part` is saved: the keys it was read with but didn't know, then its own.
    private func part<Value: Encodable>(_ value: Value, _ part: CodingKeys) -> Part<Value> {
        Part(value: value, unknownKeys: unknownPartKeys[part.stringValue])
    }

    private struct Part<Value: Encodable>: Encodable {
        let value: Value
        let unknownKeys: UnknownKeys?

        func encode(to encoder: any Encoder) throws {
            try unknownKeys?.encode(to: encoder)
            try value.encode(to: encoder)
        }
    }

    /// Reads the children one at a time. One that can't be read comes back as unread, at
    /// its index in the list as it was saved.
    private static func readChildren(in container: KeyedDecodingContainer<CodingKeys>) throws -> ([LayerNode], [UnreadChild]) {
        var list = try container.nestedUnkeyedContainer(forKey: .children)
        return try read(from: &list)
    }

    /// Reads a list of nodes one at a time: a node's children, or the canvas's nodes. One that
    /// can't be read comes back as unread, at its index in the list as it was saved.
    static func read(from list: inout any UnkeyedDecodingContainer) throws -> ([LayerNode], [UnreadChild]) {
        var nodes: [LayerNode] = []
        var unread: [UnreadChild] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            // A failed read leaves the list where it was, so the same entry is read again as it is.
            if let node = try? list.decode(LayerNode.self) {
                nodes.append(node)
            } else {
                unread.append(UnreadChild(index: index, raw: try list.decode(JSONValue.self)))
            }
        }
        return (nodes, unread)
    }

    /// Writes a list of nodes, or screens, with those this build couldn't read among them. Each unread
    /// one goes at its index, or at the first place after it that is free when another has that index;
    /// one past the end of the list goes at the end. None is lost.
    static func write(_ nodes: [some Encodable], with unreadNodes: [UnreadChild], to list: inout any UnkeyedEncodingContainer) throws {
        let unread = unreadNodes.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
        var nextUnread = 0, nextNode = 0, position = 0
        while nextUnread < unread.count || nextNode < nodes.count {
            if nextUnread < unread.count, unread[nextUnread].index <= position || nextNode == nodes.count {
                try list.encode(unread[nextUnread].raw)
                nextUnread += 1
            } else {
                try list.encode(nodes[nextNode])
                nextNode += 1
            }
            position += 1
        }
    }
}

// MARK: - The parts

private enum LayoutKeys: String, CodingKey {
    case type, axis, spacing, alignment, justify, columns, columnSpacing, rowSpacing, horizontal, vertical
}

extension LayerNode.Layout {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: LayoutKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "free":
            self = .free
        case "stack":
            self = .stack(LayerNode.Stack(
                axis: try container.decode(LayerNode.Axis.self, forKey: .axis),
                spacing: try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 0,
                alignment: try container.decodeIfPresent(LayerNode.CrossAlignment.self, forKey: .alignment) ?? .start,
                justify: try container.decodeIfPresent(LayerNode.Justify.self, forKey: .justify) ?? .start))
        case "grid":
            self = .grid(LayerNode.Grid(
                columns: try container.decode(Int.self, forKey: .columns),
                columnSpacing: try container.decodeIfPresent(CGFloat.self, forKey: .columnSpacing) ?? 0,
                rowSpacing: try container.decodeIfPresent(CGFloat.self, forKey: .rowSpacing) ?? 0,
                alignment: try Self.alignment(in: container)))
        case "overlay":
            self = .overlay(try Self.alignment(in: container))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown layout \(other)")
        }
    }

    private static func alignment(in container: KeyedDecodingContainer<LayoutKeys>) throws -> LayerNode.Alignment {
        LayerNode.Alignment(
            horizontal: try container.decodeIfPresent(LayerNode.Edge3.self, forKey: .horizontal) ?? .center,
            vertical: try container.decodeIfPresent(LayerNode.Edge3.self, forKey: .vertical) ?? .center)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: LayoutKeys.self)
        switch self {
        case .free:
            try container.encode("free", forKey: .type)
        case .stack(let stack):
            try container.encode("stack", forKey: .type)
            try container.encode(stack.axis, forKey: .axis)
            try container.encode(stack.spacing, forKey: .spacing)
            try container.encode(stack.alignment, forKey: .alignment)
            try container.encode(stack.justify, forKey: .justify)
        case .grid(let grid):
            try container.encode("grid", forKey: .type)
            try container.encode(grid.columns, forKey: .columns)
            try container.encode(grid.columnSpacing, forKey: .columnSpacing)
            try container.encode(grid.rowSpacing, forKey: .rowSpacing)
            try container.encode(grid.alignment.horizontal, forKey: .horizontal)
            try container.encode(grid.alignment.vertical, forKey: .vertical)
        case .overlay(let alignment):
            try container.encode("overlay", forKey: .type)
            try container.encode(alignment.horizontal, forKey: .horizontal)
            try container.encode(alignment.vertical, forKey: .vertical)
        }
    }
}

extension LayerNode.Padding {
    private enum Keys: String, CodingKey { case top, leading, bottom, trailing }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(
            top: try container.decodeIfPresent(CGFloat.self, forKey: .top) ?? 0,
            leading: try container.decodeIfPresent(CGFloat.self, forKey: .leading) ?? 0,
            bottom: try container.decodeIfPresent(CGFloat.self, forKey: .bottom) ?? 0,
            trailing: try container.decodeIfPresent(CGFloat.self, forKey: .trailing) ?? 0)
    }
}

extension LayerNode.Sizing {
    private enum Keys: String, CodingKey { case mode, weight, min, max }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let mode: Mode
        switch try container.decodeIfPresent(String.self, forKey: .mode) ?? "fixed" {
        case "fit": mode = .fit
        case "fill": mode = .fill(weight: try container.decodeIfPresent(CGFloat.self, forKey: .weight) ?? 1)
        case "fixed": mode = .fixed
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .mode, in: container, debugDescription: "Unknown sizing \(other)")
        }
        self.init(mode,
                  minimum: try container.decodeIfPresent(CGFloat.self, forKey: .min),
                  maximum: try container.decodeIfPresent(CGFloat.self, forKey: .max))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch mode {
        case .fit: try container.encode("fit", forKey: .mode)
        case .fill(let weight):
            try container.encode("fill", forKey: .mode)
            try container.encode(weight, forKey: .weight)
        case .fixed: try container.encode("fixed", forKey: .mode)
        }
        try container.encodeIfPresent(minimum, forKey: .min)
        try container.encodeIfPresent(maximum, forKey: .max)
    }
}

extension LayerNode.Style {
    private enum Keys: String, CodingKey {
        case tint, fontSize, fontWeight, textColor, textAlignment, cornerRadius, opacity, borderColor, borderWidth, hasShadow
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init()
        tint = try container.decodeIfPresent(RGBColor.self, forKey: .tint)
        fontSize = try container.decodeIfPresent(CGFloat.self, forKey: .fontSize)
        fontWeight = try container.decodeIfPresent(FontWeightChoice.self, forKey: .fontWeight)
        textColor = try container.decodeIfPresent(RGBColor.self, forKey: .textColor)
        textAlignment = try container.decodeIfPresent(TextAlignmentChoice.self, forKey: .textAlignment)
        cornerRadius = try container.decodeIfPresent(CGFloat.self, forKey: .cornerRadius)
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity)
        borderColor = try container.decodeIfPresent(RGBColor.self, forKey: .borderColor)
        borderWidth = try container.decodeIfPresent(CGFloat.self, forKey: .borderWidth)
        hasShadow = try container.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? false
    }
}

extension LayerNode.SketchIntent {
    private enum Keys: String, CodingKey {
        case originalBounds, normalizedBounds, confidence, decidedBy, placement, structureDeclined
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        self.init(
            originalBounds: try container.decode(CGRect.self, forKey: .originalBounds),
            normalizedBounds: try container.decode(CGRect.self, forKey: .normalizedBounds),
            confidence: try container.decode(Double.self, forKey: .confidence),
            decidedBy: try container.decode(LayerNode.DecidedBy.self, forKey: .decidedBy),
            placement: try container.decode(LayerNode.PlacementIntent.self, forKey: .placement),
            structureDeclined: try container.decodeIfPresent(Bool.self, forKey: .structureDeclined) ?? false)
    }
}

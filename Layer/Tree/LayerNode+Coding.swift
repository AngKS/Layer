import CoreGraphics
import Foundation

// How a node is saved. Like `DesignElement`, it reads every key but `id` and `kind` as
// optional, so a node written before a field existed still opens; keeps the keys it
// doesn't know; and reads its children one at a time, so one this version can't read
// doesn't stop the rest from opening. Optionals are left out when nil. A node's content
// is written among its own keys, apart from `ink`, which is saved apart.

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
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation)
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
    }

    func encode(to encoder: any Encoder) throws {
        // The unknown keys go first, so that one the node now has a value for is replaced.
        try unknownKeys.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        if !children.isEmpty || !unreadChildren.isEmpty {
            var list = container.nestedUnkeyedContainer(forKey: .children)
            var next = children.makeIterator()
            let raw = Dictionary(unreadChildren.map { ($0.index, $0.raw) }, uniquingKeysWith: { first, _ in first })
            var position = 0
            while true {
                if let unread = raw[position] {
                    try list.encode(unread)
                } else if let child = next.next() {
                    try list.encode(child)
                } else {
                    break
                }
                position += 1
            }
        }
        try container.encodeIfPresent(layout, forKey: .layout)
        if padding != Padding() { try container.encode(padding, forKey: .padding) }
        if width != Sizing(.fixed) { try container.encode(width, forKey: .width) }
        if height != Sizing(.fixed) { try container.encode(height, forKey: .height) }
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
        if style != Style() { try container.encode(style, forKey: .style) }
        try container.encodeIfPresent(name, forKey: .name)
        if isLocked { try container.encode(true, forKey: .isLocked) }
        if isHidden { try container.encode(true, forKey: .isHidden) }
        try container.encodeIfPresent(accessibility, forKey: .accessibility)
        try container.encodeIfPresent(sketch, forKey: .sketch)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(interaction, forKey: .interaction)
    }

    /// Reads the children one at a time. One that can't be read comes back as unread, at
    /// its index in the list as it was saved.
    private static func readChildren(in container: KeyedDecodingContainer<CodingKeys>) throws -> ([LayerNode], [UnreadChild]) {
        var list = try container.nestedUnkeyedContainer(forKey: .children)
        var children: [LayerNode] = []
        var unread: [UnreadChild] = []
        while !list.isAtEnd {
            let index = list.currentIndex
            // A failed read leaves the list where it was, so the same entry is read again as it is.
            if let child = try? list.decode(LayerNode.self) {
                children.append(child)
            } else {
                unread.append(UnreadChild(index: index, raw: try list.decode(JSONValue.self)))
            }
        }
        return (children, unread)
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

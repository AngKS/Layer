import CoreGraphics
import Foundation

// The design's tokens in its code (call 13): `DesignTokens.swift`, and the names the views use
// for them. Only laid-out containers, cards and column screens use them; what the reading-order
// inference writes keeps its numbers, so a sketched screen's code doesn't change.

extension SwiftUICodeGenerator {
    /// `DesignTokens.swift`: the design's tokens, and the margins and column widths of its
    /// column screens' devices, as one enum.
    static func tokensFile(in context: Context) -> (name: String, source: String) {
        ("DesignTokens.swift", (["import SwiftUI", ""] + tokenEnum(in: context)).joined(separator: "\n"))
    }

    /// The `enum DesignTokens` that a view using a token name compiles against.
    static func tokenEnum(in context: Context) -> [String] {
        let tokens = context.tokens
        var lines = [
            "/// The numbers this design is laid out and styled by.",
            "enum DesignTokens {",
            "    /// The steps the space between things is made of, smallest first.",
            "    static let rhythm: [CGFloat] = [\(tokens.rhythm.map(number).joined(separator: ", "))]",
            "    static let cornerRadiusSmall: CGFloat = \(number(tokens.cornerRadii.small))",
            "    static let cornerRadiusMedium: CGFloat = \(number(tokens.cornerRadii.medium))",
            "    static let cornerRadiusLarge: CGFloat = \(number(tokens.cornerRadii.large))",
            "    static let cardPadding: CGFloat = \(number(tokens.card.padding))",
            "    static let cardRadius: CGFloat = \(number(tokens.card.radius))",
            "    static let cardFill = \(color(tokens.card.fill))",
            "    static let titleSize: CGFloat = \(number(tokens.textSizes.title))",
            "    static let bodySize: CGFloat = \(number(tokens.textSizes.body))",
            "    static let textSize: CGFloat = \(number(tokens.textSizes.text))",
        ]
        let margins = context.namedValues(context.marginNames) { $0.margin }
        if !margins.isEmpty {
            lines.append("    /// The space kept round a screen's column, inside its safe area.")
            lines += margins.map { "    static let \($0.name): CGFloat = \(number($0.value))" }
        }
        let widths = context.namedValues(context.maxContentWidthNames) { $0.maxContentWidth }
        if !widths.isEmpty {
            lines.append("    /// The widest a screen's column runs.")
            lines += widths.map { "    static let \($0.name): CGFloat = \(number($0.value))" }
        }
        return lines + ["}"]
    }
}

extension SwiftUICodeGenerator.Context {
    /// Names a device token for column screens: one `base` when every value is the same, else one
    /// per device, `base` and the device's name made a word as type names are (`marginIPhone`).
    static func names(_ base: String, for screens: [(id: TreeScreen.ID, device: DeviceFrame)],
                      value: (DeviceFrame) -> CGFloat?) -> [TreeScreen.ID: String] {
        let valued = screens.filter { value($0.device) != nil }
        guard !valued.isEmpty else { return [:] }
        if Set(valued.compactMap { value($0.device) }).count == 1 {
            return Dictionary(valued.map { ($0.id, base) }, uniquingKeysWith: { first, _ in first })
        }
        var byDevice: [String: String] = [:]
        var used: Set<String> = []
        var names: [TreeScreen.ID: String] = [:]
        for screen in valued {
            if byDevice[screen.device.id] == nil {
                let word = Self.word(for: screen.device.name)
                var name = base + word
                var number = 2
                while used.contains(name.lowercased()) {
                    name = base + word + "\(number)"
                    number += 1
                }
                used.insert(name.lowercased())
                byDevice[screen.device.id] = name
            }
            names[screen.id] = byDevice[screen.device.id]
        }
        return names
    }

    /// A device's name as a word to follow a token's: "iPhone" is `IPhone`, "iPad Pro 13″" `IPadPro13`.
    private static func word(for name: String) -> String {
        let cleaned = name.filter { $0.isLetter || $0.isNumber }
        guard let first = cleaned.first else { return "Device" }
        return first.uppercased() + cleaned.dropFirst()
    }

    /// Each name in `names` once, with its device's value, sorted by name.
    func namedValues(_ names: [TreeScreen.ID: String], value: (DeviceFrame) -> CGFloat?) -> [(name: String, value: CGFloat)] {
        var found: [String: CGFloat] = [:]
        for (id, name) in names where found[name] == nil {
            if let device = devices[id], let number = value(device) { found[name] = number }
        }
        return found.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

extension SwiftUICodeGenerator.ScreenWriter {
    /// A token name, noted as used.
    mutating func token(_ name: String) -> String {
        usesTokens = true
        return "DesignTokens.\(name)"
    }

    /// A spacing or padding in a laid-out container: its rhythm step's name when it is one, else the number.
    mutating func gap(_ value: CGFloat) -> String {
        if let step = context.tokens.rhythm.firstIndex(of: value) { return token("rhythm[\(step)]") }
        return SwiftUICodeGenerator.number(value)
    }

    /// A laid-out container's padding, its modifiers indented: the card's padding by its token,
    /// one value for every edge, or each pair or edge that has one.
    mutating func padding(_ node: LayerNode) -> [String] {
        let padding = node.padding
        let edges = [padding.top, padding.leading, padding.bottom, padding.trailing]
        if node.kind == .card, edges.allSatisfy({ $0 == context.tokens.card.padding }) {
            return ["    .padding(\(token("cardPadding")))"]
        }
        if edges.allSatisfy({ $0 == padding.top }) {
            return padding.top > 0 ? ["    .padding(\(gap(padding.top)))"] : []
        }
        var lines: [String] = []
        if padding.top == padding.bottom, padding.leading == padding.trailing {
            if padding.leading > 0 { lines.append("    .padding(.horizontal, \(gap(padding.leading)))") }
            if padding.top > 0 { lines.append("    .padding(.vertical, \(gap(padding.top)))") }
            return lines
        }
        for (edge, value) in [("top", padding.top), ("leading", padding.leading), ("bottom", padding.bottom), ("trailing", padding.trailing)]
        where value > 0 {
            lines.append("    .padding(.\(edge), \(gap(value)))")
        }
        return lines
    }

    /// A card's background: the system's secondary background for Layer's standard card fill,
    /// the design's card fill by its token, or the card's own colour; rounded by the card radius.
    mutating func cardBackground(_ node: LayerNode) -> (fill: String, radius: String) {
        let tokens = context.tokens
        let fill = node.style.tint ?? tokens.card.fill
        let radius = node.style.cornerRadius ?? tokens.card.radius
        let fillName = fill == DesignTokens.standard.card.fill ? ".background.secondary"
            : fill == tokens.card.fill ? token("cardFill")
            : SwiftUICodeGenerator.color(fill)
        let radiusName = radius == tokens.card.radius ? token("cardRadius") : SwiftUICodeGenerator.number(radius)
        return (fillName, radiusName)
    }
}

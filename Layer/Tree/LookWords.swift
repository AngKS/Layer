import CoreGraphics
import Foundation

/// What look words in brackets ask for: `[blue, bold, 18pt, radius 12]`. A field that is
/// nil was not asked for, and applying a look leaves it alone.
struct Look: Equatable, Sendable {
    enum Width: Sendable { case fill, fit }

    var width: Width?
    var tint: RGBColor?
    var textColor: RGBColor?
    var fontSize: CGFloat?
    var fontWeight: FontWeightChoice?
    var cornerRadius: CGFloat?
    var alignment: TextAlignmentChoice?
    /// For toggles, checkboxes and radio buttons.
    var isOn: Bool?
    /// For progress bars, from 0 to 1.
    var value: Double?
    var buttonLook: ButtonLook?
    var hasShadow: Bool?
    var borderColor: RGBColor?
    var borderWidth: CGFloat?
    var opacity: Double?

    /// Gives a node this look, leaving what the look doesn't say alone.
    func apply(to node: inout LayerNode) {
        switch width {
        case .fill?: node.width = LayerNode.Sizing(.fill(weight: 1))
        case .fit?: node.width = LayerNode.Sizing(.fit)
        case nil: break
        }
        if let tint { node.style.tint = tint }
        if let textColor { node.style.textColor = textColor }
        if let fontSize { node.style.fontSize = fontSize }
        if let fontWeight { node.style.fontWeight = fontWeight }
        if let cornerRadius { node.style.cornerRadius = cornerRadius }
        if let alignment { node.style.textAlignment = alignment }
        if let isOn { node.content.isOn = isOn }
        if let value { node.content.value = min(max(value, 0), 1) }
        if let buttonLook { node.content.buttonLook = buttonLook }
        if let hasShadow { node.style.hasShadow = hasShadow }
        if let borderColor {
            node.style.borderColor = borderColor
            if (node.style.borderWidth ?? 0) == 0 { node.style.borderWidth = borderWidth ?? 1 }
        }
        if let borderWidth { node.style.borderWidth = borderWidth > 0 ? borderWidth : nil }
        if let opacity { node.style.opacity = opacity >= 0.995 ? nil : min(max(opacity, 0), 1) }
    }
}

/// The words people write in a look and for each kind. Shared by `ScreenBlueprint` and the outline.
enum LookWords {
    /// The words people use for each kind of element. No word belongs to two kinds.
    static let kindWords: [(words: [String], kind: ElementKind)] = ElementKind.allCases.map { ($0.spec.writtenNames, $0) }

    static func kind(named name: String) -> ElementKind? {
        let word = name.lowercased().trimmingCharacters(in: .whitespaces)
        return kindWords.first { $0.words.contains(word) }?.kind
    }

    /// Reads look words, such as `blue`, `bold`, `18pt`, `radius 12`, `text white`, `off`,
    /// `40%`, `bordered`, `centre`, `shadow`, `border red` or `opacity 50%`. A later word wins
    /// over an earlier one for the same field. Words it doesn't know are skipped, and so is a
    /// number that isn't one (`inf`, `nan`); one too large or too small for its field is brought
    /// into range: text from 1 to 1,000 points, a radius or border from 0 to 10,000.
    static func look(from words: [String]) -> Look {
        var look = Look()
        for word in words.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) where !word.isEmpty {
            if word == "fill" || word == "full width" {
                look.width = .fill
            } else if word == "fit" {
                look.width = .fit
            } else if let weight = FontWeightChoice(rawValue: word) {
                look.fontWeight = weight
            } else if ["on", "checked", "ticked", "selected"].contains(word) {
                look.isOn = true
            } else if ["off", "unchecked", "unticked", "unselected"].contains(word) {
                look.isOn = false
            } else if ["filled", "solid", "primary"].contains(word) {
                look.buttonLook = .filled
            } else if ["bordered", "outlined", "secondary"].contains(word) {
                look.buttonLook = .bordered
            } else if ["plain", "borderless", "link", "text only"].contains(word) {
                look.buttonLook = .plain
            } else if ["left", "leading", "align left"].contains(word) {
                look.alignment = .leading
            } else if ["center", "centre", "centered", "centred", "align center", "align centre"].contains(word) {
                look.alignment = .center
            } else if ["right", "trailing", "align right"].contains(word) {
                look.alignment = .trailing
            } else if word == "shadow" {
                look.hasShadow = true
            } else if word == "no shadow" {
                look.hasShadow = false
            } else if let amount = stripPrefix(word, ["opacity"]).flatMap(fraction) {
                look.opacity = amount
            } else if let border = stripPrefix(word, ["border", "outline"]) {
                if let width = Double(border.hasSuffix("pt") ? String(border.dropLast(2)) : border) {
                    if width.isFinite { look.borderWidth = CGFloat(min(max(width, 0), largestLength)) }
                } else if let colour = ColourWords.parse(border) {
                    look.borderColor = colour
                }
            } else if word.hasSuffix("%"), let amount = fraction(word) {
                look.value = amount
            } else if word.hasSuffix("pt"), let size = Double(word.dropLast(2).trimmingCharacters(in: .whitespaces)) {
                if size.isFinite { look.fontSize = CGFloat(min(max(size, 1), largestText)) }
            } else if let radius = stripPrefix(word, ["radius", "corner", "corners"]).flatMap({ Double($0) }) {
                if radius.isFinite { look.cornerRadius = CGFloat(min(max(radius, 0), largestLength)) }
            } else if let colour = stripPrefix(word, ["text "]).flatMap(ColourWords.parse) {
                look.textColor = colour
            } else if let colour = ColourWords.parse(word) {
                look.tint = colour
            }
        }
        return look
    }

    /// What follows the first of `prefixes` that starts the line, trimmed.
    static func stripPrefix(_ line: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes where line.lowercased().hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The largest text a look asks for, and the largest radius or border, in points.
    private static let largestText: Double = 1_000
    private static let largestLength: Double = 10_000

    /// `40%` or `0.4` as 0.4; nil for a number that isn't one.
    private static func fraction(_ word: String) -> Double? {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        let amount: Double?
        if trimmed.hasSuffix("%") {
            amount = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)).map { $0 / 100 }
        } else {
            amount = Double(trimmed).map { $0 > 1 ? $0 / 100 : $0 }
        }
        return amount.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }
}

/// Colour names and hex codes, shared by the blueprint, the outline and the colour parameters.
enum ColourWords {
    static let named: [String: RGBColor] = [
        // The same colour as `Theme.accent`, which this file can't name because it builds on macOS too.
        "accent": RGBColor(hex: 0xCD6C57), "layer orange": RGBColor(hex: 0xCD6C57),
        "black": RGBColor(hex: 0x1C1C1E), "white": RGBColor(hex: 0xFFFFFF),
        "gray": RGBColor(hex: 0x8E8E93), "grey": RGBColor(hex: 0x8E8E93),
        "red": RGBColor(hex: 0xFF3B30), "orange": RGBColor(hex: 0xFF9500),
        "yellow": RGBColor(hex: 0xFFCC00), "green": RGBColor(hex: 0x34C759),
        "mint": RGBColor(hex: 0x00C7BE), "teal": RGBColor(hex: 0x30B0C7),
        "blue": RGBColor(hex: 0x007AFF), "indigo": RGBColor(hex: 0x5856D6),
        "purple": RGBColor(hex: 0xAF52DE), "pink": RGBColor(hex: 0xFF2D55),
        "brown": RGBColor(hex: 0xA2845E),
    ]

    /// A colour from a name or a hex code such as `#0A84FF` or `0A84FF`.
    static func parse(_ text: String) -> RGBColor? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let colour = named[cleaned] { return colour }
        let hex = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return RGBColor(hex: value)
    }
}

import CoreGraphics
import Foundation

/// A whole screen described in words, as Siri or Shortcuts hand it over: its sections from
/// top to bottom, each a column or a row of elements. `layout(on:)` turns it into elements
/// placed on a device, the way a person would lay the screen out.
///
/// This is the shape Siri's generable screen spec takes too, so both reach the canvas
/// through the same layout.
struct ScreenBlueprint: Equatable, Sendable {
    enum Axis: String, Sendable {
        case vertical, horizontal
    }

    enum Width: String, Sendable {
        /// Stretches across the section.
        case fill
        /// Hugs its content, at the kind's usual size.
        case fit
    }

    struct Item: Equatable, Sendable {
        var kind: ElementKind
        var text: String
        var symbol: String?
        var width: Width?
        var colour: RGBColor?
        var textColour: RGBColor?
        var fontSize: CGFloat?
        var weight: FontWeightChoice?
        var cornerRadius: CGFloat?
    }

    struct Section: Equatable, Sendable {
        var axis: Axis = .vertical
        var spacing: CGFloat = 12
        var items: [Item]
    }

    var sections: [Section]

    // MARK: Reading the written form

    /// Reads a screen written one element per line:
    ///
    ///     title: Welcome back
    ///     text field: Email
    ///     text field: Password
    ///     button: Sign in [blue, bold, radius 12]
    ///     row: button: Cancel | button: Done
    ///
    /// `row:` puts its elements side by side, split by `|`. A blank line or `---` starts a
    /// new section. Square brackets hold the look: a colour name or hex, a weight, a size
    /// such as `18pt`, `radius 12`, `text white`, `fit` or `fill`. A line with no kind is
    /// read as text. Returns nil when there is nothing to lay out.
    static func parse(_ written: String) -> ScreenBlueprint? {
        var sections: [Section] = []
        var current: [Item] = []

        func closeSection() {
            if !current.isEmpty { sections.append(Section(items: current)) }
            current = []
        }

        let lines = written
            .replacingOccurrences(of: ";", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines {
            if line.isEmpty || line.allSatisfy({ $0 == "-" }) {
                closeSection()
                continue
            }
            let cleaned = line.hasPrefix("- ") || line.hasPrefix("• ") ? String(line.dropFirst(2)) : line
            if let row = stripPrefix(cleaned, ["row:", "row -", "side by side:"]) {
                closeSection()
                let items = row.split(separator: "|").compactMap { item(String($0)) }
                if !items.isEmpty { sections.append(Section(axis: .horizontal, items: items)) }
            } else if let item = item(cleaned) {
                current.append(item)
            }
        }
        closeSection()
        return sections.isEmpty ? nil : ScreenBlueprint(sections: sections)
    }

    private static func stripPrefix(_ line: String, _ prefixes: [String]) -> String? {
        for prefix in prefixes where line.lowercased().hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The words people use for each kind of element.
    static let kindWords: [(words: [String], kind: ElementKind)] = [
        (["title", "heading", "header", "headline", "large title"], .title),
        (["body", "body text", "description", "paragraph", "subtitle", "caption"], .body),
        (["button", "primary button", "cta"], .button),
        (["text field", "textfield", "field", "input", "search field", "email field", "password field"], .textField),
        (["image", "photo", "picture", "hero", "hero image", "banner"], .image),
        (["symbol", "icon", "sf symbol"], .symbol),
        (["divider", "separator", "line", "rule"], .divider),
        (["toggle", "switch"], .toggle),
        (["checkbox", "check box", "tick box"], .checkbox),
        (["radio", "radio button", "option"], .radio),
        (["progress", "progress bar", "progress view", "loading bar"], .progress),
        (["avatar", "profile picture", "profile photo"], .avatar),
        (["text", "label"], .text),
        (["sticky note", "note"], .stickyNote),
    ]

    static func kind(named word: String) -> ElementKind? {
        let word = word.lowercased().trimmingCharacters(in: .whitespaces)
        return kindWords.first { $0.words.contains(word) }?.kind
    }

    /// One element from `kind: words [look]`.
    static func item(_ written: String) -> Item? {
        var text = written.trimmingCharacters(in: .whitespaces)
        var look: [String] = []
        if let open = text.lastIndex(of: "["), text.hasSuffix("]") {
            look = text[text.index(after: open)..<text.index(before: text.endIndex)]
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty || !look.isEmpty else { return nil }

        var kind = ElementKind.text
        if let colon = text.firstIndex(of: ":"), let named = Self.kind(named: String(text[..<colon])) {
            kind = named
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        } else if let named = Self.kind(named: text) {
            kind = named
            text = ""
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))

        var item = Item(kind: kind, text: text)
        if kind == .symbol {
            item.symbol = text.isEmpty ? "star" : text
            item.text = ""
        } else if text.isEmpty {
            item.text = kind.placeholder
        }
        for word in look {
            if word == "fill" || word == "full width" {
                item.width = .fill
            } else if word == "fit" {
                item.width = .fit
            } else if let weight = FontWeightChoice(rawValue: word) {
                item.weight = weight
            } else if word.hasSuffix("pt"), let size = Double(word.dropLast(2).trimmingCharacters(in: .whitespaces)) {
                item.fontSize = CGFloat(size)
            } else if let radius = stripPrefix(word, ["radius", "corner", "corners"]).flatMap({ Double($0) }) {
                item.cornerRadius = CGFloat(radius)
            } else if let colour = stripPrefix(word, ["text "]).flatMap(ColourWords.parse) {
                item.textColour = colour
            } else if let colour = ColourWords.parse(word) {
                item.colour = colour
            }
        }
        return item
    }

    // MARK: Laying it out

    /// Elements for this screen on a device, top to bottom inside the safe area, with
    /// 20-point side margins. Sections are 24 points apart; a row shares its width equally.
    func layout(on device: DeviceFrame) -> [DesignElement] {
        let margin: CGFloat = 20
        let width = device.size.width - margin * 2
        var y = device.safeTop + 16
        var elements: [DesignElement] = []

        for (index, section) in sections.enumerated() {
            if index > 0 { y += 24 - section.spacing }
            switch section.axis {
            case .vertical:
                for item in section.items {
                    let size = Self.size(of: item, available: width, on: device)
                    let x = margin + (width - size.width) / 2
                    elements.append(element(item, frame: CGRect(x: x, y: y, width: size.width, height: size.height)))
                    y += size.height + section.spacing
                }
            case .horizontal:
                let count = CGFloat(section.items.count)
                let slot = (width - section.spacing * (count - 1)) / count
                let sizes = section.items.map { Self.size(of: $0, available: slot, on: device, inRow: true) }
                let rowHeight = sizes.map(\.height).max() ?? 0
                for (column, (item, size)) in zip(section.items, sizes).enumerated() {
                    let slotX = margin + CGFloat(column) * (slot + section.spacing)
                    let frame = CGRect(x: slotX + (slot - size.width) / 2, y: y + (rowHeight - size.height) / 2, width: size.width, height: size.height)
                    elements.append(element(item, frame: frame))
                }
                y += rowHeight + section.spacing
            }
        }
        return elements.map { element in
            var element = element
            element.frame = element.frame.integral
            return element
        }
    }

    /// How large an item is drawn: its kind's usual size, stretched across `available`
    /// for kinds that usually run edge to edge or when asked to fill.
    static func size(of item: Item, available: CGFloat, on device: DeviceFrame, inRow: Bool = false) -> CGSize {
        var size = ElementLayout.size(for: item.kind, sketch: .zero)
        let stretches = switch item.kind {
        case .button, .textField, .divider, .image, .body, .progress: true
        default: false
        }
        if item.width == .fill || (item.width == nil && (stretches || inRow && !ElementLayout.keepsSketchedPosition(item.kind))) {
            size.width = available
        } else {
            size.width = min(size.width, available)
        }
        if item.kind == .image, !inRow {
            size.height = min(200, device.size.height / 4).rounded()
        }
        if let fontSize = item.fontSize, item.kind.hasText {
            size.height = max(size.height, (fontSize * 1.4).rounded())
        }
        return size
    }

    private func element(_ item: Item, frame: CGRect) -> DesignElement {
        var element = DesignStore.newElement(item.kind, symbol: item.symbol)
        element.frame = frame
        element.text = item.text
        if let colour = item.colour { element.tint = colour }
        element.textColor = item.textColour
        element.fontSize = item.fontSize
        element.fontWeight = item.weight
        element.cornerRadius = item.cornerRadius
        if item.kind == .title || item.kind == .body || item.kind == .text {
            element.textAlignment = frame.width >= 200 ? nil : .center
        }
        return element
    }
}

/// Colour names and hex codes, shared by the blueprint and the colour parameters.
enum ColourWords {
    static let named: [String: RGBColor] = [
        "accent": Theme.accent, "layer orange": Theme.accent,
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

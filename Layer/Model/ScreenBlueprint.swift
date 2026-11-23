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
        var alignment: TextAlignmentChoice?
        /// For toggles, checkboxes and radio buttons.
        var isOn: Bool?
        /// For progress bars, from 0 to 1.
        var value: Double?
        var buttonLook: ButtonLook?
        var hasShadow: Bool?
        var borderColour: RGBColor?
        var borderWidth: CGFloat?
        var opacity: Double?

        /// Gives an element this item's look, leaving what the item doesn't say alone.
        func applyLook(to element: inout DesignElement) {
            if let colour { element.tint = colour }
            if let textColour { element.textColor = textColour }
            if let fontSize { element.fontSize = fontSize }
            if let weight { element.fontWeight = weight }
            if let cornerRadius { element.cornerRadius = cornerRadius }
            if let alignment { element.textAlignment = alignment }
            if let isOn { element.isOn = isOn }
            if let value { element.value = min(max(value, 0), 1) }
            if let buttonLook { element.buttonLook = buttonLook }
            if let hasShadow { element.hasShadow = hasShadow }
            if let borderColour {
                element.borderColor = borderColour
                if (element.borderWidth ?? 0) == 0 { element.borderWidth = borderWidth ?? 1 }
            }
            if let borderWidth { element.borderWidth = borderWidth > 0 ? borderWidth : nil }
            if let opacity { element.opacity = opacity >= 0.995 ? nil : min(max(opacity, 0), 1) }
        }
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
        LookWords.stripPrefix(line, prefixes)
    }

    /// The words people use for each kind of element. No word belongs to two kinds.
    static let kindWords = LookWords.kindWords

    static func kind(named word: String) -> ElementKind? { LookWords.kind(named: word) }

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
        applyLook(look, to: &item)
        return item
    }

    /// Reads look words, such as `blue`, `bold`, `18pt`, `radius 12`, `text white`, `off`,
    /// `40%`, `bordered`, `centre`, `shadow`, `border red` or `opacity 50%`, into an item.
    /// Words it doesn't know are skipped. See `LookWords`.
    static func applyLook(_ words: [String], to item: inout Item) {
        let look = LookWords.look(from: words)
        if let width = look.width { item.width = width == .fill ? .fill : .fit }
        if let tint = look.tint { item.colour = tint }
        if let textColor = look.textColor { item.textColour = textColor }
        if let fontSize = look.fontSize { item.fontSize = fontSize }
        if let fontWeight = look.fontWeight { item.weight = fontWeight }
        if let cornerRadius = look.cornerRadius { item.cornerRadius = cornerRadius }
        if let alignment = look.alignment { item.alignment = alignment }
        if let isOn = look.isOn { item.isOn = isOn }
        if let value = look.value { item.value = value }
        if let buttonLook = look.buttonLook { item.buttonLook = buttonLook }
        if let hasShadow = look.hasShadow { item.hasShadow = hasShadow }
        if let borderColor = look.borderColor { item.borderColour = borderColor }
        if let borderWidth = look.borderWidth { item.borderWidth = borderWidth }
        if let opacity = look.opacity { item.opacity = opacity }
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
        let stretches = item.kind.spec.fillsWrittenWidth
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
        if item.kind == .title || item.kind == .body || item.kind == .text {
            element.textAlignment = frame.width >= 200 ? nil : .center
        }
        item.applyLook(to: &element)
        return element
    }
}

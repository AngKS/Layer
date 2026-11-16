import CoreGraphics

/// How an element looks once its own choices are laid over its kind's usual look.
extension DesignElement {
    var resolvedFontSize: CGFloat {
        if let fontSize { return fontSize }
        return switch kind {
        // A title's text grows and shrinks with its box.
        case .title: frame.height * 0.7
        case .body: 13
        case .button, .text: 17
        case .textField: 16
        case .stickyNote: 15
        case .image, .divider, .symbol: 17
        }
    }

    var resolvedFontWeight: FontWeightChoice {
        fontWeight ?? (kind == .title ? .bold : kind == .button ? .semibold : .regular)
    }

    var resolvedTextColor: RGBColor {
        if let textColor { return textColor }
        return switch kind {
        case .title: RGBColor(hex: 0x000000)
        case .body: RGBColor(hex: 0x8E8C86)
        case .button: RGBColor(hex: 0xFFFFFF)
        case .textField: RGBColor(hex: 0x9A9892)
        case .text, .stickyNote, .image, .divider, .symbol: Theme.inkTint
        }
    }

    var resolvedCornerRadius: CGFloat {
        if let cornerRadius { return cornerRadius }
        return switch kind {
        case .image: 16
        case .button: frame.height / 2
        case .textField: 12
        case .stickyNote: 6
        case .title, .body, .divider, .symbol, .text: 0
        }
    }

    var resolvedOpacity: Double { opacity ?? 1 }

    /// Whether `tint` is something this element shows.
    var hasFill: Bool { kind == .button || kind == .stickyNote || kind == .symbol }
    var hasCornerRadius: Bool { kind == .image || kind == .button || kind == .textField || kind == .stickyNote }
}

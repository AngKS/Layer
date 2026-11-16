import CoreGraphics

/// How an element looks once its own choices are laid over its kind's usual look.
extension DesignElement {
    var resolvedFontSize: CGFloat {
        if let fontSize { return fontSize }
        return switch kind {
        // A title's text grows and shrinks with its box.
        case .title: frame.height * 0.7
        // The size of iOS's subheadline: large enough to read, and two lines still fit the
        // body's usual 44 points.
        case .body: 15
        case .button, .text: 17
        case .textField: 16
        case .stickyNote: 15
        case .image, .divider, .symbol, .toggle, .avatar, .checkbox, .radio, .progress: 17
        }
    }

    var resolvedFontWeight: FontWeightChoice {
        fontWeight ?? (kind == .title ? .bold : kind == .button ? .semibold : .regular)
    }

    var resolvedTextColor: RGBColor {
        if let textColor { return textColor }
        return switch kind {
        case .title: RGBColor(hex: 0x000000)
        // About 7.5 to 1 against a white screen: softer than the title, still easy to read.
        case .body: RGBColor(hex: 0x55544F)
        // White on a filled button; a bordered or plain one shows its colour in its text.
        case .button: resolvedButtonLook == .filled ? RGBColor(hex: 0xFFFFFF) : tint
        case .textField: RGBColor(hex: 0x9A9892)
        case .text, .stickyNote, .image, .divider, .symbol, .toggle, .avatar, .checkbox, .radio, .progress: Theme.inkTint
        }
    }

    var resolvedCornerRadius: CGFloat {
        if let cornerRadius { return cornerRadius }
        return switch kind {
        case .image: 16
        case .button: frame.height / 2
        case .textField: 12
        case .stickyNote: 6
        case .avatar, .radio, .progress: min(frame.width, frame.height) / 2
        case .checkbox: min(frame.width, frame.height) * 0.25
        case .title, .body, .divider, .symbol, .text, .toggle: 0
        }
    }

    var resolvedOpacity: Double { opacity ?? 1 }

    var resolvedButtonLook: ButtonLook { buttonLook ?? .filled }

    /// A progress bar's fill, kept between 0 and 1.
    var resolvedValue: Double { min(max(value ?? 0.5, 0), 1) }

    var resolvedTextAlignment: TextAlignmentChoice {
        if let textAlignment { return textAlignment }
        return switch kind {
        case .title, .body, .button, .stickyNote: .center
        default: .leading
        }
    }

    /// The outline's width, or zero for none.
    var resolvedBorderWidth: CGFloat { max(borderWidth ?? 0, 0) }
    var resolvedBorderColor: RGBColor { borderColor ?? Theme.inkTint }

    /// Whether the corner radius makes a circle of the element.
    var isCircular: Bool {
        hasCornerRadius && resolvedCornerRadius >= min(frame.width, frame.height) / 2 - 0.5 && abs(frame.width - frame.height) < 1
    }

    /// Whether `tint` is something this element shows.
    var hasFill: Bool {
        kind == .button || kind == .stickyNote || kind == .symbol || kind == .toggle
            || kind == .checkbox || kind == .radio || kind == .progress
    }
    var hasCornerRadius: Bool {
        kind == .image || kind == .button || kind == .textField || kind == .stickyNote || kind == .avatar
            || kind == .checkbox || kind == .progress
    }
    /// Whether an outline can be drawn round the element. Checkboxes and radio buttons
    /// draw their own.
    var hasBorder: Bool {
        kind != .divider && kind != .symbol && kind != .toggle && kind != .checkbox && kind != .radio
    }
    /// Whether the element can be switched on and off.
    var hasOnState: Bool { kind == .toggle || kind == .checkbox || kind == .radio }
    /// Whether the text inside can be aligned.
    var hasTextAlignment: Bool { kind == .title || kind == .body || kind == .text || kind == .stickyNote || kind == .textField }
}

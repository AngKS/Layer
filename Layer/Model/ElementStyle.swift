import CoreGraphics

/// How an element looks once its own choices are laid over its kind's usual look.
extension DesignElement {
    var resolvedFontSize: CGFloat {
        fontSize ?? kind.spec.fontSize.points(in: frame)
    }

    var resolvedFontWeight: FontWeightChoice {
        fontWeight ?? kind.spec.fontWeight
    }

    var resolvedTextColor: RGBColor {
        if let textColor { return textColor }
        return switch kind.spec.textColour {
        case .colour(let colour): colour
        // White on a filled button; a bordered or plain one shows its colour in its text.
        case .onFill: resolvedButtonLook == .filled ? RGBColor(hex: 0xFFFFFF) : tint
        }
    }

    var resolvedCornerRadius: CGFloat {
        cornerRadius ?? kind.spec.cornerRadius.points(in: frame)
    }

    var resolvedOpacity: Double { opacity ?? 1 }

    var resolvedButtonLook: ButtonLook { buttonLook ?? .filled }

    /// A progress bar's fill, kept between 0 and 1.
    var resolvedValue: Double { min(max(value ?? 0.5, 0), 1) }

    var resolvedTextAlignment: TextAlignmentChoice {
        textAlignment ?? kind.spec.textAlignment
    }

    /// The outline's width, or zero for none.
    var resolvedBorderWidth: CGFloat { max(borderWidth ?? 0, 0) }
    var resolvedBorderColor: RGBColor { borderColor ?? Theme.inkTint }

    /// Whether the corner radius makes a circle of the element.
    var isCircular: Bool {
        hasCornerRadius && resolvedCornerRadius >= min(frame.width, frame.height) / 2 - 0.5 && abs(frame.width - frame.height) < 1
    }

    /// Whether `tint` is something this element shows.
    var hasFill: Bool { kind.spec.traits.contains(.fill) }
    var hasCornerRadius: Bool { kind.spec.traits.contains(.cornerRadius) }
    /// Whether an outline can be drawn round the element. Checkboxes and radio buttons
    /// draw their own.
    var hasBorder: Bool { kind.spec.traits.contains(.border) }
    /// Whether the element can be switched on and off.
    var hasOnState: Bool { kind.spec.traits.contains(.onState) }
    /// Whether the text inside can be aligned.
    var hasTextAlignment: Bool { kind.spec.traits.contains(.textAlignment) }
    /// Whether the element shows an amount, as a progress bar does.
    var hasValue: Bool { kind.spec.traits.contains(.value) }
    /// Whether the element can be filled, outlined or plain, as a button can.
    var hasButtonLooks: Bool { kind.spec.traits.contains(.buttonLooks) }
}

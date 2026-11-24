import CoreGraphics

/// How a node looks once its own choices are laid over its kind's usual look and the design's tokens: the values
/// `DesignElement`'s `resolved…` members give for the same fields (`ElementStyle.swift`), read off the node, and
/// what the node views draw.
extension LayerNode {
    /// Its own colour, or its kind's: a button's or sticky note's fill, a symbol's ink.
    var resolvedTint: RGBColor { style.tint ?? kind.spec.tint }

    /// Its tint; a card with no fill of its own takes the design's.
    func resolvedFill(tokens: DesignTokens) -> RGBColor {
        kind == .card ? style.tint ?? tokens.card.fill : resolvedTint
    }

    /// Its own size, else the design's title, body or text size, else its kind's (F5): the size it is measured at too.
    func resolvedFontSize(tokens: DesignTokens) -> CGFloat {
        NaturalSize.fontSize(of: self, tokens: tokens)
    }

    var resolvedFontWeight: FontWeightChoice { NaturalSize.fontWeight(of: self) }

    var resolvedTextColor: RGBColor {
        if let textColor = style.textColor { return textColor }
        return switch kind.spec.textColour {
        case .colour(let colour): colour
        // White on a filled button; a bordered or plain one shows its colour in its text.
        case .onFill: resolvedButtonLook == .filled ? RGBColor(hex: 0xFFFFFF) : resolvedTint
        }
    }

    /// Its own radius, else its kind's at its size; a card with none takes the design's.
    func resolvedCornerRadius(tokens: DesignTokens) -> CGFloat {
        if let radius = style.cornerRadius { return radius }
        return kind == .card ? tokens.card.radius : kind.spec.cornerRadius.points(in: frame)
    }

    var resolvedOpacity: Double { style.opacity ?? 1 }

    var resolvedButtonLook: ButtonLook { content.buttonLook ?? .filled }

    /// A progress bar's fill, kept between 0 and 1.
    var resolvedValue: Double { min(max(content.value ?? 0.5, 0), 1) }

    var resolvedTextAlignment: TextAlignmentChoice { style.textAlignment ?? kind.spec.textAlignment }

    /// The outline's width, or zero for none.
    var resolvedBorderWidth: CGFloat { max(style.borderWidth ?? 0, 0) }
    var resolvedBorderColor: RGBColor { style.borderColor ?? Theme.inkTint }

    /// Whether its tint is something it shows.
    var hasFill: Bool { kind.spec.traits.contains(.fill) }
    var hasCornerRadius: Bool { kind.spec.traits.contains(.cornerRadius) }
    /// Whether an outline can be drawn round it. Checkboxes and radio buttons draw their own.
    var hasBorder: Bool { kind.spec.traits.contains(.border) }

    /// What it is called in the Layers panel: its name, or what it is (`kindName`) when it has none (F7).
    var displayName: String {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return kindName }
        return name
    }

    /// What it is: a card's "Card", a `.group`'s layout ("Row", "Column", "Grid", "Overlay", or "Group" when free),
    /// or a leaf's kind name.
    var kindName: String {
        guard kind == .group else { return kind.layerName }
        return switch resolvedLayout {
        case .free: kind.layerName
        case .stack(let stack): stack.axis == .horizontal ? "Row" : "Column"
        case .grid: "Grid"
        case .overlay: "Overlay"
        }
    }
}

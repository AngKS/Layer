import CoreGraphics
import Foundation

// Each leaf's view: today's native views and styling, read from a `LayerNode`. Its frame is split
// off the view (F15): today's reading-order inference and Exact positions write the frame they
// always wrote, and a child of a row, column, grid or overlay writes the frame its sizing asks
// for instead.

extension SwiftUICodeGenerator {
    /// A leaf as its code reads it: the node, the frame it is written at, and its turn, in the
    /// space its code places it in, with the design's tokens. Its look is the node's, as the canvas
    /// draws it (`LayerNode+Look.swift`); what is its own decides what the code says of it.
    struct Leaf {
        var node: LayerNode
        var frame: CGRect
        /// From 0 up to 360, nil when upright, as an element keeps it.
        var rotation: Double?
        /// The design's, for text with no size of its own.
        var tokens: DesignTokens

        var kind: ElementKind { node.kind }
        var text: String { node.content.text }
        var name: String? { node.name }
        var symbol: String? { node.content.symbol }
        var shape: ShapeKind? { node.content.shape }
        var isOn: Bool { node.content.isOn }
        var tint: RGBColor { node.resolvedTint }
        var fontSize: CGFloat? { node.style.fontSize }
        var fontWeight: FontWeightChoice? { node.style.fontWeight }
        var textColor: RGBColor? { node.style.textColor }
        var textAlignment: TextAlignmentChoice? { node.style.textAlignment }
        var cornerRadius: CGFloat? { node.style.cornerRadius }
        var hasShadow: Bool { node.style.hasShadow }

        var resolvedFontSize: CGFloat { node.resolvedFontSize(tokens: tokens) }
        var resolvedFontWeight: FontWeightChoice { node.resolvedFontWeight }
        var resolvedCornerRadius: CGFloat { node.resolvedCornerRadius(tokens: tokens) }
        var resolvedOpacity: Double { node.resolvedOpacity }
        var resolvedButtonLook: ButtonLook { node.resolvedButtonLook }
        var resolvedValue: Double { node.resolvedValue }
        var resolvedTextAlignment: TextAlignmentChoice { node.resolvedTextAlignment }
        var resolvedBorderWidth: CGFloat { node.resolvedBorderWidth }
        var resolvedBorderColor: RGBColor { node.resolvedBorderColor }
        var resolvedRotation: Double { rotation ?? 0 }
        var hasCornerRadius: Bool { node.hasCornerRadius }
        var hasBorder: Bool { node.hasBorder }
        var isCircular: Bool {
            hasCornerRadius && resolvedCornerRadius >= min(frame.width, frame.height) / 2 - 0.5 && abs(frame.width - frame.height) < 1
        }
    }

    // MARK: Today's inference

    /// A leaf as today's reading-order inference writes it: its view at the width it has, or
    /// across the content when it is as wide as that, then placed where it sits: centred, or
    /// inset from `margin`.
    static func inferredLeaf(_ element: Leaf, margin: CGFloat, contentWidth: CGFloat, screenWidth: CGFloat) -> [String] {
        let frame = element.frame
        let fillsWidth = frame.width >= contentWidth - 1
        let centered = ElementLayout.isCentered(frame, in: screenWidth)
        /// Places a fixed-width view where it sits on the canvas: centred, or inset from the leading edge.
        var tail = placement(of: frame, margin: margin, fillsWidth: fillsWidth, centered: centered)
        /// The view up to its sized frame, and the placement modifiers that follow it.
        var lines: [String]

        switch element.kind {
        case .title:
            let alignment = element.textAlignment.map { $0.rawValue } ?? "leading"
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(titleFont(of: element)))",
            ] + textColor(of: element, usual: nil)
            if centered && (element.textAlignment ?? .center) == .center {
                // Stretched across the screen as it is placed: finished, and turned, before that.
                lines += ["    .multilineTextAlignment(.center)"]
                tail = ["    .frame(maxWidth: .infinity)"]
            } else {
                lines += ["    .frame(width: \(number(frame.width)), alignment: .\(alignment))"]
            }

        case .body:
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, style: ".subheadline", drawnAt: TextStyleSize.subheadline)))",
            ] + textColor(of: element, usual: nil) + [
                "    .multilineTextAlignment(.\(element.resolvedTextAlignment.rawValue))",
                fillsWidth ? "    .frame(maxWidth: .infinity)" : "    .frame(width: \(number(frame.width)))",
            ]

        case .text:
            let alignment = element.resolvedTextAlignment
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, style: ".body", drawnAt: TextStyleSize.body)))",
            ] + textColor(of: element, usual: nil)
                + (alignment == .leading ? [] : ["    .multilineTextAlignment(.\(alignment.rawValue))"])
                + ["    .frame(width: \(number(frame.width)), alignment: .\(alignment.rawValue))"]

        case .image, .avatar:
            lines = picture(element, frames: [".frame(width: \(number(frame.width)), height: \(number(frame.height)))"])

        case .button:
            lines = button(element, frames: [fillsWidth
                ? ".frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                : ".frame(width: \(number(frame.width)), height: \(number(frame.height)))"])

        case .textField:
            lines = textField(element, frames: [fillsWidth
                ? ".frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                : ".frame(width: \(number(frame.width)), height: \(number(frame.height)))"])

        case .symbol:
            lines = symbol(element, frames: [".frame(width: \(number(frame.width)), height: \(number(frame.height)))"])

        case .divider:
            lines = ["Divider()"] + (fillsWidth ? [] : ["    .frame(width: \(number(frame.width)))"])

        case .shape:
            lines = shape(element) + ["    .frame(width: \(number(frame.width)), height: \(number(frame.height)))"]

        case .toggle:
            lines = toggle(element)

        case .checkbox, .radio:
            lines = control(element, frames: [".frame(width: \(number(frame.width)), height: \(number(frame.height)))"])

        case .progress:
            lines = progress(element) + (fillsWidth ? [] : ["    .frame(width: \(number(frame.width)))"])

        case .stickyNote:
            // Sticky notes stay on the canvas; this is only here to keep the switch whole.
            lines = ["Text(\(literal(element.text)))"]

        case .drawing, .group, .card:
            // Ink is a note about the design, not part of the interface, and containers are
            // written by the walk: neither reaches here.
            return []
        }

        // An element is finished before it is placed, so that its border goes round it, as on
        // the canvas, rather than round the width it is centred in or the padding that insets
        // it. A turned one is turned in between, so its border and shadow turn with it.
        return lines + finish(element) + turn(element) + tail
    }

    /// Today's placement of a view the inference writes at its own width: none when it is as
    /// wide as the content, across the content when it is centred, else inset from `margin`.
    static func placement(of frame: CGRect, margin: CGFloat, fillsWidth: Bool, centered: Bool) -> [String] {
        if fillsWidth { return [] }
        if centered { return ["    .frame(maxWidth: .infinity)"] }
        let inset = frame.minX - margin
        return inset >= 1 ? ["    .padding(.leading, \(number(inset)))"] : []
    }

    // MARK: Exact positions

    /// A leaf at its place on the screen, as Exact positions has always written it.
    static func positionedLeaf(_ element: Leaf) -> [String] {
        let frame = element.frame
        let size = "width: \(number(frame.width)), height: \(number(frame.height))"
        let alignment = element.resolvedTextAlignment.rawValue
        var lines: [String]

        switch element.kind {
        case .title, .body, .text, .stickyNote:
            let textFont = switch element.kind {
            case .title: titleFont(of: element)
            case .body: font(of: element, style: ".subheadline", drawnAt: TextStyleSize.subheadline)
            case .text: font(of: element, style: ".body", drawnAt: TextStyleSize.body)
            default: font(of: element, usual: ".body")
            }
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(textFont))",
            ] + textColor(of: element, usual: nil)
                + (alignment == "leading" ? [] : ["    .multilineTextAlignment(.\(alignment))"])
                + (element.kind == .stickyNote
                    ? ["    .padding(12)", "    .frame(\(size), alignment: .\(alignment))", "    .background(\(color(element.tint)), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))"]
                    : ["    .frame(\(size), alignment: .\(alignment))"])

        case .image, .avatar:
            lines = picture(element, frames: [".frame(\(size))"])

        case .button:
            lines = button(element, frames: [".frame(\(size))"])

        case .textField:
            lines = [
                "TextField(\(literal(element.text)), text: .constant(\"\"))",
                "    .padding(.horizontal, 16)",
                "    .frame(\(size))",
                "    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
            ]

        case .symbol:
            lines = symbol(element, frames: [".frame(\(size))"])

        case .divider:
            lines = ["Divider()", "    .frame(width: \(number(frame.width)))"]

        case .shape:
            lines = shape(element) + ["    .frame(\(size))"]

        case .toggle:
            lines = toggle(element) + ["    .frame(\(size))"]

        case .checkbox, .radio:
            lines = control(element, frames: [".frame(\(size))"])

        case .progress:
            lines = progress(element) + ["    .frame(width: \(number(frame.width)))"]

        case .drawing, .group, .card:
            return []
        }

        return lines + finish(element) + turn(element) + ["    .offset(x: \(number(frame.minX)), y: \(number(frame.minY)))"]
    }

    // MARK: In a row, column, grid or overlay

    /// A leaf in a laid-out container: today's view, with `frames` (the frame its sizing asks
    /// for, unindented) where today's sized frame was. Text is drawn in the semantic font its
    /// size stands for (call 13).
    static func laidOutLeaf(_ element: Leaf, frames: [String]) -> [String] {
        let placed = frames.map { "    " + $0 }
        let alignment = element.resolvedTextAlignment
        let lines: [String]

        switch element.kind {
        case .title, .body, .text:
            // A body always says its alignment, as today; a title or text when it isn't leading.
            let aligns = element.kind == .body || alignment != .leading
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(laidOutFont(of: element)))",
            ] + textColor(of: element, usual: nil)
                + (aligns ? ["    .multilineTextAlignment(.\(alignment.rawValue))"] : [])
                + placed

        case .image, .avatar:
            lines = picture(element, frames: frames)

        case .button:
            lines = button(element, frames: frames)

        case .textField:
            lines = textField(element, frames: frames)

        case .symbol:
            lines = symbol(element, frames: frames)

        case .divider:
            lines = ["Divider()"] + placed

        case .shape:
            lines = shape(element) + placed

        case .toggle:
            lines = toggle(element) + placed

        case .checkbox, .radio:
            lines = control(element, frames: frames)

        case .progress:
            lines = progress(element) + placed

        case .stickyNote:
            lines = ["Text(\(literal(element.text)))"] + placed

        case .drawing, .group, .card:
            return []
        }
        return lines + finish(element) + turn(element)
    }

    /// Whether SwiftUI's view of a kind takes, by itself, the length on that axis the engine
    /// gives one that fits (`NaturalSize`): text and a toggle both ways, and a divider or
    /// progress bar, which run across what they're offered and are thin; a text field runs
    /// across too. Every other kind is written at its laid-out length when it fits.
    static func sizesItself(_ kind: ElementKind, across: Bool) -> Bool {
        switch kind {
        case .title, .body, .text, .toggle, .divider, .progress: true
        case .textField: across
        default: false
        }
    }

    /// The font of text in a laid-out container: the text style of the size it is drawn at when it has
    /// its kind's weight (a title's as `titleFont(of:)` says; a body's Subheadline at 15 and a text's
    /// Body at 17), else its size and weight, as it is measured and drawn.
    private static func laidOutFont(of element: Leaf) -> String {
        if element.kind == .title { return titleFont(of: element) }
        let size = element.resolvedFontSize
        let weight = element.resolvedFontWeight
        if weight == element.kind.spec.fontWeight {
            switch element.kind {
            case .body where size == TextStyleSize.subheadline: return ".subheadline"
            case .text where size == TextStyleSize.body: return ".body"
            default: break
            }
        }
        return systemFont(size: size, weight: weight)
    }

    /// The sizes SwiftUI draws its text styles at, at the standard Dynamic Type size: text drawn at one of them, in its
    /// kind's weight, is written in that style, and text at any other size at its size, so that canvas and code agree
    /// whatever a design's own text sizes are (final review B-I2). Layer's standard tokens give text these sizes (Title
    /// 28, Subheadline 15 for a body, Body 17 for text), and so does the Magic Pen (Title 2 at 22, Large Title at 34).
    private enum TextStyleSize {
        static let largeTitle = ElementLayout.largeTitleSize
        static let title: CGFloat = 28
        static let title2 = ElementLayout.titleTwoSize
        static let body: CGFloat = 17
        static let subheadline: CGFloat = 15
    }

    // MARK: Pieces of the views

    /// A picture, sized by `frames` (unindented) and clipped to its shape.
    private static func picture(_ element: Leaf, frames: [String]) -> [String] {
        let fallback = element.kind == .avatar ? "avatar" : "photo"
        let shape = element.isCircular ? ".circle" : ".rect(cornerRadius: \(number(element.resolvedCornerRadius)))"
        return [
            "Image(\(literal(assetName(element.name) ?? fallback)))",
            "    .resizable()",
            "    .scaledToFill()",
        ] + frames.map { "    " + $0 } + [
            "    .clipShape(\(shape))",
        ]
    }

    /// A title's font, by the size it is drawn at, whatever the design's title size: with a title's
    /// weight, Title at 28, Title 2 at 22 and Large Title at 34 (`TextStyleSize`); otherwise its size
    /// and weight.
    private static func titleFont(of element: Leaf) -> String {
        let size = element.resolvedFontSize
        let weight = element.resolvedFontWeight
        if weight == element.kind.spec.fontWeight {
            switch size {
            case TextStyleSize.title: return ".title.bold()"
            case TextStyleSize.title2: return ".title2.bold()"
            case TextStyleSize.largeTitle: return ".largeTitle.bold()"
            default: break
            }
        }
        return systemFont(size: size, weight: weight)
    }

    /// A button in its look. `frames` size the label, unindented.
    private static func button(_ element: Leaf, frames: [String]) -> [String] {
        let look = element.resolvedButtonLook
        let tint = color(element.tint)
        var lines = [
            "Button {",
            "} label: {",
            "    Text(\(literal(element.text)))",
            "        .font(\(font(of: element, usual: ".headline")))",
            "        .foregroundStyle(\(element.textColor.map(color) ?? (look == .filled ? ".white" : tint)))",
        ] + frames.map { "        " + $0 }
        switch look {
        case .filled:
            let shape = element.cornerRadius.map { ".rect(cornerRadius: \(number($0)))" } ?? ".capsule"
            lines.append("        .background(\(tint), in: \(shape))")
        case .bordered:
            let shape = element.cornerRadius.map { "RoundedRectangle(cornerRadius: \(number($0)))" } ?? "Capsule()"
            lines += ["        .overlay {", "            \(shape)", "                .strokeBorder(\(tint), lineWidth: 1.5)", "        }"]
        case .plain:
            break
        }
        return lines + ["}"]
    }

    /// A text field on its rounded background, sized by `frames` (unindented).
    private static func textField(_ element: Leaf, frames: [String]) -> [String] {
        [
            "TextField(\(literal(element.text)), text: .constant(\"\"))",
        ] + (element.resolvedTextAlignment == .leading ? [] : ["    .multilineTextAlignment(.\(element.resolvedTextAlignment.rawValue))"]) + [
            "    .padding(.horizontal, 16)",
        ] + frames.map { "    " + $0 } + [
            "    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
        ]
    }

    /// An SF Symbol in its colour, sized by `frames` (unindented).
    private static func symbol(_ element: Leaf, frames: [String]) -> [String] {
        [
            "Image(systemName: \(literal(SystemSymbol.resolve(element.symbol ?? "questionmark.square.dashed"))))",
            "    .resizable()",
            "    .scaledToFit()",
        ] + frames.map { "    " + $0 } + (element.tint == Theme.inkTint ? [] : ["    .foregroundStyle(\(color(element.tint)))"])
    }

    /// A checkbox or radio button, drawn with the symbols iOS uses for them, sized by `frames` (unindented).
    private static func control(_ element: Leaf, frames: [String]) -> [String] {
        let symbol = switch (element.kind, element.isOn) {
        case (.checkbox, true): "checkmark.square.fill"
        case (.checkbox, false): "square"
        case (_, true): "largecircle.fill.circle"
        case (_, false): "circle"
        }
        return [
            "Image(systemName: \(literal(symbol)))",
            "    .resizable()",
            "    .scaledToFit()",
        ] + frames.map { "    " + $0 } + [
            "    .foregroundStyle(\(element.isOn ? color(element.tint) : ".secondary"))",
        ]
    }

    private static func progress(_ element: Leaf) -> [String] {
        // To the hundredth, which `number` would round away.
        ["ProgressView(value: \((element.resolvedValue * 100).rounded() / 100))"]
            + (element.tint == Theme.accent ? [] : ["    .tint(\(color(element.tint)))"])
    }

    private static func toggle(_ element: Leaf) -> [String] {
        [
            "Toggle(\(literal(element.name ?? "")), isOn: .constant(\(element.isOn)))",
            "    .labelsHidden()",
        ] + (element.tint == Theme.accent ? [] : ["    .tint(\(color(element.tint)))"])
    }

    /// A shape, filled or outlined in its colour, without its frame. SwiftUI's own shapes
    /// where there is one; otherwise its outline as a path, at the leaf's size.
    private static func shape(_ element: Leaf) -> [String] {
        let kind = element.shape ?? .rectangle
        let paint = color(element.tint)
        let width = number(ShapeKind.outlineWidth)
        let builtIn: String? = switch kind {
        case .rectangle: "Rectangle()"
        case .roundedRectangle: "RoundedRectangle(cornerRadius: \(number(element.resolvedCornerRadius)), style: .continuous)"
        case .ellipse: "Ellipse()"
        case .capsule: "Capsule()"
        default: nil
        }
        if let builtIn {
            return [builtIn, element.isOn ? "    .fill(\(paint))" : "    .strokeBorder(\(paint), lineWidth: \(width))"]
        }
        // Outlined, the path is drawn inside the frame as the canvas draws it.
        let inset = element.isOn ? 0 : ShapeKind.outlineWidth / 2
        let size = CGSize(width: element.frame.width - inset * 2, height: element.frame.height - inset * 2)
        let points = (kind.polygon(in: size) ?? []).map { "CGPoint(x: \(number($0.x + inset)), y: \(number($0.y + inset)))" }
        return [
            "Path { path in",
            "    path.addLines([\(points.joined(separator: ", "))])",
            "    path.closeSubpath()",
            "}",
            element.isOn ? ".fill(\(paint))" : ".stroke(\(paint), style: StrokeStyle(lineWidth: \(width), lineJoin: .round))",
        ].map { $0.hasPrefix(".") ? "    " + $0 : $0 }
    }

    /// The turn of a leaf, clockwise, about its centre: nothing when it is upright.
    static func turn(_ element: Leaf) -> [String] {
        element.resolvedRotation == 0 ? [] : ["    .rotationEffect(.degrees(\(number(CGFloat(element.resolvedRotation)))))"]
    }

    /// The border, shadow and opacity that any leaf can have.
    private static func finish(_ element: Leaf) -> [String] {
        var lines: [String] = []
        if element.hasBorder, element.resolvedBorderWidth > 0 {
            let shape = element.isCircular
                ? "Circle()"
                : element.kind == .button && element.cornerRadius == nil
                    ? "Capsule()"
                    : "RoundedRectangle(cornerRadius: \(number(element.hasCornerRadius ? element.resolvedCornerRadius : 0)))"
            lines += [
                "    .overlay {",
                "        \(shape)",
                "            .strokeBorder(\(color(element.resolvedBorderColor)), lineWidth: \(number(element.resolvedBorderWidth)))",
                "    }",
            ]
        }
        if element.hasShadow {
            lines.append("    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)")
        }
        if element.resolvedOpacity < 1 {
            lines.append("    .opacity(\(number(element.resolvedOpacity)))")
        }
        return lines
    }

    /// The font modifier's argument: the kind's usual font unless the leaf has its own.
    private static func font(of element: Leaf, usual: String?) -> String {
        if element.fontSize == nil, element.fontWeight == nil, let usual { return usual }
        return systemFont(size: element.resolvedFontSize, weight: element.resolvedFontWeight)
    }

    /// A body's or a text's font: its kind's text style while it has no size or weight of its own and is drawn at the
    /// style's own size (`TextStyleSize`), as Layer's standard tokens draw it; otherwise its size and weight, as it is
    /// drawn at the design's own text sizes.
    private static func font(of element: Leaf, style: String, drawnAt styleSize: CGFloat) -> String {
        if element.fontSize == nil, element.fontWeight == nil, element.resolvedFontSize == styleSize { return style }
        return systemFont(size: element.resolvedFontSize, weight: element.resolvedFontWeight)
    }

    /// The system font at a size, with its weight where it isn't regular.
    private static func systemFont(size: CGFloat, weight: FontWeightChoice) -> String {
        weight == .regular
            ? ".system(size: \(number(size)))"
            : ".system(size: \(number(size)), weight: .\(weight.rawValue))"
    }

    private static func textColor(of element: Leaf, usual: String?) -> [String] {
        if let own = element.textColor { return ["    .foregroundStyle(\(color(own)))"] }
        return usual.map { [$0] } ?? []
    }

    /// A layer's name as an asset catalogue name: "Hero Photo" becomes `hero-photo`.
    static func assetName(_ name: String?) -> String? {
        guard let name else { return nil }
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }
}

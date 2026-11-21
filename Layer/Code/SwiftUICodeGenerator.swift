import CoreGraphics
import Foundation

/// Writes a screen out as a SwiftUI view. By default that is a vertical stack of its
/// elements, top to bottom, with the spacing, sizes and styling they have on the canvas;
/// `CodeSettings` can ask for every element at its exact place instead, a preview, and the
/// screen's title as its navigation title. Hidden elements are left out.
enum SwiftUICodeGenerator {
    private static let spacing: CGFloat = 16
    /// How far down a large navigation title pushes the content, below the status bar.
    private static let navigationBarHeight: CGFloat = 96

    static func fileName(for screen: DesignScreen) -> String {
        screen.typeName + ".swift"
    }

    /// The file a screen is written to among the design's `screens`, named after its view.
    static func fileName(for screen: DesignScreen, among screens: [DesignScreen]) -> String {
        (typeNames(for: screens)[screen.id] ?? screen.typeName) + ".swift"
    }

    /// The name of each screen's view, told apart where two would be the same: "Screen 2"
    /// again after a screen was deleted, or "Sign In" beside "Sign-In". Two files declaring
    /// the same view don't compile in one target. Names that differ only in case are told
    /// apart too, since a Mac's disk doesn't tell their files apart. The first keeps its name.
    static func typeNames(for screens: [DesignScreen]) -> [DesignScreen.ID: String] {
        var used: Set<String> = []
        var names: [DesignScreen.ID: String] = [:]
        for screen in screens {
            var name = screen.typeName
            var number = 2
            while used.contains(name.lowercased()) {
                name = "\(screen.typeName)\(number)"
                number += 1
            }
            used.insert(name.lowercased())
            names[screen.id] = name
        }
        return names
    }

    /// A screen's code, its view named as it is among the design's `screens`.
    static func code(for screen: DesignScreen, among screens: [DesignScreen], settings: CodeSettings = CodeSettings()) -> String {
        code(for: screen, typeName: typeNames(for: screens)[screen.id], settings: settings)
    }

    static func code(for screen: DesignScreen, typeName: String? = nil, settings: CodeSettings = CodeSettings()) -> String {
        let typeName = typeName ?? screen.typeName
        var elements = screen.elements.filter { !$0.isHidden }.sorted { $0.frame.minY < $1.frame.minY }

        // The topmost title becomes the navigation title rather than a view of its own.
        var navigationTitle: String?
        if settings.usesNavigationTitle, let index = elements.firstIndex(where: { $0.kind == .title }) {
            navigationTitle = elements.remove(at: index).text
        }

        var root = switch settings.layout {
        case .stack: stack(elements, on: screen.device, belowNavigationBar: navigationTitle != nil)
        case .absolute: absolute(elements)
        }
        if let navigationTitle {
            root = ["NavigationStack {"] + indented(root + [".navigationTitle(\(literal(navigationTitle)))"]) + ["}"]
        }

        var lines = ["import SwiftUI", "", "struct \(typeName): View {", "    var body: some View {"]
        lines += root.map { "        " + $0 }
        lines += ["    }", "}"]
        if settings.includesPreview {
            lines += ["", "#Preview {", "    \(typeName)()", "}"]
        }
        return lines.joined(separator: "\n")
    }

    /// Every screen of a design, as files named after their views, each view a name of its own.
    static func files(for screens: [DesignScreen], settings: CodeSettings = CodeSettings()) -> [(name: String, source: String)] {
        let names = typeNames(for: screens)
        return screens.map { screen in
            let typeName = names[screen.id] ?? screen.typeName
            return (typeName + ".swift", code(for: screen, typeName: typeName, settings: settings))
        }
    }

    private static func indented(_ lines: [String]) -> [String] {
        lines.map { "    " + $0 }
    }

    // MARK: A vertical stack

    private static func stack(_ elements: [DesignElement], on device: DeviceFrame, belowNavigationBar: Bool) -> [String] {
        let width = device.size.width
        let margin = elements.map { min($0.frame.minX, width - $0.frame.maxX) }.min().map { max(0, $0) } ?? 0
        let contentWidth = width - margin * 2
        let topEdge = device.safeTop + (belowNavigationBar ? navigationBarHeight : 0)

        var body: [String] = []
        var previousBottom: CGFloat?
        var usesSpacer = false

        let rows = Self.rows(of: elements)
        for (index, row) in rows.enumerated() {
            let element = row[0]
            let bounds = row.dropFirst().reduce(element.frame) { $0.union($1.frame) }
            var lines = row.count == 1
                ? view(for: element, margin: margin, contentWidth: contentWidth, screenWidth: width)
                : horizontalStack(row, margin: margin)
            if let previousBottom {
                let gap = bounds.minY - previousBottom
                let isLast = index == rows.count - 1
                let hugsBottom = device.size.height - bounds.maxY <= device.safeBottom + 60
                if isLast, hugsBottom, gap > spacing * 2 {
                    // A last element near the bottom edge is pinned there rather than spaced down.
                    body.append("Spacer()")
                    usesSpacer = true
                } else if gap - spacing >= 2 {
                    lines.append("    .padding(.top, \(number(gap - spacing)))")
                }
            }
            if row.count == 1, let name = element.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.insert("// \(commentText(name))", at: 0)
            }
            body += lines
            previousBottom = bounds.maxY
        }

        guard !body.isEmpty else { return ["Color.clear"] }
        var lines = ["VStack(alignment: .leading, spacing: \(number(spacing))) {"]
        lines += indented(body)
        lines.append("}")
        if margin > 0 { lines.append(".padding(.horizontal, \(number(margin)))") }
        if let first = elements.first, first.frame.minY - topEdge >= 1 {
            lines.append(".padding(.top, \(number(first.frame.minY - topEdge)))")
        }
        if usesSpacer, let last = elements.last {
            let inset = device.size.height - device.safeBottom - last.frame.maxY
            if inset >= 1 { lines.append(".padding(.bottom, \(number(inset)))") }
        } else {
            lines.append(".frame(maxHeight: .infinity, alignment: .top)")
        }
        return lines
    }

    /// Groups elements, sorted top to bottom, into rows: elements side by side, sharing
    /// most of their height and none of the screen's width, go in one row, leading first.
    static func rows(of elements: [DesignElement]) -> [[DesignElement]] {
        var rows: [[DesignElement]] = []
        for element in elements {
            if let last = rows.last, last.allSatisfy({ sharesRow($0.frame, element.frame) }) {
                rows[rows.count - 1].append(element)
            } else {
                rows.append([element])
            }
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    private static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let apart = a.maxX <= b.minX || b.maxX <= a.minX
        return apart && overlap >= min(a.height, b.height) * 0.5
    }

    /// A row of elements side by side, each at its own width, spaced as on the canvas.
    private static func horizontalStack(_ row: [DesignElement], margin: CGFloat) -> [String] {
        let spacing = zip(row, row.dropFirst()).map { $1.frame.minX - $0.frame.maxX }.min() ?? 0
        var body: [String] = []
        for (element, next) in zip(row, row.dropFirst().map { Optional($0) } + [nil]) {
            if let name = element.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append("// \(commentText(name))")
            }
            // Each element at its own width, flush with the one before it.
            body += view(for: element, margin: element.frame.minX, contentWidth: .infinity, screenWidth: .infinity)
            if let next, next.frame.minX - element.frame.maxX - spacing >= 2 {
                body.append("Spacer(minLength: \(number(next.frame.minX - element.frame.maxX - spacing)))")
            }
        }
        var lines = ["HStack(alignment: .center, spacing: \(number(spacing))) {"] + indented(body) + ["}"]
        if let first = row.first, first.frame.minX - margin >= 1 {
            lines.append("    .padding(.leading, \(number(first.frame.minX - margin)))")
        }
        return lines
    }

    private static func view(for element: DesignElement, margin: CGFloat, contentWidth: CGFloat, screenWidth: CGFloat) -> [String] {
        let frame = element.frame
        let fillsWidth = frame.width >= contentWidth - 1
        let centered = ElementLayout.isCentered(frame, in: screenWidth)
        /// Places a fixed-width view where it sits on the canvas: centred, or inset from the leading edge.
        var placement: [String] {
            if fillsWidth { return [] }
            if centered { return ["    .frame(maxWidth: .infinity)"] }
            let inset = frame.minX - margin
            return inset >= 1 ? ["    .padding(.leading, \(number(inset)))"] : []
        }
        /// The view up to its sized frame, and the placement modifiers that follow it.
        var lines: [String]
        var tail = placement

        switch element.kind {
        case .title:
            let alignment = element.textAlignment.map { $0.rawValue } ?? "leading"
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: titleFont(height: frame.height))))",
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
                "    .font(\(font(of: element, usual: ".subheadline")))",
            ] + textColor(of: element, usual: nil) + [
                "    .multilineTextAlignment(.\(element.resolvedTextAlignment.rawValue))",
                fillsWidth ? "    .frame(maxWidth: .infinity)" : "    .frame(width: \(number(frame.width)))",
            ]

        case .text:
            let alignment = element.resolvedTextAlignment
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: ".body")))",
            ] + textColor(of: element, usual: nil)
                + (alignment == .leading ? [] : ["    .multilineTextAlignment(.\(alignment.rawValue))"])
                + ["    .frame(width: \(number(frame.width)), alignment: .\(alignment.rawValue))"]


        case .image, .avatar:
            lines = picture(element)

        case .button:
            lines = button(element, frame: fillsWidth
                ? "        .frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                : "        .frame(width: \(number(frame.width)), height: \(number(frame.height)))")

        case .textField:
            lines = [
                "TextField(\(literal(element.text)), text: .constant(\"\"))",
            ] + (element.resolvedTextAlignment == .leading ? [] : ["    .multilineTextAlignment(.\(element.resolvedTextAlignment.rawValue))"]) + [
                "    .padding(.horizontal, 16)",
                fillsWidth
                    ? "    .frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                    : "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
                "    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
            ]

        case .symbol:
            lines = [
                "Image(systemName: \(literal(element.symbol ?? "questionmark.square.dashed")))",
                "    .resizable()",
                "    .scaledToFit()",
                "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
            ] + (element.tint == Theme.inkTint ? [] : ["    .foregroundStyle(\(color(element.tint)))"])

        case .divider:
            lines = ["Divider()"] + (fillsWidth ? [] : ["    .frame(width: \(number(frame.width)))"])

        case .shape:
            lines = shape(element) + ["    .frame(width: \(number(frame.width)), height: \(number(frame.height)))"]

        case .toggle:
            lines = toggle(element)

        case .checkbox, .radio:
            lines = control(element)

        case .progress:
            lines = progress(element) + (fillsWidth ? [] : ["    .frame(width: \(number(frame.width)))"])

        case .stickyNote:
            // Sticky notes stay on the canvas; this is only here to keep the switch whole.
            lines = ["Text(\(literal(element.text)))"]

        case .drawing:
            // Ink is a note about the design, not part of the interface: no code for it.
            return []
        }

        // An element is finished before it is placed, so that its border goes round it, as on
        // the canvas, rather than round the width it is centred in or the padding that insets
        // it. A turned one is turned in between, so its border and shadow turn with it.
        return lines + finish(element) + turn(element) + tail
    }

    // MARK: Exact positions

    /// Every element at its place on the screen, measured from the screen's top-left
    /// corner, which is why the stack reaches under the status bar.
    private static func absolute(_ elements: [DesignElement]) -> [String] {
        guard !elements.isEmpty else { return ["Color.clear"] }
        var body = ["Color.clear"]
        for element in elements {
            if let name = element.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                body.append("// \(commentText(name))")
            }
            body += positioned(element)
        }
        return ["ZStack(alignment: .topLeading) {"] + indented(body) + [
            "}",
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)",
            ".ignoresSafeArea()",
        ]
    }

    private static func positioned(_ element: DesignElement) -> [String] {
        let frame = element.frame
        let size = "width: \(number(frame.width)), height: \(number(frame.height))"
        let alignment = element.resolvedTextAlignment.rawValue
        var lines: [String]

        switch element.kind {
        case .title, .body, .text, .stickyNote:
            let usual = switch element.kind {
            case .title: titleFont(height: frame.height) ?? ".title.bold()"
            case .body: ".subheadline"
            default: ".body"
            }
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: usual)))",
            ] + textColor(of: element, usual: nil)
                + (alignment == "leading" ? [] : ["    .multilineTextAlignment(.\(alignment))"])
                + (element.kind == .stickyNote
                    ? ["    .padding(12)", "    .frame(\(size), alignment: .\(alignment))", "    .background(\(color(element.tint)), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))"]
                    : ["    .frame(\(size), alignment: .\(alignment))"])

        case .image, .avatar:
            lines = picture(element)

        case .button:
            lines = button(element, frame: "        .frame(\(size))")

        case .textField:
            lines = [
                "TextField(\(literal(element.text)), text: .constant(\"\"))",
                "    .padding(.horizontal, 16)",
                "    .frame(\(size))",
                "    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
            ]

        case .symbol:
            lines = [
                "Image(systemName: \(literal(element.symbol ?? "questionmark.square.dashed")))",
                "    .resizable()",
                "    .scaledToFit()",
                "    .frame(\(size))",
            ] + (element.tint == Theme.inkTint ? [] : ["    .foregroundStyle(\(color(element.tint)))"])

        case .divider:
            lines = ["Divider()", "    .frame(width: \(number(frame.width)))"]

        case .shape:
            lines = shape(element) + ["    .frame(\(size))"]

        case .toggle:
            lines = toggle(element) + ["    .frame(\(size))"]

        case .checkbox, .radio:
            lines = control(element)

        case .progress:
            lines = progress(element) + ["    .frame(width: \(number(frame.width)))"]

        case .drawing:
            return []
        }

        return lines + finish(element) + turn(element) + ["    .offset(x: \(number(frame.minX)), y: \(number(frame.minY)))"]
    }

    // MARK: Pieces shared by both layouts

    private static func picture(_ element: DesignElement) -> [String] {
        let frame = element.frame
        let fallback = element.kind == .avatar ? "avatar" : "photo"
        let shape = element.isCircular ? ".circle" : ".rect(cornerRadius: \(number(element.resolvedCornerRadius)))"
        return [
            "Image(\(literal(assetName(element.name) ?? fallback)))",
            "    .resizable()",
            "    .scaledToFill()",
            "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
            "    .clipShape(\(shape))",
        ]
    }

    /// The text style a title of this height is drawn in: Title 2, Title or Large Title.
    private static func titleFont(height: CGFloat) -> String? {
        switch height {
        case 31...33: ".title2.bold()"
        case 39...41: ".title.bold()"
        case 47...49: ".largeTitle.bold()"
        default: nil
        }
    }

    /// A button in its look. `frame` is the label's frame modifier, indented.
    private static func button(_ element: DesignElement, frame: String) -> [String] {
        let look = element.resolvedButtonLook
        let tint = color(element.tint)
        var lines = [
            "Button {",
            "} label: {",
            "    Text(\(literal(element.text)))",
            "        .font(\(font(of: element, usual: ".headline")))",
            "        .foregroundStyle(\(element.textColor.map(color) ?? (look == .filled ? ".white" : tint)))",
            frame,
        ]
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

    /// A checkbox or radio button, drawn with the symbols iOS uses for them.
    private static func control(_ element: DesignElement) -> [String] {
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
            "    .frame(width: \(number(element.frame.width)), height: \(number(element.frame.height)))",
            "    .foregroundStyle(\(element.isOn ? color(element.tint) : ".secondary"))",
        ]
    }

    private static func progress(_ element: DesignElement) -> [String] {
        // To the hundredth, which `number` would round away.
        ["ProgressView(value: \((element.resolvedValue * 100).rounded() / 100))"]
            + (element.tint == Theme.accent ? [] : ["    .tint(\(color(element.tint)))"])
    }

    private static func toggle(_ element: DesignElement) -> [String] {
        [
            "Toggle(\(literal(element.name ?? "")), isOn: .constant(\(element.isOn)))",
            "    .labelsHidden()",
        ] + (element.tint == Theme.accent ? [] : ["    .tint(\(color(element.tint)))"])
    }

    /// A shape, filled or outlined in its colour, without its frame. SwiftUI's own shapes
    /// where there is one; otherwise its outline as a path, at the element's size.
    private static func shape(_ element: DesignElement) -> [String] {
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

    /// The turn of an element, clockwise, about its centre: nothing when it is upright.
    private static func turn(_ element: DesignElement) -> [String] {
        element.resolvedRotation == 0 ? [] : ["    .rotationEffect(.degrees(\(number(CGFloat(element.resolvedRotation)))))"]
    }

    /// The border, shadow and opacity that any element can have.
    private static func finish(_ element: DesignElement) -> [String] {
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

    /// The font modifier's argument: the kind's usual font unless the element has its own.
    private static func font(of element: DesignElement, usual: String?) -> String {
        if element.fontSize == nil, element.fontWeight == nil, let usual { return usual }
        let weight = element.resolvedFontWeight
        return weight == .regular
            ? ".system(size: \(number(element.resolvedFontSize)))"
            : ".system(size: \(number(element.resolvedFontSize)), weight: .\(weight.rawValue))"
    }

    private static func textColor(of element: DesignElement, usual: String?) -> [String] {
        if let own = element.textColor { return ["    .foregroundStyle(\(color(own)))"] }
        return usual.map { [$0] } ?? []
    }

    /// A layer's name as an asset catalogue name: "Hero Photo" becomes `hero-photo`.
    static func assetName(_ name: String?) -> String? {
        guard let name else { return nil }
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }
        return words.isEmpty ? nil : words.joined(separator: "-")
    }

    // MARK: Literals

    /// Text as a Swift string literal. A carriage return or another control character,
    /// pasted from Windows or set by a Siri intent, is escaped too: left in, it ended the
    /// literal, and the file didn't compile.
    private static func literal(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: escaped += String(format: "\\u{%02X}", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// A layer's name for a comment line: a line break or control character in it would
    /// end the comment and leave the rest of the name as code.
    private static func commentText(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }

    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        // Past what an Int holds it is written as it is: a size like that is a mistake,
        // but writing it out mustn't stop the app.
        guard rounded.magnitude < 1e15 else { return String(Double(rounded)) }
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    private static func color(_ tint: RGBColor) -> String {
        func component(_ value: Double) -> String { String(format: "%.2f", value) }
        return "Color(red: \(component(tint.red)), green: \(component(tint.green)), blue: \(component(tint.blue)))"
    }
}

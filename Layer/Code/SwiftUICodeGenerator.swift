import CoreGraphics
import Foundation

/// Writes a screen out as a SwiftUI view: a vertical stack of its elements, top to bottom,
/// with the spacing, sizes and styling they have on the canvas.
enum SwiftUICodeGenerator {
    private static let spacing: CGFloat = 16

    static func fileName(for screen: DesignScreen) -> String {
        screen.typeName + ".swift"
    }

    static func code(for screen: DesignScreen) -> String {
        let device = screen.device
        let elements = screen.elements.sorted { $0.frame.minY < $1.frame.minY }
        let width = device.size.width
        let margin = elements.map { min($0.frame.minX, width - $0.frame.maxX) }.min().map { max(0, $0) } ?? 0
        let contentWidth = width - margin * 2

        var body: [String] = []
        var previousBottom: CGFloat?
        var usesSpacer = false

        for (index, element) in elements.enumerated() {
            var lines = view(for: element, margin: margin, contentWidth: contentWidth, screenWidth: width)
            if let previousBottom {
                let gap = element.frame.minY - previousBottom
                let isLast = index == elements.count - 1
                let hugsBottom = device.size.height - element.frame.maxY <= device.safeBottom + 60
                if isLast, hugsBottom, gap > spacing * 2 {
                    // A last element near the bottom edge is pinned there rather than spaced down.
                    body.append("Spacer()")
                    usesSpacer = true
                } else if gap - spacing >= 2 {
                    lines.append("    .padding(.top, \(number(gap - spacing)))")
                }
            }
            body += lines
            previousBottom = element.frame.maxY
        }

        var lines = ["import SwiftUI", "", "struct \(screen.typeName): View {", "    var body: some View {"]
        if body.isEmpty {
            lines.append("        Color.clear")
        } else {
            lines.append("        VStack(alignment: .leading, spacing: \(number(spacing))) {")
            lines += body.map { "            " + $0 }
            lines.append("        }")
            if margin > 0 { lines.append("        .padding(.horizontal, \(number(margin)))") }
            if let first = elements.first, first.frame.minY - device.safeTop >= 1 {
                lines.append("        .padding(.top, \(number(first.frame.minY - device.safeTop)))")
            }
            if usesSpacer, let last = elements.last {
                let inset = device.size.height - device.safeBottom - last.frame.maxY
                if inset >= 1 { lines.append("        .padding(.bottom, \(number(inset)))") }
            } else {
                lines.append("        .frame(maxHeight: .infinity, alignment: .top)")
            }
        }
        lines += ["    }", "}"]
        return lines.joined(separator: "\n")
    }

    // MARK: Elements

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
        let lines: [String]

        switch element.kind {
        case .title:
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: abs(frame.height - 40) < 1 ? ".title.bold()" : nil)))",
            ] + textColor(of: element, usual: nil) + (centered
                ? ["    .frame(maxWidth: .infinity)", "    .multilineTextAlignment(.center)"]
                : ["    .frame(width: \(number(frame.width)), alignment: .leading)"] + placement)

        case .body:
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: ".footnote")))",
            ] + textColor(of: element, usual: "    .foregroundStyle(.secondary)") + [
                "    .multilineTextAlignment(.center)",
                fillsWidth ? "    .frame(maxWidth: .infinity)" : "    .frame(width: \(number(frame.width)))",
            ] + placement

        case .text:
            lines = [
                "Text(\(literal(element.text)))",
                "    .font(\(font(of: element, usual: ".body")))",
            ] + textColor(of: element, usual: nil) + [
                "    .frame(width: \(number(frame.width)), alignment: .leading)",
            ] + placement

        case .image:
            lines = [
                "Image(\"photo\")",
                "    .resizable()",
                "    .scaledToFill()",
                "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
                "    .clipShape(.rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
            ] + placement

        case .button:
            let shape = element.cornerRadius.map { ".rect(cornerRadius: \(number($0)))" } ?? ".capsule"
            lines = [
                "Button {",
                "} label: {",
                "    Text(\(literal(element.text)))",
                "        .font(\(font(of: element, usual: ".headline")))",
                "        .foregroundStyle(\(element.textColor.map(color) ?? ".white"))",
                fillsWidth
                    ? "        .frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                    : "        .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
                "        .background(\(color(element.tint)), in: \(shape))",
                "}",
            ] + placement

        case .textField:
            lines = [
                "TextField(\(literal(element.text)), text: .constant(\"\"))",
                "    .padding(.horizontal, 16)",
                fillsWidth
                    ? "    .frame(maxWidth: .infinity, minHeight: \(number(frame.height)))"
                    : "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
                "    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: \(number(element.resolvedCornerRadius))))",
            ] + placement

        case .symbol:
            lines = [
                "Image(systemName: \(literal(element.symbol ?? "questionmark.square.dashed")))",
                "    .resizable()",
                "    .scaledToFit()",
                "    .frame(width: \(number(frame.width)), height: \(number(frame.height)))",
            ] + (element.tint == Theme.inkTint ? [] : ["    .foregroundStyle(\(color(element.tint)))"]) + placement

        case .divider:
            lines = ["Divider()"] + (fillsWidth ? [] : ["    .frame(width: \(number(frame.width)))"] + placement)

        case .stickyNote:
            // Sticky notes stay on the canvas; this is only here to keep the switch whole.
            lines = ["Text(\(literal(element.text)))"]
        }

        return element.resolvedOpacity < 1 ? lines + ["    .opacity(\(number(element.resolvedOpacity)))"] : lines
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

    // MARK: Literals

    private static func literal(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    private static func color(_ tint: RGBColor) -> String {
        func component(_ value: Double) -> String { String(format: "%.2f", value) }
        return "Color(red: \(component(tint.red)), green: \(component(tint.green)), blue: \(component(tint.blue)))"
    }
}

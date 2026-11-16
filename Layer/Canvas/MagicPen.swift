import PencilKit
import UIKit

/// The palette's custom tool: a pen whose sketches become design elements.
enum MagicPen {
    static let identifier = "app.layer.magic-pen"

    /// Everything in the palette: the Magic Pen first, then all of PencilKit's own tools.
    @MainActor
    static func paletteItems() -> [PKToolPickerItem] {
        var configuration = PKToolPickerCustomItem.Configuration(identifier: identifier, name: "Magic Pen")
        configuration.imageProvider = { _ in image }
        // Its ink is always the canvas's ink colour; the accent colour has its own control.
        configuration.allowsColorSelection = false
        configuration.toolAttributeControls = []

        let inks: [PKInkingTool.InkType] = [.pen, .monoline, .pencil, .marker, .fountainPen, .watercolor, .crayon, .reed]
        return [PKToolPickerCustomItem(configuration: configuration)]
            + inks.map { PKToolPickerInkingItem(type: $0) }
            + [PKToolPickerEraserItem(type: .vector), PKToolPickerLassoItem(), PKToolPickerRulerItem()]
    }

    /// The pen as it appears in the palette, tip up like the system's tools.
    static let image: UIImage = {
        let size = CGSize(width: 44, height: 132)
        let accent = Theme.accent.uiColor.cgColor
        let graphite = CGColor(red: 0.17, green: 0.165, blue: 0.153, alpha: 1)
        let cream = CGColor(red: 0.96, green: 0.94, blue: 0.9, alpha: 1)

        return UIGraphicsImageRenderer(size: size).image { renderer in
            let context = renderer.cgContext
            func fill(_ color: CGColor, _ points: [CGPoint]) {
                context.setFillColor(color)
                context.addLines(between: points)
                context.closePath()
                context.fillPath()
            }

            // Tip, with the nib in the accent colour.
            fill(cream, [CGPoint(x: 22, y: 4), CGPoint(x: 34, y: 42), CGPoint(x: 10, y: 42)])
            fill(accent, [CGPoint(x: 22, y: 4), CGPoint(x: 27, y: 20), CGPoint(x: 17, y: 20)])

            // Collar and barrel.
            context.setFillColor(accent)
            context.fill(CGRect(x: 10, y: 42, width: 24, height: 9))
            context.setFillColor(graphite)
            context.fill(CGRect(x: 10, y: 51, width: 24, height: size.height - 51))
            context.setFillColor(CGColor(gray: 1, alpha: 0.14))
            context.fill(CGRect(x: 13, y: 51, width: 3, height: size.height - 51))

            // A four-point sparkle on the barrel.
            let center = CGPoint(x: 23, y: 78)
            fill(cream, (0..<8).map { index in
                let angle = CGFloat(index) * .pi / 4 - .pi / 2
                let radius: CGFloat = index.isMultiple(of: 2) ? 8 : 2.6
                return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
            })
        }
    }()
}

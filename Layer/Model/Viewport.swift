import CoreGraphics

/// Which part of the canvas is on screen, and how large it is shown.
struct Viewport: Equatable, Sendable {
    /// The canvas is a fixed, very large sheet that stands in for an endless one. New
    /// designs start in its middle, with room to grow in every direction.
    static let canvasSize = CGSize(width: 20_000, height: 20_000)
    static let zoomRange: ClosedRange<CGFloat> = 0.1...4

    /// The view's top-left corner, in canvas points multiplied by `scale`.
    var offset: CGPoint = .zero
    var scale: CGFloat = 1

    func viewPoint(for canvas: CGPoint) -> CGPoint {
        CGPoint(x: canvas.x * scale - offset.x, y: canvas.y * scale - offset.y)
    }

    func viewRect(for canvas: CGRect) -> CGRect {
        CGRect(origin: viewPoint(for: canvas.origin), size: CGSize(width: canvas.width * scale, height: canvas.height * scale))
    }

    func canvasPoint(for view: CGPoint) -> CGPoint {
        CGPoint(x: (view.x + offset.x) / scale, y: (view.y + offset.y) / scale)
    }

    func canvasRect(for view: CGRect) -> CGRect {
        CGRect(origin: canvasPoint(for: view.origin), size: CGSize(width: view.width / scale, height: view.height / scale))
    }

    /// The part of the canvas a view of this size shows.
    func visibleRect(in viewSize: CGSize) -> CGRect {
        canvasRect(for: CGRect(origin: .zero, size: viewSize))
    }

    /// The viewport that shows `rect` whole and centred in a view of `viewSize`, zoomed in
    /// no further than `maximumScale`.
    static func fitting(_ rect: CGRect, in viewSize: CGSize, padding: CGFloat = 80, maximumScale: CGFloat = 1) -> Viewport {
        fitting(rect, within: CGRect(origin: .zero, size: viewSize), padding: padding, maximumScale: maximumScale)
    }

    /// The viewport that shows `rect` whole and centred in `area`, the part of the view
    /// that bars and controls leave clear, zoomed in no further than `maximumScale`.
    static func fitting(_ rect: CGRect, within area: CGRect, padding: CGFloat = 12, maximumScale: CGFloat = 1) -> Viewport {
        let available = CGSize(width: max(area.width - padding * 2, 1), height: max(area.height - padding * 2, 1))
        let fit = min(available.width / max(rect.width, 1), available.height / max(rect.height, 1))
        let scale = min(max(min(fit, maximumScale), zoomRange.lowerBound), zoomRange.upperBound)
        return Viewport(offset: CGPoint(x: rect.midX * scale - area.midX, y: rect.midY * scale - area.midY), scale: scale)
    }

    /// The viewport that puts `center` in the middle of a view of `viewSize`.
    static func centered(on center: CGPoint, scale: CGFloat, in viewSize: CGSize) -> Viewport {
        Viewport(
            offset: CGPoint(x: center.x * scale - viewSize.width / 2, y: center.y * scale - viewSize.height / 2),
            scale: scale
        )
    }
}

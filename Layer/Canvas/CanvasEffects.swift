import SwiftUI
import UIKit

/// The grid behind everything: dots or lines, or nothing. It moves and scales with the
/// canvas, and drops to every second, fourth, eighth mark as the canvas shrinks so it
/// never crowds.
struct CanvasGrid: View {
    var viewport = Viewport()
    var settings = CanvasSettings()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            guard settings.showsGrid else { return }
            var step = max(settings.gridSpacing, 4)
            while step * viewport.scale < 14 { step *= 2 }
            // A whole number of pixels between marks, so that the tile repeats exactly and
            // marks don't creep as the canvas scrolls.
            let pixels = max((step * viewport.scale * displayScale).rounded(), 2)
            let gap = pixels / displayScale
            let origin = CGPoint(
                x: -(viewport.offset.x.truncatingRemainder(dividingBy: gap)),
                y: -(viewport.offset.y.truncatingRemainder(dividingBy: gap))
            )
            // One tile, repeated by the GPU, rather than thousands of marks drawn every frame.
            let tile = GridTile.image(pixels: Int(pixels), style: settings.gridStyle, isDark: settings.isDark, viewScale: viewport.scale, displayScale: displayScale)
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .tiledImage(Image(uiImage: tile), origin: origin, scale: 1)
            )
        }
        .background(settings.resolvedBackground.color)
    }
}

/// One repeat of the canvas grid: a dot, or a line along two edges, in a square.
@MainActor
private enum GridTile {
    private struct Key: Hashable {
        var pixels: Int
        var style: CanvasSettings.GridStyle
        var isDark: Bool
        var radius: Int
        var displayScale: CGFloat
    }

    private static var cache: [Key: UIImage] = [:]

    /// `isDark` is whether the canvas behind is dark, which the marks are lightened for.
    static func image(pixels: Int, style: CanvasSettings.GridStyle, isDark: Bool, viewScale: CGFloat, displayScale: CGFloat) -> UIImage {
        let radius = min(max(0.75 * viewScale.squareRoot(), 0.6), 1.3)
        let key = Key(pixels: pixels, style: style, isDark: isDark, radius: Int(radius * 20), displayScale: displayScale)
        if let cached = cache[key] { return cached }
        if cache.count > 64 { cache.removeAll() }

        let side = CGFloat(pixels) / displayScale
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { renderer in
            let context = renderer.cgContext
            let color = isDark ? UIColor.white.withAlphaComponent(0.22) : UIColor(Theme.gridDot)
            switch style {
            case .dots:
                // The dot sits on the tile's corner, as the marks sit on multiples of the
                // spacing; its four quarters are drawn at the four corners.
                context.setFillColor(color.cgColor)
                for corner in [CGPoint.zero, CGPoint(x: side, y: 0), CGPoint(x: 0, y: side), CGPoint(x: side, y: side)] {
                    context.fillEllipse(in: CGRect(x: corner.x - radius, y: corner.y - radius, width: radius * 2, height: radius * 2))
                }
            case .lines:
                context.setFillColor(color.withAlphaComponent(0.55).cgColor)
                let width = max(0.5, 1 / displayScale)
                context.fill(CGRect(x: 0, y: 0, width: side, height: width))
                context.fill(CGRect(x: 0, y: 0, width: width, height: side))
            }
        }
        cache[key] = image
        return image
    }
}

/// Re-traces a sketch in the accent colour while it is being read.
struct RetraceView: View {
    let effect: RetraceEffect
    let accent: Color
    @State private var progress: CGFloat = 0

    var body: some View {
        let path = Path { path in
            for stroke in effect.strokes where stroke.count >= 2 {
                path.addLines(stroke)
            }
        }
        let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        ZStack(alignment: .topLeading) {
            if let band = effect.band {
                Capsule()
                    .fill(accent.opacity(0.55))
                    .frame(width: band.width * progress, height: 3)
                    .blur(radius: 1.5)
                    .background {
                        Capsule().fill(accent.opacity(0.35)).blur(radius: 9).padding(-7)
                    }
                    .position(x: band.midX, y: band.midY)
            }
            path.trim(from: 0, to: progress)
                .stroke(accent.opacity(0.45), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                .blur(radius: 6)
            path.trim(from: 0, to: progress)
                .stroke(accent, style: style)
            Spark(points: effect.strokes.flatMap { $0 }, progress: progress)
                .foregroundStyle(accent)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.65)) { progress = 1 }
        }
    }
}

/// A sketch that wasn't recognised, fading out of existence.
struct GhostView: View {
    let ghost: InkGhost
    @State private var isFading = false

    var body: some View {
        Path { path in
            for stroke in ghost.strokes where stroke.count >= 2 {
                path.addLines(stroke)
            }
        }
        .stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        .opacity(isFading ? 0 : 1)
        .blur(radius: isFading ? 3 : 0)
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { isFading = true }
        }
    }
}

/// A small starburst that rides the leading end of the re-trace.
private struct Spark: View, Animatable {
    let points: [CGPoint]
    var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        if let point = point(at: progress) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .bold))
                .rotationEffect(.degrees(progress * 180))
                .position(point)
        }
    }

    /// The point a given fraction of the way along the strokes, by length.
    private func point(at fraction: CGFloat) -> CGPoint? {
        guard let first = points.first else { return nil }
        let lengths = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        var remaining = lengths.reduce(0, +) * min(max(fraction, 0), 1)
        for (index, length) in lengths.enumerated() {
            if remaining <= length, length > 0 {
                let t = remaining / length
                return CGPoint(
                    x: points[index].x + (points[index + 1].x - points[index].x) * t,
                    y: points[index].y + (points[index + 1].y - points[index].y) * t
                )
            }
            remaining -= length
        }
        return points.last ?? first
    }
}

/// A soft glow round the edge of the canvas while sketches are being read.
struct EdgeGlow: View {
    let accent: Color
    let isActive: Bool

    var body: some View {
        // Only there while it shows: a blurred layer the size of the screen costs every
        // frame it exists, even at no opacity.
        ZStack {
            if isActive {
                Rectangle()
                    .strokeBorder(accent.opacity(0.7), lineWidth: 5)
                    .blur(radius: 9)
                    .overlay { Rectangle().strokeBorder(accent.opacity(0.5), lineWidth: 1.5) }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isActive)
        .allowsHitTesting(false)
    }
}

/// The red dot that marks the pen tip, with its halo and the pen's shadow.
struct PenCursor: View {
    let pen: PenTracker

    var body: some View {
        if let location = pen.location {
            ZStack {
                // The pen's shadow, soft-edged by its gradient rather than by a blur,
                // which would be redrawn for every movement of the pen.
                Capsule()
                    .fill(EllipticalGradient(colors: [.black.opacity(0.10), .black.opacity(0.04), .clear], center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                    .frame(width: 190, height: 38)
                    .offset(x: 95)
                    .rotationEffect(.degrees(16))
                Circle()
                    .fill(RadialGradient(colors: [Theme.penDot.opacity(0.28), .clear], center: .center, startRadius: 0, endRadius: 30))
                    .frame(width: 60, height: 60)
                Circle()
                    .fill(Theme.penDot)
                    .frame(width: 6, height: 6)
            }
            .position(location)
            .allowsHitTesting(false)
        }
    }
}

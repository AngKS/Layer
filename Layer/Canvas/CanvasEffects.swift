import SwiftUI

/// The grid behind everything: dots or lines, or nothing. It moves and scales with the
/// canvas, and drops to every second, fourth, eighth mark as the canvas shrinks so it
/// never crowds.
struct CanvasGrid: View {
    var viewport = Viewport()
    var settings = CanvasSettings()

    var body: some View {
        Canvas { context, size in
            guard settings.showsGrid else { return }
            var step = max(settings.gridSpacing, 4)
            while step * viewport.scale < 14 { step *= 2 }
            let gap = step * viewport.scale
            // Marks sit on multiples of `step` in canvas points.
            let firstX = -viewport.offset.x.truncatingRemainder(dividingBy: gap) - gap
            let firstY = -viewport.offset.y.truncatingRemainder(dividingBy: gap) - gap

            var marks = Path()
            switch settings.gridStyle {
            case .dots:
                let radius = min(max(0.75 * viewport.scale.squareRoot(), 0.6), 1.3)
                var y = firstY
                while y < size.height + gap {
                    var x = firstX
                    while x < size.width + gap {
                        marks.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                        x += gap
                    }
                    y += gap
                }
                context.fill(marks, with: .color(Theme.gridDot))
            case .lines:
                var x = firstX
                while x < size.width + gap {
                    marks.move(to: CGPoint(x: x, y: 0))
                    marks.addLine(to: CGPoint(x: x, y: size.height))
                    x += gap
                }
                var y = firstY
                while y < size.height + gap {
                    marks.move(to: CGPoint(x: 0, y: y))
                    marks.addLine(to: CGPoint(x: size.width, y: y))
                    y += gap
                }
                context.stroke(marks, with: .color(Theme.gridDot.opacity(0.55)), lineWidth: 0.5)
            }
        }
        .background(Theme.canvas)
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
        Rectangle()
            .strokeBorder(accent.opacity(0.7), lineWidth: 5)
            .blur(radius: 9)
            .overlay { Rectangle().strokeBorder(accent.opacity(0.5), lineWidth: 1.5) }
            .opacity(isActive ? 1 : 0)
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
                Capsule()
                    .fill(.black.opacity(0.11))
                    .frame(width: 170, height: 20)
                    .blur(radius: 9)
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

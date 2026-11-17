import SwiftUI
import UIKit

/// Laid over the whole canvas: the pencil's bubble, where the squeeze opened it, and the
/// Pencil Pro's taps for when listening begins and when a command is sent.
struct PencilVoiceLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let pencil = model.pencilVoice
        ZStack(alignment: .topLeading) {
            if let bubble = pencil.bubble {
                PencilVoiceBubble(pencil: pencil, bubble: bubble, bounds: CGRect(origin: .zero, size: model.canvasSize), topInset: model.topBarBottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(duration: 0.35, bounce: 0.3), value: pencil.bubble == nil)
        // Behind the bubble and the size of the canvas, so the taps are felt at the tip's point.
        .background {
            PencilVoiceFeedback(bubble: pencil.bubble, retarget: pencil.retarget)
                .allowsHitTesting(false)
        }
    }
}

/// The bubble that swivels out of the pen's tip while the pencil listens: the model's icon
/// and the sound it hears, on the side away from the hand. The words heard show under the
/// sound if Settings asks for them; a problem always shows, so that a failure is never silent.
struct PencilVoiceBubble: View {
    let pencil: PencilVoice
    let bubble: PencilVoice.Bubble
    let bounds: CGRect
    let topInset: CGFloat

    @Environment(AppModel.self) private var model
    @AppStorage("pencilVoice.showsWords") private var showsWords = false
    /// Measured once laid out. Until then, about the size it opens at.
    @State private var size = CGSize(width: 190, height: 52)
    @State private var isMeasured = false

    /// How far the bubble keeps from the tip.
    nonisolated static let gap: CGFloat = 28
    /// How far it keeps from the window's edges.
    nonisolated static let margin: CGFloat = 12

    /// The bubble's top-left: `gap` from the tip in the direction away from the barrel, or
    /// below the tip when the pencil's angle isn't known, and kept inside `bounds` and clear
    /// of the bar above `topInset`.
    nonisolated static func origin(anchor: CGPoint, azimuth: Angle?, size: CGSize, in bounds: CGRect, topInset: CGFloat) -> CGPoint {
        var center: CGPoint
        if let azimuth {
            // The azimuth is the way the barrel points from the tip: the bubble goes the
            // other way, far enough that all of it is at least `gap` beyond the tip.
            let dx = -cos(azimuth.radians), dy = -sin(azimuth.radians)
            let reach = gap + abs(dx) * size.width / 2 + abs(dy) * size.height / 2
            center = CGPoint(x: anchor.x + dx * reach, y: anchor.y + dy * reach)
        } else {
            center = CGPoint(x: anchor.x, y: anchor.y + gap + size.height / 2)
        }
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let minY = max(inner.minY, topInset + margin)
        origin.x = max(min(origin.x, inner.maxX - size.width), inner.minX)
        origin.y = max(min(origin.y, inner.maxY - size.height), minY)
        return origin
    }

    var body: some View {
        let canvas = model.store.canvas
        let origin = Self.origin(anchor: bubble.anchor, azimuth: bubble.azimuth, size: size, in: bounds, topInset: topInset)
        // The tip, as a point of the canvas the bubble is laid out across: what it grows
        // out of and shrinks back to.
        let tip = UnitPoint(
            x: bounds.width > 0 ? bubble.anchor.x / bounds.width : 0.5,
            y: bounds.height > 0 ? bubble.anchor.y / bounds.height : 0.5
        )
        Button {
            pencil.tapBubble()
        } label: {
            content
                .padding(.vertical, 8)
                .padding(.leading, 8)
                .padding(.trailing, 14)
                .contentShape(.rect(cornerRadius: 26, style: .continuous))
        }
        .buttonStyle(.plain)
        // Tinted with the canvas, as the call's pill is.
        .glassEffect(.regular.tint(canvas.resolvedBackground.color.opacity(0.7)).interactive(), in: .rect(cornerRadius: 26, style: .continuous))
        .environment(\.colorScheme, canvas.isDark ? .dark : .light)
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { measured in
            // A bubble that grows or shrinks moves with it, so that its edge keeps its
            // distance from the tip: the move is animated as the change of size is. The first
            // measurement only corrects the guess, before anything is seen.
            if isMeasured {
                withAnimation(.snappy(duration: 0.25)) { size = measured }
            } else {
                size = measured
                isMeasured = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening with \(model.modelChoice.displayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Stops listening")
        .accessibilityIdentifier("pencil bubble")
        .reportsChromeFrame("pencil bubble", to: model)
        .offset(x: origin.x, y: origin.y)
        // Laid out across the whole canvas, so that the tip is a point of it to swivel round.
        // Only the bubble itself takes touches.
        .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
        // Outside the offset, so the place and the contents change together.
        .animation(.snappy(duration: 0.25), value: bubble.state)
        .animation(.snappy(duration: 0.25), value: wordsShown)
        .transition(.modifier(
            active: Swivel(scale: 0.2, angle: .degrees(-12), opacity: 0, anchor: tip),
            identity: Swivel(scale: 1, angle: .zero, opacity: 1, anchor: tip)
        ))
    }

    @ViewBuilder private var content: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.modelChoice.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(.primary.opacity(0.12), in: .circle)
            switch bubble.state {
            case .gettingReady, .listening:
                VStack(alignment: .leading, spacing: 4) {
                    PencilVoiceWaveform(pencil: pencil)
                        // Dim until the microphone is on: words now would be lost.
                        .opacity(bubble.state == .gettingReady ? 0.4 : 1)
                    if let words = wordsShown {
                        Text(words)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            // The newest words are the ones worth seeing.
                            .truncationMode(.head)
                            .frame(maxWidth: 220, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
            case .working:
                ProgressView()
                    .controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
            case .problem(let message):
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .frame(maxWidth: 280, alignment: .leading)
                }
            }
            if let queued = pencil.call?.queuedCount, queued > 0 {
                Text("+\(queued)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(queued) more waiting")
            }
        }
    }

    /// The words heard for this listen, when Settings asks for them.
    private var wordsShown: String? {
        showsWords ? pencil.wordsHeard : nil
    }

    private var accessibilityValue: String {
        switch bubble.state {
        case .gettingReady: "Getting ready"
        case .listening: "Listening"
        case .working: "Working"
        case .done: "Done"
        case .problem(let message): message
        }
    }
}

/// The waveform on its own, so that the levels, which change many times a second, redraw
/// only the bars.
private struct PencilVoiceWaveform: View {
    let pencil: PencilVoice

    var body: some View {
        CallWaveform(levels: pencil.levels)
    }
}

/// The bubble's entrance and exit: it swivels out of the tip, growing as it turns.
private struct Swivel: ViewModifier {
    let scale: CGFloat
    let angle: Angle
    let opacity: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .rotationEffect(angle, anchor: anchor)
            .opacity(opacity)
    }
}

/// The Pencil Pro's taps: one when listening has actually begun, so the person knows to
/// speak, and one when the command is sent. Felt at the tip's point, so a pencil hovering
/// there feels them.
private struct PencilVoiceFeedback: UIViewRepresentable {
    let bubble: PencilVoice.Bubble?
    let retarget: PencilVoice.Retarget?

    func makeUIView(context: Context) -> FeedbackView {
        FeedbackView()
    }

    func updateUIView(_ view: FeedbackView, context: Context) {
        view.update(to: bubble)
        view.update(to: retarget)
    }

    final class FeedbackView: UIView {
        private var feedback: UICanvasFeedbackGenerator?
        private var last: PencilVoice.State?
        private var lastRetarget: PencilVoice.Retarget?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            feedback = window == nil ? nil : UICanvasFeedbackGenerator(view: self)
        }

        /// A squeeze during a phone call moved what the command is about: one tap there.
        func update(to retarget: PencilVoice.Retarget?) {
            defer { lastRetarget = retarget }
            guard let retarget, retarget != lastRetarget else { return }
            feedback?.alignmentOccurred(at: retarget.point)
        }

        func update(to bubble: PencilVoice.Bubble?) {
            let state = bubble?.state
            defer { last = state }
            guard let bubble, state != last else { return }
            switch state {
            case .listening:
                feedback?.alignmentOccurred(at: bubble.anchor)
            case .working where last == .listening || last == .gettingReady:
                // Sent. A bubble that goes back to working after a step doesn't tap again.
                feedback?.pathCompleted(at: bubble.anchor)
            default:
                break
            }
        }
    }
}

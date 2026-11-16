import SwiftUI
import UIKit

/// Changes a whole-number field by sliding a ruler: a finger held on the field and dragged
/// sideways, or an Apple Pencil Pro squeezed once over the field, rolled, and squeezed
/// again to keep the value. Each step is one unit, and on Pencil Pro each step is felt as
/// a tick.
@MainActor @Observable
final class Scrubber {
    /// A field that can be scrubbed: where it is, and how to read and change its value.
    struct Target {
        var label: String
        var unit: String
        /// In `Scrubber.space`.
        var frame: CGRect
        var range: ClosedRange<CGFloat>
        var get: () -> CGFloat
        var set: (CGFloat) -> Void
    }

    /// The coordinate space field frames and the ruler share: the panel's.
    static let space = "scrubber"
    /// How far a finger slides for each step.
    static let pointsPerStep: CGFloat = 8
    /// How far the pencil's barrel turns for each step.
    static let degreesPerStep = 10.0

    /// The field being scrubbed.
    private(set) var target: Target?
    private(set) var value: CGFloat = 0

    /// The field the pencil is hovering over, which a squeeze scrubs.
    @ObservationIgnored var hovered: Target?
    @ObservationIgnored var onBegin: () -> Void = {}
    @ObservationIgnored var onEnd: () -> Void = {}
    /// A step was taken, at this point in `Scrubber.space`.
    @ObservationIgnored var onStep: (CGPoint) -> Void = { _ in }

    @ObservationIgnored private var start: CGFloat = 0
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var lastRoll: Angle?
    @ObservationIgnored private var rolled = Angle.zero
    /// Whether a squeeze is under way, so that each squeeze acts once, as it starts.
    @ObservationIgnored private var isSqueezing = false

    func begin(_ target: Target) {
        guard self.target == nil else { return }
        start = target.get().rounded()
        value = start
        steps = 0
        lastRoll = nil
        rolled = .zero
        self.target = target
        onBegin()
    }

    /// Moves the value `steps` units from where it was when scrubbing began.
    func scrub(to steps: Int) {
        guard let target, steps != self.steps else { return }
        self.steps = steps
        let new = Self.value(from: start, steps: steps, in: target.range)
        guard new != value else { return }
        value = new
        target.set(new)
        onStep(CGPoint(x: target.frame.midX, y: target.frame.midY))
    }

    func end() {
        guard target != nil else { return }
        target = nil
        onEnd()
    }

    // MARK: Apple Pencil

    /// A squeeze over a field brings up its ruler, and the pencil need not stay squeezed:
    /// rolling the barrel then turns the value. The next squeeze keeps the value and puts
    /// the ruler away.
    func squeeze(_ phase: PencilSqueezeGesturePhase) {
        switch phase {
        case .active(let value):
            guard !isSqueezing else { return }
            isSqueezing = true
            if target != nil {
                end()
            } else if let hovered {
                begin(hovered)
                // Turning counts from where the barrel is now.
                lastRoll = value.hoverPose?.roll
            }
        case .ended, .failed:
            isSqueezing = false
        }
    }

    /// The barrel's roll, as the pencil hovers. While scrubbing, turning it steps the value.
    func rolled(to roll: Angle) {
        guard target != nil else { return }
        if let lastRoll { rolled += Self.turn(from: lastRoll, to: roll) }
        lastRoll = roll
        scrub(to: Self.steps(forRoll: rolled))
    }

    // MARK: The arithmetic

    static func value(from start: CGFloat, steps: Int, in range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(start + CGFloat(steps), range.lowerBound), range.upperBound)
    }

    static func steps(forDrag width: CGFloat) -> Int {
        Int((width / pointsPerStep).rounded(.towardZero))
    }

    static func steps(forRoll turn: Angle) -> Int {
        Int((turn.degrees / degreesPerStep).rounded(.towardZero))
    }

    /// The turn from one roll to the next, the short way round, so that passing the point
    /// where the angle wraps isn't read as a full turn back.
    static func turn(from: Angle, to: Angle) -> Angle {
        var degrees = (to - from).degrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 } else if degrees < -180 { degrees += 360 }
        return .degrees(degrees)
    }
}

// MARK: The ruler

/// The ruler shown while a field is scrubbed: ticks that slide under a fixed needle, one
/// per unit, longer every ten, with the value above the needle.
struct ScrubberRuler: View {
    let value: CGFloat
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text("\(Int(value)) \(unit)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: value))
            Canvas { context, size in
                let spacing = Scrubber.pointsPerStep
                let middle = size.width / 2
                let reach = Int(middle / spacing) + 1
                let first = Int(value.rounded()) - reach
                for unit in first...(first + reach * 2) {
                    let x = middle + (CGFloat(unit) - value) * spacing
                    let isMajor = unit.isMultiple(of: 10)
                    let height: CGFloat = isMajor ? 14 : 7
                    // Ticks fade towards the ends of the ruler.
                    let fade = 1 - min(abs(x - middle) / middle, 1)
                    let tick = Path(CGRect(x: x - 0.5, y: size.height - height, width: 1, height: height))
                    context.fill(tick, with: .color(Color.primary.opacity((isMajor ? 0.7 : 0.35) * fade)))
                }
                let needle = Path(roundedRect: CGRect(x: middle - 1, y: 0, width: 2, height: size.height), cornerRadius: 1)
                context.fill(needle, with: .color(Color.accentColor))
            }
            .frame(height: 18)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .accessibilityHidden(true)
    }
}

/// Puts the ruler above the field being scrubbed, across the width of the panel.
struct ScrubberOverlay: View {
    @Environment(Scrubber.self) private var scrubber

    var body: some View {
        GeometryReader { proxy in
            if let target = scrubber.target {
                ScrubberRuler(value: scrubber.value, unit: target.unit)
                    .frame(width: proxy.size.width - 24)
                    .position(x: proxy.size.width / 2, y: max(target.frame.minY - 30, 30))
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.snappy(duration: 0.18), value: scrubber.target != nil)
        .allowsHitTesting(false)
    }
}

// MARK: Apple Pencil

/// A view behind the panel that follows the pencil's roll as it hovers anywhere in the
/// window, and plays the Pencil Pro's haptic ticks.
struct PencilBridge: UIViewRepresentable {
    let scrubber: Scrubber

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        view.scrubber = scrubber
        scrubber.onStep = { [weak view] point in view?.feedback?.alignmentOccurred(at: point) }
        return view
    }

    func updateUIView(_ view: BridgeView, context: Context) {}

    final class BridgeView: UIView {
        weak var scrubber: Scrubber?
        private(set) var feedback: UICanvasFeedbackGenerator?
        private var hover: UIHoverGestureRecognizer?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let hover { hover.view?.removeGestureRecognizer(hover) }
            hover = nil
            guard let window else { return }
            feedback = UICanvasFeedbackGenerator(view: self)
            // On the window, so the roll is followed even where the pencil leaves the panel.
            let recognizer = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
            hover = recognizer
        }

        @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let scrubber, scrubber.target != nil else { return }
            scrubber.rolled(to: .radians(recognizer.rollAngle))
        }
    }
}

import SwiftUI
import UIKit

/// Changes a whole-number field by sliding a ruler: a finger held on the field and dragged
/// sideways, or an Apple Pencil Pro squeezed once over the field, rolled, and squeezed
/// again to keep the value. Each step is one unit, and on Pencil Pro each step is felt as
/// a tick.
@MainActor @Observable
final class Scrubber {
    /// A field that can be scrubbed: where it is, and how to read and change its value.
    /// Who the ruler is for: the Format panel's fields (a scrub is an edit), or the zoom
    /// control (it isn't).
    enum Owner: Hashable { case panel, zoom }

    struct Target {
        var label: String
        var unit: String
        /// A panel field's is in `Scrubber.space`; the zoom control's is in the window.
        var frame: CGRect
        var range: ClosedRange<CGFloat>
        var get: () -> CGFloat
        var set: (CGFloat) -> Void
        /// How far a finger slides for each step.
        var pointsPerStep: CGFloat = Scrubber.pointsPerStep
        /// How far the pencil's barrel turns for each step.
        var degreesPerStep: Double = Scrubber.degreesPerStep
        /// Whether going past one end of the range comes out at the other, as an angle does.
        var wraps = false
        /// Only every this-many units is a mark on the ruler, and felt as a tick.
        var ticksEvery = 1
        var owner: Owner = .panel
        /// The ruler's words for a value; nil gives the value and the unit.
        var text: ((CGFloat) -> String)? = nil
        /// The units that get a longer mark; nil means every `ticksEvery` (above 1), else every 10.
        var majorMarks: Set<Int>? = nil

        func shown(_ value: CGFloat) -> String {
            text?(value) ?? "\(Int(value)) \(unit)"
        }

        func isMajor(_ unit: Int) -> Bool {
            if let majorMarks { return majorMarks.contains(unit) }
            return unit.isMultiple(of: ticksEvery > 1 ? ticksEvery : 10)
        }
    }

    /// The coordinate space field frames and the ruler share: the panel's.
    nonisolated static let space = "scrubber"
    /// How far a finger slides for each step.
    nonisolated static let pointsPerStep: CGFloat = 8
    /// How far the pencil's barrel turns for each step.
    nonisolated static let degreesPerStep = 10.0

    /// The field being scrubbed.
    private(set) var target: Target? {
        didSet { updateWantsSqueeze() }
    }
    private(set) var value: CGFloat = 0

    /// The field the pencil is hovering over, which a squeeze scrubs.
    @ObservationIgnored var hovered: Target? {
        didSet { updateWantsSqueeze() }
    }
    /// Whether a squeeze would be the scrubber's: a field is hovered or a ruler is up.
    private(set) var wantsSqueeze = false
    @ObservationIgnored var onBegin: () -> Void = {}
    @ObservationIgnored var onEnd: () -> Void = {}
    /// A step was taken, at this point in the window.
    @ObservationIgnored var onStep: (CGPoint) -> Void = { _ in }
    /// Where `Scrubber.space`'s origin is in the window: the Format panel's top left, which
    /// the panel keeps current. A panel field's tick is felt there plus its frame's middle.
    @ObservationIgnored var panelOrigin: CGPoint = .zero

    @ObservationIgnored private var start: CGFloat = 0
    @ObservationIgnored private var steps = 0
    @ObservationIgnored private var lastRoll: Angle?
    @ObservationIgnored private var rolled = Angle.zero

    func begin(_ target: Target) {
        guard self.target == nil else { return }
        start = target.get().rounded()
        value = start
        steps = 0
        lastRoll = nil
        rolled = .zero
        self.target = target
        if target.owner == .panel { onBegin() }
    }

    /// Moves the value `steps` units from where it was when scrubbing began.
    func scrub(to steps: Int) {
        guard let target, steps != self.steps else { return }
        self.steps = steps
        let new = Self.value(from: start, steps: steps, in: target.range, wraps: target.wraps)
        guard new != value else { return }
        value = new
        target.set(new)
        if Int(new.rounded()).isMultiple(of: target.ticksEvery) {
            // In the window: a panel field's frame is in the panel's space.
            let origin = target.owner == .panel ? panelOrigin : .zero
            onStep(CGPoint(x: origin.x + target.frame.midX, y: origin.y + target.frame.midY))
        }
    }

    func end() {
        guard let ended = target else { return }
        target = nil
        if ended.owner == .panel { onEnd() }
    }

    /// Ends the ruler only if it is this owner's.
    func end(_ owner: Owner) {
        guard target?.owner == owner else { return }
        end()
    }

    /// Forgets the hovered field only if it is this owner's.
    func forgetHovered(_ owner: Owner) {
        guard hovered?.owner == owner else { return }
        hovered = nil
    }

    /// Written only when it changes: the pen hovers many times a second.
    private func updateWantsSqueeze() {
        let wants = hovered != nil || target != nil
        if wants != wantsSqueeze { wantsSqueeze = wants }
    }

    /// A finger holds a field to scrub it. A ruler the pencil left up on another field is put
    /// away first: the finger's steps are this field's, not the one the pencil was scrubbing.
    func hold(_ field: Target) {
        if let target, target.label != field.label || target.frame != field.frame { end() }
        begin(field)
    }

    /// A finger holding a field has dragged this far sideways since it was held: the field
    /// is scrubbed a step for every `pointsPerStep`.
    func fingerDragged(_ field: Target, by width: CGFloat) {
        hold(field)
        scrub(to: Self.steps(forDrag: width, pointsPerStep: field.pointsPerStep))
    }

    // MARK: Apple Pencil

    /// A squeeze with a ruler up keeps the value and puts it away; with a field hovered it
    /// brings that field's ruler up, turning counted from `roll`, and the pencil need not
    /// stay squeezed: rolling the barrel then turns the value. Returns whether the scrubber
    /// took the squeeze. It doesn't filter repeats: the window's `SqueezeRouter` does.
    @discardableResult
    func squeezeBegan(roll: Angle?) -> Bool {
        if target != nil {
            end()
            return true
        }
        guard let hovered else { return false }
        begin(hovered)
        // Turning counts from where the barrel is now.
        lastRoll = roll
        return true
    }

    /// The pencil hovering anywhere in the window: coming into range, moving, or leaving it.
    /// Only a roll made while it stays in range turns the value. The barrel turned in the
    /// hand while the pencil was away, or touching the screen, isn't counted: it made the
    /// value jump as the pencil came back.
    func hover(_ state: UIGestureRecognizer.State, roll: Angle) {
        switch state {
        case .began:
            // Turning counts from where the barrel is as the pencil comes back.
            lastRoll = nil
            rolled(to: roll)
        case .changed:
            rolled(to: roll)
        default:
            lastRoll = nil
        }
    }

    /// The barrel's roll, as the pencil hovers. While scrubbing, turning it steps the value.
    func rolled(to roll: Angle) {
        guard target != nil else { return }
        if let lastRoll { rolled += Self.turn(from: lastRoll, to: roll) }
        lastRoll = roll
        scrub(to: Self.steps(forRoll: rolled, degreesPerStep: target?.degreesPerStep ?? Self.degreesPerStep))
    }

    // MARK: The arithmetic

    /// The value `steps` units from `start`: stopped at the ends of the range, or, when it
    /// wraps, carried round from one end to the other (so 5 steps back from 2 is 357 in
    /// 0...360). The top of a wrapping range is the same place as the bottom, and reads as it.
    static func value(from start: CGFloat, steps: Int, in range: ClosedRange<CGFloat>, wraps: Bool = false) -> CGFloat {
        typed(start + CGFloat(steps), in: range, wraps: wraps)
    }

    /// A number typed in: wrapped into the range, or stopped at its ends.
    static func typed(_ value: CGFloat, in range: ClosedRange<CGFloat>, wraps: Bool) -> CGFloat {
        guard wraps else { return min(max(value, range.lowerBound), range.upperBound) }
        let span = range.upperBound - range.lowerBound
        let offset = (value - range.lowerBound).truncatingRemainder(dividingBy: span)
        return range.lowerBound + (offset < 0 ? offset + span : offset)
    }

    static func steps(forDrag width: CGFloat, pointsPerStep: CGFloat = pointsPerStep) -> Int {
        Int((width / pointsPerStep).rounded(.towardZero))
    }

    static func steps(forRoll turn: Angle, degreesPerStep: Double = degreesPerStep) -> Int {
        // Angle keeps radians, so 30 degrees can read back as 29.999999999999996.
        let exact = (turn.degrees / degreesPerStep * 1e6).rounded() / 1e6
        return Int(exact.rounded(.towardZero))
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
/// per unit, longer every ten (or at the field's own marks), with the value above the needle.
struct ScrubberRuler: View {
    let value: CGFloat
    let text: String
    /// How far apart the ticks are.
    var spacing = Scrubber.pointsPerStep
    /// Whether a unit gets a longer tick.
    var isMajor: (Int) -> Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(text)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText(value: value))
            Canvas { context, size in
                let middle = size.width / 2
                let reach = Int(middle / spacing) + 1
                let first = Int(value.rounded()) - reach
                for unit in first...(first + reach * 2) {
                    let x = middle + (CGFloat(unit) - value) * spacing
                    let isMajor = isMajor(unit)
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
            if let target = scrubber.target, target.owner == .panel {
                ScrubberRuler(
                    value: scrubber.value, text: target.shown(scrubber.value),
                    spacing: target.pointsPerStep, isMajor: target.isMajor
                )
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

/// A view behind the canvas that follows the pencil's roll as it hovers anywhere in the
/// window, and plays the Pencil Pro's haptic ticks.
struct PencilBridge: UIViewRepresentable {
    let scrubber: Scrubber

    func makeUIView(context: Context) -> BridgeView {
        let view = BridgeView()
        // It fills the window behind the canvas: touches are the canvas's. Its hover
        // recogniser is on the window, which this doesn't stop.
        view.isUserInteractionEnabled = false
        view.scrubber = scrubber
        // A step's point is in the window.
        scrubber.onStep = { [weak view] point in
            guard let view else { return }
            view.feedback?.alignmentOccurred(at: view.convert(point, from: nil))
        }
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

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            guard let scrubber, scrubber.target != nil else { return }
            scrubber.hover(recognizer.state, roll: .radians(recognizer.rollAngle))
        }
    }
}

import PencilKit
import UIKit

/// Tells two fingers that turn from two that pinch or spread, or that move together, from
/// where they were when both were down and where they are now. They must turn about 8°
/// before the distance between them changes by about 8%, and before the point between them
/// moves about 12 points, for the selection to turn; otherwise the canvas zooms or scrolls.
enum TwistClassifier {
    enum Decision { case undecided, twist, pinch, pan }

    /// How far, in degrees, the line between the fingers turns before it is a twist.
    static let turnThreshold = 8.0
    /// How much the distance between the fingers changes, as a share of what it was, before
    /// it is a pinch.
    static let spreadThreshold = 0.08
    /// How far, in points, the point halfway between the fingers moves before it is a pan.
    /// One finger still and the other going round it moves that point about 7 points by 8°
    /// at 100 points apart, which stays a twist.
    static let panThreshold = 12.0

    /// How far the line from the first finger to the second has turned, in degrees clockwise
    /// on the screen, the short way round: from -180 to 180.
    static func turn(from start: (CGPoint, CGPoint), to now: (CGPoint, CGPoint)) -> Double {
        Rotation.shortestTurn(from: direction(start), to: direction(now))
    }

    /// Each measure as a share of its mark: the turn, the change of distance, and how far
    /// the point between the fingers has moved. Undecided until one is past its mark; then
    /// the one furthest past it decides. A tie goes to the canvas, as it did before there was
    /// a twist: a pinch over a twist, a pan over a twist, and a pinch over a pan.
    static func decide(from start: (CGPoint, CGPoint), to now: (CGPoint, CGPoint)) -> Decision {
        let turned = abs(turn(from: start, to: now)) / turnThreshold
        let spread = abs(distance(now) / max(distance(start), 1) - 1) / spreadThreshold
        let (was, mid) = (middle(start), middle(now))
        let travelled = hypot(mid.x - was.x, mid.y - was.y) / panThreshold
        guard max(turned, spread, travelled) >= 1 else { return .undecided }
        if turned > spread, turned > travelled { return .twist }
        return spread >= travelled ? .pinch : .pan
    }

    private static func direction(_ fingers: (CGPoint, CGPoint)) -> Double {
        atan2(fingers.1.y - fingers.0.y, fingers.1.x - fingers.0.x) * 180 / .pi
    }

    private static func distance(_ fingers: (CGPoint, CGPoint)) -> Double {
        hypot(fingers.1.x - fingers.0.x, fingers.1.y - fingers.0.y)
    }

    private static func middle(_ fingers: (CGPoint, CGPoint)) -> CGPoint {
        CGPoint(x: (fingers.0.x + fingers.1.x) / 2, y: (fingers.0.y + fingers.1.y) / 2)
    }
}

/// What two fingers have shown themselves to be, from where and when each landed and how
/// they have moved since: a twist, not one, or not yet known. Apart from UIKit's touches and
/// states, which `TwistGestureRecognizer` maps onto it.
struct TwistTracker {
    enum Verdict { case undecided, twist, notATwist }

    /// How soon after the first finger the second must land.
    static let secondFingerWait: TimeInterval = 0.25
    /// How far the first finger may move before the second lands. Further, it is dragging.
    static let firstFingerDrift: CGFloat = 10

    private(set) var verdict = Verdict.undecided
    /// How far the fingers have turned, in degrees clockwise, since both were down: from
    /// then rather than from when they were found to twist, so that the selection catches up
    /// with the turn it took to tell. Added up move by move, it goes on past a half turn.
    private(set) var turn: Double = 0

    private var fingers = 0
    /// Where and when the first finger landed.
    private var landing: (point: CGPoint, time: TimeInterval)?
    /// Where both fingers were as the second landed.
    private var start: (CGPoint, CGPoint)?
    /// Where they were at the last move.
    private var last: (CGPoint, CGPoint)?

    /// A finger landed at `point`, at `time`, while the first is at `first` (the same point,
    /// for the first). Asks whether it is on the selection, and for the first whether
    /// anything can turn, only when that is still in question.
    mutating func landed(
        at point: CGPoint, time: TimeInterval, first: CGPoint,
        isOnSelection: @autoclosure () -> Bool, canTurn: @autoclosure () -> Bool
    ) {
        guard verdict == .undecided else { return }
        fingers += 1
        switch fingers {
        case 1:
            guard canTurn(), isOnSelection() else { return verdict = .notATwist }
            landing = (point, time)
        case 2:
            guard let landing, time - landing.time <= Self.secondFingerWait, isOnSelection() else { return verdict = .notATwist }
            start = (first, point)
            last = start
        default:
            // A third finger before it was decided: whatever this is, it isn't a twist.
            verdict = .notATwist
        }
    }

    /// The fingers moved: the first is at `first`, and the second, once down, at `second`.
    mutating func moved(first: CGPoint, second: CGPoint?, time: TimeInterval) {
        guard verdict != .notATwist else { return }
        guard let second, let start, let last else {
            // The first finger alone. Still alone after a moment, or moving off, it is a
            // drag or a scroll.
            guard let landing else { return }
            if time - landing.time > Self.secondFingerWait
                || hypot(first.x - landing.point.x, first.y - landing.point.y) > Self.firstFingerDrift {
                verdict = .notATwist
            }
            return
        }
        let now = (first, second)
        turn += TwistClassifier.turn(from: last, to: now)
        self.last = now
        guard verdict == .undecided else { return }
        switch TwistClassifier.decide(from: start, to: now) {
        case .twist: verdict = .twist
        case .pinch, .pan: verdict = .notATwist
        case .undecided: break
        }
    }
}

/// Two fingers that land on the selection and turn before they pinch, spread or move
/// together: the selection turns with them (`AppModel.beginTwist()`). Anything else, it
/// fails as soon as it can tell, so that the canvases' pan and pinch, which wait for it, go
/// on as before.
///
/// It is on the window, as `RestingFingerDetector` is, to see fingers on the selection's
/// own targets, which are drawn above the canvas. Only fingers: Apple Pencil and the pointer
/// never start or join a twist, which leaves the Pencil's drawing, hover and squeeze alone.
/// The resting-finger and Pencil detectors and the palette's flicks recognise alongside it,
/// as they do alongside every gesture: their delegates say so.
final class TwistGestureRecognizer: UIGestureRecognizer {
    /// Whether a point in its view, the window, is on what is selected.
    var isOnSelection: (CGPoint) -> Bool = { _ in false }
    /// Whether what is selected can be turned now.
    var canTurn: () -> Bool = { false }
    /// How far the fingers have turned, in degrees clockwise, since both were down (see
    /// `TwistTracker.turn`).
    var turn: Double { tracker.turn }

    private var tracker = TwistTracker()
    private weak var first: UITouch?
    private weak var second: UITouch?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        // A drag a finger had begun on the selection gives way once the twist wins.
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// Nothing that began with the fingers stops them turning the selection: the drag of
    /// the element under the first finger, for one, which the twist ends as it begins. Only
    /// a canvas's own gesture can, ink a finger is already drawing. (The canvases' pan and
    /// pinch wait for the twist, so they never begin first.)
    override func canBePrevented(by preventing: UIGestureRecognizer) -> Bool {
        preventing.view is PKCanvasView
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state == .possible else {
            // A third finger: whatever the fingers are doing now, it isn't this twist.
            state = .cancelled
            return
        }
        for touch in touches {
            if first == nil { first = touch } else if second == nil { second = touch }
            let point = touch.location(in: view)
            tracker.landed(
                at: point, time: touch.timestamp, first: first?.location(in: view) ?? point,
                isOnSelection: isOnSelection(point), canTurn: canTurn()
            )
            if tracker.verdict == .notATwist { return fail() }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let first else { return }
        tracker.moved(first: first.location(in: view), second: second?.location(in: view), time: event.timestamp)
        switch tracker.verdict {
        case .twist: state = state == .possible ? .began : .changed
        case .notATwist: fail()
        case .undecided: break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // A finger lifted: the twist is done, or never was one.
        state = state == .possible ? .failed : .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        tracker = TwistTracker()
        first = nil
        second = nil
    }

    private func fail() {
        state = .failed
    }
}

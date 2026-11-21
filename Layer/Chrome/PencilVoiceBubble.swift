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
    /// The name the bubble's frame is reported under, among the canvas's chrome.
    static let chromeName = "pencil bubble"

    let pencil: PencilVoice
    let bubble: PencilVoice.Bubble
    let bounds: CGRect
    let topInset: CGFloat

    @Environment(AppModel.self) private var model
    @AppStorage("pencilVoice.showsWords") private var showsWords = true
    /// Measured once laid out. Until then, about the size it opens at.
    @State private var size = CGSize(width: 190, height: 52)
    @State private var isMeasured = false
    /// The largest it has been measured since it opened at this tip.
    @State private var largest = CGSize.zero
    /// Which way round the tip it went, chosen once for the tip it opened at: the side is
    /// kept as it grows and shrinks from state to state, unless something comes in the way.
    @State private var chosenTurn: Double?
    @State private var chosenFor: CGPoint?

    /// How far the bubble keeps from the tip.
    nonisolated static let gap: CGFloat = 28
    /// How far it keeps from the window's edges.
    nonisolated static let margin: CGFloat = 12

    /// The bubble's top-left: `gap` from the tip in the direction away from the barrel, or
    /// below the tip when the pencil's angle isn't known, and kept inside `bounds` and clear
    /// of the bar above `topInset`.
    ///
    /// Kept inside, it can be pushed back over the tip, by the bar above or a window edge,
    /// and the pen would hide it. It can also land on chrome in `obstacles`, such as the
    /// actions over what the squeeze selected, or on `subject`, what is being spoken about.
    /// Then it swivels round the tip, a step at a time away from straight opposite the
    /// barrel, to the first place clear of all of them. Failing that, it keeps clear of
    /// the tip and the chrome, and failing that, of the tip alone: a subject as big as a
    /// whole screen can't be kept clear of.
    nonisolated static func origin(
        anchor: CGPoint, azimuth: Angle?, size: CGSize, in bounds: CGRect, topInset: CGFloat,
        avoiding obstacles: [CGRect] = [], subject: CGRect? = nil
    ) -> CGPoint {
        let turn = turn(anchor: anchor, azimuth: azimuth, size: size, in: bounds, topInset: topInset, avoiding: obstacles, subject: subject)
        return origin(anchor: anchor, azimuth: azimuth, turn: turn, size: size, in: bounds, topInset: topInset)
    }

    /// The turns tried, in radians away from straight opposite the barrel, in order.
    nonisolated static let turns: [Double] = [0, -1, 1, -2, 2, -3, 3].map { $0 * .pi / 4 }

    /// Which way round the tip a bubble of `size` goes, as `origin` says: one of `turns`.
    nonisolated static func turn(
        anchor: CGPoint, azimuth: Angle?, size: CGSize, in bounds: CGRect, topInset: CGFloat,
        avoiding obstacles: [CGRect] = [], subject: CGRect? = nil
    ) -> Double {
        turn(anchor: anchor, azimuth: azimuth, sizes: [size], in: bounds, topInset: topInset, avoiding: obstacles, subject: subject)
    }

    /// Which way round the tip a bubble goes that will be each of `sizes` in turn: the
    /// first side that does for all of them. A smaller bubble sits nearer the tip, so a
    /// side clear for the largest isn't always clear for the smallest.
    ///
    /// In a tight spot (a narrow window, chrome hugging the tip) no side may do as well
    /// for all the sizes as one does for the bubble's `actual` size. Then the side is the
    /// one for the actual size, as if only it were planned for: it may change with the
    /// state, but it is never left over the tip or on chrome that could have been missed.
    nonisolated static func turn(
        anchor: CGPoint, azimuth: Angle?, sizes: [CGSize], actual: CGSize? = nil, in bounds: CGRect, topInset: CGFloat,
        avoiding obstacles: [CGRect] = [], subject: CGRect? = nil
    ) -> Double {
        func clearness(_ turn: Double, _ size: CGSize) -> Clearness {
            let frame = place(towards: away(azimuth) + turn, anchor: anchor, size: size, in: bounds, topInset: topInset)
            return Self.clearness(of: frame, anchor: anchor, obstacles: obstacles, subject: subject)
        }
        let planned = turns.map { turn in (turn: turn, clearness: sizes.map { clearness(turn, $0) }.max() ?? .clear) }
        let bestPlanned = planned.map(\.clearness).min() ?? .clear
        if let actual {
            let now = turns.map { (turn: $0, clearness: clearness($0, actual)) }
            let bestNow = now.map(\.clearness).min() ?? .clear
            if bestNow < bestPlanned, let side = now.first(where: { $0.clearness == bestNow }) { return side.turn }
        }
        return planned.first { $0.clearness == bestPlanned }?.turn ?? turns[0]
    }

    /// The top-left of a bubble of `size` that has gone `turn` round the tip.
    nonisolated static func origin(anchor: CGPoint, azimuth: Angle?, turn: Double, size: CGSize, in bounds: CGRect, topInset: CGFloat) -> CGPoint {
        place(towards: away(azimuth) + turn, anchor: anchor, size: size, in: bounds, topInset: topInset).origin
    }

    /// Whether the side `turn` no longer does for a bubble of `size`: another side would
    /// keep it clearer, of the tip, of chrome or of what is spoken about, judged as the
    /// side is chosen. A subject no side can miss blocks nothing.
    nonisolated static func isBlocked(
        turn: Double, anchor: CGPoint, azimuth: Angle?, size: CGSize, in bounds: CGRect, topInset: CGFloat,
        avoiding obstacles: [CGRect], subject: CGRect? = nil
    ) -> Bool {
        func clearness(_ turn: Double) -> Clearness {
            let frame = place(towards: away(azimuth) + turn, anchor: anchor, size: size, in: bounds, topInset: topInset)
            return Self.clearness(of: frame, anchor: anchor, obstacles: obstacles, subject: subject)
        }
        return clearness(turn) > (turns.map(clearness).min() ?? .clear)
    }

    /// How well a place keeps clear, best first. A side is chosen for the best it can get.
    nonisolated enum Clearness: Int, Comparable {
        /// Clear of the tip, the chrome and what is spoken about.
        case clear
        /// Clear of the tip and the chrome, on what is spoken about.
        case onSubject
        /// Clear of the tip, on chrome.
        case onChrome
        /// Over the tip.
        case onTip

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    nonisolated private static func clearness(of frame: CGRect, anchor: CGPoint, obstacles: [CGRect], subject: CGRect?) -> Clearness {
        if !isClear(of: anchor, frame) { return .onTip }
        if obstacles.contains(where: { $0.intersects(frame) }) { return .onChrome }
        if let subject, subject.intersects(frame) { return .onSubject }
        return .clear
    }

    /// The sizes the side is chosen for: about as small as the bubble gets (working or
    /// done), listening, listening with words if they are shown, and as big as it gets (a
    /// problem's line, or the largest it has been measured).
    nonisolated static func plannedSizes(showsWords: Bool, largestMeasured: CGSize) -> [CGSize] {
        [CGSize(width: 80, height: 48), CGSize(width: 200, height: 52)]
            + (showsWords ? [CGSize(width: 64 + PencilVoiceWords.width, height: 64)] : [])
            + [CGSize(width: max(300, largestMeasured.width), height: max(52, largestMeasured.height))]
    }

    /// The way the bubble goes from the tip: opposite the barrel, or straight down.
    nonisolated private static func away(_ azimuth: Angle?) -> Double {
        azimuth.map { $0.radians + .pi } ?? .pi / 2
    }

    /// Clear of the tip by half the gap at least: kept from the bar or an edge, a bubble
    /// may have been brought nearer than the whole of it.
    nonisolated private static func isClear(of anchor: CGPoint, _ frame: CGRect) -> Bool {
        !frame.insetBy(dx: -gap / 2, dy: -gap / 2).contains(anchor)
    }

    /// The bubble's frame `gap` beyond the tip in the direction `angle` (radians, clockwise
    /// from the right), kept inside the window and below the bar.
    nonisolated private static func place(towards angle: Double, anchor: CGPoint, size: CGSize, in bounds: CGRect, topInset: CGFloat) -> CGRect {
        let dx = cos(angle), dy = sin(angle)
        // Far enough that all of it is at least `gap` beyond the tip.
        let reach = gap + abs(dx) * size.width / 2 + abs(dy) * size.height / 2
        var origin = CGPoint(x: anchor.x + dx * reach - size.width / 2, y: anchor.y + dy * reach - size.height / 2)
        let inner = bounds.insetBy(dx: margin, dy: margin)
        let minY = max(inner.minY, topInset + margin)
        origin.x = max(min(origin.x, inner.maxX - size.width), inner.minX)
        origin.y = max(min(origin.y, inner.maxY - size.height), minY)
        return CGRect(origin: origin, size: size)
    }

    var body: some View {
        let canvas = model.store.canvas
        // The other chrome on the canvas, such as the actions over what the squeeze selected.
        let chrome = model.chromeFrames.filter { $0.key != Self.chromeName }.map(\.value)
        let subject = model.selectionViewRect
        // The side is the one chosen when it opened here, for every size it takes, so that
        // it doesn't swap sides from state to state. Only something in the way chooses again.
        let turn: Double = if let chosenTurn, chosenFor == bubble.anchor,
            !Self.isBlocked(
                turn: chosenTurn, anchor: bubble.anchor, azimuth: bubble.azimuth, size: size, in: bounds, topInset: topInset,
                avoiding: chrome, subject: subject
            ) {
            chosenTurn
        } else {
            Self.turn(
                anchor: bubble.anchor, azimuth: bubble.azimuth, sizes: Self.plannedSizes(showsWords: showsWords, largestMeasured: largest),
                actual: size, in: bounds, topInset: topInset, avoiding: chrome, subject: subject
            )
        }
        let origin = Self.origin(anchor: bubble.anchor, azimuth: bubble.azimuth, turn: turn, size: size, in: bounds, topInset: topInset)
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
            largest = CGSize(width: max(largest.width, measured.width), height: max(largest.height, measured.height))
        }
        // Kept from here on: chosen when it opens, again at a new tip, and when the side it
        // had was blocked.
        .onChange(of: Choice(turn: turn, anchor: bubble.anchor), initial: true) { _, choice in
            chosenTurn = choice.turn
            chosenFor = choice.anchor
        }
        // A new tip starts afresh: how big the last one's bubble got says nothing here.
        .onChange(of: bubble.anchor) { largest = .zero }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Listening with \(model.modelChoice.displayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Stops listening")
        .accessibilityIdentifier("pencil bubble")
        .reportsChromeFrame(Self.chromeName, to: model)
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
                        PencilVoiceWords(words: Self.newestWords(of: words))
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

    /// How many of the newest words the line keeps. More than its width shows: the rest
    /// are there to scroll in from, so the line slides rather than jumps.
    nonisolated static let wordLimit = 8

    /// The newest `wordLimit` words of `words`, between ellipses when earlier ones were
    /// left out, as the person asked: "…words…".
    nonisolated static func newestWords(of words: String) -> String {
        let all = words.split(whereSeparator: \.isWhitespace)
        guard all.count > wordLimit else { return all.joined(separator: " ") }
        return "…" + all.suffix(wordLimit).joined(separator: " ") + "…"
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

/// The side a bubble went, and for which tip.
private struct Choice: Equatable {
    var turn: Double
    var anchor: CGPoint
}

/// The waveform on its own, so that the levels, which change many times a second, redraw
/// only the bars.
private struct PencilVoiceWaveform: View {
    let pencil: PencilVoice

    var body: some View {
        CallWaveform(levels: pencil.levels)
    }
}

/// The words heard, on one line of a fixed width, so the bubble keeps its size while they
/// come in. Longer than the line, they scroll along it to the newest, fading out at the
/// leading edge, instead of the bubble growing to fit them.
struct PencilVoiceWords: View {
    let words: String

    nonisolated static let width: CGFloat = 220

    var body: some View {
        ScrollView(.horizontal) {
            Text(words)
                .font(.subheadline)
                // Primary: secondary was too faint where the glass, tinted with a dark
                // canvas, lies over a white screen.
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
        .scrollIndicators(.hidden)
        .scrollDisabled(true)
        // Kept at the newest words as each one arrives, which slides the line along.
        .defaultScrollAnchor(.trailing, for: .initialOffset)
        .defaultScrollAnchor(.trailing, for: .sizeChanges)
        .animation(.smooth(duration: 0.3), value: words)
        .frame(width: Self.width, alignment: .leading)
        // Faded only once earlier words have gone, which their ellipsis says.
        .mask {
            LinearGradient(stops: [.init(color: words.hasPrefix("…") ? .clear : .black, location: 0), .init(color: .black, location: 0.12)], startPoint: .leading, endPoint: .trailing)
        }
        .accessibilityLabel(words)
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

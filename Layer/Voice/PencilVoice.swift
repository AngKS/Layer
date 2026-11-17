import Observation
import SwiftUI
import UIKit

/// Apple Pencil Pro's push-to-talk. A squeeze over something listens for a command about
/// it: a quick squeeze leaves the pencil listening until the next one, and a held squeeze
/// listens until it is let go of. Over empty canvas, a new screen goes where the pen was.
///
/// It has a call of its own, which listens only while asked and lives alongside a phone
/// call. While a phone call is up, that call hears everything, and a squeeze only says
/// what the next command is about.
@Observable
@MainActor
final class PencilVoice {
    /// What shows at the pen's tip while the pencil is listening or has been heard.
    struct Bubble: Equatable {
        /// Where the squeeze began, in the view's points.
        var anchor: CGPoint
        /// Which way the pencil's barrel pointed, so that the bubble sits clear of the hand.
        var azimuth: Angle?
        var state: State
    }

    enum State: Equatable {
        /// The microphone isn't on yet: words now would be lost.
        case gettingReady
        case listening
        case working
        case done
        case problem(String)
    }

    /// A squeeze shorter than this is a toggle; one longer is held to talk. Device
    /// squeezes measured 0.18–0.23 s quick, and 1.75 s and more held.
    static let holdThreshold: Duration = .milliseconds(350)
    /// How long a toggle left listening waits for words before it gives up, sending nothing.
    static let silenceTimeout: Duration = .seconds(20)

    /// What the model is told with a command the pencil pointed at empty canvas for.
    static let canvasHint = "(The person pointed at empty canvas: a description of a screen means a new screen there.)"

    private(set) var bubble: Bubble?
    /// The pencil's call, from the first hover or squeeze.
    private(set) var call: VoiceCall?
    /// The microphone levels of what is being listened to now, newest last, for the waveform.
    var levels: [Float] {
        guard let call, call.isListeningAsAsked else { return [] }
        return call.levels
    }

    /// Whether squeezing is turned off in Settings, which Layer respects.
    @ObservationIgnored var squeezeIsOff: @MainActor () -> Bool = { UIPencilInteraction.preferredSqueezeAction == .ignore }
    /// Whether the design's model can be asked. A test says.
    @ObservationIgnored var readiness: @MainActor () -> ProviderReadiness
    /// How often a toggle left listening checks whether it has waited long enough.
    @ObservationIgnored var silenceCheck: Duration = .milliseconds(250)
    /// How long a problem Layer finds itself, such as no model, stays in the bubble.
    @ObservationIgnored var problemTime: Duration = .seconds(6)

    private enum Mode {
        /// Listening, held or toggled. `stale` is the call's caption when it began, which
        /// says nothing about this listen.
        case listening(began: ContinuousClock.Instant, toggled: Bool, stale: UUID?)
        /// Sent: the bubble follows the call's caption until it clears.
        case sent(stale: UUID?)
        /// Showing a line of its own, which closes after `problemTime`.
        case saying
    }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let makeRoute: @MainActor () -> any VoiceRoute
    @ObservationIgnored private let makeRunner: @MainActor (AppModel) -> any VoiceCommandRunner
    @ObservationIgnored private let clock: () -> ContinuousClock.Instant
    @ObservationIgnored private var mode: Mode?
    /// The call getting ready, which a squeeze waits on before it listens.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// A listen waiting on the call to be ready, not yet asked of it.
    @ObservationIgnored private var pendingListen: Task<Void, Never>?
    /// Whether the call has been asked for this listen. From then on, the call's own
    /// `hasOpenListen` says whether it is still going.
    @ObservationIgnored private var askedToListen = false
    /// Whether any words have been heard since this listen began.
    @ObservationIgnored private var heardWords = false
    /// Set once the design has closed: the call ends as soon as it has nothing to finish.
    @ObservationIgnored private var designHasClosed = false
    /// Set when a squeeze sent a toggle: letting go of that squeeze does nothing more.
    @ObservationIgnored private var endIsIgnored = false
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    /// When words were last heard by a toggle, and which.
    @ObservationIgnored private var lastHeard: (at: ContinuousClock.Instant, caption: UUID?)?
    @ObservationIgnored private var closing: Task<Void, Never>?

    init(
        model: AppModel,
        makeRoute: @escaping @MainActor () -> any VoiceRoute = { DictationRoute(endsOnPause: false) },
        makeRunner: @escaping @MainActor (AppModel) -> any VoiceCommandRunner = { VoiceAgent(model: $0) },
        clock: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.model = model
        self.makeRoute = makeRoute
        self.makeRunner = makeRunner
        self.clock = clock
        readiness = { [weak model] in model?.modelChoice.sketchProvider.readiness() ?? .ready }
    }

    // MARK: The pencil

    /// The pen came into hover range. The first time, the model gets ready, so that the
    /// first squeeze doesn't wait on it. Nothing listens.
    func hovered() {
        // A phone call hears everything while it is up: the pencil's own isn't needed.
        guard call == nil, model?.voice == nil, case .ready = readiness() else { return }
        startCall()
    }

    /// A squeeze began, with the pen hovering at `viewPoint`, or out of range when nil.
    func squeezeBegan(at viewPoint: CGPoint?, azimuth: Angle?) {
        // Only starting needs the pen in range: a toggle is sent wherever the pen has drifted.
        if case .listening(_, toggled: true, _) = mode {
            endIsIgnored = true
            send()
            return
        }
        guard let model, let viewPoint, !squeezeIsOff(), model.tool != .draw, !isOverChrome(viewPoint, in: model) else { return }
        endIsIgnored = false
        let target = target(at: viewPoint, in: model)
        select(target, in: model)
        // The phone call hears the command: the squeeze only said what it is about.
        guard model.voice == nil else { return }
        if case .unavailable(let reason) = readiness() {
            open(at: viewPoint, azimuth: azimuth, .problem(reason))
            say()
            return
        }
        guard let call = startCall() else { return }
        open(at: viewPoint, azimuth: azimuth, .gettingReady)
        mode = .listening(began: clock(), toggled: false, stale: call.caption?.id)
        listen(for: target, on: call)
    }

    func squeezeEnded() {
        if endIsIgnored {
            endIsIgnored = false
            return
        }
        guard case .listening(let began, toggled: false, let stale) = mode else { return }
        if clock() - began < Self.holdThreshold {
            mode = .listening(began: began, toggled: true, stale: stale)
            startSilenceTimer()
        } else {
            send()
        }
    }

    /// A finger tapped the bubble: whatever is being listened to is let go of.
    func tapBubble() {
        stopHearing()
        close()
    }

    /// The window left the screen: listening stops and nothing is sent. A command already
    /// running is left to finish.
    func stopListening() {
        stopHearing()
        close()
    }

    /// The design closed: listening stops, and the call ends once whatever it is running
    /// has finished.
    func designClosed() {
        designHasClosed = true
        stopListening()
        endIfIdle()
    }

    private func endIfIdle() {
        guard designHasClosed, let call, !call.isHearing, call.queuedCount == 0, call.phase != .working else { return }
        call.end()
    }

    // MARK: Listening

    @discardableResult
    private func startCall() -> VoiceCall? {
        if let call { return call }
        guard let model else { return nil }
        let inner = makeRunner(model)
        let runner = PencilRunner(inner) { [weak self] in self?.commandEnded() }
        let call = VoiceCall(listening: .onRequest(makeRoute: makeRoute), runner: runner, vocabulary: { [weak model] in model?.voiceVocabulary ?? [] })
        // What the agent is doing, tool by tool, is what the bubble's caption says.
        (inner as? VoiceAgent)?.onStep = { [weak call] step in call?.showStep(step) }
        call.onCommandStarts = { [weak self] target in self?.commandStarts(target) }
        // The model's endCall ends a pencil call too. The next squeeze starts another.
        call.onEnd = { [weak self, weak call] in
            guard let self, self.call === call else { return }
            self.call = nil
            self.starting = nil
            self.close()
        }
        self.call = call
        watch(call)
        starting = Task { await call.start() }
        return call
    }

    /// Listens once the call is ready. Getting ready captures the canvas and can take a
    /// moment, and a call that isn't ready yet ignores being asked.
    private func listen(for target: VoiceTarget, on call: VoiceCall) {
        pendingListen?.cancel()
        askedToListen = false
        heardWords = false
        let starting = starting
        pendingListen = Task { [weak self] in
            await starting?.value
            guard let self, !Task.isCancelled, self.call === call else { return }
            self.pendingListen = nil
            self.askedToListen = true
            await call.listen(for: target)
        }
    }

    private func send() {
        silenceTimer?.cancel()
        guard let call else { return }
        if let pendingListen {
            // Let go of before the call was even ready to listen, so nothing was heard.
            pendingListen.cancel()
            self.pendingListen = nil
            bubble?.state = .problem(VoiceCall.tooSoon)
            say()
            return
        }
        if case .listening(_, toggled: true, let stale) = mode, call.isListeningAsAsked {
            if let caption = call.caption, caption.id != stale, caption.kind == .hearing { heardWords = true }
            // A toggle with nothing said sends nothing, and there is nothing to wait for.
            if !heardWords {
                VoiceLog.log.info("pencil: nothing said, so nothing is sent")
                stopHearing()
                close()
                return
            }
        }
        mode = .sent(stale: call.caption?.id)
        bubble?.state = .working
        call.send()
        refresh()
    }

    private func stopHearing() {
        pendingListen?.cancel()
        pendingListen = nil
        call?.cancelListening()
    }

    private func startSilenceTimer() {
        lastHeard = (clock(), call?.caption?.id)
        silenceTimer?.cancel()
        let interval = silenceCheck
        silenceTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled, let lastHeard = self.lastHeard else { return }
                if self.clock() - lastHeard.at >= Self.silenceTimeout {
                    VoiceLog.log.info("pencil: nothing said, so the toggle closes")
                    self.stopHearing()
                    self.close()
                    return
                }
            }
        }
    }

    // MARK: Targets

    private func isOverChrome(_ viewPoint: CGPoint, in model: AppModel) -> Bool {
        viewPoint.y < model.topBarBottom || model.chromeFrames.values.contains { $0.contains(viewPoint) }
    }

    /// What the pen is over. Drawings are looked through, since voice can't change one.
    /// Part of what is selected means all of it.
    private func target(at viewPoint: CGPoint, in model: AppModel) -> VoiceTarget {
        guard let hit = model.hoverTarget(at: viewPoint, skippingDrawings: true) else {
            return .canvas(model.viewport.canvasPoint(for: viewPoint))
        }
        if let selection = model.selection, selection.isSeveral {
            var isPart = selection.contains(hit)
            // An element on a screen that is selected is part of it too.
            if case .element(let ref) = hit, case .screen(let id) = ref.host, selection.contains(.screen(id)) { isPart = true }
            if isPart { return .thing(selection) }
        }
        return .thing(hit)
    }

    private func select(_ target: VoiceTarget, in model: AppModel) {
        switch target {
        case .thing(let thing): model.selection = thing
        case .canvas: model.selection = nil
        }
    }

    /// A command is about to run: what it was spoken about is selected again, as a later
    /// squeeze may have moved the selection on.
    private func commandStarts(_ target: VoiceTarget?) {
        guard let model else { return }
        switch target {
        case .thing(let thing)?:
            model.newScreenAnchor = nil
            model.voiceHint = nil
            model.selection = thing
        case .canvas(let point)?:
            model.selection = nil
            model.newScreenAnchor = point
            model.voiceHint = Self.canvasHint
        case nil:
            break
        }
    }

    private func commandEnded() {
        model?.newScreenAnchor = nil
        model?.voiceHint = nil
    }

    // MARK: The bubble

    private func open(at anchor: CGPoint, azimuth: Angle?, _ state: State) {
        closing?.cancel()
        silenceTimer?.cancel()
        bubble = Bubble(anchor: anchor, azimuth: azimuth, state: state)
    }

    /// Shows the bubble's line for a while, and then closes it.
    private func say() {
        mode = .saying
        closing?.cancel()
        let time = problemTime
        closing = Task { [weak self] in
            try? await Task.sleep(for: time)
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func close() {
        mode = nil
        bubble = nil
        lastHeard = nil
        closing?.cancel()
        silenceTimer?.cancel()
    }

    /// Follows the call: whenever what it shows changes, the bubble is brought up to date.
    private func watch(_ call: VoiceCall) {
        withObservationTracking {
            _ = call.caption
            _ = call.isHearing
            _ = call.isListeningAsAsked
            _ = call.hasOpenListen
            _ = call.queuedCount
            _ = call.phase
        } onChange: { [weak self, weak call] in
            // Held weakly: the call keeps this closure, and mustn't keep itself through it.
            Task { @MainActor [weak self, weak call] in
                guard let self, let call, self.call === call else { return }
                self.refresh()
                self.endIfIdle()
                self.watch(call)
            }
        }
    }

    private func refresh() {
        guard let call, let mode, bubble != nil else { return }
        switch mode {
        case .listening(_, let toggled, let stale):
            let caption = call.caption?.id == stale ? nil : call.caption
            if let caption, caption.kind == .hearing {
                heardWords = true
                if toggled, caption.id != lastHeard?.caption { lastHeard = (clock(), caption.id) }
            }
            // Whether this listen failed is the call's to say. A problem shown while it is
            // still starting is some earlier command's.
            if askedToListen, !call.hasOpenListen {
                silenceTimer?.cancel()
                if let caption, caption.kind == .problem {
                    // The microphone or speech couldn't start, or stopped: why, until the line clears.
                    self.mode = .sent(stale: nil)
                    bubble?.state = .problem(caption.text)
                } else {
                    close()
                }
                return
            }
            bubble?.state = call.isListeningAsAsked ? .listening : .gettingReady
        case .sent(let stale):
            if let caption = call.caption, caption.id != stale {
                switch caption.kind {
                case .hearing, .working: bubble?.state = .working
                case .done: bubble?.state = .done
                // What the model said when it did nothing is never shown as done.
                case .said, .problem: bubble?.state = .problem(caption.text)
                }
            } else if call.isHearing || call.queuedCount > 0 || call.phase == .working {
                bubble?.state = .working
            } else {
                // Nothing came of it, or what came of it has been shown long enough.
                close()
            }
        case .saying:
            break
        }
    }
}

/// The runner a pencil call acts through: the design's own, with the pen's anchor and
/// hint let go of once each command is over.
@MainActor
private final class PencilRunner: VoiceCommandRunner {
    private let inner: any VoiceCommandRunner
    private let finished: @MainActor () -> Void

    init(_ inner: any VoiceCommandRunner, finished: @escaping @MainActor () -> Void) {
        self.inner = inner
        self.finished = finished
    }

    func warmUp() async {
        await inner.warmUp()
    }

    func run(_ command: String) async -> VoiceOutcome {
        let outcome = await inner.run(command)
        finished()
        return outcome
    }
}

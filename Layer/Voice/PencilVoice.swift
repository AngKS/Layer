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
    /// The longest a squeeze listens, held or toggled. A held squeeze's end can go astray
    /// (the canvas torn down, the gesture's end never delivered), and talk in the room
    /// keeps a toggle's silence from ever coming: either way, the microphone isn't left on
    /// for good.
    static let maximumHold: Duration = .seconds(60)
    /// Said when a squeeze listened for as long as one can.
    static let heldTooLong = "Stopped listening after a minute. Nothing was sent."

    /// How long a hover waits before asking again whether an unavailable model can be
    /// used now. Asking can read the Keychain, and the pen hovers many times a second.
    static let readinessRetry: Duration = .seconds(2)

    private(set) var bubble: Bubble?
    /// The pencil's call, from the first hover or squeeze.
    private(set) var call: VoiceCall?
    /// A squeeze during a phone call, which only moved what the next command is about: the
    /// pencil taps where it was, since no bubble opens to say so.
    struct Retarget: Equatable {
        var point: CGPoint
        var id = UUID()
    }

    private(set) var retarget: Retarget?

    /// Whether the squeeze under way, or the next one, is the pencil's to send with: a
    /// toggle is listening, or a squeeze has just sent one and hasn't been let go of. The
    /// format panel's scrubber leaves such a squeeze alone, whichever of them hears it first.
    /// With Squeeze to Talk off, neither can be so: see `squeezeToTalkTurnedOff()`.
    var ownsSqueeze: Bool {
        if endIsIgnored { return true }
        if case .listening(_, toggled: true, _) = mode { return true }
        return false
    }

    /// The words heard so far for this listen, for the bubble to show if asked. Words the
    /// call still shows from an earlier listen aren't these.
    var wordsHeard: String? {
        guard case .listening(_, _, let stale) = mode, let caption = call?.caption,
              caption.id != stale, caption.kind == .hearing else { return nil }
        return caption.text
    }

    /// The microphone levels of what is being listened to now, newest last, for the waveform.
    var levels: [Float] {
        guard let call, call.isListeningAsAsked else { return [] }
        return call.levels
    }

    /// Whether the system's Apple Pencil settings keep the squeeze from Layer, which it
    /// respects: see `systemKeepsSqueeze(_:)`.
    @ObservationIgnored var squeezeIsOff: @MainActor () -> Bool = { PencilVoice.systemKeepsSqueeze(UIPencilInteraction.preferredSqueezeAction) }
    /// Whether a phone call is up in any window. Only one thing hears at a time, so the
    /// pencil doesn't listen then. A test says.
    @ObservationIgnored var phoneCallIsUp: @MainActor () -> Bool
    /// The other windows' designs, whose pencils stop listening when this one starts: only
    /// one thing hears at a time. A test says.
    @ObservationIgnored var otherWindows: @MainActor () -> [AppModel]
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
        /// Sent: the bubble follows the command numbered `command`, its captions and
        /// nobody else's, until it is over and its caption has cleared.
        case sent(command: Int)
        /// This listen failed: the bubble shows the call's caption saying why, until it clears.
        case failed(caption: UUID)
        /// Showing a line of its own, which closes after `problemTime`.
        case saying
    }

    @ObservationIgnored private weak var model: AppModel?
    /// How each listen hears, and what carries a command out.
    @ObservationIgnored private(set) var makeRoute: @MainActor () -> any VoiceRoute
    @ObservationIgnored private(set) var makeRunner: @MainActor (AppModel) -> any VoiceCommandRunner
    @ObservationIgnored private let clock: () -> ContinuousClock.Instant
    @ObservationIgnored private var mode: Mode?
    /// The call getting ready, which a squeeze waits on before it listens.
    @ObservationIgnored private var starting: Task<Void, Never>?
    /// A listen waiting on the call to be ready, not yet asked of it.
    @ObservationIgnored private var pendingListen: Task<Void, Never>?
    /// Whether the call has been asked for this listen. From then on, the call's own
    /// `hasOpenListen` says whether it is still going.
    @ObservationIgnored private var askedToListen = false
    /// Set once the design has closed: the call ends as soon as it has nothing to finish.
    @ObservationIgnored private var designHasClosed = false
    /// Set when Squeeze to Talk went off, which ends the call in the same way. The next
    /// call, once it is back on, is a new one.
    @ObservationIgnored private var squeezeWentOff = false
    /// Set when a squeeze sent a toggle: letting go of that squeeze does nothing more.
    @ObservationIgnored private var endIsIgnored = false
    @ObservationIgnored private var silenceTimer: Task<Void, Never>?
    /// Ends a held squeeze whose end never comes: see `maximumHold`.
    @ObservationIgnored private var holdTimer: Task<Void, Never>?
    /// When words were last heard by a toggle, and which.
    @ObservationIgnored private var lastHeard: (at: ContinuousClock.Instant, caption: UUID?)?
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// When a hover last asked whether the model can be used, while it couldn't.
    @ObservationIgnored private var lastReadinessCheck: ContinuousClock.Instant?
    @ObservationIgnored nonisolated(unsafe) private var preferencesObserver: (any NSObjectProtocol)?

    init(
        model: AppModel,
        makeRoute: @escaping @MainActor () -> any VoiceRoute = PencilVoice.standardRoute,
        makeRunner: @escaping @MainActor (AppModel) -> any VoiceCommandRunner = PencilVoice.standardRunner(for:),
        clock: @escaping () -> ContinuousClock.Instant = { .now }
    ) {
        self.model = model
        self.makeRoute = makeRoute
        self.makeRunner = makeRunner
        self.clock = clock
        readiness = { [weak model] in model?.modelChoice.sketchProvider.readiness() ?? .ready }
        otherWindows = { [weak model] in OpenDesigns.shared.all.filter { $0 !== model } }
        phoneCallIsUp = { [weak model] in (model?.phoneLine ?? .shared).call != nil }
        // A key added or a model chosen in Settings may have made the model usable.
        preferencesObserver = NotificationCenter.default.addObserver(forName: ModelPreferences.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastReadinessCheck = nil }
        }
    }

    /// A listen's route: a command ends when the squeeze says so, not at a pause, and a
    /// problem is put in the pencil's words.
    static func standardRoute() -> any VoiceRoute {
        DictationRoute(endsOnPause: false, serving: .pencil)
    }

    /// What carries the pencil's commands out: the design's agent, without the tool that
    /// ends a call, since the pencil's stays up for the next squeeze.
    static func standardRunner(for model: AppModel) -> any VoiceCommandRunner {
        VoiceAgent(model: model, canEndCall: false)
    }

    /// Whether the squeeze chosen in the system's settings isn't Layer's to take: squeezing
    /// is turned off, or runs a shortcut, which the system does without asking the app.
    static func systemKeepsSqueeze(_ action: UIPencilPreferredAction) -> Bool {
        action == .ignore || action == .runSystemShortcut
    }

    #if DEBUG
    /// Puts the simulator's scripted squeeze into the instance the canvas already shows,
    /// which keeps to the one it first read. Reaches the next call, not one already up.
    func script(route makeRoute: @escaping @MainActor () -> any VoiceRoute, runner makeRunner: @escaping @MainActor (AppModel) -> any VoiceCommandRunner) {
        self.makeRoute = makeRoute
        self.makeRunner = makeRunner
    }
    #endif

    deinit {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    }

    // MARK: The pencil

    /// The pen came into hover range. The first time, the model gets ready, so that the
    /// first squeeze doesn't wait on it. Nothing listens.
    func hovered() {
        // A phone call hears everything while it is up, in this window or another: the
        // pencil's own isn't needed. In Draw the squeeze is PencilKit's, so the pen hovering
        // there isn't on its way to one, nor anywhere when squeezing doesn't talk.
        guard call == nil, let model, model.tool != .draw, model.squeezesToTalk, !squeezeIsOff(),
              model.voice == nil, !phoneCallIsUp() else { return }
        if let lastReadinessCheck, clock() - lastReadinessCheck < Self.readinessRetry { return }
        guard case .ready = readiness() else {
            lastReadinessCheck = clock()
            return
        }
        lastReadinessCheck = nil
        startCall()
    }

    /// A squeeze began, with the pen hovering at `viewPoint`, or out of range when nil.
    func squeezeBegan(at viewPoint: CGPoint?, azimuth: Angle?) {
        // With Squeeze to Talk off the squeeze is the system's: it starts and sends nothing.
        guard model?.squeezesToTalk != false else {
            VoiceLog.log.info("pencil: squeeze ignored (squeeze to talk off)")
            return
        }
        // Only starting needs the pen in range: a toggle is sent wherever the pen has drifted.
        if case .listening(_, toggled: true, _) = mode {
            endIsIgnored = true
            send()
            return
        }
        // One squeeze already listening: a second start of it isn't a new one.
        if case .listening(_, toggled: false, _) = mode { return }
        guard let model, let viewPoint, !squeezeIsOff(), model.tool != .draw, !isOverChrome(viewPoint, in: model) else {
            VoiceLog.log.info("pencil: squeeze ignored (in range \(viewPoint != nil, privacy: .public), squeeze off \(self.squeezeIsOff(), privacy: .public), draw \(self.model?.tool == .draw, privacy: .public), over chrome \(viewPoint.flatMap { p in self.model.map { self.isOverChrome(p, in: $0) } } ?? false, privacy: .public))")
            return
        }
        // A phone call in another window has the microphone, and its commands are about that
        // window's design: a squeeze here has nothing to say to it, so it does nothing.
        if model.voice == nil, phoneCallIsUp() { return }
        endIsIgnored = false
        let target = target(at: viewPoint, in: model)
        select(target, in: model)
        // This window's phone call hears the command: the squeeze only said what it is about.
        guard model.voice == nil else {
            retarget = Retarget(point: viewPoint)
            return
        }
        if case .unavailable(let reason) = readiness() {
            open(at: viewPoint, azimuth: azimuth, .problem(reason))
            say()
            return
        }
        // One microphone at a time: a pencil listening in another window lets go, unsent.
        for other in otherWindows() { other.stopPencilListening() }
        guard let call = startCall() else { return }
        open(at: viewPoint, azimuth: azimuth, .gettingReady)
        mode = .listening(began: clock(), toggled: false, stale: call.caption?.id)
        listen(for: target, on: call)
        startHoldTimer()
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

    /// Draw came on, which takes the squeeze for PencilKit's palette: a squeeze under way
    /// will never be heard to end, so whatever it was listening to is let go of, unsent.
    /// A command already sent is left to finish.
    func drawTurnedOn() {
        letGoOfSqueeze()
    }

    /// Squeeze to Talk was turned off, which takes the squeeze away as Draw does: whatever
    /// was being listened to is let go of, unsent. The call isn't needed until it is back
    /// on, so it ends, once a command already sent has finished.
    func squeezeToTalkTurnedOff() {
        letGoOfSqueeze()
        squeezeWentOff = true
        endIfIdle()
    }

    private func letGoOfSqueeze() {
        endIsIgnored = false
        if case .listening = mode {
            stopHearing()
            close()
        }
    }

    /// The squeeze's gesture failed, or the view it was on went away: its end won't come.
    /// A held squeeze is let go of unsent, since nobody said it was over.
    func squeezeFailed() {
        if endIsIgnored {
            endIsIgnored = false
            return
        }
        guard case .listening(_, toggled: false, _) = mode else { return }
        stopHearing()
        close()
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
    /// has stopped. A running command isn't cancelled here, but it ends at its next tool
    /// call, since nothing more is done to a closed design (see `VoiceAgent.makeSession`).
    func designClosed() {
        designHasClosed = true
        stopListening()
        // Routes sent and still settling are stopped too: nothing more is sent.
        call?.stopAllListening()
        endIfIdle()
    }

    private func endIfIdle() {
        guard designHasClosed || squeezeWentOff, let call, !call.isHearing, call.queuedCount == 0, call.phase != .working else { return }
        call.end()
    }

    // MARK: Listening

    @discardableResult
    private func startCall() -> VoiceCall? {
        // Back on: the call is wanted again, should it still be finishing a command.
        squeezeWentOff = false
        if let call { return call }
        guard let model else { return nil }
        let runner = makeRunner(model)
        let call = VoiceCall(listening: .onRequest(makeRoute: makeRoute), runner: runner, vocabulary: { [weak model] in model?.voiceVocabulary ?? [] })
        // A phone call's commands and this one's take turns.
        call.gate = model.voiceCommands
        // What the agent is doing, tool by tool, is what the bubble's caption says.
        (runner as? VoiceAgent)?.onStep = { [weak call] step in call?.showStep(step) }
        call.onCommandStarts = { [weak self] target in self?.commandStarts(target) }
        // The call ends only with the design. The next squeeze after that starts another.
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
        holdTimer?.cancel()
        guard let call else { return }
        if let pendingListen {
            // Let go of before the call was even ready to listen, so nothing was heard.
            pendingListen.cancel()
            self.pendingListen = nil
            bubble?.state = .problem(VoiceCall.tooSoon)
            say()
            return
        }
        // The listen failed a moment ago, and the bubble hasn't caught up: why is shown,
        // rather than a send that has nothing to send.
        if askedToListen, !call.hasOpenListen, case .listening = mode {
            refresh()
            return
        }
        // Whether anything was said is the route's to say once it is told to finish: words
        // spoken just before the squeeze may not have been shown yet. With nothing, it says
        // so at once and the bubble closes.
        guard let number = call.send() else {
            close()
            return
        }
        mode = .sent(command: number)
        bubble?.state = .working
        refresh()
    }

    private func stopHearing() {
        pendingListen?.cancel()
        pendingListen = nil
        call?.cancelListening()
    }

    private func startHoldTimer() {
        holdTimer?.cancel()
        let interval = silenceCheck
        holdTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // A toggle too: words in the room keep its silence timer from running out.
                guard let self, !Task.isCancelled, case .listening(let began, _, _) = self.mode else { return }
                if self.clock() - began >= Self.maximumHold {
                    VoiceLog.log.info("pencil: a listen went on too long, so it stops")
                    self.stopHearing()
                    self.bubble?.state = .problem(Self.heldTooLong)
                    self.say()
                    return
                }
            }
        }
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

    /// The bubble still on screen from the last squeeze isn't counted: a squeeze over it is
    /// a new one, which replaces it. A Pencil tap on it is still a tap on chrome.
    private func isOverChrome(_ viewPoint: CGPoint, in model: AppModel) -> Bool {
        viewPoint.y < model.topBarBottom
            || model.chromeFrames.contains { $0.key != PencilVoiceBubble.chromeName && $0.value.contains(viewPoint) }
    }

    /// What the pen is over. Drawings are looked through, since voice can't change one.
    /// Part of what is selected means all of it, a drawing in it included: the drawing is
    /// looked at before it is looked through.
    private func target(at viewPoint: CGPoint, in model: AppModel) -> VoiceTarget {
        if let selection = model.selection, selection.isSeveral,
           let top = model.hoverTarget(at: viewPoint), Self.isPart(top, of: selection) {
            return .thing(selection)
        }
        guard let hit = model.hoverTarget(at: viewPoint, skippingDrawings: true) else {
            return .canvas(model.viewport.canvasPoint(for: viewPoint))
        }
        if let selection = model.selection, selection.isSeveral, Self.isPart(hit, of: selection) {
            return .thing(selection)
        }
        return .thing(hit)
    }

    private static func isPart(_ hit: CanvasSelection, of selection: CanvasSelection) -> Bool {
        if selection.contains(hit) { return true }
        // An element on a screen that is selected is part of it too.
        if case .element(let ref) = hit, case .screen(let id) = ref.host, selection.contains(.screen(id)) { return true }
        return false
    }

    private func select(_ target: VoiceTarget, in model: AppModel) {
        switch target {
        case .thing(let thing): model.selection = thing
        case .canvas: model.selection = nil
        }
    }

    /// A command is about to run: what it was spoken about is selected again, as a later
    /// squeeze may have moved the selection on. Where a new screen goes goes with the
    /// command itself, to the agent.
    private func commandStarts(_ target: VoiceTarget?) {
        guard let model else { return }
        switch target {
        case .thing(let thing)?: model.selection = thing
        case .canvas?: model.selection = nil
        case nil: break
        }
    }

    // MARK: The bubble

    private func open(at anchor: CGPoint, azimuth: Angle?, _ state: State) {
        closing?.cancel()
        silenceTimer?.cancel()
        holdTimer?.cancel()
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
        holdTimer?.cancel()
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
            _ = call.settling
            _ = call.working
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
            if let caption, caption.kind == .hearing, toggled, caption.id != lastHeard?.caption {
                lastHeard = (clock(), caption.id)
            }
            // Whether this listen failed is the call's to say. A problem shown while it is
            // still starting is some earlier command's, and so is one about a command: a
            // listen not yet sent has no number.
            if askedToListen, !call.hasOpenListen {
                silenceTimer?.cancel()
                holdTimer?.cancel()
                if let caption, caption.kind == .problem, caption.command == nil {
                    // The microphone or speech couldn't start, or stopped: why, until the line clears.
                    self.mode = .failed(caption: caption.id)
                    bubble?.state = .problem(caption.text)
                } else {
                    close()
                }
                return
            }
            bubble?.state = call.isListeningAsAsked ? .listening : .gettingReady
        case .sent(let number):
            // Another command's working, outcome or problem isn't this one's.
            if let caption = call.caption, caption.command == number {
                switch caption.kind {
                case .hearing, .working: bubble?.state = .working
                case .done: bubble?.state = .done
                // What the model said when it did nothing is never shown as done.
                case .said, .problem: bubble?.state = .problem(caption.text)
                }
            } else if call.isUnderWay(number) {
                // Still settling, waiting its turn, or running: whatever else the call is doing.
                bubble?.state = .working
            } else {
                // Nothing came of it (nothing was heard, or it was no command), or what came
                // of it has been shown long enough.
                close()
            }
        case .failed(let id):
            if call.caption?.id != id { close() }
        case .saying:
            break
        }
    }
}

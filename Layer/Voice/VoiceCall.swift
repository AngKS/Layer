import Foundation
import Observation

/// One call in voice mode, from the phone button being tapped to hanging up: what it is
/// doing, what it has to say, how loud the room is, and the commands waiting their turn.
///
/// A call only listens and keeps order. Hearing is its route's job and carrying a command
/// out is its runner's, so the same call serves speech recognised on the iPad and audio
/// streamed to a model.
@MainActor
@Observable
final class VoiceCall {
    enum Phase: Equatable {
        /// Getting the microphone and whatever the route needs before it can hear.
        case starting
        case listening
        /// A command is being carried out. The call still listens, for the next one.
        case working
        case ended
    }

    /// Something said that the call acts on itself, without asking a model.
    enum LocalAction: Equatable {
        case stop
        case hangUp
    }

    /// The line the pill grows to show.
    struct Caption: Equatable {
        enum Kind: Equatable {
            case hearing
            case working
            case done
            /// What the model said when it did nothing: why it couldn't, most often.
            /// Never shown as done, because nothing was.
            case said
            case problem
        }

        var kind: Kind
        var text: String
    }

    /// How many microphone levels are kept, which is how many bars the waveform has.
    static let levelCount = 28

    /// The call that is up, in whichever window. There is one microphone, so one call:
    /// starting another ends this one.
    static weak var current: VoiceCall?

    private(set) var phase = Phase.starting
    private(set) var caption: Caption?
    /// When listening began, which is when the timer starts.
    private(set) var startedAt: Date?
    /// The latest microphone levels, newest last.
    private(set) var levels: [Float] = []
    /// Commands spoken and not yet started.
    private(set) var queuedCount = 0
    /// Why the call ended, when it wasn't hung up.
    private(set) var endReason: String?

    /// How long a caption stays once there is nothing more to add to it.
    @ObservationIgnored var captionTimes: (done: Duration, problem: Duration) = (.seconds(3), .seconds(6))
    /// Called once, when the call ends for any reason.
    @ObservationIgnored var onEnd: (() -> Void)?

    @ObservationIgnored private let route: any VoiceRoute
    @ObservationIgnored private let runner: any VoiceCommandRunner
    @ObservationIgnored private let vocabulary: @MainActor () -> [String]
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var running: Task<VoiceOutcome, Never>?
    @ObservationIgnored private var captionClearing: Task<Void, Never>?

    init(route: any VoiceRoute, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] }) {
        self.route = route
        self.runner = runner
        self.vocabulary = vocabulary
    }

    // MARK: Starting and ending

    /// Starts listening. Returns once the route can hear, or has said why it can't.
    func start() async {
        guard phase == .starting, listening == nil else { return }
        if let other = Self.current, other !== self { other.end() }
        Self.current = self
        // Asking for the microphone, or fetching what speech recognition needs, can take a while.
        show(.working, "Getting ready to listen…")
        VoiceLog.log.info("call: getting ready")
        do {
            let events = try await route.start(vocabulary: vocabulary())
            // Hung up while it was getting ready.
            guard phase == .starting else { return }
            VoiceLog.log.info("call: listening")
            phase = .listening
            startedAt = .now
            caption = nil
            listening = Task { [weak self] in
                for await event in events {
                    self?.handle(event)
                }
            }
        } catch {
            VoiceLog.log.error("call: couldn't start: \(String(reflecting: error), privacy: .public)")
            end(because: (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Hangs up: the microphone stops at once, and a command under way is stopped.
    func end() {
        end(because: nil)
    }

    private func end(because reason: String?) {
        guard phase != .ended else { return }
        VoiceLog.log.info("call: ended, \(reason ?? "hung up", privacy: .public)")
        phase = .ended
        endReason = reason
        route.stop()
        listening?.cancel()
        running?.cancel()
        worker?.cancel()
        captionClearing?.cancel()
        queue.removeAll()
        queuedCount = 0
        caption = nil
        if Self.current === self { Self.current = nil }
        onEnd?()
    }

    // MARK: Hearing

    private func handle(_ event: VoiceRouteEvent) {
        guard phase != .ended else { return }
        switch event {
        case .level(let level):
            levels.append(level)
            if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
        case .hearing(let words):
            if !words.isEmpty { show(.hearing, words) }
        case .command(let command):
            received(command)
        case .failed(let reason):
            end(because: reason)
        }
    }

    private func received(_ command: String) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let action = Self.localAction(for: command)
        VoiceLog.log.info("call: heard a command of \(command.count) characters\(action == nil ? "" : ", acted on here", privacy: .public): \(command, privacy: .private)")
        switch action {
        case .stop:
            // The command under way reports that it was stopped, which is what is shown.
            queue.removeAll()
            queuedCount = 0
            if let running { running.cancel() } else { caption = nil }
        case .hangUp:
            end()
        case nil:
            queue.append(command)
            queuedCount = queue.count
            startWorker()
        }
    }

    /// "Stop" and "hang up" are acted on here, so that they work at once and whatever the
    /// model is doing. Only the bare phrases count: "stop the button being blue" is a
    /// command. A "please" or an "OK" with them is still the bare phrase.
    static func localAction(for command: String) -> LocalAction? {
        let words = command.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["please", "ok", "okay"].contains($0) }
            .joined(separator: " ")
        switch words {
        case "stop", "cancel", "stop that", "cancel that", "stop it", "cancel it": return .stop
        case "hang up", "end call", "end the call", "goodbye": return .hangUp
        default: return nil
        }
    }

    // MARK: Working

    /// Carries the waiting commands out, one at a time and in the order they were spoken.
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase != .ended, !self.queue.isEmpty else { break }
                let command = self.queue.removeFirst()
                self.queuedCount = self.queue.count
                self.phase = .working
                self.show(.working, "Thinking…")
                let runner = self.runner
                let run = Task { await runner.run(command) }
                self.running = run
                let outcome = await run.value
                self.running = nil
                guard self.phase != .ended else { break }
                self.show(outcome)
                if outcome.endsCall {
                    self.end()
                    break
                }
            }
            guard let self else { return }
            self.worker = nil
            if self.phase == .working { self.phase = .listening }
        }
    }

    /// What the command under way is doing right now, such as "Restyling…".
    func showStep(_ text: String) {
        guard phase == .working else { return }
        show(.working, text)
    }

    private func show(_ outcome: VoiceOutcome) {
        VoiceLog.log.info("""
            call: command over. steps \(outcome.lines.count), stopped \(outcome.wasCancelled), \
            problem: \(outcome.problem ?? "none", privacy: .private), said: \(outcome.said, privacy: .private)
            """)
        if outcome.wasCancelled {
            show(.done, "Stopped")
        } else if let problem = outcome.problem {
            show(.problem, problem)
        } else if let line = outcome.lines.last {
            show(.done, line)
        } else if !outcome.said.isEmpty {
            // Nothing was done, so no tick, whatever the model says it did.
            show(.said, outcome.said)
        } else {
            caption = nil
        }
    }

    private func show(_ kind: Caption.Kind, _ text: String) {
        captionClearing?.cancel()
        let shown = Caption(kind: kind, text: text)
        caption = shown
        // Words being heard and work under way stay until something replaces them.
        let time: Duration
        switch kind {
        case .done: time = captionTimes.done
        case .problem, .said: time = captionTimes.problem
        case .hearing, .working: return
        }
        captionClearing = Task { [weak self] in
            try? await Task.sleep(for: time)
            guard !Task.isCancelled, let self, self.caption == shown else { return }
            self.caption = nil
        }
    }
}

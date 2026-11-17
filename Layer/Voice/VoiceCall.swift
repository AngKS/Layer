import Foundation
import Observation

/// What a command was spoken about: a thing on the canvas, or a place on it, in canvas
/// coordinates. Squeezing the pencil over something says which.
enum VoiceTarget: Equatable, Sendable {
    case thing(CanvasSelection)
    case canvas(CGPoint)
}

/// One call in voice mode, from the phone button being tapped to hanging up: what it is
/// doing, what it has to say, how loud the room is, and the commands waiting their turn.
///
/// A call only listens and keeps order. Hearing is its route's job and carrying a command
/// out is its runner's, so the same call serves speech recognised on the iPad and audio
/// streamed to a model.
@MainActor
@Observable
final class VoiceCall {
    /// When a call hears. A phone call listens the whole time and takes a pause as the end
    /// of a command. A pencil call listens only while asked, with a fresh route each time,
    /// and a command ends when the person says so.
    enum Listening {
        case continuous(any VoiceRoute)
        case onRequest(makeRoute: @MainActor () -> any VoiceRoute)
    }

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

    /// The phone call that is up, in whichever window. Only one listens the whole time, so
    /// starting another ends this one. A pencil call isn't counted: it holds the microphone
    /// only while asked, and lives alongside a phone call.
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
    /// Whether a route asked for is open, from its starting until it stops. Only a call
    /// that listens on request has these.
    private(set) var isHearing = false

    /// How long a caption stays once there is nothing more to add to it.
    @ObservationIgnored var captionTimes: (done: Duration, problem: Duration) = (.seconds(3), .seconds(6))
    /// Called once, when the call ends for any reason.
    @ObservationIgnored var onEnd: (() -> Void)?
    /// Called just before each command is carried out, with what it was spoken about, so
    /// that the canvas can turn to it first.
    @ObservationIgnored var onCommandStarts: ((VoiceTarget?) -> Void)?
    /// How long a route told to finish has to send its command before it is stopped
    /// anyway. A late phrase can keep a recogniser settling for a couple of seconds.
    @ObservationIgnored var finishWait: Duration = .seconds(3)

    @ObservationIgnored private let listeningStyle: Listening
    @ObservationIgnored private let runner: any VoiceCommandRunner
    @ObservationIgnored private let vocabulary: @MainActor () -> [String]
    @ObservationIgnored private var queue: [(text: String, target: VoiceTarget?)] = []
    /// The route asked for and not yet told the command is over.
    @ObservationIgnored private var open: Ear?
    /// Routes told the command is over, waiting for it to arrive.
    @ObservationIgnored private var finishing: [Ear] = []
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var running: Task<VoiceOutcome, Never>?
    @ObservationIgnored private var captionClearing: Task<Void, Never>?

    init(listening: Listening, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] }) {
        listeningStyle = listening
        self.runner = runner
        self.vocabulary = vocabulary
    }

    convenience init(route: any VoiceRoute, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] }) {
        self.init(listening: .continuous(route), runner: runner, vocabulary: vocabulary)
    }

    private var listensOnRequest: Bool {
        if case .onRequest = listeningStyle { true } else { false }
    }

    // MARK: Starting and ending

    /// Starts listening. Returns once the route can hear, or has said why it can't.
    func start() async {
        guard phase == .starting, listening == nil else { return }
        guard case .continuous(let route) = listeningStyle else {
            // Nothing to hear until asked, but the model can get ready all the same. There
            // is no microphone to wait on here, and warming up only starts the model off,
            // so it is awaited.
            await runner.warmUp()
            VoiceLog.log.info("call: listening when asked")
            phase = .listening
            startedAt = .now
            return
        }
        if let other = Self.current, other !== self { other.end() }
        Self.current = self
        // Asking for the microphone, or fetching what speech recognition needs, can take a while.
        show(.working, "Getting ready to listen…")
        VoiceLog.log.info("call: getting ready")
        // A model's first answer in a conversation is its slowest by far, so it gets
        // ready while the microphone does and the person draws breath.
        let runner = runner
        Task { await runner.warmUp() }
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
        if case .continuous(let route) = listeningStyle { route.stop() }
        for ear in [open].compactMap({ $0 }) + finishing { ear.close() }
        open = nil
        finishing.removeAll()
        isHearing = false
        listening?.cancel()
        running?.cancel()
        worker?.cancel()
        captionClearing?.cancel()
        letGoOfFragment()
        queue.removeAll()
        queuedCount = 0
        caption = nil
        if Self.current === self { Self.current = nil }
        onEnd?()
    }

    // MARK: Listening when asked

    /// One route asked for, and what its commands were spoken about.
    @MainActor
    private final class Ear {
        let route: any VoiceRoute
        let target: VoiceTarget?
        var events: Task<Void, Never>?
        var deadline: Task<Void, Never>?

        init(route: any VoiceRoute, target: VoiceTarget?) {
            self.route = route
            self.target = target
        }

        func close() {
            route.stop()
            events?.cancel()
            deadline?.cancel()
        }
    }

    /// Starts listening for one command about `target`. Asked again before `send()`, the
    /// route listening now is let go and a fresh one takes its place. A command already
    /// sent still arrives, about what it was spoken about.
    func listen(for target: VoiceTarget?) async {
        guard case .onRequest(let makeRoute) = listeningStyle, phase == .listening || phase == .working else { return }
        if let open { close(open) }
        let ear = Ear(route: makeRoute(), target: target)
        open = ear
        do {
            let events = try await ear.route.start(vocabulary: vocabulary())
            // Let go of, or the call ended, while the route was getting ready.
            guard open === ear, phase != .ended else {
                ear.route.stop()
                return
            }
            VoiceLog.log.info("call: listening, as asked")
            isHearing = true
            ear.events = Task { [weak self, weak ear] in
                for await event in events {
                    guard let self, let ear else { return }
                    self.handle(event, from: ear)
                }
                // The route stopped by itself.
                guard let self, let ear else { return }
                self.close(ear)
            }
        } catch {
            VoiceLog.log.error("call: couldn't listen: \(String(reflecting: error), privacy: .public)")
            guard open === ear else { return }
            close(ear)
            // A pencil call stays up for the next squeeze, so this one only says why.
            show(.problem, (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The command is over: the route settles what it heard and sends it, and is stopped
    /// once it has, or after `finishWait` if nothing comes.
    func send() {
        guard let ear = open else { return }
        open = nil
        finishing.append(ear)
        ear.route.finish()
        let wait = finishWait
        ear.deadline = Task { [weak self, weak ear] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let ear else { return }
            self.close(ear)
        }
    }

    /// Stops listening without acting on anything heard.
    func cancelListening() {
        guard let ear = open else { return }
        close(ear)
        if caption?.kind == .hearing { caption = nil }
    }

    private func close(_ ear: Ear) {
        ear.close()
        if open === ear { open = nil }
        finishing.removeAll { $0 === ear }
        isHearing = open != nil || !finishing.isEmpty
    }

    private func handle(_ event: VoiceRouteEvent, from ear: Ear) {
        // Something heard after the listening was let go of is not to be acted on.
        guard open === ear || finishing.contains(where: { $0 === ear }) else { return }
        if case .failed(let reason) = event {
            // As when it can't start: this listen is over, and the call stays up.
            close(ear)
            show(.problem, reason)
        } else if case .command = event, finishing.contains(where: { $0 === ear }) {
            handle(event, target: ear.target)
            close(ear)
        } else {
            handle(event, target: ear.target)
        }
    }

    // MARK: Hearing

    private func handle(_ event: VoiceRouteEvent, target: VoiceTarget? = nil) {
        guard phase != .ended else { return }
        switch event {
        case .level(let level):
            levels.append(level)
            if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
        case .hearing(let words):
            if !words.isEmpty { show(.hearing, words) }
        case .command(let command):
            received(command, target: target)
        case .failed(let reason):
            end(because: reason)
        }
    }

    private func received(_ command: String, target: VoiceTarget?) {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        var action = Self.localAction(for: command)
        // A pencil call stays up for the next squeeze: "hang up" there only means stop
        // what is going on.
        if action == .hangUp, listensOnRequest { action = .stop }
        VoiceLog.log.info("call: heard a command of \(command.count) characters\(action == nil ? "" : ", acted on here", privacy: .public): \(command, privacy: .private)")
        if action != nil { letGoOfFragment() }
        switch action {
        case .stop:
            // The command under way reports that it was stopped, which is what is shown.
            queue.removeAll()
            queuedCount = 0
            if let running { running.cancel() } else { caption = nil }
        case .hangUp:
            end()
        case nil where listensOnRequest:
            // The person said they were done, so there is no rest of the sentence to wait for.
            take(command, target: target)
        case nil:
            var command = command
            // The rest of a sentence that stopped mid-way.
            if let held = heldFragment {
                command = held + " " + command
                letGoOfFragment()
            }
            // Only something worth asking about is waited on: "So" alone is let go at once.
            if Self.endsMidSentence(command), Self.isWorthAsking(command) {
                hold(command)
            } else {
                take(command, target: nil)
            }
        }
    }

    private func take(_ command: String, target: VoiceTarget?) {
        guard Self.isWorthAsking(command) else {
            VoiceLog.log.info("call: let go, it is no command")
            // The words were shown as they were heard, and aren't to be acted on.
            if caption?.kind == .hearing { caption = nil }
            return
        }
        queue.append((command, target))
        queuedCount = queue.count
        startWorker()
    }

    /// Keeps a sentence that stopped mid-way for the rest of it, and takes it as it is if
    /// nothing follows.
    private func hold(_ fragment: String) {
        VoiceLog.log.info("call: waiting for the rest of a sentence")
        heldFragment = fragment
        show(.hearing, fragment)
        let wait = fragmentWait
        fragmentTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let held = self.heldFragment, self.phase != .ended else { return }
            self.letGoOfFragment()
            self.take(held, target: nil)
        }
    }

    private func letGoOfFragment() {
        heldFragment = nil
        fragmentTimer?.cancel()
        fragmentTimer = nil
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

    /// Whether what was heard is worth putting to a model. A pause for thought can leave
    /// a noise or a single word on its own, "So" or the "make" of a sentence not yet
    /// said, and a model handed one does something all the same. Only a word that is a
    /// command by itself is taken alone; anything of two words that mean something is.
    /// How long a sentence stopped mid-way waits for the rest before it is taken as it is.
    @ObservationIgnored var fragmentWait: Duration = .seconds(4)
    @ObservationIgnored private var heldFragment: String?
    @ObservationIgnored private var fragmentTimer: Task<Void, Never>?

    /// Whether what was heard stops in the middle of a sentence, on a word that needs
    /// more after it: "I want a screen to". A pause there is a thought, not the end.
    static func endsMidSentence(_ command: String) -> Bool {
        let words = command.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let last = words.last else { return false }
        return needsMore.contains(last)
    }

    /// Words a sentence doesn't end on. Not "in", "on", "up" and the like, which end
    /// "zoom in" and "turn it on"; nor "this" and "that", which end "undo that".
    private static let needsMore: Set<String> = [
        "to", "the", "a", "an", "and", "or", "but", "of", "for", "with", "into", "onto", "at", "by", "from", "my", "your",
        "its", "their", "then", "than", "as", "is", "are", "be", "so", "because", "about", "below", "above", "beside",
        "under", "between", "make", "put", "move", "set", "change", "add", "give", "want", "can", "could", "would",
    ]

    static func isWorthAsking(_ command: String) -> Bool {
        let words = command.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !noises.contains($0) }
        return words.count > 1 || (words.count == 1 && commandsOfOneWord.contains(words[0]))
    }

    /// Words that fill a pause or start a sentence, and say nothing by themselves.
    private static let noises: Set<String> = [
        "so", "um", "uh", "er", "erm", "hmm", "mm", "ah", "oh", "okay", "ok", "yeah", "yes", "yep", "no", "nope", "well",
        "right", "like", "and", "then", "but", "the", "a", "an", "you", "please", "hey", "hi", "hello",
    ]

    private static let commandsOfOneWord: Set<String> = [
        "undo", "redo", "delete", "duplicate", "bigger", "larger", "smaller", "bold", "centre", "center",
    ]

    // MARK: Working

    /// Carries the waiting commands out, one at a time and in the order they were spoken.
    private func startWorker() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.phase != .ended, !self.queue.isEmpty else { break }
                let (command, target) = self.queue.removeFirst()
                self.queuedCount = self.queue.count
                self.phase = .working
                self.show(.working, "Thinking…")
                self.onCommandStarts?(target)
                let runner = self.runner
                let run = Task { await runner.run(command) }
                self.running = run
                let outcome = await run.value
                self.running = nil
                guard self.phase != .ended else { break }
                self.show(outcome)
                // Stopped or gone wrong, the model starts afresh for the next command.
                // Warmed now, the next one doesn't wait on that.
                if outcome.wasCancelled || outcome.problem != nil {
                    Task { await runner.warmUp() }
                }
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

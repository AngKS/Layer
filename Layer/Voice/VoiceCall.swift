import Foundation
import Observation

/// What a command was spoken about: a thing on the canvas, or a place on it, in canvas
/// coordinates. Squeezing the pencil over something says which.
enum VoiceTarget: Equatable, Sendable {
    case thing(CanvasSelection)
    case canvas(CGPoint)
    /// A change typed, or held to speak, about one screen and everything on it. It can
    /// change nothing else.
    case screenEdit(DesignScreen.ID)
}

/// Where the phone call that is up, in whichever window, is kept. Only one listens the
/// whole time, so starting another ends it. A pencil call isn't counted: it holds the
/// microphone only while asked, and lives alongside a phone call.
///
/// The app has one line. A test gives its designs and calls a line of their own: on the
/// one line, a call started by one test ended the call of another running alongside.
@MainActor
final class PhoneLine {
    static let shared = PhoneLine()

    /// The call that is up on this line.
    weak var call: VoiceCall?
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
        /// Which showing of a line this is, so that the same words shown twice can be
        /// told apart. Not part of what the line says, so not part of `==`.
        var id = UUID()
        /// Which command the line is about, numbered as the call took them, when it is
        /// about one: what a sent pencil bubble follows. Not part of `==` either.
        var command: Int?

        static func == (lhs: Caption, rhs: Caption) -> Bool {
            lhs.kind == rhs.kind && lhs.text == rhs.text
        }
    }

    /// How one command is getting on, told from the lines about it: what a typed change's
    /// field shows in place of its words.
    enum Progress: Equatable {
        /// Waiting its turn or being carried out, with the step its line says it is on.
        /// Without a line of its own (waiting behind another command, its route still
        /// settling, or its line replaced by words being heard) there is no step to show.
        case working(String?)
        /// What was done, as its line says.
        case done(String)
        /// What the model said when it did nothing.
        case said(String)
        case problem(String)
        /// Nothing more to show: its line has gone or been replaced, or it was never taken.
        case over
    }

    /// Said when a listen is sent before its route could hear anything.
    static let tooSoon = "Didn't catch that. Wait for the tap, then speak."

    /// Said when a listen was sent with words heard, and its command never came.
    static let missedTheEnd = "Didn't catch the end of that."

    /// How many microphone levels are kept, which is how many bars the waveform has.
    static let levelCount = 28

    /// The line phone calls are made on. Only one call on it listens the whole time, so
    /// starting another ends the one that is up.
    @ObservationIgnored let line: PhoneLine

    private(set) var phase = Phase.starting
    private(set) var caption: Caption?
    /// When listening began, which is when the timer starts.
    private(set) var startedAt: Date?
    /// The latest microphone levels, newest last.
    private(set) var levels: [Float] = []
    /// Commands spoken or typed and not yet started.
    private(set) var queuedCount = 0
    /// How many commands the call has numbered, which is the number of the last one. A
    /// listen is numbered when it is sent, so that its outcome is told from one sent
    /// before it whose words arrive later; a phone call's command when it is taken, and
    /// typed words when they are submitted.
    @ObservationIgnored private(set) var commandsTaken = 0
    /// The numbers of listens sent whose routes are still settling what they heard.
    private(set) var settling: Set<Int> = []
    /// Why the call ended, when it wasn't hung up.
    private(set) var endReason: String?
    /// Whether a route asked for is open, from its starting until it stops. Only a call
    /// that listens on request has these.
    private(set) var isHearing = false
    /// Whether the route asked for last can hear, and hasn't been told the command is
    /// over. Unlike `isHearing`, a route sent and still settling doesn't count.
    private(set) var isListeningAsAsked = false
    /// Whether the route asked for last is still open, starting or hearing, and not sent.
    /// When it goes false without being sent or let go of, that listen failed.
    private(set) var hasOpenListen = false

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
    /// The design's turn-taking for spoken commands, shared with its other calls. Without
    /// one, the call's commands take no turns but their own.
    @ObservationIgnored var gate: VoiceCommandGate?

    @ObservationIgnored private let listeningStyle: Listening
    @ObservationIgnored private let runner: any VoiceCommandRunner
    @ObservationIgnored private let vocabulary: @MainActor () -> [String]
    @ObservationIgnored private var queue: [(text: String, target: VoiceTarget?, number: Int)] = []
    /// The route asked for and not yet told the command is over.
    @ObservationIgnored private var open: Ear?
    /// A route made and prepared as the call started, never started, for the first listen.
    @ObservationIgnored private var spare: (any VoiceRoute)?
    /// Routes told the command is over, waiting for it to arrive.
    @ObservationIgnored private var finishing: [Ear] = []
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var running: Task<VoiceOutcome, Never>?
    @ObservationIgnored private var captionClearing: Task<Void, Never>?

    init(listening: Listening, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] }, line: PhoneLine = .shared) {
        listeningStyle = listening
        self.runner = runner
        self.vocabulary = vocabulary
        self.line = line
    }

    convenience init(route: any VoiceRoute, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] }, line: PhoneLine = .shared) {
        self.init(listening: .continuous(route), runner: runner, vocabulary: vocabulary, line: line)
    }

    private var listensOnRequest: Bool {
        if case .onRequest = listeningStyle { true } else { false }
    }

    // MARK: Starting and ending

    /// Starts listening. Returns once the route can hear, or has said why it can't.
    func start() async {
        guard phase == .starting, listening == nil else { return }
        guard case .continuous(let route) = listeningStyle else {
            // Nothing to hear until asked, but speech recognition can get ready all the
            // same, so that the first squeeze doesn't wait on it. That is the language and
            // the recogniser's model, never the microphone.
            // The route is kept for the first listen.
            if case .onRequest(let makeRoute) = listeningStyle {
                let route = makeRoute()
                spare = route
                Task { await route.prepare() }
            }
            // The model too. There is no microphone to wait on here, and warming up only
            // starts the model off, so it is awaited.
            await runner.warmUp()
            // Ended while the model got ready: it stays ended.
            guard phase == .starting else { return }
            VoiceLog.log.info("call: listening when asked")
            phase = .listening
            startedAt = .now
            return
        }
        if let other = line.call, other !== self { other.end() }
        line.call = self
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
        spare = nil
        finishing.removeAll()
        settling = []
        isHearing = false
        isListeningAsAsked = false
        hasOpenListen = false
        listening?.cancel()
        running?.cancel()
        worker?.cancel()
        captionClearing?.cancel()
        letGoOfFragment()
        queue.removeAll()
        queuedCount = 0
        // The worker stops without reporting the command under way, so it is over here.
        working = nil
        caption = nil
        if line.call === self { line.call = nil }
        onEnd?()
    }

    // MARK: Listening when asked

    /// One route asked for, and what its commands were spoken about.
    @MainActor
    private final class Ear {
        let route: any VoiceRoute
        let target: VoiceTarget?
        /// Whether its route has started, and so could have heard anything.
        var hasStarted = false
        /// Whether its route has reported any words.
        var heardWords = false
        /// The number its command has, given when it was sent: what a pencil bubble follows.
        var number: Int?
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

        /// An ear let go of without being closed, with the call it belonged to, still
        /// stops its route: otherwise the microphone stays counted as in use.
        isolated deinit {
            close()
        }
    }

    /// Starts listening for one command about `target`. Asked again before `send()`, the
    /// route listening now is let go and a fresh one takes its place. A command already
    /// sent still arrives, about what it was spoken about.
    func listen(for target: VoiceTarget?) async {
        guard case .onRequest(let makeRoute) = listeningStyle, phase == .listening || phase == .working else { return }
        if let open { close(open) }
        let ear = Ear(route: spare ?? makeRoute(), target: target)
        spare = nil
        open = ear
        // The waveform is this listen's alone.
        levels = []
        isListeningAsAsked = false
        hasOpenListen = true
        do {
            let events = try await ear.route.start(vocabulary: vocabulary())
            // Let go of, or the call ended, while the route was getting ready.
            guard open === ear, phase != .ended else {
                ear.route.stop()
                return
            }
            VoiceLog.log.info("call: listening, as asked")
            ear.hasStarted = true
            isHearing = true
            isListeningAsAsked = true
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
    ///
    /// Returns the number the command will have, which every line about it carries, or nil
    /// when nothing was listening.
    @discardableResult
    func send() -> Int? {
        guard let ear = open else { return nil }
        commandsTaken += 1
        let number = commandsTaken
        ear.number = number
        guard ear.hasStarted else {
            // Let go of before the microphone came on, so nothing was heard. Said, rather
            // than dropped in silence, or the person waits for a command that never comes.
            VoiceLog.log.info("call: sent before the route could hear")
            close(ear)
            show(.problem, Self.tooSoon, about: number)
            return number
        }
        open = nil
        isListeningAsAsked = false
        hasOpenListen = false
        finishing.append(ear)
        settling.insert(number)
        ear.route.finish()
        let wait = finishWait
        // The route ends every finish within its patience (one and a half seconds as it
        // ships), with a command, nothing heard, or why. Only a route that is stuck gets here.
        ear.deadline = Task { [weak self, weak ear] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, let ear else { return }
            VoiceLog.log.error("call: a sent route didn't finish in time")
            self.close(ear)
            // Words were heard and are now lost. Said, so that nobody waits on them.
            if ear.heardWords { self.show(.problem, Self.missedTheEnd, about: number) }
        }
        return number
    }

    /// Whether the command numbered `number` is still to come or under way: its route
    /// settling, or the command waiting its turn or being carried out. Once it isn't, all
    /// there is to show of it is its caption.
    func isUnderWay(_ number: Int) -> Bool {
        settling.contains(number) || working == number || queue.contains { $0.number == number }
    }

    /// How the command numbered `number` is getting on: its own line while the caption is
    /// about it, and otherwise only whether it is still to come or under way.
    func progress(of number: Int) -> Progress {
        // The queue isn't observed, its count is: read so that whatever follows this
        // hears a command leave the queue.
        _ = queuedCount
        if let caption, caption.command == number {
            switch caption.kind {
            case .hearing, .working: return .working(caption.text)
            case .done: return .done(caption.text)
            case .said: return .said(caption.text)
            case .problem: return .problem(caption.text)
            }
        }
        return isUnderWay(number) ? .working(nil) : .over
    }

    /// Stops listening without acting on anything heard.
    func cancelListening() {
        guard let ear = open else { return }
        close(ear)
        if caption?.kind == .hearing { caption = nil }
    }

    /// Stops every route it asked for, sent and settling ones too, and sends nothing more:
    /// the design is closing. Commands already taken still run.
    func stopAllListening() {
        for ear in [open].compactMap({ $0 }) + finishing { close(ear) }
        spare = nil
        if caption?.kind == .hearing { caption = nil }
    }

    private func close(_ ear: Ear) {
        ear.close()
        if open === ear {
            open = nil
            isListeningAsAsked = false
            hasOpenListen = false
        }
        finishing.removeAll { $0 === ear }
        if let number = ear.number { settling.remove(number) }
        isHearing = open != nil || !finishing.isEmpty
    }

    private func handle(_ event: VoiceRouteEvent, from ear: Ear) {
        // Something heard after the listening was let go of is not to be acted on.
        guard open === ear || finishing.contains(where: { $0 === ear }) else { return }
        // The waveform is for what is being listened to now, not a sent route settling.
        if case .level = event, open !== ear { return }
        if case .hearing(let words) = event {
            if !words.isEmpty { ear.heardWords = true }
            // A sent route revising its words while the next listen is open: those words
            // are the last command's, and shown now they would be taken for this one's.
            if let open, open !== ear { return }
        }
        if case .nothingHeard = event {
            // Told to finish, it had nothing. There is nothing to wait for, so the
            // microphone is let go of now.
            guard finishing.contains(where: { $0 === ear }) else { return }
            close(ear)
            if open == nil, caption?.kind == .hearing { caption = nil }
        } else if case .failed(let reason) = event {
            // As when it can't start: this listen is over, and the call stays up. A sent
            // listen's problem is about its command, and only that command's bubble shows it.
            close(ear)
            show(.problem, reason, about: ear.number)
        } else if case .command = event, finishing.contains(where: { $0 === ear }) {
            // Taken before the ear is closed, so the command is never neither settling
            // nor queued.
            handle(event, target: ear.target, number: ear.number)
            close(ear)
        } else {
            handle(event, target: ear.target, number: ear.number)
        }
    }

    // MARK: Hearing

    /// `number` is the command's, when its listen was numbered as it was sent.
    private func handle(_ event: VoiceRouteEvent, target: VoiceTarget? = nil, number: Int? = nil) {
        guard phase != .ended else { return }
        switch event {
        case .level(let level):
            // Made whole and set once, so that whatever draws the waveform hears of it once.
            var latest = levels
            latest.append(level)
            if latest.count > Self.levelCount { latest.removeFirst(latest.count - Self.levelCount) }
            levels = latest
        case .hearing(let words):
            if !words.isEmpty { show(.hearing, words) }
        case .command(let command):
            received(command, target: target, number: number)
        case .nothingHeard:
            break
        case .failed(let reason):
            end(because: reason)
        }
    }

    private func received(_ command: String, target: VoiceTarget?, number: Int? = nil) {
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
            take(command, target: target, number: number)
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

    private func take(_ command: String, target: VoiceTarget?, number: Int? = nil) {
        guard Self.isWorthAsking(command) else {
            VoiceLog.log.info("call: let go, it is no command")
            // The words were shown as they were heard, and aren't to be acted on.
            if caption?.kind == .hearing { caption = nil }
            return
        }
        enqueue(command, target: target, number: number)
    }

    /// Takes typed words as a command about `target`, to wait its turn behind any command
    /// waiting or under way. They are taken as they were typed: none of speech's filters
    /// apply, so "blue" is a command, and "stop" or "hang up" goes to the model like
    /// anything else, never stopping or ending anything here.
    ///
    /// Returns the command's number, which every line about it carries, or nil when there
    /// is nothing to take: blank text, or a call not up. A call still starting takes
    /// nothing, as its first command would set it working and the start would then stop
    /// short of listening.
    func submit(_ text: String, about target: VoiceTarget?) -> Int? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, phase == .listening || phase == .working else { return nil }
        VoiceLog.log.info("call: typed a command of \(command.count) characters: \(command, privacy: .private)")
        return enqueue(command, target: target, number: nil)
    }

    /// Puts a command at the back of the queue and sets the worker going. A sent listen's
    /// command has its number already; any other is numbered now. Returns its number.
    @discardableResult
    private func enqueue(_ command: String, target: VoiceTarget?, number: Int?) -> Int {
        let numbered: Int
        if let number {
            numbered = number
        } else {
            commandsTaken += 1
            numbered = commandsTaken
        }
        queue.append((command, target, numbered))
        queuedCount = queue.count
        startWorker()
        return numbered
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
            .filter { !$0.isEmpty && !["please", "ok", "okay", "thank", "thanks", "you", "cool"].contains($0) }
            .joined(separator: " ")
        switch words {
        case "stop", "cancel", "stop that", "cancel that", "stop it", "cancel it": return .stop
        case "hang up", "end call", "end the call", "goodbye", "bye", "bye bye": return .hangUp
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
        // Said to the iPad as it works, not to it: "cool, cool, cool" was taken for undo.
        "cool", "nice", "great", "awesome", "perfect", "good", "alright", "sure", "wow", "thanks", "thank",
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
                let (command, target, number) = self.queue.removeFirst()
                self.queuedCount = self.queue.count
                self.phase = .working
                self.working = number
                let gate = self.gate
                let waits = gate?.isBusy == true
                self.show(.working, waits ? Self.waitingItsTurn : "Thinking…", about: number)
                let runner = self.runner
                // Waiting its turn is part of the command, so that "stop" or hanging up
                // while it waits stops it there.
                let run = Task { [weak self] () -> VoiceOutcome in
                    if let gate {
                        guard await gate.enter() else { return VoiceOutcome(wasCancelled: true) }
                    }
                    defer { gate?.leave() }
                    guard let self, self.phase != .ended, !Task.isCancelled else { return VoiceOutcome(wasCancelled: true) }
                    if waits { self.show(.working, "Thinking…", about: number) }
                    self.onCommandStarts?(target)
                    return await runner.run(command, about: target)
                }
                self.running = run
                let outcome = await run.value
                self.running = nil
                guard self.phase != .ended else { break }
                self.show(outcome, about: number)
                self.working = nil
                // Stopped or gone wrong, the model starts afresh for the next command.
                // Warmed now, the next one doesn't wait on that.
                if outcome.wasCancelled || outcome.problem != nil {
                    Task { await runner.warmUp() }
                }
                // A pencil call stays up for the next squeeze, with whatever else was
                // asked of it, as for a spoken "hang up": only a phone call is hung up.
                if outcome.endsCall, !self.listensOnRequest {
                    self.end()
                    break
                }
            }
            guard let self else { return }
            self.worker = nil
            if self.phase == .working { self.phase = .listening }
        }
    }

    /// Said while a command waits for another call's to finish.
    static let waitingItsTurn = "Waiting for the last command…"

    /// The number of the command being carried out, for its captions. Observed, so that a
    /// bubble following a command hears when it is over.
    private(set) var working: Int?

    /// What the command under way is doing right now, such as "Restyling…".
    func showStep(_ text: String) {
        guard phase == .working else { return }
        show(.working, text, about: working)
    }

    private func show(_ outcome: VoiceOutcome, about command: Int) {
        VoiceLog.log.info("""
            call: command over. steps \(outcome.lines.count), stopped \(outcome.wasCancelled), \
            problem: \(outcome.problem ?? "none", privacy: .private), said: \(outcome.said, privacy: .private)
            """)
        if outcome.wasCancelled {
            show(.done, "Stopped", about: command)
        } else if let problem = outcome.problem {
            show(.problem, problem, about: command)
        } else if let line = outcome.lines.last {
            show(.done, line, about: command)
        } else if !outcome.said.isEmpty {
            // Nothing was done, so no tick, whatever the model says it did.
            show(.said, outcome.said, about: command)
        } else {
            caption = nil
        }
    }

    /// `command` is the number of the command the line is about, for a line that is.
    private func show(_ kind: Caption.Kind, _ text: String, about command: Int? = nil) {
        captionClearing?.cancel()
        let shown = Caption(kind: kind, text: text, command: command)
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
            guard !Task.isCancelled, let self, self.caption?.id == shown.id else { return }
            self.caption = nil
        }
    }
}

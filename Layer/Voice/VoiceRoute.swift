import Foundation

/// What a route hears, as a call needs to know it.
enum VoiceRouteEvent: Sendable, Equatable {
    /// How loud the microphone is, from 0 to 1, about twenty times a second.
    case level(Float)
    /// The words so far of the command being spoken.
    case hearing(String)
    /// A finished command: the speaker has paused.
    case command(String)
    /// Told to finish, the route heard nothing that makes a command. Nothing more is
    /// coming from this utterance, so there is nothing to wait for.
    case nothingHeard
    /// The route can't go on. The call ends, and says why.
    case failed(String)
}

/// A way of listening. Speech recognised on the iPad is one; audio streamed to a model
/// that listens for itself is another. Either way a call is handed the same events.
@MainActor
protocol VoiceRoute: AnyObject {
    /// Gets whatever the route needs ready ahead of time, without the microphone: the
    /// language to listen for and the recogniser's model. Starting does it too, if this
    /// hasn't, so it only saves the wait.
    func prepare() async
    /// Starts listening. `vocabulary` is words the speaker is likely to say that a
    /// recogniser might otherwise mishear: the names of screens, the words on elements.
    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent>
    /// Stops listening and lets go of the microphone. The stream then ends.
    func stop()
    /// Ends the command being spoken now, without waiting for a pause: what has been
    /// heard is settled and sent as one `.command`, or as `.nothingHeard` if no words were.
    /// The route keeps listening afterwards, until `stop()`. For routes that end a
    /// command only when told to; one that ends on a pause has no use for it.
    func finish()
}

extension VoiceRoute {
    func prepare() async {}
    func finish() {}
}

/// What carries a spoken command out.
@MainActor
protocol VoiceCommandRunner: AnyObject {
    /// Runs one command to its end. Cancelling the task that awaits it stops the command.
    func run(_ command: String) async -> VoiceOutcome
    /// Runs one command about what the pencil pointed at. What it was about goes with the
    /// command and no other, so that another command running meanwhile can't take it.
    func run(_ command: String, about target: VoiceTarget?) async -> VoiceOutcome
    /// Gets ready to be asked, so that the first command doesn't wait on it. Asked for
    /// as a call starts, and again after a command that left things to start afresh.
    func warmUp() async
}

extension VoiceCommandRunner {
    func warmUp() async {}

    func run(_ command: String, about target: VoiceTarget?) async -> VoiceOutcome {
        await run(command)
    }
}

/// Lets one spoken command at a time act on a design. The pencil's call and a phone call
/// each have their own model, and both change the same design: run together, one's undo
/// step closed in the middle of the other's, and one took the other's selection. A
/// command waits here for its turn, in the order the commands came, and is never cut short
/// by one that comes after it.
@MainActor
final class VoiceCommandGate {
    private(set) var isBusy = false
    private var waiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []

    /// Waits for this command's turn. False if the command was stopped while it waited,
    /// in which case it has no turn to give back.
    func enter() async -> Bool {
        guard isBusy else {
            isBusy = true
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { turn in
                if Task.isCancelled {
                    turn.resume(returning: false)
                } else {
                    waiting.append((id, turn))
                }
            }
        } onCancel: {
            Task { @MainActor in self.giveUp(id) }
        }
    }

    /// The command is over: the next one waiting goes.
    func leave() {
        guard !waiting.isEmpty else {
            isBusy = false
            return
        }
        waiting.removeFirst().turn.resume(returning: true)
    }

    private func giveUp(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).turn.resume(returning: false)
    }
}

/// How a command went, for the call to show.
struct VoiceOutcome: Equatable, Sendable {
    /// What each step did, in order, one short line each.
    var lines: [String] = []
    /// What the model said in closing. Shown only when nothing was done.
    var said = ""
    /// What went wrong, in plain words.
    var problem: String?
    /// Whether the command was stopped before it finished.
    var wasCancelled = false
    /// Whether the command was to hang up.
    var endsCall = false
}

/// Makes commands out of what a speech recogniser reports. A recogniser hands over words
/// a phrase at a time, first as a guess that it keeps revising and then settled; where
/// one command ends and the next begins is for the listener to decide.
///
/// A command ends when the speaker stops, and that is heard in the sound, not in the
/// words: a recogniser delivers its words in bursts about a second apart, so a second
/// without new words can fall in the middle of a sentence. When the room has gone quiet
/// the recogniser is asked to settle whatever it is still holding, and what it has heard
/// by then is the command. Where the sound can't say (a room that is never quiet, or
/// speech too soft to tell from it) the words going stale ends the command instead.
///
/// It keeps no clock of its own: it is told the time with everything it hears and each
/// time it is asked what to do next.
struct UtteranceAssembler {
    enum Step: Equatable {
        /// Nothing to do yet.
        case wait
        /// The speaker has stopped. The recogniser should be asked to settle what it has
        /// heard, and `settled(at:)` called when it has; the command follows.
        case settle
        /// A finished command.
        case command(String)
        /// Told to finish, and nothing was said: there is no command coming.
        case nothingHeard
    }

    private let pause: Duration
    private let staleness: Duration
    private let patience: Duration
    private let settling: Duration
    private let loudness: Float
    /// Whether a pause in the speech can end a command. Where it can't, only `finishNow`
    /// does: a speaker holding a button down may pause as long as they like.
    private let endsOnPause: Bool

    /// Phrases the recogniser has settled since the last command.
    private var settledPhrases: [String] = []
    /// The phrase it is still revising.
    private var unsettled = ""
    /// When the words last changed.
    private var lastHeard: ContinuousClock.Instant?
    /// When the room was last loud enough to be someone speaking.
    private var lastLoud: ContinuousClock.Instant?
    /// Whether anything that loud has been heard since the last command.
    private var hasSpoken = false
    private var askedToSettle: ContinuousClock.Instant?
    private var settledAt: ContinuousClock.Instant?
    /// Whether it was the words going stale that ended the command, in a room that
    /// hadn't gone quiet. Loudness says nothing in such a room.
    private var endedOnStaleWords = false
    /// Words taken as a command before they were settled, so that they aren't taken for
    /// a second command if the recogniser settles them late.
    private var takenUnsettled: String?
    /// Whether the command was ended by being told to, not by a pause.
    private var isFinishing = false

    /// - Parameters:
    ///   - pause: How long the room is quiet before the speaker is taken to have stopped.
    ///     Long enough for a thought between words: at 0.8 s and again at 1.2 s, people
    ///     speaking to an iPad had their sentences cut in two.
    ///   - staleness: How long the words go unchanged before a command is taken as
    ///     finished, where the sound can't say. Longer than a recogniser's bursts are apart.
    ///   - patience: How long the recogniser is given to settle once asked.
    ///   - settling: How long its last phrases are given to arrive once it has settled.
    ///   - loudness: The level, from 0 to 1, at and above which sound counts as speech.
    ///   - endsOnPause: Whether a command ends when the speaker pauses. When not, only
    ///     `finishNow(at:)` ends one.
    init(
        endsOnPause: Bool = true,
        pause: Duration = .milliseconds(1800), staleness: Duration = .milliseconds(2500), patience: Duration = .milliseconds(1500),
        settling: Duration = .milliseconds(250), loudness: Float = 0.2
    ) {
        self.endsOnPause = endsOnPause
        self.pause = pause
        self.staleness = staleness
        self.patience = patience
        self.settling = settling
        self.loudness = loudness
    }

    /// The words of the command being spoken, as far as they have been heard.
    var hearing: String {
        (settledPhrases + (unsettled.isEmpty ? [] : [unsettled])).joined(separator: " ")
    }

    /// Takes in how loud the room is, from 0 to 1, `now` being when the sound was made.
    /// Sound can arrive a little late, and out of turn.
    mutating func sound(level: Float, at now: ContinuousClock.Instant) {
        guard level >= loudness else { return }
        if lastLoud.map({ now > $0 }) != false { lastLoud = now }
        hasSpoken = true
        // Speaking again: the command isn't over after all. Unless the room was never
        // quiet to begin with: then this is the room, not the speaker, and the command
        // that ended on its words going stale stays ended. Otherwise it would be called
        // back ten times a second and never taken. Sound made before the recogniser was
        // asked to settle is the end of what was said, not more of it.
        guard !endedOnStaleWords, !isFinishing else { return }
        if let askedToSettle, now < askedToSettle { return }
        askedToSettle = nil
        settledAt = nil
    }

    /// Takes in a phrase from the recogniser: `isFinal` once it is settled, and before
    /// that as many revisions of it as the recogniser cares to make.
    mutating func heard(_ text: String, isFinal: Bool, at now: ContinuousClock.Instant) {
        // The quiet between commands can come out as punctuation: a phrase of nothing
        // else, or a few marks ahead of the first word. Neither is anything said.
        let words = String(text.drop { $0.isPunctuation || $0.isWhitespace }).trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            unsettled = ""
            if let taken = takenUnsettled {
                takenUnsettled = nil
                if Self.areTheSame(taken, words) { return }
            }
            guard !words.isEmpty else { return }
            settledPhrases.append(words)
        } else {
            // New words while settling are the recogniser catching up with what was
            // said, not the speaker going on: that would be heard in the sound.
            guard words != unsettled else { return }
            unsettled = words
        }
        lastHeard = now
    }

    /// The recogniser has settled what it had, as `Step.settle` asked.
    mutating func settled(at now: ContinuousClock.Instant) {
        guard askedToSettle != nil else { return }
        settledAt = now
    }

    /// The command is over, whatever the room sounds like: the speaker said so. The next
    /// `next(at:)` goes down the same path a pause does, so the recogniser is asked to
    /// settle, with the same patience if it never does. That happens even when nothing
    /// seems to have been said: soft speech never sounds loud, and the recogniser's first
    /// words can be a second behind the voice, so it may still hold the command. If it
    /// doesn't, `next` says `.nothingHeard`, so that nobody waits for one.
    ///
    /// Asked while a pause is already settling, the same settle carries on: there is
    /// never a second one, so never a second command. It still counts as finished, so
    /// that a settle ending with nothing says so.
    mutating func finishNow(at now: ContinuousClock.Instant) {
        isFinishing = true
    }

    /// What to do now. Asked often, about ten times a second.
    mutating func next(at now: ContinuousClock.Instant) -> Step {
        let hasWords = !settledPhrases.isEmpty || !unsettled.isEmpty
        guard hasWords || hasSpoken || isFinishing else { return .wait }

        if let askedToSettle {
            if let settledAt {
                // A moment after it settled, and after the last words it brought out. Words
                // that keep coming, as speech after the release does, wait no longer than
                // the patience: they would otherwise grow the command for as long as they came.
                let isSettled = now - settledAt >= settling && lastHeard.map({ now - $0 >= settling }) != false
                guard isSettled || now - askedToSettle >= patience else { return .wait }
                if !isSettled, !unsettled.isEmpty { takenUnsettled = unsettled }
                return take()
            }
            guard now - askedToSettle >= patience else { return .wait }
            // It never settled. What it had is taken as it is.
            if !unsettled.isEmpty { takenUnsettled = unsettled }
            return take()
        }

        let isQuiet = endsOnPause && hasSpoken && lastLoud.map { now - $0 >= pause } == true
        let isStale = endsOnPause && hasWords && lastHeard.map { now - $0 >= staleness } == true
        guard isQuiet || isStale || isFinishing else { return .wait }
        askedToSettle = now
        endedOnStaleWords = !isQuiet && !isFinishing
        return .settle
    }

    /// Takes what has been heard as a command and starts afresh. A noise that turned out
    /// to have no words in it is just forgotten, unless the speaker said they were done:
    /// then they are told nothing was heard.
    private mutating func take() -> Step {
        let command = hearing
        let wasFinishing = isFinishing
        settledPhrases = []
        unsettled = ""
        lastHeard = nil
        hasSpoken = false
        askedToSettle = nil
        settledAt = nil
        endedOnStaleWords = false
        isFinishing = false
        if command.isEmpty { return wasFinishing ? .nothingHeard : .wait }
        return .command(command)
    }

    /// Whether two phrases are one, give or take the capitals, the punctuation and a last
    /// word that settling adds.
    private static func areTheSame(_ one: String, _ other: String) -> Bool {
        func plain(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let (a, b) = (plain(one), plain(other))
        return !a.isEmpty && !b.isEmpty && (a.hasPrefix(b) || b.hasPrefix(a))
    }
}

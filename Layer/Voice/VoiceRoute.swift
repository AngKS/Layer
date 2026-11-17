import Foundation

/// What a route hears, as a call needs to know it.
enum VoiceRouteEvent: Sendable, Equatable {
    /// How loud the microphone is, from 0 to 1, about twenty times a second.
    case level(Float)
    /// The words so far of the command being spoken.
    case hearing(String)
    /// A finished command: the speaker has paused.
    case command(String)
    /// The route can't go on. The call ends, and says why.
    case failed(String)
}

/// A way of listening. Speech recognised on the iPad is one; audio streamed to a model
/// that listens for itself is another. Either way a call is handed the same events.
@MainActor
protocol VoiceRoute: AnyObject {
    /// Starts listening. `vocabulary` is words the speaker is likely to say that a
    /// recogniser might otherwise mishear: the names of screens, the words on elements.
    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent>
    /// Stops listening and lets go of the microphone. The stream then ends.
    func stop()
}

/// What carries a spoken command out.
@MainActor
protocol VoiceCommandRunner: AnyObject {
    /// Runs one command to its end. Cancelling the task that awaits it stops the command.
    func run(_ command: String) async -> VoiceOutcome
    /// Gets ready to be asked, so that the first command doesn't wait on it. Asked for
    /// as a call starts, and again after a command that left things to start afresh.
    func warmUp() async
}

extension VoiceCommandRunner {
    func warmUp() async {}
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
    }

    private let pause: Duration
    private let staleness: Duration
    private let patience: Duration
    private let settling: Duration
    private let loudness: Float

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

    /// - Parameters:
    ///   - pause: How long the room is quiet before the speaker is taken to have stopped.
    ///     Long enough for a thought between words: at 0.8 s, people speaking to an iPad
    ///     had their sentences cut in two.
    ///   - staleness: How long the words go unchanged before a command is taken as
    ///     finished, where the sound can't say. Longer than a recogniser's bursts are apart.
    ///   - patience: How long the recogniser is given to settle once asked.
    ///   - settling: How long its last phrases are given to arrive once it has settled.
    ///   - loudness: The level, from 0 to 1, at and above which sound counts as speech.
    init(
        pause: Duration = .milliseconds(1200), staleness: Duration = .seconds(2), patience: Duration = .milliseconds(1500),
        settling: Duration = .milliseconds(250), loudness: Float = 0.2
    ) {
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

    /// Takes in how loud the room is, from 0 to 1.
    mutating func sound(level: Float, at now: ContinuousClock.Instant) {
        guard level >= loudness else { return }
        lastLoud = now
        hasSpoken = true
        // Speaking again: the command isn't over after all. Unless the room was never
        // quiet to begin with: then this is the room, not the speaker, and the command
        // that ended on its words going stale stays ended. Otherwise it would be called
        // back ten times a second and never taken.
        guard !endedOnStaleWords else { return }
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

    /// What to do now. Asked often, about ten times a second.
    mutating func next(at now: ContinuousClock.Instant) -> Step {
        let hasWords = !settledPhrases.isEmpty || !unsettled.isEmpty
        guard hasWords || hasSpoken else { return .wait }

        if let askedToSettle {
            if let settledAt {
                // A moment after it settled, and after the last words it brought out.
                guard now - settledAt >= settling, lastHeard.map({ now - $0 >= settling }) != false else { return .wait }
                return take()
            }
            guard now - askedToSettle >= patience else { return .wait }
            // It never settled. What it had is taken as it is.
            if !unsettled.isEmpty { takenUnsettled = unsettled }
            return take()
        }

        let isQuiet = hasSpoken && lastLoud.map { now - $0 >= pause } == true
        let isStale = hasWords && lastHeard.map { now - $0 >= staleness } == true
        guard isQuiet || isStale else { return .wait }
        askedToSettle = now
        endedOnStaleWords = !isQuiet
        return .settle
    }

    /// Takes what has been heard as a command and starts afresh. A noise that turned out
    /// to have no words in it is just forgotten.
    private mutating func take() -> Step {
        let command = hearing
        settledPhrases = []
        unsettled = ""
        lastHeard = nil
        hasSpoken = false
        askedToSettle = nil
        settledAt = nil
        endedOnStaleWords = false
        return command.isEmpty ? .wait : .command(command)
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

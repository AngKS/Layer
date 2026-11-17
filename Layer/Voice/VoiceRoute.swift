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
/// one command ends and the next begins is for the listener to decide. Here a command
/// ends when the speaker has paused.
///
/// It keeps no clock of its own: it is told the time with everything it hears and each
/// time it is asked what to do next, so the pause it waits for is the caller's to measure.
struct UtteranceAssembler {
    enum Step: Equatable {
        /// Nothing to do yet.
        case wait
        /// The speaker has paused with words the recogniser hasn't settled. It should be
        /// asked to settle what it has heard; the command follows when it does.
        case settle
        /// A finished command.
        case command(String)
    }

    private let pause: Duration
    private let patience: Duration
    /// Phrases the recogniser has settled since the last command.
    private var settled: [String] = []
    /// The phrase it is still revising.
    private var unsettled = ""
    private var lastHeard: ContinuousClock.Instant?
    private var askedToSettle: ContinuousClock.Instant?
    /// Words taken as a command before they were settled, so that they aren't taken for
    /// a second command when the recogniser gets round to settling them.
    private var takenUnsettled: String?

    /// `pause` is how long the speaker is quiet before a command is taken as finished.
    /// `patience` is how long the recogniser is given to settle its last words once asked.
    init(pause: Duration = .milliseconds(900), patience: Duration = .milliseconds(1500)) {
        self.pause = pause
        self.patience = patience
    }

    /// The words of the command being spoken, as far as they have been heard.
    var hearing: String {
        (settled + (unsettled.isEmpty ? [] : [unsettled])).joined(separator: " ")
    }

    /// Takes in a phrase from the recogniser: `isFinal` once it is settled, and before
    /// that as many revisions of it as the recogniser cares to make.
    mutating func heard(_ text: String, isFinal: Bool, at now: ContinuousClock.Instant) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal {
            unsettled = ""
            if let taken = takenUnsettled {
                takenUnsettled = nil
                if Self.areTheSame(taken, words) { return }
            }
            guard !words.isEmpty else { return }
            settled.append(words)
        } else {
            guard words != unsettled else { return }
            unsettled = words
            // Speaking again: the command isn't over after all.
            if !words.isEmpty { askedToSettle = nil }
        }
        lastHeard = now
    }

    /// What to do now. Asked often, a few times a second.
    mutating func next(at now: ContinuousClock.Instant) -> Step {
        guard let lastHeard, !settled.isEmpty || !unsettled.isEmpty else { return .wait }
        if unsettled.isEmpty {
            // Settled because it was asked to be, the pause has already been taken.
            guard askedToSettle != nil || now - lastHeard >= pause else { return .wait }
            return take()
        }
        if let askedToSettle {
            guard now - askedToSettle >= patience else { return .wait }
            takenUnsettled = unsettled
            return take()
        }
        guard now - lastHeard >= pause else { return .wait }
        askedToSettle = now
        return .settle
    }

    private mutating func take() -> Step {
        let command = hearing
        settled = []
        unsettled = ""
        lastHeard = nil
        askedToSettle = nil
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

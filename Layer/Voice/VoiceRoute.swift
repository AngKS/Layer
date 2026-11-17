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

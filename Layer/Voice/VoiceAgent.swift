import Foundation
@_weakLinked import FoundationModels

/// Carries spoken commands out with the design's model. There is one for a call: it keeps
/// the call's session, so that a command can lean on the ones before it ("now make it
/// green"), and the call's handles, so that E2 goes on meaning the same element.
///
/// Each command is put to the model with the canvas as it is. The model answers by
/// calling tools, which change the design; the canvas is looked at again after each, and
/// the whole command is one undo step however many tools it took.
@MainActor
final class VoiceAgent: VoiceCommandRunner {
    private weak var model: AppModel?
    private let handles = VoiceHandles()
    private let toolbox: VoiceToolbox
    private let testModel: (any LanguageModel)?
    private var session: LanguageModelSession?
    /// Set by a test, to say how the canvas is told between steps whatever the model.
    private let looksAgain: Bool?

    /// Whether a model is told about the canvas again after each step of a command.
    ///
    /// A hosted model is: it may go on to act on what a step made. The on-device model is
    /// told once for the command. It asks for all its tools in one answer and then only
    /// says it is done, and to say so it has to read again whatever it was told had
    /// changed: measured on an iPad, three seconds after every command, against well
    /// under one where the canvas was the same. A step that makes something still hands
    /// back its handle, which is what a further step needs.
    static func looksAgainBetweenSteps(with choice: ModelChoice) -> Bool {
        choice.hostedProvider != nil
    }

    /// Gets the model ready to be asked: the conversation is made, told the rules, the
    /// tools and the canvas, and the model is given them to read ahead of the first
    /// command. On an iPad that reading was fourteen seconds of the first command's wait.
    func warmUp() async {
        guard session == nil, let model else { return }
        let session = makeSession()
        self.session = session
        session.properties.voiceModel = model.modelChoice
        lookAtTheCanvas()
        VoiceLog.log.info("agent: warming \(String(describing: model.modelChoice), privacy: .public)")
        session.prewarm()
    }

    /// Called with what the command under way is doing now, such as "Restyling…".
    var onStep: ((String) -> Void)?

    /// `testModel` stands in for the design's own model, for tests and the simulator.
    init(model: AppModel, testModel: (any LanguageModel)? = nil, looksAgainBetweenSteps: Bool? = nil) {
        self.model = model
        self.testModel = testModel
        self.looksAgain = looksAgainBetweenSteps
        toolbox = VoiceToolbox(model: model, handles: handles)
    }

    func run(_ command: String) async -> VoiceOutcome {
        guard let model else { return VoiceOutcome(problem: "The design has closed.") }
        toolbox.reset()
        let session = session ?? makeSession()
        self.session = session
        session.properties.voiceModel = model.modelChoice
        lookAtTheCanvas()

        // Everything the command changes is one step to undo, whatever becomes of it.
        model.store.beginHeldEdit()
        defer { model.store.endHeldEdit() }

        var outcome = VoiceOutcome()
        VoiceLog.log.info("agent: asking \(String(describing: model.modelChoice), privacy: .public)")
        let began = ContinuousClock.now
        do {
            let response = try await session.respond(to: command)
            // Handles are between the app and the model; the person is told in words.
            outcome.said = toolbox.inWords(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            // A conversation cut off part way, with a tool asked for and never answered,
            // isn't one to build the next command on. The next starts afresh.
            self.session = nil
            // The pill gets plain words; the log gets what the error really was.
            VoiceLog.log.error("agent: \(String(reflecting: error), privacy: .public)")
            if Task.isCancelled || Self.isCancellation(error) {
                outcome.wasCancelled = true
            } else {
                outcome.problem = Self.problem(from: error)
            }
        }
        outcome.lines = toolbox.lines
        outcome.endsCall = toolbox.endsCall
        // The last thing tried couldn't be done: that is what the person needs to know,
        // whatever the model went on to say.
        if outcome.problem == nil, !outcome.wasCancelled, toolbox.lastFailed, let failure = toolbox.failures.last {
            outcome.problem = failure
        }
        VoiceLog.log.info("agent: answered in \((ContinuousClock.now - began).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1))), privacy: .public)")
        return outcome
    }

    private func makeSession() -> LanguageModelSession {
        let hooks = VoiceHooks(
            willRun: { [weak self] tool in await self?.stepStarted(with: tool) },
            didRun: { [weak self] in await self?.stepFinished() },
            mayRun: { !Task.isCancelled }
        )
        return LanguageModelSession(profile: VoiceProfile(actor: toolbox, hooks: hooks, testModel: testModel))
    }

    private func stepStarted(with tool: String) {
        VoiceLog.log.info("agent: tool \(tool, privacy: .public)")
        onStep?(VoiceTools.step(for: tool))
    }

    private func stepFinished() {
        guard let model else { return }
        // A test's stand-in is told again, as a hosted model is, unless the test says not.
        if looksAgain ?? (testModel != nil || Self.looksAgainBetweenSteps(with: model.modelChoice)) {
            lookAtTheCanvas()
        }
    }

    /// Takes the canvas as it is now for the model's next look at it.
    private func lookAtTheCanvas() {
        guard let model, let session else { return }
        session.properties.canvasPicture = CanvasPicture.capture(from: model, handles: handles)
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let toolError = error as? LanguageModelSession.ToolCallError { return isCancellation(toolError.underlyingError) }
        return false
    }

    /// Why a command couldn't be carried out, in words for the pill.
    private static func problem(from error: any Error) -> String {
        if let toolError = error as? LanguageModelSession.ToolCallError { return problem(from: toolError.underlyingError) }
        if let said = (error as? any LocalizedError)?.errorDescription, !said.isEmpty { return said }
        return "That couldn't be carried out. Try saying it another way."
    }
}

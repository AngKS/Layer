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
    enum Correction: Equatable {
        case undoOnly
        case undoThenAsk
    }

    /// Whether a command says the last one was wrong: "No, …", "Not the …", "That's
    /// wrong". `undoOnly` when it says nothing more; `undoThenAsk` when it goes on to say
    /// what was meant.
    static func correction(in command: String) -> Correction? {
        let words = command.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let first = words.first else { return nil }
        let opens = ["no", "nope", "nah", "not", "wrong", "oops"].contains(first)
            || (words.count > 2 && words[0] == "that" && ["s", "is", "was"].contains(words[1]) && words[2] == "wrong")
        guard opens else { return nil }
        let saysNoMore: Set<String> = [
            "no", "nope", "nah", "not", "wrong", "oops", "undo", "revert", "that", "s", "is", "was", "it", "one", "go", "back",
            "sorry", "wait", "the", "please", "change",
        ]
        return words.allSatisfy(saysNoMore.contains) ? .undoOnly : .undoThenAsk
    }

    /// The history mark the last command left, when it changed the design: its step is on
    /// top of the history for as long as the mark hasn't moved, and only then does a
    /// correction undo it. A drag by hand since, or another call's command, moves it.
    private var lastCommandStep: Int?

    /// How many commands a session takes before the next starts a fresh one. The model is
    /// sent only the last two anyway (`VoiceProfile`), but the session keeps every word,
    /// tool call and answer, and the pencil's lives as long as the design is open.
    var commandsPerSession = 40
    private var commandsInSession = 0

    func warmUp() async {
        guard session == nil, let model, !model.isClosed else { return }
        let session = makeSession()
        self.session = session
        commandsInSession = 0
        session.properties.voiceModel = model.modelChoice
        lookAtTheCanvas()
        VoiceLog.log.info("agent: warming \(String(describing: model.modelChoice), privacy: .public)")
        session.prewarm()
    }

    /// Called with what the command under way is doing now, such as "Restyling…".
    var onStep: ((String) -> Void)?

    /// Whether the model may end the call. The pencil's call has no voice mode to end, so
    /// it isn't handed the tool: given it, a model said "Hanging up." and nothing hung up.
    let canEndCall: Bool

    /// `testModel` stands in for the design's own model, for tests and the simulator.
    init(model: AppModel, testModel: (any LanguageModel)? = nil, looksAgainBetweenSteps: Bool? = nil, canEndCall: Bool = true) {
        self.model = model
        self.testModel = testModel
        self.looksAgain = looksAgainBetweenSteps
        self.canEndCall = canEndCall
        toolbox = VoiceToolbox(model: model, handles: handles)
    }

    func run(_ command: String) async -> VoiceOutcome {
        await run(command, about: nil)
    }

    /// What the model is told with a command the pencil pointed at empty canvas for.
    static let canvasHint = "(The person pointed at empty canvas: a description of a screen means a new screen there.)"

    /// What the model is told with a command the pencil pointed at a thing for.
    static func thingHint(_ pointed: String) -> String {
        "(The person is pointing at \(pointed). \"This\", \"it\", \"that\" and a change that names nothing mean what is pointed at, and nothing else.)"
    }

    func run(_ command: String, about target: VoiceTarget?) async -> VoiceOutcome {
        guard let model, !model.isClosed else { return VoiceOutcome(problem: AppModel.closedProblem) }
        toolbox.reset()
        // Where the pencil pointed goes with this command and no other: a new screen goes
        // there, and the model is told so.
        var hint: String?
        if case .canvas(let point) = target {
            hint = Self.canvasHint
            toolbox.newScreenAnchor = point
        }
        if session == nil { commandsInSession = 0 }
        commandsInSession += 1
        let session = session ?? makeSession()
        self.session = session
        session.properties.voiceModel = model.modelChoice
        lookAtTheCanvas()
        // Pointed at a thing: said outright, as a model left to find "[selected]" in the
        // canvas restyled the avatar for "the phone" and deleted what "it" was before (iPad).
        if case .thing = target, let pointed = session.properties.canvasPicture.selectionInWords {
            hint = Self.thingHint(pointed)
        }

        // Everything the command changes is one step to undo, whatever becomes of it.
        model.store.beginHeldEdit()
        correctedTo = nil
        let before = model.store.content
        let outcome = await carryOut(command, hint: hint, in: session, on: model)
        model.store.endHeldEdit()
        // A correction's own undo isn't a change of the command's to correct again.
        lastCommandStep = model.store.content != (correctedTo ?? before) ? model.store.historyMark : nil
        if commandsInSession >= commandsPerSession {
            // Made ready now, so that the next command doesn't wait on a cold session.
            VoiceLog.log.info("agent: a fresh session after \(self.commandsInSession) commands")
            self.session = nil
            Task { [weak self] in await self?.warmUp() }
        }
        return outcome
    }

    /// The design as a correction's undo left it, for the command under way.
    private var correctedTo: DesignContent?

    private func carryOut(_ command: String, hint: String?, in session: LanguageModelSession, on model: AppModel) async -> VoiceOutcome {
        toolbox.spokenCommand = command
        var outcome = VoiceOutcome()
        // "Not the check marks": the last change is undone before what was meant is done.
        // Left to the model, it did what was meant and left the mistake.
        var prompt = command
        if let correction = Self.correction(in: command), let step = lastCommandStep, model.store.historyMark == step {
            VoiceLog.log.info("agent: a correction, so the last change is undone first")
            _ = toolbox.undo()
            lastCommandStep = nil
            correctedTo = model.store.content
            if correction == .undoOnly {
                outcome.lines = toolbox.lines
                return outcome
            }
            prompt = "(The last change has been undone.) " + command
            lookAtTheCanvas()
        }
        if let hint {
            prompt = hint + " " + prompt
            VoiceLog.log.info("agent: told \(hint, privacy: .public)")
        }
        VoiceLog.log.info("agent: asking \(String(describing: model.modelChoice), privacy: .public)")
        let began = ContinuousClock.now
        do {
            let response = try await session.respond(to: prompt)
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
            // Nothing more is done to a design once it has closed.
            mayRun: { @MainActor [weak model] in !Task.isCancelled && model?.isClosed == false }
        )
        let turns = VoiceToolTurns()
        let session = LanguageModelSession(profile: VoiceProfile(actor: toolbox, hooks: hooks, turns: turns, testModel: testModel, canEndCall: canEndCall))
        turns.session = session
        return session
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

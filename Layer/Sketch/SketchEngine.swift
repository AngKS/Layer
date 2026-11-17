import Foundation
import Observation
import os

/// Reads sketches. The built-in rules settle every sketch whose shape is clear. A sketch
/// that is a close call goes to the chosen provider, which decides from the screen's
/// context, with the rules' answer standing whenever the provider can't give one.
/// A reading always comes back; this never throws.
///
/// A provider that is listed as available is not necessarily answering, so the engine
/// asks it one small question up front, and gives it a rest when it fails repeatedly.
/// Either way no sketch is kept waiting long on a provider that isn't there.
@MainActor @Observable
final class SketchEngine {
    /// How long a sketch waits for the provider before the rules' answer is used. The
    /// on-device model answers in well under a second.
    static let readLimit: Duration = .seconds(4)
    /// Failed attempts in a row before the provider is left alone, and for how long.
    static let failuresBeforeResting = 2
    static let rest: Duration = .seconds(120)

    let provider: SketchProvider
    private(set) var readiness: ProviderReadiness
    /// True when the provider's most recent attempt failed or gave an impossible answer.
    private(set) var lastAttemptFailed = false
    /// True while the provider is being left alone after failing repeatedly.
    private(set) var isResting = false
    /// The on-device log entry the most recent `read(_:)` wrote, if it wrote one — nil for
    /// an asked reading, or one off the open canvas. Whoever creates the element this
    /// reading became should call `SketchReadingLog.shared.link` with it, so a deletion
    /// soon after can be recognised as a correction. Stage 0 of
    /// `reports/Fast and slow sketch recognition.md`.
    @ObservationIgnored private(set) var lastLogID: UUID?
    /// A word `HandwritingRecognizer` read out of the most recent `read(_:)`'s strokes, if
    /// it tried and found one. Whoever creates the element this reading became can use it
    /// as the element's text, the way a prompt's own wording already becomes a label in
    /// `readAsked`. Stage 2.
    @ObservationIgnored private(set) var lastRecognizedText: String?

    @ObservationIgnored private let rules = RuleInterpreter()
    @ObservationIgnored private var hasWarmedUp = false
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private var restingUntil: ContinuousClock.Instant?
    @ObservationIgnored private var check: Task<Void, Never>?
    /// When each provider last answered, so that it isn't asked to prove itself for every design opened.
    @ObservationIgnored private static var lastAnswered: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "kahshin.Layer", category: "sketch")

    init(provider: SketchProvider = .appleIntelligence) {
        self.provider = provider
        readiness = provider.readiness()
    }

    /// One line for the UI saying what is reading sketches right now.
    var statusLine: String {
        switch readiness {
        case .unavailable(let reason): "\(reason) Using built-in shape rules."
        case .ready where isResting: "\(provider.name) isn't answering. Using built-in shape rules for now."
        case .ready where lastAttemptFailed: "\(provider.name) didn't answer. Using built-in shape rules."
        case .ready: "\(provider.name) decides the close calls"
        }
    }

    /// Whether the provider is Apple Intelligence and all it needs is switching on.
    private(set) var canBeTurnedOnInSettings = false

    /// Re-checks whether the provider can run, loads its model if so, and finds out
    /// whether it answers. Called when a design opens and when the app comes back to
    /// the screen, since Apple Intelligence can be switched on, or finish downloading,
    /// while the app is away.
    func prepare() {
        // Asking is not free (tens of milliseconds for Apple Intelligence), so it is asked
        // here, when the answer can have changed, rather than for every sketch.
        readiness = provider.readiness()
        canBeTurnedOnInSettings = provider.id == SketchProvider.appleIntelligence.id && readiness != .ready
            && AppleIntelligenceInterpreter.isTurnedOff
        guard readiness == .ready else { return }
        if provider.id == SketchProvider.appleIntelligence.id, !hasWarmedUp, !Self.isConserving {
            hasWarmedUp = true
            AppleIntelligenceInterpreter.warmUp()
        }
        checkThatProviderAnswers()
    }

    /// Asks the provider one small question, so that a provider that fails every request
    /// is found out here rather than by a sketch waiting on it.
    private func checkThatProviderAnswers() {
        if let last = Self.lastAnswered[provider.id], ContinuousClock.now - last < .seconds(300) { return }
        guard check == nil, !isStillResting() else { return }
        check = Task { [weak self] in
            guard let self else { return }
            let interpreter = provider.makeInterpreter(nil)
            let board = "The board has one screen. Screen 1, an iPhone screen, has from top to bottom: a title saying “Welcome”."
            // No longer than a sketch would wait: until this is known, each sketch
            // and each board name waits out its own limit on a provider that hangs.
            let answer = try? await withTimeout(.seconds(6)) { try await interpreter.suggestTitle(for: board) }
            if answer == nil { log.error("\(self.provider.id, privacy: .public) is available but did not answer its check") }
            record(answered: answer != nil, restsAtOnce: true)
            check = nil
        }
    }

    func read(_ requested: SketchRequest) async -> SketchReading {
        lastLogID = nil
        lastRecognizedText = nil
        if requested.isAsked { return await readAsked(requested) }
        let request: SketchRequest
        if Self.mightBeHandwriting(requested.observation.form) {
            var withText = requested
            withText.recognizedText = await HandwritingRecognizer.recognize(requested.strokes)
            lastRecognizedText = withText.recognizedText
            request = withText
        } else {
            request = requested
        }
        let fallback = rules.reading(for: request)
        let escalated = rules.isCloseCall(request)
        guard escalated else {
            lastLogID = await log(request, chosen: fallback, escalated: false, decidedBy: "rules")
            return fallback
        }

        guard readiness == .ready, !isStillResting(), !Self.isConserving else {
            lastLogID = await log(request, chosen: fallback, escalated: true, decidedBy: "rules")
            return fallback
        }

        let interpreter = provider.makeInterpreter(nil)
        let started = ContinuousClock.now
        do {
            let reading = try await withTimeout(Self.readLimit) { try await interpreter.read(request) }
            let elapsed = ContinuousClock.now - started
            log.info("\(self.provider.id, privacy: .public) read \(SketchPrompt.name(for: reading), privacy: .public) in \(String(describing: elapsed), privacy: .public)")
            let isPossible = request.candidates.contains(reading)
            record(answered: isPossible)
            let final = isPossible ? reading : fallback
            lastLogID = await log(request, chosen: final, escalated: true, decidedBy: isPossible ? provider.id : "rules")
            return final
        } catch {
            log.error("\(self.provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            record(answered: false)
            lastLogID = await log(request, chosen: fallback, escalated: true, decidedBy: "rules")
            return fallback
        }
    }

    /// Writes one reading to the on-device log (Stage 0), and returns its entry id so the
    /// element it becomes, if any, can be linked to it. Limited to on-screen readings: the
    /// scored table and the confusable pairs it's measured against both live there, and an
    /// open-canvas reading (screen, sticky note, text) never has more than one candidate to
    /// log.
    /// Whether this shape is even worth asking PencilKit's handwriting recognizer about.
    /// Most sketches are clean geometric shapes with an obvious answer; trying to recognise
    /// words out of every one of them would cost a model call nothing needs. A squiggle
    /// might be a word; an enclosure with something unclassified inside it (`.other`, never
    /// `.tick`/`.cross`/`.dot`) might have a word written inside it, such as a button's
    /// label. Shared with `SketchBenchmarkRunner`, so the benchmark exercises the same
    /// trigger `read(_:)` does rather than guessing at it separately.
    nonisolated static func mightBeHandwriting(_ form: SketchObservation.Form) -> Bool {
        switch form {
        case .wave, .scribble: true
        case .enclosure(_, .other): true
        default: false
        }
    }

    private func log(_ request: SketchRequest, chosen: SketchReading, escalated: Bool, decidedBy: String) async -> UUID? {
        guard case .onScreen(_, let existing, let size) = request.placement else { return nil }
        let scored = request.scoredReadings
        let existingKinds: [String] = existing.map { $0.kind.rawValue }
        let existingFrames: [[Double]] = existing.map { element -> [Double] in
            let frame = element.frame
            return [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
        }
        let strokePoints: [[[Double]]] = request.strokes.map { stroke -> [[Double]] in
            stroke.map { point -> [Double] in [Double(point.x), Double(point.y)] }
        }
        let candidateNames: [String] = scored.map { SketchPrompt.name(for: $0.reading) }
        let scoreValues: [Double] = scored.map(\.score)
        let chosenName = SketchPrompt.name(for: chosen)
        let screenSize = [Double(size.width), Double(size.height)]
        return await SketchReadingLog.shared.record(
            placementKind: "onScreen",
            existingKinds: existingKinds,
            existingFrames: existingFrames,
            screenSize: screenSize,
            strokes: strokePoints,
            candidates: candidateNames,
            scores: scoreValues,
            chosen: chosenName,
            escalated: escalated,
            decidedBy: decidedBy
        )
    }

    /// Reads a drawing someone asked to have read. What their prompt names outright is
    /// what it becomes. Otherwise the model chooses, told the prompt; failing that, the
    /// shape decides, and failing that the likeliest thing for where it was drawn.
    private func readAsked(_ request: SketchRequest) async -> SketchReading {
        let options = request.options
        if let prompt = request.prompt, let named = SketchPrompt.reading(namedIn: prompt, among: options) {
            return named
        }
        let shaped = rules.reading(for: request)
        let fallback = options.contains(shaped) ? shaped : options.first ?? .unknown
        guard readiness == .ready, !isStillResting(), !Self.isConserving else { return fallback }

        let interpreter = provider.makeInterpreter(nil)
        do {
            let reading = try await withTimeout(Self.readLimit) { try await interpreter.read(request) }
            let isPossible = options.contains(reading)
            record(answered: isPossible)
            return isPossible ? reading : fallback
        } catch {
            log.error("\(self.provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            record(answered: false)
            return fallback
        }
    }

    /// A name for a board from the design's own words, with no waiting.
    func fallbackTitle(for content: DesignContent) -> String {
        rules.title(for: content)
    }

    /// A name for a board, from the provider when it can give one and from the design's
    /// own words otherwise.
    func suggestTitle(for content: DesignContent) async -> String {
        let fallback = rules.title(for: content)
        guard readiness == .ready, !isStillResting(), !Self.isConserving else { return fallback }
        let interpreter = provider.makeInterpreter(nil)
        let board = SketchPrompt.describe(board: content)
        guard let suggestion = try? await withTimeout(.seconds(5), { try await interpreter.suggestTitle(for: board) }) else {
            record(answered: false)
            return fallback
        }
        record(answered: true)
        // Models sometimes add quotation marks, a full stop or a second line.
        let line = suggestion.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'.*#"))
        return Self.isUsableTitle(cleaned) ? cleaned : fallback
    }

    /// Whether a model's suggestion can name a board: short, and not a refusal or an
    /// apology, which a model gives as ordinary text rather than as an error.
    static func isUsableTitle(_ title: String) -> Bool {
        guard !title.isEmpty, title.count <= 48, title.split(separator: " ").count <= 6 else { return false }
        let lowered = title.lowercased()
        let refusals = ["sorry", "i can't", "i cannot", "i can’t", "i'm unable", "i’m unable", "unable to", "as an ai", "i apologize", "can't help", "can’t help", "not able to"]
        return !refusals.contains { lowered.contains($0) } && !title.hasSuffix("?")
    }

    /// Whether the iPad is hot or in Low Power Mode. The model is left alone then, and
    /// the built-in rules decide: they are instant and cost next to nothing.
    static var isConserving: Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }

    // MARK: How the provider is doing

    private func record(answered: Bool, restsAtOnce: Bool = false) {
        lastAttemptFailed = !answered
        if answered {
            failuresInARow = 0
            restingUntil = nil
            isResting = false
            Self.lastAnswered[provider.id] = .now
        } else {
            failuresInARow += 1
            Self.lastAnswered[provider.id] = nil
            if restsAtOnce || failuresInARow >= Self.failuresBeforeResting {
                restingUntil = .now + Self.rest
                isResting = true
            }
        }
    }

    /// Whether the provider is being left alone. A rest ends by itself.
    private func isStillResting() -> Bool {
        guard let until = restingUntil else { return false }
        if ContinuousClock.now < until { return true }
        restingUntil = nil
        isResting = false
        failuresInARow = 0
        return false
    }
}

/// Runs `work`, giving up with `CancellationError` if it takes longer than `limit`.
func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CancellationError() }
        return first
    }
}

import Foundation
@_weakLinked import FoundationModels

/// Writes a whole screen from a description, with the design's own model, and streams it:
/// the model writes the screen a line at a time, and each time a finished line adds to it the
/// screen so far is handed on as a keyed tree, so the canvas can show it growing while the
/// model is still writing. Every model writes an outline (`Outline`, read by `OutlineStream`):
/// the on-device model with the compact prompt, a hosted one with the full prompt (`hostedFormat`).
/// A screen asked for in A2UI 1.0, a message per line (`A2UIStream`), says at the end what of it
/// couldn't be brought in (`Update.leftOut`).
///
/// Every model goes through a Foundation Models `LanguageModelSession`: the on-device
/// Apple Intelligence model, or a hosted one (`HostedLanguageModel`).
enum ScreenGenerator {
    enum GenerationError: LocalizedError, Equatable {
        case nothingWritten

        var errorDescription: String? {
            switch self {
            case .nothingWritten: "The model didn't describe any elements. Try saying more about the screen."
            }
        }
    }

    /// What a model writes a screen in (`ScreenFormat`).
    typealias Format = ScreenFormat

    /// What hosted models write: the outline, by My call 8's rule on plan 6's measure. On LM Studio
    /// (`google/gemma-4-26b-a4b`, 24 screens of each) the outline was 24 of 24 valid and A2UI 13 of 24, and A2UI's
    /// first content came 33% later (docs/benchmarks/screen-prompt.md). Until then it was A2UI (My call 17).
    static let hostedFormat = Format.outline

    /// The outline for the on-device model, and for a hosted model this system can't run (which falls back to it);
    /// `hostedFormat` for a hosted model.
    static func format(for choice: ModelChoice) -> Format {
        room(for: choice) == .compact ? .outline : hostedFormat
    }

    /// What `choice`'s model is told before it writes the screen in `description`, in the format it writes. See
    /// `ScreenPrompt` and `A2UIPrompt` for how each is put together.
    static func instructions(for description: String, using choice: ModelChoice) -> String {
        instructions(for: description, room: room(for: choice), format: format(for: choice))
    }

    private static func instructions(for description: String, room: ScreenPrompt.Room, format: Format) -> String {
        switch format {
        case .outline: ScreenPrompt.instructions(room, for: description)
        case .a2ui: A2UIPrompt.instructions(for: description)
        }
    }

    static func room(for choice: ModelChoice) -> ScreenPrompt.Room {
        choice.hostedProvider != nil && choice.model != nil && HostedLanguageModel.isSupported ? .full : .compact
    }

    /// A short name for the new screen, from the first words of its description.
    static func name(for description: String) -> String {
        let words = description.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters)
        guard let first = trimmed.first else { return "Generated Screen" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// What a screen is written from.
    struct Request: Equatable, Sendable {
        /// What the screen is for, as the person said it.
        var description: String
        /// What the rest of the design says (`SketchPrompt.describe(board:)`), so the new screen's words match it;
        /// nil for an empty design.
        var board: String? = nil
        /// The model that writes it.
        var choice: ModelChoice
        /// The design's tokens, which the screen's spacings and cards are read with: no model picks a number.
        var tokens = DesignTokens.standard
    }

    /// How far a screen has got.
    enum Update: Equatable, Sendable {
        /// The model has begun its answer. Until then it is thinking: a model that
        /// reasons first can spend most of the time there, and Foundation Models sends no
        /// update until the answer itself starts.
        case startedWriting
        /// The screen as far as it has been written: a keyed root, fixed (`TreeValidator.fixGenerated`) and not laid
        /// out, with ids fresh from the parse.
        case screen(LayerNode)
        /// What the model wrote that couldn't be brought in, but for buttons' actions, which are never run anyway:
        /// once, after the last screen, when there is any. Only A2UI says so.
        case leftOut([A2UIDiagnostic])
    }

    /// Writes the screen `request` describes with its model, in the format its model writes (`format(for:)`).
    static func stream(_ request: Request) -> AsyncThrowingStream<Update, any Error> {
        stream(request, format: format(for: request.choice))
    }

    /// Writes the screen `request` describes with its model, which is told to write `format`. Each screen update
    /// has more leaves than the one before. Throws `nothingWritten` when the whole answer gave no screen.
    static func stream(_ request: Request, format: Format) -> AsyncThrowingStream<Update, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let room = Self.room(for: request.choice)
                    let session = makeSession(for: request.choice, instructions: instructions(for: request.description, room: room, format: format))
                    let prompt = ScreenPrompt.request(request.description, board: request.board, room: room)
                    var reader = ScreenReader(format, tokens: request.tokens)
                    var text = ""
                    var hasHandedOn = false
                    var hasStarted = false
                    for try await snapshot in session.streamResponse(to: prompt) {
                        text = snapshot.content
                        if !hasStarted, !text.isEmpty {
                            hasStarted = true
                            continuation.yield(.startedWriting)
                        }
                        if let root = reader.take(text, isComplete: false) {
                            hasHandedOn = true
                            continuation.yield(.screen(root))
                        }
                    }
                    if let root = reader.take(text, isComplete: true) {
                        hasHandedOn = true
                        continuation.yield(.screen(root))
                    }
                    if !hasHandedOn { throw GenerationError.nothingWritten }
                    let leftOut = reader.leftOut
                    if !leftOut.isEmpty { continuation.yield(.leftOut(leftOut)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeSession(for choice: ModelChoice, instructions: String) -> LanguageModelSession {
        if let provider = choice.hostedProvider, let model = choice.model, HostedLanguageModel.isSupported {
            return LanguageModelSession(model: HostedLanguageModel(provider: provider, model: model), instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }
}


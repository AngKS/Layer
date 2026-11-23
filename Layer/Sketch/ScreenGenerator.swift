import Foundation
@_weakLinked import FoundationModels

/// Writes a whole screen from a description, with the design's own model, and streams it:
/// the model writes the screen as an outline (`Outline`), one line at a time, and each time
/// a finished line adds to it the screen so far is handed on as a keyed tree (`OutlineStream`),
/// so the canvas can show it growing while the model is still writing.
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

    /// What `choice`'s model is told before it writes the screen in `description`. See
    /// `ScreenPrompt` for how it is put together.
    static func instructions(for description: String, using choice: ModelChoice) -> String {
        ScreenPrompt.instructions(room(for: choice), for: description)
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
    }

    /// Writes the screen `request` describes with its model. Each screen update has more leaves than the one
    /// before. Throws `nothingWritten` when the whole answer gave no screen.
    static func stream(_ request: Request) -> AsyncThrowingStream<Update, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(for: request.choice, description: request.description)
                    let prompt = ScreenPrompt.request(request.description, board: request.board, room: room(for: request.choice))
                    var outline = OutlineStream(tokens: request.tokens)
                    var text = ""
                    var hasHandedOn = false
                    var hasStarted = false
                    for try await snapshot in session.streamResponse(to: prompt) {
                        text = snapshot.content
                        if !hasStarted, !text.isEmpty {
                            hasStarted = true
                            continuation.yield(.startedWriting)
                        }
                        if let root = outline.take(text, isComplete: false) {
                            hasHandedOn = true
                            continuation.yield(.screen(root))
                        }
                    }
                    if let root = outline.take(text, isComplete: true) {
                        hasHandedOn = true
                        continuation.yield(.screen(root))
                    }
                    if !hasHandedOn { throw GenerationError.nothingWritten }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeSession(for choice: ModelChoice, description: String) -> LanguageModelSession {
        let instructions = instructions(for: description, using: choice)
        if let provider = choice.hostedProvider, let model = choice.model, HostedLanguageModel.isSupported {
            return LanguageModelSession(model: HostedLanguageModel(provider: provider, model: model), instructions: instructions)
        }
        return LanguageModelSession(instructions: instructions)
    }
}


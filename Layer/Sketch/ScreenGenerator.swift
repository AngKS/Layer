import Foundation
@_weakLinked import FoundationModels

/// Writes a whole screen from a description, with the design's own model, and streams it:
/// the model writes one element per line in `ScreenBlueprint`'s written form, and each
/// time a line is finished the screen so far is handed on, so the canvas can show it
/// growing while the model is still writing.
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

    /// The screen so far: the blueprint of every finished line in `text`, with one
    /// primary action. While the model is still writing, the last line may be half
    /// written, so it waits for the next.
    static func blueprint(ofFinishedLinesIn text: String, isComplete: Bool) -> ScreenBlueprint? {
        var lines = text.components(separatedBy: "\n")
        if !isComplete { lines.removeLast() }
        // Models sometimes wrap the lines in a code block or add a heading anyway.
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("```") && !trimmed.hasPrefix("#")
        }
        return ScreenBlueprint.parse(kept.joined(separator: "\n"))?.withOnePrimaryAction()
    }

    /// A short name for the new screen, from the first words of its description.
    static func name(for description: String) -> String {
        let words = description.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters)
        guard let first = trimmed.first else { return "Generated Screen" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// How far a screen has got.
    enum Update: Equatable, Sendable {
        /// The model has begun its answer. Until then it is thinking: a model that
        /// reasons first can spend most of the time there, and Foundation Models sends no
        /// update until the answer itself starts.
        case startedWriting
        /// The screen as far as it has been written.
        case screen(ScreenBlueprint)
    }

    /// Writes a screen described in `description` with `choice`'s model. `board` is what
    /// the rest of the design says (`SketchPrompt.describe(board:)`), so the new screen's
    /// words match it; nil for an empty design. Each screen update has more elements than
    /// the one before.
    static func stream(_ description: String, board: String? = nil, using choice: ModelChoice) -> AsyncThrowingStream<Update, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(for: choice, description: description)
                    let request = ScreenPrompt.request(description, board: board, room: room(for: choice))
                    var text = ""
                    var count = 0
                    var hasStarted = false
                    for try await snapshot in session.streamResponse(to: request) {
                        text = snapshot.content
                        if !hasStarted, !text.isEmpty {
                            hasStarted = true
                            continuation.yield(.startedWriting)
                        }
                        if let blueprint = blueprint(ofFinishedLinesIn: text, isComplete: false), blueprint.itemCount > count {
                            count = blueprint.itemCount
                            continuation.yield(.screen(blueprint))
                        }
                    }
                    if let blueprint = blueprint(ofFinishedLinesIn: text, isComplete: true), blueprint.itemCount > count {
                        count = blueprint.itemCount
                        continuation.yield(.screen(blueprint))
                    }
                    if count == 0 { throw GenerationError.nothingWritten }
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

extension ScreenBlueprint {
    /// How many elements it has, in every section.
    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
}

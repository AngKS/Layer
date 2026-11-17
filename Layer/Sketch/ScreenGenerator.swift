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

    static let instructions = """
        You design phone app screens for a wireframing tool. Given a description of a screen, \
        write its elements one per line, from top to bottom, in this form:

        kind: words [look]

        Kinds: title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, \
        progress, avatar, text. Start a line with "row:" and separate elements with "|" to put \
        them side by side. A blank line starts a new section. Square brackets are optional and \
        hold the look: a colour name, bold, a size such as 18pt, radius 12, on or off, 40% for a \
        progress bar, bordered or plain for a button.

        Example:
        title: Welcome back
        body: Sign in to continue
        text field: Email
        text field: Password
        button: Sign in [blue]
        row: button: Forgot password? [plain] | button: Create account [plain]

        Write only the lines: no introduction, no explanation, no markdown. Use 4 to 12 lines.
        """

    /// The screen so far: the blueprint of every finished line in `text`. While the model
    /// is still writing, the last line may be half written, so it waits for the next.
    static func blueprint(ofFinishedLinesIn text: String, isComplete: Bool) -> ScreenBlueprint? {
        var lines = text.components(separatedBy: "\n")
        if !isComplete { lines.removeLast() }
        // Models sometimes wrap the lines in a code block or add a heading anyway.
        let kept = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("```") && !trimmed.hasPrefix("#")
        }
        return ScreenBlueprint.parse(kept.joined(separator: "\n"))
    }

    /// A short name for the new screen, from the first words of its description.
    static func name(for description: String) -> String {
        let words = description.split(whereSeparator: \.isWhitespace).prefix(4).joined(separator: " ")
        let trimmed = words.trimmingCharacters(in: .punctuationCharacters)
        guard let first = trimmed.first else { return "Generated Screen" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Writes a screen described in `description` with `choice`'s model. Each value is the
    /// screen as far as it has been written, and has more elements than the one before.
    static func stream(_ description: String, using choice: ModelChoice) -> AsyncThrowingStream<ScreenBlueprint, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(for: choice)
                    var text = ""
                    var count = 0
                    for try await snapshot in session.streamResponse(to: description) {
                        text = snapshot.content
                        if let blueprint = blueprint(ofFinishedLinesIn: text, isComplete: false), blueprint.itemCount > count {
                            count = blueprint.itemCount
                            continuation.yield(blueprint)
                        }
                    }
                    if let blueprint = blueprint(ofFinishedLinesIn: text, isComplete: true), blueprint.itemCount > count {
                        count = blueprint.itemCount
                        continuation.yield(blueprint)
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

    private static func makeSession(for choice: ModelChoice) -> LanguageModelSession {
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

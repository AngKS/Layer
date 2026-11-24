import Foundation
@_weakLinked import FoundationModels

/// Measures how models write whole screens, with the app's own prompts and parsers: each screen is printed with its
/// scores, then a summary line. See `run.sh` for the modes and docs/benchmarks/screen-prompt.md for what was measured.
@main struct Harness {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "check":
            exit(check() ? 0 : 1)
        case "outline":
            await onDevice(runs: runs(arguments.dropFirst(1).first))
        case "hosted" where arguments.count >= 3:
            guard let format = Format(rawValue: arguments[2]) else { usage() }
            await hosted(model: arguments[1], format: format, runs: runs(arguments.dropFirst(3).first))
        default:
            usage()
        }
    }

    private static func usage() -> Never {
        print("usage: run.sh check | outline [runs] | hosted <LM Studio model id> <outline|a2ui> [runs]")
        exit(2)
    }

    private static func runs(_ argument: String?) -> Int {
        argument.flatMap(Int.init).map { max($0, 1) } ?? 1
    }

    // MARK: Check

    /// Scores the canned answers, each streamed a line at a time as a model would write it. No model runs.
    private static func check() -> Bool {
        var outline = Summary(label: "check outline")
        var a2ui = Summary(label: "check a2ui")
        for (format, text) in [(Format.outline, Briefs.cannedOutline), (.a2ui, Briefs.cannedA2UI)] {
            var reader = Reader(format)
            var shown = 0
            var written = ""
            for line in text.components(separatedBy: "\n") {
                written += line + "\n"
                if reader.take(written, isComplete: false) != nil { shown += 1 }
            }
            if reader.take(written, isComplete: true) != nil { shown += 1 }
            let score = format == .outline ? Score.outline(written) : Score.a2ui(written)
            print("=== check \(format.rawValue): \(shown) screens handed on\n\(score.line)")
            if format == .outline { outline.scores.append(score) } else { a2ui.scores.append(score) }
            if shown == 0 { print("ERR check \(format.rawValue): the stream handed on nothing") }
        }
        print(outline.line)
        print(a2ui.line)
        let outlineValid = outline.scores.filter(\.valid).count, a2uiValid = a2ui.scores.filter(\.valid).count
        print("harness \(outlineValid == 1 && a2uiValid == 1 ? "ok" : "FAILED"): outline \(outlineValid)/1 valid, a2ui \(a2uiValid)/1 valid")
        return outlineValid == 1 && a2uiValid == 1
    }

    // MARK: Models

    /// The on-device model, as the app asks it (`ScreenGenerator`): the compact outline prompt, the description as
    /// the message, and the session's own options.
    private static func onDevice(runs: Int) async {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            print("ERR the on-device model isn't available here: \(model.availability)")
            exit(1)
        }
        var summary = Summary(label: "on-device outline")
        for brief in Briefs.all {
            for _ in 0..<runs {
                let session = LanguageModelSession(instructions: ScreenPrompt.instructions(.compact, for: brief))
                let message = ScreenPrompt.request(brief, board: nil, room: .compact)
                await measure(brief, .outline, into: &summary) { take in
                    for try await snapshot in session.streamResponse(to: message) { take(snapshot.content) }
                    return nil
                }
            }
        }
        print(summary.line)
    }

    /// A model LM Studio serves on this Mac, through `HostedModelClient`, with no key: the full prompt in `format`,
    /// sent as the app sends it (`HostedLanguageModel`), the instructions as the system prompt.
    private static func hosted(model: String, format: Format, runs: Int) async {
        var summary = Summary(label: "LM Studio \(model) \(format.rawValue)")
        for brief in Briefs.all {
            for _ in 0..<runs {
                let instructions = format == .outline ? ScreenPrompt.instructions(.full, for: brief) : A2UIPrompt.instructions(for: brief)
                let conversation = HostedConversation(
                    system: instructions,
                    messages: [HostedConversation.Message(role: .user, text: ScreenPrompt.request(brief, board: nil, room: .full))])
                await measure(brief, format, into: &summary) { take in
                    var text = ""
                    var tokens: Int?
                    for try await event in HostedModelClient.stream(
                        conversation, schema: nil, maximumTokens: nil, temperature: nil, provider: .lmStudio, model: model, key: nil
                    ) {
                        switch event {
                        case .text(let more):
                            text += more
                            take(text)
                        case .usage(_, let output):
                            tokens = max(tokens ?? 0, output)
                        case .reasoning, .toolCall:
                            break
                        }
                    }
                    return tokens
                }
            }
        }
        print(summary.line)
    }

    /// Runs one answer through the app's stream reader as it arrives, timing the first screen handed on (what the
    /// canvas first shows) and the end, then scores the whole answer. `answer` hands each answer-so-far to `take` and
    /// returns the output tokens, when the model says.
    private static func measure(
        _ brief: String, _ format: Format, into summary: inout Summary,
        answer: (_ take: (String) -> Void) async throws -> Int?
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        var reader = Reader(format)
        var text = ""
        var firstContent: Duration?
        do {
            let tokens = try await answer { soFar in
                text = soFar
                if reader.take(soFar, isComplete: false) != nil, firstContent == nil { firstContent = clock.now - start }
            }
            if reader.take(text, isComplete: true) != nil, firstContent == nil { firstContent = clock.now - start }
            summary.completion.append(clock.now - start)
            if let firstContent { summary.firstContent.append(firstContent) }
            if let tokens { summary.outputTokens.append(tokens) }
        } catch {
            print("=== \(summary.label) · \(brief)\nERR \(error)\n")
            summary.errors.append("\(brief): \(error)")
            return
        }
        let score = format == .outline ? Score.outline(text) : Score.a2ui(text)
        let timing = "firstContent=\(firstContent.map { "\(Int(($0 / .milliseconds(1)).rounded()))" } ?? "-")ms completion=\(Int(((clock.now - start) / .milliseconds(1)).rounded()))ms"
        print("=== \(summary.label) · \(brief)\n\(text)\n\(score.line) \(timing)\n")
        summary.scores.append(score)
    }
}

/// The app's stream reader for a format, as `ScreenGenerator` reads an answer.
private enum Reader {
    case outline(OutlineStream)
    case a2ui(A2UIStream)

    init(_ format: Format) {
        switch format {
        case .outline: self = .outline(OutlineStream(tokens: .standard))
        case .a2ui: self = .a2ui(A2UIStream(tokens: .standard))
        }
    }

    /// The screen so far, when it has more leaves than the last one handed on.
    mutating func take(_ text: String, isComplete: Bool) -> LayerNode? {
        switch self {
        case .outline(var outline):
            defer { self = .outline(outline) }
            return outline.take(text, isComplete: isComplete)
        case .a2ui(var a2ui):
            defer { self = .a2ui(a2ui) }
            return a2ui.take(text, isComplete: isComplete)
        }
    }
}

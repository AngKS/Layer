import Foundation
@_weakLinked import FoundationModels

/// Measures how models write whole screens, with the app's own prompts and parsers: each screen is printed with its
/// scores, then a summary line. See `run.sh` for the modes and docs/benchmarks/screen-prompt.md for what was measured.
@main struct Harness {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "check":
            let harness = check()
            let rule = HostedFormatRule.check()
            exit(harness && rule ? 0 : 1)
        case "outline":
            await onDevice(runs: runs(arguments.dropFirst(1).first))
        case "hosted" where arguments.count >= 3 && arguments[2] == "both":
            await hostedBoth(model: arguments[1], runs: runs(arguments.dropFirst(3).first))
        case "hosted" where arguments.count >= 3:
            guard let format = Format(rawValue: arguments[2]) else { usage() }
            await hosted(model: arguments[1], format: format, runs: runs(arguments.dropFirst(3).first))
        default:
            usage()
        }
    }

    private static func usage() -> Never {
        print("usage: run.sh check | outline [runs] | hosted <LM Studio model id> <outline|a2ui|both> [runs]")
        exit(2)
    }

    private static func runs(_ argument: String?) -> Int {
        argument.flatMap(Int.init).map { max($0, 1) } ?? 1
    }

    // MARK: Check

    /// Scores the canned answers, each streamed a line at a time as a model would write it. No model runs. Each passes
    /// when its reader handed on a screen and the whole answer is valid.
    private static func check() -> Bool {
        var outline = Summary(label: "check outline")
        var a2ui = Summary(label: "check a2ui")
        var handedOn = true
        for (format, text) in [(Format.outline, Briefs.cannedOutline), (.a2ui, Briefs.cannedA2UI)] {
            var reader = ScreenReader(format, tokens: .standard)
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
            if shown == 0 {
                print("ERR check \(format.rawValue): the stream handed on nothing")
                handedOn = false
            }
        }
        print(outline.line)
        print(a2ui.line)
        let outlineValid = outline.scores.filter(\.valid).count, a2uiValid = a2ui.scores.filter(\.valid).count
        let ok = handedOn && outlineValid == 1 && a2uiValid == 1
        print("harness \(ok ? "ok" : "FAILED"): outline \(outlineValid)/1 valid, a2ui \(a2uiValid)/1 valid")
        return ok
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
            for _ in 0..<runs { await hostedRun(brief, model: model, format: format, into: &summary) }
        }
        print(summary.line)
    }

    /// Both formats, one after the other on each brief, A2UI first on the odd ones (the first, third...), so that
    /// neither format always meets a model warmed or cooled by the other. Each format's summary as `hosted` prints it,
    /// then the default `HostedFormatRule` chooses from them (My call 8).
    private static func hostedBoth(model: String, runs: Int) async {
        var outline = Summary(label: "LM Studio \(model) outline")
        var a2ui = Summary(label: "LM Studio \(model) a2ui")
        for (index, brief) in Briefs.all.enumerated() {
            for _ in 0..<runs {
                if index % 2 == 0 {
                    await hostedRun(brief, model: model, format: .a2ui, into: &a2ui)
                    await hostedRun(brief, model: model, format: .outline, into: &outline)
                } else {
                    await hostedRun(brief, model: model, format: .outline, into: &outline)
                    await hostedRun(brief, model: model, format: .a2ui, into: &a2ui)
                }
            }
        }
        print(outline.line)
        print(a2ui.line)
        func result(_ summary: Summary) -> HostedFormatRule.Result {
            HostedFormatRule.Result(valid: summary.valid, screens: summary.screens, firstContentP50: summary.firstContentP50)
        }
        print(HostedFormatRule.line(outline: result(outline), a2ui: result(a2ui)))
    }

    /// One answer from the hosted model in `format`, scored into `summary`.
    private static func hostedRun(_ brief: String, model: String, format: Format, into summary: inout Summary) async {
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

    /// Runs one answer through the app's stream reader as it arrives, timing the first screen handed on (what the
    /// canvas first shows) and the end, then scores the whole answer. `answer` hands each answer-so-far to `take` and
    /// returns the output tokens, when the model says.
    private static func measure(
        _ brief: String, _ format: Format, into summary: inout Summary,
        answer: (_ take: (String) -> Void) async throws -> Int?
    ) async {
        let clock = ContinuousClock()
        let start = clock.now
        var reader = ScreenReader(format, tokens: .standard)
        var text = ""
        var firstContent: Duration?
        var completion = Duration.zero
        do {
            let tokens = try await answer { soFar in
                text = soFar
                if reader.take(soFar, isComplete: false) != nil, firstContent == nil { firstContent = clock.now - start }
            }
            if reader.take(text, isComplete: true) != nil, firstContent == nil { firstContent = clock.now - start }
            completion = clock.now - start
            summary.completion.append(completion)
            if let firstContent { summary.firstContent.append(firstContent) }
            if let tokens { summary.outputTokens.append(tokens) }
        } catch {
            print("=== \(summary.label) · \(brief)\nERR \(error)\n")
            summary.errors.append("\(brief): \(error)")
            return
        }
        let score = format == .outline ? Score.outline(text) : Score.a2ui(text)
        let timing = "firstContent=\(firstContent.map { "\(Int(($0 / .milliseconds(1)).rounded()))" } ?? "-")ms completion=\(Int((completion / .milliseconds(1)).rounded()))ms"
        print("=== \(summary.label) · \(brief)\n\(text)\n\(score.line) \(timing)\n")
        summary.scores.append(score)
    }
}

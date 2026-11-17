#if DEBUG
import CoreGraphics
import Foundation

/// Plays a voice call without a microphone or a real model, so the pill and what a command
/// does to the canvas can be watched and photographed in the simulator.
///
/// Launch with `-LayerVoiceDemo "<spoken> => <what comes of it>; …"`. Each line is heard
/// word by word, then carried out. What comes of it is one of:
///
/// - tools for the model to call, as `tool key=value key=value`, several joined by `&&`.
///   The real agent runs them on the design: `make it blue => styleElement element=E2 look=blue`.
/// - plain words, which the pill shows as what was done: `make it blue => Made it blue`.
/// - `!` and plain words, which the pill shows as what went wrong.
///
/// `-LayerVoiceDemoFreeze` holds the call at the first moment of one kind: `listening`,
/// `hearing`, `working`, `done` or `problem`. `-LayerVoiceDemoDark YES` plays it on the
/// dark canvas. `-LayerVoiceDemoDesign login` puts a login screen on the canvas first:
/// S1, with E1 a title, E2 a "Sign in" button and E3 an image.
///
/// Keep apostrophes and quotation marks out of the script: launched from a UI test, one
/// swallows the arguments that follow it.
@MainActor
enum VoiceDemo {
    struct Line: Equatable {
        var spoken: String
        var result: String
    }

    static func lines(from script: String) -> [Line] {
        script.split(separator: ";").compactMap { part in
            let sides = part.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2, !sides[0].isEmpty else { return nil }
            return Line(spoken: sides[0], result: sides[1])
        }
    }

    /// The tool calls a line's result stands for, or nil if it is plain words.
    static func steps(from result: String) -> [ScriptedLanguageModel.Step]? {
        var steps: [ScriptedLanguageModel.Step] = []
        for written in result.components(separatedBy: "&&") {
            let parts = written.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
            guard let tool = parts.first, VoiceTools.step(for: tool) != VoiceTools.step(for: "") else { return nil }
            // Each value runs up to the next `key=`, so it can hold spaces and commas.
            let rest = parts.count > 1 ? parts[1] : ""
            let keys = rest.matches(of: /(\w+)=/)
            var arguments: [String: String] = [:]
            for (index, key) in keys.enumerated() {
                let end = index + 1 < keys.count ? keys[index + 1].range.lowerBound : rest.endIndex
                arguments[String(key.1)] = rest[key.range.upperBound..<end].trimmingCharacters(in: .whitespaces)
            }
            let json = (try? JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys)).map { String(decoding: $0, as: UTF8.self) }
            steps.append(ScriptedLanguageModel.Step(tool: tool, arguments: json ?? "{}"))
        }
        return steps.isEmpty ? nil : steps
    }

    static func runIfRequested(on model: AppModel) async {
        let defaults = UserDefaults.standard
        guard let script = defaults.string(forKey: "LayerVoiceDemo") else { return }
        let freeze = defaults.string(forKey: "LayerVoiceDemoFreeze")
        if defaults.bool(forKey: "LayerVoiceDemoDark") {
            model.store.updateCanvas { $0.background = CanvasSettings.backgrounds.last }
        }
        if defaults.string(forKey: "LayerVoiceDemoDesign") == "login", model.store.screens.isEmpty {
            addLoginScreen(to: model)
        }

        let lines = lines(from: script)
        let route = DemoRoute(lines: lines, freeze: freeze) { [weak model] in model?.voice?.phase == .working }
        // Lines that name tools go to the real agent, with a model that calls just those tools.
        var toolScript: [String: [ScriptedLanguageModel.Step]] = [:]
        for line in lines {
            if let steps = steps(from: line.result) { toolScript[line.spoken.lowercased()] = steps }
        }
        let runner: any VoiceCommandRunner = toolScript.isEmpty
            ? DemoRunner(lines: lines, freeze: freeze, model: model)
            : VoiceAgent(model: model, testModel: ScriptedLanguageModel(script: toolScript))
        await model.startVoiceCall(route: route, runner: runner)
        if freeze == "done" || freeze == "problem" {
            model.voice?.captionTimes = (done: .seconds(3600), problem: .seconds(3600))
        }
    }

    private static func addLoginScreen(to model: AppModel) {
        let device = DeviceFrame.iPhone
        let screen = model.store.addScreen(device, at: DesignActions.placementForNewScreen(device, in: model))
        model.store.updateScreen(screen.id) { $0.name = "Login" }
        _ = model.store.setElements([
            DesignElement(kind: .title, frame: CGRect(x: 20, y: 75, width: 353, height: 41), text: "Welcome back", tint: Theme.accent),
            DesignElement(kind: .button, frame: CGRect(x: 20, y: 420, width: 353, height: 50), text: "Sign in", tint: Theme.accent),
            DesignElement(kind: .image, frame: CGRect(x: 20, y: 500, width: 200, height: 200), text: "", tint: Theme.accent),
        ], on: screen.id, replacing: true)
        model.ink?.zoomToFit()
    }
}

/// Hears a script: the room's sound rising and falling as if someone were speaking, the
/// words arriving one by one, then the finished command.
@MainActor
private final class DemoRoute: VoiceRoute {
    let lines: [VoiceDemo.Line]
    let freeze: String?
    /// Whether the last command is still being carried out.
    let isBusy: @MainActor () -> Bool
    private var speaking: Task<Void, Never>?
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?

    init(lines: [VoiceDemo.Line], freeze: String?, isBusy: @escaping @MainActor () -> Bool) {
        self.lines = lines
        self.freeze = freeze
        self.isBusy = isBusy
    }

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        let (events, continuation) = AsyncStream<VoiceRouteEvent>.makeStream()
        self.continuation = continuation
        let (lines, freeze, isBusy) = (lines, freeze, isBusy)
        speaking = Task {
            // The sound of the room, all the while.
            let room = Task {
                var step = 0
                while !Task.isCancelled {
                    step += 1
                    let swell = (sin(Double(step) * 0.55) + 1) / 2
                    continuation.yield(.level(Float(0.15 + 0.75 * swell * Double.random(in: 0.5...1))))
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            defer { room.cancel() }
            if freeze == "listening" { return await Self.hold() }
            for line in lines {
                try? await Task.sleep(for: .milliseconds(900))
                var heard: [Substring] = []
                let words = line.spoken.split(separator: " ")
                for (index, word) in words.enumerated() {
                    heard.append(word)
                    continuation.yield(.hearing(heard.joined(separator: " ")))
                    if freeze == "hearing", index >= words.count / 2 { return await Self.hold() }
                    try? await Task.sleep(for: .milliseconds(220))
                }
                continuation.yield(.command(line.spoken))
                // The next line waits for this one to be carried out and its result to be read.
                try? await Task.sleep(for: .milliseconds(300))
                while isBusy() {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                // Held at the first result, or at the first that went wrong.
                if freeze == "done", !line.result.hasPrefix("!") { return await Self.hold() }
                if freeze == "problem", line.result.hasPrefix("!") { return await Self.hold() }
                try? await Task.sleep(for: .milliseconds(2600))
                if Task.isCancelled { return }
            }
            await Self.hold()
        }
        return events
    }

    func stop() {
        speaking?.cancel()
        continuation?.finish()
    }

    private static func hold() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}

/// Carries a scripted command out by saying what the script says was done.
@MainActor
private final class DemoRunner: VoiceCommandRunner {
    let lines: [VoiceDemo.Line]
    let freeze: String?
    weak var model: AppModel?

    init(lines: [VoiceDemo.Line], freeze: String?, model: AppModel) {
        self.lines = lines
        self.freeze = freeze
        self.model = model
    }

    func run(_ command: String) async -> VoiceOutcome {
        try? await Task.sleep(for: .milliseconds(700))
        model?.voice?.showStep("Restyling…")
        while freeze == "working", !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
        try? await Task.sleep(for: .milliseconds(1100))
        if Task.isCancelled { return VoiceOutcome(wasCancelled: true) }
        let result = lines.first { $0.spoken == command }?.result ?? "Done"
        return result.hasPrefix("!")
            ? VoiceOutcome(problem: String(result.dropFirst()))
            : VoiceOutcome(lines: [result])
    }
}
#endif

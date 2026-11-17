#if DEBUG
import Foundation

/// Plays a voice call without a microphone, so the pill and its states can be watched and
/// photographed in the simulator.
///
/// Launch with `-LayerVoiceDemo "<spoken> => <what was done>; <spoken> => !<what went wrong>"`.
/// Each line is heard word by word, then carried out. `-LayerVoiceDemoFreeze` holds the
/// call at the first moment of one kind: `listening`, `hearing`, `working`, `done` or `problem`.
/// Keep apostrophes out of the script: launched from a UI test, one swallows the
/// arguments that follow it.
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

    static func runIfRequested(on model: AppModel) async {
        let defaults = UserDefaults.standard
        guard let script = defaults.string(forKey: "LayerVoiceDemo") else { return }
        let freeze = defaults.string(forKey: "LayerVoiceDemoFreeze")
        // `-LayerVoiceDemoDark YES` plays the call on the dark canvas.
        if defaults.bool(forKey: "LayerVoiceDemoDark") {
            model.store.updateCanvas { $0.background = CanvasSettings.backgrounds.last }
        }
        let lines = lines(from: script)
        let route = DemoRoute(lines: lines, freeze: freeze)
        let runner = DemoRunner(lines: lines, freeze: freeze, model: model)
        route.runner = runner
        await model.startVoiceCall(route: route, runner: runner)
        if freeze == "done" || freeze == "problem" {
            model.voice?.captionTimes = (done: .seconds(3600), problem: .seconds(3600))
        }
    }
}

/// Hears a script: the room's sound rising and falling as if someone were speaking, the
/// words arriving one by one, then the finished command.
@MainActor
private final class DemoRoute: VoiceRoute {
    let lines: [VoiceDemo.Line]
    let freeze: String?
    weak var runner: DemoRunner?
    private var speaking: Task<Void, Never>?
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?

    init(lines: [VoiceDemo.Line], freeze: String?) {
        self.lines = lines
        self.freeze = freeze
    }

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        let (events, continuation) = AsyncStream<VoiceRouteEvent>.makeStream()
        self.continuation = continuation
        let (lines, freeze) = (lines, freeze)
        speaking = Task { [weak self] in
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
                while self?.runner?.isRunning == true {
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
    private(set) var isRunning = false

    init(lines: [VoiceDemo.Line], freeze: String?, model: AppModel) {
        self.lines = lines
        self.freeze = freeze
        self.model = model
    }

    func run(_ command: String) async -> VoiceOutcome {
        isRunning = true
        defer { isRunning = false }
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

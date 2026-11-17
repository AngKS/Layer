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
/// dark canvas, and `NO` on the paper. `-LayerVoiceDemoDesign login` puts a login screen
/// on the canvas first: S1, with E1 a title, E2 a "Sign in" button and E3 an image.
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
        if let script = defaults.string(forKey: "LayerPencilDemo") {
            await PencilDemo.run(script, on: model)
            return
        }
        guard let script = defaults.string(forKey: "LayerVoiceDemo") else { return }
        let freeze = defaults.string(forKey: "LayerVoiceDemoFreeze")
        prepareCanvas(of: model)

        let lines = lines(from: script)
        let route = DemoRoute(lines: lines, freeze: freeze) { [weak model] in model?.voice?.phase == .working }
        let runner = runner(for: lines, freeze: freeze, model: model) { [weak model] step in model?.voice?.showStep(step) }
        await model.startVoiceCall(route: route, runner: runner)
        if freeze == "done" || freeze == "problem" {
            model.voice?.captionTimes = (done: .seconds(3600), problem: .seconds(3600))
        }
    }

    /// The dark canvas and the login screen, if the launch asks for them.
    static func prepareCanvas(of model: AppModel) {
        let defaults = UserDefaults.standard
        // NO puts the paper back, for a design an earlier run left dark.
        if defaults.object(forKey: "LayerVoiceDemoDark") != nil {
            let isDark = defaults.bool(forKey: "LayerVoiceDemoDark")
            model.store.updateCanvas { $0.background = isDark ? CanvasSettings.backgrounds.last : nil }
        }
        if defaults.string(forKey: "LayerVoiceDemoDesign") == "login", model.store.screens.isEmpty {
            addLoginScreen(to: model)
        }
    }

    /// Lines that name tools go to the real agent, with a model that calls just those
    /// tools. Otherwise the script's words are shown as what was done.
    static func runner(for lines: [Line], freeze: String?, model: AppModel, step: @escaping @MainActor (String) -> Void) -> any VoiceCommandRunner {
        var toolScript: [String: [ScriptedLanguageModel.Step]] = [:]
        for line in lines {
            if let steps = steps(from: line.result) { toolScript[line.spoken.lowercased()] = steps }
        }
        return toolScript.isEmpty
            ? DemoRunner(lines: lines, freeze: freeze, step: step)
            : VoiceAgent(model: model, testModel: ScriptedLanguageModel(script: toolScript))
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

/// Plays an Apple Pencil Pro squeeze, which the simulator can't make, so that the pencil's
/// bubble can be watched and photographed there.
///
/// Launch with `-LayerPencilDemo "<x>,<y>,<azimuth>,<hold|toggle> => <spoken> => <what comes of it>"`.
/// The squeeze begins at the point `x`,`y` of the window, in points, with the barrel
/// pointing `azimuth` degrees clockwise from the right (0 points right, 90 down), or `-`
/// for a pencil whose angle isn't known. A hold is let go of once the words are heard; a
/// toggle is a quick squeeze, and a second one sends. What comes of it is written as for
/// `-LayerVoiceDemo`.
///
/// `-LayerVoiceDemoFreeze` holds the bubble at `listening` (never sent), `working`,
/// `done` or `problem`. A hold left listening still stops after `PencilVoice.maximumHold`,
/// a minute; a toggle stays. `-LayerPencilDemoWords YES` shows the words heard, as the setting
/// does, and anything else hides them. `-LayerVoiceDemoDark` and `-LayerVoiceDemoDesign`
/// work as for `-LayerVoiceDemo`.
@MainActor
enum PencilDemo {
    struct Squeeze: Equatable {
        var point: CGPoint
        var azimuth: Double?
        var toggles: Bool
        var line: VoiceDemo.Line
    }

    static func squeeze(from script: String) -> Squeeze? {
        let sides = script.components(separatedBy: "=>").map { $0.trimmingCharacters(in: .whitespaces) }
        guard sides.count == 3, !sides[1].isEmpty else { return nil }
        let fields = sides[0].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 4, let x = Double(fields[0]), let y = Double(fields[1]),
              fields[3] == "hold" || fields[3] == "toggle" else { return nil }
        let azimuth = Double(fields[2])
        guard azimuth != nil || fields[2] == "-" else { return nil }
        return Squeeze(point: CGPoint(x: x, y: y), azimuth: azimuth, toggles: fields[3] == "toggle", line: VoiceDemo.Line(spoken: sides[1], result: sides[2]))
    }

    static func run(_ script: String, on model: AppModel) async {
        guard let squeeze = squeeze(from: script) else {
            VoiceLog.log.error("pencil demo: couldn't read the script")
            return
        }
        let defaults = UserDefaults.standard
        let freeze = defaults.string(forKey: "LayerVoiceDemoFreeze")
        // The setting the bubble reads, set either way so that an earlier run's doesn't linger.
        defaults.set(defaults.bool(forKey: "LayerPencilDemoWords"), forKey: "pencilVoice.showsWords")
        VoiceDemo.prepareCanvas(of: model)

        let lines = [squeeze.line]
        // The canvas already shows this instance and keeps to it, so the script goes into
        // it rather than replacing it. There is no hover in the simulator, so no call yet.
        let pencil = model.pencilVoice
        pencil.makeRoute = { DemoRoute(lines: lines, freeze: freeze, endsWhenTold: true, isBusy: { false }) }
        pencil.makeRunner = { model in
            VoiceDemo.runner(for: lines, freeze: freeze, model: model) { [weak model] step in model?.pencilVoice.call?.showStep(step) }
        }
        // Neither the model nor the system's squeeze setting has a say: the squeeze is scripted.
        pencil.readiness = { .ready }
        pencil.squeezeIsOff = { false }
        if freeze == "problem" { pencil.problemTime = .seconds(3600) }
        // A squeeze with Draw in hand is PencilKit's.
        model.tool = .select

        // The canvas laid out at its final size, and fitted to what is on it: a fit made
        // while the design was still opening leaves the screen out of view.
        for _ in 0..<100 where model.canvasSize == .zero || model.topBarBottom == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1))
        if !model.store.screens.isEmpty { model.ink?.zoomToFit() }
        try? await Task.sleep(for: .milliseconds(500))

        // The pen comes into range, and the call gets ready.
        pencil.hovered()
        if freeze == "done" || freeze == "problem" {
            pencil.call?.captionTimes = (done: .seconds(3600), problem: .seconds(3600))
        }
        try? await Task.sleep(for: .seconds(1))

        pencil.squeezeBegan(at: squeeze.point, azimuth: squeeze.azimuth.map { .degrees($0) })
        if pencil.bubble == nil {
            VoiceLog.log.error("pencil demo: the squeeze opened nothing, over the bar or the chrome?")
            return
        }
        if squeeze.toggles {
            try? await Task.sleep(for: .milliseconds(200))
            pencil.squeezeEnded()
        }
        // Every word heard, and a moment to look at them.
        for _ in 0..<100 where pencil.call?.caption?.text != squeeze.line.spoken {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(800))
        if freeze == "listening" { return }

        if squeeze.toggles {
            // The second squeeze sends wherever the pen has gone.
            pencil.squeezeBegan(at: nil, azimuth: nil)
            try? await Task.sleep(for: .milliseconds(200))
        }
        pencil.squeezeEnded()
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
    /// Whether a command ends only when the route is told to finish, as a pencil's does,
    /// rather than on a pause.
    let endsWhenTold: Bool
    private var speaking: Task<Void, Never>?
    private var continuation: AsyncStream<VoiceRouteEvent>.Continuation?
    /// The words heard so far, for `finish()` to send.
    private var heard = ""

    init(lines: [VoiceDemo.Line], freeze: String?, endsWhenTold: Bool = false, isBusy: @escaping @MainActor () -> Bool) {
        self.lines = lines
        self.freeze = freeze
        self.endsWhenTold = endsWhenTold
        self.isBusy = isBusy
    }

    func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent> {
        if endsWhenTold { return startUntilTold() }
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

    /// Speaks the first line word by word, the room sounding all the while, and then keeps
    /// listening. The command is sent only when `finish()` says it is over.
    private func startUntilTold() -> AsyncStream<VoiceRouteEvent> {
        let (events, continuation) = AsyncStream<VoiceRouteEvent>.makeStream()
        self.continuation = continuation
        let words = lines.first?.spoken.split(separator: " ") ?? []
        speaking = Task { [weak self] in
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
            // A moment for the tap that says listening has begun.
            try? await Task.sleep(for: .milliseconds(500))
            for index in words.indices {
                guard !Task.isCancelled else { return }
                let heard = words[...index].joined(separator: " ")
                self?.heard = heard
                continuation.yield(.hearing(heard))
                try? await Task.sleep(for: .milliseconds(220))
            }
            // Still listening. The words are said again now and then, so that a toggle left
            // listening for a picture isn't closed as silent.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let heard = self?.heard, !heard.isEmpty else { continue }
                continuation.yield(.hearing(heard))
            }
        }
        return events
    }

    func finish() {
        guard endsWhenTold else { return }
        speaking?.cancel()
        continuation?.yield(heard.isEmpty ? .nothingHeard : .command(heard))
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
    /// Shows what the command is doing, on whichever call is carrying it out.
    let step: @MainActor (String) -> Void

    init(lines: [VoiceDemo.Line], freeze: String?, step: @escaping @MainActor (String) -> Void) {
        self.lines = lines
        self.freeze = freeze
        self.step = step
    }

    func run(_ command: String) async -> VoiceOutcome {
        try? await Task.sleep(for: .milliseconds(700))
        step("Restyling…")
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

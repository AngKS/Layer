import Foundation
@_weakLinked import FoundationModels

extension SessionPropertyValues {
    /// The canvas as it is now. Written before each command and after each tool, on the
    /// main actor only; read by the instructions, which the framework evaluates afresh
    /// before every request it makes of a model.
    @SessionPropertyEntry var canvasPicture: CanvasPicture = .empty
    /// The model the design uses, which decides the profile in force.
    @SessionPropertyEntry var voiceModel: ModelChoice = .appleIntelligence
}

/// The canvas, put to the model as part of its instructions. Because instructions are
/// evaluated before every request, the model is looking at the canvas as it is, between
/// commands and between the steps of one, and never has to ask what is there.
struct CanvasBrief: DynamicInstructions {
    @SessionProperty(\.canvasPicture) private var picture
    let detail: CanvasPicture.Detail

    var body: some DynamicInstructions {
        Instructions("The canvas now:\n\(picture.text(detail))")
    }
}

/// What the profile tells the call as a command is carried out.
struct VoiceHooks: Sendable {
    /// A tool is about to run; its name.
    var willRun: @Sendable (String) async -> Void
    /// A tool has run, and the canvas may have changed.
    var didRun: @Sendable () async -> Void
    /// Whether tools may still run. False once the command has been stopped.
    var mayRun: @Sendable () async -> Bool
}

/// How a call's session is set up, whichever model the design uses: which model answers,
/// how much it is told, which tools it is handed and how much of the conversation it is
/// sent. The profile in force follows the design's model, so changing the model in the
/// middle of a call takes effect at the next command.
struct VoiceProfile: LanguageModelSession.DynamicProfile {
    @SessionProperty(\.voiceModel) private var choice
    @SessionProperty(\.canvasPicture) private var picture

    private let actor: any VoiceActing
    private let hooks: VoiceHooks
    /// A stand-in for the design's model, for tests and the simulator.
    private let testModel: (any LanguageModel)?
    /// Whether the stand-in is told the canvas in the prompt, as the on-device model is.
    private let testCanvasInPrompt: Bool

    init(actor: any VoiceActing, hooks: VoiceHooks, testModel: (any LanguageModel)? = nil, testCanvasInPrompt: Bool = false) {
        self.actor = actor
        self.hooks = hooks
        self.testModel = testModel
        self.testCanvasInPrompt = testCanvasInPrompt
    }

    /// Whether the canvas goes at the head of each command's prompt rather than in the
    /// instructions: for the on-device model, which is what the profile below falls back
    /// to wherever a hosted model can't run.
    ///
    /// Its rules and tools are then the same from one command to the next, and the model
    /// reads them once. With the canvas between them, as it was, every command after a
    /// change read all the tools again: measured on a Mac, an edit took 2.7 s, now 1.9 s.
    /// The first command of a call is a third of a second slower, as its canvas is no
    /// longer read ahead. See "Prompt order" in docs/benchmarks/voice-on-device.md.
    static func canvasGoesInPrompt(with choice: ModelChoice) -> Bool {
        choice.sketchProvider.id == SketchProvider.appleIntelligence.id
    }

    /// What goes before a command where the canvas is in the prompt.
    static func canvasLeading(_ picture: CanvasPicture) -> String {
        "The canvas now:\n\(picture.text(.compact))\n\n\(commandMarker)"
    }

    /// Where the command itself starts in such a prompt.
    static let commandMarker = "The command: "

    var body: some LanguageModelSession.DynamicProfile {
        if let testModel {
            Profile {
                Instructions(VoiceRules.full)
                if !testCanvasInPrompt {
                    CanvasBrief(detail: .full)
                }
                VoiceTools.all(actor)
            }
            .model(testModel)
            .historyTransform { Self.trimmed($0, keepingCommands: 6) }
            .reporting(to: hooks)
        } else if let provider = choice.hostedProvider, let model = choice.model, HostedLanguageModel.isSupported {
            // A hosted model has room for everything: the whole canvas and every tool.
            Profile {
                Instructions(VoiceRules.full)
                CanvasBrief(detail: .full)
                VoiceTools.all(actor)
            }
            .model(HostedLanguageModel(provider: provider, model: model))
            .historyTransform { Self.trimmed($0, keepingCommands: 6) }
            .reporting(to: hooks)
        } else {
            // The on-device model has little: one screen in full, the tools that make
            // sense for the canvas as it is, and only the last couple of commands. The
            // canvas is told in each command's prompt (`canvasGoesInPrompt`), so that the
            // rules and the tools stay the same and are read once.
            Profile {
                Instructions(VoiceRules.compact)
                if picture.hasScreens {
                    VoiceTools.all(actor)
                } else {
                    VoiceTools.forEmptyCanvas(actor)
                }
            }
            .historyTransform { Self.trimmed($0, keepingCommands: 2) }
            .maximumResponseTokens(200)
            // Always its likeliest answer, so the same words on the same canvas get the
            // same result every time. Measured, it is no less accurate that way.
            // See docs/benchmarks/voice-on-device.md.
            .samplingMode(.greedy)
            .reporting(to: hooks)
        }
    }

    /// The conversation as it is sent to a model: the instructions, and the last `count`
    /// commands whole. The framework hands the instructions over along with the history,
    /// so they are kept here by name; taking only the last few entries would drop them.
    /// A command is kept or dropped as a whole, so a tool call is never parted from its result.
    static func trimmed(_ entries: [Transcript.Entry], keepingCommands count: Int) -> [Transcript.Entry] {
        let prompts = entries.indices.filter { if case .prompt = entries[$0] { true } else { false } }
        guard count > 0, prompts.count > count else { return entries }
        let start = prompts[prompts.count - count]
        let instructions = entries[..<start].filter { if case .instructions = $0 { true } else { false } }
        return instructions + entries[start...]
    }
}

private extension LanguageModelSession.DynamicProfile {
    /// Tells the call what each tool is doing, and refuses tools once it has been stopped.
    func reporting(to hooks: VoiceHooks) -> some LanguageModelSession.DynamicProfile {
        onToolCall { call in
            guard await hooks.mayRun() else { throw CancellationError() }
            await hooks.willRun(call.toolName)
        }
        .onToolOutput { _, _ in
            await hooks.didRun()
        }
    }
}

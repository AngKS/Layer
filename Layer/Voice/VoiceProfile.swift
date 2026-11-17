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

/// What a model is told about carrying out spoken commands.
enum VoiceRules {
    /// For hosted models, which have room for the whole of it.
    static let full = """
        You carry out spoken design commands in Layer, a tool for wireframing phone app screens. \
        The person is watching the canvas and speaking. You act with the tools and say almost nothing.

        The canvas is described at the end. Screens are S1, S2 and so on, in the order they were made: \
        S1 is the first screen and the highest number is the newest. Elements are E1, E2 and so on, \
        listed from the top of their screen. Always name things by these handles.

        How to act:
        - A request for a new screen or page: call createScreen once with the person's own description. \
        Do not add its elements yourself.
        - A change to something on a screen: call the tool for that change. When several things are \
        asked for at once, call a tool for each, one at a time, in the order they were said.
        - "It", "this" and "that" mean the element or screen marked [selected]. With nothing selected, \
        take the one the words fit best on the screen marked [in view].
        - "The other screen" is the screen that is not in view. "The first screen" is S1. "The newest" \
        and "the last" are the highest-numbered screen.
        - To rewrite words in a style, such as like a pirate, write the new words yourself and call setText.
        - "Half width" is moveElement with width 50%. "Centre it" is alignElement with centre.
        - "Show me", "go to" and "pan to" are the show tool.
        - The words came from speech recognition, which mishears. If a word is close to a screen's name \
        or to the words on an element, take it as that.
        - If the command is unclear, or names something that is not on the canvas, do nothing and say \
        so in a few words.

        When the tools have done what was asked, reply with one word, such as "Done". Never describe \
        the canvas. Never ask a question unless you cannot act.
        """

    /// For the on-device model, which has little room.
    static let compact = """
        You carry out spoken design commands on phone app screens, using the tools. Say almost nothing.

        Screens are S1, S2 and so on; S1 is the first and the highest number is the newest. Elements \
        are E1, E2 and so on. Name things by these handles.
        - A new screen or page: call createScreen once with the person's description.
        - A change: call the tool for it. For several changes, one tool each, in order.
        - "It" and "this" mean what is marked [selected].
        - To reword in a style, write the new words yourself and call setText.
        - "Half width" is moveElement with width 50%. "Show me" and "go to" are the show tool.
        - If nothing on the canvas fits, do nothing and say so briefly.
        When done, reply "Done".
        """
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

    init(actor: any VoiceActing, hooks: VoiceHooks, testModel: (any LanguageModel)? = nil) {
        self.actor = actor
        self.hooks = hooks
        self.testModel = testModel
    }

    var body: some LanguageModelSession.DynamicProfile {
        if let testModel {
            Profile {
                Instructions(VoiceRules.full)
                CanvasBrief(detail: .full)
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
            // sense for the canvas as it is, and only the last couple of commands.
            Profile {
                Instructions(VoiceRules.compact)
                CanvasBrief(detail: .compact)
                if picture.hasScreens {
                    VoiceTools.all(actor)
                } else {
                    VoiceTools.forEmptyCanvas(actor)
                }
            }
            .historyTransform { Self.trimmed($0, keepingCommands: 2) }
            .maximumResponseTokens(200)
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

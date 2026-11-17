import Foundation

/// Prompts that can be swapped without rebuilding, for tuning them.
///
/// In a debug build, when the environment variable `LAYER_PROMPT_DIR` names a folder, a
/// file in it called `<key>.txt` is used in place of the built-in text of that prompt.
/// The benchmark harnesses and `xcodebuild test` (as `TEST_RUNNER_LAYER_PROMPT_DIR`) both
/// pass it through, so a wording can be measured before it is written into the code.
/// Release builds always use the built-in text.
///
/// The keys are listed in `Key`. A prompt that has no file keeps its built-in text, so a
/// folder need only hold the prompts being tried.
enum PromptOverrides {
    enum Key: String, CaseIterable {
        /// What the sketch agent is told about reading close calls (`SketchPrompt.instructions`).
        case sketchInstructions = "sketch-instructions"
        /// What a board-naming model is told (`SketchPrompt.titleInstructions`).
        case titleInstructions = "title-instructions"
        /// How a screen is written down: its kinds and looks (`ScreenPrompt.grammar`).
        case screenGrammar = "screen-grammar"
        /// What makes a written screen good, for hosted models (`ScreenPrompt.rules(.full)`).
        case screenRules = "screen-rules"
        /// The same, for the on-device model (`ScreenPrompt.rules(.compact)`).
        case screenRulesCompact = "screen-rules-compact"
    }

    static func text(_ key: Key, default builtIn: @autoclosure () -> String) -> String {
        #if DEBUG
        if let folder = ProcessInfo.processInfo.environment["LAYER_PROMPT_DIR"], !folder.isEmpty,
           let text = try? String(contentsOf: URL(filePath: folder).appending(path: "\(key.rawValue).txt"), encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        #endif
        return builtIn()
    }
}

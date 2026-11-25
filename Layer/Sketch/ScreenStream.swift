import Foundation

/// A screen read as its outline is written: each time a finished line adds a leaf, the screen so far is handed on.
///
/// The half-written last line waits for the next, and so does a line that adds no leaf (an opener, a fence, a blank).
/// Each screen handed on is keyed by its path of `kind:ordinal` steps (`Outline`), which stay as lines come, with ids
/// fresh from the parse: the reconciler maps keys to the ids the screen already has. It builds on macOS, for the
/// screen harness.
struct OutlineStream: Sendable {
    private let tokens: DesignTokens
    /// The leaves of the last screen handed on.
    private var handedOn = 0

    /// `tokens` are the design's: the outline's spacings and a card's padding come from them, never from the model.
    init(tokens: DesignTokens) {
        self.tokens = tokens
    }

    /// The screen so far when it has more leaves than the last one handed on; nil otherwise.
    mutating func take(_ text: String, isComplete: Bool) -> LayerNode? {
        // A model wrote it, so its look's numbers are passed over (spec §14).
        var root = Outline.parse(text, isComplete: isComplete, tokens: tokens, readsLookNumbers: false)
        // Clamps and drops what the tree can't hold; never re-keys.
        _ = TreeValidator.fixGenerated(&root)
        guard root.leafCount > handedOn else { return nil }
        handedOn = root.leafCount
        return root
    }
}

/// What a model writes a screen in.
enum ScreenFormat: String, Sendable, CaseIterable {
    /// The indented outline (`Outline`): what every model writes (`ScreenGenerator.format(for:)`).
    case outline
    /// A2UI 1.0 in Layer's catalogue, a message per line (`A2UIPrompt`).
    case a2ui
}

/// A model's answer read as it is written, in the format the model was told to write: `ScreenGenerator` reads each
/// answer through one, and so does the screen harness.
enum ScreenReader {
    case outline(OutlineStream)
    case a2ui(A2UIStream)

    init(_ format: ScreenFormat, tokens: DesignTokens) {
        switch format {
        case .outline: self = .outline(OutlineStream(tokens: tokens))
        case .a2ui: self = .a2ui(A2UIStream(tokens: tokens))
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

    /// Once the answer is complete, what couldn't be brought in, but for buttons' actions: Layer never runs
    /// one, so that isn't something left out. The outline reads every line it can and passes over the rest.
    var leftOut: [A2UIDiagnostic] {
        guard case .a2ui(let a2ui) = self else { return [] }
        return a2ui.diagnostics.filter { $0.reason != .actionNotRun }
    }
}

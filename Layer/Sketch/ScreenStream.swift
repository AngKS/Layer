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

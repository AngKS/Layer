import CoreGraphics

/// Reads sketches with fixed geometric rules. It needs no model, so it settles every
/// clear-cut sketch, and is what the app falls back on when a provider can't answer.
struct RuleInterpreter: SketchInterpreter {
    func read(_ request: SketchRequest) async -> SketchReading {
        reading(for: request)
    }

    func reading(for request: SketchRequest) -> SketchReading {
        request.scoredReadings.first?.reading ?? .unknown
    }

    /// Whether the sketch sits so near one of the rules' dividing lines that its shape
    /// alone shouldn't decide. These are the sketches worth a provider's judgement.
    ///
    /// A two-signal trigger, not one global threshold: either the winning score itself is
    /// in the gray area (not confident even on its own), or it's confident but the runner-up
    /// is close behind — the case a single threshold misses, since a sketch can score 0.8
    /// and still have a 0.75 sitting right next to it. `reports/Fast and slow sketch
    /// recognition.md`, citing the Lenovo gesture-ambiguity patent (US10755027B2).
    func isCloseCall(_ request: SketchRequest) -> Bool {
        guard case .onScreen = request.placement else { return false }
        let scored = request.scoredReadings
        guard let top = scored.first else { return false }
        let lowConfidence = top.score < SketchConventions.closeCallConfidence
        let smallMargin = scored.count > 1 && (top.score - scored[1].score) < SketchConventions.closeCallMargin
        return lowConfidence || smallMargin
    }

    /// Without a model there is nothing to read meaning from, so the name says what kind
    /// of board it is. `board` is unused; `title(for:)` works from the design itself.
    func suggestTitle(for board: String) async -> String {
        "Untitled Board"
    }

    /// A plain name for a design: what its first screen says, or what device it is for.
    /// Its words are its leaves', screen by screen and then the open canvas's, each in the order its screen lists them.
    func title(for content: TreeContent) -> String {
        let texts = (content.screens.flatMap(\.root.leaves) + content.canvasLeaves)
            .filter { $0.kind == .title || $0.kind == .text }
            .map { $0.content.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let written = texts.first(where: { !$0.isEmpty && $0 != ElementKind.title.placeholder && $0 != ElementKind.text.placeholder }) {
            return String(written.prefix(40))
        }
        guard let screen = content.screens.first else { return "Untitled Board" }
        return "\(content.device(of: screen).name) Wireframe"
    }
}

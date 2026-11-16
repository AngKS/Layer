import CoreGraphics

/// Reads sketches with fixed geometric rules. It needs no model, so it settles every
/// clear-cut sketch, and is what the app falls back on when a provider can't answer.
struct RuleInterpreter: SketchInterpreter {
    func read(_ request: SketchRequest) async -> SketchReading {
        reading(for: request)
    }

    func reading(for request: SketchRequest) -> SketchReading {
        let candidates = request.candidates
        guard candidates.count > 1, case .onScreen(let local, let existing, let size) = request.placement else {
            return candidates.first ?? .unknown
        }
        if case .enclosure(let roundness, _) = request.observation.form {
            guard local.width >= local.height * SketchConventions.wideRatio else { return .element(.image) }
            return .element(roundness >= SketchConventions.pillRoundness ? .button : .textField)
        }
        let isShort = local.width / size.width < SketchConventions.shortFraction
        let hasTitle = existing.contains { $0.kind == .title }
        return .element(isShort && !hasTitle ? .title : .body)
    }

    /// Whether the sketch sits so near one of the rules' dividing lines that its shape
    /// alone shouldn't decide. These are the sketches worth a provider's judgement.
    func isCloseCall(_ request: SketchRequest) -> Bool {
        guard request.candidates.count > 1, case .onScreen(let local, let existing, let size) = request.placement else {
            return false
        }
        // An outline only has several candidates when it falls inside one of the bands.
        if request.observation.form.isEnclosure { return true }
        if SketchConventions.shortBand.contains(local.width / size.width) { return true }
        // What is left is a short squiggle: a title near the top of a screen without one,
        // body text on a screen that has one. Further down an untitled screen it could
        // be a title or a caption.
        let hasTitle = existing.contains { $0.kind == .title }
        return !hasTitle && local.midY > size.height * 0.4
    }

    /// Without a model there is nothing to read meaning from, so the name says what kind
    /// of board it is. `board` is unused; `title(for:)` works from the design itself.
    func suggestTitle(for board: String) async -> String {
        "Untitled Board"
    }

    /// A plain name for a design: what its first screen says, or what device it is for.
    func title(for content: DesignContent) -> String {
        let texts = (content.screens.flatMap(\.elements) + content.floating.map(\.element))
            .filter { $0.kind == .title || $0.kind == .text }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let written = texts.first(where: { !$0.isEmpty && $0 != ElementKind.title.placeholder && $0 != ElementKind.text.placeholder }) {
            return String(written.prefix(40))
        }
        guard let screen = content.screens.first else { return "Untitled Board" }
        return "\(screen.device.name) Wireframe"
    }
}

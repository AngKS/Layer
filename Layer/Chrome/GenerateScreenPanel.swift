import SwiftUI

/// How the screen being generated is getting on, floating at the bottom of the canvas:
/// thinking, writing (with how many elements so far), then done (or how many parts of it
/// couldn't be brought in, or still doesn't fit) or what went wrong.
struct GenerationStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let generation = model.generation {
            HStack(spacing: 10) {
                switch generation.phase {
                case .writing:
                    ProgressView()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(progressText(generation))
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.numericText())
                        Text(model.modelChoice.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Stop", role: .destructive) { model.stopGenerating() }
                        .buttonStyle(.bordered)
                case .finished:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(Self.finishedText(generation))
                        .font(.subheadline.weight(.semibold))
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .font(.subheadline)
                        .lineLimit(3)
                    Button("Dismiss", systemImage: "xmark") { model.dismissGeneration() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .glassEffect(.regular, in: .capsule)
            .animation(.snappy(duration: 0.2), value: generation)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier(generation))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func progressText(_ generation: AppModel.ScreenGeneration) -> String {
        if generation.isThinking { return "Thinking…" }
        return generation.elementCount == 0 ? "Writing…" : "Writing… \(Self.elements(generation.elementCount))"
    }

    /// What a finished generation says: how much it wrote, or, when some of what the model wrote
    /// couldn't be brought in, how much that was.
    static func finishedText(_ generation: AppModel.ScreenGeneration) -> String {
        guard generation.leftOut > 0 || generation.unfixed > 0 else { return "Wrote \(elements(generation.elementCount))" }
        var text = "Finished."
        if generation.leftOut > 0 {
            let parts = generation.leftOut == 1 ? "1 part" : "\(generation.leftOut) parts"
            text += " \(parts) couldn't be brought in."
        }
        if generation.unfixed > 0 { text += " \(UnfixedIssue.sentence(generation.unfixedIssues))." }
        return text
    }

    private static func elements(_ count: Int) -> String {
        count == 1 ? "1 element" : "\(count) elements"
    }

    private func identifier(_ generation: AppModel.ScreenGeneration) -> String {
        switch generation.phase {
        case .writing: generation.isThinking ? "generation.thinking" : "generation.progress"
        case .finished: "generation.finished"
        case .failed: "generation.failed"
        }
    }
}

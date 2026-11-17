import SwiftUI

/// Describe a screen and have the design's model write it. The panel closes as soon as
/// generating starts, so the screen can be watched filling in; `GenerationStatus` on the
/// canvas shows how far it has got.
struct GenerateScreenPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var description = ""
    @FocusState private var isFocused: Bool

    private var canGenerate: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate Screen")
                .font(.headline)
            TextField("Describe a screen, such as a sign-in screen with email and password", text: $description, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .accessibilityLabel("Screen description")
            Label(model.modelChoice.displayName, systemImage: model.modelChoice.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.isGenerating {
                Text("A screen is being written. Stop it, or wait for it to finish, to start another.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.generateScreen(from: description)
                dismiss()
            } label: {
                Label("Generate", systemImage: "wand.and.sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate)
        }
        .padding(16)
        .frame(width: 340)
        .onAppear { isFocused = true }
    }
}

/// How the screen being generated is getting on, floating at the bottom of the canvas:
/// thinking, writing (with how many elements so far), then done or what went wrong.
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
                    Text("Wrote \(elements(generation.elementCount))")
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
        return generation.elementCount == 0 ? "Writing…" : "Writing… \(elements(generation.elementCount))"
    }

    private func elements(_ count: Int) -> String {
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

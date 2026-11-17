import SwiftUI

/// Describe a screen and have the design's model write it. Its elements appear on the
/// canvas as the model writes them; this panel shows how far it has got.
struct GenerateScreenPanel: View {
    @Environment(AppModel.self) private var model
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
                .disabled(model.isGenerating)
                .accessibilityLabel("Screen description")
            Label(model.modelChoice.displayName, systemImage: model.modelChoice.symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let generation = model.generation {
                switch generation.phase {
                case .writing:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(generation.elementCount == 0 ? "Writing…" : "Writing… \(elements(generation.elementCount))")
                            .contentTransition(.numericText())
                        Spacer()
                        Button("Stop", role: .destructive) { model.stopGenerating() }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("generation.progress")
                case .finished:
                    Label("Wrote \(elements(generation.elementCount)).", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("generation.finished")
                case .failed(let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("generation.failed")
                }
            }

            Button {
                model.generateScreen(from: description)
            } label: {
                Label("Generate", systemImage: "wand.and.sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canGenerate)
        }
        .padding(16)
        .frame(width: 340)
        .animation(.snappy(duration: 0.2), value: model.generation)
        .onAppear {
            model.dismissGeneration()
            isFocused = true
        }
    }

    private func elements(_ count: Int) -> String {
        count == 1 ? "1 element" : "\(count) elements"
    }
}

import SwiftUI

/// The canvas settings' design tokens: the rhythm the space between things is made of, what a card is, and the sizes
/// of text, with a way back to Layer's own. The corner radii are kept with the design, and Reset Tokens puts them back
/// too, but have no row until something reads them (see `body`). What is typed is read as a file's tokens are read
/// (`DesignTokens.reading`, F25), and a run of changes is one Format step. Its number fields are a form's
/// (`numberFieldsOfAForm`): a squeeze over one scrubs it.
struct DesignTokensSection: View {
    @Environment(AppModel.self) private var model
    /// The rhythm as it is being typed.
    @State private var rhythmDraft = ""
    @FocusState private var isTypingRhythm: Bool

    var body: some View {
        let tokens = model.store.tree.settings.tokens
        VStack(alignment: .leading, spacing: 0) {
            PanelSection {
                Text("Design Tokens")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                PanelRow("Rhythm") {
                    TextField("8, 12, 16, 24, 32", text: $rhythmDraft)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($isTypingRhythm)
                        .onSubmit { isTypingRhythm = false }
                        .font(.system(size: 14).monospacedDigit())
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(Color(uiColor: .tertiarySystemFill), in: .rect(cornerRadius: 10))
                        .accessibilityLabel("Rhythm")
                }
                // The Radii row (S, M and L: `cornerRadii.small`, `.medium` and `.large`) returns here, under Rhythm,
                // once something draws or exports with the design's radii. Nothing reads them yet, so its fields would
                // change nothing a person sees (final review B-I3). The radii stay in the design and its file as read.
            }

            PanelSection {
                PanelRow("Card") {
                    size("P", "Card padding", \.card.padding, of: tokens)
                    size("R", "Card radius", \.card.radius, of: tokens)
                    ColorField(label: "Card fill", color: Binding(
                        get: { tokens.card.fill },
                        set: { fill in Self.edit(model) { $0.card.fill = fill } }
                    ))
                }
                PanelRow("Text") {
                    size("T", "Title size", \.textSizes.title, of: tokens)
                    size("B", "Body size", \.textSizes.body, of: tokens)
                    size("Aa", "Text size", \.textSizes.text, of: tokens)
                }
                let isStandard = tokens == Self.standard(keeping: tokens)
                Button("Reset Tokens", systemImage: "arrow.counterclockwise") { Self.reset(model) }
                    .foregroundStyle(isStandard ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .disabled(isStandard)
            }
        }
        .numberFieldsOfAForm(model)
        .onAppear { rhythmDraft = Self.text(of: tokens.rhythm) }
        .onChange(of: tokens.rhythm) { _, rhythm in
            if !isTypingRhythm { rhythmDraft = Self.text(of: rhythm) }
        }
        .onChange(of: isTypingRhythm) { _, typing in
            if !typing { keepRhythm(typed: rhythmDraft, over: tokens.rhythm) }
        }
        // The menu closed while the rhythm was being typed: what was typed is kept, as a number field keeps it.
        .onDisappear {
            if isTypingRhythm { keepRhythm(typed: rhythmDraft, over: tokens.rhythm) }
        }
    }

    /// The rhythm typed, read as a file's is, set when it differs from the design's, and shown as it was read.
    private func keepRhythm(typed text: String, over rhythm: [CGFloat]) {
        let read = Self.rhythm(typed: text)
        if read != rhythm { Self.edit(model) { $0.rhythm = read } }
        rhythmDraft = Self.text(of: read)
    }

    /// A field for one of the sizes, in whole points.
    private func size(_ unit: String, _ label: String, _ keyPath: WritableKeyPath<DesignTokens, CGFloat>,
                      of tokens: DesignTokens) -> some View {
        NumberField(unit, label: label, value: Binding(
            get: { tokens[keyPath: keyPath] },
            set: { value in Self.edit(model) { $0[keyPath: keyPath] = value } }
        ), range: 1...400)
    }

    // MARK: The edits

    /// Every change the section makes: to the design's tokens, read as a file's are (`DesignTokens.asRead`), in the
    /// Format panel's run of quick changes, so that a run of them is one step.
    static func edit(_ model: AppModel, _ change: (inout DesignTokens) -> Void) {
        model.adjusting {
            model.store.updateCanvas { settings in
                change(&settings.tokens)
                settings.tokens = settings.tokens.asRead
            }
        }
    }

    /// Layer's own tokens again. What a newer Layer saved with them, which this one can't reset, stays.
    static func reset(_ model: AppModel) {
        edit(model) { $0 = standard(keeping: $0) }
    }

    private static func standard(keeping tokens: DesignTokens) -> DesignTokens {
        var standard = DesignTokens.standard
        standard.unknownKeys = tokens.unknownKeys
        return standard
    }

    /// A rhythm as it is shown and typed: "8, 12, 16, 24, 32".
    static func text(of rhythm: [CGFloat]) -> String {
        rhythm.map { $0 == $0.rounded() && abs($0) < 1e15 ? String(Int($0)) : String(Double($0)) }.joined(separator: ", ")
    }

    /// The rhythm typed, read as a file's is (`DesignTokens.reading(rhythm:)`): what isn't a number is left out.
    static func rhythm(typed text: String) -> [CGFloat] {
        let numbers = text.split { $0 == "," || $0.isWhitespace }.compactMap { Double($0) }.map { CGFloat($0) }
        return DesignTokens.reading(rhythm: numbers)
    }
}

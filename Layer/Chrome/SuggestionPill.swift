import SwiftUI

/// "Did you mean…": a small pill under an element the Magic Pen made from a sketch that
/// could as well have been something else. Tapping it makes the element that instead.
/// Left alone it goes after a few seconds, so it never has to be answered.
struct SuggestionPill: View {
    @Environment(AppModel.self) private var model
    @State private var size = CGSize(width: 220, height: 36)

    var body: some View {
        if let suggestion = model.suggestion, let rect = model.viewRect(of: .element(suggestion.ref)) {
            HStack(spacing: 0) {
                Button {
                    withAnimation(.smooth(duration: 0.3)) { model.acceptSuggestion() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: suggestion.kind.symbol)
                            .font(.system(size: 13, weight: .medium))
                        Text("Did you mean \(Text(suggestion.kind.layerName).fontWeight(.semibold))?")
                            .font(.system(size: 14))
                    }
                    .foregroundStyle(.primary)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .frame(height: 36)
                    .contentShape(.rect)
                }
                .accessibilityLabel("Did you mean \(suggestion.kind.layerName)?")
                .accessibilityHint("Changes what the sketch became")

                Button {
                    withAnimation(.smooth(duration: 0.25)) { model.dismissSuggestion() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Keep it as it is")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: .capsule)
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .reportsChromeFrame("suggestion", to: model)
            .position(position(below: rect))
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            .id(suggestion.id)
        }
    }

    /// Centred under the element, or over it when there is no room below, and kept
    /// inside the view.
    private func position(below rect: CGRect) -> CGPoint {
        let view = model.canvasSize
        let gap: CGFloat = 10
        var y = rect.maxY + gap + size.height / 2
        if y + size.height / 2 > view.height - 12 {
            y = max(rect.minY - gap - size.height / 2, model.topBarBottom + 8 + size.height / 2)
        }
        let half = size.width / 2
        let x = min(max(rect.midX, 12 + half), max(view.width - 12 - half, 12 + half))
        return CGPoint(x: x, y: y)
    }
}

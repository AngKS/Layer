import SwiftUI

/// "Did you mean…": a small pill under an element the Magic Pen made from a sketch that
/// could as well have been something else. Tapping it makes the element that instead.
/// Left alone it goes after a few seconds, so it never has to be answered.
///
/// Once no such pill is up, the structure pass's offer shows the same way, under the things
/// it would line up: "Make a row?" (plan 5, call 12). One pill at a time.
struct SuggestionPill: View {
    @Environment(AppModel.self) private var model
    @State private var size = CGSize(width: 220, height: 36)

    var body: some View {
        if let suggestion = model.suggestion, let rect = model.viewRect(of: .element(suggestion.ref)) {
            pill(
                symbol: suggestion.kind.symbol,
                title: Text("Did you mean \(Text(suggestion.kind.layerName).fontWeight(.semibold))?"),
                label: "Did you mean \(suggestion.kind.layerName)?", hint: "Changes what the sketch became",
                dismissLabel: "Keep it as it is", below: rect,
                accept: { model.acceptSuggestion() }, dismiss: { model.dismissSuggestion() }
            )
            .id(suggestion.id)
        } else if let offer = model.shownStructureOffer, let rect = model.structureOfferViewRect {
            let kind = offer.structure.kind
            pill(
                symbol: kind.symbol, title: Text(offer.structure.title),
                label: offer.structure.title, hint: kind.hint,
                dismissLabel: "Keep them as drawn", below: rect,
                accept: { model.acceptStructureOffer() }, dismiss: { model.declineStructureOffer() }
            )
            .id(offer.id)
        }
    }

    private func pill(symbol: String, title: Text, label: String, hint: String, dismissLabel: String, below rect: CGRect,
                      accept: @escaping () -> Void, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.3)) { accept() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                    title
                        .font(.system(size: 14))
                }
                .foregroundStyle(.primary)
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 36)
                .contentShape(.rect)
            }
            .accessibilityLabel(label)
            .accessibilityHint(hint)

            Button {
                withAnimation(.smooth(duration: 0.25)) { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(dismissLabel)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .reportsChromeFrame("suggestion", to: model)
        .position(position(below: rect))
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
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

private extension StructureInference.Structure.Kind {
    var symbol: String {
        switch self {
        case .row: "rectangle.split.3x1"
        case .column, .cardColumn: "rectangle.split.1x2"
        case .grid: "square.grid.2x2"
        }
    }

    /// What VoiceOver says the offer does.
    var hint: String {
        switch self {
        case .row: String(localized: "Lays these out as a row")
        case .column, .cardColumn: String(localized: "Lays these out as a column")
        case .grid: String(localized: "Lays these out as a grid")
        }
    }
}

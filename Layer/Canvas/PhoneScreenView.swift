import SwiftUI

/// One node's own look, drawn to fill whatever frame it is given: a leaf, or a card's fill. What a container holds
/// is drawn by `NodeView`.
struct ElementView: View {
    let node: LayerNode
    /// Its parent lays it out: text is drawn whole and top-aligned, never shrunk (My call 18).
    let isLaidOut: Bool
    /// For a card with no fill or radius of its own, and text with no size of its own.
    let tokens: DesignTokens
    @Environment(ImageLibrary.self) private var images

    init(node: LayerNode, isLaidOut: Bool = false, tokens: DesignTokens = .standard) {
        self.node = node
        self.isLaidOut = isLaidOut
        self.tokens = tokens
    }

    struct TextFit: Equatable {
        var lineLimit: Int?
        var shrinks: Bool
        var vertical: VerticalAlignment
    }

    /// Laid out: no line limit, no shrinking, top-aligned. Otherwise today's per-kind values.
    static func textFit(for kind: ElementKind, isLaidOut: Bool) -> TextFit {
        if isLaidOut { return TextFit(lineLimit: nil, shrinks: false, vertical: .top) }
        switch kind {
        case .title: return TextFit(lineLimit: 1, shrinks: true, vertical: .center)
        case .text: return TextFit(lineLimit: nil, shrinks: false, vertical: .top)
        default: return TextFit(lineLimit: nil, shrinks: false, vertical: .center)
        }
    }

    /// How its text is fitted to its frame: `textFit(for:isLaidOut:)` for its kind.
    var textFit: TextFit { Self.textFit(for: node.kind, isLaidOut: isLaidOut) }

    var body: some View {
        let radius = node.resolvedCornerRadius(tokens: tokens)
        content
            .overlay {
                if node.hasBorder, node.resolvedBorderWidth > 0 {
                    RoundedRectangle(cornerRadius: node.hasCornerRadius ? radius : 0, style: .continuous)
                        .strokeBorder(node.resolvedBorderColor.color, lineWidth: node.resolvedBorderWidth)
                }
            }
            .modifier(ElementShadow(isOn: node.style.hasShadow))
            .opacity(node.resolvedOpacity)
    }

    private var alignment: Alignment {
        switch node.resolvedTextAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch node.resolvedTextAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    @ViewBuilder
    private var content: some View {
        let radius = node.resolvedCornerRadius(tokens: tokens)
        let tint = node.resolvedTint.color
        let frame = node.frame
        switch node.kind {
        case .title, .body, .text:
            let fit = textFit
            label
                .lineLimit(fit.lineLimit)
                .minimumScaleFactor(fit.shrinks ? 0.4 : 1)
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment.horizontal, vertical: fit.vertical))

        case .image, .avatar:
            if let picture = images.image(node.content.imageID) {
                Color.clear
                    .overlay { Image(uiImage: picture).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.imageTop, Theme.imageBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: node.kind == .avatar ? "person.fill" : "photo")
                            .font(.system(size: min(frame.width, frame.height) * (node.kind == .avatar ? 0.45 : 0.26), weight: .medium))
                            .foregroundStyle(.white)
                    }
            }

        case .button:
            let shape = RoundedRectangle(cornerRadius: radius)
            Group {
                switch node.resolvedButtonLook {
                case .filled: shape.fill(tint)
                case .bordered: shape.strokeBorder(tint, lineWidth: 1.5)
                case .plain: Color.clear
                }
            }
            .overlay {
                label
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 16)
            }

        case .textField:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.fieldFill)
                .overlay(alignment: alignment) {
                    label
                        .lineLimit(1)
                        .padding(.horizontal, 16)
                }

        case .divider:
            Rectangle()
                .fill(Theme.dividerLine)

        case .symbol:
            Image(systemName: SystemSymbol.resolve(node.content.symbol ?? "questionmark.square.dashed"))
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)

        case .shape:
            ShapeElementView(kind: node.content.shape ?? .rectangle, color: tint, isFilled: node.content.isOn, cornerRadius: radius)

        case .stickyNote:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tint)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .overlay(alignment: alignment) {
                    label
                        .multilineTextAlignment(textAlignment)
                        .padding(12)
                }

        case .checkbox:
            let side = min(frame.width, frame.height)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(node.content.isOn ? tint : .clear)
                .strokeBorder(node.content.isOn ? tint : Theme.controlOutline, lineWidth: max(1.5, side * 0.08))
                .overlay {
                    if node.content.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: side * 0.55, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

        case .radio:
            let side = min(frame.width, frame.height)
            Circle()
                .strokeBorder(node.content.isOn ? tint : Theme.controlOutline, lineWidth: max(1.5, side * 0.08))
                .overlay {
                    if node.content.isOn {
                        Circle()
                            .fill(tint)
                            .padding(side * 0.25)
                    }
                }

        case .progress:
            Capsule()
                .fill(Theme.dividerLine)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(tint)
                            .frame(width: proxy.size.width * CGFloat(node.resolvedValue))
                    }
                }
                .clipShape(.capsule)

        case .drawing:
            // A drawing that can be drawn on is on the ink canvas, where PencilKit draws
            // it. Locked, it is off that canvas, out of the eraser's reach, and drawn here.
            if node.isLocked { InkPicture(ink: node.content.ink) }

        case .card:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(node.resolvedFill(tokens: tokens).color)

        case .group:
            // A group draws nothing of its own: `NodeView` draws what it holds.
            EmptyView()

        case .toggle:
            // Drawn rather than a live `Toggle`, so that it scales with its frame.
            Capsule()
                .fill(node.content.isOn ? tint : Theme.dividerLine)
                .overlay(alignment: node.content.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .padding(frame.height * 0.07)
                }
        }
    }

    private var label: some View {
        Text(node.content.text)
            .font(.system(size: node.resolvedFontSize(tokens: tokens), weight: node.resolvedFontWeight.fontWeight))
            .foregroundStyle(node.resolvedTextColor.color)
    }
}

extension FontWeightChoice {
    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

/// An element's own shadow, there only when it has one: shadows are redrawn on every frame
/// of a zoom or pan, so elements without one shouldn't pay for an empty one.
private struct ElementShadow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.shadow(color: .black.opacity(0.18), radius: 10, y: 5)
        } else {
            content
        }
    }
}

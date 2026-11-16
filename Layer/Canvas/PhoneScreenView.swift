import SwiftUI

/// A device screen and its elements, laid out in the screen's logical points and then
/// scaled to its size on the canvas.
struct PhoneScreenView: View {
    let screen: DesignScreen
    var showsName = true

    var body: some View {
        let device = screen.device
        let size = device.size
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.09), radius: 28, y: 12)
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)

            statusBar(for: device)

            ForEach(screen.elements.filter { !$0.isHidden }) { element in
                ElementView(element: element)
                    .frame(width: element.frame.width, height: element.frame.height)
                    .offset(x: element.frame.minX, y: element.frame.minY)
                    .transition(.blurReplace)
            }

            if device.hasHomeIndicator {
                let width: CGFloat = size.width > 600 ? 260 : 134
                Capsule()
                    .fill(Theme.homeIndicator)
                    .frame(width: width, height: 5)
                    .offset(x: (size.width - width) / 2, y: size.height - 13)
            }

            if showsName {
                Text(screen.name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.label)
                    .fixedSize()
                    .offset(x: 4, y: -30)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .scaleEffect(screen.scale, anchor: .topLeading)
        .frame(width: size.width * screen.scale, height: size.height * screen.scale, alignment: .topLeading)
    }

    /// The time and status icons, around a Dynamic Island on devices that have one.
    private func statusBar(for device: DeviceFrame) -> some View {
        ZStack {
            if device.hasIsland {
                Capsule()
                    .fill(Theme.island)
                    .frame(width: 112, height: 33)
            }
            HStack {
                Text("9:41")
                    .font(.system(size: device.hasIsland ? 16 : 13, weight: .semibold))
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "cellularbars")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: device.hasIsland ? 14 : 12, weight: .semibold))
            }
            .foregroundStyle(Theme.statusGlyph)
            .padding(.horizontal, device.hasIsland ? 48 : 20)
        }
        .frame(width: device.size.width, height: device.hasIsland ? 33 : 18)
        .offset(y: device.hasIsland ? 15 : 3)
    }
}

/// An element on the open canvas, drawn at the scale it would have on a screen.
struct FloatingElementView: View {
    let floating: FloatingElement

    var body: some View {
        let frame = floating.element.frame
        if !floating.element.isHidden { placed(frame) }
    }

    private func placed(_ frame: CGRect) -> some View {
        ElementView(element: floating.element)
            .frame(width: frame.width, height: frame.height)
            .scaleEffect(floating.scale, anchor: .topLeading)
            .frame(width: frame.width * floating.scale, height: frame.height * floating.scale, alignment: .topLeading)
            .offset(x: floating.canvasFrame.minX, y: floating.canvasFrame.minY)
    }
}

/// One element, drawn to fill whatever frame it is given.
struct ElementView: View {
    let element: DesignElement
    @Environment(ImageLibrary.self) private var images

    var body: some View {
        let radius = element.resolvedCornerRadius
        content
            .overlay {
                if element.hasBorder, element.resolvedBorderWidth > 0 {
                    RoundedRectangle(cornerRadius: element.hasCornerRadius ? radius : 0, style: .continuous)
                        .strokeBorder(element.resolvedBorderColor.color, lineWidth: element.resolvedBorderWidth)
                }
            }
            .shadow(color: .black.opacity(element.hasShadow ? 0.18 : 0), radius: element.hasShadow ? 10 : 0, y: element.hasShadow ? 5 : 0)
            .opacity(element.resolvedOpacity)
    }

    private var alignment: Alignment {
        switch element.resolvedTextAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private var textAlignment: TextAlignment {
        switch element.resolvedTextAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    @ViewBuilder
    private var content: some View {
        let radius = element.resolvedCornerRadius
        switch element.kind {
        case .title:
            label
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)

        case .body:
            label
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)

        case .text:
            label
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Alignment(horizontal: alignment.horizontal, vertical: .top))

        case .image, .avatar:
            if let picture = images.image(element.imageID) {
                Color.clear
                    .overlay { Image(uiImage: picture).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.imageTop, Theme.imageBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: element.kind == .avatar ? "person.fill" : "photo")
                            .font(.system(size: min(element.frame.width, element.frame.height) * (element.kind == .avatar ? 0.45 : 0.26), weight: .medium))
                            .foregroundStyle(.white)
                    }
            }

        case .button:
            RoundedRectangle(cornerRadius: radius)
                .fill(element.tint.color)
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
            Image(systemName: element.symbol ?? "questionmark.square.dashed")
                .resizable()
                .scaledToFit()
                .foregroundStyle(element.tint.color)

        case .stickyNote:
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(element.tint.color)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                .overlay(alignment: alignment) {
                    label
                        .multilineTextAlignment(textAlignment)
                        .padding(12)
                }

        case .toggle:
            // Drawn rather than a live `Toggle`, so that it scales with its frame.
            Capsule()
                .fill(element.isOn ? element.tint.color : Theme.dividerLine)
                .overlay(alignment: element.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                        .padding(element.frame.height * 0.07)
                }
        }
    }

    private var label: some View {
        Text(element.text)
            .font(.system(size: element.resolvedFontSize, weight: element.resolvedFontWeight.fontWeight))
            .foregroundStyle(element.resolvedTextColor.color)
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

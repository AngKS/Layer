import SwiftUI

/// A device screen and its elements, laid out in the screen's logical points and then
/// scaled to its size on the canvas.
struct PhoneScreenView: View {
    let screen: DesignScreen

    var body: some View {
        let device = screen.device
        let size = device.size
        ZStack(alignment: .topLeading) {
            // One soft shadow and a hairline edge. Shadows are redrawn on every frame of a
            // zoom, and a wide one is the costliest thing on the canvas.
            RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                        .strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
                }

            statusBar(for: device)

            ForEach(screen.elements) { element in
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

            Text(screen.name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.label)
                .fixedSize()
                .offset(x: 4, y: -30)
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
        content
            .opacity(element.resolvedOpacity)
    }

    @ViewBuilder
    private var content: some View {
        let radius = element.resolvedCornerRadius
        switch element.kind {
        case .title:
            label
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .body:
            label
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .text:
            label
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        case .image:
            if let picture = images.image(element.imageID) {
                Color.clear
                    .overlay { Image(uiImage: picture).resizable().scaledToFill() }
                    .clipShape(.rect(cornerRadius: radius, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.imageTop, Theme.imageBottom], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: min(element.frame.width, element.frame.height) * 0.26, weight: .medium))
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
                .overlay(alignment: .leading) {
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
                .overlay {
                    label
                        .multilineTextAlignment(.center)
                        .padding(12)
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

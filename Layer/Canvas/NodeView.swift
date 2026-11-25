import SwiftUI

/// One node of the tree, drawn to fill whatever frame it is given, with everything it holds.
///
/// A container draws a card's look filling its frame, then each visible child in order, framed to its size, turned
/// about its centre and moved to its origin in this node's space. Nothing clips. A leaf is an `ElementView`.
///
/// Compared by value, and each child is drawn `.equatable()`: one edit draws again only the views on its path, the
/// node changed and the containers above it (`CanvasWork.nodeViewsBuilt`). It reads nothing from the model.
struct NodeView: View, Equatable {
    let node: LayerNode
    /// Its parent lays it out: text is drawn whole and top-aligned, never shrunk (My call 18).
    let isLaidOut: Bool
    /// For a card with no fill or radius of its own, and text with no size of its own.
    let tokens: DesignTokens

    init(node: LayerNode, isLaidOut: Bool = false, tokens: DesignTokens = .standard) {
        self.node = node
        self.isLaidOut = isLaidOut
        self.tokens = tokens
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.isLaidOut == b.isLaidOut && a.tokens == b.tokens && a.node == b.node
    }

    var body: some View {
        #if DEBUG
        let _ = CanvasWork.builtNodeView(node.id)
        #endif
        if node.isContainer {
            let laysOut = node.resolvedLayout != .free
            ZStack(alignment: .topLeading) {
                if node.kind == .card {
                    ElementView(node: node, tokens: tokens)
                }
                ForEach(node.children.filter { !$0.isHidden }) { child in
                    NodeView(node: child, isLaidOut: laysOut, tokens: tokens)
                        .equatable()
                        .placed(as: child)
                        .transition(.blurReplace)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ElementView(node: node, isLaidOut: isLaidOut, tokens: tokens)
        }
    }
}

/// A device screen and what is on it, drawn in the screen's own points and then scaled to its size on the canvas:
/// the device's chrome round its root's node view.
struct ScreenView: View, Equatable {
    @Environment(\.isCanvasZooming) private var isZooming
    let screen: TreeScreen
    /// The screen's device, which may be one of the design's own (`TreeContent.device(of:)`).
    let device: DeviceFrame
    let tokens: DesignTokens
    var showsName = true

    init(screen: TreeScreen, device: DeviceFrame, tokens: DesignTokens, showsName: Bool = true) {
        self.screen = screen
        self.device = device
        self.tokens = tokens
        self.showsName = showsName
    }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.showsName == b.showsName && a.device == b.device && a.tokens == b.tokens && a.screen == b.screen
    }

    var body: some View {
        let size = device.size
        ZStack(alignment: .topLeading) {
            // One soft shadow and a hairline edge. Shadows are redrawn on every frame of a
            // zoom, and a wide one is the costliest thing on the canvas.
            RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                .fill(.white)
                // Left out mid-zoom: a shadow is redrawn for every frame the scale changes.
                .shadow(color: .black.opacity(isZooming ? 0 : 0.08), radius: isZooming ? 0 : 16, y: isZooming ? 0 : 8)
                .overlay {
                    RoundedRectangle(cornerRadius: device.cornerRadius, style: .continuous)
                        .strokeBorder(.black.opacity(0.05), lineWidth: 0.5)
                }

            if device.family == .desktop {
                menuBar
            } else {
                statusBar
            }

            NodeView(node: screen.root, isLaidOut: false, tokens: tokens)
                .equatable()
                .placed(as: screen.root)

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

    /// A Mac's menu bar: the Apple menu and an app's menus on the left, status on the right.
    private var menuBar: some View {
        HStack(spacing: 20) {
            Image(systemName: "apple.logo")
                .font(.system(size: 15, weight: .medium))
            Text("App").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { menu in
                Text(menu).font(.system(size: 13))
            }
            Spacer()
            HStack(spacing: 14) {
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
                Text("Mon 9:41")
            }
            .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(Theme.statusGlyph)
        .padding(.horizontal, 18)
        .frame(width: device.size.width, height: device.safeTop)
        .background(.black.opacity(0.03))
    }

    /// The time and status icons, around a Dynamic Island on devices that have one.
    private var statusBar: some View {
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

/// A node on the open canvas, with everything it holds: framed to its own size, scaled by its scale, turned about its
/// scaled centre, at its origin on the canvas. Nothing for a hidden one.
struct CanvasNodeView: View, Equatable {
    let node: LayerNode
    let tokens: DesignTokens

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tokens == b.tokens && a.node == b.node
    }

    var body: some View {
        if !node.isHidden {
            let frame = node.frame
            // As the index draws it: a scale that isn't a size is 1.
            let scale = node.scale.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 1
            NodeView(node: node, isLaidOut: false, tokens: tokens)
                .equatable()
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: frame.width * scale, height: frame.height * scale, alignment: .topLeading)
                .rotationEffect(.degrees(node.drawnDegrees))
                .offset(x: frame.minX * scale, y: frame.minY * scale)
        }
    }
}

private extension LayerNode {
    /// Its own angle, as its transform turns it: one that isn't a number is upright.
    var drawnDegrees: Double { rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
}

private extension View {
    /// Drawn as `node` is in its parent's space: framed to its size, turned about its centre, then moved to its origin,
    /// as `LayerNode.transformToParent` places it.
    func placed(as node: LayerNode) -> some View {
        frame(width: node.frame.width, height: node.frame.height)
            .rotationEffect(.degrees(node.drawnDegrees))
            .offset(x: node.frame.minX, y: node.frame.minY)
    }
}

#if DEBUG
extension CanvasWork {
    /// `NodeView` bodies evaluated, by node: what a test reads for its own board's nodes, so that other suites' views
    /// drawn meanwhile don't add to it (F9). It only grows.
    private static var nodeViews: [UUID: Int] = [:]

    /// How many times a `NodeView` of the node with `id` has had its body evaluated.
    static func nodeViewsBuilt(of id: UUID) -> Int { nodeViews[id] ?? 0 }

    /// Counts one evaluation of a `NodeView`'s body.
    static func builtNodeView(_ id: UUID) {
        nodeViews[id, default: 0] += 1
    }
}
#endif

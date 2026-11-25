import CoreGraphics
import Foundation

// MARK: From a design

extension CanvasPicture {
    /// The picture of a design as it is now, read from its tree: each screen's root's children and the canvas's
    /// nodes, containers with what they hold under them. Anything not yet seen in this call is given its handle here,
    /// each container's before what it holds.
    @MainActor
    static func capture(from model: AppModel, handles: VoiceHandles) -> CanvasPicture {
        let visible = model.canvasSize == .zero ? CGRect.null : model.viewport.visibleRect(in: model.canvasSize)
        let tree = model.store.tree
        // With several things selected, "these" are all of them. A container selected is itself, and is marked so,
        // not what it holds (call 7).
        var selectedNodes: Set<UUID> = []
        var selectedScreens: Set<TreeScreen.ID> = []
        for thing in model.selectedThings {
            switch thing {
            case .element(let ref): selectedNodes.insert(ref.node)
            case .screen(let id): selectedScreens.insert(id)
            case .several: break
            }
        }

        /// A node placed in its parent's space, as `TreeIndex.ownPose(of:in:)` poses it: its upright frame in its
        /// host's own points and its summed angle. Its frame is told on a screen, not on the canvas.
        ///
        /// Ink is a node like any other in the design, and a board can hold hundreds of drawings. They are the
        /// Pencil's: a model is told nothing of them, so it has no handle to change one by, and the on-device
        /// model's room isn't spent on them.
        ///
        /// A node is told locked when it or a container above it is (`inLocked`), as voice refuses to move it then.
        func picture(of placed: TreeIndex.OwnSpace.Placed, _ node: LayerNode, isOnAScreen: Bool, inLocked: Bool = false) -> Element? {
            guard node.kind != .drawing else { return nil }
            let isLocked = inLocked || node.isLocked
            var element = Element(
                handle: handles.handle(forNode: node.id), kind: node.kind.layerName.lowercased(),
                text: node.kind == .symbol ? (node.content.symbol ?? "") : node.content.text.trimmingCharacters(in: .whitespacesAndNewlines),
                frame: isOnAScreen ? placed.frame : nil, rotation: Rotation.kept(placed.degrees) ?? 0,
                isSelected: selectedNodes.contains(node.id), isLocked: isLocked, isHidden: node.isHidden
            )
            if node.isContainer {
                element.isContainer = true
                element.layout = words(for: node.layout)
                element.children = inReadingOrder(node, in: placed.space).compactMap {
                    picture(of: $0.placed, $0.node, isOnAScreen: isOnAScreen, inLocked: isLocked)
                }
            } else {
                element.look = look(of: node)
            }
            return element
        }

        var whole = CanvasPicture()
        for screen in tree.screens {
            let device = tree.device(of: screen)
            let frame = screen.canvasFrame(on: device)
            let shown = frame.intersection(visible)
            let share = shown.isNull || frame.isEmpty ? 0 : Double(shown.width * shown.height / (frame.width * frame.height))
            // The handle of the screen comes before those of what is on it.
            let handle = handles.handle(forScreen: screen.id)
            let root = TreeIndex.OwnSpace.host.placing(screen.root).space
            whole.screens.append(Screen(
                handle: handle, name: screen.name, size: inWholePoints(device.size), visibleShare: share,
                isSelected: selectedScreens.contains(screen.id), isLocked: screen.isLocked == true,
                elements: inReadingOrder(screen.root, in: root).compactMap {
                    picture(of: $0.placed, $0.node, isOnAScreen: true, inLocked: screen.root.isLocked)
                },
                layout: words(for: screen.root.layout)
            ))
        }
        // As the canvas holds them, from the back: they have no screen to be read down.
        whole.loose = tree.canvas.compactMap { picture(of: TreeIndex.OwnSpace.host.placing($0), $0, isOnAScreen: false) }
        whole.devices = tree.settings.customDevices.map { "\"\($0.name)\" \($0.size.width.wholePoints)x\($0.size.height.wholePoints)" }
        return whole
    }

    /// A layout in words, as a model is told it: `row, spacing 12, centred`; `column, spacing 16`; `grid of 2, spacing
    /// 12`, or `grid of 2, spacing 12 across, 16 down` when the two differ; `overlay`; nil for free. Alignment is told
    /// only when it isn't the start: a row's top, centred, bottom or stretched, a column's left, centred, right or
    /// stretched.
    static func words(for layout: LayerNode.Layout?) -> String? {
        switch layout ?? .free {
        case .free:
            return nil
        case .stack(let stack):
            let isRow = stack.axis == .horizontal
            var words = "\(isRow ? "row" : "column"), spacing \(points(stack.spacing))"
            switch stack.alignment {
            case .start: break
            case .center: words += ", centred"
            case .end: words += isRow ? ", bottom" : ", right"
            case .fill: words += ", stretched"
            }
            return words
        case .grid(let grid):
            let spacing = grid.columnSpacing == grid.rowSpacing
                ? "spacing \(points(grid.columnSpacing))"
                : "spacing \(points(grid.columnSpacing)) across, \(points(grid.rowSpacing)) down"
            return "grid of \(grid.columns), \(spacing)"
        case .overlay:
            return "overlay"
        }
    }

    /// What a container or a screen's root holds, each placed in its own space, in the order it is read: a row's,
    /// column's, grid's or overlay's own order, which lays them out; otherwise from the top down, then from the left.
    private static func inReadingOrder(_ container: LayerNode, in space: TreeIndex.OwnSpace)
        -> [(node: LayerNode, placed: TreeIndex.OwnSpace.Placed)] {
        let placed = container.children.map { (node: $0, placed: space.placing($0)) }
        guard container.resolvedLayout == .free else { return placed }
        return placed.sorted { ($0.placed.frame.minY, $0.placed.frame.minX) < ($1.placed.frame.minY, $1.placed.frame.minX) }
    }

    /// The parts of a leaf's look worth telling a model, in the words that would set them.
    private static func look(of node: LayerNode) -> [String] {
        var look: [String] = []
        // The fill only shows on the kinds that are filled.
        let isFilled: Set<ElementKind> = [.button, .symbol, .stickyNote, .toggle, .checkbox, .radio, .progress, .avatar]
        if isFilled.contains(node.kind) { look.append("colour \(name(of: node.resolvedTint))") }
        if let textColour = node.style.textColor { look.append("text \(name(of: textColour))") }
        if let size = node.style.fontSize { look.append("\(points(size))pt") }
        if let weight = node.style.fontWeight, weight != .regular { look.append(weight.rawValue) }
        if node.kind == .button, let style = node.content.buttonLook, style != .filled { look.append(style.rawValue) }
        if [.toggle, .checkbox, .radio].contains(node.kind) { look.append(node.content.isOn ? "on" : "off") }
        if node.kind == .progress { look.append("\(points(CGFloat((node.content.value ?? 0.5) * 100)))%") }
        return look
    }

    /// A colour by the shortest name Layer knows it by, or else as a hex code.
    private static func name(of colour: RGBColor) -> String {
        ColourWords.named.filter { $0.value == colour }.map(\.key).min { ($0.count, $0) < ($1.count, $1) } ?? colour.hex
    }

    /// A number from the design to the nearest whole point, said as `wholePoints` says it: never a trap, whatever a
    /// file held.
    private static func points(_ value: CGFloat) -> Int { value.rounded().wholePoints }

    /// A size in whole points (`wholePoints`): a device a file held as too large for a whole number is told as the
    /// largest length a design has, as the device picker says it.
    private static func inWholePoints(_ size: CGSize) -> CGSize {
        CGSize(width: CGFloat(size.width.wholePoints), height: CGFloat(size.height.wholePoints))
    }
}

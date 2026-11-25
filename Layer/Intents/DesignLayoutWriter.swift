import CoreGraphics
import Foundation

/// A design as JSON, with every position and size, for a model or a shortcut that edits a design and needs to see
/// exactly where things are and what holds them. Screens give their device, canvas position and scale, and how their
/// root lays out what it holds. Read from the tree: a node's frame is its host shape, the upright frame centred on what
/// is seen (screen points on a screen, canvas points on the canvas), with the angle it is seen at as its `rotation`, and
/// it is locked or hidden as it is with the containers above it.
///
/// `elements` and `canvasElements` are the leaves, each with every key it had before containers were written, so what a
/// shortcut read there it reads still (call 4); each `id` is the identifier its entity goes by. The containers, groups
/// and cards, are listed beside them, in `containers` and `canvasContainers`, with their children's ids.
enum DesignLayoutWriter {
    /// Today's JSON, plus the tree (call 4). Leaves gain "sizing", "parent" and "rotation"; screens gain "deviceName",
    /// "layout", "padding" and "containers"; the top level gains "canvasContainers", and the canvas "newScreenDeviceName".
    /// "device" and "newScreenDevice" are the device's id.
    /// Frames are host shapes: screen points on screens, canvas points on the canvas (call 3). Sorted keys.
    static func json(for snapshot: DesignSnapshot, ink: (count: Int, bounds: CGRect?)? = nil, hasUnreadSketch: Bool = false) -> String {
        let content = snapshot.content
        let writer = Writer(design: snapshot.id, index: TreeIndex(content))
        let canvas = writer.held(content.canvas, on: .canvas)
        var root: [String: Any] = [
            "design": snapshot.name,
            "id": snapshot.id,
            "canvas": settings(content.settings),
            "screens": content.screens.map { writer.screen($0, on: content.device(of: $0)) },
            "canvasElements": canvas.leaves,
            "canvasContainers": canvas.containers,
        ]
        if let ink {
            var drawing: [String: Any] = ["strokes": ink.count]
            if let bounds = ink.bounds { drawing["bounds"] = rect(bounds) }
            root["ink"] = drawing
        }
        if hasUnreadSketch { root["unreadMagicPenSketch"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func settings(_ settings: CanvasSettings) -> [String: Any] {
        [
            "background": settings.resolvedBackground.hex,
            "showsGrid": settings.showsGrid,
            "gridStyle": settings.gridStyle.rawValue,
            "gridSpacing": tenthWithinReach(settings.gridSpacing),
            "snapsToGuides": settings.snapsToGuides,
            "snapsToGrid": settings.snapsToGrid,
            "showsMeasurements": settings.showsMeasurements,
            "showsFrameNames": settings.showsFrameNames,
            // Its id, as a screen's "device" is: a built-in's as before, and the design's own device's where the iPhone
            // it falls back to was written; with the name Siri and Shortcuts know it by.
            "newScreenDevice": settings.sketchDevice.id,
            "newScreenDeviceName": DeviceChoice.displayName(of: settings.sketchDevice),
            // The option's value, which Update Canvas Settings takes, not the layout's own name.
            "codeLayout": CodeLayoutOption(settings.code.layout).rawValue,
            "codeIncludesPreview": settings.code.includesPreview,
            "codeUsesNavigationTitle": settings.code.usesNavigationTitle,
        ]
    }

    private static func rect(_ rect: CGRect) -> [String: Double] {
        ["x": tenthWithinReach(rect.minX), "y": tenthWithinReach(rect.minY),
         "width": tenthWithinReach(rect.width), "height": tenthWithinReach(rect.height)]
    }

    /// Rounded to a tenth of a point, which is all a layout needs, and within the farthest written. A file can hold any
    /// number: what isn't one is written as 0, and what is past any design's length as the farthest one written, as the
    /// canvas picture tells them, so that nothing infinite reaches `JSONSerialization`, which ends the app rather than
    /// throwing. For frames, sizes and looks; a layout, padding or sizing is written as the file writes it
    /// (`Writer.finiteOrNil(_:)`).
    fileprivate static func tenthWithinReach(_ value: CGFloat) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(Double(value), -farthest), farthest) * 10).rounded() / 10
    }

    /// The farthest a number is written: 1e12 points, as the canvas picture's.
    private static let farthest: Double = 1_000_000_000_000

    /// An angle seen, from 0 up to 360, to a tenth of a degree. Nil when it is upright.
    fileprivate static func turn(_ degrees: Double) -> Double? {
        let tenth = (Rotation.normalized(degrees) * 10).rounded() / 10
        return tenth == 0 || tenth == 360 ? nil : tenth
    }
}

/// Writes one design's nodes, each found in the design's index.
private struct Writer {
    typealias Host = NodeRef.Host

    /// What a screen's root or the open canvas holds: its leaves and its containers, each depth first and back to front,
    /// so each container comes before what it holds.
    struct Held {
        var leaves: [[String: Any]] = []
        var containers: [[String: Any]] = []
    }

    let design: String
    let index: TreeIndex

    init(design: String, index: TreeIndex) {
        self.design = design
        self.index = index
    }

    func screen(_ screen: TreeScreen, on device: DeviceFrame) -> [String: Any] {
        let contents = held(screen.root.children, on: .screen(screen.id))
        return [
            "id": EntityKey.screen(design: design, screen: screen.id),
            "name": screen.name,
            "device": device.id,
            "deviceName": DeviceChoice.displayName(of: device),
            "width": DesignLayoutWriter.tenthWithinReach(device.size.width),
            "height": DesignLayoutWriter.tenthWithinReach(device.size.height),
            "x": DesignLayoutWriter.tenthWithinReach(screen.origin.x),
            "y": DesignLayoutWriter.tenthWithinReach(screen.origin.y),
            "scale": DesignLayoutWriter.tenthWithinReach(screen.scale * 100),
            "locked": screen.isLocked == true,
            "safeAreaTop": DesignLayoutWriter.tenthWithinReach(device.safeTop),
            "safeAreaBottom": DesignLayoutWriter.tenthWithinReach(device.safeBottom),
            "layout": Self.written(screen.root.layout ?? .free),
            "padding": Self.written(screen.root.padding),
            "elements": contents.leaves,
            "containers": contents.containers,
        ]
    }

    /// What `nodes`, the children of a screen's root or the canvas's nodes, hold: none of them is in a container.
    func held(_ nodes: [LayerNode], on host: Host) -> Held {
        var held = Held()
        add(nodes, in: nil, on: host, to: &held)
        return held
    }

    private func add(_ nodes: [LayerNode], in parent: UUID?, on host: Host, to held: inout Held) {
        for node in nodes {
            if node.isContainer {
                held.containers.append(container(node, in: parent, on: host))
                add(node.children, in: node.id, on: host, to: &held)
            } else {
                held.leaves.append(leaf(node, in: parent, on: host))
            }
        }
    }

    private func id(_ node: UUID, on host: Host) -> String {
        EntityKey.element(design: design, host: host, element: node)
    }

    /// What every node says: what it is, its host shape's frame and angle, its sizing, the container it is in, and its
    /// lock and hide with the containers above it.
    private func placed(_ node: LayerNode, in parent: UUID?, on host: Host) -> [String: Any] {
        let entry = index[node.id]
        let frame = entry?.hostShape.rect ?? node.frame
        var info: [String: Any] = [
            "id": id(node.id, on: host),
            "kind": node.kind.rawValue,
            "name": node.displayName,
            "x": DesignLayoutWriter.tenthWithinReach(frame.minX),
            "y": DesignLayoutWriter.tenthWithinReach(frame.minY),
            "width": DesignLayoutWriter.tenthWithinReach(frame.width),
            "height": DesignLayoutWriter.tenthWithinReach(frame.height),
            "sizing": Self.written(width: node.width, height: node.height),
        ]
        if let parent { info["parent"] = id(parent, on: host) }
        if let turn = DesignLayoutWriter.turn(entry?.hostShape.degrees ?? node.rotation ?? 0) { info["rotation"] = turn }
        if entry?.isLockedWithAncestors ?? node.isLocked { info["locked"] = true }
        if entry?.isHiddenWithAncestors ?? node.isHidden { info["hidden"] = true }
        return info
    }

    /// A group's or a card's entry: how it lays out what it holds, and what it holds, in order.
    private func container(_ node: LayerNode, in parent: UUID?, on host: Host) -> [String: Any] {
        var info = placed(node, in: parent, on: host)
        info["layout"] = Self.written(node.layout ?? .free)
        info["padding"] = Self.written(node.padding)
        info["children"] = node.children.map { id($0.id, on: host) }
        return info
    }

    /// A leaf's entry: its words and its look.
    private func leaf(_ node: LayerNode, in parent: UUID?, on host: Host) -> [String: Any] {
        var info = placed(node, in: parent, on: host)
        let style = node.style, content = node.content
        let traits = node.kind.spec.traits
        info["colour"] = node.resolvedTint.hex
        if node.kind.hasText { info["text"] = content.text }
        if let symbol = content.symbol { info["symbol"] = symbol }
        if node.kind == .shape { info["shape"] = (content.shape ?? .rectangle).rawValue }
        if content.imageID != nil { info["hasPicture"] = true }
        if let fontSize = style.fontSize { info["fontSize"] = DesignLayoutWriter.tenthWithinReach(fontSize) }
        if let weight = style.fontWeight { info["fontWeight"] = weight.rawValue }
        if let textColor = style.textColor { info["textColour"] = textColor.hex }
        if let alignment = style.textAlignment { info["textAlignment"] = alignment.rawValue }
        if let radius = style.cornerRadius { info["cornerRadius"] = DesignLayoutWriter.tenthWithinReach(radius) }
        if let opacity = style.opacity { info["opacity"] = opacity }
        if let width = style.borderWidth, width > 0 {
            info["borderWidth"] = DesignLayoutWriter.tenthWithinReach(width)
            if let colour = style.borderColor { info["borderColour"] = colour.hex }
        }
        if style.hasShadow { info["shadow"] = true }
        if traits.contains(.onState) { info["on"] = content.isOn }
        if traits.contains(.value) { info["progress"] = content.value ?? 0.5 }
        if traits.contains(.buttonLooks) { info["buttonStyle"] = (content.buttonLook ?? .filled).rawValue }
        return info
    }

    // MARK: Layout, padding and sizing

    // Each written with the keys and values `design.json` gives it (`LayerNode+Coding.swift`), as its encoder writes
    // them and JSON reads them back. A part holding a number that isn't finite, which the encoder refuses, is an empty
    // object.

    private static func written(_ layout: LayerNode.Layout) -> [String: Any] {
        switch layout {
        case .free:
            return ["type": "free"]
        case .stack(let stack):
            guard let spacing = finiteOrNil(stack.spacing) else { return [:] }
            return ["type": "stack", "axis": stack.axis.rawValue, "spacing": spacing, "alignment": stack.alignment.rawValue,
                    "justify": stack.justify.rawValue]
        case .grid(let grid):
            guard let columnSpacing = finiteOrNil(grid.columnSpacing), let rowSpacing = finiteOrNil(grid.rowSpacing) else {
                return [:]
            }
            return ["type": "grid", "columns": grid.columns, "columnSpacing": columnSpacing, "rowSpacing": rowSpacing,
                    "horizontal": grid.alignment.horizontal.rawValue, "vertical": grid.alignment.vertical.rawValue]
        case .overlay(let alignment):
            return ["type": "overlay", "horizontal": alignment.horizontal.rawValue, "vertical": alignment.vertical.rawValue]
        }
    }

    private static func written(_ padding: LayerNode.Padding) -> [String: Any] {
        guard let top = finiteOrNil(padding.top), let leading = finiteOrNil(padding.leading),
              let bottom = finiteOrNil(padding.bottom), let trailing = finiteOrNil(padding.trailing) else { return [:] }
        return ["top": top, "leading": leading, "bottom": bottom, "trailing": trailing]
    }

    /// Both axes' sizing, as a node's `width` and `height` are saved: empty when either can't be written.
    private static func written(width: LayerNode.Sizing, height: LayerNode.Sizing) -> [String: Any] {
        guard let width = written(width), let height = written(height) else { return [:] }
        return ["width": width, "height": height]
    }

    private static func written(_ sizing: LayerNode.Sizing) -> [String: Any]? {
        var fields: [String: Any]
        switch sizing.mode {
        case .fit:
            fields = ["mode": "fit"]
        case .fill(let weight):
            guard let weight = finiteOrNil(weight) else { return nil }
            fields = ["mode": "fill", "weight": weight]
        case .fixed:
            fields = ["mode": "fixed"]
        }
        if let minimum = sizing.minimum {
            guard let minimum = finiteOrNil(minimum) else { return nil }
            fields["min"] = minimum
        }
        if let maximum = sizing.maximum {
            guard let maximum = finiteOrNil(maximum) else { return nil }
            fields["max"] = maximum
        }
        return fields
    }

    /// A number of a layout, padding or sizing as `design.json`'s encoder writes it and JSON reads it back: as it is,
    /// where a negative zero is 0. Nil when it isn't finite, which the encoder refuses, so its part is written empty.
    /// Not rounded or kept within reach, as frames are (`DesignLayoutWriter.tenthWithinReach(_:)`).
    private static func finiteOrNil(_ value: CGFloat) -> Double? {
        guard value.isFinite else { return nil }
        return value == 0 ? 0 : Double(value)
    }
}

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
            "gridSpacing": number(settings.gridSpacing),
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
        ["x": number(rect.minX), "y": number(rect.minY), "width": number(rect.width), "height": number(rect.height)]
    }

    /// Rounded to a tenth of a point, which is all a layout needs.
    fileprivate static func number(_ value: CGFloat) -> Double {
        (Double(value) * 10).rounded() / 10
    }

    /// An angle seen, from 0 up to 360, to a tenth of a degree. Nil when it is upright.
    fileprivate static func turn(_ degrees: Double) -> Double? {
        let tenth = (Rotation.normalized(degrees) * 10).rounded() / 10
        return tenth == 0 || tenth == 360 ? nil : tenth
    }
}

/// Writes one design's nodes, each found in the design's index.
private struct Writer {
    typealias Host = DesignStore.ElementRef.Host

    /// What a screen's root or the open canvas holds: its leaves and its containers, each depth first and back to front,
    /// so each container comes before what it holds.
    struct Held {
        var leaves: [[String: Any]] = []
        var containers: [[String: Any]] = []
    }

    /// Both axes' sizing, as a node's `width` and `height` are saved.
    private struct Sizes: Encodable {
        var width: LayerNode.Sizing
        var height: LayerNode.Sizing
    }

    let design: String
    let index: TreeIndex
    /// Writes a layout, padding or sizing as `design.json` does.
    private let encoder = JSONEncoder()

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
            "width": DesignLayoutWriter.number(device.size.width),
            "height": DesignLayoutWriter.number(device.size.height),
            "x": DesignLayoutWriter.number(screen.origin.x),
            "y": DesignLayoutWriter.number(screen.origin.y),
            "scale": DesignLayoutWriter.number(screen.scale * 100),
            "locked": screen.isLocked == true,
            "safeAreaTop": DesignLayoutWriter.number(device.safeTop),
            "safeAreaBottom": DesignLayoutWriter.number(device.safeBottom),
            "layout": written(screen.root.layout ?? .free),
            "padding": written(screen.root.padding),
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
            "x": DesignLayoutWriter.number(frame.minX),
            "y": DesignLayoutWriter.number(frame.minY),
            "width": DesignLayoutWriter.number(frame.width),
            "height": DesignLayoutWriter.number(frame.height),
            "sizing": written(Sizes(width: node.width, height: node.height)),
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
        info["layout"] = written(node.layout ?? .free)
        info["padding"] = written(node.padding)
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
        if let fontSize = style.fontSize { info["fontSize"] = DesignLayoutWriter.number(fontSize) }
        if let weight = style.fontWeight { info["fontWeight"] = weight.rawValue }
        if let textColor = style.textColor { info["textColour"] = textColor.hex }
        if let alignment = style.textAlignment { info["textAlignment"] = alignment.rawValue }
        if let radius = style.cornerRadius { info["cornerRadius"] = DesignLayoutWriter.number(radius) }
        if let opacity = style.opacity { info["opacity"] = opacity }
        if let width = style.borderWidth, width > 0 {
            info["borderWidth"] = DesignLayoutWriter.number(width)
            if let colour = style.borderColor { info["borderColour"] = colour.hex }
        }
        if style.hasShadow { info["shadow"] = true }
        if traits.contains(.onState) { info["on"] = content.isOn }
        if traits.contains(.value) { info["progress"] = content.value ?? 0.5 }
        if traits.contains(.buttonLooks) { info["buttonStyle"] = (content.buttonLook ?? .filled).rawValue }
        return info
    }

    /// `part` as `design.json` writes it.
    private func written(_ part: some Encodable) -> Any {
        guard let data = try? encoder.encode(part), let object = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return object
    }
}

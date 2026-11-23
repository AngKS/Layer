import CoreGraphics
import Foundation
import os

/// Writes a screen of the design's tree out as a SwiftUI view (spec §7).
///
/// In Structure, the default, the code follows the tree. A row or column is an `HStack` or
/// `VStack`, a grid a `Grid` of `GridRow`s, an overlay a `ZStack`, and a card its stack, padded,
/// on its background. A column screen is a `VStack` inside the safe area, padded by its device's
/// margin. These use the design's token names (`DesignTokens.swift`). What is placed freely, a
/// sketched screen above all, is read in reading order as it always was (call 12): see
/// `SwiftUICodeGenerator+Inference.swift`. Exact positions puts every leaf at its place on the
/// screen. Hidden nodes, drawings and the open canvas are left out.
enum SwiftUICodeGenerator {
    /// What a screen's code needs from its design. Cheap to make: per screen, not per node.
    struct Context: Equatable, Sendable {
        var tokens: DesignTokens
        var devices: [TreeScreen.ID: DeviceFrame]
        var typeNames: [TreeScreen.ID: String]
        /// For each column screen, its margin's token: "margin", or "marginIPhone" and so on when
        /// the column screens' devices' margins differ.
        var marginNames: [TreeScreen.ID: String]
        /// For each column screen whose device has a widest column, that width's token, named likewise.
        var maxContentWidthNames: [TreeScreen.ID: String]

        init(_ content: TreeContent) {
            tokens = content.settings.tokens
            var devices: [TreeScreen.ID: DeviceFrame] = [:]
            for screen in content.screens where devices[screen.id] == nil {
                devices[screen.id] = content.device(of: screen)
            }
            self.devices = devices
            typeNames = SwiftUICodeGenerator.typeNames(for: content.screens)
            let columns = content.screens.filter { $0.root.resolvedLayout != .free }.map { (id: $0.id, device: content.device(of: $0)) }
            marginNames = Self.names("margin", for: columns) { $0.margin }
            maxContentWidthNames = Self.names("maxContentWidth", for: columns) { $0.maxContentWidth }
        }

        func device(of screen: TreeScreen) -> DeviceFrame { devices[screen.id] ?? screen.device }

        func typeName(of screen: TreeScreen) -> String { typeNames[screen.id] ?? SwiftUICodeGenerator.typeName(of: screen) }
    }

    /// "Screen 1" becomes `Screen1`, as `DesignScreen.typeName` names it.
    static func typeName(of screen: TreeScreen) -> String {
        DesignScreen.typeName(forScreenNamed: screen.name)
    }

    /// The name of each screen's view, told apart where two would be the same: "Screen 2"
    /// again after a screen was deleted, or "Sign In" beside "Sign-In". Two files declaring
    /// the same view don't compile in one target. Names that differ only in case are told
    /// apart too, since a Mac's disk doesn't tell their files apart. The first keeps its name.
    static func typeNames(for screens: [TreeScreen]) -> [TreeScreen.ID: String] {
        var used: Set<String> = []
        var names: [TreeScreen.ID: String] = [:]
        for screen in screens {
            let typeName = typeName(of: screen)
            var name = typeName
            var number = 2
            while used.contains(name.lowercased()) {
                name = "\(typeName)\(number)"
                number += 1
            }
            used.insert(name.lowercased())
            names[screen.id] = name
        }
        return names
    }

    /// The file a screen is written to, named after its view.
    static func fileName(for screen: TreeScreen, in context: Context) -> String {
        context.typeName(of: screen) + ".swift"
    }

    /// One screen's view, then the design's `enum DesignTokens` when the view uses a token name,
    /// so it compiles on its own. What Share, the code panel and Siri give. A free screen of
    /// leaves uses none, so it is today's code.
    static func code(for screen: TreeScreen, in context: Context, settings: CodeSettings) -> String {
        let view = view(for: screen, in: context, settings: settings)
        var lines = view.lines
        if view.usesTokens { lines += [""] + tokenEnum(in: context) }
        lines += preview(for: screen, in: context, settings: settings)
        return lines.joined(separator: "\n")
    }

    /// `DesignTokens.swift` first when any view uses a token name, then one file per screen,
    /// each named after its view; the views without the enum.
    static func files(for content: TreeContent, settings: CodeSettings) -> [(name: String, source: String)] {
        let context = Context(content)
        var usesTokens = false
        var files: [(name: String, source: String)] = content.screens.map { screen in
            let view = view(for: screen, in: context, settings: settings)
            usesTokens = usesTokens || view.usesTokens
            return (fileName(for: screen, in: context), (view.lines + preview(for: screen, in: context, settings: settings)).joined(separator: "\n"))
        }
        if usesTokens { files.insert(tokensFile(in: context), at: 0) }
        return files
    }

    /// A screen's view, and whether it uses a token name.
    private static func view(for screen: TreeScreen, in context: Context, settings: CodeSettings) -> (lines: [String], usesTokens: Bool) {
        #if DEBUG
        CodeWork.wrote(screen.id)
        #endif
        var writer = ScreenWriter(screen: screen, context: context, settings: settings)
        let body = writer.body()
        var lines = ["import SwiftUI", "", "struct \(context.typeName(of: screen)): View {", "    var body: some View {"]
        lines += body.map { "        " + $0 }
        lines += ["    }", "}"]
        return (lines, writer.usesTokens)
    }

    /// The preview a file ends with, unless asked not to: a custom frame's at its size.
    private static func preview(for screen: TreeScreen, in context: Context, settings: CodeSettings) -> [String] {
        guard settings.includesPreview else { return [] }
        let device = context.device(of: screen)
        let opening = device.isCustom
            ? "#Preview(traits: .fixedLayout(width: \(number(device.size.width)), height: \(number(device.size.height)))) {"
            : "#Preview {"
        return ["", opening, "    \(context.typeName(of: screen))()", "}"]
    }

    static func indented(_ lines: [String]) -> [String] {
        lines.map { "    " + $0 }
    }
}

// MARK: - One screen

extension SwiftUICodeGenerator {
    /// Writes one screen's body, and notes whether it used a token name.
    struct ScreenWriter {
        let screen: TreeScreen
        let context: Context
        let settings: CodeSettings
        let device: DeviceFrame
        /// The topmost title, written as the navigation title rather than as a view of its own.
        private(set) var navigationTitle: LayerNode?
        /// Whether the code names one of the design's tokens.
        var usesTokens = false

        init(screen: TreeScreen, context: Context, settings: CodeSettings) {
            self.screen = screen
            self.context = context
            self.settings = settings
            device = context.device(of: screen)
            if settings.usesNavigationTitle { navigationTitle = firstTitle(in: screen.root) }
        }

        /// Whether a node is in the code: one that shows, isn't ink and isn't the navigation title.
        func isWritten(_ node: LayerNode) -> Bool {
            !node.isHidden && node.kind != .drawing && node.id != navigationTitle?.id
        }

        /// The first title in reading order: a free container's items top to bottom, a laid-out one's children in order.
        private func firstTitle(in container: LayerNode) -> LayerNode? {
            let children = container.resolvedLayout == .free ? items(of: container).map(\.node) : container.children.filter(isWritten)
            for child in children {
                if child.kind == .title { return child }
                if child.isContainer, let found = firstTitle(in: child) { return found }
            }
            return nil
        }

        mutating func body() -> [String] {
            var root = switch settings.layout {
            case .structure: screen.root.resolvedLayout == .free ? freeScreen(belowNavigationBar: navigationTitle != nil) : columnScreen()
            case .absolute: absolute()
            }
            if let navigationTitle {
                root = ["NavigationStack {"] + SwiftUICodeGenerator.indented(root + [".navigationTitle(\(SwiftUICodeGenerator.literal(navigationTitle.content.text)))"]) + ["}"]
            }
            return root
        }
    }
}

// MARK: - Rows, columns, grids, overlays and cards

extension SwiftUICodeGenerator.ScreenWriter {
    /// A screen whose root lays its children out: its block inside the safe area, which SwiftUI
    /// keeps clear, padded by its device's margin, across the column, at most as wide as its
    /// device's widest column, and from the top.
    mutating func columnScreen() -> [String] {
        let root = screen.root
        var lines = block(of: root)
        if let name = context.marginNames[screen.id] {
            lines.append(".padding(\(token(name)))")
        } else {
            lines.append(".padding(\(Generator.number(device.margin)))")
        }
        if let edge = Generator.alignmentName(horizontal: Generator.contentAlignment(of: root).horizontal, vertical: nil) {
            lines.append(".frame(maxWidth: .infinity, alignment: .\(edge))")
        }
        if let name = context.maxContentWidthNames[screen.id] {
            lines.append(".frame(maxWidth: \(token(name)))")
        }
        lines.append(".frame(maxHeight: .infinity, alignment: .top)")
        return lines
    }

    /// A container below the screen root as one view, its modifiers indented: a free one inferred
    /// inside its content box and framed to its size; a laid-out one's block, held to its own size
    /// where it fits it, its padding and `frames` (unindented); then a card's background, and its
    /// turn. `stretched` says which of its axes its stack stretches it across (F6).
    mutating func container(_ node: LayerNode, frames: [String], stretched: (across: Bool, down: Bool),
                            rotation: Double?) -> [String] {
        var lines = node.resolvedLayout == .free
            ? freeContainer(node)
            : block(of: node) + heldToItsSize(node, stretched: stretched) + padding(node) + Generator.indented(frames)
        if node.kind == .card {
            let background = cardBackground(node)
            lines.append("    .background(\(background.fill), in: .rect(cornerRadius: \(background.radius)))")
        }
        if let rotation {
            lines.append("    .rotationEffect(.degrees(\(Generator.number(CGFloat(rotation)))))")
        }
        return lines
    }

    /// A row, column, grid or overlay's own block: its stack and what it holds, each child as its
    /// layout places it. A free container is inferred.
    private mutating func block(of node: LayerNode) -> [String] {
        let children = node.children.filter(isWritten)
        switch node.resolvedLayout {
        case .stack(let stack):
            return stackBlock(node, stack, children)
        case .grid(let grid):
            // One `GridRow` for each row of the grid's columns, as the engine fills them.
            let columns = min(12, max(1, grid.columns))
            let alignment = Generator.alignmentName(horizontal: grid.alignment.horizontal, vertical: grid.alignment.vertical)
            var lines = ["Grid(\(alignment.map { "alignment: .\($0), " } ?? "")horizontalSpacing: \(gap(grid.columnSpacing)), verticalSpacing: \(gap(grid.rowSpacing))) {"]
            for start in stride(from: 0, to: children.count, by: columns) {
                var row: [String] = []
                for child in children[start..<min(start + columns, children.count)] {
                    row += childLines(child, in: node)
                }
                lines += Generator.indented(["GridRow {"] + Generator.indented(row) + ["}"])
            }
            return lines + ["}"]
        case .overlay(let alignment):
            let name = Generator.alignmentName(horizontal: alignment.horizontal, vertical: alignment.vertical) ?? "center"
            var layers: [String] = []
            for child in children { layers += childLines(child, in: node) }
            return ["ZStack(alignment: .\(name)) {"] + Generator.indented(layers) + ["}"]
        case .free:
            return freeContainer(node)
        }
    }

    /// A stack: its cross alignment (a stretching one, which SwiftUI's stacks don't have, as its
    /// start: F6), its spacing, its children, and `Spacer()`s for how it spreads the room left
    /// over, only when no child fills it, as the engine spreads it.
    private mutating func stackBlock(_ node: LayerNode, _ stack: LayerNode.Stack, _ children: [LayerNode]) -> [String] {
        let vertical = stack.axis == .vertical
        let cross = Generator.edge(stack.alignment)
        let opening = vertical
            ? "VStack(alignment: .\(Generator.alignmentName(horizontal: cross, vertical: nil) ?? "center"), spacing: \(gap(stack.spacing))) {"
            : "HStack(alignment: .\(Generator.alignmentName(horizontal: nil, vertical: cross) ?? "center"), spacing: \(gap(stack.spacing))) {"
        var views: [[String]] = []
        for child in children { views.append(childLines(child, in: node)) }
        let fills = children.contains { child in
            if case .fill = (vertical ? child.height : child.width).mode { return true }
            return false
        }
        if !views.isEmpty, !fills, Self.roomLeft(in: node, stack) >= 1 {
            let spacer = ["Spacer()"]
            switch stack.justify {
            case .start:
                break
            case .center:
                views = [spacer] + views + [spacer]
            case .end:
                views = [spacer] + views
            case .spaceBetween:
                views = Array(views.map { [$0] }.joined(separator: [spacer]))
            case .spaceAround, .spaceEvenly:
                // SwiftUI's spacers share the room equally, so both are spread evenly.
                views = [spacer] + Array(views.map { [$0] }.joined(separator: [spacer])) + [spacer]
            }
        }
        return [opening] + Generator.indented(views.flatMap { $0 }) + ["}"]
    }

    /// The room a stack's children leave along its axis, as laid out.
    private static func roomLeft(in node: LayerNode, _ stack: LayerNode.Stack) -> CGFloat {
        let shown = node.children.filter { !$0.isHidden }
        let vertical = stack.axis == .vertical
        let padding = node.padding
        let room = vertical ? node.frame.height - padding.top - padding.bottom : node.frame.width - padding.leading - padding.trailing
        let used = shown.reduce(0) { $0 + (vertical ? $1.frame.height : $1.frame.width) }
        return room - used - max(0, stack.spacing) * CGFloat(max(0, shown.count - 1))
    }

    /// A child of a row, column, grid or overlay: its name, then its view at the size its sizing gives it.
    private mutating func childLines(_ child: LayerNode, in parent: LayerNode) -> [String] {
        var lines = Generator.comment(child.name).map { ["// \($0)"] } ?? []
        let frames = Self.sizingFrames(of: child, in: parent)
        let rotation = Rotation.kept(child.rotation ?? 0)
        if child.isContainer {
            lines += container(child, frames: frames.lines, stretched: (frames.stretchedAcross, frames.stretchedDown), rotation: rotation)
        } else {
            lines += Generator.laidOutLeaf(Generator.Leaf(node: child, frame: child.frame, rotation: rotation), frames: frames.lines)
        }
        return lines
    }

    /// A child's frames in a row, column, grid or overlay, and how they let it grow.
    struct ChildFrames {
        /// The frame modifiers, unindented.
        var lines: [String] = []
        /// Whether a frame lets it grow across, or down, as far as it is offered.
        var growsAcross = false
        var growsDown = false
        /// Whether its stack stretches it across, or down, to the stack's own length (F6).
        var stretchedAcross = false
        var stretchedDown = false
    }

    /// The frames a child of a row, column, grid or overlay is written with: first its fixed
    /// lengths, and the lengths of a fitting leaf whose SwiftUI view wouldn't take them by itself;
    /// then, as far as it can go, a filling length, a length its stack stretches it across (not a
    /// toggle, checkbox, radio, avatar or symbol, as in the engine: F6), and a grid column's width,
    /// which the columns share equally.
    private static func sizingFrames(of child: LayerNode, in parent: LayerNode) -> ChildFrames {
        func exact(_ sizing: LayerNode.Sizing, _ length: CGFloat, across: Bool) -> CGFloat? {
            switch sizing.mode {
            case .fixed: length
            case .fit: child.isContainer || Generator.sizesItself(child.kind, across: across) ? nil : length
            case .fill: nil
            }
        }
        let own = Generator.contentAlignment(of: child)
        var width = (exact: exact(child.width, child.frame.width, across: true), flexible: fills(child.width), edge: own.horizontal)
        var height = (exact: exact(child.height, child.frame.height, across: false), flexible: fills(child.height), edge: own.vertical)
        var found = ChildFrames()

        switch parent.resolvedLayout {
        case .stack(let stack) where stack.alignment == .fill && !NaturalSize.keepsItsShape(child.kind):
            // Words, and a button's title, keep their place in the room they're stretched over, as
            // the canvas draws them; anything else sits at the start (F6, and the rulings on it).
            let keepsItsPlace = Generator.isText(child.kind) || child.kind == .button
            if stack.axis == .vertical, child.width.mode != .fixed {
                (width.flexible, width.edge) = (true, keepsItsPlace ? own.horizontal : .start)
                found.stretchedAcross = true
            }
            if stack.axis == .horizontal, child.height.mode != .fixed {
                (height.flexible, height.edge) = (true, keepsItsPlace ? own.vertical : .start)
                found.stretchedDown = true
            }
        case .grid(let grid):
            (width.flexible, width.edge) = (true, grid.alignment.horizontal)
            // A grid row is as tall as its tallest child.
            height.flexible = false
        default:
            break
        }
        (found.growsAcross, found.growsDown) = (width.flexible, height.flexible)

        var frames: [String] = []
        let exactParts = [width.exact.map { "width: \(Generator.number($0))" }, height.exact.map { "height: \(Generator.number($0))" }]
        if exactParts.contains(where: { $0 != nil }) {
            let alignment = Generator.alignmentName(horizontal: width.exact == nil ? nil : own.horizontal,
                                                    vertical: height.exact == nil ? nil : own.vertical)
            frames.append(".frame(\((exactParts + [alignment.map { "alignment: .\($0)" }]).compactMap { $0 }.joined(separator: ", ")))")
        }
        let flexibleParts = [width.flexible ? "maxWidth: .infinity" : nil, height.flexible ? "maxHeight: .infinity" : nil]
        if flexibleParts.contains(where: { $0 != nil }) {
            let alignment = Generator.alignmentName(horizontal: width.flexible ? width.edge : nil, vertical: height.flexible ? height.edge : nil)
            frames.append(".frame(\((flexibleParts + [alignment.map { "alignment: .\($0)" }]).compactMap { $0 }.joined(separator: ", ")))")
        }
        found.lines = frames
        return found
    }

    private static func fills(_ sizing: LayerNode.Sizing) -> Bool {
        if case .fill = sizing.mode { return true }
        return false
    }

    /// SwiftUI's stacks grow to the room they're offered when a child can grow; the engine's
    /// containers hug what they hold. So a container that fits what it holds, and isn't stretched
    /// by its own stack, is held to its own size on an axis where a child would grow it:
    /// - down, when any child grows down (the engine measures a fitting height with no room
    ///   offered, so nothing that fills or stretches down makes it taller): a stretching row's
    ///   children then take the row's height, the tallest of them, as in the engine;
    /// - across, for a stretching column when no child fills across (the engine measures a
    ///   stretching column's width without stretching it, but a child that fills across takes the
    ///   width offered, in both).
    private func heldToItsSize(_ node: LayerNode, stretched: (across: Bool, down: Bool)) -> [String] {
        let children = node.children.filter(isWritten)
        let frames = children.map { Self.sizingFrames(of: $0, in: node) }
        let down = node.height.mode == .fit && !stretched.down && frames.contains { $0.growsDown }
        var across = false
        if case .stack(let stack) = node.resolvedLayout, stack.axis == .vertical, stack.alignment == .fill,
           node.width.mode == .fit, !stretched.across, !children.contains(where: { Self.fills($0.width) }) {
            across = frames.contains { $0.growsAcross }
        }
        guard across || down else { return [] }
        return ["    .fixedSize(horizontal: \(across), vertical: \(down))"]
    }

    /// The frame a row, column, grid or overlay is written with as an item of the inference, in
    /// a free container whose children's frames are their own: its lengths where it doesn't fit
    /// what it holds, its content placed in it as the engine places it.
    func framesInFreeParent(_ node: LayerNode) -> [String] {
        let width: CGFloat? = node.width.mode == .fit ? nil : node.frame.width
        let height: CGFloat? = node.height.mode == .fit ? nil : node.frame.height
        guard width != nil || height != nil else { return [] }
        let own = Generator.contentAlignment(of: node)
        let alignment = Generator.alignmentName(horizontal: width == nil ? nil : own.horizontal, vertical: height == nil ? nil : own.vertical)
        let parts = [width.map { "width: \(Generator.number($0))" }, height.map { "height: \(Generator.number($0))" }, alignment.map { "alignment: .\($0)" }]
        return [".frame(\(parts.compactMap { $0 }.joined(separator: ", ")))"]
    }
}

extension SwiftUICodeGenerator {
    /// Where a node's content sits in a frame larger than it, as the engine places it: text by
    /// its alignment, from the top; a stack by its cross alignment and how it spreads; a grid's
    /// columns across it, from the top; an overlay by its alignment; a free container from its
    /// top-left corner; anything else centred.
    static func contentAlignment(of node: LayerNode) -> (horizontal: LayerNode.Edge3, vertical: LayerNode.Edge3) {
        guard node.isContainer else {
            guard isText(node.kind) else { return (.center, .center) }
            let alignment = node.style.textAlignment ?? node.kind.spec.textAlignment
            return (alignment == .leading ? .start : alignment == .center ? .center : .end, .start)
        }
        switch node.resolvedLayout {
        case .free:
            return (.start, .start)
        case .stack(let stack):
            let main: LayerNode.Edge3 = switch stack.justify {
            case .center: .center
            case .end: .end
            default: .start
            }
            return stack.axis == .vertical ? (edge(stack.alignment), main) : (main, edge(stack.alignment))
        case .grid:
            return (.center, .start)
        case .overlay(let alignment):
            return (alignment.horizontal, alignment.vertical)
        }
    }

    /// Whether a kind is words, placed by their text alignment: a title, body, text, or a sticky note's words.
    static func isText(_ kind: ElementKind) -> Bool {
        switch kind {
        case .title, .body, .text, .stickyNote: true
        default: false
        }
    }

    /// A stack's cross alignment as an edge: a stretching one is its start (F6).
    static func edge(_ alignment: LayerNode.CrossAlignment) -> LayerNode.Edge3 {
        switch alignment {
        case .start, .fill: .start
        case .center: .center
        case .end: .end
        }
    }

    /// SwiftUI's name for where content sits on the axes given (nil for an axis not constrained):
    /// `leading`, `top`, `bottomTrailing` and so on, or nil for the centre, which is the default.
    static func alignmentName(horizontal: LayerNode.Edge3?, vertical: LayerNode.Edge3?) -> String? {
        let across: String? = switch horizontal {
        case .start: "leading"
        case .end: "trailing"
        default: nil
        }
        let down: String? = switch vertical {
        case .start: "top"
        case .end: "bottom"
        default: nil
        }
        switch (across, down) {
        case (let across?, let down?): return down + across.prefix(1).uppercased() + across.dropFirst()
        case (let across?, nil): return across
        case (nil, let down?): return down
        case (nil, nil): return nil
        }
    }
}

// MARK: - Exact positions

extension SwiftUICodeGenerator.ScreenWriter {
    /// Every leaf at its place on the screen (its shape in `TreeIndex`), measured from the
    /// screen's top-left corner, which is why the stack reaches under the status bar. Top to
    /// bottom, as today; a card's background goes just before what it holds.
    mutating func absolute() -> [String] {
        var single = TreeContent()
        single.screens = [screen]
        let index = TreeIndex(single)
        var leaves: [LayerNode] = []
        var cards: [(node: LayerNode, holds: Set<UUID>)] = []
        func visit(_ node: LayerNode) -> [UUID] {
            guard isWritten(node) else { return [] }
            guard node.isContainer else {
                leaves.append(node)
                return [node.id]
            }
            let card = node.kind == .card ? cards.count : nil
            if card != nil { cards.append((node, [])) }
            let held = node.children.flatMap(visit)
            if let card { cards[card].holds = Set(held) }
            return held
        }
        for child in screen.root.children { _ = visit(child) }

        func shape(_ node: LayerNode) -> TurnedRect {
            index[node.id]?.hostShape ?? TurnedRect(rect: node.frame, degrees: node.rotation ?? 0)
        }
        var order: [(node: LayerNode, isCard: Bool)] = leaves.sorted { shape($0).rect.minY < shape($1).rect.minY }.map { ($0, false) }
        for card in cards {
            let top = shape(card.node).rect.minY
            let place = order.firstIndex { !$0.isCard && card.holds.contains($0.node.id) }
                ?? order.firstIndex { !$0.isCard && shape($0.node).rect.minY > top }
                ?? order.count
            order.insert((card.node, true), at: place)
        }

        guard !order.isEmpty else { return ["Color.clear"] }
        var body = ["Color.clear"]
        for entry in order {
            if let name = Generator.comment(entry.node.name) {
                body.append("// \(name)")
            }
            let placed = shape(entry.node)
            body += entry.isCard
                ? positionedCard(entry.node, at: placed)
                : Generator.positionedLeaf(Generator.Leaf(node: entry.node, frame: placed.rect, rotation: Rotation.kept(placed.degrees)))
        }
        return ["ZStack(alignment: .topLeading) {"] + Generator.indented(body) + [
            "}",
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)",
            ".ignoresSafeArea()",
        ]
    }

    /// A card's background, at its place on the screen.
    private mutating func positionedCard(_ node: LayerNode, at shape: TurnedRect) -> [String] {
        let background = cardBackground(node)
        let rotation = Rotation.kept(shape.degrees)
        return [
            "RoundedRectangle(cornerRadius: \(background.radius))",
            "    .fill(\(background.fill))",
            "    .frame(width: \(Generator.number(shape.rect.width)), height: \(Generator.number(shape.rect.height)))",
        ] + (rotation.map { ["    .rotationEffect(.degrees(\(Generator.number(CGFloat($0)))))"] } ?? []) + [
            "    .offset(x: \(Generator.number(shape.rect.minX)), y: \(Generator.number(shape.rect.minY)))",
        ]
    }
}

// MARK: - Literals

extension SwiftUICodeGenerator {
    /// Text as a Swift string literal. A carriage return or another control character,
    /// pasted from Windows or set by a Siri intent, is escaped too: left in, it ended the
    /// literal, and the file didn't compile.
    static func literal(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F: escaped += String(format: "\\u{%02X}", scalar.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"\(escaped)\""
    }

    /// A layer's name as a comment's text, or nil when it has none: a line break or control
    /// character in it would end the comment and leave the rest of the name as code.
    static func comment(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return String(String.UnicodeScalarView(name.unicodeScalars.map { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
    }

    static func number(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        guard rounded.isFinite else { return rounded.isNaN ? "0" : rounded > 0 ? ".infinity" : "-.infinity" }
        // Past what an Int holds it is written as it is: a size like that is a mistake,
        // but writing it out mustn't stop the app.
        guard rounded.magnitude < 1e15 else { return String(Double(rounded)) }
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(Double(rounded))
    }

    static func color(_ tint: RGBColor) -> String {
        func component(_ value: Double) -> String { String(format: "%.2f", value) }
        return "Color(red: \(component(tint.red)), green: \(component(tint.green)), blue: \(component(tint.blue)))"
    }
}

#if DEBUG
/// How much code is written, for each screen: for the tests that hold what is drawn on every
/// frame to writing none (the share menu). Kept for each screen under a lock, since suites
/// that run alongside write code for screens of their own, from any thread. The counts only
/// grow: a test measures the difference it makes.
enum CodeWork {
    private static let counts = OSAllocatedUnfairLock(initialState: [TreeScreen.ID: Int]())

    static func wrote(_ screen: TreeScreen.ID) {
        counts.withLock { $0[screen, default: 0] += 1 }
    }

    static func generated(for screen: TreeScreen.ID) -> Int {
        counts.withLock { $0[screen] ?? 0 }
    }
}
#endif

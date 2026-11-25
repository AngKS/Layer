import CoreGraphics
import Foundation

// Today's reading-order inference, which writes what is placed freely (call 12): a sketched
// screen, and a free card or group below it. It reads items, each at its frame and turn in the
// space of the container it infers, as it once read a screen's elements: rows by vertical
// overlap become `HStack`s, gaps become `.padding(.top, …)`, the side margin is inferred, and
// on a screen a last row near the bottom becomes a `Spacer()`. The numbers stay as they are.

extension SwiftUICodeGenerator {
    /// The space between rows the inference writes.
    static let spacing: CGFloat = 16
    /// How far down a large navigation title pushes the content, below the status bar.
    static let navigationBarHeight: CGFloat = 96

    /// One thing the inference places: a leaf, or a container written as one block (a card, or
    /// a row, column, grid or overlay), at its frame and turn in the inferred container's space.
    struct Item {
        var node: LayerNode
        var frame: CGRect
        /// From 0 up to 360, nil when upright.
        var rotation: Double?
    }

    /// Where the inference reads a node from: a node's own space in the inferred container's.
    /// While every node down to it is upright, origins are added, so whole numbers stay exact;
    /// under a turned one the centre goes through the turns, as `TreeIndex` turns it.
    struct Place {
        var toContainer = CGAffineTransform.identity
        var origin = CGPoint.zero
        var degrees: Double = 0
        var isUpright = true

        /// A child of the node this is the place of: its frame and angle in the container's space, and its own place.
        func placing(_ node: LayerNode) -> (frame: CGRect, rotation: Double?, place: Place) {
            let own = node.rotation.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let size = node.frame.size
            let frame: CGRect
            if isUpright {
                frame = CGRect(origin: CGPoint(x: origin.x + node.frame.origin.x, y: origin.y + node.frame.origin.y), size: size)
            } else {
                let centre = CGPoint(x: node.frame.origin.x + size.width / 2, y: node.frame.origin.y + size.height / 2)
                    .applying(toContainer)
                frame = CGRect(origin: CGPoint(x: centre.x - size.width / 2, y: centre.y - size.height / 2), size: size)
            }
            let degrees = self.degrees + own
            let place = Place(toContainer: node.transformToParent.concatenating(toContainer), origin: frame.origin,
                              degrees: degrees, isUpright: isUpright && Rotation.normalized(own) == 0)
            return (frame, Rotation.kept(degrees), place)
        }
    }

    /// The box the inference fills: a screen, inside its safe areas, or a container's content box.
    struct InferenceBox {
        var size: CGSize
        /// Where the content starts below the top edge: the safe area, and a navigation bar.
        var top: CGFloat
        var bottom: CGFloat
        /// A screen ends with a `Spacer()` before a last row near its bottom, and fills its height.
        var isScreen: Bool
    }
}

extension SwiftUICodeGenerator.ScreenWriter {
    typealias Generator = SwiftUICodeGenerator

    /// What a free container places, in reading order: its written children at their frames and
    /// turns in its own space, a free group's members in its place (a free group is transparent).
    func items(of container: LayerNode) -> [Generator.Item] {
        var found: [Generator.Item] = []
        func gather(_ children: [LayerNode], at place: Generator.Place) {
            for child in children where isWritten(child) {
                let placed = place.placing(child)
                if child.kind == .group, child.resolvedLayout == .free {
                    gather(child.children, at: placed.place)
                } else {
                    found.append(Generator.Item(node: child, frame: placed.frame, rotation: placed.rotation))
                }
            }
        }
        gather(container.children, at: Generator.Place())
        // Top to bottom, as today's elements were sorted.
        return found.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// A free screen: today's vertical stack in reading order, on its device, below a navigation bar when there is one.
    mutating func freeScreen(belowNavigationBar: Bool) -> [String] {
        let box = Generator.InferenceBox(size: device.size, top: device.safeTop + (belowNavigationBar ? Generator.navigationBarHeight : 0),
                                         bottom: device.safeBottom, isScreen: true)
        return inferred(items(of: screen.root), in: box)
    }

    /// A free container below the screen root: inferred inside its content box, with no safe
    /// areas and no bottom `Spacer()`, then padded and framed to its size. Its modifiers are
    /// indented, as a view's are.
    ///
    /// The canvas places a free container's children from its frame's corner, padding or not, and
    /// a sketched card holds what it takes where it is on the screen, often closer to its edge
    /// than its padding. So each side is padded only as far as what it holds is in from that side
    /// (plan 5's final review, B2), and what it holds is written where the canvas draws it.
    mutating func freeContainer(_ node: LayerNode) -> [String] {
        let found = items(of: node)
        var padded = node
        if let first = found.first?.frame {
            let held = found.dropFirst().reduce(first) { $0.union($1.frame) }
            let padding = node.padding
            padded.padding = LayerNode.Padding(top: max(0, min(padding.top, held.minY)),
                                               leading: max(0, min(padding.leading, held.minX)),
                                               bottom: max(0, min(padding.bottom, node.frame.height - held.maxY)),
                                               trailing: max(0, min(padding.trailing, node.frame.width - held.maxX)))
        }
        let inset = padded.padding
        let box = Generator.InferenceBox(size: CGSize(width: max(0, node.frame.width - inset.leading - inset.trailing),
                                                      height: max(0, node.frame.height - inset.top - inset.bottom)),
                                         top: 0, bottom: 0, isScreen: false)
        let placed = found.map { item in
            var item = item
            item.frame.origin = CGPoint(x: item.frame.minX - inset.leading, y: item.frame.minY - inset.top)
            return item
        }
        return inferred(placed, in: box)
            + padding(padded)
            + ["    .frame(width: \(Generator.number(node.frame.width)), height: \(Generator.number(node.frame.height)), alignment: .topLeading)"]
    }

    /// Today's vertical stack of `items`, sorted top to bottom, in `box`: rows by vertical overlap,
    /// gaps as padding, the side margin inferred. A container's rows are spaced no wider than its
    /// closest two (B2), so that none is written lower than the canvas draws it; a screen's are
    /// spaced as they always were.
    mutating func inferred(_ items: [Generator.Item], in box: Generator.InferenceBox) -> [String] {
        let rows = Generator.rows(of: items)
        let spacing = box.isScreen ? Generator.spacing : Generator.rowSpacing(of: rows)
        let width = box.size.width
        let margin = items.map { min($0.frame.minX, width - $0.frame.maxX) }.min().map { max(0, $0) } ?? 0
        let contentWidth = width - margin * 2
        let topEdge = box.top

        var body: [String] = []
        var previousBottom: CGFloat?
        var usesSpacer = false

        for (index, row) in rows.enumerated() {
            let item = row[0]
            let bounds = row.dropFirst().reduce(item.frame) { $0.union($1.frame) }
            var lines = row.count == 1
                ? view(for: item, margin: margin, contentWidth: contentWidth, screenWidth: width)
                : horizontalStack(row, margin: margin)
            if let previousBottom {
                let gap = bounds.minY - previousBottom
                let isLast = index == rows.count - 1
                let hugsBottom = box.size.height - bounds.maxY <= box.bottom + 60
                if box.isScreen, isLast, hugsBottom, gap > spacing * 2 {
                    // A last element near the bottom edge is pinned there rather than spaced down.
                    body.append("Spacer()")
                    usesSpacer = true
                } else if gap - spacing >= 2 {
                    lines.append("    .padding(.top, \(Generator.number(gap - spacing)))")
                }
            }
            if row.count == 1, let name = Generator.comment(item.node.name) {
                lines.insert("// \(name)", at: 0)
            }
            body += lines
            previousBottom = bounds.maxY
        }

        guard !body.isEmpty else { return ["Color.clear"] }
        // A screen's stack is the body's own, its modifiers unindented; a container's is a view among others.
        let modifier = box.isScreen ? "" : "    "
        var lines = ["VStack(alignment: .leading, spacing: \(Generator.number(spacing))) {"]
        lines += Generator.indented(body)
        lines.append("}")
        if margin > 0 { lines.append(modifier + ".padding(.horizontal, \(Generator.number(margin)))") }
        if let first = items.first, first.frame.minY - topEdge >= 1 {
            lines.append(modifier + ".padding(.top, \(Generator.number(first.frame.minY - topEdge)))")
        }
        guard box.isScreen else { return lines }
        if usesSpacer, let last = items.last {
            let inset = box.size.height - box.bottom - last.frame.maxY
            if inset >= 1 { lines.append(".padding(.bottom, \(Generator.number(inset)))") }
        } else {
            lines.append(".frame(maxHeight: .infinity, alignment: .top)")
        }
        return lines
    }

    /// A row of items side by side, each at its own width, spaced as on the canvas.
    private mutating func horizontalStack(_ row: [Generator.Item], margin: CGFloat) -> [String] {
        let spacing = zip(row, row.dropFirst()).map { $1.frame.minX - $0.frame.maxX }.min() ?? 0
        var body: [String] = []
        for (item, next) in zip(row, row.dropFirst().map { Optional($0) } + [nil]) {
            if let name = Generator.comment(item.node.name) {
                body.append("// \(name)")
            }
            // Each item at its own width, flush with the one before it.
            body += view(for: item, margin: item.frame.minX, contentWidth: .infinity, screenWidth: .infinity)
            if let next, next.frame.minX - item.frame.maxX - spacing >= 2 {
                body.append("Spacer(minLength: \(Generator.number(next.frame.minX - item.frame.maxX - spacing)))")
            }
        }
        var lines = ["HStack(alignment: .center, spacing: \(Generator.number(spacing))) {"] + Generator.indented(body) + ["}"]
        if let first = row.first, first.frame.minX - margin >= 1 {
            lines.append("    .padding(.leading, \(Generator.number(first.frame.minX - margin)))")
        }
        return lines
    }

    /// One item as the inference writes it: a leaf as today, or a container's own code at its
    /// size and turn, then placed as a leaf of that frame would be.
    private mutating func view(for item: Generator.Item, margin: CGFloat, contentWidth: CGFloat, screenWidth: CGFloat) -> [String] {
        guard item.node.isContainer else {
            return Generator.inferredLeaf(Generator.Leaf(node: item.node, frame: item.frame, rotation: item.rotation, tokens: context.tokens),
                                          margin: margin, contentWidth: contentWidth, screenWidth: screenWidth)
        }
        let fillsWidth = item.frame.width >= contentWidth - 1
        let centered = ElementLayout.isCentered(item.frame, in: screenWidth)
        return container(item.node, frames: framesInFreeParent(item.node), stretched: (false, false), rotation: item.rotation)
            + Generator.placement(of: item.frame, margin: margin, fillsWidth: fillsWidth, centered: centered)
    }
}

extension SwiftUICodeGenerator {
    /// Groups items, sorted top to bottom, into rows: items side by side, sharing most of their
    /// height and none of the screen's width, go in one row, leading first.
    static func rows(of items: [Item]) -> [[Item]] {
        var rows: [[Item]] = []
        for item in items {
            if let last = rows.last, last.allSatisfy({ sharesRow($0.frame, item.frame) }) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// The space between the rows of a free container: the inference's, or the least gap between
    /// two rows when that is less, and never less than none.
    static func rowSpacing(of rows: [[Item]]) -> CGFloat {
        let bounds = rows.map { row in row.dropFirst().reduce(row[0].frame) { $0.union($1.frame) } }
        let least = zip(bounds, bounds.dropFirst()).map { $1.minY - $0.maxY }.min() ?? spacing
        return max(0, min(spacing, least))
    }

    private static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let apart = a.maxX <= b.minX || b.maxX <= a.minX
        return apart && overlap >= min(a.height, b.height) * 0.5
    }
}

import CoreGraphics

/// Lays a whole screen out again, the way a designer tidies a rough one: the same things
/// in the same order, on one margin, on one rhythm of spacing. Asked to "align everything",
/// a model lined every element up by its centre and stacked a whole screen into one
/// column; this is the deterministic answer to that request, and the reflow a screen gets
/// when it changes device.
///
/// The rules, and why:
/// - **The order is kept.** Elements are read top to bottom. Two whose vertical extents
///   overlap by at least half the shorter one, and which don't sit on top of each other,
///   are a row and stay side by side. A tidy changes where things are, not what the screen says.
/// - **One column.** Everything sits inside the same side margins: 20 points on a phone,
///   as generated screens have (`ElementLayout.margin`), 32 on a tablet and 48 on a Mac,
///   whose wider screens look cramped at a phone's margin. On a Mac the column is also
///   kept to a readable width and centred, as a web page's container is, so that a
///   button doesn't run 1,400 points across.
/// - **Full width for what is naturally full width.** Buttons, text fields, dividers and
///   progress bars span the column, and so do text and images wider than half of it.
///   Small things (symbols, avatars, toggles, checkboxes, radio buttons), and text and
///   images narrower than half, keep their size and go to the column's leading edge, its
///   centre or its trailing edge, whichever they were nearest.
/// - **Rows share the column.** Small things keep their width and the rest share what is
///   left in proportion to their widths, 12 points apart (`ElementLayout.gutter`); a row
///   of small things only, such as a tab bar, gets equal slots, as generated rows do.
///   Members are centred on the row's middle.
/// - **The top is the generator's top.** The first row starts 16 points below the safe
///   area, where `ScreenBlueprint.layout(on:)` starts, so a tidied screen looks generated.
/// - **Spacing on a rhythm** (`ElementLayout.rhythm`): 8 between a heading and the text
///   under it, 16 between a heading and anything else, 12 between items, and 24 between
///   groups. A group starts at a heading (a title, or bold text) and a divider ends one.
/// - **Bottom things stay at the bottom.** Rows that sat in the bottom quarter, clearly
///   apart from what is above (24 points or more), such as a primary button or a tab bar,
///   are pinned to the bottom, `safeBottom + 8` up as new elements are kept
///   (`ElementLayout.frame`), and never less than the side margin.
/// - **It fits if it can.** When the rows don't fit above the bottom, the group gaps
///   close to 12 first, then every gap to 8, and only then are pinned rows let go to
///   follow the rest. Nothing overlaps.
/// - **What isn't the layout's stays put.** Locked elements don't move and the rest go
///   round them, those that were below one staying below it. Hidden ones keep their place, and so do drawings and shapes, which
///   are the person's own marks.
enum ScreenTidy {
    static let tight: CGFloat = 8
    static let normal: CGFloat = 12
    static let afterHeading: CGFloat = 16
    static let group: CGFloat = 24
    /// The widest a column runs on a large screen.
    static let widestColumn: CGFloat = 1080

    /// The side margin on a device.
    static func margin(on device: DeviceFrame) -> CGFloat {
        switch device.family {
        case .phone: ElementLayout.margin
        case .tablet: 32
        case .desktop: 48
        }
    }

    /// The column everything is laid out in, from its leading edge.
    static func column(on device: DeviceFrame) -> (x: CGFloat, width: CGFloat) {
        let margin = margin(on: device)
        let width = min(device.size.width - margin * 2, widestColumn)
        return (((device.size.width - width) / 2).rounded(), width)
    }

    /// Where the first row starts: as `ScreenBlueprint.layout(on:)` places its first element.
    static func top(on device: DeviceFrame) -> CGFloat {
        device.safeTop + 16
    }

    /// How far a pinned row's bottom is from the screen's bottom.
    static func bottomInset(on device: DeviceFrame) -> CGFloat {
        max(device.safeBottom + 8, margin(on: device))
    }

    /// Whether the tidy moves an element at all.
    static func moves(_ element: DesignElement) -> Bool {
        !element.isLocked && !element.isHidden && element.kind != .drawing && element.kind != .shape && element.kind.belongsOnScreens
    }

    /// New frames for the elements of a screen on `device`, by the rules above. Only the
    /// elements that move are in the answer. `previous` is the device the frames are in
    /// now, when the screen is changing device; their shares of its column carry over.
    static func frames(for elements: [DesignElement], on device: DeviceFrame, from previous: DeviceFrame? = nil) -> [DesignElement.ID: CGRect] {
        let old = previous ?? device
        let oldColumn = column(on: old)
        let newColumn = column(on: device)
        let rows = rows(of: elements.filter(moves))
        guard !rows.isEmpty else { return [:] }
        // Locked things are in the way. Hidden ones, drawings and shapes aren't: they are
        // under or over the layout, not part of it.
        let obstacles = elements.filter { $0.isLocked && !$0.isHidden && $0.kind != .drawing && $0.kind != .shape }.map(\.frame)

        // Each row laid out across the column, from a top of 0.
        let laidOut = rows.map { lay($0, from: oldColumn, to: newColumn) }
        let pinnedFrom = firstPinned(rows, on: old)

        // Gentler spacing until it fits.
        let schemes: [(group: CGFloat, normal: CGFloat, afterHeading: CGFloat, tight: CGFloat)] = [
            (group, normal, afterHeading, tight),
            (normal, normal, normal, tight),
            (tight, tight, tight, tight),
        ]
        let bottom = device.size.height - bottomInset(on: device)
        var best: [DesignElement.ID: CGRect] = [:]
        for pinning in [pinnedFrom, rows.count] where pinning <= rows.count {
            let pinned = Array(laidOut[pinning...])
            let pinnedHeight = pinned.map(\.height).reduce(0, +) + normal * CGFloat(max(pinned.count - 1, 0))
            let limit = pinned.isEmpty ? bottom : bottom - pinnedHeight - group
            for scheme in schemes {
                var frames: [DesignElement.ID: CGRect] = [:]
                var y = top(on: device)
                for index in 0..<pinning {
                    if index > 0 {
                        y += gap(after: rows[index - 1], before: rows[index], scheme: scheme)
                    }
                    let row = laidOut[index]
                    // A row that was below a locked element stays below it.
                    let top = rows[index].map(\.frame.minY).min() ?? 0
                    for obstacle in obstacles where obstacle.midY < top { y = max(y, obstacle.maxY + normal) }
                    y = clear(of: obstacles, top: y, row: row)
                    for (id, frame) in row.frames { frames[id] = frame.offsetBy(dx: 0, dy: y) }
                    y += row.height
                }
                // Pinned rows stack up from the bottom, 12 apart.
                var pinnedY = bottom
                for row in pinned.reversed() {
                    pinnedY -= row.height
                    for (id, frame) in row.frames { frames[id] = frame.offsetBy(dx: 0, dy: pinnedY) }
                    pinnedY -= normal
                }
                best = frames
                if y <= limit { return rounded(best) }
            }
        }
        return rounded(best)
    }

    // MARK: Rows

    /// A row laid out across the column: each member's frame from the row's top, and the
    /// row's height.
    struct LaidRow {
        var frames: [(DesignElement.ID, CGRect)]
        var height: CGFloat
    }

    /// The elements in reading order, in rows. Members of a row are in order from the left.
    static func rows(of elements: [DesignElement]) -> [[DesignElement]] {
        let sorted = elements.sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        var rows: [[DesignElement]] = []
        for element in sorted {
            if var last = rows.last, joins(element, last) {
                last.append(element)
                rows[rows.count - 1] = last
            } else {
                rows.append([element])
            }
        }
        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    /// Whether an element belongs in a row beside the ones there: it overlaps the row
    /// from top to bottom by half the shorter of them, and none of them from side to side
    /// by half the narrower. A divider is a row of its own.
    private static func joins(_ element: DesignElement, _ row: [DesignElement]) -> Bool {
        guard element.kind != .divider, !row.contains(where: { $0.kind == .divider }) else { return false }
        let band = row.dropFirst().reduce(row[0].frame) { $0.union($1.frame) }
        let shared = min(band.maxY, element.frame.maxY) - max(band.minY, element.frame.minY)
        guard shared >= min(band.height, element.frame.height) / 2, shared > 0 else { return false }
        return row.allSatisfy { other in
            let across = min(other.frame.maxX, element.frame.maxX) - max(other.frame.minX, element.frame.minX)
            return across < min(other.frame.width, element.frame.width) / 2
        }
    }

    private static let spans: Set<ElementKind> = [.button, .textField, .divider, .progress]
    private static let small: Set<ElementKind> = [.symbol, .avatar, .toggle, .checkbox, .radio]

    /// Lays one row out across the new column, from a top of 0.
    private static func lay(_ row: [DesignElement], from old: (x: CGFloat, width: CGFloat), to new: (x: CGFloat, width: CGFloat)) -> LaidRow {
        let height = row.map(\.frame.height).max() ?? 0
        func centred(_ element: DesignElement, x: CGFloat, width: CGFloat) -> (DesignElement.ID, CGRect) {
            (element.id, CGRect(x: x, y: (height - element.frame.height) / 2, width: width, height: element.frame.height))
        }

        if row.count == 1 {
            let element = row[0]
            let share = element.frame.width / old.width
            if spans.contains(element.kind) || (!small.contains(element.kind) && share > 0.5) {
                return LaidRow(frames: [centred(element, x: new.x, width: new.width)], height: height)
            }
            // Kept to its size, or its share of the column, by the edge it was nearest.
            let width = small.contains(element.kind) ? element.frame.width : min(new.width, (share * new.width).rounded())
            let offset = element.frame.midX - (old.x + old.width / 2)
            let x: CGFloat = if abs(offset) <= max(8, old.width * 0.08) {
                new.x + (new.width - width) / 2
            } else if offset > 0 {
                new.x + new.width - width
            } else {
                new.x
            }
            return LaidRow(frames: [centred(element, x: x, width: width)], height: height)
        }

        let gutter = ElementLayout.gutter
        let stretchy = row.filter { !small.contains($0.kind) }
        let fixedWidth = row.filter { small.contains($0.kind) }.map(\.frame.width).reduce(0, +)
        let room = new.width - gutter * CGFloat(row.count - 1) - fixedWidth
        if !stretchy.isEmpty, room >= 44 * CGFloat(stretchy.count) {
            // What is left is shared in proportion to the widths they have now.
            let total = max(stretchy.map(\.frame.width).reduce(0, +), 1)
            var x = new.x
            var frames: [(DesignElement.ID, CGRect)] = []
            for element in row {
                let width = small.contains(element.kind) ? element.frame.width : room * element.frame.width / total
                frames.append(centred(element, x: x, width: width))
                x += width + gutter
            }
            return LaidRow(frames: frames, height: height)
        }
        // Equal slots, each member centred in its own, as a generated row is.
        let slot = new.width / CGFloat(row.count)
        let frames = row.enumerated().map { index, element in
            let width = min(element.frame.width, slot - gutter)
            return centred(element, x: new.x + CGFloat(index) * slot + (slot - width) / 2, width: width)
        }
        return LaidRow(frames: frames, height: height)
    }

    /// The index of the first row pinned to the bottom, or the count when none is: the
    /// last rows, in the bottom quarter of the screen, apart from what is above them.
    private static func firstPinned(_ rows: [[DesignElement]], on device: DeviceFrame) -> Int {
        let zone = device.size.height * 0.75
        var first = rows.count
        while first > 1, rows.count - first < 3, rows[first - 1].allSatisfy({ $0.frame.minY >= zone }) {
            first -= 1
        }
        guard first < rows.count else { return rows.count }
        let above = rows[first - 1].map(\.frame.maxY).max() ?? 0
        let below = rows[first].map(\.frame.minY).min() ?? 0
        return below - above >= group ? first : rows.count
    }

    // MARK: Spacing

    private static func isHeading(_ row: [DesignElement]) -> Bool {
        guard row.count == 1 else { return false }
        let element = row[0]
        return element.kind == .title || (element.kind == .text && [.semibold, .bold].contains(element.fontWeight))
    }

    private static func isText(_ row: [DesignElement]) -> Bool {
        row.count == 1 && [.body, .text].contains(row[0].kind) && !isHeading(row)
    }

    private static func gap(after previous: [DesignElement], before next: [DesignElement], scheme: (group: CGFloat, normal: CGFloat, afterHeading: CGFloat, tight: CGFloat)) -> CGFloat {
        if previous.count == 1, previous[0].kind == .divider { return scheme.group }
        if isHeading(next) { return scheme.group }
        if isHeading(previous) { return isText(next) ? scheme.tight : scheme.afterHeading }
        return scheme.normal
    }

    /// The top a row starts at so that it clears every locked element in its way.
    private static func clear(of obstacles: [CGRect], top: CGFloat, row: LaidRow) -> CGFloat {
        guard !row.frames.isEmpty else { return top }
        let across = row.frames.dropFirst().reduce(row.frames[0].1) { $0.union($1.1) }
        var y = top
        var moved = true
        while moved {
            moved = false
            for obstacle in obstacles {
                let band = CGRect(x: across.minX, y: y, width: across.width, height: row.height)
                if band.insetBy(dx: 0, dy: -0.5).intersects(obstacle), obstacle.minX < band.maxX, band.minX < obstacle.maxX {
                    y = obstacle.maxY + normal
                    moved = true
                }
            }
        }
        return y
    }

    private static func rounded(_ frames: [DesignElement.ID: CGRect]) -> [DesignElement.ID: CGRect] {
        frames.mapValues { frame in
            CGRect(x: frame.minX.rounded(), y: frame.minY.rounded(), width: frame.width.rounded(), height: frame.height.rounded())
        }
    }
}

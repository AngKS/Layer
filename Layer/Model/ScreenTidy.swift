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
/// - **Pictures keep their shape.** An image or an avatar given a new width is given the
///   height that keeps its proportions: kept at its height, a phone's 353 × 200 image became
///   756 × 200 on an iPad, a flat strip. It grows no taller than half the screen (as a
///   picture made for a screen is placed, see `ImagePlaygroundSupport`), or than it was if it
///   was taller already, so that one picture can't push the rest off the screen; past that
///   its width follows (and it is centred in the column), and the gaps close up as for
///   anything else that doesn't fit.
/// - **What rides on a picture or a shape goes with it.** Text or a button laid over an
///   image or a shape on purpose, with at least 80% of its area inside it (`ridesOn`), is
///   part of it: it moves and scales with it, in the same place on it, and the two are laid
///   out as one block. Pulled apart as if they overlapped by accident, a caption ended up
///   under its photo. Something that only overlaps a little is still separated. What rides
///   on something that stays put (a shape, or anything locked) stays put with it, and
///   the layout goes round that whole block, so nothing is set down on a card or its label.
///   Only a block can carry things: a picture or a shape that covers nearly all of the
///   screen (`backdropShare`, 90% of its area) is a backdrop, not a host, and is left where it is, so that
///   a background doesn't make the whole screen ride on it and go untidied.
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
///   follow the rest. Nothing overlaps but what rides on something.
/// - **What isn't the layout's stays put.** Locked elements don't move and the rest go
///   round them, those that were below one staying below it. Hidden ones keep their place, and so do drawings and shapes, which
///   are the person's own marks.
/// - **A turned element keeps its size and its angle.** It is laid out by the upright box
///   round its turned shape (`box(of:)`), and never stretched or resized, as a small thing
///   isn't: given the column's width, a button at 15° spilled over the rows round it, and one
///   stood on end ran off the top of an iPad. Riding on something, it goes with it at its own
///   size; a turned backdrop is carried to its place on a new device, not stretched to fill it.
enum ScreenTidy {
    static let tight: CGFloat = 8
    static let normal: CGFloat = 12
    static let afterHeading: CGFloat = 16
    static let group: CGFloat = 24
    /// The widest a column runs on a large screen.
    static let widestColumn: CGFloat = 1080
    /// How much of an element's area has to lie inside an image or a shape for it to ride
    /// on it. Most of it, so that a caption set on a photo stays there while a label that
    /// merely strays over one's edge is moved off it.
    static let ridesOn: CGFloat = 0.8
    /// The share of the screen's area from which a picture or a shape is a backdrop: it
    /// carries nothing and isn't laid out, and no locked one is an obstacle. Unlocked, it is
    /// scaled with its screen on a device change, shapes too, though they otherwise stay put.
    /// A big hero picture below it is an ordinary picture.
    static let backdropShare: CGFloat = 0.9

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

    /// Whether an element is turned: see `box(of:)`.
    static func isTurned(_ element: DesignElement) -> Bool {
        element.resolvedRotation != 0
    }

    /// The room an element takes up on its screen, which the tidy lays out: its frame, or for
    /// one that is turned, the upright box round its turned shape.
    static func box(of element: DesignElement) -> CGRect {
        isTurned(element) ? element.shapeBounds : element.frame
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
        let hosts = hosts(in: elements, on: old)
        // A shape that carries something stays put, and the layout goes round it.
        let keptClear = Set(hosts.values.filter { !moves($0) }.map(\.id))
        let blocks = elements.filter { keptClear.contains($0.id) }.map(box(of:))
        let flowing = elements.filter { moves($0) && hosts[$0.id] == nil && !isBackdrop($0, on: old) }
        var laid = layout(flowing, among: elements, keeping: blocks, on: device, from: old)
        // A turned element was laid out by its box: its frame goes where that went.
        for element in flowing where isTurned(element) {
            guard let placed = laid[element.id] else { continue }
            let box = box(of: element)
            laid[element.id] = element.frame.offsetBy(dx: placed.minX - box.minX, dy: placed.minY - box.minY)
        }
        // An unlocked backdrop grows with its screen, and isn't laid out otherwise.
        if old.size != device.size, old.size.width > 0, old.size.height > 0 {
            let (sx, sy) = (device.size.width / old.size.width, device.size.height / old.size.height)
            for element in elements where !element.isLocked && !element.isHidden && isBackdrop(element, on: old) {
                let f = element.frame
                laid[element.id] = isTurned(element)
                    // Turned, it keeps its size, and its middle goes to the same place on the screen.
                    ? CGRect(x: f.midX * sx - f.width / 2, y: f.midY * sy - f.height / 2, width: f.width, height: f.height)
                    : CGRect(x: f.minX * sx, y: f.minY * sy, width: f.width * sx, height: f.height * sy)
            }
        }
        return rounded(carry(hosts, with: laid, in: elements), in: elements)
    }

    /// Whether an element covers at least `share` of `device`'s screen.
    private static func covers(_ element: DesignElement, _ share: CGFloat, on device: DeviceFrame) -> Bool {
        element.frame.width * element.frame.height >= device.size.width * device.size.height * share
    }

    /// Whether an element is a backdrop on `device`: see `backdropShare`.
    static func isBackdrop(_ element: DesignElement, on device: DeviceFrame) -> Bool {
        carries.contains(element.kind)
            && covers(element, backdropShare, on: device)
    }

    /// The layout of everything that is laid out: all that moves except what rides on another.
    private static func layout(_ moving: [DesignElement], among elements: [DesignElement], keeping blocks: [CGRect], on device: DeviceFrame, from old: DeviceFrame) -> [DesignElement.ID: CGRect] {
        let oldColumn = column(on: old)
        let newColumn = column(on: device)
        let rows = rows(of: moving)
        guard !rows.isEmpty else { return [:] }
        // Locked things are in the way, and so are shapes with something laid on them.
        // Hidden ones, a locked backdrop, drawings and other shapes
        // aren't: they are under or over the layout, not part of it.
        let obstacles = elements.filter { $0.isLocked && !$0.isHidden && $0.kind != .drawing && $0.kind != .shape && !covers($0, backdropShare, on: old) }.map(box(of:)) + blocks

        // Each row laid out across the column, from a top of 0.
        let tallest = device.size.height / 2
        let laidOut = rows.map { lay($0, from: oldColumn, to: newColumn, tallest: tallest) }
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
            // Pinned rows stack up from the bottom, 12 apart, each above any obstacle it would
            // lie on, a locked picture or a card. One that was below an obstacle stays below
            // it, as a row that flows does; if it can't, the rows aren't pinned.
            var pinnedFrames: [DesignElement.ID: CGRect] = [:]
            var pinnedTop = bottom
            var pinnedClear = true
            for index in (pinning..<rows.count).reversed() {
                let row = laidOut[index]
                let y = clear(of: obstacles, bottom: index == rows.count - 1 ? bottom : pinnedTop - normal, row: row)
                let was = rows[index].map { box(of: $0).minY }.min() ?? 0
                if obstacles.contains(where: { $0.midY < was && y < $0.maxY + normal }) { pinnedClear = false }
                for (id, frame) in row.frames { pinnedFrames[id] = frame.offsetBy(dx: 0, dy: y) }
                pinnedTop = y
            }
            let limit = pinning == rows.count ? bottom : pinnedTop - group
            for scheme in schemes {
                var frames: [DesignElement.ID: CGRect] = [:]
                var y = top(on: device)
                for index in 0..<pinning {
                    if index > 0 {
                        y += gap(after: rows[index - 1], before: rows[index], scheme: scheme)
                    }
                    let row = laidOut[index]
                    // A row that was below a locked element stays below it.
                    let top = rows[index].map { box(of: $0).minY }.min() ?? 0
                    for obstacle in obstacles where obstacle.midY < top { y = max(y, obstacle.maxY + normal) }
                    y = clear(of: obstacles, top: y, row: row)
                    for (id, frame) in row.frames { frames[id] = frame.offsetBy(dx: 0, dy: y) }
                    y += row.height
                }
                frames.merge(pinnedFrames) { _, pinned in pinned }
                best = frames
                if pinnedClear, y <= limit { return best }
            }
        }
        return best
    }

    // MARK: Rows

    /// A row laid out across the column: each member's frame from the row's top (for a
    /// turned one, its box), and the row's height.
    struct LaidRow {
        var frames: [(DesignElement.ID, CGRect)]
        var height: CGFloat
    }

    /// The elements in reading order, in rows. Members of a row are in order from the left.
    static func rows(of elements: [DesignElement]) -> [[DesignElement]] {
        let sorted = elements.sorted { (box(of: $0).minY, box(of: $0).minX) < (box(of: $1).minY, box(of: $1).minX) }
        var rows: [[DesignElement]] = []
        for element in sorted {
            if var last = rows.last, joins(element, last) {
                last.append(element)
                rows[rows.count - 1] = last
            } else {
                rows.append([element])
            }
        }
        return rows.map { $0.sorted { box(of: $0).minX < box(of: $1).minX } }
    }

    /// Whether an element belongs in a row beside the ones there: it overlaps the row
    /// from top to bottom by half the shorter of them, and none of them from side to side
    /// by half the narrower. A divider is a row of its own.
    private static func joins(_ element: DesignElement, _ row: [DesignElement]) -> Bool {
        guard element.kind != .divider, !row.contains(where: { $0.kind == .divider }) else { return false }
        let mine = box(of: element)
        let band = row.dropFirst().reduce(box(of: row[0])) { $0.union(box(of: $1)) }
        let shared = min(band.maxY, mine.maxY) - max(band.minY, mine.minY)
        guard shared >= min(band.height, mine.height) / 2, shared > 0 else { return false }
        return row.allSatisfy { other in
            let theirs = box(of: other)
            let across = min(theirs.maxX, mine.maxX) - max(theirs.minX, mine.minX)
            return across < min(theirs.width, mine.width) / 2
        }
    }

    private static let spans: Set<ElementKind> = [.button, .textField, .divider, .progress]
    private static let small: Set<ElementKind> = [.symbol, .avatar, .toggle, .checkbox, .radio]
    /// Kinds whose picture is drawn to their frame, and so look wrong stretched one way only.
    static let keepsShape: Set<ElementKind> = [.image, .avatar]
    /// Kinds that something can be laid on: see `ridesOn`.
    static let carries: Set<ElementKind> = [.image, .shape]

    /// Whether an element keeps its size in a row: a small thing, or anything turned.
    private static func keepsSize(_ element: DesignElement) -> Bool {
        small.contains(element.kind) || isTurned(element)
    }

    /// The height an element has at a new width: its own, or for a picture the one that
    /// keeps its proportions, no taller than `tallest` unless it was taller already. A
    /// turned element isn't resized: it is as tall as its box.
    static func height(of element: DesignElement, at width: CGFloat, tallest: CGFloat) -> CGFloat {
        guard !isTurned(element) else { return box(of: element).height }
        let frame = element.frame
        guard keepsShape.contains(element.kind), frame.width > 0, width != frame.width else { return frame.height }
        return min(frame.height * width / frame.width, max(tallest, frame.height))
    }

    /// The width a picture is given when its height was held to `tallest` and it is centred
    /// in the column: the proportions are kept. Anything else keeps the width it is given.
    static func width(of element: DesignElement, at place: (x: CGFloat, width: CGFloat), height: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let frame = element.frame
        guard keepsShape.contains(element.kind), !isTurned(element), frame.width > 0, frame.height > 0 else { return place }
        let kept = height * frame.width / frame.height
        guard kept < place.width - 0.5 else { return place }
        return (place.x + (place.width - kept) / 2, kept)
    }

    /// Lays one row out across the new column, from a top of 0.
    private static func lay(_ row: [DesignElement], from old: (x: CGFloat, width: CGFloat), to new: (x: CGFloat, width: CGFloat), tallest: CGFloat) -> LaidRow {
        // Where each member goes across first; its height follows from its width.
        let across = placed(row, from: old, to: new)
        let heights = zip(row, across).map { height(of: $0, at: $1.width, tallest: tallest) }
        let height = heights.max() ?? 0
        let frames = zip(row, zip(across, heights)).map { element, place in
            // A picture held to a height is narrowed to keep its shape, and centred in its place.
            let across = width(of: element, at: place.0, height: place.1)
            // Members are centred on the row's middle.
            return (element.id, CGRect(x: across.x, y: (height - place.1) / 2, width: across.width, height: place.1))
        }
        return LaidRow(frames: frames, height: height)
    }

    /// Where each member of a row goes across the new column, and how wide it is.
    private static func placed(_ row: [DesignElement], from old: (x: CGFloat, width: CGFloat), to new: (x: CGFloat, width: CGFloat)) -> [(x: CGFloat, width: CGFloat)] {
        if row.count == 1 {
            let element = row[0]
            let box = box(of: element)
            let share = box.width / old.width
            if !isTurned(element), spans.contains(element.kind) || (!small.contains(element.kind) && share > 0.5) {
                return [(new.x, new.width)]
            }
            // Kept to its size, or its share of the column, by the edge it was nearest. A
            // turned element wider than the column is centred on it.
            let width = keepsSize(element) ? box.width : min(new.width, (share * new.width).rounded())
            let offset = box.midX - (old.x + old.width / 2)
            let x: CGFloat = if abs(offset) <= max(8, old.width * 0.08) || (isTurned(element) && width > new.width) {
                new.x + (new.width - width) / 2
            } else if offset > 0 {
                new.x + new.width - width
            } else {
                new.x
            }
            return [(x, width)]
        }

        let gutter = ElementLayout.gutter
        let stretchy = row.filter { !keepsSize($0) }
        let fixedWidth = row.filter(keepsSize).map { box(of: $0).width }.reduce(0, +)
        let room = new.width - gutter * CGFloat(row.count - 1) - fixedWidth
        if !stretchy.isEmpty, room >= 44 * CGFloat(stretchy.count) {
            // What is left is shared in proportion to the widths they have now.
            let total = max(stretchy.map(\.frame.width).reduce(0, +), 1)
            var x = new.x
            var places: [(x: CGFloat, width: CGFloat)] = []
            for element in row {
                let width = keepsSize(element) ? box(of: element).width : room * element.frame.width / total
                places.append((x, width))
                x += width + gutter
            }
            return places
        }
        // Equal slots, each member centred in its own, as a generated row is.
        let slot = new.width / CGFloat(row.count)
        return row.enumerated().map { index, element in
            let width = isTurned(element) ? box(of: element).width : min(element.frame.width, slot - gutter)
            return (new.x + CGFloat(index) * slot + (slot - width) / 2, width)
        }
    }

    // MARK: Riding

    /// What each element that rides on another rides on: an image or a shape, visible and
    /// larger than it and no backdrop on `device`, with at least `ridesOn` of its area
    /// inside. Of several, the smallest, so that a caption on a photo on a card goes with
    /// the photo.
    static func hosts(in elements: [DesignElement], on device: DeviceFrame) -> [DesignElement.ID: DesignElement] {
        let candidates = elements.filter { carries.contains($0.kind) && !$0.isHidden && $0.kind.belongsOnScreens && !isBackdrop($0, on: device) }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
        var hosts: [DesignElement.ID: DesignElement] = [:]
        for element in elements where moves(element) {
            let mine = box(of: element)
            let own = area(mine)
            guard own > 0 else { continue }
            let host = candidates
                .filter { $0.id != element.id && area(box(of: $0)) > own && area(box(of: $0).intersection(mine)) >= own * ridesOn }
                .min { area(box(of: $0)) < area(box(of: $1)) }
            if let host { hosts[element.id] = host }
        }
        return hosts
    }

    /// The laid-out frames, with every rider put where its host went: in the same place on
    /// it, as wide in proportion, and a picture's height in proportion too. A rider whose
    /// host stays put stays put, and isn't in the answer.
    private static func carry(_ hosts: [DesignElement.ID: DesignElement], with laid: [DesignElement.ID: CGRect], in elements: [DesignElement]) -> [DesignElement.ID: CGRect] {
        guard !hosts.isEmpty else { return laid }
        let byID = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var frames = laid
        // A host is always larger than its rider, so following hosts up ends.
        func placed(_ element: DesignElement) -> CGRect {
            if let frame = frames[element.id] { return frame }
            guard let host = hosts[element.id] else { return element.frame }
            let to = placed(byID[host.id] ?? host)
            let from = host.frame
            guard to != from, from.width > 0, from.height > 0 else { return element.frame }
            let mine = element.frame
            // A turned host isn't resized: what rides on it goes along as it is.
            if isTurned(host) {
                let frame = mine.offsetBy(dx: to.minX - from.minX, dy: to.minY - from.minY)
                frames[element.id] = frame
                return frame
            }
            let (sx, sy) = (to.width / from.width, to.height / from.height)
            if isTurned(element) {
                // Turned, it keeps its size: its middle goes to the same place on the host,
                // and its box is kept on it.
                let box = box(of: element)
                let midX = to.minX + (mine.midX - from.minX) * sx
                let midY = to.minY + (mine.midY - from.minY) * sy
                let x = min(max(midX, to.minX + box.width / 2), max(to.maxX - box.width / 2, to.minX + box.width / 2))
                let y = min(max(midY, to.minY + box.height / 2), max(to.maxY - box.height / 2, to.minY + box.height / 2))
                let frame = CGRect(x: x - mine.width / 2, y: y - mine.height / 2, width: mine.width, height: mine.height)
                frames[element.id] = frame
                return frame
            }
            let width = mine.width * sx
            let height = min(keepsShape.contains(element.kind) ? mine.height * sx : mine.height, to.height)
            let midX = to.minX + (mine.midX - from.minX) * sx
            let midY = to.minY + (mine.midY - from.minY) * sy
            // Kept on its host, should the host have been held to a height.
            let x = min(max(midX - width / 2, to.minX), max(to.maxX - width, to.minX))
            let y = min(max(midY - height / 2, to.minY), max(to.maxY - height, to.minY))
            let frame = CGRect(x: x, y: y, width: width, height: height)
            frames[element.id] = frame
            return frame
        }
        for id in hosts.keys {
            guard let element = byID[id] else { continue }
            let frame = placed(element)
            if frame == element.frame { frames[id] = nil }
        }
        return frames
    }

    /// The index of the first row pinned to the bottom, or the count when none is: the
    /// last rows, in the bottom quarter of the screen, apart from what is above them.
    private static func firstPinned(_ rows: [[DesignElement]], on device: DeviceFrame) -> Int {
        let zone = device.size.height * 0.75
        var first = rows.count
        while first > 1, rows.count - first < 3, rows[first - 1].allSatisfy({ box(of: $0).minY >= zone }) {
            first -= 1
        }
        guard first < rows.count else { return rows.count }
        let above = rows[first - 1].map { box(of: $0).maxY }.max() ?? 0
        let below = rows[first].map { box(of: $0).minY }.min() ?? 0
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

    /// The top of a row pinned to the bottom so that it clears every obstacle in its way: its
    /// bottom at `bottom`, or moved up above an obstacle it would lie on.
    private static func clear(of obstacles: [CGRect], bottom: CGFloat, row: LaidRow) -> CGFloat {
        var y = bottom - row.height
        guard !row.frames.isEmpty else { return y }
        let across = row.frames.dropFirst().reduce(row.frames[0].1) { $0.union($1.1) }
        var moved = true
        while moved {
            moved = false
            for obstacle in obstacles {
                let band = CGRect(x: across.minX, y: y, width: across.width, height: row.height)
                if band.insetBy(dx: 0, dy: -0.5).intersects(obstacle), obstacle.minX < band.maxX, band.minX < obstacle.maxX {
                    y = obstacle.minY - normal - row.height
                    moved = true
                }
            }
        }
        return y
    }

    /// On whole points. A turned element keeps its size exactly: only where it is is rounded.
    private static func rounded(_ frames: [DesignElement.ID: CGRect], in elements: [DesignElement]) -> [DesignElement.ID: CGRect] {
        let turned = Set(elements.filter(isTurned).map(\.id))
        var rounded = frames
        for (id, frame) in frames {
            let size = turned.contains(id) ? frame.size : CGSize(width: frame.width.rounded(), height: frame.height.rounded())
            rounded[id] = CGRect(origin: CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()), size: size)
        }
        return rounded
    }
}

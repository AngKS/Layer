import CoreGraphics
import Foundation

/// Voice's element tools: adding a thing, rewording, restyling, moving, resizing, turning, duplicating and deleting
/// one, each through the store verb its control in the app uses, in the command's one step.
extension VoiceToolbox {
    // MARK: Elements

    func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String {
        forCommand {
            guard let model else { return gone }
            let host: TreeScreen
            if let screen, !screen.trimmingCharacters(in: .whitespaces).isEmpty {
                switch find(screen: screen) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let found): host = found
                }
            } else {
                switch currentScreen(in: model) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let current): host = current
                }
            }
            guard let kind = LookWords.kind(named: kind), kind.belongsOnScreens else {
                return failed("I can't add “\(kind)”. The kinds are title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, progress, avatar and text.")
            }
            let words = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var node = LayerNode.standard(kind, symbol: kind == .symbol ? (words.isEmpty ? "star" : words) : nil)
            if kind.hasText, !words.isEmpty { node.content.text = words }
            if let look { Self.look(look)?.apply(to: &node) }
            let store = model.store
            let relation = relation.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
            let target = target.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }

            // Beside a thing a row, column or grid on this screen places: it joins that one, next to it.
            if let relation, let target, let side = Self.side(named: relation), case .success(let other) = find(element: target),
               other.screen?.id == host.id, let placer = placer(of: other), let parent = store.parent(of: other.id),
               let slot = store.index[other.id]?.siblingIndex {
                guard store.add(node, to: parent, at: side == .below || side == .rightOf ? slot + 1 : slot) else {
                    return failed("That couldn't be added.")
                }
                reveal(.element(NodeRef(host: .screen(host.id), node: node.id)), in: model)
                let added = done("Added \(Self.describe(node, article: "a")) as \(handles.handle(forNode: node.id)).")
                return added + " " + done("Put \(Self.describe(node)) \(side.rawValue) \(Self.describe(other.node)) in \(placer.handle).")
            }

            // Below what is on a free root; last in a root that lays things out, which places it.
            if host.root.resolvedLayout == .free, let frame = store.newElementFrame(kind, on: host.id) { node.frame = frame }
            guard store.add(node, to: .screen(host.id)) else { return failed("That couldn't be added.") }
            reveal(.element(NodeRef(host: .screen(host.id), node: node.id)), in: model)
            let handle = handles.handle(forNode: node.id)
            let added = done("Added \(Self.describe(node, article: "a")) as \(handle).")
            // "Add an image below the title": put by the other one as it is added.
            if let relation, let target {
                return added + " " + placeElement(element: handle, relation: relation, target: target)
            }
            return added
        }
    }

    func setText(element: String, text: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                // Asked for a text colour, a small model will hand the colour over as the
                // words. A colour on its own, in lower case, is taken as the words' colour.
                if let colour = Self.colourMeantAsWords(text) {
                    return styleElement(element: element, look: "text \(colour)")
                }
                // A card, row or other container shows the words of what it holds, not words of its own.
                if found.node.isContainer {
                    let what = found.node.kindName.lowercased()
                    return failed("\(handle(of: found)) is \(Self.article(for: what)) \(what), which has no words of its own.")
                }
                guard found.node.kind.hasText else {
                    return failed("The \(found.node.kind.layerName.lowercased()) has no words to change.")
                }
                reveal(.element(found.ref), in: model)
                model.store.update(found.id) { $0.content.text = text }
                return done("Reworded the \(found.node.kind.layerName.lowercased()) to “\(text)”.")
            }
        }
    }

    /// A look goes to the thing named, or, for a plain group (a free one, a row, a column, a grid or an overlay), to
    /// each thing it holds, in one step: "make these blue" with a group selected recolours what is in it. A card takes
    /// it itself (call 7).
    ///
    /// A width word (fill, fit) is about the thing named, never what it holds: "make the row full width" stretches the
    /// row. It is told where it changes nothing, rather than kept there (`widthRefusal`).
    func styleElement(element: String, look: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let words = Self.look(look) else {
                    return failed("I didn't understand the look “\(look)”. Try words such as blue, bold, 18pt, radius 12 or text white.")
                }
                var rest = words
                rest.width = nil
                let refusal = words.width.flatMap { widthRefusal($0, for: found) }
                let width = refusal == nil ? words.width : nil
                let restyled = rest == Look() ? [] : found.node.kind == .group ? found.node.leaves.map(\.id) : [found.id]
                guard width != nil || !restyled.isEmpty else {
                    // Only a width that changes nothing where it is, or a group that holds nothing to restyle.
                    return failed(refusal ?? "\(handle(of: found)) holds nothing, so nothing was restyled.")
                }
                reveal(.element(found.ref), in: model)
                let store = model.store
                store.asOneStep {
                    if let width { store.update(found.id) { Look(width: width).apply(to: &$0) } }
                    for id in restyled { store.update(id) { rest.apply(to: &$0) } }
                }
                let line = done("Restyled \(Self.describe(found.node)).")
                return refusal.map { line + " " + noted($0) } ?? line
            }
        }
    }

    /// Why a width word changes nothing on `found`, or nil where it does. Fill takes the room a row, column or grid
    /// gives, and fit is as wide as what is in it: in a free parent, which gives no room and places a leaf by its frame,
    /// only a container's fit does anything.
    private func widthRefusal(_ width: Look.Width, for found: Found) -> String? {
        guard !found.placed.isLaidOut else { return nil }
        let handle = handle(of: found)
        switch (found.node.isContainer, width) {
        case (true, .fit): return nil
        case (true, .fill): return "\(handle) isn't in a row, column or grid, so fill doesn't apply to it. To change its width, call moveElement with a width."
        case (false, _): return "\(handle) isn't in a row, column or grid, so fill and fit don't apply to it. To change its width, call moveElement with a width."
        }
    }

    /// In a free parent, a position or a size is where it goes or how big it is, in its host's points. A container goes
    /// whole, moved and resized as the Format panel's X, Y, W and H move and resize one (`DesignStore.setBox`): a size
    /// scales it in proportion. A thing a row, column, grid or overlay places is
    /// only resized by its numbers, which fixes the axes they change: a position changes nothing, and the model is
    /// told how to reorder it or take it out, which `takeOut` does through the drag rule (call 8). Under a screen's
    /// root that lays things out, there is nowhere to take it out to (F15).
    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handle(of: found)
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                let given = [x, y, width, height].map { $0?.trimmingCharacters(in: .whitespaces) }.map { $0?.isEmpty == true ? nil : $0 }
                let isPositioned = given[0] != nil || given[1] != nil
                let isTakingOut = Self.saysYes(takeOut)
                let placer = placer(of: found)
                if let placer {
                    if !placer.canTakeOut, isPositioned || isTakingOut { return failed(placedLine(handle, placer)) }
                    if isTakingOut, !isPositioned { return failed("Say where \(handle) goes: x and y.") }
                    if !isTakingOut, isPositioned { return failed(placedLine(handle, placer)) }
                }
                guard given.contains(where: { $0 != nil }) else { return failed("Say where it should go or how big it should be.") }
                // On a screen, shares are of the screen. A loose element has no screen to share.
                let screenSize = found.screen.flatMap { model.store.device(of: $0.id)?.size }
                // Loose elements are given in canvas points and kept in points of their own.
                let scale: CGFloat = found.screen == nil ? found.placed.placement.scale : 1
                var values: [CGFloat?] = []
                for (index, written) in given.enumerated() {
                    guard let written else {
                        values.append(nil)
                        continue
                    }
                    let extent = index.isMultiple(of: 2) ? screenSize?.width : screenSize?.height
                    // Said plainly: told only that "50%" wasn't understood, a model tries
                    // some other number of its own.
                    if extent == nil, written.hasSuffix("%") {
                        return failed("That isn't on a screen, so it can't be a share of one. Give its size in points, such as 180.")
                    }
                    guard let value = Self.length(written, of: extent), index < 2 || value >= 1 else {
                        return failed("I didn't understand the size “\(written)”. Give points, such as 180, or a share of the screen, such as 50%.")
                    }
                    values.append(value / scale)
                }
                // Its upright frame in its host's points, as the canvas and the picture have it.
                var frame = found.placed.frame
                if let x = values[0] { frame.origin.x = x }
                if let y = values[1] { frame.origin.y = y }
                if let width = values[2] { frame.size.width = width }
                if let height = values[3] { frame.size.height = height }
                let isResize = values[2] != nil || values[3] != nil
                reveal(.element(found.ref), in: model)
                let store = model.store
                if let placer {
                    guard isTakingOut else {
                        store.move(found.id, toHostFrame: frame, size: true)
                        return done("Resized \(Self.describe(found.node)).")
                    }
                    return self.takeOut(found, handle: handle, from: placer, to: frame)
                }
                if found.node.isContainer {
                    store.setBox(of: found.ref, x: values[0], y: values[1], width: values[2], height: values[3])
                } else {
                    store.place(found.id, at: frame)
                }
                return done("\(isResize ? "Resized" : "Moved") \(Self.describe(found.node)).")
            }
        }
    }

    /// Takes a laid-out thing out to `frame`, by the drag rule (`DesignStore.move(_:toHostFrame:)`): onto its host's top
    /// there, or into the row, column or grid on its host that the frame's middle falls in.
    private func takeOut(_ found: Found, handle: String, from placer: Placer, to frame: CGRect) -> String {
        guard let store = model?.store else { return gone }
        switch store.move(found.id, toHostFrame: frame) {
        case .takenOut:
            return done("Took \(handle) out of \(placer.handle).")
        case .reordered:
            let now = self.placer(of: found.id)
            guard let now, now.handle != placer.handle else { return done("Moved \(handle) to another place in \(placer.handle).") }
            return done("Moved \(handle) into the \(now.word) \(now.handle), which places it.")
        case .resized, .placed:
            return done("Resized \(Self.describe(found.node)).")
        case .unchanged:
            return noted("\(handle) is there already.")
        case .refused:
            var nowhere = placer
            nowhere.canTakeOut = false
            return failed(placedLine(handle, nowhere))
        }
    }

    /// Whether the words say yes: `yes`, `true` or `y`.
    private static func saysYes(_ words: String?) -> Bool {
        guard let words else { return false }
        return ["yes", "true", "y"].contains(words.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
    }

    func rotateElement(element: String, angle: String?, by: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handle(of: found)
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                let words = [angle, by].map { $0?.trimmingCharacters(in: .whitespaces) }.map { $0?.isEmpty == true ? nil : $0 }
                // The angle wins when both are given.
                guard let written = words[0] ?? words[1] else {
                    return failed("Say an angle, such as 45, or how far to turn it, such as 15.")
                }
                guard let degrees = Self.degrees(written) else {
                    return failed("I didn't understand the angle “\(written)”.")
                }
                // On the canvas, its containers' turns included. A laid-out child turns where it is placed, which
                // is how it is seen, as in SwiftUI.
                let target = words[0] != nil ? degrees : found.placed.degrees + degrees
                reveal(.element(found.ref), in: model)
                model.store.setCanvasAngles([found.id: target])
                return done("Turned \(handle) to \(Int(Rotation.shown(target)))°.")
            }
        }
    }

    /// Reads "45", "45°", "45 degrees" and "-15"; nil for anything else, including "nan".
    private static func degrees(_ written: String) -> Double? {
        var text = written.lowercased().trimmingCharacters(in: .whitespaces)
        for unit in ["degrees", "degree", "deg", "°"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    func duplicateElement(element: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let copy = model.store.duplicate(node: found.id) else { return failed("That couldn't be duplicated.") }
                reveal(.element(NodeRef(host: found.ref.host, node: copy)), in: model)
                return done("Duplicated \(Self.describe(found.node)) as \(handles.handle(forNode: copy)).")
            }
        }
    }

    /// A container goes with everything in it, and only by its own word: "card", "row", "group" or its name.
    func deleteElement(element: String, named: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                if let refusal = refusesToDelete() { return refusal }
                let handle = handle(of: found)
                // Only what the person named goes: see `VoiceNaming`. A handle given as the
                // name is no name at all.
                if let named, VoiceHandles.tidied(named) == nil, !Self.fits(named, found.node) {
                    return failed("There is no \(named.trimmingCharacters(in: .whitespaces)) here. That is \(Self.describe(found.node)).")
                }
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                model.store.delete(nodes: [found.id])
                return done("Deleted \(Self.describe(found.node)).")
            }
        }
    }

    /// The colour that new "words" really are: `blue` or `text blue`, in lower case, as a
    /// model writes a colour and not as anyone writes a label.
    private static func colourMeantAsWords(_ text: String) -> String? {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words == words.lowercased() else { return nil }
        if words.hasPrefix("text ") { words = String(words.dropFirst(5)) }
        return ColourWords.named[words] != nil ? words : nil
    }

    /// Whether what the person called something fits a node: by what its kind is
    /// called, by the words on it, or by its own name. A container goes by what the Layers
    /// panel calls it too, such as "row" or "card", and by its own name, never by the
    /// words of what it holds: "delete the Wi-Fi" isn't the row.
    private static func fits(_ named: String, _ node: LayerNode) -> Bool {
        var kindNames = (LookWords.kindWords.first { $0.kind == node.kind }?.words ?? []) + [node.kind.layerName]
        if node.isContainer { kindNames.append(node.kindName) }
        // "Email field" and the like say what a field is for, not what it is. That is for
        // the words on the field to bear out, or any field would answer to "password field".
        if node.kind == .textField { kindNames.removeAll { ["search field", "email field", "password field"].contains($0) } }
        // Anything with words on it can be called "the text".
        let loose = node.kind.hasText ? ["text", "words", "label", "copy"] : []
        return VoiceNaming.fits(named, names: kindNames + loose,
                                words: "\(node.content.text) \(node.name ?? "") \(node.content.symbol ?? "")")
    }

    /// The look some words describe; nil if none of them meant anything.
    private static func look(_ look: String) -> Look? {
        let words = LookWords.look(from: look.components(separatedBy: ","))
        return words == Look() ? nil : words
    }

    /// A length as written: points (`180`, `44pt`) or a share of `extent` (`50%`).
    private static func length(_ written: String, of extent: CGFloat?) -> CGFloat? {
        var text = written.lowercased().trimmingCharacters(in: .whitespaces)
        // "nan" and "inf" read as numbers. A frame with either in it can't be laid out.
        if text.hasSuffix("%") {
            guard let extent, let share = Double(text.dropLast().trimmingCharacters(in: .whitespaces)), share.isFinite else { return nil }
            return (extent * CGFloat(share) / 100).rounded()
        }
        for unit in ["points", "point", "pts", "pt"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        guard let value = Double(text), value.isFinite else { return nil }
        return CGFloat(value)
    }
}

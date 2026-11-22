import CoreGraphics
import Foundation

/// Carries spoken commands out on a design. Every change goes through the design's store
/// and the same code the Siri actions use, so a change made by voice is the change made by
/// hand: undoable, and seen by everything that watches the design.
///
/// Nothing here throws for a request that can't be met. A model that names something
/// that isn't there is told so in a line, and can try again or say so.
@MainActor
final class VoiceToolbox: VoiceActing {
    private weak var model: AppModel?
    private let handles: VoiceHandles

    /// What each step of the command under way did, in order.
    private(set) var lines: [String] = []
    /// What couldn't be done, and why.
    private(set) var failures: [String] = []
    /// Whether the command asked to hang up.
    private(set) var endsCall = false
    /// Whether the last thing tried was one that couldn't be done.
    private(set) var lastFailed = false

    init(model: AppModel, handles: VoiceHandles) {
        self.model = model
        self.handles = handles
    }

    /// Where a new screen goes for the command under way, in canvas points: where the
    /// pencil pointed at empty canvas. Nil puts it where screens always go.
    var newScreenAnchor: CGPoint?

    /// The screen the command under way is for, when it can change nothing else: a change
    /// asked of one screen. Another screen, an element not on this one (loose ones too) and
    /// a new screen are refused, and a tool given no screen means this one, whatever is
    /// selected. Nil lets a command go anywhere.
    var scope: DesignScreen.ID?

    /// What a correction ("No, …") may do with the undo and redo tools in the command under
    /// way. A correction for one screen undoes only that screen's last change, which its
    /// agent undoes itself before the model is asked (`VoiceAgent`); the model can't tell
    /// whose the step on top is.
    enum CorrectionUndo {
        /// Undo or redo a command's step, as in a command that can go anywhere.
        case allowed
        /// Nothing more: the screen's last change has been undone already. The model is
        /// told so, which is no failure: what it asked for is done.
        case alreadyDone
        /// Nothing: the step on top may be another screen's.
        case refused
    }

    var correctionUndo = CorrectionUndo.allowed

    /// Makes what a tool changes the spoken command's under way: one step with the rest of
    /// the command, and never one with what the person does meanwhile (V1).
    private func forCommand<T>(_ body: () -> T) -> T {
        guard let store = model?.store else { return body() }
        return store.actingForCommand(body)
    }

    /// Forgets the last command's results, ready for the next.
    func reset() {
        lines = []
        failures = []
        endsCall = false
        lastFailed = false
        newScreenAnchor = nil
        scope = nil
        correctionUndo = .allowed
    }

    // MARK: Screens

    /// Puts several elements one after another, none overlapping: down a column with
    /// their left edges together, or along a row with their tops together, 12 points
    /// apart. They keep the order they stand in; those on top of one another, which have
    /// none, take the order they were named in. It starts where the first of them is.
    /// What was said, for the command under way: a delete goes ahead only if it asks for
    /// one. Nil where no one spoke, as in tests of a tool alone.
    var spokenCommand: String?

    /// Whether what was said asks for something to be taken away. Three times the
    /// on-device model answered a command that said nothing of the kind with a delete.
    static func asksToRemove(_ said: String) -> Bool {
        let words = said.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let removing: Set<String> = [
            "delete", "deleting", "deleted", "remove", "removing", "erase", "erasing", "clear", "bin", "trash", "scrap",
            "discard", "ditch", "drop", "kill", "lose", "cut",
        ]
        if words.contains(where: removing.contains) { return true }
        if let get = words.firstIndex(of: "get"), words.dropFirst(get + 1).first == "rid" { return true }
        if let take = words.firstIndex(of: "take"), !Set(words[take...]).isDisjoint(with: ["out", "off", "away"]) { return true }
        return false
    }

    private func refusesToDelete() -> String? {
        guard let spokenCommand, !Self.asksToRemove(spokenCommand) else { return nil }
        // The model's doing, not the person's: it is said that way round.
        return failed("That would have deleted something you didn't ask to remove, so nothing was changed.")
    }

    /// Puts one element next to another, 12 points from it: below or above it with their
    /// left edges together, or beside it with their tops together.
    func placeElement(element: String, relation: String, target: String) -> String {
        forCommand {
            guard let model else { return gone }
            guard let side = Self.side(named: relation) else {
                return failed("I can put it above, below, left of or right of another, not “\(relation)”.")
            }
            // Next to the screen it is on is an edge of that screen: asked for "the image to
            // the top", the on-device model names the screen here, or the element at the top.
            // Unless one thing was said to go by another, an edge is what was meant.
            let askedToPlace = spokenCommand.map(Self.asksToPlace) ?? true
            if VoiceHandles.tidied(target)?.hasPrefix("S") == true || !askedToPlace {
                let edge = switch side {
                case .above: "top"
                case .below: "bottom"
                case .leftOf: "left"
                case .rightOf: "right"
                }
                return alignElement(element: element, alignment: edge)
            }
            let moving: FoundElement
            let other: FoundElement
            switch (find(element: element), find(element: target)) {
            case (.failure(let refusal), _), (_, .failure(let refusal)): return failed(refusal.line)
            case (.success(let one), .success(let two)): (moving, other) = (one, two)
            }
            guard moving.ref != other.ref else {
                return failed("Name two different elements. To add a new one next to another, give addElement where it goes.")
            }
            guard moving.ref.host == other.ref.host else { return failed("Those aren't on the same screen.") }
            guard !moving.element.isLocked else { return failed("\(handles.handle(forElement: moving.element.id)) is locked.") }
            let store = model.store
            guard let frame = store.canvasFrame(of: .element(moving.ref)), let by = store.canvasFrame(of: .element(other.ref)) else {
                return failed("That couldn't be placed.")
            }
            // In the points of the screen they are on.
            let gap = 12 * (store.resolve(moving.ref)?.placement.scale ?? 1)
            let origin = switch side {
            case .below: CGPoint(x: by.minX, y: by.maxY + gap)
            case .above: CGPoint(x: by.minX, y: by.minY - gap - frame.height)
            case .leftOf: CGPoint(x: by.minX - gap - frame.width, y: by.minY)
            case .rightOf: CGPoint(x: by.maxX + gap, y: by.minY)
            }
            reveal(.element(moving.ref), in: model)
            store.position([.element(moving.ref): origin])
            return done("Put \(Self.describe(moving.element)) \(side.rawValue) \(Self.describe(other.element)).")
        }
    }

    /// Whether what was said puts one thing by another: "below the title", "next to it".
    /// "On the left" and "to the top" are edges of the screen.
    static func asksToPlace(_ said: String) -> Bool {
        let words = said.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if !Set(words).isDisjoint(with: ["below", "under", "underneath", "beneath", "above", "beside", "besides"]) { return true }
        for (one, next) in zip(words, words.dropFirst()) {
            if (one == "next" && next == "to") || (["left", "right", "top"].contains(one) && next == "of") { return true }
        }
        return false
    }

    enum Side: String {
        case below, above
        case leftOf = "left of"
        case rightOf = "right of"
    }

    static func side(named words: String) -> Side? {
        let said = Set(words.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        if !said.isDisjoint(with: ["below", "under", "underneath", "beneath"]) { return .below }
        if !said.isDisjoint(with: ["above", "over", "top"]) { return .above }
        if said.contains("left") { return .leftOf }
        if !said.isDisjoint(with: ["right", "beside", "next"]) { return .rightOf }
        return nil
    }

    /// The handles in a list such as "E3, E4" or "E2 E1". A handle written loosely, "E 2",
    /// is one.
    private static func handleList(_ written: String) -> [String] {
        written.components(separatedBy: CharacterSet(charactersIn: ",;&")).flatMap { part -> [String] in
            let part = part.replacingOccurrences(of: " and ", with: " ")
            let words = part.split(separator: " ").map(String.init)
            return words.count > 1 && words.allSatisfy({ VoiceHandles.tidied($0) != nil }) ? words : [part]
        }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    func stackElements(elements: String, direction: String) -> String {
        forCommand {
            guard let model else { return gone }
            let isColumn: Bool
            switch direction.lowercased().trimmingCharacters(in: .whitespaces) {
            case "column", "vertical", "vertically", "down": isColumn = true
            case "row", "horizontal", "horizontally", "across": isColumn = false
            default: return failed("I can stack in a column or a row, not “\(direction)”.")
            }
            let named = Self.handleList(elements)
            var found: [FoundElement] = []
            for handle in named {
                switch find(element: handle) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let one):
                    guard !one.element.isLocked else { return failed("\(handles.handle(forElement: one.element.id)) is locked.") }
                    if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
                }
            }
            guard found.count > 1 else { return failed("Name two or more elements to stack.") }
            guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }

            // Worked out on the canvas, where the store puts things, in the points of the
            // screen they are on: a gap of 12 of those is less on a screen drawn small.
            let store = model.store
            let scale = store.resolve(found[0].ref)?.placement.scale ?? 1
            let gap = 12 * scale
            var placed: [(ref: DesignStore.ElementRef, frame: CGRect)] = found.compactMap { one in
                store.canvasFrame(of: .element(one.ref)).map { (one.ref, $0) }
            }
            guard placed.count == found.count else { return failed("Those couldn't be stacked.") }
            // A stable sort: things at the same place keep the order they were named in.
            placed = placed.enumerated().sorted { a, b in
                let (one, other) = isColumn ? (a.element.frame.minY, b.element.frame.minY) : (a.element.frame.minX, b.element.frame.minX)
                return abs(one - other) > 0.5 ? one < other : a.offset < b.offset
            }.map(\.element)
            let left = placed.map(\.frame.minX).min() ?? 0
            let top = placed.map(\.frame.minY).min() ?? 0
            var next = isColumn ? top : left
            var origins: [CanvasSelection: CGPoint] = [:]
            for (ref, frame) in placed {
                origins[.element(ref)] = isColumn ? CGPoint(x: left, y: next) : CGPoint(x: next, y: top)
                next += (isColumn ? frame.height : frame.width) + gap
            }
            reveal(.element(placed[0].ref), in: model)
            store.position(origins)
            // All of them stay selected, so that "them" goes on meaning them.
            select(.several(Set(placed.map { .element($0.ref) })), in: model)
            return done("Stacked \(placed.count) elements in a \(isColumn ? "column" : "row").")
        }
    }

    /// The way to pan that some words ask for, and how far, as a share of what is in
    /// view: "down" is most of a view, "down a bit" half of that. Nil for anything that
    /// isn't only a direction: a handle, or a name with "left" in it.
    static func pan(named target: String) -> (name: String, shift: CGVector)? {
        let said = target.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let little: Set<String> = ["bit", "little", "slightly", "touch"]
        let empty: Set<String> = ["pan", "scroll", "move", "go", "the", "view", "canvas", "a", "to", "it"]
        let ways = said.filter { !little.contains($0) && !empty.contains($0) }
        guard ways.count == 1 else { return nil }
        let isLittle = said.contains(where: little.contains)
        let share: CGFloat = isLittle ? 0.3 : 0.6
        let way: String
        let shift: CGVector
        switch ways[0] {
        case "up", "upward", "upwards": (way, shift) = ("up", CGVector(dx: 0, dy: -share))
        case "down", "downward", "downwards": (way, shift) = ("down", CGVector(dx: 0, dy: share))
        case "left": (way, shift) = ("left", CGVector(dx: -share, dy: 0))
        case "right": (way, shift) = ("right", CGVector(dx: share, dy: 0))
        default: return nil
        }
        return (isLittle ? "\(way) a little" : way, shift)
    }

    /// Where the middle of the view goes when it is panned by a share of itself.
    static func centre(of visible: CGRect, panned shift: CGVector) -> CGPoint {
        CGPoint(x: visible.midX + shift.dx * visible.width, y: visible.midY + shift.dy * visible.height)
    }

    /// What a model said, with each handle in it put as the thing it stands for. Handles
    /// are between the app and the model: a person asked "E24, E25 or E26?" can't answer.
    func inWords(_ text: String) -> String {
        guard let model else { return text }
        var said = ""
        var rest = text[...]
        while let match = rest.firstMatch(of: /\b[ES]\d+\b/) {
            let handle = String(match.output)
            var before = rest[..<match.range.lowerBound]
            var after = rest[match.range.upperBound...]
            // A model puts a handle in quotes as often as not. The quotes go with it.
            let isQuoted = before.last.map("“\"'‘".contains) == true && after.first.map("”\"'’".contains) == true
            var words: String?
            if let id = handles.screen(handle), let screen = model.store.screen(id) {
                // "Screen S2" and “S2” already say it is a screen.
                let isCalledAScreen = before.lowercased().hasSuffix("screen ") || (isQuoted && before.dropLast().lowercased().hasSuffix("screen "))
                words = isCalledAScreen ? "“\(screen.name)”" : "the screen “\(screen.name)”"
            } else if case .success(let found) = locate(element: handle) {
                // Off the screen a change is for, it is still said as what it is.
                words = Self.describe(found.element)
            }
            guard var words else {
                said += before + handle
                rest = after
                continue
            }
            if isQuoted {
                before = before.dropLast()
                after = after.dropFirst()
            }
            said += before
            // At the start of a sentence it takes the capital the handle had.
            let sofar = said.trimmingCharacters(in: .whitespaces)
            if sofar.isEmpty || ".!?".contains(sofar.last ?? " ") { words = words.prefix(1).uppercased() + words.dropFirst() }
            said += words
            rest = after
        }
        return said + rest
    }

    func createScreen(name: String?, description: String, device: String?) async throws -> String {
        guard let model else { throw CancellationError() }
        // A change for one screen makes no other.
        if let scoped = outsideTheScope { return failed(scoped.line) }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return failed("Say what the screen is for.") }
        guard !model.isClosed else { return failed(AppModel.closedProblem) }
        guard !model.isGenerating else { return failed("A screen is already being written.") }
        // A device word that isn't one is passed over: the screen is still wanted, and
        // the design's usual device is the likeliest one meant.
        let usual = model.store.canvas.sketchDevice
        // The device the model named, or else the one the person did: on an iPad the
        // model left it out, and "on the MacBook" got a phone screen.
        let frame = device.flatMap { Self.device(named: $0, preferring: usual) }
            ?? spokenCommand.flatMap { Self.device(named: $0, preferring: usual) }
        // What the voice model asked for, so that a session log shows it beside the screen made.
        VoiceLog.log.info("tool: createScreen \"\(description, privacy: .public)\" on \((frame ?? usual).id, privacy: .public) (said \(device ?? "nothing", privacy: .public))")
        // Inside a command the screen is part of the command's own undo step.
        model.store.actingForCommand {
            model.generateScreen(from: description, named: Self.screenName(name), near: newScreenAnchor, device: frame)
        }
        guard let screenID = model.generation?.screenID else { return failed("The screen couldn't be started.") }
        // Stopping the command stops the model; what it has written so far stays.
        await withTaskCancellationHandler {
            await model.waitForGeneration()
        } onCancel: {
            Task { @MainActor in model.stopGenerating() }
        }
        let outcome = model.generation?.phase
        // The pill has said how it went, so the canvas's own notice isn't left behind.
        model.dismissGeneration()
        try Task.checkCancellation()
        if case .failed(let reason) = outcome { return failed(reason) }
        guard let screen = model.store.screen(screenID) else {
            // Taken away while it was being written, by undo or by hand.
            return failed(outcome == nil ? "The screen was taken away while it was being written." : "The model didn't describe any elements.")
        }
        let count = screen.elements.count
        // Said so: seeing the new screen in its canvas list, a model took it for another
        // one already there with the same name.
        return done("Made the screen “\(screen.name)” as \(handles.handle(forScreen: screenID)), with \(count == 1 ? "1 element" : "\(count) elements"). It is the \(handles.handle(forScreen: screenID)) now in the canvas list.")
    }

    func renameScreen(screen: String, name: String) -> String {
        forCommand {
            guard let model else { return gone }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return failed("Say what to call it.") }
            switch find(screen: screen) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                model.store.updateScreen(found.id) { $0.name = name }
                reveal(.screen(found.id), in: model)
                return done("Renamed \(handles.handle(forScreen: found.id)) to “\(name)”.")
            }
        }
    }

    func deleteScreen(screen: String, named: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(screen: screen) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                if let refusal = refusesToDelete() { return refusal }
                let handle = handles.handle(forScreen: found.id)
                // Only what the person named goes: see `VoiceNaming`. A handle given as the
                // name is no name at all.
                if let named, VoiceHandles.tidied(named) == nil, !VoiceNaming.fits(named, names: [], words: found.name) {
                    return failed("There is no \(named.trimmingCharacters(in: .whitespaces)) here. That screen is “\(found.name)”.")
                }
                guard found.isLocked != true else { return failed("\(handle) is locked.") }
                model.store.deleteScreen(found.id)
                return done("Deleted the screen “\(found.name)”.")
            }
        }
    }

    /// Lays a whole screen out again with design sense: see `ScreenTidy`. One change, so
    /// one undo puts it back.
    func tidyScreen(screen: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch screenMeant(screen, in: model) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let frames = ScreenTidy.frames(for: found.elements, on: found.device)
                let handle = handles.handle(forScreen: found.id)
                guard !frames.isEmpty else { return failed("There is nothing on \(handle) that can be tidied.") }
                reveal(.screen(found.id), in: model)
                model.store.updateScreen(found.id) { Self.apply(frames, to: &$0) }
                return done("Tidied the layout of \(handle).")
            }
        }
    }

    /// Makes a screen another device's and lays what is on it out again for that size,
    /// so that it looks made for it rather than a phone's layout in a tablet's corner.
    func changeScreenDevice(screen: String?, device: String) -> String {
        forCommand {
            guard let model else { return gone }
            guard let frame = Self.device(named: device, preferring: model.store.canvas.sketchDevice) else {
                return failed("I can make it an iPhone, iPad or Mac screen, not “\(device)”.")
            }
            switch screenMeant(screen, in: model) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handles.handle(forScreen: found.id)
                let named = "\(Self.article(for: frame.name)) \(frame.name) screen (\(Int(frame.size.width)) × \(Int(frame.size.height)))"
                guard found.device.id != frame.id else { return done("\(handle) is already \(named).") }
                let frames = ScreenTidy.frames(for: found.elements, on: frame, from: found.device)
                model.store.updateScreen(found.id) { screen in
                    // An iPhone is kept as no device at all, as the Siri action keeps it.
                    screen.deviceID = frame.id == DeviceFrame.iPhone.id ? nil : frame.id
                    Self.apply(frames, to: &screen)
                }
                reveal(.screen(found.id), in: model)
                return done("Made \(handle) \(named).")
            }
        }
    }

    private static func apply(_ frames: [DesignElement.ID: CGRect], to screen: inout DesignScreen) {
        for index in screen.elements.indices {
            if let frame = frames[screen.elements[index].id] { screen.elements[index].frame = frame }
        }
    }

    private static func article(for name: String) -> String {
        name.first.map { "aeiouAEIOU".contains($0) } == true ? "an" : "a"
    }

    /// The device some words name: "iPad", "iPhone Pro Max", "a webpage", "laptop". A
    /// word that names only a family, such as "phone", "tablet" or "Mac", is `usual` when
    /// that is of the family, so a design made on an iPad mini goes on with iPad minis.
    static func device(named words: String, preferring usual: DeviceFrame = .iPhone) -> DeviceFrame? {
        let said = words.lowercased()
            .replacingOccurrences(of: "web page", with: "webpage").replacingOccurrences(of: "web site", with: "website")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let all = Set(said)
        func frame(_ id: String) -> DeviceFrame? { DeviceFrame.all.first { $0.id == id } }
        func family(_ family: DeviceFrame.Family, _ id: String) -> DeviceFrame? {
            usual.family == family ? usual : frame(id)
        }
        let iPad = all.contains("ipad") || all.contains("tablet")
        let mac = !all.isDisjoint(with: ["mac", "macbook", "imac", "desktop", "laptop", "computer", "web", "webpage", "website", "browser", "site"])
        let phone = !all.isDisjoint(with: ["iphone", "phone", "mobile", "smartphone"])
        if iPad {
            if all.contains("mini") { return frame("ipad-mini") }
            if all.contains("pro") { return frame("ipad-pro-13") }
            return family(.tablet, "ipad")
        }
        if mac {
            if all.contains("imac") { return frame("imac") }
            if all.contains("macbook"), all.contains("pro") { return frame("macbook-pro-16") }
            if all.contains("macbook") || all.contains("air") { return frame("macbook-air") }
            return family(.desktop, "macbook-air")
        }
        if phone {
            if !all.isDisjoint(with: ["max", "plus", "large", "big"]) { return frame("iphone-pro-max") }
            if !all.isDisjoint(with: ["se", "small", "mini"]) { return frame("iphone-se") }
            return family(.phone, "iphone")
        }
        return nil
    }

    /// The screen a screen tool means. A handle names it, and an element's handle the
    /// screen it is on: pointed at an element, "this screen" is the element's screen, and
    /// the model is told the element's handle. With no handle, or words that aren't one,
    /// it is the screen pointed at: the one selected or holding the selection, else the
    /// one mostly in view, else the newest.
    private func screenMeant(_ given: String?, in model: AppModel) -> Result<DesignScreen, Refusal> {
        if let given, let tidy = VoiceHandles.tidied(given) {
            if tidy.hasPrefix("E") {
                switch find(element: tidy) {
                case .failure(let refusal): return .failure(refusal)
                case .success(let found):
                    guard let screen = found.screen else { return .failure(Refusal(line: "\(tidy) isn't on a screen.")) }
                    return .success(screen)
                }
            }
            return find(screen: tidy)
        }
        // A change for one screen is for that one, whatever is selected.
        if let scoped = scopedScreen(in: model) { return scoped }
        if let selected = model.selectedScreen { return .success(selected) }
        let holding = Set(model.selectedElements.compactMap { found -> DesignScreen.ID? in
            if case .screen(let id) = found.ref.host { id } else { nil }
        })
        if holding.count == 1, let id = holding.first, let screen = model.store.screen(id) { return .success(screen) }
        if model.canvasSize != .zero {
            let visible = model.viewport.visibleRect(in: model.canvasSize)
            let inView = model.store.screens.map { screen -> (DesignScreen, CGFloat) in
                let shown = screen.canvasFrame.intersection(visible)
                let frame = screen.canvasFrame
                return (screen, shown.isNull || frame.isEmpty ? 0 : shown.width * shown.height / (frame.width * frame.height))
            }.filter { $0.1 > 0.3 }.max { $0.1 < $1.1 }
            if let inView { return .success(inView.0) }
        }
        guard let newest = model.store.screens.last else { return .failure(Refusal(line: "There is no screen yet.")) }
        return .success(newest)
    }

    // MARK: Elements

    func addElement(screen: String?, kind: String, text: String?, look: String?, relation: String?, target: String?) -> String {
        forCommand {
            guard let model else { return gone }
            let host: DesignScreen
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
            guard let kind = ScreenBlueprint.kind(named: kind), kind.belongsOnScreens else {
                return failed("I can't add “\(kind)”. The kinds are title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, progress, avatar and text.")
            }
            let words = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var element = DesignStore.newElement(kind, symbol: kind == .symbol ? (words.isEmpty ? "star" : words) : nil)
            if kind.hasText, !words.isEmpty { element.text = words }
            if let look { Self.apply(look: look, to: &element) }
            element.frame = DesignActions.frameForNewElement(element, on: host)
            let ref = model.store.setElements([element], on: host.id, replacing: false)[0]
            reveal(.element(ref), in: model)
            let handle = handles.handle(forElement: element.id)
            let added = done("Added \(Self.describe(element, article: "a")) as \(handle).")
            // "Add an image below the title": put by the other one as it is added.
            if let relation, !relation.trimmingCharacters(in: .whitespaces).isEmpty,
               let target, !target.trimmingCharacters(in: .whitespaces).isEmpty {
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
                guard found.element.kind.hasText else {
                    return failed("The \(found.element.kind.layerName.lowercased()) has no words to change.")
                }
                reveal(.element(found.ref), in: model)
                model.store.update(found.ref) { $0.text = text }
                return done("Reworded the \(found.element.kind.layerName.lowercased()) to “\(text)”.")
            }
        }
    }

    func styleElement(element: String, look: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                var restyled = found.element
                guard Self.apply(look: look, to: &restyled) else {
                    return failed("I didn't understand the look “\(look)”. Try words such as blue, bold, 18pt, radius 12 or text white.")
                }
                reveal(.element(found.ref), in: model)
                model.store.update(found.ref) { $0 = restyled }
                return done("Restyled \(Self.describe(found.element)).")
            }
        }
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard !found.element.isLocked else { return failed("\(handles.handle(forElement: found.element.id)) is locked.") }
                let given = [x, y, width, height].map { $0?.trimmingCharacters(in: .whitespaces) }.map { $0?.isEmpty == true ? nil : $0 }
                guard given.contains(where: { $0 != nil }) else { return failed("Say where it should go or how big it should be.") }
                // On a screen, shares are of the screen. A loose element has no screen to share.
                let screenSize = found.screen?.size
                // Loose elements are given in canvas points and kept in points of their own.
                let scale: CGFloat = found.screen == nil ? (model.store.resolve(found.ref)?.placement.scale ?? 1) : 1
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
                reveal(.element(found.ref), in: model)
                model.store.update(found.ref) { element in
                    if let x = values[0] { element.frame.origin.x = x }
                    if let y = values[1] { element.frame.origin.y = y }
                    if let width = values[2] { element.frame.size.width = width }
                    if let height = values[3] { element.frame.size.height = height }
                }
                let isResize = values[2] != nil || values[3] != nil
                return done("\(isResize ? "Resized" : "Moved") \(Self.describe(found.element)).")
            }
        }
    }

    func rotateElement(element: String, angle: String?, by: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handles.handle(forElement: found.element.id)
                guard !found.element.isLocked else { return failed("\(handle) is locked.") }
                let words = [angle, by].map { $0?.trimmingCharacters(in: .whitespaces) }.map { $0?.isEmpty == true ? nil : $0 }
                // The angle wins when both are given.
                guard let written = words[0] ?? words[1] else {
                    return failed("Say an angle, such as 45, or how far to turn it, such as 15.")
                }
                guard let degrees = Self.degrees(written) else {
                    return failed("I didn't understand the angle “\(written)”.")
                }
                let target = words[0] != nil ? degrees : found.element.resolvedRotation + degrees
                reveal(.element(found.ref), in: model)
                model.store.update(found.ref) { $0.setRotation(target) }
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

    func alignElement(element: String, alignment: String) -> String {
        forCommand {
            guard let model else { return gone }
            let named = Self.handleList(element)
            if named.count > 1 { return alignTogether(named, alignment: alignment) }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let (edge, name) = Self.alignment(named: alignment) else {
                    return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
                }
                guard found.screen != nil else { return failed("\(handles.handle(forElement: found.element.id)) isn't on a screen to line up with.") }
                guard !found.element.isLocked else { return failed("\(handles.handle(forElement: found.element.id)) is locked.") }
                reveal(.element(found.ref), in: model)
                model.store.align(found.ref, edge)
                return done("Aligned \(Self.describe(found.element)) to the \(name).")
            }
        }
    }

    /// Lines several elements up with one another: by an edge, or through the middle, of
    /// the area they cover together.
    private func alignTogether(_ named: [String], alignment: String) -> String {
        guard let model else { return gone }
        guard let (edge, name) = Self.alignment(named: alignment) else {
            return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
        }
        var found: [FoundElement] = []
        for handle in named {
            switch find(element: handle) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let one):
                guard !one.element.isLocked else { return failed("\(handles.handle(forElement: one.element.id)) is locked.") }
                if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
            }
        }
        guard found.count > 1 else { return alignElement(element: named[0], alignment: alignment) }
        guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }
        let together = CanvasSelection.several(Set(found.map { .element($0.ref) }))
        reveal(.element(found[0].ref), in: model)
        model.store.align(together, edge)
        select(together, in: model)
        let by = name.hasSuffix("centre") ? "\(name)s" : "\(name) edges"
        return done("Lined up \(found.count) elements by their \(by).")
    }

    func duplicateElement(element: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let copy = model.store.duplicate(found.ref) else { return failed("That couldn't be duplicated.") }
                reveal(.element(copy), in: model)
                return done("Duplicated \(Self.describe(found.element)) as \(handles.handle(forElement: copy.element)).")
            }
        }
    }

    func deleteElement(element: String, named: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                if let refusal = refusesToDelete() { return refusal }
                let handle = handles.handle(forElement: found.element.id)
                // Only what the person named goes: see `VoiceNaming`. A handle given as the
                // name is no name at all.
                if let named, VoiceHandles.tidied(named) == nil, !Self.fits(named, found.element) {
                    return failed("There is no \(named.trimmingCharacters(in: .whitespaces)) here. That is \(Self.describe(found.element)).")
                }
                guard !found.element.isLocked else { return failed("\(handle) is locked.") }
                model.store.delete(found.ref)
                return done("Deleted \(Self.describe(found.element)).")
            }
        }
    }

    // MARK: The canvas

    func show(target: String) -> String {
        guard let model else { return gone }
        let word = target.lowercased().trimmingCharacters(in: .whitespaces)
        if ["all", "everything", "fit", "the whole canvas"].contains(word) {
            model.ink?.zoomToFit()
            return done("Showing everything.")
        }
        // "Down a bit" has nothing to show: it is the view that moves.
        if Self.pan(named: target) != nil { return pan(direction: target) }
        // A screen's handle is answered as a screen's: one that names nothing is reported
        // as the screen it would be, and a screen a change isn't for is refused.
        if VoiceHandles.tidied(target)?.hasPrefix("S") == true {
            switch find(screen: target) {
            case .success(let screen):
                DesignActions.reveal(.screen(screen.id), in: model, selecting: scope == nil)
                return done("Showing “\(screen.name)”.")
            case .failure(let refusal):
                return failed(refusal.line)
            }
        }
        switch find(element: target) {
        case .success(let found):
            // Asked for, the view moves even in a change for one screen; the screen stays
            // selected.
            DesignActions.reveal(.element(found.ref), in: model, selecting: scope == nil)
            return done("Showing \(Self.describe(found.element)).")
        case .failure(let refusal):
            return failed(refusal.line)
        }
    }

    /// Moves the view up, down, left or right by most of what is in it, or by half of
    /// that for "a bit".
    func pan(direction: String) -> String {
        guard let model else { return gone }
        guard let pan = Self.pan(named: direction) else {
            return failed("I can move the view up, down, left or right, not “\(direction)”.")
        }
        if model.canvasSize != .zero {
            let visible = model.viewport.visibleRect(in: model.canvasSize)
            model.ink?.glide(toCenter: Self.centre(of: visible, panned: pan.shift), scale: model.viewport.scale)
        }
        return done("Moved the view \(pan.name).")
    }

    func zoom(to level: String) -> String {
        guard let model else { return gone }
        let word = level.lowercased().trimmingCharacters(in: .whitespaces)
        switch word {
        case "in", "closer":
            model.ink?.zoom(to: model.zoomScale * 1.25)
            return done("Zoomed in.")
        case "out", "further":
            model.ink?.zoom(to: model.zoomScale / 1.25)
            return done("Zoomed out.")
        case "fit", "all", "everything":
            model.ink?.zoomToFit()
            return done("Showing everything.")
        default:
            let digits = word.hasSuffix("%") ? String(word.dropLast()) : word
            guard let percent = Double(digits.trimmingCharacters(in: .whitespaces)), percent > 0 else {
                return failed("I can zoom in, out, to fit, or to a percentage such as 150.")
            }
            let scale = min(max(CGFloat(percent) / 100, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
            model.ink?.zoom(to: scale)
            return done("Zoomed to \(Int((scale * 100).rounded()))%.")
        }
    }

    // MARK: History and the call

    func undo() -> String {
        stepThroughHistory(isUndo: true)
    }

    func redo() -> String {
        stepThroughHistory(isUndo: false)
    }

    /// Undo and redo act on whole steps. What the command has done so far is a step
    /// already, and the command goes on in a new one afterwards: the store sees to both.
    private func stepThroughHistory(isUndo: Bool) -> String {
        guard let model else { return gone }
        guard let history = model.store.undoManager, isUndo ? history.canUndo : history.canRedo else {
            return failed(isUndo ? "There is nothing to undo." : "There is nothing to redo.")
        }
        // "Undo" said outright is the Undo button: the last change goes, whoever made it. A
        // correction ("No, …") is about the command, and takes back only a command's step:
        // a model asked to correct a command undid the person's own change instead (I-2).
        // Nor does a correction redo a change made by hand.
        let isCorrection = spokenCommand.flatMap(VoiceAgent.correction(in:)) != nil
        if isCorrection, correctionUndo == .alreadyDone { return noted(Self.undoneAlready) }
        guard !isCorrection || (isUndo ? model.store.lastStepIsCommand : model.store.nextRedoIsCommand) else {
            return failed(Self.changedByHand)
        }
        guard !isCorrection || correctionUndo == .allowed else { return failed(Self.notThisScreens) }
        if isUndo { history.undo() } else { history.redo() }
        return done(isUndo ? "Undid the last change." : "Redid the last change.")
    }

    /// Why a correction won't undo or redo the change at hand.
    static let changedByHand = "That change was made by hand, not by voice, so a correction leaves it. The Undo and Redo buttons work on it."

    /// What the model is told of an undo or redo asked for in a correction for one screen
    /// whose last change has been undone already.
    static let undoneAlready = "The last change made for this screen has been undone already, so nothing more is undone."

    /// Why a correction for one screen won't undo the change at hand: one made otherwise.
    static let notThisScreens = "A correction for one screen undoes only the last change made for it, so this one stays. The Undo button works on it."

    /// A correction with nothing of the last command's to undo: the command changed
    /// nothing, or something has been changed by hand since, which isn't undone in its place.
    /// `notThisScreens` when it is for one screen, and the last command's step is on top but
    /// wasn't a change to that screen.
    func refuseCorrection(notThisScreens: Bool = false) -> String {
        if notThisScreens { return failed(Self.notThisScreens) }
        return failed("There's nothing of the last command's to undo: it changed nothing, or something has been changed by hand since.")
    }

    func endCall() -> String {
        endsCall = true
        return done("Hanging up.")
    }

    // MARK: Finding what was named

    private struct Refusal: Error {
        var line: String
    }

    private struct FoundElement {
        var ref: DesignStore.ElementRef
        var element: DesignElement
        /// The screen it is on; nil for a loose element.
        var screen: DesignScreen?
    }

    private var gone: String { failed("The design has closed.") }

    /// Selects what a tool changed and brings it into view, so that "it" means that one
    /// next. A change for one screen leaves both alone: the screen stays selected, with
    /// the field the change was typed in, and the view stays where the person put it.
    private func reveal(_ target: CanvasSelection, in model: AppModel) {
        guard scope == nil else { return }
        DesignActions.reveal(target, in: model)
    }

    /// Selects several things a tool changed together; not in a change for one screen.
    private func select(_ together: CanvasSelection, in model: AppModel) {
        guard scope == nil else { return }
        model.selection = together
    }

    /// Why nothing can be done in a change for one screen once that screen has gone.
    static let screenGone = "That screen has gone, so nothing can be changed here."

    /// The screen a tool means when none is named in a change for one screen: that one,
    /// or a refusal once it has gone, so that nothing is done to another in its place.
    /// Nil when a command can go anywhere.
    private func scopedScreen(in model: AppModel) -> Result<DesignScreen, Refusal>? {
        guard let scope else { return nil }
        guard let screen = model.store.screen(scope) else {
            return .failure(Refusal(line: Self.screenGone))
        }
        return .success(screen)
    }

    /// The screen a change is for, as a refusal names it: `S1 “Login”`. Nil without one.
    private var scopeNamed: String? {
        guard let scope else { return nil }
        let handle = handles.handle(forScreen: scope)
        guard let name = model?.store.screen(scope)?.name else { return handle }
        return "\(handle) “\(name)”"
    }

    /// Why a change for one screen can't touch another, or make one; nil without a scope.
    private var outsideTheScope: Refusal? {
        scopeNamed.map { Refusal(line: "Only \($0) can be changed here.") }
    }

    private func find(screen handle: String) -> Result<DesignScreen, Refusal> {
        guard let tidy = VoiceHandles.tidied(handle) else {
            return .failure(Refusal(line: "“\(handle)” isn't a handle. Use one from the list, such as S1."))
        }
        guard tidy.hasPrefix("S") else { return .failure(Refusal(line: "There is no screen \(tidy).")) }
        guard let id = handles.screen(tidy), let screen = model?.store.screen(id) else {
            return .failure(Refusal(line: "There is no \(tidy)."))
        }
        if let scope, id != scope, let scoped = outsideTheScope { return .failure(scoped) }
        return .success(screen)
    }

    /// An element a tool may change: one on the screen a change is for, when there is one.
    private func find(element handle: String) -> Result<FoundElement, Refusal> {
        let found = locate(element: handle)
        guard let scope, case .success(let one) = found, one.ref.host != .screen(scope), let screen = scopeNamed else {
            return found
        }
        return .failure(Refusal(line: "\(handles.handle(forElement: one.element.id)) isn't on \(screen), the screen this change is for."))
    }

    /// An element wherever it is, on any screen or loose on the canvas.
    private func locate(element handle: String) -> Result<FoundElement, Refusal> {
        guard let tidy = VoiceHandles.tidied(handle) else {
            return .failure(Refusal(line: "“\(handle)” isn't a handle. Use one from the list, such as E2."))
        }
        guard tidy.hasPrefix("E") else { return .failure(Refusal(line: "There is no element \(tidy).")) }
        guard let id = handles.element(tidy), let store = model?.store else {
            return .failure(Refusal(line: "There is no \(tidy)."))
        }
        // Looked up afresh each time: an element can have moved to another screen.
        for screen in store.screens {
            if let element = screen.elements.first(where: { $0.id == id }) {
                return .success(FoundElement(ref: .init(host: .screen(screen.id), element: id), element: element, screen: screen))
            }
        }
        if let loose = store.floating.first(where: { $0.id == id }) {
            return .success(FoundElement(ref: .init(host: .canvas, element: id), element: loose.element, screen: nil))
        }
        return .failure(Refusal(line: "There is no \(tidy)."))
    }

    /// The screen a new element goes on when none is named: the one a change is for, the
    /// selected one, the one holding the selection, or the newest.
    private func currentScreen(in model: AppModel) -> Result<DesignScreen, Refusal> {
        if let scoped = scopedScreen(in: model) { return scoped }
        if let screen = model.selectedScreen { return .success(screen) }
        if let selected = model.selectedElement, case .screen(let id) = selected.ref.host, let screen = model.store.screen(id) {
            return .success(screen)
        }
        guard let newest = model.store.screens.last else { return .failure(Refusal(line: "There is no screen to add to yet.")) }
        return .success(newest)
    }

    // MARK: Results

    private func done(_ line: String) -> String {
        VoiceLog.log.info("tool: done. \(line, privacy: .private)")
        // The model is told the handle of what was made, to go on with. The pill isn't.
        lines.append(line.replacing(#/ It is the [ES]\d+ now in the canvas list\./#, with: "").replacing(#/ as [ES]\d+/#, with: ""))
        lastFailed = false
        return line
    }

    /// A line for the model about something that needn't be done: neither done, nor a
    /// failure that would be the person's to hear.
    private func noted(_ line: String) -> String {
        VoiceLog.log.info("tool: noted. \(line, privacy: .private)")
        return line
    }

    private func failed(_ line: String) -> String {
        VoiceLog.log.info("tool: couldn't. \(line, privacy: .private)")
        failures.append(line)
        lastFailed = true
        return line
    }

    // MARK: Reading what was asked

    /// "the button “Sign in”", or "a text field “Email”".
    private static func describe(_ element: DesignElement, article: String = "the") -> String {
        let what = DesignDescriber.describe(element)
        // "An image", not "a image".
        let isVowel = what.first.map { "aeiou".contains($0.lowercased()) } == true
        return "\(article == "a" && isVowel ? "an" : article) \(what)"
    }

    /// A screen's name as a model gave it, without the words that only say it is a
    /// screen: "the Welcome screen" is Welcome. Nil if nothing is left to call it by.
    static func screenName(_ given: String?) -> String? {
        var name = (given ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        for article in ["the ", "a ", "an "] where name.lowercased().hasPrefix(article) {
            name = String(name.dropFirst(article.count))
        }
        for kind in [" screen", " page", " view"] where name.lowercased().hasSuffix(kind) {
            name = String(name.dropLast(kind.count))
        }
        name = String(name.trimmingCharacters(in: .whitespaces).prefix(40))
        // With no name to give, a small model gives the handle the screen is about to
        // get, or a word that says only that it is new. Neither is a name.
        let noName: Set<String> = ["new", "another", "next", "other", "untitled", "screen", "page", "view"]
        guard let first = name.first, VoiceHandles.tidied(name) == nil, !noName.contains(name.lowercased()) else { return nil }
        return first.uppercased() + name.dropFirst()
    }

    /// The colour that new "words" really are: `blue` or `text blue`, in lower case, as a
    /// model writes a colour and not as anyone writes a label.
    private static func colourMeantAsWords(_ text: String) -> String? {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words == words.lowercased() else { return nil }
        if words.hasPrefix("text ") { words = String(words.dropFirst(5)) }
        return ColourWords.named[words] != nil ? words : nil
    }

    /// Whether what the person called something fits an element: by what its kind is
    /// called, by the words on it, or by its own name.
    private static func fits(_ named: String, _ element: DesignElement) -> Bool {
        var kindNames = (ScreenBlueprint.kindWords.first { $0.kind == element.kind }?.words ?? []) + [element.kind.layerName]
        // "Email field" and the like say what a field is for, not what it is. That is for
        // the words on the field to bear out, or any field would answer to "password field".
        if element.kind == .textField { kindNames.removeAll { ["search field", "email field", "password field"].contains($0) } }
        // Anything with words on it can be called "the text".
        let loose = element.kind.hasText ? ["text", "words", "label", "copy"] : []
        return VoiceNaming.fits(named, names: kindNames + loose, words: "\(element.text) \(element.name ?? "") \(element.symbol ?? "")")
    }

    /// Gives an element the look some words describe. False if none of them meant anything.
    @discardableResult
    private static func apply(look: String, to element: inout DesignElement) -> Bool {
        let blank = ScreenBlueprint.Item(kind: element.kind, text: element.text)
        var item = blank
        ScreenBlueprint.applyLook(look.components(separatedBy: ","), to: &item)
        guard item != blank else { return false }
        item.applyLook(to: &element)
        return true
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

    private static func alignment(named word: String) -> (ElementLayout.Alignment, String)? {
        switch word.lowercased().trimmingCharacters(in: .whitespaces) {
        case "left", "leading": (.left, "left")
        // "Middle" is how people say centred, so it is side to side like "centre".
        case "centre", "center", "centred", "centered", "centrally", "middle", "horizontal centre", "horizontal center": (.centerX, "centre")
        case "right", "trailing": (.right, "right")
        case "top": (.top, "top")
        case "vertical centre", "vertical center", "vertical middle", "vertically", "centre vertically", "center vertically": (.centerY, "vertical centre")
        case "bottom": (.bottom, "bottom")
        default: nil
        }
    }
}

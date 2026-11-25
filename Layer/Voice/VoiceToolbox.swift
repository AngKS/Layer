import CoreGraphics
import Foundation

/// Carries spoken commands out on a design. Every change goes through the design's store
/// and the same code the Siri actions use, so a change made by voice is the change made by
/// hand: undoable, and seen by everything that watches the design.
///
/// A handle names any node of the tree, containers included (plan 6, call 7). Each tool
/// finds it through the store's index and changes it through the tree's verbs, as the
/// canvas and the panels do. A thing a row, column, grid or overlay places isn't moved by
/// its own numbers: the model is told what places it, and how to reorder it or take it out
/// (call 8).
///
/// Nothing here throws for a request that can't be met. A model that names something
/// that isn't there is told so in a line, and can try again or say so.
@MainActor
final class VoiceToolbox: VoiceActing {
    // Internal, not private, only for VoiceToolbox+Structure.swift, as are the helpers it calls here; nothing else uses them.
    private(set) weak var model: AppModel?
    let handles: VoiceHandles

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
    var scope: TreeScreen.ID?

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

    /// Whether the model of the command under way is handed `setLayout` and `reorder`: not the on-device one, which has
    /// no room for them (`VoiceProfile.handsAllTools`). Its refusals then say what the person can do instead.
    var offersStructureTools = true

    /// Makes what a tool changes the spoken command's under way: one step with the rest of
    /// the command, and never one with what the person does meanwhile (V1).
    func forCommand<T>(_ body: () -> T) -> T {
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
            let moving: Found
            let other: Found
            switch (find(element: element), find(element: target)) {
            case (.failure(let refusal), _), (_, .failure(let refusal)): return failed(refusal.line)
            case (.success(let one), .success(let two)): (moving, other) = (one, two)
            }
            guard moving.ref != other.ref else {
                return failed("Name two different elements. To add a new one next to another, give addElement where it goes.")
            }
            guard moving.ref.host == other.ref.host else { return failed("Those aren't on the same screen.") }
            guard !moving.placed.isLocked else { return failed("\(handle(of: moving)) is locked.") }
            if let placer = placer(of: moving) { return failed(placedLine(handle(of: moving), placer)) }
            let store = model.store
            guard let frame = store.canvasFrame(of: .element(moving.ref)), let by = store.canvasFrame(of: .element(other.ref)) else {
                return failed("That couldn't be placed.")
            }
            // In the points of the screen they are on.
            let gap = 12 * moving.placed.placement.scale
            let origin = switch side {
            case .below: CGPoint(x: by.minX, y: by.maxY + gap)
            case .above: CGPoint(x: by.minX, y: by.minY - gap - frame.height)
            case .leftOf: CGPoint(x: by.minX - gap - frame.width, y: by.minY)
            case .rightOf: CGPoint(x: by.maxX + gap, y: by.minY)
            }
            reveal(.element(moving.ref), in: model)
            store.position([.element(moving.ref): origin])
            return done("Put \(Self.describe(moving.node)) \(side.rawValue) \(Self.describe(other.node)).")
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
    static func handleList(_ written: String) -> [String] {
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
            var found: [Found] = []
            for handle in named {
                switch find(element: handle) {
                case .failure(let refusal): return failed(refusal.line)
                case .success(let one):
                    guard !one.placed.isLocked else { return failed("\(self.handle(of: one)) is locked.") }
                    if let placer = placer(of: one) { return failed(placedLine(self.handle(of: one), placer)) }
                    if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
                }
            }
            guard found.count > 1 else { return failed("Name two or more elements to stack.") }
            guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }

            // Worked out on the canvas, where the store puts things, in the points of the
            // screen they are on: a gap of 12 of those is less on a screen drawn small.
            let store = model.store
            let gap = 12 * found[0].placed.placement.scale
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
            if let id = handles.screen(handle), let screen = model.store.treeScreen(id) {
                // "Screen S2" and “S2” already say it is a screen.
                let isCalledAScreen = before.lowercased().hasSuffix("screen ") || (isQuoted && before.dropLast().lowercased().hasSuffix("screen "))
                words = isCalledAScreen ? "“\(screen.name)”" : "the screen “\(screen.name)”"
            } else if case .success(let found) = locate(element: handle) {
                // Off the screen a change is for, it is still said as what it is.
                words = Self.describe(found.node)
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
        let settings = model.store.tree.settings
        let usual = settings.sketchDevice
        // The device the model named, or else the one the person did: on an iPad the
        // model left it out, and "on the MacBook" got a phone screen. A device of the
        // design's own goes by its name.
        let frame = device.flatMap { Self.device(named: $0, preferring: usual, custom: settings.customDevices) }
            ?? spokenCommand.flatMap { Self.device(named: $0, preferring: usual, custom: settings.customDevices) }
        // One of the design's own that a file held broken (`DeviceFrame.problems`) is refused, as a device change refuses
        // it: no screen is made on it, and none is said to be.
        let chosen = frame ?? usual
        guard chosen.problems.isEmpty else { return failed(Self.cantMake(Self.screenNamed(chosen), on: chosen)) }
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
        guard let screen = model.store.treeScreen(screenID) else {
            // Taken away while it was being written, by undo or by hand.
            return failed(outcome == nil ? "The screen was taken away while it was being written." : "The model didn't describe any elements.")
        }
        // Told as a person would count what is on it: its leaves, not the rows and cards that hold them.
        let count = screen.root.leaves.count
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
                model.store.updateTreeScreen(found.id) { $0.name = name }
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

    /// Lays a whole screen out again with design sense: the structure pass in its tidy mode
    /// (`DesignStore.tidy(_:)`). One change, so one undo puts it back.
    func tidyScreen(screen: String?) -> String {
        forCommand {
            guard let model else { return gone }
            switch screenMeant(screen, in: model) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let handle = handles.handle(forScreen: found.id)
                let built = model.store.tidy(found.id)
                guard !built.isEmpty else { return failed("There is nothing on \(handle) that can be tidied.") }
                model.rememberBuiltStructures(built)
                reveal(.screen(found.id), in: model)
                return done("Tidied the layout of \(handle).")
            }
        }
    }

    /// Makes a screen another device's, as the device picker and Siri do (`changeDevice(of:to:)`):
    /// what is on it follows where it was put, so that it looks made for the new size rather
    /// than a phone's layout in a tablet's corner. A device of the design's own goes by its name.
    func changeScreenDevice(screen: String?, device: String) -> String {
        forCommand {
            guard let model else { return gone }
            let settings = model.store.tree.settings
            guard let frame = Self.device(named: device, preferring: settings.sketchDevice, custom: settings.customDevices) else {
                return failed(Self.noDevice(called: device, custom: settings.customDevices))
            }
            switch screenMeant(screen, in: model) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                let store = model.store
                let handle = handles.handle(forScreen: found.id)
                let named = Self.screenNamed(frame)
                guard store.device(of: found.id)?.id != frame.id else { return done("\(handle) is already \(named).") }
                store.changeDevice(of: found.id, to: frame)
                // The store refuses one of the design's own that a file held broken (`DeviceFrame.problems`): said so,
                // not that it was made.
                guard store.device(of: found.id)?.id == frame.id else { return failed(Self.cantMake("\(handle) \(named)", on: frame)) }
                reveal(.screen(found.id), in: model)
                return done("Made \(handle) \(named).")
            }
        }
    }

    /// A screen of a device in words, such as `an iPad screen (820 × 1180)`. A size a file held may be too large for a
    /// whole number: said as the device picker says it.
    private static func screenNamed(_ device: DeviceFrame) -> String {
        "\(article(for: device.name)) \(device.name) screen (\(device.size.width.wholePoints) × \(device.size.height.wholePoints))"
    }

    /// Why `what` can't be made on a device that can't be used (`DeviceFrame.problems`), such as `Couldn't make S1 a Huge
    /// screen (1000000 × 1000000). Width is 1 to 4,000 points.`
    private static func cantMake(_ what: String, on device: DeviceFrame) -> String {
        let problems = device.problems
        return "Couldn't make \(what). \(problems.isEmpty ? "That device can't be used." : problems.joined(separator: " "))"
    }

    /// Why no device was found for some words: the built-in families, and the design's own devices by name.
    static func noDevice(called words: String, custom: [DeviceFrame]) -> String {
        guard !custom.isEmpty else { return "I can make it an iPhone, iPad or Mac screen, not “\(words)”." }
        return "I can make it an iPhone, iPad or Mac screen, or \(custom.map(\.name).joined(separator: ", ")), not “\(words)”."
    }

    static func article(for name: String) -> String {
        name.first.map { "aeiouAEIOU".contains($0) } == true ? "an" : "a"
    }

    /// A name that is exactly one of `custom`'s, then the built-ins as today, then a custom name the words contain.
    ///
    /// `custom` is the design's own devices. One is chosen by its exact name, ignoring case and the space round it
    /// (`CanvasSettings.customDevice(named:)`), before anything else. Then the built-ins: "iPad", "iPhone Pro Max",
    /// "a webpage", "laptop", where a word that names only a family, such as "phone", "tablet" or "Mac", is `usual`
    /// when that is of the family, so a design made on an iPad mini goes on with iPad minis. A built-in wins over a
    /// name the words only contain. Last, one of the design's own whose name the words hold, such as "the kiosk
    /// screen" for "Kiosk": the longest such name, and of two as long, the one made first.
    static func device(named words: String, preferring usual: DeviceFrame = .iPhone, custom: [DeviceFrame] = []) -> DeviceFrame? {
        var settings = CanvasSettings()
        settings.customDevices = custom
        if let exact = settings.customDevice(named: words) { return exact }
        if let builtIn = builtInDevice(named: words, preferring: usual) { return builtIn }
        let said = Self.words(of: words)
        let held = custom.filter { device in
            let name = Self.words(of: device.name)
            guard !name.isEmpty, name.count <= said.count else { return false }
            return (0...(said.count - name.count)).contains { Array(said[$0..<($0 + name.count)]) == name }
        }
        return held.max { Self.words(of: $0.name).count < Self.words(of: $1.name).count }
    }

    /// The words of some text, in lower case, without what is between them.
    private static func words(of text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// The built-in device some words name: see `device(named:preferring:custom:)`.
    private static func builtInDevice(named words: String, preferring usual: DeviceFrame) -> DeviceFrame? {
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
    private func screenMeant(_ given: String?, in model: AppModel) -> Result<TreeScreen, Refusal> {
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
        let store = model.store
        if let id = model.selectedScreenID, let selected = store.treeScreen(id) { return .success(selected) }
        let holding = Set(model.selectedThings.compactMap { thing -> TreeScreen.ID? in
            guard case .element(let ref) = thing, case .screen(let id) = ref.host else { return nil }
            return id
        })
        if holding.count == 1, let id = holding.first, let screen = store.treeScreen(id) { return .success(screen) }
        let tree = store.tree
        if model.canvasSize != .zero {
            let visible = model.viewport.visibleRect(in: model.canvasSize)
            let inView = tree.screens.map { screen -> (TreeScreen, CGFloat) in
                let frame = screen.canvasFrame(on: tree.device(of: screen))
                let shown = frame.intersection(visible)
                return (screen, shown.isNull || frame.isEmpty ? 0 : shown.width * shown.height / (frame.width * frame.height))
            }.filter { $0.1 > 0.3 }.max { $0.1 < $1.1 }
            if let inView { return .success(inView.0) }
        }
        guard let newest = tree.screens.last else { return .failure(Refusal(line: "There is no screen yet.")) }
        return .success(newest)
    }

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
                reveal(.element(DesignStore.ElementRef(host: .screen(host.id), element: node.id)), in: model)
                let added = done("Added \(Self.describe(node, article: "a")) as \(handles.handle(forNode: node.id)).")
                return added + " " + done("Put \(Self.describe(node)) \(side.rawValue) \(Self.describe(other.node)) in \(placer.handle).")
            }

            // Below what is on a free root; last in a root that lays things out, which places it.
            if host.root.resolvedLayout == .free, let frame = store.newElementFrame(kind, on: host.id) { node.frame = frame }
            guard store.add(node, to: .screen(host.id)) else { return failed("That couldn't be added.") }
            reveal(.element(DesignStore.ElementRef(host: .screen(host.id), element: node.id)), in: model)
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
    /// whole, moved and resized exactly as the Format panel's X, Y, W and H move and resize one (`setBox`): a size
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
                    Self.setBox(of: found.ref, x: values[0], y: values[1], width: values[2], height: values[3], in: store)
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

    /// A container's X, Y, W and H, in its host's points, as the Format panel sets them: a copy of the body of
    /// `AppModel.setGroupBox(_:x:y:width:height:)` (AppModel.swift), which runs in the panel's own edit (`adjusting`) and
    /// so can't join a spoken command's step. Keep the two the same.
    /// - X or Y moves everything in it as one piece, by as far as the box moves (`position` takes canvas points).
    /// - W or H scales everything in it in proportion, both sides by the side given, from its top-left: by the width
    ///   whenever a width is given, so a width as it is with a new height changes nothing. A row, column, grid or
    ///   overlay is scaled the same way, and fixed on both axes that change (`resizeGroup`).
    private static func setBox(of ref: DesignStore.ElementRef, x: CGFloat?, y: CGFloat?, width: CGFloat?, height: CGFloat?,
                               in store: DesignStore) {
        if x != nil || y != nil, let item = store.placed(ref), item.node.isContainer {
            let box = item.canvasShape.bounds
            let across = ((x ?? item.frame.minX) - item.frame.minX) * item.placement.scale
            let down = ((y ?? item.frame.minY) - item.frame.minY) * item.placement.scale
            store.position([.element(ref): CGPoint(x: box.minX + across, y: box.minY + down)])
        }
        if width != nil || height != nil, let item = store.placed(ref), item.node.isContainer,
           item.frame.width > 0, item.frame.height > 0 {
            // The side given exactly; given both, the width, as the ratio is the widths'.
            let box = item.frame
            let size = width.map { CGSize(width: $0, height: box.height * $0 / box.width) }
                ?? CGSize(width: box.width * (height ?? box.height) / box.height, height: height ?? box.height)
            store.resizeGroup(ref, to: CGRect(origin: box.origin, size: size))
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

    /// One thing lined up with its screen, as the popover's Align does: only in a free parent (spec §10). What a row,
    /// column, grid or overlay places is lined up by that one's alignment, which the model is told to set.
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
                let handle = handle(of: found)
                guard found.screen != nil else { return failed("\(handle) isn't on a screen to line up with.") }
                guard !found.placed.isLocked else { return failed("\(handle) is locked.") }
                if let placer = placer(of: found) { return failed(alignedLine(handle, placer)) }
                reveal(.element(found.ref), in: model)
                model.store.align(found.ref, edge)
                return done("Aligned \(Self.describe(found.node)) to the \(name).")
            }
        }
    }

    /// Lines several elements up with one another: by an edge, or through the middle, of
    /// the area they cover together. As the popover's Align does (`AppModel.lineUpSelection`): in one row, column,
    /// grid or overlay, by that one's alignment; otherwise only what is in a free parent moves (spec §10), and what
    /// is placed stays where it is, the rest lining up with it all the same.
    private func alignTogether(_ named: [String], alignment: String) -> String {
        guard let model else { return gone }
        guard let (edge, name) = Self.alignment(named: alignment) else {
            return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
        }
        var found: [Found] = []
        for handle in named {
            switch find(element: handle) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let one):
                guard !one.placed.isLocked else { return failed("\(self.handle(of: one)) is locked.") }
                if !found.contains(where: { $0.ref == one.ref }) { found.append(one) }
            }
        }
        guard found.count > 1 else { return alignElement(element: named[0], alignment: alignment) }
        guard Set(found.map(\.ref.host)).count == 1 else { return failed("Those aren't all on one screen.") }
        let together = CanvasSelection.several(Set(found.map { .element($0.ref) }))
        let store = model.store
        let by = name.hasSuffix("centre") ? "\(name)s" : "\(name) edges"
        if let aligned = store.layoutAligned(together, edge) {
            reveal(.element(found[0].ref), in: model)
            store.update(aligned.parent) { $0.layout = aligned.layout }
            select(together, in: model)
            return done("Lined up \(found.count) elements by their \(by).")
        }
        // All in one that places them along this edge, or each placed by one: nothing of theirs can move.
        if store.laidOutParent(of: together) != nil || !store.holdsSomethingInAFreeParent(together),
           let placed = found.first(where: { $0.placed.isLaidOut }), let placer = placer(of: placed) {
            return failed(alignedLine(handle(of: placed), placer))
        }
        reveal(.element(found[0].ref), in: model)
        store.alignInFreeParents(together, edge)
        select(together, in: model)
        return done("Lined up \(found.count) elements by their \(by).")
    }

    func duplicateElement(element: String) -> String {
        forCommand {
            guard let model else { return gone }
            switch find(element: element) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found):
                guard let copy = model.store.duplicate(node: found.id) else { return failed("That couldn't be duplicated.") }
                reveal(.element(DesignStore.ElementRef(host: found.ref.host, element: copy)), in: model)
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
            return done("Showing \(Self.describe(found.node)).")
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

    struct Refusal: Error {
        var line: String
    }

    /// A node a handle names, where it is now: a leaf or a container, on a screen or on the open canvas.
    struct Found {
        /// Its frame in its host's points, its angle, its parent's layout, and its lock and hide with its containers'.
        var placed: PlacedNode
        /// The screen it is on; nil for one on the open canvas.
        var screen: TreeScreen?

        var id: UUID { placed.node.id }
        var node: LayerNode { placed.node }
        var ref: DesignStore.ElementRef { placed.ref }
    }

    /// What places a thing a row, column, grid or overlay lays out: that one's handle, or its screen's for a screen's
    /// root, and the word its layout goes by.
    private struct Placer {
        var handle: String
        /// `row`, `column`, `grid` or `overlay`.
        var word: String
        /// Whether it can be taken out onto its host's top: not from under a screen's root that lays things out, which
        /// has no free top to take it to (F15).
        var canTakeOut: Bool
    }

    func handle(of found: Found) -> String {
        handles.handle(forNode: found.id)
    }

    /// What places `found`, or nil when it is in a free parent: a free container, a free root or the open canvas.
    private func placer(of found: Found) -> Placer? {
        guard found.placed.isLaidOut else { return nil }
        return placer(of: found.id)
    }

    /// What places a node: see `placer(of:)`. Nil for a node in a free parent, or one the design doesn't have.
    private func placer(of id: UUID) -> Placer? {
        guard let store = model?.store, let parent = store.parent(of: id) else { return nil }
        let holder: UUID?
        let placer: (handle: String, canTakeOut: Bool)
        switch parent {
        case .node(let container):
            holder = container
            placer = (handles.handle(forNode: container), true)
        case .screen(let screen):
            holder = store.treeScreen(screen)?.root.id
            placer = (handles.handle(forScreen: screen), false)
        case .canvas:
            return nil
        }
        guard let layout = holder.flatMap(store.node)?.resolvedLayout, let word = Self.word(for: layout) else { return nil }
        return Placer(handle: placer.handle, word: word, canTakeOut: placer.canTakeOut)
    }

    /// What a layout is called: `row`, `column`, `grid` or `overlay`; nil for free.
    private static func word(for layout: LayerNode.Layout) -> String? {
        switch layout {
        case .free: nil
        case .stack(let stack): stack.axis == .horizontal ? "row" : "column"
        case .grid: "grid"
        case .overlay: "overlay"
        }
    }

    /// Why a thing that is placed by a row, column, grid or overlay wasn't moved, and what to do instead (call 8):
    /// `E6 is in the row E5, which places it. To change its place in E5, call reorder. To take it out of E5, call
    /// moveElement again with takeOut yes and where it goes.` Under a screen's root that lays things out, there is
    /// nowhere to take it, so the last sentence isn't said (F15). A model without `reorder` is told the Layers panel.
    private func placedLine(_ handle: String, _ placer: Placer) -> String {
        let reorder = offersStructureTools ? "call reorder" : "drag it in the Layers panel"
        let line = "\(handle) is in the \(placer.word) \(placer.handle), which places it. To change its place in \(placer.handle), \(reorder)."
        guard placer.canTakeOut else { return line }
        return line + " To take it out of \(placer.handle), call moveElement again with takeOut yes and where it goes."
    }

    /// Why a thing that is placed by a row, column, grid or overlay wasn't lined up, and what lines it up instead: for a
    /// model without `setLayout`, the Format panel's Layout section.
    private func alignedLine(_ handle: String, _ placer: Placer) -> String {
        let how = offersStructureTools
            ? "call setLayout on \(placer.handle) with an alignment, such as \(placer.word) centred"
            : "set \(placer.handle)'s alignment in the Format panel's Layout section"
        return "\(handle) is in the \(placer.word) \(placer.handle), which places it. To line things up in \(placer.handle), \(how)."
    }

    var gone: String { failed("The design has closed.") }

    /// Selects what a tool changed and brings it into view, so that "it" means that one
    /// next. A change for one screen leaves both alone: the screen stays selected, with
    /// the field the change was typed in, and the view stays where the person put it.
    func reveal(_ target: CanvasSelection, in model: AppModel) {
        guard scope == nil else { return }
        DesignActions.reveal(target, in: model)
    }

    /// Selects several things a tool changed together; not in a change for one screen.
    func select(_ together: CanvasSelection, in model: AppModel) {
        guard scope == nil else { return }
        model.selection = together
    }

    /// Why nothing can be done in a change for one screen once that screen has gone.
    static let screenGone = "That screen has gone, so nothing can be changed here."

    /// The screen a tool means when none is named in a change for one screen: that one,
    /// or a refusal once it has gone, so that nothing is done to another in its place.
    /// Nil when a command can go anywhere.
    private func scopedScreen(in model: AppModel) -> Result<TreeScreen, Refusal>? {
        guard let scope else { return nil }
        guard let screen = model.store.treeScreen(scope) else {
            return .failure(Refusal(line: Self.screenGone))
        }
        return .success(screen)
    }

    /// The screen a change is for, as a refusal names it: `S1 “Login”`. Nil without one.
    private var scopeNamed: String? {
        guard let scope else { return nil }
        let handle = handles.handle(forScreen: scope)
        guard let name = model?.store.treeScreen(scope)?.name else { return handle }
        return "\(handle) “\(name)”"
    }

    /// Why a change for one screen can't touch another, or make one; nil without a scope.
    private var outsideTheScope: Refusal? {
        scopeNamed.map { Refusal(line: "Only \($0) can be changed here.") }
    }

    func find(screen handle: String) -> Result<TreeScreen, Refusal> {
        guard let tidy = VoiceHandles.tidied(handle) else {
            return .failure(Refusal(line: "“\(handle)” isn't a handle. Use one from the list, such as S1."))
        }
        guard tidy.hasPrefix("S") else { return .failure(Refusal(line: "There is no screen \(tidy).")) }
        guard let id = handles.screen(tidy), let screen = model?.store.treeScreen(id) else {
            return .failure(Refusal(line: "There is no \(tidy)."))
        }
        if let scope, id != scope, let scoped = outsideTheScope { return .failure(scoped) }
        return .success(screen)
    }

    /// A node a tool may change: one on the screen a change is for, when there is one.
    func find(element handle: String) -> Result<Found, Refusal> {
        let found = locate(element: handle)
        guard let scope, case .success(let one) = found, one.ref.host != .screen(scope), let screen = scopeNamed else {
            return found
        }
        return .failure(Refusal(line: "\(self.handle(of: one)) isn't on \(screen), the screen this change is for."))
    }

    /// A node wherever it is, a leaf or a container, on any screen or loose on the canvas, found through the store's
    /// index.
    private func locate(element handle: String) -> Result<Found, Refusal> {
        guard let tidy = VoiceHandles.tidied(handle) else {
            return .failure(Refusal(line: "“\(handle)” isn't a handle. Use one from the list, such as E2."))
        }
        guard tidy.hasPrefix("E") else { return .failure(Refusal(line: "There is no element \(tidy).")) }
        // Looked up afresh each time: a node can have moved to another screen, or into another container.
        guard let id = handles.node(tidy), let store = model?.store, let placed = store.placed(id) else {
            return .failure(Refusal(line: "There is no \(tidy)."))
        }
        let screen: TreeScreen? = if case .screen(let screenID) = placed.ref.host { store.treeScreen(screenID) } else { nil }
        return .success(Found(placed: placed, screen: screen))
    }

    /// The screen a new element goes on when none is named: the one a change is for, the
    /// selected one, the one holding the selection, or the newest.
    private func currentScreen(in model: AppModel) -> Result<TreeScreen, Refusal> {
        if let scoped = scopedScreen(in: model) { return scoped }
        let store = model.store
        if let id = model.selectedScreenID, let screen = store.treeScreen(id) { return .success(screen) }
        if let selected = model.selectedNode, case .screen(let id) = selected.ref.host, let screen = store.treeScreen(id) {
            return .success(screen)
        }
        guard let newest = store.tree.screens.last else { return .failure(Refusal(line: "There is no screen to add to yet.")) }
        return .success(newest)
    }

    // MARK: Results

    func done(_ line: String) -> String {
        VoiceLog.log.info("tool: done. \(line, privacy: .private)")
        // The model is told the handle of what was made, to go on with. The pill isn't.
        lines.append(line.replacing(#/ It is the [ES]\d+ now in the canvas list\./#, with: "").replacing(#/ as [ES]\d+/#, with: ""))
        lastFailed = false
        return line
    }

    /// A line for the model about something that needn't be done: neither done, nor a
    /// failure that would be the person's to hear.
    func noted(_ line: String) -> String {
        VoiceLog.log.info("tool: noted. \(line, privacy: .private)")
        return line
    }

    func failed(_ line: String) -> String {
        VoiceLog.log.info("tool: couldn't. \(line, privacy: .private)")
        failures.append(line)
        lastFailed = true
        return line
    }

    // MARK: Reading what was asked

    /// "the button “Sign in”", "a text field “Email”", or for a container what it is, as the Layers panel calls it:
    /// "the card", "the row".
    private static func describe(_ node: LayerNode, article: String = "the") -> String {
        let what: String
        if node.isContainer {
            what = node.kindName.lowercased()
        } else if node.kind == .symbol, let symbol = node.content.symbol {
            what = "\(symbol) symbol"
        } else {
            // As Siri describes a leaf (`DesignDescriber`).
            let words = node.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = node.kind.layerName.lowercased()
            what = words.isEmpty ? kind : "\(kind) “\(words)”"
        }
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

import CoreGraphics
import Foundation

/// Voice's screen tools: making a screen from a description, renaming, deleting and tidying one, and making it
/// another device's, each through the store verb its control in the app uses, in the command's one step.
extension VoiceToolbox {
    // MARK: Screens

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
        // Inside a command the screen is part of the command's own undo step. The screen is the one this call made: a
        // refused one leaves the last generation's in place, which is never said to be made.
        let started = model.store.actingForCommand {
            model.generateScreen(from: description, named: Self.screenName(name), near: newScreenAnchor, device: frame)
        }
        guard let screenID = started, model.generation?.screenID == screenID else {
            return failed("The screen couldn't be started.")
        }
        // Stopping the command stops the model; what it has written so far stays.
        await withTaskCancellationHandler {
            await model.waitForGeneration()
        } onCancel: {
            Task { @MainActor in model.stopGenerating() }
        }
        // Read before the status goes: what it says of what was left out or couldn't be put right (spec §9) is said by
        // the reply below, so the canvas's own notice isn't left behind.
        let finished = model.generation
        let outcome = finished?.phase
        model.dismissGeneration()
        try Task.checkCancellation()
        if case .failed(let reason) = outcome { return failed(reason) }
        guard let screen = model.store.treeScreen(screenID) else {
            // Taken away while it was being written, by undo or by hand.
            return failed(outcome == nil ? "The screen was taken away while it was being written." : "The model didn't describe any elements.")
        }
        // Told as a person would count what is on it: its leaves, not the rows and cards that hold them.
        let count = screen.root.leaves.count
        let report = finished?.report.map { " \($0)" } ?? ""
        // Said so: seeing the new screen in its canvas list, a model took it for another
        // one already there with the same name.
        return done("Made the screen “\(screen.name)” as \(handles.handle(forScreen: screenID)), with \(count == 1 ? "1 element" : "\(count) elements").\(report) It is the \(handles.handle(forScreen: screenID)) now in the canvas list.")
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
}

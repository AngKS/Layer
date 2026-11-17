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

    /// Forgets the last command's results, ready for the next.
    func reset() {
        lines = []
        failures = []
        endsCall = false
        lastFailed = false
    }

    // MARK: Screens

    func createScreen(description: String) async throws -> String {
        guard let model else { throw CancellationError() }
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return failed("Say what the screen is for.") }
        guard !model.isGenerating else { return failed("A screen is already being written.") }
        model.generateScreen(from: description)
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
        guard let screen = model.store.screen(screenID) else { return failed("The model didn't describe any elements.") }
        let count = screen.elements.count
        return done("Made the screen “\(screen.name)” as \(handles.handle(forScreen: screenID)), with \(count == 1 ? "1 element" : "\(count) elements").")
    }

    func renameScreen(screen: String, name: String) -> String {
        guard let model else { return gone }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return failed("Say what to call it.") }
        switch find(screen: screen) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            model.store.updateScreen(found.id) { $0.name = name }
            DesignActions.reveal(.screen(found.id), in: model)
            return done("Renamed \(handles.handle(forScreen: found.id)) to “\(name)”.")
        }
    }

    func deleteScreen(screen: String, named: String?) -> String {
        guard let model else { return gone }
        switch find(screen: screen) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            let handle = handles.handle(forScreen: found.id)
            if let named, !VoiceNaming.fits(named, names: [], words: found.name) {
                return failed("There is no \(named.trimmingCharacters(in: .whitespaces)) here. \(handle) is “\(found.name)”.")
            }
            guard found.isLocked != true else { return failed("\(handle) is locked.") }
            model.store.deleteScreen(found.id)
            return done("Deleted the screen “\(found.name)”.")
        }
    }

    // MARK: Elements

    func addElement(screen: String?, kind: String, text: String?, look: String?) -> String {
        guard let model else { return gone }
        let host: DesignScreen
        if let screen, !screen.trimmingCharacters(in: .whitespaces).isEmpty {
            switch find(screen: screen) {
            case .failure(let refusal): return failed(refusal.line)
            case .success(let found): host = found
            }
        } else if let current = currentScreen(in: model) {
            host = current
        } else {
            return failed("There is no screen to add to yet.")
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
        DesignActions.reveal(.element(ref), in: model)
        return done("Added \(Self.describe(element, article: "a")) as \(handles.handle(forElement: element.id)).")
    }

    func setText(element: String, text: String) -> String {
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
            DesignActions.reveal(.element(found.ref), in: model)
            model.store.update(found.ref) { $0.text = text }
            return done("Reworded the \(found.element.kind.layerName.lowercased()) to “\(text)”.")
        }
    }

    func styleElement(element: String, look: String) -> String {
        guard let model else { return gone }
        switch find(element: element) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            var restyled = found.element
            guard Self.apply(look: look, to: &restyled) else {
                return failed("I didn't understand the look “\(look)”. Try words such as blue, bold, 18pt, radius 12 or text white.")
            }
            DesignActions.reveal(.element(found.ref), in: model)
            model.store.update(found.ref) { $0 = restyled }
            return done("Restyled \(Self.describe(found.element)).")
        }
    }

    func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String {
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
                guard let value = Self.length(written, of: extent), index < 2 || value >= 1 else {
                    return failed("I didn't understand the size “\(written)”. Give points, such as 180, or a share of the screen, such as 50%.")
                }
                values.append(value / scale)
            }
            DesignActions.reveal(.element(found.ref), in: model)
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

    func alignElement(element: String, alignment: String) -> String {
        guard let model else { return gone }
        switch find(element: element) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            guard let (edge, name) = Self.alignment(named: alignment) else {
                return failed("I can align to the left, centre, right, top, middle or bottom, not “\(alignment)”.")
            }
            guard found.screen != nil else { return failed("\(handles.handle(forElement: found.element.id)) isn't on a screen to line up with.") }
            guard !found.element.isLocked else { return failed("\(handles.handle(forElement: found.element.id)) is locked.") }
            DesignActions.reveal(.element(found.ref), in: model)
            model.store.align(found.ref, edge)
            return done("Aligned \(Self.describe(found.element)) to the \(name).")
        }
    }

    func duplicateElement(element: String) -> String {
        guard let model else { return gone }
        switch find(element: element) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            guard let copy = model.store.duplicate(found.ref) else { return failed("That couldn't be duplicated.") }
            DesignActions.reveal(.element(copy), in: model)
            return done("Duplicated \(Self.describe(found.element)) as \(handles.handle(forElement: copy.element)).")
        }
    }

    func deleteElement(element: String, named: String?) -> String {
        guard let model else { return gone }
        switch find(element: element) {
        case .failure(let refusal): return failed(refusal.line)
        case .success(let found):
            let handle = handles.handle(forElement: found.element.id)
            // Only what the person named goes: see `VoiceNaming`.
            if let named, !Self.fits(named, found.element) {
                return failed("There is no \(named.trimmingCharacters(in: .whitespaces)) here. \(handle) is \(Self.describe(found.element)).")
            }
            guard !found.element.isLocked else { return failed("\(handle) is locked.") }
            model.store.delete(found.ref)
            return done("Deleted \(Self.describe(found.element)).")
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
        if case .success(let screen) = find(screen: target) {
            DesignActions.reveal(.screen(screen.id), in: model)
            return done("Showing “\(screen.name)”.")
        }
        switch find(element: target) {
        case .success(let found):
            DesignActions.reveal(.element(found.ref), in: model)
            return done("Showing \(Self.describe(found.element)).")
        case .failure(let refusal):
            // A screen's handle that names nothing is reported as the screen it would be.
            if VoiceHandles.tidied(target)?.hasPrefix("S") == true { return failed("There is no \(VoiceHandles.tidied(target) ?? target).") }
            return failed(refusal.line)
        }
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

    /// Undo and redo act on whole steps, so what the command has done so far is closed
    /// off as a step of its own first, and the command goes on in a new one afterwards.
    private func stepThroughHistory(isUndo: Bool) -> String {
        guard let model else { return gone }
        let store = model.store
        let wasHeld = store.isHoldingEdit
        if wasHeld { store.endHeldEdit() }
        defer { if wasHeld { store.beginHeldEdit() } }
        guard let history = store.undoManager, isUndo ? history.canUndo : history.canRedo else {
            return failed(isUndo ? "There is nothing to undo." : "There is nothing to redo.")
        }
        if isUndo { history.undo() } else { history.redo() }
        return done(isUndo ? "Undid the last change." : "Redid the last change.")
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

    private func find(screen handle: String) -> Result<DesignScreen, Refusal> {
        guard let tidy = VoiceHandles.tidied(handle) else {
            return .failure(Refusal(line: "“\(handle)” isn't a handle. Use one from the list, such as S1."))
        }
        guard tidy.hasPrefix("S") else { return .failure(Refusal(line: "There is no screen \(tidy).")) }
        guard let id = handles.screen(tidy), let screen = model?.store.screen(id) else {
            return .failure(Refusal(line: "There is no \(tidy)."))
        }
        return .success(screen)
    }

    private func find(element handle: String) -> Result<FoundElement, Refusal> {
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

    /// The screen a new element goes on when none is named: the selected one, the one
    /// holding the selection, or the newest.
    private func currentScreen(in model: AppModel) -> DesignScreen? {
        if let screen = model.selectedScreen { return screen }
        if let selected = model.selectedElement, case .screen(let id) = selected.ref.host, let screen = model.store.screen(id) {
            return screen
        }
        return model.store.screens.last
    }

    // MARK: Results

    private func done(_ line: String) -> String {
        lines.append(line)
        lastFailed = false
        return line
    }

    private func failed(_ line: String) -> String {
        failures.append(line)
        lastFailed = true
        return line
    }

    // MARK: Reading what was asked

    /// "the button “Sign in”", or "a text field “Email”".
    private static func describe(_ element: DesignElement, article: String = "the") -> String {
        "\(article) \(DesignDescriber.describe(element))"
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
        let kindNames = (ScreenBlueprint.kindWords.first { $0.kind == element.kind }?.words ?? []) + [element.kind.layerName]
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
        if text.hasSuffix("%") {
            guard let extent, let share = Double(text.dropLast().trimmingCharacters(in: .whitespaces)) else { return nil }
            return (extent * CGFloat(share) / 100).rounded()
        }
        for unit in ["points", "point", "pts", "pt"] where text.hasSuffix(unit) {
            text = String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            break
        }
        return Double(text).map { CGFloat($0) }
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

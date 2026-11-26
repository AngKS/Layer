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
    // Internal, not private, only for the toolbox's extensions (VoiceToolbox+Screens.swift and the rest), as are the helpers
    // they share here; nothing else uses them.
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

    // MARK: What was said

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

    func refusesToDelete() -> String? {
        guard let spokenCommand, !Self.asksToRemove(spokenCommand) else { return nil }
        // The model's doing, not the person's: it is said that way round.
        return failed("That would have deleted something you didn't ask to remove, so nothing was changed.")
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

    // MARK: The call

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
        var ref: NodeRef { placed.ref }
    }

    /// What places a thing a row, column, grid or overlay lays out: that one's handle, or its screen's for a screen's
    /// root, and the word its layout goes by. Internal for VoiceToolbox+Structure.swift's reorder.
    struct Placer {
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
    /// Internal for VoiceToolbox+Structure.swift's reorder.
    func placer(of found: Found) -> Placer? {
        guard found.placed.isLaidOut else { return nil }
        return placer(of: found.id)
    }

    /// What places a node: see `placer(of:)`. Nil for a node in a free parent, or one the design doesn't have.
    func placer(of id: UUID) -> Placer? {
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
    func placedLine(_ handle: String, _ placer: Placer) -> String {
        let reorder = offersStructureTools ? "call reorder" : "drag it in the Layers panel"
        let line = "\(handle) is in the \(placer.word) \(placer.handle), which places it. To change its place in \(placer.handle), \(reorder)."
        guard placer.canTakeOut else { return line }
        return line + " To take it out of \(placer.handle), call moveElement again with takeOut yes and where it goes."
    }

    /// Why things each placed by a row, column, grid or overlay of its own weren't lined up with one another, said of one
    /// of them, and what lines it up instead: for a model without `setLayout`, the Format panel's Layout section. One
    /// thing, or several in one such parent, is lined up by that parent's alignment itself (`alignElement`).
    func alignedLine(_ handle: String, _ placer: Placer) -> String {
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
    func scopedScreen(in model: AppModel) -> Result<TreeScreen, Refusal>? {
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
    var outsideTheScope: Refusal? {
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
    func currentScreen(in model: AppModel) -> Result<TreeScreen, Refusal> {
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
    static func describe(_ node: LayerNode, article: String = "the") -> String {
        // A container by its kind's name; a leaf as Siri describes one (plan 6, Task 7 review M3).
        let what = node.isContainer ? node.kindName.lowercased() : DesignDescriber.describe(node)
        // "An image", not "a image".
        let isVowel = what.first.map { "aeiou".contains($0.lowercased()) } == true
        return "\(article == "a" && isVowel ? "an" : article) \(what)"
    }
}

@_weakLinked import AppIntents
import CoreGraphics
import Foundation

// Actions on device screens. Changes run in the foreground so that the person sees them
// land on the canvas, and each undoes as one step.

struct AddScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Add Screen"
    static let description = IntentDescription(
        "Adds an empty device screen to a Layer design, to the right of its other screens.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Device", description: "The device the screen is drawn as: phone, large phone, small phone or tablet.", default: .iPhone)
    var device: DeviceChoice

    @Parameter(title: "Name", description: "What to call the screen, such as Login or Settings. Numbered like Screen 3 if not given.")
    var name: String?

    @Parameter(title: "Design", description: "The design to add it to. The design at the front if not given.")
    var design: DesignEntity?

    @Parameter(title: "X", description: "Where the screen's left edge goes, in canvas points. To the right of the other screens if not given.")
    var x: Double?

    @Parameter(title: "Y", description: "Where the screen's top edge goes, in canvas points. Level with the newest screen if not given.")
    var y: Double?

    @Parameter(title: "Scale", description: "How large it is drawn on the canvas, as a percentage of its real size, from 10 to 400. The newest screen's scale if not given.", inclusiveRange: (10, 400))
    var scale: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$device) screen named \(\.$name)") {
            \.$design
            \.$x
            \.$y
            \.$scale
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> & ProvidesDialog {
        let model = try await DesignActions.model(for: design)
        let frame = device.frame
        var placement = DesignActions.placementForNewScreen(frame, in: model)
        if let scale { placement.scale = CGFloat(scale) / 100 }
        if let x { placement.origin.x = CGFloat(x) }
        if let y { placement.origin.y = CGFloat(y) }
        let screen = DesignActions.edit(model, undoManager: undoManager, actionName: "Add Screen") {
            var screen = model.store.addScreen(frame, at: placement)
            if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                model.store.updateScreen(screen.id) { $0.name = name }
                screen.name = name
            }
            return screen
        }
        DesignActions.reveal(.screen(screen.id), in: model, selecting: false)
        guard let entity = DesignActions.entity(for: screen, in: model) else { throw LayerIntentError.screenNotFound }
        return .result(value: entity, dialog: "Added \(screen.name).")
    }
}

struct BuildScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Build Screen"
    static let description = IntentDescription(
        """
        Builds a whole screen in a Layer design from a description, one element per line from top to bottom, \
        such as “title: Welcome back”, “text field: Email”, “button: Sign in [blue, bold]”. Indent lines under \
        “card:”, “column:” or “grid 2:” to put them inside it; start a line with “row:” and split elements with \
        “|” to put them side by side; a blank line or “---” starts a new section. Kinds: title, body, button, \
        text field, image, symbol, divider, toggle, checkbox, radio, progress, avatar, text. Square brackets \
        hold the look: a colour name or hex code, a weight, text white, fill or fit, on or off, a percentage \
        such as 40% for a progress bar, filled, bordered or plain for a button, left, centre or right, shadow, \
        border red. Or give A2UI 1.0 JSON, starting with “{” or “[”, \
        and Layer builds its components. When rebuilding a screen, what was built before is kept in place and \
        what was added by hand is left alone.
        """,
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(
        title: "Layout",
        description: "The screen's elements, one per line from top to bottom, written as kind: words [look], or A2UI JSON.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var layout: String

    @Parameter(title: "Name", description: "What to call the new screen, such as Login. Ignored when rebuilding an existing screen.")
    var name: String?

    @Parameter(title: "Device", description: "The device for a new screen. A phone if not given.", default: .iPhone)
    var device: DeviceChoice

    @Parameter(title: "Rebuild Screen", description: "An existing screen to replace the contents of. A new screen is added if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Design", description: "The design to add a new screen to. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Build \(\.$device) screen \(\.$name) from \(\.$layout)") {
            \.$screen
            \.$design
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> & ProvidesDialog {
        let model: AppModel
        let target: TreeScreen.ID?
        if let screen {
            let found = try await DesignActions.screen(screen)
            model = found.model
            target = found.screen.id
        } else {
            model = try await DesignActions.model(for: design)
            target = nil
        }
        let id = try await Self.build(layout, on: target, name: name, device: device.frame, in: model, undoManager: undoManager)
        DesignActions.reveal(.screen(id), in: model, selecting: false)
        guard let built = model.store.screen(id), let entity = DesignActions.entity(for: built, in: model) else {
            throw LayerIntentError.screenNotFound
        }
        let count = model.store.root(of: id)?.leafCount ?? 0
        return .result(value: entity, dialog: "Built \(built.name) with \(count == 1 ? "1 element" : "\(count) elements").")
    }
}

/// Why Build Screen made nothing from A2UI.
enum BuildScreenError: LocalizedError, Equatable {
    /// The JSON made no screen. Carries what the importer said about it: the missing root's message when it said one,
    /// else its first diagnostic's.
    case nothingInA2UI(String)

    var errorDescription: String? {
        switch self {
        case .nothingInA2UI(let message): message
        }
    }
}

extension BuildScreenIntent {
    /// What `perform` does. `layout` is A2UI JSON when `A2UIImporter.looksLikeA2UI`, else the outline. A new screen
    /// (no `target`) is laid out off the main actor and added. An existing one is merged by a reconciler that
    /// adopts it and committed through `commitGenerated`. One step through `DesignActions.edit` ("Build Screen").
    ///
    /// Siri sees leaves only. A new screen with no `name` takes the surface's own when the A2UI carries one (F3), and
    /// is on `device`. When the screen's root has changed since it was read (by the person, while this worked off
    /// the main actor), the generated root is merged again over the root as it is now, and committed without the
    /// layout hint, so the rules lay it out (call 1).
    @MainActor
    static func build(_ layout: String, on target: TreeScreen.ID?, name: String?, device: DeviceFrame, in model: AppModel,
                      undoManager: UndoManager?) async throws -> TreeScreen.ID {
        if let target {
            guard let screen = model.store.tree.screens.first(where: { $0.id == target }) else { throw LayerIntentError.screenNotFound }
            guard screen.isLocked != true else { throw LayerIntentError.locked }
        }
        // Worked off the main actor for the design's settings as they are, and again when they change meanwhile.
        var prepared: Prepared
        repeat {
            let settings = model.store.tree.settings
            let snapshot = target.flatMap { model.store.root(of: $0) }
            // A rebuild is laid out for the screen's own device (nil is the iPhone); Siri's `device` is for a new screen.
            let deviceID: String? = if let target, let screen = model.store.tree.screens.first(where: { $0.id == target }) {
                screen.deviceID
            } else {
                device == .iPhone ? nil : device.id
            }
            prepared = try await Task.detached {
                try Prepared.make(layout, snapshot: snapshot, deviceID: deviceID, settings: settings)
            }.value
        } while prepared.settings != model.store.tree.settings

        return try DesignActions.edit(model, undoManager: undoManager, actionName: "Build Screen") { () throws -> TreeScreen.ID in
            guard let target else {
                let screen = Self.newScreen(prepared, name: name, device: device, in: model)
                guard let id = model.store.addLaidOutScreens([screen]).first else { throw LayerIntentError.invalidBlueprint }
                return id
            }
            guard let screen = model.store.tree.screens.first(where: { $0.id == target }) else { throw LayerIntentError.screenNotFound }
            guard screen.isLocked != true else { throw LayerIntentError.locked }
            guard let snapshot = prepared.snapshot else { throw LayerIntentError.screenNotFound }
            if screen.root == snapshot {
                model.store.commitGenerated(prepared.laidOut, on: target, laidOutOver: snapshot)
            } else {
                let again = TreeReconciler(adopting: snapshot).merged(prepared.generated, over: screen.root)
                model.store.commitGenerated(again.root, on: target, laidOutOver: nil)
            }
            return target
        }
    }

    /// The new screen a prepared build makes, named, placed and on `device`.
    @MainActor
    private static func newScreen(_ prepared: Prepared, name: String?, device: DeviceFrame, in model: AppModel) -> TreeScreen {
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = prepared.surfaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = [given, surface].compactMap { $0 }.first { !$0.isEmpty }
        let placement = DesignActions.placementForNewScreen(device, in: model)
        var screen = TreeScreen(name: chosen ?? "Screen \(model.store.tree.screens.count + 1)", origin: placement.origin,
                                scale: placement.scale, deviceID: device == .iPhone ? nil : device.id)
        // Set after: `init` keeps a root to a built-in device only, and this one is laid out for the design's own.
        screen.root = prepared.laidOut
        return screen
    }

    /// A layout read, merged where there is a screen to merge into, and laid out: all pure, for off the main actor.
    fileprivate struct Prepared: Sendable {
        var settings: CanvasSettings
        var generated: LayerNode
        var surfaceName: String?
        /// The screen's root as it was read, when rebuilding.
        var snapshot: LayerNode?
        var laidOut: LayerNode

        static func make(_ layout: String, snapshot: LayerNode?, deviceID: String?, settings: CanvasSettings) throws -> Prepared {
            let generated: LayerNode
            var surfaceName: String?
            if A2UIImporter.looksLikeA2UI(layout) {
                let imported = A2UIImporter.importJSON(Data(layout.utf8), tokens: settings.tokens, trustsLayerLook: true)
                guard let screen = imported.screens.first else {
                    let said = imported.diagnostics.first { $0.reason == .missingRoot } ?? imported.diagnostics.first
                    throw BuildScreenError.nothingInA2UI(said?.message ?? "There was no A2UI screen in that.")
                }
                generated = screen.root
                surfaceName = screen.name
            } else {
                // Read as a generated outline: its look's numbers are passed over (spec §14).
                generated = Outline.parse(layout, isComplete: true, tokens: settings.tokens, readsLookNumbers: false)
                guard generated.leafCount > 0 else { throw LayerIntentError.invalidBlueprint }
            }
            guard let snapshot else {
                let laid = TreeRules.laidOut(generated, deviceID: deviceID, settings: settings, previous: nil)
                return Prepared(settings: settings, generated: generated, surfaceName: surfaceName, laidOut: laid)
            }
            let merge = TreeReconciler(adopting: snapshot).merged(generated, over: snapshot)
            let laid = TreeRules.laidOut(merge.root, deviceID: deviceID, settings: settings, previous: snapshot)
            return Prepared(settings: settings, generated: generated, surfaceName: surfaceName, snapshot: snapshot,
                            laidOut: laid)
        }
    }
}

struct OpenScreenIntent: OpenIntent {
    static let title: LocalizedStringResource = "Show Screen"
    static let description = IntentDescription(
        "Opens the design a screen belongs to, selects the screen and brings it into view.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to show.")
    var target: ScreenEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let (model, screen) = try await DesignActions.screen(target)
        DesignActions.reveal(.screen(screen.id), in: model)
        return .result()
    }
}

struct FindScreensIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Screens"
    static let description = IntentDescription(
        "Finds screens in Layer designs whose name, or whose elements' words, contain the words given.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Words", description: "Part of a screen's name or of the words on it, such as sign in.")
    var words: String

    static var parameterSummary: some ParameterSummary {
        Summary("Find screens matching \(\.$words)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[ScreenEntity]> {
        .result(value: try await ScreenQuery().entities(matching: words))
    }
}

struct RenameScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Rename Screen"
    static let description = IntentDescription("Gives a screen in a Layer design a new name. The name is also its SwiftUI view's name.", categoryName: "Screens")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to rename. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Name", description: "The new name, such as Profile.")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$screen) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Rename Screen") {
            model.store.updateScreen(target.id) { $0.name = name }
        }
        return .result(dialog: "Renamed \(target.name) to \(name).")
    }
}

struct ChangeScreenDeviceIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Screen Device"
    static let description = IntentDescription(
        "Changes the device a screen in a Layer design is drawn as, such as from a phone to a tablet. Its elements keep their positions.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to change. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Device", description: "Phone, large phone, small phone or tablet.")
    var device: DeviceChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$screen) an \(\.$device) screen")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Change Device") {
            model.store.updateScreen(target.id) { $0.deviceID = device == .iPhone ? nil : device.rawValue }
        }
        return .result(dialog: "\(target.name) is now an \(device.name) screen.")
    }
}

struct DuplicateScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Duplicate Screen"
    static let description = IntentDescription("Copies a screen and everything on it, placing the copy to its right.", categoryName: "Screens")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to copy. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Duplicate \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        let copy = DesignActions.edit(model, undoManager: undoManager, actionName: "Duplicate Screen") {
            model.store.duplicateScreen(target.id)
        }
        guard let copy, let entity = DesignActions.entity(for: copy, in: model) else { throw LayerIntentError.screenNotFound }
        DesignActions.reveal(.screen(copy.id), in: model)
        return .result(value: entity, dialog: "Made \(copy.name).")
    }
}

struct DeleteScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Delete Screen"
    static let description = IntentDescription("Deletes a screen and everything on it from a Layer design. It can be undone.", categoryName: "Screens")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to delete.")
    var screen: ScreenEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screen(screen)
        guard target.isLocked != true else { throw LayerIntentError.locked }
        try await requestConfirmation(dialog: "Delete \(target.name) and its \(target.elements.count) elements?")
        DesignActions.edit(model, undoManager: undoManager, actionName: "Delete Screen") {
            model.store.deleteScreen(target.id)
        }
        return .result(dialog: "Deleted \(target.name).")
    }
}

struct MoveScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Move or Scale Screen"
    static let description = IntentDescription(
        """
        Moves a screen on the canvas, or changes how large it is drawn. Positions are canvas points for its \
        top-left corner; scale is a percentage of its real size. Its elements move with it. Anything left out \
        stays as it is.
        """,
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to move. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "X", description: "Where its left edge goes, in canvas points.")
    var x: Double?

    @Parameter(title: "Y", description: "Where its top edge goes, in canvas points.")
    var y: Double?

    @Parameter(title: "Scale", description: "How large it is drawn, as a percentage of its real size, from 10 to 400.", inclusiveRange: (10, 400))
    var scale: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$screen)") {
            \.$x
            \.$y
            \.$scale
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        guard target.isLocked != true else { throw LayerIntentError.locked }
        DesignActions.edit(model, undoManager: undoManager, actionName: "Move Screen") {
            model.store.updateScreen(target.id) { screen in
                if let x { screen.origin.x = CGFloat(x) }
                if let y { screen.origin.y = CGFloat(y) }
                if let scale { screen.scale = CGFloat(scale) / 100 }
            }
        }
        return .result(dialog: "Moved \(target.name).")
    }
}

struct SetScreenLockedIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Lock or Unlock Screen"
    static let description = IntentDescription(
        "Locks a screen so it can't be moved or deleted, or unlocks it. Its elements can still be edited.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to lock or unlock. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Locked", description: "On to lock it, off to unlock it.", default: true)
    var locked: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$screen) locked to \(\.$locked)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        DesignActions.edit(model, undoManager: undoManager, actionName: locked ? "Lock Screen" : "Unlock Screen") {
            model.store.updateScreen(target.id) { $0.isLocked = locked ? true : nil }
        }
        return .result(dialog: locked ? "Locked \(target.name)." : "Unlocked \(target.name).")
    }
}

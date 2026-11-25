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

    @Parameter(title: "Custom Device", description: "One of this design's own devices, by name. Used instead of Device when given.",
               optionsProvider: CustomDeviceOptions())
    var customDevice: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$device) screen named \(\.$name)") {
            \.$customDevice
            \.$design
            \.$x
            \.$y
            \.$scale
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> & ProvidesDialog {
        let model = try await DesignActions.model(for: design)
        let frame = try DesignActions.device(device, custom: customDevice, in: model) ?? device.frame
        var placement = DesignActions.placementForNewScreen(frame, in: model)
        if let scale { placement.scale = CGFloat(scale) / 100 }
        if let x { placement.origin.x = CGFloat(x) }
        if let y { placement.origin.y = CGFloat(y) }
        let named = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        let id = try DesignActions.edit(model, undoManager: undoManager, actionName: "Add Screen") { () throws -> TreeScreen.ID in
            var screen = TreeScreen(name: named ?? "Screen \(model.store.tree.screens.count + 1)", origin: placement.origin,
                                    scale: placement.scale, deviceID: frame == .iPhone ? nil : frame.id)
            // A screen's root takes the screen's identifier, as one the canvas adds does. `init` keeps a root to a
            // built-in device only: this one may be the design's own.
            screen.root.id = screen.id
            screen.keepRootToDevice(frame)
            guard let id = model.store.addScreen(screen) else { throw LayerIntentError.designTooLarge }
            return id
        }
        DesignActions.reveal(.screen(id), in: model, selecting: false)
        guard let entity = DesignActions.entity(for: id, in: model) else { throw LayerIntentError.screenNotFound }
        return .result(value: entity, dialog: "Added \(entity.name).")
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

    @Parameter(title: "Custom Device", description: "One of this design's own devices, by name. Used instead of Device when given.",
               optionsProvider: CustomDeviceOptions())
    var customDevice: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Build \(\.$device) screen \(\.$name) from \(\.$layout)") {
            \.$customDevice
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
        let id = try await Self.build(layout, on: target, name: name, device: device, custom: customDevice, in: model,
                                      undoManager: undoManager)
        DesignActions.reveal(.screen(id), in: model, selecting: false)
        guard let built = model.store.treeScreen(id), let entity = DesignActions.entity(for: id, in: model) else {
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
    /// `build(_:on:name:device:in:undoManager:)` with the device as the intent's parameters give it: `custom`, one of
    /// the design's own by name (`DesignActions.device(_:custom:in:)`), else `choice`. The device is looked up only for
    /// a new screen, which is the only build that uses it: rebuilding `target` never fails on a name it wouldn't use.
    @MainActor
    static func build(_ layout: String, on target: TreeScreen.ID?, name: String?, device choice: DeviceChoice, custom: String?,
                      in model: AppModel, undoManager: UndoManager?) async throws -> TreeScreen.ID {
        let device = target == nil ? try DesignActions.device(choice, custom: custom, in: model) ?? choice.frame : choice.frame
        return try await build(layout, on: target, name: name, device: device, in: model, undoManager: undoManager)
    }

    /// What `perform` does. `layout` is A2UI JSON when `A2UIImporter.looksLikeA2UI`, else the outline, read off the
    /// main actor with the design's tokens. All the work off the main actor is done again when the design's settings
    /// change meanwhile. One step through `DesignActions.edit` ("Build Screen").
    ///
    /// A new screen (no `target`) is laid out off the main actor and added. It is on `device`, and with no `name` takes
    /// the surface's own when the A2UI carries one (F3), on one line of at most 40 characters. An existing one is
    /// written as a generation's update is, by a `GenerationWriter` whose reconciler adopts it (call 7): merged and
    /// laid out off the main actor, then committed. When the person changed the screen meanwhile, the writer merges
    /// again over it as it is then, and the rules lay that out (call 1).
    ///
    /// Siri sees leaves only. A build the design has no room for (more than 5,000 things, or nested deeper than 32)
    /// changes nothing and throws `designTooLarge`. A new screen on a device of the design's own that can't be used
    /// (`DeviceFrame.problems`), such as a New Screens device a file held broken, throws `deviceNotFound` before
    /// anything is read or laid out, as the store would refuse it.
    @MainActor
    static func build(_ layout: String, on target: TreeScreen.ID?, name: String?, device: DeviceFrame, in model: AppModel,
                      undoManager: UndoManager?) async throws -> TreeScreen.ID {
        guard let target else {
            return try await buildScreen(layout, name: name, device: device, in: model, undoManager: undoManager)
        }
        guard let screen = model.store.tree.screens.first(where: { $0.id == target }) else { throw LayerIntentError.screenNotFound }
        guard screen.isLocked != true else { throw LayerIntentError.locked }
        return try await rebuild(target, from: layout, in: model, undoManager: undoManager)
    }

    /// A new screen built from `layout`.
    @MainActor
    private static func buildScreen(_ layout: String, name: String?, device: DeviceFrame, in model: AppModel,
                                    undoManager: UndoManager?) async throws -> TreeScreen.ID {
        guard device.problems.isEmpty else { throw LayerIntentError.deviceNotFound(device.name) }
        let deviceID: String? = device == .iPhone ? nil : device.id
        var made: Made
        repeat {
            let settings = model.store.tree.settings
            made = try await Task.detached {
                let read = try Read(layout, tokens: settings.tokens)
                return Made(read: read, settings: settings,
                            laidOut: TreeRules.laidOut(read.generated, deviceID: deviceID, settings: settings, previous: nil))
            }.value
        } while made.settings != model.store.tree.settings

        return try DesignActions.edit(model, undoManager: undoManager, actionName: "Build Screen") { () throws -> TreeScreen.ID in
            let screen = Self.newScreen(made, name: name, device: device, in: model)
            guard let id = model.store.addLaidOutScreens([screen]).first else { throw LayerIntentError.designTooLarge }
            return id
        }
    }

    /// The screen `target` rebuilt from `layout`.
    @MainActor
    private static func rebuild(_ target: TreeScreen.ID, from layout: String, in model: AppModel,
                                undoManager: UndoManager?) async throws -> TreeScreen.ID {
        // Read and laid out again whenever the design's settings change meanwhile, so the commit lays nothing out
        // unless the screen itself changed.
        var writer: GenerationWriter
        var prepared: GenerationWriter.Prepared
        var settings: CanvasSettings
        repeat {
            settings = model.store.tree.settings
            let read = try await Task.detached { [tokens = settings.tokens] in try Read(layout, tokens: tokens) }.value
            guard let root = model.store.root(of: target) else { throw LayerIntentError.screenNotFound }
            writer = GenerationWriter(screenID: target, reconciler: TreeReconciler(adopting: root))
            #if DEBUG
            writer.beforeCommit = { model.beforeGenerationCommit?() }
            #endif
            guard let ready = await writer.prepare(read.generated, from: model.store) else { throw LayerIntentError.screenNotFound }
            prepared = ready
        } while settings != model.store.tree.settings

        return try DesignActions.edit(model, undoManager: undoManager, actionName: "Build Screen") { () throws -> TreeScreen.ID in
            guard let screen = model.store.tree.screens.first(where: { $0.id == target }) else { throw LayerIntentError.screenNotFound }
            guard screen.isLocked != true else { throw LayerIntentError.locked }
            guard writer.commit(prepared, to: model.store) else { throw LayerIntentError.designTooLarge }
            return target
        }
    }

    /// The new screen a build makes, named, placed and on `device`.
    @MainActor
    private static func newScreen(_ made: Made, name: String?, device: DeviceFrame, in model: AppModel) -> TreeScreen {
        let given = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let surface = made.read.surfaceName.flatMap(AppModel.screenName(from:))
        let chosen = [given, surface].compactMap { $0 }.first { !$0.isEmpty }
        let placement = DesignActions.placementForNewScreen(device, in: model)
        var screen = TreeScreen(name: chosen ?? "Screen \(model.store.tree.screens.count + 1)", origin: placement.origin,
                                scale: placement.scale, deviceID: device == .iPhone ? nil : device.id)
        // Set after: `init` keeps a root to a built-in device only, and this one is laid out for the design's own.
        screen.root = made.laidOut
        return screen
    }

    /// A layout read into a generated root: pure, for off the main actor.
    fileprivate struct Read: Sendable {
        var generated: LayerNode
        /// The name the A2UI's surface gives its screen, as it was written.
        var surfaceName: String?

        init(_ layout: String, tokens: DesignTokens) throws {
            if A2UIImporter.looksLikeA2UI(layout) {
                let imported = A2UIImporter.importJSON(Data(layout.utf8), tokens: tokens, trustsLayerLook: true)
                guard let screen = imported.screens.first else {
                    let said = imported.diagnostics.first { $0.reason == .missingRoot } ?? imported.diagnostics.first
                    throw BuildScreenError.nothingInA2UI(said?.message ?? "There was no A2UI screen in that.")
                }
                generated = screen.root
                surfaceName = screen.name
            } else {
                // Read as a generated outline: its look's numbers are passed over (spec §14).
                generated = Outline.parse(layout, isComplete: true, tokens: tokens, readsLookNumbers: false)
                guard generated.leafCount > 0 else { throw LayerIntentError.invalidScreenDescription }
            }
        }
    }

    /// A new screen's root, read and laid out for the design's settings.
    fileprivate struct Made: Sendable {
        var read: Read
        var settings: CanvasSettings
        var laidOut: LayerNode
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
            model.store.updateTreeScreen(target.id) { $0.name = name }
        }
        return .result(dialog: "Renamed \(target.name) to \(name).")
    }
}

struct ChangeScreenDeviceIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Screen Device"
    static let description = IntentDescription(
        """
        Changes the device a screen in a Layer design is drawn as, such as from a phone to a tablet, or to one of the \
        design's own devices. On a free screen, everything follows where it was drawn: what sits against an edge or in \
        the middle stays there, and what spans the screen stretches with it. A screen laid out as a column is laid out \
        again for the new size.
        """,
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to change. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Device", description: "Phone, large phone, small phone or tablet.")
    var device: DeviceChoice

    @Parameter(title: "Custom Device", description: "One of this design's own devices, by name. Used instead of Device when given.",
               optionsProvider: CustomDeviceOptions())
    var customDevice: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make \(\.$screen) an \(\.$device) screen") {
            \.$customDevice
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let (model, target) = try await DesignActions.screenOrCurrent(screen)
        let said = try Self.change(target.id, to: device, custom: customDevice, in: model, undoManager: undoManager)
        return .result(dialog: "\(said)")
    }

    /// Draws the screen as `custom`, one of the design's own devices by name, when it is given, else as `choice`, as one
    /// step, "Change Device" (`DesignStore.changeDevice(of:to:)`): what a free root holds follows its placement intent,
    /// and any other root is laid out again. Returns the dialog, which takes "an" before a device name that starts with
    /// a vowel letter, and "a" otherwise: "an iPhone", "an iPad", "a MacBook Air 13″", "a Kiosk" (F23).
    ///
    /// Throws `deviceNotFound` for a name the design has no device of its own called, and `screenNotFound`.
    @MainActor
    static func change(_ screen: TreeScreen.ID, to choice: DeviceChoice, custom: String?, in model: AppModel,
                       undoManager: UndoManager?) throws -> String {
        guard let target = model.store.treeScreen(screen) else { throw LayerIntentError.screenNotFound }
        let device = try DesignActions.device(choice, custom: custom, in: model) ?? choice.frame
        DesignActions.edit(model, undoManager: undoManager, actionName: "Change Device") {
            model.store.changeDevice(of: screen, to: device)
        }
        let article = device.name.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
        return "\(target.name) is now \(article) \(device.name) screen."
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
        let copy = try Self.duplicate(target.id, in: model, undoManager: undoManager)
        guard let entity = DesignActions.entity(for: copy, in: model) else { throw LayerIntentError.screenNotFound }
        DesignActions.reveal(.screen(copy), in: model)
        return .result(value: entity, dialog: "Made \(entity.name).")
    }

    /// Copies a screen with everything on it to its right, as one step, "Duplicate Screen"
    /// (`DesignStore.duplicateTreeScreen`). Returns the copy's id.
    ///
    /// Throws `screenNotFound` for a screen that has gone, and `designTooLarge` when the design can't hold the copy:
    /// past 5,000 things, the store makes none. The copy keeps the screen's device, whatever it is.
    @MainActor
    static func duplicate(_ screen: TreeScreen.ID, in model: AppModel, undoManager: UndoManager?) throws -> TreeScreen.ID {
        guard model.store.treeScreen(screen) != nil else { throw LayerIntentError.screenNotFound }
        let copy = DesignActions.edit(model, undoManager: undoManager, actionName: "Duplicate Screen") {
            model.store.duplicateTreeScreen(screen)
        }
        guard let copy else { throw LayerIntentError.designTooLarge }
        return copy
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
        try await requestConfirmation(dialog: "Delete \(target.name) and its \(target.root.leaves.count) elements?")
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
            model.store.updateTreeScreen(target.id) { screen in
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
            model.store.updateTreeScreen(target.id) { $0.isLocked = locked ? true : nil }
        }
        return .result(dialog: locked ? "Locked \(target.name)." : "Unlocked \(target.name).")
    }
}

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
        DesignActions.reveal(.screen(screen.id), in: model)
        guard let entity = DesignActions.entity(for: screen, in: model) else { throw LayerIntentError.screenNotFound }
        return .result(value: entity, dialog: "Added \(screen.name).")
    }
}

struct BuildScreenIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Build Screen"
    static let description = IntentDescription(
        """
        Builds a whole screen in a Layer design from a description, one element per line from top to bottom, \
        such as “title: Welcome back”, “text field: Email”, “button: Sign in [blue, bold]”. Start a line with \
        “row:” and split elements with “|” to put them side by side; a blank line or “---” starts a new section. \
        Kinds: title, body, button, text field, image, symbol, divider, toggle, checkbox, radio, progress, \
        avatar, text. Square brackets hold the look: a colour name or hex code, a weight, a size such as 18pt, \
        radius 12, text white, fill or fit, on or off, a percentage such as 40% for a progress bar, filled, \
        bordered or plain for a button, left, centre or right, shadow, border red, opacity 50%.
        """,
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(
        title: "Layout",
        description: "The screen's elements, one per line from top to bottom, written as kind: words [look].",
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
        guard let blueprint = ScreenBlueprint.parse(layout) else { throw LayerIntentError.invalidBlueprint }
        let model: AppModel
        let target: DesignScreen?
        if let screen {
            let found = try await DesignActions.screen(screen)
            model = found.model
            target = found.screen
        } else {
            model = try await DesignActions.model(for: design)
            target = nil
        }
        let built = try DesignActions.edit(model, undoManager: undoManager, actionName: "Build Screen") { () throws -> DesignScreen in
            let host: DesignScreen
            if let target {
                guard target.isLocked != true else { throw LayerIntentError.locked }
                host = target
            } else {
                var added = model.store.addScreen(device.frame, at: DesignActions.placementForNewScreen(device.frame, in: model))
                if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                    model.store.updateScreen(added.id) { $0.name = name }
                    added.name = name
                }
                host = added
            }
            model.store.setElements(blueprint.layout(on: host.device), on: host.id, replacing: true)
            return model.store.screen(host.id) ?? host
        }
        DesignActions.reveal(.screen(built.id), in: model)
        guard let entity = DesignActions.entity(for: built, in: model) else { throw LayerIntentError.screenNotFound }
        let count = built.elements.count
        return .result(value: entity, dialog: "Built \(built.name) with \(count == 1 ? "1 element" : "\(count) elements").")
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

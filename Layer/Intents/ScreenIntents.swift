import AppIntents
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

    @Parameter(title: "Device", description: "The device the screen is drawn as: iPhone, iPhone Pro Max, iPhone SE or iPad.", default: .iPhone)
    var device: DeviceChoice

    @Parameter(title: "Name", description: "What to call the screen, such as Login or Settings. Numbered like Screen 3 if not given.")
    var name: String?

    @Parameter(title: "Design", description: "The design to add it to. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$device) screen named \(\.$name)") {
            \.$design
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScreenEntity> & ProvidesDialog {
        let model = try await DesignActions.model(for: design)
        let frame = device.frame
        let screen = DesignActions.edit(model, undoManager: undoManager, actionName: "Add Screen") {
            var screen = model.store.addScreen(frame, at: DesignActions.placementForNewScreen(frame, in: model))
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
        “row:” and split elements with “|” to put them side by side. Kinds: title, body, button, text field, \
        image, symbol, divider, toggle, avatar, text. Square brackets hold the look: a colour name or hex code, \
        a weight, a size such as 18pt, radius 12, or text white.
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

    @Parameter(title: "Device", description: "The device for a new screen. iPhone if not given.", default: .iPhone)
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
        "Changes the device a screen in a Layer design is drawn as, such as from iPhone to iPad. Its elements keep their positions.",
        categoryName: "Screens"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Screen", description: "The screen to change. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Device", description: "iPhone, iPhone Pro Max, iPhone SE or iPad.")
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

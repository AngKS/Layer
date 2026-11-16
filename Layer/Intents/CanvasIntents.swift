import AppIntents
import Foundation

// The canvas itself, undo and redo, and the Magic Pen.

struct UpdateCanvasSettingsIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Change Canvas Settings"
    static let description = IntentDescription(
        "Changes how a Layer design's canvas looks and behaves: its grid, snapping, screen names and background colour. Anything left out stays as it is.",
        categoryName: "Canvas"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Show Grid", description: "Whether the grid of dots or lines is drawn.")
    var showsGrid: Bool?

    @Parameter(title: "Grid Style", description: "Dots or lines.")
    var gridStyle: GridStyleOption?

    @Parameter(title: "Grid Spacing", description: "The distance between grid marks, in points from 8 to 96.", inclusiveRange: (8, 96))
    var gridSpacing: Double?

    @Parameter(title: "Snap to Guides", description: "Whether dragged elements snap to the edges and centres of the screen and their neighbours.")
    var snapsToGuides: Bool?

    @Parameter(title: "Snap to Grid", description: "Whether dragged things snap to the grid.")
    var snapsToGrid: Bool?

    @Parameter(title: "Show Screen Names", description: "Whether each screen's name is drawn above it.")
    var showsFrameNames: Bool?

    @Parameter(title: "Background", description: "The canvas colour behind everything.")
    var background: ColourOption?

    @Parameter(title: "Design", description: "The design to change. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Change canvas settings") {
            \.$showsGrid
            \.$gridStyle
            \.$gridSpacing
            \.$snapsToGuides
            \.$snapsToGrid
            \.$showsFrameNames
            \.$background
            \.$design
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await DesignActions.model(for: design)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Canvas Settings") {
            model.store.updateCanvas { canvas in
                if let showsGrid { canvas.showsGrid = showsGrid }
                if let gridStyle { canvas.gridStyle = gridStyle.style }
                if let gridSpacing { canvas.gridSpacing = CGFloat(gridSpacing) }
                if let snapsToGuides { canvas.snapsToGuides = snapsToGuides }
                if let snapsToGrid { canvas.snapsToGrid = snapsToGrid }
                if let showsFrameNames { canvas.showsFrameNames = showsFrameNames }
                if let background { canvas.background = background.colour }
            }
        }
        return .result()
    }
}

struct ZoomToFitIntent: AppIntent {
    static let title: LocalizedStringResource = "Zoom to Fit"
    static let description = IntentDescription("Zooms the canvas of the design at the front to show everything on it.", categoryName: "Canvas")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await DesignActions.model(for: nil as String?)
        model.ink?.zoomToFit()
        return .result()
    }
}

struct UndoIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo in Layer"
    static let description = IntentDescription("Undoes the last change to the design at the front, whether made by hand or by Siri.", categoryName: "History")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await DesignActions.model(for: nil as String?)
        guard let undoManager = model.store.undoManager, undoManager.canUndo else {
            return .result(dialog: "There's nothing to undo.")
        }
        let name = undoManager.undoActionName
        undoManager.undo()
        return .result(dialog: name.isEmpty ? "Undone." : "Undid \(name).")
    }
}

struct RedoIntent: AppIntent {
    static let title: LocalizedStringResource = "Redo in Layer"
    static let description = IntentDescription("Redoes the last change that was undone in the design at the front.", categoryName: "History")
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await DesignActions.model(for: nil as String?)
        guard let undoManager = model.store.undoManager, undoManager.canRedo else {
            return .result(dialog: "There's nothing to redo.")
        }
        undoManager.redo()
        return .result(dialog: "Redone.")
    }
}

struct ConvertSketchesIntent: AppIntent {
    static let title: LocalizedStringResource = "Convert Sketches"
    static let description = IntentDescription(
        "Turns every Magic Pen sketch on the design at the front into screens and elements now, without waiting for the pen to rest.",
        categoryName: "Magic Pen"
    )
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await DesignActions.model(for: nil as String?)
        guard model.hasSketch else { return .result(dialog: "There are no sketches waiting to be converted.") }
        model.convertNow()
        return .result(dialog: "Converting your sketches.")
    }
}

struct ClearSketchesIntent: AppIntent {
    static let title: LocalizedStringResource = "Clear Sketches"
    static let description = IntentDescription(
        "Throws away the Magic Pen sketches on the design at the front that haven't become anything. Ink drawn with other pens stays.",
        categoryName: "Magic Pen"
    )
    static let supportedModes: IntentModes = .foreground

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await DesignActions.model(for: nil as String?)
        model.discardSketch()
        return .result()
    }
}

// MARK: App Shortcuts

/// Phrases that work with Siri as soon as Layer is installed, with no setup. Every phrase
/// names the app, as App Shortcuts require.
struct LayerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CreateDesignIntent(),
            phrases: [
                "New design in \(.applicationName)",
                "Start a \(.applicationName) design",
                "Create a design in \(.applicationName)",
            ],
            shortTitle: "New Design",
            systemImageName: "plus.square.on.square"
        )
        AppShortcut(
            intent: OpenDesignIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Open a \(.applicationName) design",
            ],
            shortTitle: "Open Design",
            systemImageName: "square.on.square.dashed"
        )
        AppShortcut(
            intent: FindDesignsIntent(),
            phrases: [
                "Find designs in \(.applicationName)",
                "Search \(.applicationName)",
            ],
            shortTitle: "Find Designs",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: AddScreenIntent(),
            phrases: [
                "Add a screen in \(.applicationName)",
                "Add an \(\.$device) screen in \(.applicationName)",
            ],
            shortTitle: "Add Screen",
            systemImageName: "iphone"
        )
        AppShortcut(
            intent: BuildScreenIntent(),
            phrases: [
                "Build a screen in \(.applicationName)",
                "Lay out a screen in \(.applicationName)",
            ],
            shortTitle: "Build Screen",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: AddElementIntent(),
            phrases: [
                "Add a \(\.$kind) in \(.applicationName)",
                "Add an element in \(.applicationName)",
            ],
            shortTitle: "Add Element",
            systemImageName: "plus.rectangle"
        )
        AppShortcut(
            intent: GenerateSwiftUICodeIntent(),
            phrases: [
                "Get the SwiftUI code from \(.applicationName)",
                "Generate code in \(.applicationName)",
            ],
            shortTitle: "SwiftUI Code",
            systemImageName: "chevron.left.forwardslash.chevron.right"
        )
        AppShortcut(
            intent: GenerateImageIntent(),
            phrases: [
                "Make an image in \(.applicationName)",
                "Make a \(\.$style) in \(.applicationName)",
                "Open Image Playground in \(.applicationName)",
            ],
            shortTitle: "Make Image",
            systemImageName: "apple.image.playground"
        )
        AppShortcut(
            intent: ExportDesignImageIntent(),
            phrases: [
                "Export my \(.applicationName) design",
                "Share an image of my \(.applicationName) design",
            ],
            shortTitle: "Export Image",
            systemImageName: "square.and.arrow.up"
        )
        AppShortcut(
            intent: UndoIntent(),
            phrases: [
                "Undo in \(.applicationName)",
                "Undo that in \(.applicationName)",
            ],
            shortTitle: "Undo",
            systemImageName: "arrow.uturn.backward"
        )
    }
}

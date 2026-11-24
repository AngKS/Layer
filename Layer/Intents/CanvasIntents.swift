@_weakLinked import AppIntents
import CoreGraphics
import Foundation
import PencilKit
import UIKit

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

    @Parameter(title: "Show Spacing", description: "Whether the distances to neighbours are shown while an element is moved or resized.")
    var showsMeasurements: Bool?

    @Parameter(title: "Background", description: "The canvas colour behind everything.")
    var background: ColourOption?

    @Parameter(title: "Background Hex", description: "The canvas colour as a hex code such as #F4F3EC, when no named colour fits.")
    var backgroundHex: String?

    @Parameter(title: "New Screen Device", description: "The device a tall rectangle drawn with the Magic Pen becomes.")
    var sketchDevice: DeviceChoice?

    @Parameter(title: "Code Layout", description: "Whether generated SwiftUI follows the screen's structure, the way a person writes it, or uses each element's exact position.")
    var codeLayout: CodeLayoutOption?

    @Parameter(title: "Include Preview", description: "Whether each generated SwiftUI file ends with a #Preview.")
    var includesPreview: Bool?

    @Parameter(title: "Title as Navigation Title", description: "Whether a screen's title becomes its navigation title in the generated SwiftUI.")
    var usesNavigationTitle: Bool?

    @Parameter(title: "Convert After a Pause", description: "Whether Magic Pen sketches are read on their own once the pen rests. Applies to every design.")
    var convertsAutomatically: Bool?


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
            \.$showsMeasurements
            \.$background
            \.$backgroundHex
            \.$sketchDevice
            \.$codeLayout
            \.$includesPreview
            \.$usesNavigationTitle
            \.$convertsAutomatically
            \.$design
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let colour = try ColourOption.resolve(background, hex: backgroundHex)
        let model = try await DesignActions.model(for: design)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Canvas Settings") {
            model.store.updateCanvas { canvas in
                if let showsGrid { canvas.showsGrid = showsGrid }
                if let gridStyle { canvas.gridStyle = gridStyle.style }
                if let gridSpacing { canvas.gridSpacing = CGFloat(gridSpacing) }
                if let snapsToGuides { canvas.snapsToGuides = snapsToGuides }
                if let snapsToGrid { canvas.snapsToGrid = snapsToGrid }
                if let showsFrameNames { canvas.showsFrameNames = showsFrameNames }
                if let showsMeasurements { canvas.showsMeasurements = showsMeasurements }
                if let colour { canvas.background = colour }
                if let sketchDevice { canvas.sketchDeviceID = sketchDevice == .iPhone ? nil : sketchDevice.rawValue }
                if let codeLayout { canvas.code.layout = codeLayout.layout }
                if let includesPreview { canvas.code.includesPreview = includesPreview }
                if let usesNavigationTitle { canvas.code.usesNavigationTitle = usesNavigationTitle }
            }
        }
        // App-wide preferences, outside the design's undo history.
        if let convertsAutomatically { model.convertsAutomatically = convertsAutomatically }
        return .result()
    }
}

struct SetCanvasViewIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Canvas View"
    static let description = IntentDescription(
        """
        Pans and zooms the canvas of the design at the front, or locks it against panning and zooming by touch. \
        The centre is in canvas points; the zoom is a percentage, 100 being actual size.
        """,
        categoryName: "Canvas"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Zoom", description: "How far to zoom, as a percentage from 10 to 400. Unchanged if not given.", inclusiveRange: (10, 400))
    var zoom: Double?

    @Parameter(title: "Centre X", description: "The canvas point to put in the middle of the view, across. Unchanged if not given.")
    var centerX: Double?

    @Parameter(title: "Centre Y", description: "The canvas point to put in the middle of the view, down. Unchanged if not given.")
    var centerY: Double?

    @Parameter(title: "Locked", description: "Whether touch can pan and zoom the canvas.")
    var locked: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Set the canvas view") {
            \.$zoom
            \.$centerX
            \.$centerY
            \.$locked
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await DesignActions.model(for: nil as String?)
        if zoom != nil || centerX != nil || centerY != nil {
            guard let ink = model.ink else { throw LayerIntentError.canvasNotReady }
            let current = model.viewport.canvasPoint(for: CGPoint(x: model.canvasSize.width / 2, y: model.canvasSize.height / 2))
            let center = CGPoint(x: centerX.map { CGFloat($0) } ?? current.x, y: centerY.map { CGFloat($0) } ?? current.y)
            ink.glide(toCenter: center, scale: zoom.map { CGFloat($0) / 100 } ?? model.viewport.scale)
        }
        if let locked { model.isCanvasLocked = locked }
        return .result()
    }
}

struct DrawStrokesIntent: AppIntent {
    static let title: LocalizedStringResource = "Draw Strokes"
    static let description = IntentDescription(
        """
        Draws pen strokes on a Layer design, as a stylus would. With the Magic Pen they are read as interface \
        elements, exactly as a hand-drawn sketch is: a tall rectangle becomes a screen, a zigzag a title, low long \
        waves body text, a box with a cross an image, a rounded bar a button, a small pill a toggle, a small circle \
        an avatar, a tiny square a checkbox, a long thin box a progress bar, and scribbling over an element deletes \
        it. With another pen they stay as ink; give Read As to have that ink read as what it describes. \
        Write one stroke per line: x,y points such as “20,40 120,40 120,90”, or a shape: box x y w h [radius], \
        pill x y w h, circle cx cy r, oval x y w h, line x1 y1 x2 y2 …, wave x y w h [humps], cross x y w h, \
        tick x y w h, dot cx cy [r], scribble x y w h. A JSON array of strokes of [x, y] points works too. \
        Returns the design's contents afterwards.
        """,
        categoryName: "Magic Pen"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(
        title: "Strokes",
        description: "One stroke per line: x,y points, or a shape such as “box 30 200 330 56 12” or “wave 150 112 96 40 3”.",
        inputOptions: String.IntentInputOptions(multiline: true)
    )
    var strokes: String

    @Parameter(title: "Pen", description: "The Magic Pen, whose sketches become elements, or a pen whose ink stays as drawn.", default: .magicPen)
    var pen: InkPenOption

    @Parameter(title: "Coordinates", description: "Screen points, from the top-left of the screen; or canvas points, needed to sketch a new screen or draw beside the screens.", default: .screen)
    var coordinates: StrokeSpaceOption

    @Parameter(title: "Screen", description: "The screen the points are measured from. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Read As", description: "What the strokes are meant to be, such as “a button saying Sign up”. They are read with this in mind and replaced by what they mean.")
    var prompt: String?

    @Parameter(title: "Convert Now", description: "Whether Magic Pen strokes are read straight away, and the action waits to report what they became.", default: true)
    var convertsNow: Bool

    @Parameter(title: "Colour", description: "The ink colour for pens other than the Magic Pen.")
    var colour: ColourOption?

    @Parameter(title: "Colour Hex", description: "The ink colour as a hex code such as #1C1C1E.")
    var colourHex: String?

    @Parameter(title: "Line Width", description: "The ink's width in points, for pens other than the Magic Pen.", inclusiveRange: (0.5, 40))
    var lineWidth: Double?

    @Parameter(title: "Design", description: "The design to draw on, for canvas points. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Draw \(\.$strokes) with \(\.$pen)") {
            \.$coordinates
            \.$screen
            \.$prompt
            \.$convertsNow
            \.$colour
            \.$colourHex
            \.$lineWidth
            \.$design
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let paths: [[CGPoint]]
        do {
            paths = try StrokeScript.parse(strokes)
        } catch let error as StrokeScript.ParseError {
            throw LayerIntentError.invalidStrokes(error.line > 0 ? "Line \(error.line), “\(error.text)”: \(error.reason)" : error.reason)
        }
        guard !paths.isEmpty else { throw LayerIntentError.invalidStrokes("There were no strokes in it.") }
        let inkColour = try ColourOption.resolve(colour, hex: colourHex)

        let model: AppModel
        var placement: Placement?
        if coordinates == .screen {
            let (found, target) = try await DesignActions.screenOrCurrent(screen)
            model = found
            placement = target.placement
        } else {
            model = try await DesignActions.model(for: screen?.designID ?? design?.id)
        }
        guard let ink = model.ink else { throw LayerIntentError.canvasNotReady }
        let canvasPaths = paths.map { path in path.map { placement?.canvasPoint(for: $0) ?? $0 } }
        let reading = prompt.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }

        if pen == .magicPen, reading == nil {
            model.tool = .draw
            ink.appendSketch(canvasPaths)
            guard convertsNow else {
                return .result(value: Self.contents(of: model), dialog: "Sketched \(paths.count) strokes with the Magic Pen.")
            }
            model.convertNow()
            await model.waitForConversions()
            let note = model.hasSketch ? " Some strokes weren't read as anything and are still on the canvas." : ""
            return .result(value: Self.contents(of: model) + note, dialog: "Sketched and converted \(paths.count) strokes.")
        }

        let type: PKInk.InkType = switch pen {
        case .magicPen, .monoline: .monoline
        case .pen: .pen
        case .marker: .marker
        case .pencil: .pencil
        }
        let defaultWidth: CGFloat = switch pen {
        case .marker: 10
        case .pencil: 3
        default: 2
        }
        let width = (lineWidth.map { CGFloat($0) } ?? defaultWidth) * (placement?.scale ?? 1)
        let keys = ink.appendInk(canvasPaths, ink: PKInk(type, color: (inkColour ?? Theme.inkTint).uiColor), width: width)
        guard let reading else {
            return .result(value: Self.contents(of: model), dialog: "Drew \(paths.count) strokes.")
        }
        model.tool = .select
        // The strokes just drawn are a drawing now, or part of the one they touch.
        model.selection = ink.drawing(owning: keys).map { .element(.init(host: .canvas, element: $0)) }
        model.convertSelection(prompt: reading)
        await model.waitForConversions()
        return .result(value: Self.contents(of: model), dialog: "Drew \(paths.count) strokes and read them as \(reading).")
    }

    @MainActor
    private static func contents(of model: AppModel) -> String {
        let snapshot = DesignActions.snapshot(of: model)
            ?? DesignSnapshot(id: "", name: model.store.title ?? "The design", content: model.store.tree, modified: nil)
        return DesignDescriber.describe(snapshot)
    }
}

struct EraseInkIntent: AppIntent {
    static let title: LocalizedStringResource = "Erase Ink"
    static let description = IntentDescription(
        """
        Erases ink drawn with the ordinary pens on the design at the front: every stroke touching an area, or all \
        of it when no area is given. Elements and Magic Pen sketches stay. It can be undone.
        """,
        categoryName: "Magic Pen"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "X", description: "The area's left edge, in canvas points, or in screen points when a screen is given.")
    var x: Double?

    @Parameter(title: "Y", description: "The area's top edge.")
    var y: Double?

    @Parameter(title: "Width", description: "The area's width.")
    var width: Double?

    @Parameter(title: "Height", description: "The area's height.")
    var height: Double?

    @Parameter(title: "Screen", description: "Measure the area from this screen's top-left corner, in its points.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Erase ink") {
            \.$x
            \.$y
            \.$width
            \.$height
            \.$screen
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model: AppModel
        var area: CGRect?
        if let x, let y, let width, let height {
            area = CGRect(x: x, y: y, width: width, height: height)
        }
        if let screen {
            let (found, target) = try await DesignActions.screen(screen)
            model = found
            area = area.map(target.canvasRect(for:)) ?? target.canvasFrame
        } else {
            model = try await DesignActions.model(for: nil as String?)
        }
        guard let ink = model.ink else { throw LayerIntentError.canvasNotReady }
        let keys = ink.inkKeys(touching: area)
        guard !keys.isEmpty else { return .result(dialog: "There's no ink there.") }
        if model.selectedElement?.element.kind == .drawing { model.selection = nil }
        ink.deleteInk(keys)
        return .result(dialog: "Erased \(keys.count) strokes.")
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
    static let description = IntentDescription("Undoes the last change to the design at the front, whether made by hand or by voice.", categoryName: "History")
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

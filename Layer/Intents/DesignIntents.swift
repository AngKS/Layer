@_weakLinked import AppIntents
import Foundation
import UniformTypeIdentifiers

// Actions on whole designs. Each title and description is written for someone who has
// never seen Layer: Siri and Shortcuts read them to decide which action fits a request.

struct CreateDesignIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Design"
    static let description = IntentDescription(
        "Makes a new, empty Layer design and opens it. A design is a canvas for app screens.",
        categoryName: "Designs"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Name", description: "What to call the design, such as Travel App. Layer suggests a name later if none is given.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create a design named \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<DesignEntity> & ProvidesDialog {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = try await OpenDesigns.shared.makeNew(named: title?.isEmpty == false ? title : nil)
        guard let entity = DesignActions.snapshot(of: model)?.entity else { throw LayerIntentError.couldNotOpen }
        return .result(value: entity, dialog: "Made a new design called \(entity.name).")
    }
}

struct OpenDesignIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Design"
    static let description = IntentDescription("Opens a Layer design on its canvas.", categoryName: "Designs")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Design", description: "The design to open.")
    var target: DesignEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await OpenDesigns.shared.open(design: target.id)
        OpenDesigns.shared.activated(model)
        return .result()
    }
}

struct FindDesignsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Designs"
    static let description = IntentDescription(
        "Finds Layer designs whose name, or the name of one of their screens, contains the words given. Lists every design when no words are given.",
        categoryName: "Designs"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Words", description: "Part of a design's name or a screen's name, such as checkout.")
    var words: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Find designs matching \(\.$words)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[DesignEntity]> {
        let query = DesignQuery()
        guard let words, !words.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .result(value: try await query.allEntities())
        }
        return .result(value: try await query.entities(matching: words))
    }
}

struct RenameDesignIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Rename Design"
    static let description = IntentDescription("Gives a Layer design a new name. Its file is renamed to match.", categoryName: "Designs")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Design", description: "The design to rename. The design at the front if not given.")
    var design: DesignEntity?

    @Parameter(title: "Name", description: "The new name.")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$design) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await DesignActions.model(for: design)
        DesignActions.edit(model, undoManager: undoManager, actionName: "Rename Design") {
            model.store.setTitle(name)
        }
        return .result(dialog: "Renamed the design to \(name).")
    }
}

struct DescribeDesignIntent: AppIntent {
    static let title: LocalizedStringResource = "Describe Design"
    static let description = IntentDescription(
        "Says what is in a Layer design: each screen, its device, and its elements from top to bottom.",
        categoryName: "Designs"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Design", description: "The design to describe. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Describe \(\.$design)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let snapshot: DesignSnapshot? = if let design {
            await DesignActions.snapshot(design: design.id)
        } else {
            OpenDesigns.shared.current.flatMap(DesignActions.snapshot(of:))
        }
        guard let snapshot else { throw design == nil ? LayerIntentError.noOpenDesign : LayerIntentError.designNotFound }
        let text = DesignDescriber.describe(snapshot)
        return .result(value: text, dialog: "\(text)")
    }
}

struct GetDesignLayoutIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Design Layout"
    static let description = IntentDescription(
        """
        Returns a Layer design as JSON with every position and size: each screen's device, canvas position and \
        scale, and its elements' frames in the screen's own points, text and look; loose elements in canvas \
        points; the canvas settings; and how much ink is drawn. Use it to see exactly where things are before \
        moving, styling or drawing.
        """,
        categoryName: "Designs"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Design", description: "The design to read. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get the layout of \(\.$design)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        // An open design also reports its ink, which is only known while it is open.
        let open = design.map { OpenDesigns.shared.model(forDesign: $0.id) } ?? OpenDesigns.shared.current
        if let open, let snapshot = DesignActions.snapshot(of: open) {
            return .result(value: DesignLayoutWriter.json(for: snapshot, ink: open.ink?.inkSummary, hasUnreadSketch: open.hasSketch))
        }
        guard let design else { throw LayerIntentError.noOpenDesign }
        guard let snapshot = await DesignActions.snapshot(design: design.id) else { throw LayerIntentError.designNotFound }
        return .result(value: DesignLayoutWriter.json(for: snapshot))
    }
}

struct ExportDesignImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Export Design as Image"
    static let description = IntentDescription(
        "Makes a PNG picture of everything on a Layer design's canvas: its screens, loose elements and ink. Use it to share or send a design.",
        categoryName: "Designs"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Design", description: "The design to export. The design at the front if not given.")
    var design: DesignEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Export \(\.$design) as an image")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let model = try await DesignActions.model(for: design)
        guard let data = await BoardSnapshot.png(of: model) else {
            throw LayerIntentError.nothingToExport
        }
        let name = DesignFileName.fileName(for: model.chosenName ?? "Layer Design")
        return .result(value: IntentFile(data: data, filename: "\(name).png", type: .png))
    }
}

struct GenerateSwiftUICodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Generate SwiftUI Code"
    static let description = IntentDescription(
        "Writes the SwiftUI source code for one screen of a Layer design, as a SwiftUI view a developer can paste into Xcode.",
        categoryName: "Code"
    )
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Screen", description: "The screen to write code for. The selected or newest screen of the design at the front if not given.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Generate SwiftUI code for \(\.$screen)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let source: (screen: TreeScreen.ID, name: String, design: TreeContent)
        if let screen, let id = screen.screenID, let snapshot = await DesignActions.snapshot(design: screen.designID),
           let found = snapshot.content.screens.first(where: { $0.id == id }) {
            source = (found.id, found.name, snapshot.content)
        } else if screen == nil {
            let current = try await DesignActions.screenOrCurrent(nil)
            source = (current.screen.id, current.screen.name, current.model.store.tree)
        } else {
            throw LayerIntentError.screenNotFound
        }
        guard let code = Self.code(for: source.screen, in: source.design) else { throw LayerIntentError.screenNotFound }
        return .result(value: code, dialog: "Here's the SwiftUI for \(source.name).")
    }

    /// The code for one screen of a design, as Share and the code panel write it: its view named
    /// as the shared files name it, so two screens called "Home" are `Home` and `Home2` (review
    /// M-8), and the design's tokens after it when it uses them. Nil when the design has no such screen.
    static func code(for screenID: TreeScreen.ID, in content: TreeContent) -> String? {
        guard let screen = content.screens.first(where: { $0.id == screenID }) else { return nil }
        return SwiftUICodeGenerator.code(for: screen, in: SwiftUICodeGenerator.Context(content), settings: content.settings.code)
    }
}

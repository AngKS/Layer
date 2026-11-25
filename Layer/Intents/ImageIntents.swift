@_weakLinked import AppIntents
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ImageStyleOption: String, AppEnum {
    case illustration, animation, sketch

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Image Style"
    static let caseDisplayRepresentations: [ImageStyleOption: DisplayRepresentation] = [
        .illustration: "Illustration", .animation: "Animation", .sketch: "Sketch",
    ]

    var style: GeneratedImageStyle { GeneratedImageStyle(rawValue: rawValue) ?? .illustration }
}

/// Makes a picture with Image Playground. Apple's way to make images in an app is its
/// Image Playground sheet, where the person sees, picks and can change what is made; the
/// API that made images with no sheet is deprecated in iOS 27 and refuses to work in the
/// background. So this opens the sheet in Layer, already holding the person's words and
/// the screen's own, and the picture they choose goes onto the design.
struct GenerateImageIntent: AppIntent {
    static let title: LocalizedStringResource = "Make Image with Image Playground"
    static let description = IntentDescription(
        """
        Opens Image Playground in Layer to make a picture for a design: a new image on a screen, \
        or a new picture for an image element that is already there. Image Playground starts from \
        the description given and the words on the screen, and the person picks the result.
        """,
        categoryName: "Images"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Description", description: "What the picture shows, such as a lighthouse at sunset.")
    var prompt: String?

    @Parameter(title: "Style", description: "Illustration, animation or sketch. Image Playground's own choice if not given.")
    var style: ImageStyleOption?

    @Parameter(title: "Replace Image", description: "An image element to make a new picture for. A new image is added if not given, unless the selected element is an image.")
    var element: ElementEntity?

    @Parameter(title: "Screen", description: "The screen to add a new image to. The selected screen if not given.")
    var screen: ScreenEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Make an image of \(\.$prompt)") {
            \.$style
            \.$element
            \.$screen
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard AppModel.canUseImagePlayground else { throw LayerIntentError.imagePlaygroundUnavailable }
        if let element {
            let (model, ref, found) = try await DesignActions.node(element)
            guard found.kind == .image else { throw LayerIntentError.notAnImage }
            DesignActions.reveal(.element(ref), in: model)
            model.remakeImageWithPlayground(ref, prompt: prompt, style: style?.style)
        } else if let screen {
            let (model, target) = try await DesignActions.screen(screen)
            DesignActions.reveal(.screen(target.id), in: model)
            model.makeImageWithPlayground(prompt: prompt, style: style?.style, onScreen: target.id)
        } else {
            let model = try await DesignActions.model(for: nil as String?)
            if let selected = DesignActions.selectedLeaf(in: model), selected.node.kind == .image {
                model.remakeImageWithPlayground(selected.ref, prompt: prompt, style: style?.style)
            } else {
                model.makeImageWithPlayground(prompt: prompt, style: style?.style)
            }
        }
        return .result(dialog: "Opened Image Playground. Pick the picture you like and it goes on your design.")
    }
}

struct AddImageFileIntent: AppIntent, UndoableIntent {
    static let title: LocalizedStringResource = "Add Picture"
    static let description = IntentDescription(
        """
        Adds a picture from a file or photo to a screen in a Layer design, as an image element: below what is \
        already there, or at the position and size given in the screen's points. Without a screen and with On \
        Canvas, it goes in the middle of the view. With Replace Image, it becomes the picture of that image instead.
        """,
        categoryName: "Elements"
    )
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Picture", description: "The picture to add: a PNG, JPEG, HEIC or other image file.", supportedContentTypes: [.image])
    var file: IntentFile

    @Parameter(title: "Screen", description: "The screen to add it to. The selected or newest screen if not given.")
    var screen: ScreenEntity?

    @Parameter(title: "Replace Image", description: "An image element to give this picture, keeping its place and size.")
    var element: ElementEntity?

    @Parameter(title: "X", description: "Distance of its left edge from the screen's left edge, in points.")
    var x: Double?

    @Parameter(title: "Y", description: "Distance of its top edge from the screen's top edge, in points.")
    var y: Double?

    @Parameter(title: "Width", description: "Its width in points. As wide as the screen allows if not given.", inclusiveRange: (1, 4000))
    var width: Double?

    @Parameter(title: "Height", description: "Its height in points. As tall as the picture's shape asks if not given.", inclusiveRange: (1, 4000))
    var height: Double?

    @Parameter(title: "On Canvas", description: "Put it in the middle of the view instead of on a screen.", default: false)
    var onCanvas: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$file) to \(\.$screen)") {
            \.$element
            \.$x
            \.$y
            \.$width
            \.$height
            \.$onCanvas
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ElementEntity> & ProvidesDialog {
        guard let prepared = ImageImport.prepare(file.data) else { throw LayerIntentError.invalidImage }
        let model: AppModel
        let request: ImagePlaygroundRequest
        if let element {
            let (found, ref, existing) = try await DesignActions.node(element)
            guard existing.kind == .image else { throw LayerIntentError.notAnImage }
            model = found
            request = ImagePlaygroundRequest(target: .replace(ref))
        } else if onCanvas, screen == nil {
            model = try await DesignActions.model(for: nil as String?)
            request = ImagePlaygroundRequest(target: .newImage(onScreen: nil))
        } else {
            let (found, target) = try await DesignActions.screenOrCurrent(screen)
            model = found
            request = ImagePlaygroundRequest(target: .newImage(onScreen: target.id))
        }
        let ref = DesignActions.edit(model, undoManager: undoManager, actionName: "Add Picture") { () -> DesignStore.ElementRef? in
            guard let ref = model.placeGeneratedImage(prepared, for: request) else { return nil }
            if element == nil, x != nil || y != nil || width != nil || height != nil, let placed = model.store.placed(ref) {
                // In its host's points, as Move Element takes them: a screen root that lays it out keeps its place.
                var frame = placed.frame
                let aspect = frame.height / max(frame.width, 1)
                if let width {
                    frame.size.width = CGFloat(width)
                    if height == nil { frame.size.height = (CGFloat(width) * aspect).rounded() }
                }
                if let height { frame.size.height = CGFloat(height) }
                if let x { frame.origin.x = CGFloat(x) }
                if let y { frame.origin.y = CGFloat(y) }
                model.store.place(ref.element, at: frame)
            }
            return ref
        }
        guard let ref, let entity = DesignActions.entity(for: ref, in: model) else { throw LayerIntentError.elementNotFound }
        return .result(value: entity, dialog: "Added the picture to \(entity.screenName).")
    }
}

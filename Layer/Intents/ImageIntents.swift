@_weakLinked import AppIntents
import Foundation

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
            let (model, ref, found) = try await DesignActions.element(element)
            guard found.kind == .image else { throw LayerIntentError.notAnImage }
            DesignActions.reveal(.element(ref), in: model)
            model.remakeImageWithPlayground(ref, prompt: prompt, style: style?.style)
        } else if let screen {
            let (model, target) = try await DesignActions.screen(screen)
            DesignActions.reveal(.screen(target.id), in: model)
            model.makeImageWithPlayground(prompt: prompt, style: style?.style, onScreen: target.id)
        } else {
            let model = try await DesignActions.model(for: nil as String?)
            if let selected = model.selectedElement, selected.element.kind == .image {
                model.remakeImageWithPlayground(selected.ref, prompt: prompt, style: style?.style)
            } else {
                model.makeImageWithPlayground(prompt: prompt, style: style?.style)
            }
        }
        return .result(dialog: "Opened Image Playground. Pick the picture you like and it goes on your design.")
    }
}

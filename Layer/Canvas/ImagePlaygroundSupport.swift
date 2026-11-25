import ImagePlayground
import SwiftUI

/// An image to make with Image Playground: a new one for a screen or the canvas, or a new
/// picture for an image element that is already there.
struct ImagePlaygroundRequest: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        /// A new image element, on this screen, or in the middle of the view when nil.
        case newImage(onScreen: TreeScreen.ID?)
        /// A new picture for this image element, which keeps its place and size.
        case replace(DesignStore.ElementRef)
    }

    let id = UUID()
    var target: Target
    /// What the person asked for, in their words.
    var prompt: String?
    var style: GeneratedImageStyle?
}

/// The Image Playground styles a person can ask for by name.
enum GeneratedImageStyle: String, CaseIterable, Sendable {
    case illustration, animation, sketch

    var playgroundStyle: ImagePlaygroundStyle {
        switch self {
        case .illustration: .illustration
        case .animation: .animation
        case .sketch: .sketch
        }
    }
}

extension AppModel {
    /// Whether Image Playground can run here: Apple Intelligence on, and its models ready.
    nonisolated static var canUseImagePlayground: Bool { ImagePlaygroundViewController.isAvailable }

    /// Opens Image Playground for a new image: on the selected screen, or the screen the
    /// selected element is on, or in the middle of the view.
    func makeImageWithPlayground(prompt: String? = nil, style: GeneratedImageStyle? = nil, onScreen screenID: TreeScreen.ID? = nil) {
        let screen = screenID ?? selectedScreenID ?? {
            if let selected = selectedNode, case .screen(let id) = selected.ref.host { return id }
            return nil
        }()
        imagePlaygroundRequest = ImagePlaygroundRequest(target: .newImage(onScreen: screen), prompt: prompt, style: style)
    }

    /// Opens Image Playground to make a new picture for an image element.
    func remakeImageWithPlayground(_ ref: DesignStore.ElementRef, prompt: String? = nil, style: GeneratedImageStyle? = nil) {
        imagePlaygroundRequest = ImagePlaygroundRequest(target: .replace(ref), prompt: prompt, style: style)
    }

    /// The words Image Playground starts from: what the person asked for, and what the
    /// screen the image is for says, so a picture for a travel app's welcome screen is
    /// about travel without being asked.
    func imageConcepts(for request: ImagePlaygroundRequest) -> (prompt: String?, context: String?, title: String?) {
        let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenID: TreeScreen.ID? = switch request.target {
        case .newImage(let id): id
        case .replace(let ref): if case .screen(let id) = ref.host { id } else { nil }
        }
        let screen = screenID.flatMap(store.treeScreen)
        var context: String?
        if let screen {
            // Its visible leaves, top to bottom by what is seen of them.
            let index = store.index
            let words = screen.root.leaves
                .compactMap { leaf -> (words: String, top: CGFloat)? in
                    guard let entry = index[leaf.id], !entry.isHiddenWithAncestors, [.title, .body, .text, .button].contains(leaf.kind),
                          leaf.content.text != leaf.kind.placeholder else { return nil }
                    return (leaf.content.text.trimmingCharacters(in: .whitespacesAndNewlines), entry.hostShape.rect.minY)
                }
                .sorted { $0.top < $1.top }
                .map(\.words)
                .filter { !$0.isEmpty }
            if !words.isEmpty { context = words.joined(separator: ". ") }
        }
        let title = [store.title, screen?.name].compactMap(\.self).joined(separator: " – ")
        return (prompt?.isEmpty == false ? prompt : nil, context, title.isEmpty ? nil : title)
    }

    /// The size the new picture is for, in points: the element it replaces, or the width a
    /// new image takes on its screen.
    func imageSize(for request: ImagePlaygroundRequest) -> CGSize {
        switch request.target {
        case .replace(let ref):
            return store.placed(ref)?.frame.size ?? CGSize(width: 333, height: 333)
        case .newImage(let screenID):
            let width = screenID.flatMap(store.device(of:)).map { $0.size.width - 40 } ?? 320
            return CGSize(width: width, height: width)
        }
    }

    /// Puts the picture Image Playground made where it was asked for, selected, as one
    /// undo step. Returns where it is.
    @discardableResult
    func placeGeneratedImage(_ prepared: ImageImport.Prepared, for request: ImagePlaygroundRequest) -> DesignStore.ElementRef? {
        imagePlaygroundRequest = nil
        if case .newImage(nil) = request.target {
            addImage(prepared)
            return selectedNode?.ref
        }
        let id = images.add(prepared)
        document.update { $0.images[id.uuidString] = prepared.data }
        let ref: DesignStore.ElementRef
        switch request.target {
        case .replace(let existing):
            // A picture for the image where it is, in whatever holds it: its frame and its place stay.
            guard store.placed(existing) != nil else { return nil }
            store.update(existing.element) { $0.content.imageID = id }
            ref = existing
        case .newImage(let screenID?):
            guard let device = store.device(of: screenID) else { return nil }
            var image = LayerNode.standard(.image)
            image.content.imageID = id
            // As wide as a full-width image, as tall as the picture's shape asks, below
            // what is already on the screen.
            let width = min(device.size.width - 40, 400).rounded()
            let aspect = prepared.image.size.height / max(prepared.image.size.width, 1)
            let size = CGSize(width: width, height: min((width * aspect).rounded(), (device.size.height / 2).rounded()))
            let below = store.newElementFrame(.image, on: screenID)?.minY ?? device.safeTop
            let lowest = device.size.height - device.safeBottom - 8 - size.height
            image.frame = CGRect(
                origin: CGPoint(x: ((device.size.width - size.width) / 2).rounded(), y: max(device.safeTop, min(below, lowest))),
                size: size
            )
            guard store.add(image, to: .screen(screenID)) else { return nil }
            ref = DesignStore.ElementRef(host: .screen(screenID), element: image.id)
        case .newImage(nil):
            return nil
        }
        tool = .select
        selection = .element(ref)
        return ref
    }
}

/// Shows Image Playground over the canvas whenever there is a request, and puts what it
/// makes on the board.
struct ImagePlaygroundPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var hasFailed = false

    func body(content: Content) -> some View {
        let request = model.imagePlaygroundRequest
        content
            .imagePlaygroundSheet(
                isPresented: Binding(
                    get: { model.imagePlaygroundRequest != nil },
                    set: { if !$0 { model.imagePlaygroundRequest = nil } }
                ),
                concepts: concepts(for: request),
                sourceImage: sourceImage(for: request),
                onCompletion: { url in
                    guard let request else { return }
                    finish(request, with: url)
                },
                onCancellation: { model.imagePlaygroundRequest = nil }
            )
            .imagePlaygroundGenerationStyle(request?.style?.playgroundStyle ?? .illustration, in: ImagePlaygroundStyle.all)
            .imagePlaygroundOptions(options(for: request))
            .alert("The image couldn't be added.", isPresented: $hasFailed) {
                Button("OK", role: .cancel) {}
            }
    }

    private func concepts(for request: ImagePlaygroundRequest?) -> [ImagePlaygroundConcept] {
        guard let request else { return [] }
        let words = model.imageConcepts(for: request)
        var concepts: [ImagePlaygroundConcept] = []
        if let prompt = words.prompt { concepts.append(.text(prompt)) }
        if let context = words.context { concepts.append(.extracted(from: context, title: words.title)) }
        return concepts
    }

    /// The picture an image element shows now, to make a new one from.
    private func sourceImage(for request: ImagePlaygroundRequest?) -> Image? {
        guard case .replace(let ref)? = request?.target,
              let picture = model.store.placed(ref).flatMap({ model.images.image($0.node.content.imageID) })
        else { return nil }
        return Image(uiImage: picture)
    }

    private func options(for request: ImagePlaygroundRequest?) -> ImagePlaygroundOptions {
        var options = ImagePlaygroundOptions()
        if let request {
            options.sizeSpecification = .closest(to: model.imageSize(for: request))
        }
        return options
    }

    private func finish(_ request: ImagePlaygroundRequest, with url: URL) {
        // Image Playground hands over a file of its own, readable for this moment.
        guard let data = try? Data(contentsOf: url), let prepared = ImageImport.prepare(data) else {
            model.imagePlaygroundRequest = nil
            hasFailed = true
            return
        }
        withAnimation(.smooth(duration: 0.3)) {
            if model.placeGeneratedImage(prepared, for: request) == nil { hasFailed = true }
        }
    }
}

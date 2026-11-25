import PencilKit
import SwiftUI
import UIKit

/// The share button: the generated SwiftUI, a picture of the board, or the design file.
struct ShareMenu: View {
    @Environment(AppModel.self) private var model
    @State private var picture: SharedPicture?
    /// What went wrong in making something to share, said in an alert.
    @State private var problem: String?
    /// Whether a picture of the board or a copy of the design is being made to share.
    @State private var isPreparing = false

    var body: some View {
        Menu {
            // The code and the A2UI of the selected screen, or of the first one.
            let tree = model.store.tree
            if let screen = sharedScreen(in: tree) {
                let shared = SharedScreen(screen, in: tree)
                ShareLink(item: shared.code, preview: SharePreview(shared.codeFileName)) {
                    Label("SwiftUI Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                // Written when picked, through the share sheet that says when it closes, so that its folder goes then.
                Button {
                    do {
                        picture = try SharedPicture.a2ui(shared.a2ui)
                    } catch {
                        problem = SharedA2UI.problem
                    }
                } label: {
                    Label("A2UI JSON", systemImage: "curlybraces")
                }
            }
            if tree.screens.count > 1 {
                Button("SwiftUI Files for All Screens", systemImage: "doc.on.doc") {
                    if let files = SharedPicture.codeFiles(for: model.store.tree) { picture = files }
                }
            }
            ForEach(ShareItem.offered(for: model), id: \.self) { item in
                Button(item.title, systemImage: item.symbol) { share(item) }
            }
        } label: {
            // A big board takes a moment: the button spins meanwhile, in its own place.
            ToolIcon(symbol: "square.and.arrow.up")
                .opacity(isPreparing ? 0 : 1)
                .overlay { if isPreparing { ProgressView() } }
        }
        .disabled(isPreparing)
        .accessibilityLabel("Share")
        .popover(item: $picture) { picture in
            ActivityView(items: picture.urls, whenClosed: picture.whenClosed)
        }
        .alert(problem ?? "", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
            Button("OK", role: .cancel) {}
        }
    }

    /// The screen whose code is shared: the selected one, or the first.
    private func sharedScreen(in tree: TreeContent) -> TreeScreen? {
        if case .screen(let id) = model.selection, let screen = tree.screens.first(where: { $0.id == id }) { return screen }
        return tree.screens.first
    }

    /// Makes what `item` shares from the design as it is now, and hands it to the share sheet.
    private func share(_ item: ShareItem) {
        Task {
            isPreparing = true
            defer { isPreparing = false }
            do {
                guard let url = try await item.file(for: model) else {
                    problem = item.problem
                    return
                }
                picture = SharedPicture(urls: [url]) { item.cleanUp(url) }
            } catch {
                problem = item.problem
            }
        }
    }
}

/// What the Share menu offers of one screen: its SwiftUI code and its A2UI, both named from one context's view names,
/// made once each time the menu is.
struct SharedScreen {
    let code: SharedSwiftUICode
    /// "<TypeName>.swift".
    let codeFileName: String
    let a2ui: SharedA2UI

    init(_ screen: TreeScreen, in tree: TreeContent) {
        let context = SwiftUICodeGenerator.Context(tree)
        code = SharedSwiftUICode(screen: screen, context: context, settings: tree.settings.code)
        codeFileName = SwiftUICodeGenerator.fileName(for: screen, in: context)
        a2ui = SharedA2UI(screen: screen, typeName: context.typeName(of: screen))
    }
}

/// A screen's SwiftUI code, written when it is shared and not before: the menu is made again
/// on every change to the design, a frame of a drag among them, and the code is as long as
/// the screen is full. It shares what `SwiftUICodeGenerator.code(for:in:settings:)` gives
/// for the design as it was when the menu was made, as text.
struct SharedSwiftUICode: Transferable, Sendable {
    let screen: TreeScreen
    let context: SwiftUICodeGenerator.Context
    let settings: CodeSettings

    init(screen: TreeScreen, context: SwiftUICodeGenerator.Context, settings: CodeSettings) {
        self.screen = screen
        self.context = context
        self.settings = settings
    }

    /// The code itself.
    var source: String {
        SwiftUICodeGenerator.code(for: screen, in: context, settings: settings)
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.source)
    }
}

/// A screen's A2UI, written when it is shared and not before, like `SharedSwiftUICode`: the menu is
/// made again on every change to the design, and the file is as long as the screen is full.
struct SharedA2UI: Sendable {
    let screen: TreeScreen
    let typeName: String

    init(screen: TreeScreen, typeName: String) {
        self.screen = screen
        self.typeName = typeName
    }

    /// The file's contents: the screen's messages as one JSON array.
    var data: Data { A2UIExporter.document(for: screen, surfaceID: typeName) }

    /// "<TypeName>.a2ui.json".
    var fileName: String { typeName + ".a2ui.json" }

    /// The start of the name of each folder a screen's A2UI is written in to share.
    static let folderPrefix = "A2UI-"

    /// Said when the file couldn't be written to share, as the design file's copy says it.
    static let problem = "Layer couldn't write the screen's A2UI to share."

    /// Writes the file, named `fileName`, in a folder of its own in `temporary`, which goes when the share sheet closes
    /// (`ShareFolder.remove(holding:prefix:)`). A file that can't be written leaves nothing behind.
    func write(in temporary: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = try ShareFolder.make(Self.folderPrefix, in: temporary)
        do {
            let url = folder.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
}

/// A folder of its own for files made to share, in the system's temporary folder, taken away once the share sheet has
/// closed: each share used to leave one behind.
enum ShareFolder {
    /// A new folder in `temporary` whose name starts with `prefix`, such as `A2UI-`.
    static func make(_ prefix: String, in temporary: URL) throws -> URL {
        let folder = temporary.appendingPathComponent(prefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Takes away the folder `file` was written in, when its name starts with `prefix`: nothing else is touched.
    static func remove(holding file: URL, prefix: String) {
        let folder = file.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix(prefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

/// What the share menu makes when one of its items is picked, from the design as it is
/// then: a picture of the board, or a copy of the design.
enum ShareItem: Hashable {
    case picture, designFile

    var title: String {
        switch self {
        case .picture: "Image of Board"
        case .designFile: "Design File"
        }
    }

    var symbol: String {
        switch self {
        case .picture: "photo"
        case .designFile: "doc"
        }
    }

    /// Said when nothing could be made to share.
    var problem: String {
        switch self {
        case .picture: "There is nothing on the board to make a picture of yet."
        case .designFile: "Layer couldn't make a copy of the design to share."
        }
    }

    /// What the menu offers for a design: its file only once it has been saved somewhere.
    @MainActor static func offered(for model: AppModel) -> [ShareItem] {
        model.fileURL == nil ? [.picture] : [.picture, .designFile]
    }

    /// Makes the file to share: for the design, a copy of it as it is rather than the file
    /// as last saved. Nil when there is nothing to make a picture of.
    @MainActor func file(for model: AppModel) async throws -> URL? {
        switch self {
        case .picture: await BoardSnapshot.file(of: model)
        case .designFile: try await model.fileToShare()
        }
    }

    /// Takes away what was made, once the share sheet has closed: a copy of a design can be
    /// large. A picture stays in the system's temporary folder, under the board's name.
    func cleanUp(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        guard self == .designFile, folder.lastPathComponent.hasPrefix(Self.copyPrefix) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// The start of the name of each folder a copy of a design is made in.
    static let copyPrefix = "Design-"

    /// Clears the copies made more than ten minutes ago in `temporary`, whose share sheet
    /// closed without saying so. Newer ones are left: another window may be sharing one.
    static func clearOldCopies(in temporary: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let folders = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: Array(keys))) ?? []
        let cutoff = Date.now.addingTimeInterval(-600)
        for folder in folders where folder.lastPathComponent.hasPrefix(copyPrefix) {
            guard let made = try? folder.resourceValues(forKeys: keys).contentModificationDate, made < cutoff else { continue }
            try? FileManager.default.removeItem(at: folder)
        }
    }
}

/// Files on their way to the share sheet.
struct SharedPicture: Identifiable {
    let urls: [URL]
    let id = UUID()
    /// Done once the share sheet has closed.
    var whenClosed: (@Sendable () -> Void)?

    /// A screen's A2UI, written in a folder of its own in `temporary`, which goes once the share sheet has closed.
    /// Throws, leaving nothing behind, when it can't be written.
    static func a2ui(_ shared: SharedA2UI, in temporary: URL = FileManager.default.temporaryDirectory) throws -> SharedPicture {
        let url = try shared.write(in: temporary)
        return SharedPicture(urls: [url]) { ShareFolder.remove(holding: url, prefix: SharedA2UI.folderPrefix) }
    }

    /// The SwiftUI files for every screen, written in a folder of their own in `temporary`, which goes once the share
    /// sheet has closed. Nil, leaving nothing behind, when they can't be written.
    static func codeFiles(for design: TreeContent, in temporary: URL = FileManager.default.temporaryDirectory) -> SharedPicture? {
        guard let urls = CodeFiles.write(design, in: temporary) else { return nil }
        return SharedPicture(urls: urls) {
            if let file = urls.first { ShareFolder.remove(holding: file, prefix: CodeFiles.folderPrefix) }
        }
    }
}

/// The generated SwiftUI for every screen, written out as files to share: `DesignTokens.swift`
/// too when the views use the design's tokens.
enum CodeFiles {
    /// The start of the name of each folder the files are written in to share.
    static let folderPrefix = "SwiftUI-"

    /// The files, in a folder of their own in `temporary`, which goes when the share sheet closes
    /// (`ShareFolder.remove(holding:prefix:)`). Nil, leaving nothing behind, when they can't be written.
    static func write(_ design: TreeContent, in temporary: URL = FileManager.default.temporaryDirectory) -> [URL]? {
        guard let folder = try? ShareFolder.make(folderPrefix, in: temporary) else { return nil }
        do {
            return try SwiftUICodeGenerator.files(for: design, settings: design.settings.code).map { file in
                let url = folder.appendingPathComponent(file.name)
                try Data(file.source.utf8).write(to: url, options: .atomic)
                return url
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
    }
}

/// The system share sheet.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var whenClosed: (@Sendable () -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        Self.controller(sharing: items, whenClosed: whenClosed)
    }

    /// The share sheet for `items`, which calls `whenClosed` when it closes, whether something was shared or not.
    static func controller(sharing items: [Any], whenClosed: (@Sendable () -> Void)?) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in whenClosed?() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A picture of everything on the board: screens, loose elements and ink.
@MainActor
enum BoardSnapshot {
    /// A small picture of the board for the document browser, as JPEG data. The board
    /// sits on a card of canvas that is never very wide or very tall, whatever shape the
    /// design is, so that designs line up in a grid. Nil for a board with nothing on it.
    static func thumbnail(of model: AppModel) -> Data? {
        thumbnailParts(of: model)?.thumbnail()
    }

    /// The part of a thumbnail that has to be drawn on the main thread, the board's SwiftUI
    /// views. The ink and the JPEG can be done after, on any thread.
    static func thumbnailParts(of model: AppModel) -> Parts? {
        // The browser shows a thumbnail at most a few hundred pixels across.
        parts(of: model, longestSide: 480, aspect: 0.8...1.25)
    }

    /// A board drawn but not yet put together with its ink.
    struct Parts: @unchecked Sendable {
        let design: UIImage
        let drawing: PKDrawing?
        let area: CGRect
        let scale: CGFloat

        func image() -> UIImage {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            return UIGraphicsImageRenderer(size: area.size, format: format).image { _ in
                design.draw(in: CGRect(origin: .zero, size: area.size))
                drawing?.image(from: area, scale: scale).draw(in: CGRect(origin: .zero, size: area.size))
            }
        }

        func thumbnail() -> Data? {
            image().jpegData(compressionQuality: 0.8)
        }

        func png() -> Data? {
            image().pngData()
        }
    }

    /// The board as a PNG, no more than 4096 pixels along its longer side. Only its views
    /// are drawn on the main thread: at that size its ink, the picture and the PNG take
    /// long enough to hold the app up, so they are made on another. `offTheMainThread` is
    /// called there first: a test looks at where that is.
    static func png(of model: AppModel, offTheMainThread: @escaping @Sendable () async -> Void = {}) async -> Data? {
        guard let parts = parts(of: model, longestSide: 4096, aspect: nil) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            await offTheMainThread()
            return parts.png()
        }.value
    }

    private static func parts(of model: AppModel, longestSide: CGFloat, aspect: ClosedRange<CGFloat>?) -> Parts? {
        let drawing = model.store.tree.visibleInk
        let ink = drawing.strokes.isEmpty ? nil : drawing.bounds
        let design = model.store.contentBounds
        guard var area = (design.map { ink?.union($0) ?? $0 } ?? ink)?.insetBy(dx: -40, dy: -40).integral else { return nil }
        if let aspect {
            let width = max(area.width, area.height * aspect.lowerBound)
            let height = max(area.height, area.width / aspect.upperBound)
            area = area.insetBy(dx: (area.width - width) / 2, dy: (area.height - height) / 2).integral
        }

        // Drawn from the tree through the canvas's own views.
        let tree = model.store.tree
        let tokens = tree.settings.tokens
        let board = ZStack(alignment: .topLeading) {
            ForEach(tree.screens) { screen in
                ScreenView(screen: screen, device: tree.device(of: screen), tokens: tokens, showsName: tree.settings.showsFrameNames)
                    .equatable()
                    .offset(x: screen.origin.x, y: screen.origin.y)
            }
            ForEach(tree.canvas) { node in
                CanvasNodeView(node: node, tokens: tokens)
                    .equatable()
                    // Drawings last, as the canvas draws them.
                    .zIndex(node.kind == .drawing ? 1 : 0)
            }
        }
        .offset(x: -area.minX, y: -area.minY)
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .background(model.store.canvas.resolvedBackground.color)
        .environment(model.images)

        let scale = min(2, longestSide / max(area.width, area.height))
        let renderer = ImageRenderer(content: board)
        renderer.scale = scale
        guard let design = renderer.uiImage else { return nil }
        return Parts(design: design, drawing: ink == nil ? nil : drawing, area: area, scale: scale)
    }

    /// Writes the snapshot as a PNG named after the board, for sharing. The file is
    /// written off the main thread too.
    static func file(of model: AppModel) async -> URL? {
        guard let data = await png(of: model) else { return nil }
        let name = (model.chosenName ?? "Board").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("png")
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do {
                try data.write(to: url, options: .atomic)
                return url
            } catch {
                return nil
            }
        }.value
    }
}

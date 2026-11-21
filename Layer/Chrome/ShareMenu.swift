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
            // The code of the selected screen, or of the first one.
            if let screen = model.selectedScreen ?? model.store.screens.first {
                ShareLink(
                    item: SwiftUICodeGenerator.code(for: screen, settings: model.store.canvas.code),
                    preview: SharePreview(SwiftUICodeGenerator.fileName(for: screen))
                ) {
                    Label("SwiftUI Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            if model.store.screens.count > 1 {
                Button("SwiftUI Files for All Screens", systemImage: "doc.on.doc") {
                    if let urls = CodeFiles.write(model.store.screens, settings: model.store.canvas.code) {
                        picture = SharedPicture(urls: urls)
                    }
                }
            }
            Button("Image of Board", systemImage: "photo") {
                Task {
                    isPreparing = true
                    defer { isPreparing = false }
                    if let url = await BoardSnapshot.file(of: model) {
                        picture = SharedPicture(urls: [url])
                    } else {
                        problem = "There is nothing on the board to make a picture of yet."
                    }
                }
            }
            if model.fileURL != nil {
                // A copy of the design as it is, rather than the file as last saved.
                Button("Design File", systemImage: "doc") {
                    Task {
                        isPreparing = true
                        defer { isPreparing = false }
                        do {
                            picture = SharedPicture(urls: [try await model.fileToShare()])
                        } catch {
                            problem = "Layer couldn't make a copy of the design to share."
                        }
                    }
                }
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
            ActivityView(items: picture.urls)
        }
        .alert(problem ?? "", isPresented: Binding { problem != nil } set: { if !$0 { problem = nil } }) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// Files on their way to the share sheet.
private struct SharedPicture: Identifiable {
    let urls: [URL]
    let id = UUID()
}

/// The generated SwiftUI for every screen, written out as files to share.
enum CodeFiles {
    static func write(_ screens: [DesignScreen], settings: CodeSettings) -> [URL]? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftUI-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return try SwiftUICodeGenerator.files(for: screens, settings: settings).map { file in
                let url = folder.appendingPathComponent(file.name)
                try Data(file.source.utf8).write(to: url, options: .atomic)
                return url
            }
        } catch {
            return nil
        }
    }
}

/// The system share sheet.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
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
    /// long enough to hold the app up, so they are made on another.
    static func png(of model: AppModel) async -> Data? {
        guard let parts = parts(of: model, longestSide: 4096, aspect: nil) else { return nil }
        return await Task.detached(priority: .userInitiated) { parts.png() }.value
    }

    private static func parts(of model: AppModel, longestSide: CGFloat, aspect: ClosedRange<CGFloat>?) -> Parts? {
        let drawing = model.store.content.visibleInk
        let ink = drawing.strokes.isEmpty ? nil : drawing.bounds
        let design = model.store.contentBounds
        guard var area = (design.map { ink?.union($0) ?? $0 } ?? ink)?.insetBy(dx: -40, dy: -40).integral else { return nil }
        if let aspect {
            let width = max(area.width, area.height * aspect.lowerBound)
            let height = max(area.height, area.width / aspect.upperBound)
            area = area.insetBy(dx: (area.width - width) / 2, dy: (area.height - height) / 2).integral
        }

        let board = ZStack(alignment: .topLeading) {
            ForEach(model.store.screens) { screen in
                PhoneScreenView(screen: screen, showsName: model.store.canvas.showsFrameNames)
                    .offset(x: screen.origin.x, y: screen.origin.y)
            }
            ForEach(model.store.floating) { floating in
                FloatingElementView(floating: floating)
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
        let name = (model.store.title ?? "Board").replacingOccurrences(of: "/", with: "-")
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

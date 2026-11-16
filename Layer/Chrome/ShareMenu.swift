import PencilKit
import SwiftUI
import UIKit

/// The share button: the generated SwiftUI, a picture of the board, or the design file.
struct ShareMenu: View {
    @Environment(AppModel.self) private var model
    @State private var picture: SharedPicture?
    @State private var nothingToShare = false

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
                if let url = BoardSnapshot.file(of: model) {
                    picture = SharedPicture(urls: [url])
                } else {
                    nothingToShare = true
                }
            }
            if let url = model.fileURL {
                ShareLink(item: url) {
                    Label("Design File", systemImage: "doc")
                }
            }
        } label: {
            ToolIcon(symbol: "square.and.arrow.up")
        }
        .accessibilityLabel("Share")
        .popover(item: $picture) { picture in
            ActivityView(items: picture.urls)
        }
        .alert("There is nothing on the board to make a picture of yet.", isPresented: $nothingToShare) {
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
        image(of: model, longestSide: 640, aspect: 0.8...1.25)?.jpegData(compressionQuality: 0.8)
    }

    /// A picture no more than `longestSide` pixels along its longer side. `aspect` limits
    /// its width over its height, by adding canvas around the board.
    static func image(of model: AppModel, longestSide: CGFloat = 4096, aspect: ClosedRange<CGFloat>? = nil) -> UIImage? {
        let drawing = model.document.current.drawing
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

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: area.size, format: format).image { _ in
            design.draw(in: CGRect(origin: .zero, size: area.size))
            if ink != nil {
                drawing.image(from: area, scale: scale).draw(in: CGRect(origin: .zero, size: area.size))
            }
        }
    }

    /// Writes the snapshot as a PNG named after the board, for sharing.
    static func file(of model: AppModel) -> URL? {
        guard let data = image(of: model)?.pngData() else { return nil }
        let name = (model.store.title ?? "Board").replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

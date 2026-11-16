import SwiftUI

@main
struct LayerApp: App {
    init() {
        CloudFile.prepareContainer()
    }

    var body: some Scene {
        DocumentGroup(newDocument: { LayerDocument() }) { configuration in
            DesignEditor(document: configuration.document, fileURL: configuration.fileURL)
                // The system makes a new document object when a file changes underneath
                // the app, for instance when iCloud delivers another device's edits.
                // A new identity gives that object a fresh editor.
                .id(ObjectIdentifier(configuration.document))
        }

        DocumentGroupLaunchScene("Layer") {
            NewDocumentButton("New Design")
        } background: {
            CanvasGrid()
        }
    }
}

/// The canvas for one open design.
private struct DesignEditor: View {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private let fileURL: URL?

    init(document: LayerDocument, fileURL: URL?) {
        _model = State(initialValue: AppModel(document: document))
        self.fileURL = fileURL
    }

    var body: some View {
        CanvasScreen()
            .environment(model)
            .environment(model.images)
            .onChange(of: fileURL, initial: true) { _, url in model.fileURL = url }
            .onDisappear { model.close() }
            // The system saves a design as the app leaves the screen; its picture goes with it.
            .onChange(of: scenePhase) { _, phase in
                model.isActive = phase == .active
                if phase == .active {
                    // Things can change while the app is away: iCloud delivers other
                    // devices' edits, and Apple Intelligence gets turned on or finishes downloading.
                    model.checkFile()
                    model.engine.prepare()
                } else {
                    model.refreshPreview()
                }
            }
            // The system's own document object says when a save finishes or a conflict turns up.
            .onReceive(NotificationCenter.default.publisher(for: UIDocument.stateChangedNotification)) { note in
                guard let saved = note.object as? UIDocument,
                      saved.fileURL.standardizedFileURL == model.fileURL?.standardizedFileURL
                else { return }
                model.checkFile()
            }
            .preferredColorScheme(.light)
            .toolbar(.hidden, for: .navigationBar)
            .persistentSystemOverlays(.hidden)
    }
}

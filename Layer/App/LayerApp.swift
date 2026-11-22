import SwiftUI

@main
struct LayerApp: App {
    init() {
        CloudFile.prepareContainer()
        DesignLibrary.prepare()
        // Siri, Shortcuts and Spotlight learn what designs and screens there are.
        Task { @MainActor in
            await DesignIndexer.reindexLibrary()
            LayerShortcuts.updateAppShortcutParameters()
        }
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
                // The cog for Layer's settings, among the browser's own buttons.
                .task { await SettingsButton.install() }
        }
    }
}

/// The canvas for one open design.
private struct DesignEditor: View {
    /// Makes the design's model once. `State(initialValue:)` would make one on every
    /// `init`, which the document group runs again whenever it is redrawn (when the file
    /// is renamed, for instance), and throw all but the first away.
    @State private var made = MadeOnce()
    @Environment(\.scenePhase) private var scenePhase
    /// Squeeze to Talk, watched in case it is changed some way that doesn't tell the open
    /// designs itself, as Settings and the Magic Pen tab do. The design reads the setting
    /// itself, as it does when it opens.
    @AppStorage(AppModel.squeezesToTalkKey, store: AppSettings.defaults) private var squeezesToTalk = true

    private let document: LayerDocument
    private let fileURL: URL?

    init(document: LayerDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
    }

    var body: some View {
        let model = made.model(for: document)
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
                } else if phase == .background {
                    model.leavingTheScreen()
                } else {
                    model.refreshPreview()
                    model.withdrawTakenActionsWithNothingLeft()
                }
            }
            // The system's own document object says when a save finishes or a conflict turns up.
            .onReceive(NotificationCenter.default.publisher(for: UIDocument.stateChangedNotification)) { note in
                guard let saved = note.object as? UIDocument,
                      saved.fileURL.standardizedFileURL == model.fileURL?.standardizedFileURL
                else { return }
                model.checkFile()
            }
            // A key added or a default changed in Settings can change what this design uses.
            .onReceive(NotificationCenter.default.publisher(for: ModelPreferences.changed)) { _ in
                model.applyModelChoice()
                model.engine.prepare()
            }
            .onChange(of: squeezesToTalk) { model.readSqueezesToTalk() }
            .preferredColorScheme(.light)
            .toolbar(.hidden, for: .navigationBar)
            .persistentSystemOverlays(.hidden)
    }
}

/// Holds the model of the design an editor shows, made the first time it is asked for.
@MainActor
private final class MadeOnce {
    private var model: AppModel?

    func model(for document: LayerDocument) -> AppModel {
        if let model { return model }
        let made = AppModel(document: document)
        model = made
        return made
    }
}

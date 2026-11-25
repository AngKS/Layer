import os
import SwiftUI
import UniformTypeIdentifiers

/// A design as the system's document machinery sees it: something to read from a file
/// and to snapshot for saving. The system reads and writes off the main thread, so this
/// holds the latest saved-form copy of the design behind a lock; `AppModel` keeps it up
/// to date as the design changes.
final class LayerDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.layerDesign]

    private let state: OSAllocatedUnfairLock<State>

    private struct State {
        var file: DesignFile
        /// How many times the design has been changed here, and how many of those changes
        /// the last snapshot for saving had seen.
        var changes = 0
        var snapshotted = 0
    }
    /// Whether this design was made just now rather than opened. Its file then still has
    /// the name the system gave it.
    let isNew: Bool

    /// A new, empty design, made with `model`: the app's default model unless said.
    init(model: ModelChoice = ModelPreferences.defaultChoice) {
        // A new design starts with the app's default model, and keeps it from then on.
        var new = DesignFile()
        new.content.settings.model = model
        state = OSAllocatedUnfairLock(initialState: State(file: new))
        isNew = true
    }

    /// A design that was opened: `file` is what was read from disk.
    init(file opened: DesignFile) {
        state = OSAllocatedUnfairLock(initialState: State(file: opened))
        isNew = false
    }

    init(configuration: ReadConfiguration) throws {
        state = OSAllocatedUnfairLock(initialState: State(file: try DesignFile(wrapper: configuration.file)))
        isNew = false
    }

    /// The design as it would be saved right now.
    var current: DesignFile {
        state.withLock { $0.file }
    }

    func update(_ change: @Sendable (inout DesignFile) -> Void) {
        state.withLock {
            change(&$0.file)
            $0.changes += 1
        }
    }

    /// Whether the design has changed since it was last taken for saving: what a design
    /// that is closing still has to tell the system to save.
    var hasChangesSinceSnapshot: Bool {
        state.withLock { $0.changes != $0.snapshotted }
    }

    func snapshot(contentType: UTType) throws -> DesignFile {
        state.withLock {
            $0.snapshotted = $0.changes
            return $0.file
        }
    }

    func fileWrapper(snapshot: DesignFile, configuration: WriteConfiguration) throws -> FileWrapper {
        try snapshot.wrapper(replacing: configuration.existingFile)
    }
}

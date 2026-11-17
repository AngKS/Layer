import os
import SwiftUI
import UniformTypeIdentifiers

/// A design as the system's document machinery sees it: something to read from a file
/// and to snapshot for saving. The system reads and writes off the main thread, so this
/// holds the latest saved-form copy of the design behind a lock; `AppModel` keeps it up
/// to date as the design changes.
final class LayerDocument: ReferenceFileDocument {
    static let readableContentTypes: [UTType] = [.layerDesign]

    private let file: OSAllocatedUnfairLock<DesignFile>
    /// Whether this design was made just now rather than opened. Its file then still has
    /// the name the system gave it.
    let isNew: Bool

    /// A new, empty design.
    init() {
        // A new design starts with the app's default model, and keeps it from then on.
        var new = DesignFile()
        new.content.canvas.model = ModelPreferences.defaultChoice
        file = OSAllocatedUnfairLock(initialState: new)
        isNew = true
    }

    /// A design that was opened: `file` is what was read from disk.
    init(file opened: DesignFile) {
        file = OSAllocatedUnfairLock(initialState: opened)
        isNew = false
    }

    init(configuration: ReadConfiguration) throws {
        file = OSAllocatedUnfairLock(initialState: try DesignFile(wrapper: configuration.file))
        isNew = false
    }

    /// The design as it would be saved right now.
    var current: DesignFile {
        file.withLock { $0 }
    }

    func update(_ change: @Sendable (inout DesignFile) -> Void) {
        file.withLock { change(&$0) }
    }

    func snapshot(contentType: UTType) throws -> DesignFile {
        current
    }

    func fileWrapper(snapshot: DesignFile, configuration: WriteConfiguration) throws -> FileWrapper {
        try snapshot.wrapper(replacing: configuration.existingFile)
    }
}

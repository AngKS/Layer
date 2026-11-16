import Foundation

/// How a design's file is named after its board, and the renaming itself.
enum DesignFileName {
    /// The file name for a board title, without the extension: the title itself, less
    /// the few things a file name can't hold.
    static func fileName(for title: String) -> String {
        var name = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        // A leading full stop would hide the file.
        while name.hasPrefix(".") { name.removeFirst() }
        return String(name.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// The name the system gives new designs, "Untitled" in English. It is in the
    /// language of the iPad, so it is learned from the first new design rather than assumed.
    static var untitled: String {
        get { UserDefaults.standard.string(forKey: "untitledFileName") ?? "Untitled" }
        set { UserDefaults.standard.set(newValue, forKey: "untitledFileName") }
    }

    /// A name without the number the system adds to tell files apart: "Untitled 3" is "Untitled".
    static func withoutNumber(_ name: String) -> String {
        let words = name.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count > 1, let last = words.last, Int(last) != nil else { return name }
        return words.dropLast().joined(separator: " ")
    }

    /// Whether a file still has the name it was created with, which nobody chose.
    static func isUntitled(_ name: String) -> Bool {
        let base = withoutNumber(name)
        return base == untitled || base == "Untitled"
    }

    /// The first name of `name`, `name 2`, `name 3`, … that nothing in the folder has.
    static func unused(_ name: String, extension ext: String, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(ext)
        var number = 2
        while isTaken(candidate) {
            candidate = folder.appendingPathComponent("\(name) \(number)").appendingPathExtension(ext)
            number += 1
        }
        return candidate
    }

    /// Renames a design's file where it is, giving it a number if the name is taken.
    /// Anything that has the file open, the document itself included, is told that it
    /// moved, so nothing is lost by renaming a design that is being edited. Returns
    /// where the file is now.
    static func rename(_ url: URL, to name: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // File coordination waits on whoever else has the file, so not on the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let isScoped = url.startAccessingSecurityScopedResource()
                defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

                let folder = url.deletingLastPathComponent()
                let destination = unused(name, extension: url.pathExtension, in: folder) {
                    FileManager.default.fileExists(atPath: $0.path)
                }
                let coordinator = NSFileCoordinator(filePresenter: nil)
                var coordinationError: NSError?
                var outcome: Result<URL, any Error> = .failure(CocoaError(.fileWriteUnknown))
                coordinator.coordinate(
                    writingItemAt: url, options: .forMoving,
                    writingItemAt: destination, options: .forReplacing,
                    error: &coordinationError
                ) { from, to in
                    do {
                        try FileManager.default.moveItem(at: from, to: to)
                        coordinator.item(at: from, didMoveTo: to)
                        outcome = .success(to)
                    } catch {
                        outcome = .failure(error)
                    }
                }
                if let coordinationError { outcome = .failure(coordinationError) }
                continuation.resume(with: outcome)
            }
        }
    }
}

import Foundation
import os

/// One design as Siri, Shortcuts and Spotlight see it: where it is and what it holds.
struct DesignSummary: Sendable {
    let id: String
    let url: URL
    let title: String
    let modified: Date?
    /// Empty when the file couldn't be read, as when iCloud hasn't downloaded it yet.
    let content: DesignContent
}

/// Finds Layer's designs on disk and reads them, for the system features that work with
/// designs that aren't open: Siri, Shortcuts and Spotlight.
///
/// A design is known by an identifier that survives relaunches and app updates: its path
/// inside Layer's iCloud folder or its Documents folder, or its full path anywhere else.
enum DesignLibrary {
    struct Roots: Sendable {
        /// Layer's folder in iCloud Drive, when signed in to iCloud.
        var cloud: URL?
        /// On My iPad › Layer.
        var local: URL
    }

    private static let cachedRoots = OSAllocatedUnfairLock<Roots?>(initialState: nil)

    /// Where designs are kept. Asking for the iCloud folder talks to another process the
    /// first time, so the first call is best made off the main thread; `prepare()` does that.
    nonisolated static var roots: Roots {
        if let roots = cachedRoots.withLock({ $0 }) { return roots }
        let cloud = FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appendingPathComponent("Documents")
        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let roots = Roots(cloud: cloud?.standardizedFileURL, local: local.standardizedFileURL)
        cachedRoots.withLock { $0 = roots }
        return roots
    }

    /// Looks up the folders off the main thread, so later calls are quick.
    static func prepare() {
        DispatchQueue.global(qos: .utility).async { _ = roots }
    }

    private static let cloudPrefix = "icloud:"
    private static let localPrefix = "local:"
    private static let filePrefix = "file:"

    nonisolated static func id(for url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = roots
        if let cloud = roots.cloud?.resolvingSymlinksInPath().path, let relative = relativePath(path, inside: cloud) {
            return cloudPrefix + relative
        }
        if let relative = relativePath(path, inside: roots.local.resolvingSymlinksInPath().path) {
            return localPrefix + relative
        }
        return filePrefix + path
    }

    nonisolated static func url(for id: String) -> URL? {
        let roots = roots
        if id.hasPrefix(cloudPrefix) {
            return roots.cloud?.appendingPathComponent(String(id.dropFirst(cloudPrefix.count)))
        }
        if id.hasPrefix(localPrefix) {
            return roots.local.appendingPathComponent(String(id.dropFirst(localPrefix.count)))
        }
        if id.hasPrefix(filePrefix) {
            return URL(fileURLWithPath: String(id.dropFirst(filePrefix.count)))
        }
        return nil
    }

    private nonisolated static func relativePath(_ path: String, inside folder: String) -> String? {
        let base = folder.hasSuffix("/") ? folder : folder + "/"
        guard path.hasPrefix(base) else { return nil }
        return String(path.dropFirst(base.count))
    }

    /// Every design in Layer's iCloud and On My iPad folders. Reads the disk.
    nonisolated static func designURLs() -> [URL] {
        let roots = roots
        var found: [URL] = []
        for folder in [roots.cloud, roots.local].compactMap(\.self) {
            guard let items = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in items where url.pathExtension == "layer" {
                found.append(url)
            }
        }
        return found
    }

    /// Reads one design, coordinating with iCloud and any app writing it. Reads the disk.
    nonisolated static func read(_ url: URL) -> DesignSummary {
        let name = url.deletingPathExtension().lastPathComponent
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var content = DesignContent()
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readable in
            if let read = try? DesignFile.content(at: readable) { content = read }
        }
        return DesignSummary(id: id(for: url), url: url, title: content.title ?? name, modified: modified, content: content)
    }

    /// Every design, newest first, read off the main thread.
    static func all() async -> [DesignSummary] {
        await Task.detached(priority: .userInitiated) {
            designURLs().map(read).sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }.value
    }

    /// One design, read off the main thread. Nil when there is no such file.
    static func summary(for id: String) async -> DesignSummary? {
        guard let url = url(for: id) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> DesignSummary? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return read(url)
        }.value
    }
}

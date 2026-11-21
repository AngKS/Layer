import Foundation
import os

/// One design as Siri, Shortcuts and Spotlight see it: where it is and what it holds.
struct DesignSummary: Sendable {
    let id: String
    let url: URL
    let title: String
    let modified: Date?
    /// Empty when the file couldn't be read, or, in the list of every design, when iCloud
    /// hasn't downloaded it to this iPad.
    let content: DesignContent
    /// False for a design listed by its name alone, which iCloud hasn't downloaded: its
    /// content wasn't read, rather than empty.
    var isRead = true
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
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey],
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

    /// Whether a design can be read without downloading it: it isn't in iCloud, or this
    /// iPad has its latest version. Reads the disk.
    nonisolated static func isDownloaded(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              values.isUbiquitousItem == true
        else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    /// One design as the list of every design has it. A design iCloud hasn't downloaded to
    /// this iPad is listed by its file's name alone: a coordinated read would download it,
    /// its pictures and ink included, and wait for that, and the list is made at every
    /// launch and for many of Siri's questions. A design unchanged since it was last read
    /// isn't read again. Reads the disk.
    nonisolated static func listed(_ url: URL, isDownloaded: (URL) -> Bool = isDownloaded) -> DesignSummary {
        guard isDownloaded(url) else {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return DesignSummary(id: id(for: url), url: url, title: url.deletingPathExtension().lastPathComponent, modified: modified, content: DesignContent(), isRead: false)
        }
        let stamp = Stamp(of: url)
        if let stamp, let kept = listedSummaries.withLock({ $0[url] }), kept.stamp == stamp { return kept.summary }
        let summary = read(url)
        if let stamp { listedSummaries.withLock { $0[url] = (stamp, summary) } }
        return summary
    }

    /// When a design and, in a package, its design file were last changed: what says a
    /// design read before is still as it was read.
    private struct Stamp: Equatable, Sendable {
        let package: Date
        let design: Date?

        nonisolated init?(of url: URL) {
            let key: Set<URLResourceKey> = [.contentModificationDateKey]
            guard let package = try? url.resourceValues(forKeys: key).contentModificationDate else { return nil }
            self.package = package
            design = try? url.appendingPathComponent(DesignPackage.design).resourceValues(forKeys: key).contentModificationDate
        }
    }

    private static let listedSummaries = OSAllocatedUnfairLock<[URL: (stamp: Stamp, summary: DesignSummary)]>(initialState: [:])

    /// Every design, newest first, read off the main thread.
    static func all() async -> [DesignSummary] {
        await Task.detached(priority: .userInitiated) {
            let urls = designURLs()
            let summaries = urls.map { listed($0) }
            // Designs that have gone are forgotten.
            let present = Set(urls)
            listedSummaries.withLock { $0 = $0.filter { present.contains($0.key) } }
            return summaries.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
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

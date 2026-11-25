import Foundation
import os

/// One design as Siri, Shortcuts and Spotlight see it: where it is and what it holds.
struct DesignSummary: Sendable {
    let id: String
    let url: URL
    let title: String
    let modified: Date?
    /// Empty when the file couldn't be read, or, in the list of every design, when iCloud
    /// hasn't downloaded it to this iPad. A design this version refuses to open has no summary.
    let content: TreeContent
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

    /// Reads one design, coordinating with iCloud and any app writing it. Nil for a design
    /// this version can't open, one saved by an earlier or a newer version or one whose
    /// design file can't be read at all: it is skipped, rather than listed as empty, and
    /// Spotlight lets it go. Reads the disk.
    nonisolated static func read(_ url: URL) -> DesignSummary? {
        let name = url.deletingPathExtension().lastPathComponent
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var content = TreeContent()
        var refused = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { readable in
            do {
                content = try DesignFile.content(at: readable).tree
            } catch is DesignFile.ReadError {
                refused = true
            } catch {}
        }
        guard !refused else { return nil }
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
    /// isn't read again. Nil for a design this version refuses to open, as `read` has it.
    /// Reads the disk.
    nonisolated static func listed(_ url: URL, isDownloaded: (URL) -> Bool = isDownloaded) -> DesignSummary? {
        guard isDownloaded(url) else { return byName(url, modified: modified(of: url)) }
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

    /// What each design read for the list was found to be, a refused one included.
    private static let listedSummaries = OSAllocatedUnfairLock<[URL: (stamp: Stamp, summary: DesignSummary?)]>(initialState: [:])

    /// A design listed by its name alone, without reading it.
    private nonisolated static func byName(_ url: URL, modified: Date?) -> DesignSummary {
        DesignSummary(id: id(for: url), url: url, title: url.deletingPathExtension().lastPathComponent, modified: modified, content: TreeContent(), isRead: false)
    }

    private nonisolated static func modified(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The design a hidden iCloud placeholder, `.Name.layer.icloud`, stands for: how iCloud
    /// Drive has kept a file it hasn't downloaded, beside keeping it under its own name
    /// with no contents. Nil for anything else.
    private nonisolated static func design(heldBy placeholder: URL) -> URL? {
        let name = placeholder.lastPathComponent
        let suffix = ".layer.icloud"
        guard name.hasPrefix("."), name.hasSuffix(suffix), name.count > suffix.count + 1 else { return nil }
        return placeholder.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(".icloud".count)))
    }

    /// Every design in some folders, and which of them could be looked through.
    struct Listing: Sendable {
        var designs: [DesignSummary]
        /// The folders that were looked through. A design in one that couldn't be, iCloud's
        /// when it can't be reached, may still be there.
        var folders: [URL]

        /// Whether a design that isn't in `designs` is known to have gone: it would have
        /// been in a folder that was looked through, or it is outside Layer's folders, as a
        /// design opened from elsewhere is, which Siri couldn't open anyway. A design in a
        /// folder that couldn't be found or looked through may still be there.
        func hasGone(_ id: String) -> Bool {
            if id.hasPrefix(DesignLibrary.filePrefix) { return true }
            guard let url = DesignLibrary.url(for: id) else { return false }
            let path = url.standardizedFileURL.path
            return folders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
    }

    /// Every design in `folders`, newest first, each as `listed` has it. A design iCloud
    /// keeps here only as a hidden placeholder is listed by its name, like one it keeps
    /// under its own name with no contents. A design this version refuses to open is left
    /// out. Hidden folders, iCloud's trash among them, aren't looked in. Reads the disk.
    nonisolated static func list(in folders: [URL], isDownloaded: (URL) -> Bool = isDownloaded) -> Listing {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        var looked: [URL] = []
        var found: [String: DesignSummary] = [:]
        var refused: Set<String> = []
        var present: Set<URL> = []
        for folder in folders {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue,
                  let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
            else { continue }
            looked.append(folder)
            for case let url as URL in items {
                if !url.lastPathComponent.hasPrefix(".") {
                    guard url.pathExtension == "layer" else { continue }
                    let key = url.standardizedFileURL.path
                    found[key] = listed(url, isDownloaded: isDownloaded)
                    if found[key] == nil { refused.insert(key) }
                    present.insert(url)
                } else if let design = design(heldBy: url) {
                    // The design itself wins over a placeholder for it, should both be there,
                    // even when it is refused.
                    let key = design.standardizedFileURL.path
                    if found[key] == nil, !refused.contains(key) { found[key] = byName(design, modified: modified(of: url)) }
                } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    items.skipDescendants()
                }
            }
        }
        // Designs that have gone from the folders looked through are forgotten.
        let listedNow = present
        let lookedIn = looked.map { $0.standardizedFileURL.path + "/" }
        listedSummaries.withLock {
            $0 = $0.filter { url, _ in
                listedNow.contains(url) || !lookedIn.contains { url.standardizedFileURL.path.hasPrefix($0) }
            }
        }
        let designs = found.values.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        return Listing(designs: designs, folders: looked)
    }

    /// Every design in Layer's iCloud and On My iPad folders, newest first, listed off the
    /// main thread.
    static func all() async -> [DesignSummary] {
        await everything().designs
    }

    /// Every design in Layer's folders, and which of the folders could be looked through,
    /// listed off the main thread.
    static func everything() async -> Listing {
        await Task.detached(priority: .userInitiated) {
            let roots = roots
            return list(in: [roots.cloud, roots.local].compactMap(\.self))
        }.value
    }

    /// One design, read off the main thread. Nil when there is no such file, or it is refused.
    static func summary(for id: String) async -> DesignSummary? {
        guard let url = url(for: id) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> DesignSummary? in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return read(url)
        }.value
    }
}

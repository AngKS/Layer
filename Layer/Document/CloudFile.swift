import Foundation

/// What iCloud says about a design's file.
enum SyncState: Equatable, Sendable {
    /// Kept on this iPad only: in On My iPad, or in a folder iCloud doesn't sync.
    /// `canUseICloud` is false when nobody is signed in to iCloud.
    case local(canUseICloud: Bool)
    case upToDate
    case uploading
    /// In iCloud Drive with changes that haven't gone up yet, as when offline.
    case waitingToUpload
    case failed(String)

    var title: String {
        switch self {
        case .local: "On this iPad only"
        case .upToDate: "In iCloud Drive"
        case .uploading: "Uploading to iCloud…"
        case .waitingToUpload: "Waiting to upload"
        case .failed: "iCloud couldn't upload this design"
        }
    }

    var detail: String? {
        switch self {
        case .local(canUseICloud: true): "Move it to iCloud Drive in Files to have it on your other devices."
        case .local(canUseICloud: false): "Sign in to iCloud in Settings to have designs on your other devices."
        case .upToDate, .uploading: nil
        case .waitingToUpload: "It goes up when this iPad is next online."
        case .failed(let reason): reason
        }
    }

    var symbol: String {
        switch self {
        case .local: "ipad"
        case .upToDate: "checkmark.icloud"
        case .uploading: "icloud.and.arrow.up"
        case .waitingToUpload: "icloud.slash"
        case .failed: "exclamationmark.icloud"
        }
    }

    /// Whether it is worth looking again soon.
    var isInFlux: Bool { self == .uploading || self == .waitingToUpload }
}

/// A design's file as iCloud sees it: whether it has synced, and what to do when two
/// devices have each saved a version of their own.
enum CloudFile {
    /// Asks the system where a design's file stands. Quick, but it talks to another
    /// process, so not for the main thread.
    static func syncState(of url: URL) -> SyncState {
        // A URL remembers what it was last told; a fresh one asks again.
        var url = url
        url.removeAllCachedResourceValues()
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .ubiquitousItemIsUploadingKey, .ubiquitousItemUploadingErrorKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true else {
            return .local(canUseICloud: FileManager.default.ubiquityIdentityToken != nil)
        }
        if let error = values.ubiquitousItemUploadingError { return .failed(error.localizedDescription) }
        if values.ubiquitousItemIsUploaded == true { return .upToDate }
        return values.ubiquitousItemIsUploading == true ? .uploading : .waitingToUpload
    }

    /// Makes sure Layer's folder exists in iCloud Drive, which is what makes it show up
    /// in Files and as the place new designs are saved. Does nothing without iCloud.
    static func prepareContainer() {
        DispatchQueue.global(qos: .utility).async {
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return }
            settleConflicts(in: container.appendingPathComponent("Documents"))
        }
    }

    /// Settles every design in Layer's iCloud folder that two devices saved at once, not
    /// just the one that is open. A conflicted file left unresolved anywhere in the folder
    /// can leave the document browser unable to make new designs. Off the main thread.
    nonisolated static func settleConflicts(in folder: URL) {
        guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { return }
        for case let url as URL in items where url.pathExtension == "layer" {
            if NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty == false {
                _ = keepConflictingVersionsNow(of: url)
            }
        }
    }

    /// The name for a version of a design kept aside as a copy.
    static func copyName(for name: String, savedOn device: String?) -> String {
        guard let device, !device.isEmpty else { return "\(name) (other version)" }
        return "\(name) (from \(DesignFileName.fileName(for: device)))"
    }

    /// Settles a design that was edited on two devices before they could sync. iCloud
    /// has already chosen which version is the design; every other version is saved
    /// beside it as a design of its own, so that nothing anyone drew is lost. Returns the
    /// names of the copies it made, which is empty when there was nothing to settle.
    static func keepConflictingVersions(of url: URL) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: keepConflictingVersionsNow(of: url))
            }
        }
    }

    /// The work of `keepConflictingVersions(of:)`, done on the calling thread.
    nonisolated static func keepConflictingVersionsNow(of url: URL) -> [String] {
        let isScoped = url.startAccessingSecurityScopedResource()
        defer { if isScoped { url.stopAccessingSecurityScopedResource() } }

        guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url), !versions.isEmpty else {
            return []
        }
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        var copies: [String] = []
        for version in versions {
            let copyName = copyName(for: name, savedOn: version.localizedNameOfSavingComputer)
            let destination = DesignFileName.unused(copyName, extension: url.pathExtension, in: folder) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            var coordinationError: NSError?
            var isCopied = false
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: destination, options: .forReplacing, error: &coordinationError) { to in
                isCopied = (try? FileManager.default.copyItem(at: version.url, to: to)) != nil
            }
            // A version that couldn't be copied is left unresolved rather than thrown away.
            guard isCopied else { continue }
            version.isResolved = true
            copies.append(destination.deletingPathExtension().lastPathComponent)
        }
        if NSFileVersion.unresolvedConflictVersionsOfItem(at: url)?.isEmpty ?? true {
            try? NSFileVersion.removeOtherVersionsOfItem(at: url)
        }
        return copies
    }
}

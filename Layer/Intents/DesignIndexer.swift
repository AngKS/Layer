@_weakLinked import AppIntents
import CoreSpotlight
import os

/// Keeps Spotlight's index of designs and screens current. Apple Intelligence searches
/// this index to find Layer's content for Siri, even from a vague description.
@MainActor
enum DesignIndexer {
    private static var pending: [String: Task<Void, Never>] = [:]
    /// When each design is next due to be indexed. A further change while one is pending
    /// pushes this out rather than cancelling and starting a new wait, so a flurry of
    /// changes (every frame of a drag, say) reschedules one task instead of replacing it
    /// again and again.
    private static var dueAt: [String: ContinuousClock.Instant] = [:]
    private static let log = Logger(subsystem: "kahshin.Layer", category: "spotlight")

    /// The index designs and screens go in: Spotlight's own, or a test's.
    static var spotlight: any SpotlightIndex = SystemSpotlight()
    /// Where the record of what is in the index is kept across launches: the app's
    /// defaults, or a test's own.
    static var recordDefaults = UserDefaults.standard {
        didSet { record = nil }
    }
    private static let recordKey = "spotlightIndexedScreens"
    private static let recordCompleteKey = "spotlightIndexRecordComplete"

    /// The record as last read or written, so that it is read from the defaults once.
    private static var record: [String: Set<String>]?
    /// Whether the launch pass is under way. It writes the record once, at its end.
    private static var isPassing = false

    /// The screens indexed for each design, by the design's identifier: the record of what
    /// is in the index, so that screens and designs that have gone can be taken out of it.
    /// Written back after each change, except during the launch pass.
    private static var indexedScreens: [String: Set<String>] {
        get {
            if let record { return record }
            let stored = storedRecord() ?? [:]
            record = stored
            return stored
        }
        set {
            record = newValue
            if !isPassing { saveRecord() }
        }
    }

    /// The record as kept in the defaults. Nil when there is none, or it can't be read.
    private static func storedRecord() -> [String: Set<String>]? {
        (recordDefaults.object(forKey: recordKey) as? [String: [String]])?.mapValues { Set($0) }
    }

    private static func saveRecord() {
        recordDefaults.set((record ?? [:]).mapValues { Array($0) }, forKey: recordKey)
    }

    /// A design changed: it is indexed again once it has been left alone for a few seconds.
    static func designChanged(_ model: AppModel) {
        guard let id = model.designID else { return }
        dueAt[id] = .now + .seconds(3)
        guard pending[id] == nil else { return }
        pending[id] = Task { [weak model] in
            while true {
                guard let due = dueAt[id] else { return }
                if ContinuousClock.now >= due { break }
                try? await Task.sleep(until: due)
                if Task.isCancelled { return }
            }
            pending[id] = nil
            dueAt[id] = nil
            guard let model, let snapshot = DesignActions.snapshot(of: model) else { return }
            await index(snapshot)
        }
    }

    static func index(_ snapshot: DesignSnapshot) async {
        let screens = snapshot.screens
        let current = Set(screens.map(\.id))
        let gone = Array((indexedScreens[snapshot.id] ?? []).subtracting(current))
        indexedScreens[snapshot.id] = current
        do {
            try await spotlight.index(designs: [snapshot.entity])
            if !screens.isEmpty { try await spotlight.index(screens: screens) }
            if !gone.isEmpty { try await spotlight.delete(screens: gone) }
        } catch {
            log.error("Couldn't index a design: \(error.localizedDescription)")
        }
    }

    /// Takes a design out of the index, as when it was renamed and is known by a new identifier.
    static func forget(design id: String) {
        let screens = Array(indexedScreens.removeValue(forKey: id) ?? [])
        let spotlight = spotlight
        Task {
            try? await spotlight.delete(designs: [id])
            if !screens.isEmpty { try? await spotlight.delete(screens: screens) }
        }
    }

    /// Brings the index up to date with every design. Done once at launch.
    static func reindexLibrary() async {
        let listing = await DesignLibrary.everything()
        await reindex(DesignActions.snapshots(with: listing.designs), hasGone: listing.hasGone)
    }

    /// Brings the index up to date with `snapshots`, every design that could be found. A
    /// design that was read is indexed afresh, its screens that have gone taken out. A
    /// design iCloud hasn't downloaded, listed by its name alone, is left as it was indexed,
    /// or indexed by its name if it never was: reading it would download it. A design in
    /// the record that wasn't found is taken out if `hasGone` says it has gone, rather than
    /// being in a folder that couldn't be looked through. The record is read once and
    /// written once. Without one that can be read, or one a pass has completed, what is in
    /// the index isn't known, and it is cleared and built again.
    static func reindex(_ snapshots: [DesignSnapshot], hasGone: (String) -> Bool = { _ in true }) async {
        isPassing = true
        defer { isPassing = false }
        let stored = storedRecord()
        let isKnown = stored != nil && recordDefaults.bool(forKey: recordCompleteKey)
        record = isKnown ? stored : [:]
        do {
            if !isKnown { try await spotlight.deleteAll() }
            let present = Set(snapshots.map(\.id))
            let gone = indexedScreens.filter { !present.contains($0.key) && hasGone($0.key) }
            if !gone.isEmpty {
                indexedScreens = indexedScreens.filter { gone[$0.key] == nil }
                try await spotlight.delete(designs: Array(gone.keys))
                let screens = gone.values.flatMap(\.self)
                if !screens.isEmpty { try await spotlight.delete(screens: screens) }
            }
            for snapshot in snapshots {
                if snapshot.isRead {
                    await index(snapshot)
                } else if indexedScreens[snapshot.id] == nil {
                    indexedScreens[snapshot.id] = []
                    try await spotlight.index(designs: [snapshot.entity])
                }
            }
            saveRecord()
            recordDefaults.set(true, forKey: recordCompleteKey)
        } catch {
            saveRecord()
            log.error("Couldn't bring the design index up to date: \(error.localizedDescription)")
        }
    }
}

/// Where designs and screens are indexed for Spotlight, which Apple Intelligence searches
/// to find Layer's content for Siri: the system's index, or one a test keeps in memory.
protocol SpotlightIndex: Sendable {
    func index(designs: [DesignEntity]) async throws
    func index(screens: [ScreenEntity]) async throws
    func delete(designs: [String]) async throws
    func delete(screens: [String]) async throws
    func deleteAll() async throws
}

/// Spotlight's own index, called off the main actor.
struct SystemSpotlight: SpotlightIndex {
    func index(designs: [DesignEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(designs)
    }

    func index(screens: [ScreenEntity]) async throws {
        try await CSSearchableIndex.default().indexAppEntities(screens)
    }

    func delete(designs: [String]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: designs, ofType: DesignEntity.self)
    }

    func delete(screens: [String]) async throws {
        try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: screens, ofType: ScreenEntity.self)
    }

    func deleteAll() async throws {
        try await CSSearchableIndex.default().deleteAppEntities(ofType: DesignEntity.self)
        try await CSSearchableIndex.default().deleteAppEntities(ofType: ScreenEntity.self)
    }
}

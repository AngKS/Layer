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
    /// The screens indexed for each design, so that deleted ones can be taken out.
    private static var indexedScreens: [String: Set<String>] = [:]
    private static let log = Logger(subsystem: "kahshin.Layer", category: "spotlight")

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
            try await Spotlight.index([snapshot.entity])
            if !screens.isEmpty { try await Spotlight.index(screens) }
            if !gone.isEmpty { try await Spotlight.delete(screens: gone) }
        } catch {
            log.error("Couldn't index a design: \(error.localizedDescription)")
        }
    }

    /// Takes a design out of the index, as when it was renamed and is known by a new identifier.
    static func forget(design id: String) {
        let screens = Array(indexedScreens.removeValue(forKey: id) ?? [])
        Task {
            try? await Spotlight.delete(designs: [id])
            if !screens.isEmpty { try? await Spotlight.delete(screens: screens) }
        }
    }

    /// Indexes every design afresh, dropping designs that have gone. Done once at launch.
    static func reindexLibrary() async {
        let snapshots = await DesignActions.allSnapshots()
        do {
            try await Spotlight.deleteAll()
            for snapshot in snapshots { await index(snapshot) }
        } catch {
            log.error("Couldn't rebuild the design index: \(error.localizedDescription)")
        }
    }

    /// The calls into Spotlight, kept off the main actor.
    private enum Spotlight {
        nonisolated static func index<Entity: IndexedEntity>(_ entities: [Entity]) async throws {
            try await CSSearchableIndex.default().indexAppEntities(entities)
        }

        nonisolated static func delete(screens: [String]) async throws {
            try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: screens, ofType: ScreenEntity.self)
        }

        nonisolated static func delete(designs: [String]) async throws {
            try await CSSearchableIndex.default().deleteAppEntities(identifiedBy: designs, ofType: DesignEntity.self)
        }

        nonisolated static func deleteAll() async throws {
            try await CSSearchableIndex.default().deleteAppEntities(ofType: DesignEntity.self)
            try await CSSearchableIndex.default().deleteAppEntities(ofType: ScreenEntity.self)
        }
    }
}

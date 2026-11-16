@_weakLinked import AppIntents
import CoreSpotlight
import os

/// Keeps Spotlight's index of designs and screens current. Apple Intelligence searches
/// this index to find Layer's content for Siri, even from a vague description.
@MainActor
enum DesignIndexer {
    private static var pending: [String: Task<Void, Never>] = [:]
    /// The screens indexed for each design, so that deleted ones can be taken out.
    private static var indexedScreens: [String: Set<String>] = [:]
    private static let log = Logger(subsystem: "kahshin.Layer", category: "spotlight")

    /// A design changed: it is indexed again once it has been left alone for a few seconds.
    static func designChanged(_ model: AppModel) {
        guard let id = model.designID else { return }
        pending[id]?.cancel()
        pending[id] = Task { [weak model] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let model, let snapshot = DesignActions.snapshot(of: model) else { return }
            pending[id] = nil
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

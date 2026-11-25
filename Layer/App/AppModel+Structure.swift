import CoreGraphics
import Foundation
import SwiftUI

/// A structure the pass is less sure of, or that would move something more than 8 pt, offered as "Make a row?" (spec §5,
/// plan 5's call 12). Accepting builds it with the rhythm's spacing, which is what it was offered with.
struct StructureOffer: Identifiable, Equatable {
    let id: UUID
    var structure: StructureInference.Structure
    var screen: TreeScreen.ID
}

/// Where a member of a structure offer is: its frame in its host's own points and its turn, where its screen is, and what
/// holds it. The offer goes once any of these changes, or the member goes (call 12): the kind suggestion's check, with
/// what holds it besides, since a thing put in a group can keep its place on the screen.
struct OfferedPlace: Equatable {
    var frame: CGRect
    var degrees: Double
    var placement: Placement
    var parent: UUID?
}

/// The structure pass after a batch of readings settles (spec §5, plan 5's calls 1, 2, 11 and 12), its offer, and declines.
/// Its state is stored in `AppModel.swift`.
extension AppModel {
    /// The offer as the pill shows it: nil while a "Did you mean" is up, which shows first (call 12).
    var shownStructureOffer: StructureOffer? { suggestion == nil ? structureOffer : nil }

    /// The pass over `nodes`' receiving containers (call 1): each one's parent that is free and is a screen's root or a
    /// container with a sketch, and each new card, whose children count as new; inside out, so that a new card's column
    /// is built before the root it lies on is looked at. What it is sure of is built, in order, as one step, or as part of
    /// the step under way (a reading's). Nothing moves more than 8 pt in it all: a structure an outer container would
    /// build is measured from where what an inner one moved lay when the pass began (plan 5's final review, A1). Of
    /// what it is less sure of, the surest is offered: one offer per pass. It reads only the tree. The end of a batch
    /// calls it.
    func structurePass(over nodes: [UUID]) {
        let receiving = receivingContainers(of: nodes)
        guard !receiving.isEmpty else { return }
        let tokens = store.tree.settings.tokens
        let started = startingPlaces(inside: receiving.map(\.id))
        var offered: StructureInference.Structure?
        var built: [UUID] = []
        keepingTheSuggestion {
            store.asOwnStep {
                for container in receiving {
                    guard let parent = store.node(container.id), let entry = store.index[container.id] else { continue }
                    // From the screen's points to the container's own, which nothing in the pass has moved yet.
                    let fromScreen = entry.toHost.inverted()
                    let decisions = StructureInference.infer(in: parent, new: container.new, grows: structuresThatMayGrow(),
                                                             tokens: tokens, depth: entry.depth,
                                                             started: started.mapValues { $0.applying(fromScreen) })
                    for decision in decisions {
                        switch decision {
                        case .apply(let structure):
                            if let id = store.build(structure), structure.kind != .cardColumn { built.append(id) }
                        case .offer(let structure):
                            if structure.confidence > offered?.confidence ?? -1 { offered = structure }
                        }
                    }
                }
            }
        }
        // Recorded once all is built: a row a column now holds is recorded as it is there.
        for id in built { builtStructures[id] = store.node(id) }
        if let offered { offer(offered) }
    }

    /// Ends the batch of readings: the pass over what it made. See `structurePass(over:)`.
    func endSketchBatch() {
        let nodes = sketchBatch
        sketchBatch = []
        guard !nodes.isEmpty else { return }
        structurePass(over: nodes)
    }

    /// Builds what is on offer, as a step of its own: "Make Row", "Make Column" or "Make Grid". One that takes the place
    /// of a container the pass made is built only while that container is as it was built (Task 6 m1): one the person
    /// has changed since, by putting a thing in it or naming it, is theirs, and nothing is built.
    func acceptStructureOffer() {
        guard let offer = structureOffer else { return }
        dismissStructureOffer()
        let mayGrow = structuresThatMayGrow()
        guard offer.structure.replacing.allSatisfy(mayGrow.contains) else { return }
        let edit = store.beginEdit(by: .app)
        store.name(edit, offer.structure.kind.stepName)
        let built = store.act(for: edit) { store.build(offer.structure) }
        store.endEdit(edit)
        if let built, offer.structure.kind != .cardColumn { builtStructures[built] = store.node(built) }
    }

    /// Remembers each of `ids` that is a container the pass made, as it is now, so that it grows as more is drawn just as
    /// what the pass builds after a batch does (call 2): voice's tidy is the pass too (call 10). A card whose column was
    /// built is the person's drawing, not one of them.
    func rememberBuiltStructures(_ ids: [UUID]) {
        for id in ids {
            guard let node = store.node(id), node.kind == .group, node.sketch?.decidedBy == .structure else { continue }
            builtStructures[id] = node
        }
    }

    /// "Keep them as drawn": what was offered is declined, so that the pass never offers it again (call 11). No step.
    func declineStructureOffer() {
        guard let offer = structureOffer else { return }
        dismissStructureOffer()
        store.declineStructure(offer.structure.members)
    }

    func dismissStructureOffer() {
        structureOfferExpiry?.cancel()
        structureOfferExpiry = nil
        structureOffer = nil
        structureOfferPlaces = [:]
        structureOfferTimeLeft = StructureConventions.offerLifetime
        structureOfferShownSince = nil
    }

    /// Starts the offer's time once it shows, or goes on with what it has left: now, or once the "Did you mean" it waits
    /// for has gone (call 12).
    func startStructureOfferClock() {
        guard structureOffer != nil, suggestion == nil, structureOfferExpiry == nil else { return }
        let left = structureOfferTimeLeft
        structureOfferShownSince = .now
        structureOfferExpiry = Task { [weak self] in
            try? await Task.sleep(for: left)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { self?.dismissStructureOffer() }
        }
    }

    /// Stops the offer's time while a "Did you mean" hides it (call 12, Task 9 m2), keeping what it has left: it goes
    /// on once that has gone (`startStructureOfferClock`).
    func pauseStructureOfferClock() {
        guard let expiry = structureOfferExpiry else { return }
        expiry.cancel()
        structureOfferExpiry = nil
        if let since = structureOfferShownSince {
            structureOfferTimeLeft = max(.zero, structureOfferTimeLeft - (ContinuousClock.now - since))
        }
        structureOfferShownSince = nil
    }

    /// Whether a member of the offer, or its screen, has changed or gone since it was offered.
    var structureOfferIsStale: Bool {
        guard let offer = structureOffer else { return false }
        return places(of: offer.structure.members) != structureOfferPlaces
    }

    /// Where the pill goes: the box round the members' shapes on the canvas, in the view's own points.
    var structureOfferViewRect: CGRect? {
        guard let offer = shownStructureOffer else { return nil }
        let index = store.index, tree = store.tree
        let boxes = offer.structure.members.compactMap { index.canvasShape(of: $0, in: tree)?.bounds }
        guard let first = boxes.first else { return nil }
        return viewport.viewRect(for: boxes.dropFirst().reduce(first) { $0.union($1) })
    }

    // MARK: - How the pass works

    /// The containers that received `nodes`, inside out, each with what is new in it. A container locked or hidden,
    /// itself or through what holds it, receives nothing: what is in it can't be moved.
    private func receivingContainers(of nodes: [UUID]) -> [(id: UUID, new: Set<UUID>)] {
        let index = store.index, tree = store.tree
        var new: [UUID: Set<UUID>] = [:], order: [UUID] = []
        func receive(_ id: UUID, _ nodes: [UUID]) {
            guard let entry = index[id], case .screen = entry.host, !entry.isLockedWithAncestors, !entry.isHiddenWithAncestors,
                  let container = index.node(id, in: tree), container.isContainer, container.resolvedLayout == .free,
                  entry.path.isEmpty || container.sketch != nil else { return }
            if new[id] == nil { order.append(id) }
            new[id, default: []].formUnion(nodes)
        }
        for id in nodes {
            guard let entry = index[id], let node = index.node(id, in: tree) else { continue }
            if let parent = entry.parent { receive(parent, [id]) }
            if node.kind == .card { receive(id, node.children.map(\.id)) }
        }
        return order.enumerated()
            .sorted { (-(index[$0.element]?.depth ?? 0), $0.offset) < (-(index[$1.element]?.depth ?? 0), $1.offset) }
            .map { ($0.element, new[$0.element] ?? []) }
    }

    /// Where everything inside each of `containers` but a screen's root lies on its screen: each node's own origin there.
    /// The pass looks at containers inside out, so that what an inner one builds moves only what such a container holds,
    /// and an outer one measures how far its structures move from here (A1).
    private func startingPlaces(inside containers: [UUID]) -> [UUID: CGPoint] {
        let index = store.index, tree = store.tree
        var places: [UUID: CGPoint] = [:]
        func visit(_ node: LayerNode, toScreen: CGAffineTransform) {
            for child in node.children {
                let own = child.transformToParent.concatenating(toScreen)
                places[child.id] = CGPoint.zero.applying(own)
                visit(child, toScreen: own)
            }
        }
        for id in containers {
            guard let entry = index[id], !entry.path.isEmpty, let node = index.node(id, in: tree) else { continue }
            visit(node, toScreen: entry.toHost)
        }
        return places
    }

    /// The containers this model built that are still exactly as it built them (F10): those may grow (call 2).
    private func structuresThatMayGrow() -> Set<UUID> {
        Set(builtStructures.compactMap { id, value in store.node(id) == value ? id : nil })
    }

    /// Puts `structure` on offer in place of any other, with where its members are now. Not when one of them is gone.
    private func offer(_ structure: StructureInference.Structure) {
        guard let entry = store.index[structure.parent], case .screen(let screen) = entry.host else { return }
        let places = places(of: structure.members)
        guard places.count == structure.members.count else { return }
        dismissStructureOffer()
        structureOffer = StructureOffer(id: UUID(), structure: structure, screen: screen)
        structureOfferPlaces = places
        startStructureOfferClock()
    }

    /// Where each of `ids` is that the design still has: see `OfferedPlace`.
    private func places(of ids: [UUID]) -> [UUID: OfferedPlace] {
        let index = store.index
        var places: [UUID: OfferedPlace] = [:]
        for id in ids {
            guard let placed = store.placed(id) else { continue }
            places[id] = OfferedPlace(frame: placed.frame, degrees: placed.degrees, placement: placed.placement,
                                      parent: index[id]?.parent)
        }
        return places
    }
}

private extension StructureInference.Structure.Kind {
    /// What Undo and Redo call an accepted offer.
    var stepName: String {
        switch self {
        case .row: String(localized: "Make Row")
        case .column, .cardColumn: String(localized: "Make Column")
        case .grid: String(localized: "Make Grid")
        }
    }
}

@_weakLinked import AppIntents
import CoreGraphics

/// Tells Apple Intelligence what is on the canvas, so that a request such as “make this
/// button blue” or “rename this screen” reaches the thing the person means. The canvas
/// draws everything in one zoomed layer, so it hands over the screens and the leaves on
/// them and on the open canvas itself, with where each one is in the view and whether it
/// is selected. A container is never handed over: Siri sees what is in it (My call 9).
extension AppModel {
    func onscreenEntities(_ context: AppEntityUIElementsContext) -> [AppEntityUIElement] {
        let visibleRects = context.requests.compactMap { request -> CGRect? in
            if case .visible(let rect) = request { return rect }
            return nil
        }
        return onscreenEntities(wantsSelected: context.requests.contains(.selected), visible: visibleRects)
    }

    /// What `onscreenEntities(_:)` answers for a request for what is selected, when `wantsSelected`, and for what lies
    /// in any of `visibleRects`, in view points. Each screen holds its leaves as subelements; a leaf's bounds are the
    /// box round its turned shape, read from the store's index. The system's context can't be made outside it, so
    /// tests ask this.
    func onscreenEntities(wantsSelected: Bool, visible visibleRects: [CGRect]) -> [AppEntityUIElement] {
        guard let snapshot = DesignActions.snapshot(of: self) else { return [] }
        let tree = snapshot.content, index = store.index

        func isWanted(_ viewFrame: CGRect, selected: Bool) -> Bool {
            (wantsSelected && selected) || visibleRects.contains { $0.intersects(viewFrame) }
        }

        /// A visible leaf on `host` as Siri sees it, where it is in the view. Nil when it isn't wanted.
        func element(_ leaf: LayerNode, on host: TreeIndex.Host, called hostName: String) -> AppEntityUIElement? {
            guard let entry = index[leaf.id], !entry.isHiddenWithAncestors,
                  let shape = index.canvasShape(of: leaf.id, in: tree) else { return nil }
            let frame = viewport.viewRect(for: shape.bounds)
            let selected = store.ref(of: leaf.id).map { selection == .element($0) } ?? false
            guard isWanted(frame, selected: selected) else { return nil }
            let entity = ElementEntity(design: snapshot.id, host: host, hostName: hostName, node: leaf,
                                       isLocked: entry.isLockedWithAncestors, isHidden: false)
            return AppEntityUIElement(entity, bounds: frame, state: .init(isSelected: selected))
        }

        var found: [AppEntityUIElement] = []
        for screen in tree.screens {
            let screenFrame = viewport.viewRect(for: screen.canvasFrame(on: tree.device(of: screen)))
            let children = screen.root.leaves.compactMap { element($0, on: .screen(screen.id), called: screen.name) }
            let selected = selection == .screen(screen.id)
            guard isWanted(screenFrame, selected: selected) || !children.isEmpty else { continue }
            let entity = ScreenEntity(design: snapshot.id, designName: snapshot.name, screen: screen, settings: tree.settings)
            found.append(AppEntityUIElement(entity, bounds: screenFrame, state: .init(isSelected: selected), subelements: children))
        }
        found += tree.canvasLeaves.compactMap { element($0, on: .canvas, called: "Canvas") }
        return found
    }

    /// The design as a whole, for requests about “this design”.
    var designEntityIdentifier: EntityIdentifier? {
        designID.map { EntityIdentifier(for: DesignEntity.self, identifier: $0) }
    }
}

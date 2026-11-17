@_weakLinked import AppIntents
import CoreGraphics

/// Tells Apple Intelligence what is on the canvas, so that a request such as “make this
/// button blue” or “rename this screen” reaches the thing the person means. The canvas
/// draws everything in one zoomed layer, so it hands over the screens and elements
/// itself, with where each one is in the view and whether it is selected.
extension AppModel {
    func onscreenEntities(_ context: AppEntityUIElementsContext) -> [AppEntityUIElement] {
        guard let snapshot = DesignActions.snapshot(of: self) else { return [] }
        let wantsSelected = context.requests.contains(.selected)
        let visibleRects = context.requests.compactMap { request -> CGRect? in
            if case .visible(let rect) = request { return rect }
            return nil
        }

        func isWanted(_ viewFrame: CGRect, selected: Bool) -> Bool {
            (wantsSelected && selected) || visibleRects.contains { $0.intersects(viewFrame) }
        }

        var found: [AppEntityUIElement] = []
        for screen in store.screens {
            let screenFrame = viewport.viewRect(for: screen.canvasFrame)
            var children: [AppEntityUIElement] = []
            for element in screen.elements where !element.isHidden {
                let ref = DesignStore.ElementRef(host: .screen(screen.id), element: element.id)
                let frame = viewport.viewRect(for: screen.canvasRect(for: element.frame))
                let selected = selection == .element(ref)
                guard isWanted(frame, selected: selected) else { continue }
                let entity = ElementEntity(design: snapshot.id, host: ref.host, hostName: screen.name, element: element)
                children.append(AppEntityUIElement(entity, bounds: frame, state: .init(isSelected: selected)))
            }
            let selected = selection == .screen(screen.id)
            guard isWanted(screenFrame, selected: selected) || !children.isEmpty else { continue }
            let entity = ScreenEntity(design: snapshot.id, designName: snapshot.name, screen: screen)
            found.append(AppEntityUIElement(entity, bounds: screenFrame, state: .init(isSelected: selected), subelements: children))
        }
        for floating in store.floating where !floating.element.isHidden {
            let ref = DesignStore.ElementRef(host: .canvas, element: floating.id)
            let frame = viewport.viewRect(for: floating.canvasFrame)
            let selected = selection == .element(ref)
            guard isWanted(frame, selected: selected) else { continue }
            let entity = ElementEntity(design: snapshot.id, host: .canvas, hostName: "Canvas", element: floating.element)
            found.append(AppEntityUIElement(entity, bounds: frame, state: .init(isSelected: selected)))
        }
        return found
    }

    /// The design as a whole, for requests about “this design”.
    var designEntityIdentifier: EntityIdentifier? {
        designID.map { EntityIdentifier(for: DesignEntity.self, identifier: $0) }
    }
}

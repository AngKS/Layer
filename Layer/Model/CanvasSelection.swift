import Foundation

/// What is selected on the canvas: one thing, or several at once. A drawing is an element
/// like any other.
enum CanvasSelection: Hashable, Sendable {
    case element(DesignStore.ElementRef)
    case screen(TreeScreen.ID)
    /// Two or more elements and screens, each a single thing. Made with `init(_:)`.
    case several(Set<CanvasSelection>)
}

extension CanvasSelection {
    /// The selection of some things: nil when there are none, and the thing itself when
    /// there is one. An element whose own screen is among them is left out: it is on that
    /// screen and goes wherever the screen goes.
    init?(_ things: some Sequence<CanvasSelection>) {
        var single = Set(things.flatMap(\.things))
        let screens = Set(single.compactMap { thing -> TreeScreen.ID? in
            if case .screen(let id) = thing { id } else { nil }
        })
        if !screens.isEmpty {
            single = single.filter { thing in
                guard case .element(let ref) = thing, case .screen(let id) = ref.host else { return true }
                return !screens.contains(id)
            }
        }
        switch single.count {
        case 0: return nil
        case 1: self = single[single.startIndex]
        default: self = .several(single)
        }
    }

    /// The single things selected: one, or each of several.
    var things: Set<CanvasSelection> {
        if case .several(let things) = self { things } else { [self] }
    }

    var isSeveral: Bool {
        if case .several = self { true } else { false }
    }

    /// Whether a single thing is selected, alone or among others.
    func contains(_ thing: CanvasSelection) -> Bool {
        self == thing || things.contains(thing)
    }

    /// The selection with a thing added to it, or taken out if it is already there.
    func toggling(_ thing: CanvasSelection) -> CanvasSelection? {
        CanvasSelection(things.symmetricDifference(thing.things))
    }

    /// The selection without a thing.
    func removing(_ thing: CanvasSelection) -> CanvasSelection? {
        CanvasSelection(things.subtracting(thing.things))
    }
}

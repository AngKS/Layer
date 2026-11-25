import CoreGraphics
import Foundation

/// What `DesignStore.move(_:toHostFrame:size:)` did with a frame.
enum MoveOutcome: Equatable {
    /// Put where it was asked, in the free parent that holds it.
    case placed
    /// Put in a row, column or grid on its own host, at the slot the frame's centre falls in: its own, reordered, or
    /// another.
    case reordered
    /// Taken out of what laid it out, onto the top of its own host at the frame, fixed on both axes.
    case takenOut
    /// A laid-out thing's size, and nothing else, changed.
    case resized
    /// Nothing to change.
    case unchanged
    /// Under a screen root that lays it out, with nowhere it could be taken out to: nothing changes (F15).
    case refused
}

/// The drag rule for a frame given in numbers rather than by a finger (plan 6, F13): what Siri's Move Element and voice's
/// `moveElement` with `takeOut` do, written once.
extension DesignStore {
    /// The drag rule for a frame given in host points (screen points; on the canvas, canvas points ÷ the top-level
    /// node's scale), as one step (F13).
    ///
    /// - A free parent: `place`.
    /// - A laid-out child, `sizeOnly`: `resizeLaidOut`, which fixes each axis whose size changed.
    /// - A laid-out child with a position: `TreeDrop.target` at the frame's centre, kept to its own host. `.insert` on
    ///   that host moves it there (`.reordered`), with the frame's size if it changed. Anything else takes it out onto
    ///   its host's root at the frame, `.fixed` on both axes (`.takenOut`), as `place` does. Under a screen root that
    ///   lays it out, which can't take it freely: `.refused`, and nothing changes (F15).
    ///
    /// Nothing is written, and the answer is `.unchanged`, for a screen's root, an id the design doesn't have, a frame
    /// that isn't finite or has a side below zero, and a frame that changes nothing. Siri's Move and voice's `takeOut`
    /// call it.
    @discardableResult
    func move(_ id: UUID, toHostFrame frame: CGRect, size sizeOnly: Bool = false) -> MoveOutcome {
        let memo = index, tree = tree
        guard let entry = memo[id], !entry.path.isEmpty, let posed = memo.posed(id, in: tree),
              let placement = memo.placement(of: id, in: tree),
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite), frame.width >= 0, frame.height >= 0
        else { return .unchanged }
        let version = contentVersion
        func ifChanged(_ outcome: MoveOutcome) -> MoveOutcome { contentVersion != version ? outcome : .unchanged }

        // Under a free container, a free root, or at the canvas's top level.
        guard let holder = posed.parent, holder.resolvedLayout != .free else {
            place(id, at: frame)
            return ifChanged(.placed)
        }
        let start = posed.node
        if sizeOnly {
            resizeLaidOut(id, to: frame.size, from: start)
            return ifChanged(.resized)
        }

        // Where a drag would let it go, its centre and the finger both at the frame's centre on the canvas.
        let centre = placement.canvasPoint(for: CGPoint(x: frame.midX, y: frame.midY))
        let target = TreeDrop.target(for: id, at: centre, centre: centre, in: tree, index: memo)
        if case .insert(let into, let slot, _) = target, host(of: into) == entry.host {
            let isResized = abs(frame.width - start.frame.width) > 0.5 || abs(frame.height - start.frame.height) > 0.5
            var outcome = MoveOutcome.unchanged
            asOneStep {
                let isWhereItIs = parent(of: id) == into && entry.siblingIndex == slot
                if !isWhereItIs {
                    guard move(id, to: into, at: slot) else {
                        outcome = .refused
                        return
                    }
                    outcome = .reordered
                }
                guard isResized else { return }
                let before = contentVersion
                resizeLaidOut(id, to: frame.size, from: start)
                if outcome == .unchanged, contentVersion != before { outcome = .resized }
            }
            return outcome
        }

        // Out onto the top of its own host, at the frame: a screen root that lays things out has no free top to take it.
        if case .screen(let screenID) = entry.host,
           (tree.screens.first(where: { $0.id == screenID })?.root.resolvedLayout ?? .free) != .free {
            return .refused
        }
        guard let placing = placing(id, at: frame) else { return .unchanged }
        changeTree(writing: 1) { Self.write([placing], to: &$0) }
        return placing.takenOutTo != nil ? .takenOut : .resized
    }
}

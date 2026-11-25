import CoreGraphics
import Foundation

/// Voice's canvas tools: showing a screen or a thing, panning and zooming the view. They change the view, never the
/// design.
extension VoiceToolbox {
    // MARK: The canvas

    func show(target: String) -> String {
        guard let model else { return gone }
        let word = target.lowercased().trimmingCharacters(in: .whitespaces)
        if ["all", "everything", "fit", "the whole canvas"].contains(word) {
            model.ink?.zoomToFit()
            return done("Showing everything.")
        }
        // "Down a bit" has nothing to show: it is the view that moves.
        if Self.pan(named: target) != nil { return pan(direction: target) }
        // A screen's handle is answered as a screen's: one that names nothing is reported
        // as the screen it would be, and a screen a change isn't for is refused.
        if VoiceHandles.tidied(target)?.hasPrefix("S") == true {
            switch find(screen: target) {
            case .success(let screen):
                DesignActions.reveal(.screen(screen.id), in: model, selecting: scope == nil)
                return done("Showing “\(screen.name)”.")
            case .failure(let refusal):
                return failed(refusal.line)
            }
        }
        switch find(element: target) {
        case .success(let found):
            // Asked for, the view moves even in a change for one screen; the screen stays
            // selected.
            DesignActions.reveal(.element(found.ref), in: model, selecting: scope == nil)
            return done("Showing \(Self.describe(found.node)).")
        case .failure(let refusal):
            return failed(refusal.line)
        }
    }

    /// Moves the view up, down, left or right by most of what is in it, or by half of
    /// that for "a bit".
    func pan(direction: String) -> String {
        guard let model else { return gone }
        guard let pan = Self.pan(named: direction) else {
            return failed("I can move the view up, down, left or right, not “\(direction)”.")
        }
        if model.canvasSize != .zero {
            let visible = model.viewport.visibleRect(in: model.canvasSize)
            model.ink?.glide(toCenter: Self.centre(of: visible, panned: pan.shift), scale: model.viewport.scale)
        }
        return done("Moved the view \(pan.name).")
    }

    func zoom(to level: String) -> String {
        guard let model else { return gone }
        let word = level.lowercased().trimmingCharacters(in: .whitespaces)
        switch word {
        case "in", "closer":
            model.ink?.zoom(to: model.zoomScale * 1.25)
            return done("Zoomed in.")
        case "out", "further":
            model.ink?.zoom(to: model.zoomScale / 1.25)
            return done("Zoomed out.")
        case "fit", "all", "everything":
            model.ink?.zoomToFit()
            return done("Showing everything.")
        default:
            let digits = word.hasSuffix("%") ? String(word.dropLast()) : word
            guard let percent = Double(digits.trimmingCharacters(in: .whitespaces)), percent > 0 else {
                return failed("I can zoom in, out, to fit, or to a percentage such as 150.")
            }
            let scale = min(max(CGFloat(percent) / 100, Viewport.zoomRange.lowerBound), Viewport.zoomRange.upperBound)
            model.ink?.zoom(to: scale)
            return done("Zoomed to \(Int((scale * 100).rounded()))%.")
        }
    }

    /// The way to pan that some words ask for, and how far, as a share of what is in
    /// view: "down" is most of a view, "down a bit" half of that. Nil for anything that
    /// isn't only a direction: a handle, or a name with "left" in it.
    static func pan(named target: String) -> (name: String, shift: CGVector)? {
        let said = target.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let little: Set<String> = ["bit", "little", "slightly", "touch"]
        let empty: Set<String> = ["pan", "scroll", "move", "go", "the", "view", "canvas", "a", "to", "it"]
        let ways = said.filter { !little.contains($0) && !empty.contains($0) }
        guard ways.count == 1 else { return nil }
        let isLittle = said.contains(where: little.contains)
        let share: CGFloat = isLittle ? 0.3 : 0.6
        let way: String
        let shift: CGVector
        switch ways[0] {
        case "up", "upward", "upwards": (way, shift) = ("up", CGVector(dx: 0, dy: -share))
        case "down", "downward", "downwards": (way, shift) = ("down", CGVector(dx: 0, dy: share))
        case "left": (way, shift) = ("left", CGVector(dx: -share, dy: 0))
        case "right": (way, shift) = ("right", CGVector(dx: share, dy: 0))
        default: return nil
        }
        return (isLittle ? "\(way) a little" : way, shift)
    }

    /// Where the middle of the view goes when it is panned by a share of itself.
    static func centre(of visible: CGRect, panned shift: CGVector) -> CGPoint {
        CGPoint(x: visible.midX + shift.dx * visible.width, y: visible.midY + shift.dy * visible.height)
    }
}

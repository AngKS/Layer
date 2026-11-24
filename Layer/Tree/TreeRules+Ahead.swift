import CoreGraphics
import Foundation

extension TreeRules {
    /// A screen's root laid out exactly as `apply` would lay it out on the screen whose device is `deviceID` among
    /// `settings`' devices, for use off the main actor. `previous` (that screen's root before) lets unchanged
    /// containers be reused. Pure.
    ///
    /// The root is kept to its device and tidied as the rules keep a screen, so that committed with
    /// `DesignStore.commitGenerated` or `addLaidOutScreens` there is nothing left for them to do (plan 3, call 6).
    static func laidOut(_ root: LayerNode, deviceID: String?, settings: CanvasSettings, previous: LayerNode?,
                        measure: TextMeasure = .shared) -> LayerNode {
        laidOutReporting(root, deviceID: deviceID, settings: settings, previous: previous, measure: measure).root
    }

    /// `laidOut(_:deviceID:settings:previous:measure:)`, with what the layout noticed and left alone (what a generated
    /// or imported screen is told it still has wrong: `UnfixedIssue`).
    static func laidOutReporting(_ root: LayerNode, deviceID: String?, settings: CanvasSettings, previous: LayerNode?,
                                 measure: TextMeasure = .shared) -> (root: LayerNode, diagnostics: [LayoutDiagnostic]) {
        #if DEBUG
        GenerationWork.laidOutAhead(root.id, onMainThread: Thread.isMainThread)
        #endif
        var content = TreeContent()
        content.settings = settings
        content.screens = [TreeScreen(name: "", origin: .zero, scale: 1, deviceID: deviceID, root: root)]
        var before: TreeContent?
        if let previous {
            var earlier = content
            earlier.screens[0].root = previous
            before = earlier
        }
        let diagnostics = apply(to: &content, after: before, measure: measure)
        return (content.screens[0].root, diagnostics)
    }
}

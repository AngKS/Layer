#if DEBUG
import CoreGraphics
import Foundation
import SwiftUI

/// Draws the reference demo's five sketches with the Magic Pen's own canvas, so the whole path
/// from ink to elements can be watched and screenshotted in the simulator.
///
/// Launch with `-LayerDemo all` (or a comma-separated subset of
/// `screen,button,title,image,body`). `-LayerDemoEnd` picks the closing state:
/// `select:<kind>`, `adjust:<kind>`, `layers` or `code`.
@MainActor
enum DemoScript {
    static func runIfRequested(on model: AppModel) async {
        let defaults = UserDefaults.standard
        guard let requested = defaults.string(forKey: "LayerDemo") else { return }
        let steps = requested == "all"
            ? ["screen", "button", "title", "image", "body"]
            : requested.split(separator: ",").map(String.init)

        await wait { model.ink != nil && model.canvasSize != .zero }
        for step in steps {
            guard let sketch = sketch(for: step, on: model) else { continue }
            model.ink?.appendSketch(sketch)
            await wait { !model.isBusy }
        }

        guard let ending = defaults.string(forKey: "LayerDemoEnd") else { return }
        try? await Task.sleep(for: .milliseconds(600))
        let parts = ending.split(separator: ":").map(String.init)
        switch parts.first {
        case "layers", "code":
            model.panelTab = parts[0] == "code" ? .code : .layers
            withAnimation(.smooth(duration: 0.35)) { model.isLayersOpen = true }
        case "select", "adjust":
            guard let screen = model.store.screens.first,
                  let kind = parts.dropFirst().first.flatMap(ElementKind.init(rawValue:)),
                  let element = screen.elements.first(where: { $0.kind == kind })
            else { return }
            model.tool = .select
            model.selection = .element(.init(host: .screen(screen.id), element: element.id))
            model.isAdjusting = parts[0] == "adjust"
        default:
            break
        }
    }

    private static func sketch(for step: String, on model: AppModel) -> [[CGPoint]]? {
        if step == "screen" {
            // In the middle of what the canvas is showing, between the top bar and the
            // controls and palette along the bottom.
            let visible = model.viewport.visibleRect(in: model.canvasSize)
            let rect = CGRect(x: visible.midX - 130, y: visible.minY + 124 / model.viewport.scale, width: 260, height: 560)
            return [SketchSamples.box(rect, radius: 26)]
        }
        guard let screen = model.store.screens.first else { return nil }
        func onScreen(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            screen.canvasRect(for: CGRect(x: x, y: y, width: width, height: height))
        }
        switch step {
        case "button":
            let rect = onScreen(28, 738, 337, 60)
            return [SketchSamples.box(rect, radius: rect.height / 2)]
        case "title":
            return [SketchSamples.wave(onScreen(150, 112, 96, 40), humps: 3)]
        case "image":
            let rect = onScreen(34, 186, 326, 364)
            return [SketchSamples.box(rect, radius: rect.width * 0.14)] + SketchSamples.cross(rect)
        case "body":
            return [SketchSamples.wave(onScreen(52, 588, 290, 28), humps: 8)]
        default:
            return nil
        }
    }

    private static func wait(for limit: Duration = .seconds(30), until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + limit
        // Give a change time to register before checking that it has settled.
        try? await Task.sleep(for: .milliseconds(300))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif

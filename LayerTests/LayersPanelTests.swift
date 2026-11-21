import SwiftUI
import Testing
import UIKit
@testable import Layer

/// The layers panel open beside the canvas while something is dragged: its rows aren't built
/// again, nor is the Code tab's SwiftUI generated and coloured, on every frame of the drag or
/// every move of the pencil's hover, only once what they show has changed (audit M9).
@MainActor
@Suite("The layers panel during a drag", .serialized)
struct LayersPanelWorkTests {
    /// A phone screen of 40 lines of text, and 20 drawings on the open canvas.
    private func board() -> (model: AppModel, lines: [DesignStore.ElementRef]) {
        let model = AppModel(document: LayerDocument())
        let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 1)).id
        let lines = model.store.setElements((0..<40).map { index in
            DesignElement(kind: .text, frame: CGRect(x: 20, y: 60 + CGFloat(index) * 19, width: 200, height: 16), text: "Line \(index)", tint: Theme.accent)
        }, on: screen, replacing: true)
        for index in 0..<20 {
            var drawing = DesignStore.newElement(.drawing)
            drawing.frame = CGRect(x: 700, y: 100 + CGFloat(index) * 60, width: 100, height: 40)
            model.store.addFloating(drawing, scale: 1)
        }
        return (model, lines)
    }

    /// Lets SwiftUI catch up with what has changed.
    private func settle(_ view: UIView, for duration: Duration = .milliseconds(100)) async throws {
        try await Task.sleep(for: duration)
        view.layoutIfNeeded()
    }

    /// 60 frames of a drag, one every few milliseconds, as touches come in.
    private func drag(_ ref: DesignStore.ElementRef, in model: AppModel, view: UIView) async throws {
        for step in 1...60 {
            model.store.update(ref) { $0.frame.origin.x = 20 + CGFloat(step) }
            view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(4))
        }
        view.layoutIfNeeded()
    }

    /// Nudges a layer until a change to the design builds no row. For a while after a window
    /// first shows, as the app finishes launching, SwiftUI builds every row on every update
    /// whatever it is given; a drag in use comes long after.
    private func waitForRowsToSettle(nudging ref: DesignStore.ElementRef, in model: AppModel, view: UIView) async throws -> Bool {
        for step in 0..<300 {
            let before = LayersPanelWork.rows
            model.store.update(ref) { $0.frame.origin.y += step.isMultiple(of: 2) ? 1 : -1 }
            view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            if LayersPanelWork.rows == before { return true }
        }
        return false
    }

    @Test func aDragOrAHoverBuildsOnlyTheRowsThatChangeAndCodeOnceItSettles() async throws {
        let (model, lines) = board()
        LayersPanelWork.reset()
        let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
        let host = UIHostingController(rootView: LayersPanel(isSheet: true).environment(model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // Every row is built as the panel first shows.
        for _ in 0..<20 where LayersPanelWork.rows == 0 { try await settle(host.view) }
        #expect(LayersPanelWork.rows >= 62, "the panel shows a row for each layer, and each screen and the canvas")
        #expect(try await waitForRowsToSettle(nudging: lines[30], in: model, view: host.view), "a change to the design went on building rows it didn't change")

        // The Layers tab: one line dragged 60 frames, then the pencil hovering over ten in turn.
        LayersPanelWork.reset()
        try await drag(lines[5], in: model, view: host.view)
        try await settle(host.view)
        let rowsInADrag = LayersPanelWork.rows
        LayersPanelWork.reset()
        for line in lines.prefix(10) {
            model.hovered = .element(line)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(4))
        }
        try await settle(host.view)
        let rowsInTenHovers = LayersPanelWork.rows

        // The Code tab: its code is made as it opens, not again during the drag, and once
        // more after the drag has settled.
        model.panelTab = .code
        try await settle(host.view, for: .milliseconds(500))
        #expect(LayersPanelWork.codes >= 1, "the code shows as the tab opens")
        LayersPanelWork.reset()
        try await drag(lines[6], in: model, view: host.view)
        let codeInADrag = LayersPanelWork.codes
        try await settle(host.view, for: .milliseconds(600))
        let codeAfterIt = LayersPanelWork.codes

        // None, where before every row was built on every frame: 2,460 for this drag. Only
        // the two rows whose tint changes for each move of the hover: 600 before.
        #expect(rowsInADrag == 0, "rows built during a 60-frame drag: \(rowsInADrag)")
        #expect(rowsInTenHovers > 0 && rowsInTenHovers <= 20, "rows built for ten hover changes: \(rowsInTenHovers)")
        // 60 then, one for each frame.
        #expect(codeInADrag == 0, "code generated during a 60-frame drag: \(codeInADrag)")
        #expect(codeAfterIt == 1, "code generated once the drag settled: \(codeAfterIt)")
    }
}

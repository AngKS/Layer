import SwiftUI
import Testing
import UIKit
@testable import Layer

extension HostedWindowSuites {
    /// The layers panel open beside the canvas while something is dragged: its rows aren't built
    /// again, nor is the Code tab's SwiftUI generated and coloured, on every frame of the drag or
    /// every move of the pencil's hover, only once what they show has changed (audit M9).
    @MainActor
    @Suite("The layers panel during a drag", .serialized)
    struct LayersPanelWorkTests {
        /// A phone screen of 20 lines of text, and 8 drawings on the open canvas: 30 rows with
        /// the two headings. Kept small, since the panel is laid out again and again, and the
        /// main thread it takes is the other suites' too.
        private func board() -> (model: AppModel, lines: [DesignStore.ElementRef]) {
            let model = AppModel(document: LayerDocument())
            let screen = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 1)).id
            let lines = model.store.setElements((0..<20).map { index in
                DesignElement(kind: .text, frame: CGRect(x: 20, y: 60 + CGFloat(index) * 19, width: 200, height: 16), text: "Line \(index)", tint: Theme.accent)
            }, on: screen)
            for index in 0..<8 {
                var drawing = DesignStore.newElement(.drawing)
                drawing.frame = CGRect(x: 700, y: 100 + CGFloat(index) * 60, width: 100, height: 40)
                model.store.addFloating(drawing, scale: 1)
            }
            return (model, lines)
        }

        /// Every id on the board, which is what its panel counts its rows and code under (F9, clause (k)):
        /// the design's own, which no other suite's panel shares.
        private func ids(of model: AppModel) -> [UUID] {
            func walk(_ node: LayerNode) -> [UUID] { [node.id] + node.children.flatMap(walk) }
            let tree = model.store.tree
            return tree.screens.flatMap { [$0.id] + walk($0.root) } + tree.canvas.flatMap(walk)
        }

        /// The rows built for the board's layers so far, summed over its own ids.
        private func rows(in model: AppModel) -> Int {
            ids(of: model).reduce(0) { $0 + LayersPanelWork.rows(of: $1) }
        }

        /// The code made for the board's screens so far.
        private func codes(in model: AppModel) -> Int {
            model.store.tree.screens.reduce(0) { $0 + LayersPanelWork.codes(for: $1.id) }
        }

        /// Waits up to three seconds for `condition`, looking every 50 ms.
        private func poll(_ view: UIView, until condition: () -> Bool) async throws -> Bool {
            for _ in 0..<60 {
                if condition() { return true }
                try await settle(view, for: .milliseconds(50))
            }
            return condition()
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

        /// Nudges a layer, now and then, until a change to the design builds no row. For a while
        /// after a window first shows, as the app finishes launching, or while another suite's
        /// window comes and goes, SwiftUI builds every row on every update whatever it is given;
        /// a drag in use comes long after. Gently: each nudge then builds every row.
        private func waitForRowsToSettle(nudging ref: DesignStore.ElementRef, in model: AppModel, view: UIView) async throws -> Bool {
            for step in 0..<40 {
                let before = rows(in: model)
                model.store.update(ref) { $0.frame.origin.y += step.isMultiple(of: 2) ? 1 : -1 }
                try await Task.sleep(for: .milliseconds(50))
                if rows(in: model) == before { return true }
            }
            return false
        }

        @Test func aDragOrAHoverBuildsOnlyTheRowsThatChangeAndCodeOnceItSettles() async throws {
            let (model, lines) = board()
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
            let host = UIHostingController(rootView: LayersPanel(isSheet: true).environment(model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            // Every row is built as the panel first shows.
            for _ in 0..<20 where rows(in: model) == 0 { try await settle(host.view) }
            #expect(rows(in: model) >= 30, "the panel shows a row for each layer, and each screen and the canvas")

            // The Layers tab: one line dragged 60 frames, then the pencil hovering over ten in
            // turn. Each is measured again, up to three times, while something outside the panel
            // has SwiftUI building every row whatever it is given (see `waitForRowsToSettle`).
            // The panel as it was built every row on every frame each time, so it can't pass by
            // a retry.
            var rowsInADrag = Int.max
            for _ in 0..<3 where rowsInADrag > 0 {
                _ = try await waitForRowsToSettle(nudging: lines[15], in: model, view: host.view)
                let built = rows(in: model)
                try await drag(lines[5], in: model, view: host.view)
                try await settle(host.view)
                rowsInADrag = rows(in: model) - built
            }
            var rowsInTenHovers = Int.max
            for _ in 0..<3 where rowsInTenHovers > 20 {
                model.hovered = nil
                _ = try await waitForRowsToSettle(nudging: lines[15], in: model, view: host.view)
                let built = rows(in: model)
                for line in lines.prefix(10) {
                    model.hovered = .element(line)
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(4))
                }
                try await settle(host.view)
                rowsInTenHovers = rows(in: model) - built
            }

            // The Code tab: its code is made as it opens, not again during the drag, and once
            // more after the drag has settled.
            model.panelTab = .code
            let shown = try await poll(host.view) { codes(in: model) >= 1 }
            #expect(shown, "the code shows as the tab opens")
            let made = codes(in: model)
            try await drag(lines[6], in: model, view: host.view)
            let codeInADrag = codes(in: model) - made
            // Once it has settled: the first time it shows, then a moment more for any second.
            _ = try await poll(host.view) { codes(in: model) - made >= 1 }
            try await settle(host.view, for: .milliseconds(300))
            let codeAfterIt = codes(in: model) - made

            // None, where before every row was built on every frame (2,460 for this drag in a
            // panel of 62). Only the two rows whose tint changes for each move of the hover (600
            // before, in that panel).
            #expect(rowsInADrag == 0, "rows built during a 60-frame drag: \(rowsInADrag)")
            #expect(rowsInTenHovers > 0 && rowsInTenHovers <= 20, "rows built for ten hover changes: \(rowsInTenHovers)")
            // 60 then, one for each frame.
            #expect(codeInADrag == 0, "code generated during a 60-frame drag: \(codeInADrag)")
            #expect(codeAfterIt == 1, "code generated once the drag settled: \(codeAfterIt)")
        }

        /// A member of an open group dragged for 60 frames builds no row: the rows are given
        /// what they show, and a group's frame, which follows its member's, is not among it
        /// (Review Focus 6).
        @Test func aDragOfAGroupedThingBuildsNoRows() async throws {
            let (model, lines) = board()
            var item = DesignStore.newElement(.group)
            item.name = "Group"
            let made = item
            let g = DesignStore.ElementRef(host: lines[0].host, element: made.id)
            model.store.apply { content in
                content.add(made, to: lines[0].host.parent)
                for line in lines[2...4] { content.update(line.element) { $0.group = made.id } }
            }
            model.selection = .element(lines[3])
            #expect(model.enteredGroups.contains(g.element), "the group is open while a member is selected")
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
            let host = UIHostingController(rootView: LayersPanel(isSheet: true).environment(model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            for _ in 0..<20 where rows(in: model) == 0 { try await settle(host.view) }
            #expect(rows(in: model) >= 30)

            var rowsInADrag = Int.max
            for _ in 0..<3 where rowsInADrag > 0 {
                _ = try await waitForRowsToSettle(nudging: lines[15], in: model, view: host.view)
                let built = rows(in: model)
                try await drag(lines[3], in: model, view: host.view)
                try await settle(host.view)
                rowsInADrag = rows(in: model) - built
            }
            #expect(rowsInADrag == 0, "rows built during a 60-frame drag of a grouped thing: \(rowsInADrag)")
        }

        /// The code's view is named as the design's files name it, so a screen named like an
        /// earlier one declares "Login2". Renaming the earlier one frees the name: the code
        /// shown is made again for it, though the screen shown hasn't changed (merge with the
        /// screens' unique view names, G2).
        @Test func theCodeFollowsTheNameItsViewIsGivenAmongTheScreens() async throws {
            let model = AppModel(document: LayerDocument())
            let first = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 100, y: 100), scale: 1)).id
            let second = model.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 600, y: 100), scale: 1)).id
            model.store.updateScreen(first) { $0.name = "Login" }
            model.store.updateScreen(second) { $0.name = "Login" }
            let window = try await testWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 900))
            let host = UIHostingController(rootView: CodePane(screenID: .constant(second)).environment(model))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            _ = try await poll(host.view) { LayersPanelWork.codes(for: second) > 0 }
            #expect(LayersPanelWork.lastCode(for: second).contains("struct Login2: View"))

            model.store.updateScreen(first) { $0.name = "Home" }
            _ = try await poll(host.view) { LayersPanelWork.lastCode(for: second).contains("struct Login: View") }
            #expect(LayersPanelWork.lastCode(for: second).contains("struct Login: View"), "the code still declares the name it had")
        }
    }
}

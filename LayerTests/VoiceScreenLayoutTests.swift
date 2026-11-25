import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Spoken screen layout and device")
@MainActor
struct VoiceScreenLayoutTests {
    private struct Bench {
        var app: AppModel
        var screen: TreeScreen.ID
        var handles: VoiceHandles
        var box: VoiceToolbox
    }

    private func bench() -> Bench {
        let (app, screen) = VoiceFixture.undoableLogin()
        let handles = VoiceHandles()
        _ = CanvasPicture.capture(from: app, handles: handles)
        return Bench(app: app, screen: screen, handles: handles, box: VoiceToolbox(model: app, handles: handles))
    }

    @Test func deviceWordsNameDevices() {
        func id(_ words: String, _ usual: DeviceFrame = .iPhone) -> String? { VoiceToolbox.device(named: words, preferring: usual)?.id }
        #expect(id("iPhone") == "iphone")
        #expect(id("phone") == "iphone")
        #expect(id("iPhone Pro Max") == "iphone-pro-max")
        #expect(id("iPhone SE") == "iphone-se")
        #expect(id("iPad") == "ipad")
        #expect(id("an iPad screen") == "ipad")
        #expect(id("tablet") == "ipad")
        #expect(id("iPad mini") == "ipad-mini")
        #expect(id("iPad Pro") == "ipad-pro-13")
        #expect(id("MacBook") == "macbook-air")
        #expect(id("MacBook Pro") == "macbook-pro-16")
        #expect(id("iMac") == "imac")
        #expect(id("desktop") == "macbook-air")
        #expect(id("laptop") == "macbook-air")
        #expect(id("web") == "macbook-air")
        #expect(id("webpage") == "macbook-air")
        #expect(id("a web page") == "macbook-air")
        #expect(id("website") == "macbook-air")
        #expect(id("watch") == nil)
        // A family's word keeps the design's own device of that family.
        let mini = DeviceFrame.all.first { $0.id == "ipad-mini" }!
        #expect(id("iPad", mini) == "ipad-mini")
        #expect(id("phone", mini) == "iphone")
    }

    @Test func thePillSaysWhatTheNewToolsAreDoing() {
        #expect(VoiceTools.step(for: "tidyScreen") == "Tidying…")
        #expect(VoiceTools.step(for: "changeScreenDevice") == "Changing the device…")
    }

    /// The structure pass in its tidy mode (plan 5's call 10, fallout p): the login's title, button and image become one
    /// column, the rhythm's 32 apart from the median gap of 167, kept where the title is.
    @Test func tidyingLaysTheScreenOutAsOneUndoStep() throws {
        let bench = bench()
        let undo = try #require(bench.app.store.undoManager)
        let before = bench.app.store.content
        let line = bench.box.tidyScreen(screen: "S1")
        #expect(line == "Tidied the layout of S1.")
        let root = try #require(bench.app.store.treeScreen(bench.screen)?.root)
        #expect(root.children.count == 1)
        let column = try #require(root.children.first)
        #expect(column.children.map(\.kind) == [.title, .button, .image])
        let frames = column.children.compactMap { bench.app.store.placed($0.id)?.frame }
        #expect(frames.map(\.minY) == [75, 148, 230])
        undo.undo()
        #expect(bench.app.store.content == before)
    }

    /// Pointed at an element, "this screen" is the screen it is on, with or without its handle.
    @Test func thisScreenIsTheOnePointedAt() throws {
        let bench = bench()
        bench.app.store.addFreeScreen([], name: "Screen 2", origin: CGPoint(x: 9000, y: 9000), scale: 0.6)
        let button = try #require(bench.app.store.screenLeaves(bench.screen).first { $0.kind == .button })
        bench.app.selection = .element(.init(host: .screen(bench.screen), node: button.id))
        #expect(bench.box.tidyScreen(screen: nil) == "Tidied the layout of S1.")
        #expect(bench.box.changeScreenDevice(screen: "E2", device: "iPad").hasPrefix("Made S1 an iPad screen"))
        #expect(bench.app.store.treeScreen(bench.screen)?.deviceID == "ipad")
        #expect(bench.box.tidyScreen(screen: "E99") == "There is no E99.")
    }

    /// Each thing follows where it was put (plan 5's call 9, fallout p): the title and the button span the column, so
    /// they scale with the screen's width, and the image keeps its leading inset.
    @Test func changingTheDeviceReflowsTheScreen() throws {
        let bench = bench()
        let store = bench.app.store
        func frames() -> [CGRect] { store.screenLeaves(bench.screen).compactMap { store.ownFrame($0.id) } }
        let before = frames()
        let line = bench.box.changeScreenDevice(screen: "S1", device: "iPad")
        #expect(line == "Made S1 an iPad screen (820 × 1180).")
        let screen = try #require(store.treeScreen(bench.screen))
        #expect(screen.deviceID == "ipad")
        #expect(store.screenLeaves(bench.screen).map(\.kind) == [.title, .button, .image])
        #expect(frames() == [CGRect(x: 42, y: 75, width: 737, height: 41),
                             CGRect(x: 42, y: 420, width: 737, height: 50),
                             CGRect(x: 20, y: 500, width: 200, height: 200)])
        // Back to an iPhone is no device at all, as the Siri action keeps it, and everything is where it was.
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "iPhone").hasPrefix("Made S1 an iPhone screen"))
        #expect(store.treeScreen(bench.screen)?.deviceID == nil)
        #expect(frames() == before)
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "watch").hasPrefix("I can make it"))
    }

    /// A button stood on end keeps its angle and its size on an iPad, and stays on the screen.
    @Test func aTurnedElementKeepsItsAngleAndSizeOnANewDevice() throws {
        let bench = bench()
        let store = bench.app.store
        let button = try #require(store.screenLeaves(bench.screen).first { $0.kind == .button })
        let size = try #require(store.ownFrame(button.id)).size
        store.setCanvasAngles([button.id: 90])
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "iPad").hasPrefix("Made S1 an iPad screen"))
        let after = try #require(store.index.ownPose(of: button.id, in: store.tree))
        #expect(after.degrees == 90)
        #expect(after.frame.size == size)
        let device = try #require(store.device(of: bench.screen))
        #expect(CGRect(origin: .zero, size: device.size).contains(TurnedRect(rect: after.frame, degrees: after.degrees).bounds))
    }

    @Test func aNewScreenIsOnTheDeviceAskedFor() async throws {
        for (said, expected) in [("iPad", "ipad"), ("webpage", "macbook-air"), (nil, nil) as (String?, String?)] {
            let bench = bench()
            let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
            bench.app.screenStream = { _ in stream }
            let making = Task { try await bench.box.createScreen(name: "Shop", description: "an Apple product page", device: said) }
            #expect(await eventually { bench.app.isGenerating })
            let made = try #require(bench.app.store.tree.screens.last)
            #expect(made.id != bench.screen)
            #expect(made.deviceID == expected)
            feed.finish()
            _ = try await making.value
        }
    }
}

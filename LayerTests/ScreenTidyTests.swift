import CoreGraphics
import Foundation
import Testing
@testable import Layer

@Suite("Tidying a screen's layout")
struct ScreenTidyTests {
    private func element(_ kind: ElementKind, _ frame: CGRect, text: String = "") -> DesignElement {
        var element = DesignStore.newElement(kind)
        element.frame = frame
        if !text.isEmpty { element.text = text }
        return element
    }

    /// A rough phone screen: a title, its body, two fields, a checkbox beside its label,
    /// and a button near the bottom, all a little off.
    private func messy() -> [DesignElement] {
        [
            element(.title, CGRect(x: 50, y: 100, width: 228, height: 40), text: "Sign up"),
            element(.body, CGRect(x: 30, y: 170, width: 300, height: 44)),
            element(.textField, CGRect(x: 10, y: 260, width: 250, height: 48), text: "Email"),
            element(.textField, CGRect(x: 35, y: 330, width: 333, height: 48), text: "Password"),
            element(.checkbox, CGRect(x: 30, y: 410, width: 24, height: 24)),
            element(.text, CGRect(x: 70, y: 408, width: 200, height: 24), text: "I agree"),
            element(.button, CGRect(x: 40, y: 770, width: 300, height: 50), text: "Create account"),
        ]
    }

    private func expectNoOverlaps(_ frames: [CGRect], sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, one) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) {
                #expect(!one.intersects(other), "\(one) overlaps \(other)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func keepsTheOrderAndTheRows() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        #expect(frames.count == elements.count)
        let tidied = elements.map { frames[$0.id]! }
        // Top to bottom as before, the checkbox and its label still side by side.
        let column = [0, 1, 2, 3, 4, 6].map { tidied[$0].minY }
        #expect(column == column.sorted())
        #expect(abs(tidied[4].midY - tidied[5].midY) < 1)
        #expect(tidied[4].maxX < tidied[5].minX)
        expectNoOverlaps(tidied)
    }

    @Test func everythingIsOnOneMarginAndOnTheRhythm() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        // Full width for the title, body, fields and button: 20 points in from each side.
        for index in [0, 1, 2, 3, 6] {
            #expect(tidied[index].minX == 20)
            #expect(tidied[index].width == 353)
        }
        // The checkbox keeps its size, at the margin; its label takes the rest of the row.
        #expect(tidied[4].size == CGSize(width: 24, height: 24))
        #expect(tidied[4].minX == 20)
        #expect(tidied[5].maxX == 373)
        // The first row is where the generator puts it; the body sits close under the title.
        #expect(tidied[0].minY == DeviceFrame.iPhone.safeTop + 16)
        #expect(tidied[1].minY - tidied[0].maxY == ScreenTidy.tight)
        #expect(tidied[3].minY - tidied[2].maxY == ScreenTidy.normal)
    }

    @Test func aButtonNearTheBottomStaysPinnedThere() throws {
        let elements = messy()
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let button = try #require(frames[elements[6].id])
        #expect(button.maxY == DeviceFrame.iPhone.size.height - ScreenTidy.bottomInset(on: .iPhone))
    }

    @Test func lockedHiddenAndDrawnThingsStayPut() throws {
        var locked = element(.image, CGRect(x: 20, y: 200, width: 353, height: 150))
        locked.isLocked = true
        var hidden = element(.body, CGRect(x: 5, y: 5, width: 100, height: 44))
        hidden.isHidden = true
        let shape = element(.shape, CGRect(x: 300, y: 600, width: 50, height: 50))
        let others = [
            element(.title, CGRect(x: 40, y: 90, width: 228, height: 40)),
            element(.textField, CGRect(x: 40, y: 380, width: 200, height: 48)),
            element(.textField, CGRect(x: 40, y: 450, width: 200, height: 48)),
        ]
        let frames = ScreenTidy.frames(for: [locked, hidden, shape] + others, on: .iPhone)
        #expect(frames[locked.id] == nil && frames[hidden.id] == nil && frames[shape.id] == nil)
        // The rest go round the locked image, in the order they were in.
        let tidied = others.map { frames[$0.id]! }
        for frame in tidied { #expect(!frame.intersects(locked.frame)) }
        #expect(tidied[0].maxY <= locked.frame.minY)
        #expect(tidied[1].minY >= locked.frame.maxY)
        #expect(tidied[1].minY < tidied[2].minY)
    }

    /// Too much for the usual spacing: the gaps close up before the button lets go of the bottom.
    @Test func itFitsOnTheScreen() throws {
        var elements = [element(.title, CGRect(x: 20, y: 75, width: 353, height: 40))]
        for index in 0..<10 {
            elements.append(element(.textField, CGRect(x: 20, y: 130 + CGFloat(index) * 52, width: 353, height: 50)))
        }
        let button = element(.button, CGRect(x: 20, y: 760, width: 353, height: 50))
        elements.append(button)
        let frames = ScreenTidy.frames(for: elements, on: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        expectNoOverlaps(tidied)
        for frame in tidied { #expect(frame.maxY <= DeviceFrame.iPhone.size.height) }
        #expect(frames[button.id]!.maxY == DeviceFrame.iPhone.size.height - ScreenTidy.bottomInset(on: .iPhone))
    }

    @Test func aRowOfSmallThingsGetsEqualSlots() throws {
        let icons = (0..<4).map { element(.symbol, CGRect(x: 40 + CGFloat($0) * 60, y: 300, width: 44, height: 44)) }
        let frames = ScreenTidy.frames(for: icons, on: .iPhone)
        let tidied = icons.map { frames[$0.id]! }
        let slot = 353.0 / 4
        for (index, frame) in tidied.enumerated() {
            #expect(abs(frame.midX - (20 + slot * (Double(index) + 0.5))) <= 1)
            #expect(frame.size == CGSize(width: 44, height: 44))
        }
    }

    @Test func aNewDeviceGetsALayoutOfItsOwn() throws {
        let elements = messy()
        guard let iPad = DeviceFrame.all.first(where: { $0.id == "ipad" }) else { throw CancellationError() }
        let frames = ScreenTidy.frames(for: elements, on: iPad, from: .iPhone)
        let tidied = elements.map { frames[$0.id]! }
        let bounds = CGRect(origin: .zero, size: iPad.size)
        for frame in tidied { #expect(bounds.contains(frame)) }
        let column = ScreenTidy.column(on: iPad)
        // Full-width things span the iPad's column, not a phone's width.
        for index in [1, 2, 3, 6] {
            #expect(tidied[index].minX == column.x)
            #expect(tidied[index].width == column.width)
        }
        #expect(tidied[6].maxY == iPad.size.height - ScreenTidy.bottomInset(on: iPad))
        expectNoOverlaps(tidied)
    }

    @Test func aMacKeepsAReadableColumn() throws {
        guard let mac = DeviceFrame.all.first(where: { $0.id == "imac" }) else { throw CancellationError() }
        let column = ScreenTidy.column(on: mac)
        #expect(column.width == ScreenTidy.widestColumn)
        #expect(column.x == (mac.size.width - column.width) / 2)
    }
}

@Suite("Spoken screen layout and device")
@MainActor
struct VoiceScreenLayoutTests {
    private struct Bench {
        var app: AppModel
        var screen: DesignScreen.ID
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

    @Test func tidyingLaysTheScreenOutAsOneUndoStep() throws {
        let bench = bench()
        let undo = try #require(bench.app.store.undoManager)
        let before = bench.app.store.content
        let line = bench.box.tidyScreen(screen: "S1")
        #expect(line == "Tidied the layout of S1.")
        let screen = try #require(bench.app.store.screen(bench.screen))
        // The button and the image move up under the title, on the margin.
        let frames = screen.elements.sorted { $0.frame.minY < $1.frame.minY }.map(\.frame)
        #expect(frames.allSatisfy { $0.minX == 20 && $0.width == 353 })
        #expect(frames[1].minY - frames[0].maxY == ScreenTidy.afterHeading)
        undo.undo()
        #expect(bench.app.store.content == before)
    }

    /// Pointed at an element, "this screen" is the screen it is on, with or without its handle.
    @Test func thisScreenIsTheOnePointedAt() throws {
        let bench = bench()
        _ = bench.app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 9000, y: 9000), scale: 0.6))
        let button = try #require(bench.app.store.screen(bench.screen)?.elements.first { $0.kind == .button })
        bench.app.selection = .element(.init(host: .screen(bench.screen), element: button.id))
        #expect(bench.box.tidyScreen(screen: nil) == "Tidied the layout of S1.")
        #expect(bench.box.changeScreenDevice(screen: "E2", device: "iPad").hasPrefix("Made S1 an iPad screen"))
        #expect(bench.app.store.screen(bench.screen)?.deviceID == "ipad")
        #expect(bench.box.tidyScreen(screen: "E99") == "There is no E99.")
    }

    @Test func changingTheDeviceReflowsTheScreen() throws {
        let bench = bench()
        let line = bench.box.changeScreenDevice(screen: "S1", device: "iPad")
        #expect(line == "Made S1 an iPad screen (820 × 1180).")
        let screen = try #require(bench.app.store.screen(bench.screen))
        #expect(screen.deviceID == "ipad")
        let bounds = CGRect(origin: .zero, size: screen.size)
        let column = ScreenTidy.column(on: screen.device)
        for element in screen.elements {
            #expect(bounds.contains(element.frame))
            #expect(element.frame.width == column.width)
        }
        // Back to an iPhone is no device at all, as the Siri action keeps it.
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "iPhone").hasPrefix("Made S1 an iPhone screen"))
        #expect(bench.app.store.screen(bench.screen)?.deviceID == nil)
        #expect(bench.box.changeScreenDevice(screen: "S1", device: "watch").hasPrefix("I can make it"))
    }

    @Test func aNewScreenIsOnTheDeviceAskedFor() async throws {
        for (said, expected) in [("iPad", "ipad"), ("webpage", "macbook-air"), (nil, nil) as (String?, String?)] {
            let bench = bench()
            let (stream, feed) = AsyncThrowingStream<ScreenGenerator.Update, any Error>.makeStream()
            bench.app.screenStream = { _, _, _ in stream }
            let making = Task { try await bench.box.createScreen(name: "Shop", description: "an Apple product page", device: said) }
            #expect(await eventually { bench.app.isGenerating })
            let made = try #require(bench.app.store.screens.last)
            #expect(made.id != bench.screen)
            #expect(made.deviceID == expected)
            feed.finish()
            _ = try await making.value
        }
    }
}

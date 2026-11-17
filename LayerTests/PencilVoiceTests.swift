import Foundation
import SwiftUI
import Testing
@testable import Layer

/// A runner whose getting ready takes as long as the test says, as the real agent's does
/// while it captures the canvas.
@MainActor
private final class SlowWarmingRunner: VoiceCommandRunner {
    var holdsWarmUp = true
    private(set) var commands: [String] = []

    func warmUp() async {
        while holdsWarmUp { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func run(_ command: String) async -> VoiceOutcome {
        commands.append(command)
        return VoiceOutcome(lines: ["Done"])
    }
}

/// The login design with a Pencil Pro's push-to-talk on it, driven by hand: the routes it
/// asks for, the runner it acts through and the time it reads are the test's.
@MainActor
private final class Bench {
    let app: AppModel
    let screen: DesignScreen.ID
    let runner = FakeRunner()
    var routes: [FakeRoute] = []
    var now = ContinuousClock.now
    /// While set, each route asked for is still getting ready, as the microphone is.
    var routesHoldStart = false
    var pencil: PencilVoice!

    /// Points in the view, which shows the canvas unscrolled and unzoomed.
    static let overTitle = CGPoint(x: 4100, y: 4055)
    static let overButton = CGPoint(x: 4100, y: 4265)
    /// On the Login screen, clear of its elements.
    static let overScreen = CGPoint(x: 4200, y: 4400)
    static let overCanvas = CGPoint(x: 3000, y: 3000)

    init(readiness: ProviderReadiness = .ready, runner custom: (any VoiceCommandRunner)? = nil) {
        (app, screen) = VoiceFixture.login()
        app.tool = .select
        let runner = custom ?? self.runner
        pencil = PencilVoice(
            model: app,
            makeRoute: { [unowned self] in
                let route = FakeRoute()
                route.holdsStart = routesHoldStart
                routes.append(route)
                return route
            },
            makeRunner: { _ in runner },
            clock: { [unowned self] in now }
        )
        pencil.squeezeIsOff = { false }
        pencil.readiness = { readiness }
        pencil.silenceCheck = .milliseconds(5)
        app.pencilVoice = pencil
    }

    func element(_ index: Int) -> CanvasSelection {
        let id = app.store.screen(screen)!.elements[index].id
        return .element(.init(host: .screen(screen), element: id))
    }

    var title: CanvasSelection { element(0) }
    var button: CanvasSelection { element(1) }
    var state: PencilVoice.State? { pencil.bubble?.state }

    /// A quick squeeze, which leaves the pencil listening.
    func toggle(at point: CGPoint = Bench.overButton) async -> Bool {
        pencil.squeezeBegan(at: point, azimuth: .radians(0.1))
        now += .milliseconds(200)
        pencil.squeezeEnded()
        return await eventually { self.state == .listening }
    }

    /// A squeeze held until the pencil is listening, and then let go of.
    func hold(at point: CGPoint = Bench.overButton) async -> Bool {
        pencil.squeezeBegan(at: point, azimuth: .radians(0.1))
        guard await eventually({ self.state == .listening }) else { return false }
        now += .seconds(1)
        pencil.squeezeEnded()
        return true
    }

    func end() {
        pencil.call?.end()
        app.endVoiceCall()
    }
}

@Suite("Push-to-talk with Apple Pencil Pro", .serialized)
@MainActor
struct PencilVoiceTests {
    @Test func aQuickSqueezeTogglesAndTheNextSends() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: .radians(0.1))
        #expect(bench.pencil.bubble == PencilVoice.Bubble(anchor: Bench.overButton, azimuth: .radians(0.1), state: .gettingReady))
        bench.now += .milliseconds(200)
        bench.pencil.squeezeEnded()
        #expect(await eventually { bench.state == .listening })
        #expect(bench.routes.count == 1 && bench.routes[0].finishCount == 0)

        // The second squeeze sends; letting go of it does nothing more.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: .radians(0.1))
        #expect(bench.routes[0].finishCount == 1)
        #expect(bench.state == .working)
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        #expect(bench.routes.count == 1 && bench.routes[0].finishCount == 1)

        bench.pencil.call?.captionTimes = (.milliseconds(100), .milliseconds(100))
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(await eventually { bench.state == .done })
        #expect(await eventually { bench.pencil.bubble == nil })
        bench.end()
    }

    @Test func aHeldSqueezeSendsOnRelease() async {
        let bench = Bench()
        #expect(await bench.hold())
        #expect(bench.routes.count == 1 && bench.routes[0].finishCount == 1)
        #expect(bench.state == .working)
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        bench.end()
    }

    @Test func theSecondSqueezeSendsWithoutAHoverPose() async {
        let bench = Bench()
        #expect(await bench.toggle())
        // The pen drifted out of hover range: the squeeze still ends the toggle.
        bench.pencil.squeezeBegan(at: nil, azimuth: nil)
        #expect(bench.routes[0].finishCount == 1)
        bench.pencil.squeezeEnded()
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        bench.end()
    }

    @Test func aSqueezeOutOfRangeStartsNothing() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: nil, azimuth: nil)
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty && bench.app.selection == nil)
        bench.end()
    }

    @Test func aSqueezeOverChromeOrInDrawStartsNothing() async {
        let bench = Bench()
        // A panel over the button.
        bench.app.chromeFrames["format"] = CGRect(x: 4050, y: 4200, width: 200, height: 200)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        // The bar across the top.
        bench.app.topBarBottom = 60
        bench.pencil.squeezeBegan(at: CGPoint(x: 300, y: 30), azimuth: nil)
        bench.pencil.squeezeEnded()
        bench.app.chromeFrames = [:]
        // Draw on: the squeeze is PencilKit's.
        bench.app.tool = .draw
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        bench.app.tool = .select
        // Squeezing turned off in Settings.
        bench.pencil.squeezeIsOff = { true }
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty && bench.app.selection == nil)
        bench.end()
    }

    @Test func aSqueezeDuringACallOnlyRetargets() async {
        let bench = Bench()
        await bench.app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.app.selection == bench.button)
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        bench.end()
    }

    @Test func aSqueezeOverAnElementSelectsIt() async {
        let bench = Bench()
        bench.runner.holds = true
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.app.selection == bench.button)
        #expect(await eventually { bench.state == .listening })
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        // Selected something else in the meantime: the command still works on the button.
        bench.app.selection = bench.title
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(bench.app.selection == bench.button)
        bench.runner.holds = false
        bench.end()
    }

    @Test func aSqueezeOverADrawingTargetsWhatIsBeneath() async {
        let bench = Bench()
        // Ink over the button. Locked, it is picked by its frame.
        var ink = DesignStore.newElement(.drawing)
        ink.frame = CGRect(x: 4050, y: 4200, width: 150, height: 100)
        ink.isLocked = true
        let drawing = bench.app.store.addFloating(ink, scale: 1)
        #expect(bench.app.hoverTarget(at: Bench.overButton) == .element(drawing))
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.app.selection == bench.button)
        bench.end()
    }

    @Test func aSqueezeOnPartOfASelectionKeepsTheWholeSelection() async {
        let bench = Bench()
        let both = CanvasSelection([bench.title, bench.button])
        bench.app.selection = both
        #expect(await bench.hold())
        #expect(bench.app.selection == both)
        bench.app.selection = nil
        bench.routes[0].send(.command("make them blue"))
        #expect(await eventually { bench.runner.commands == ["make them blue"] })
        #expect(bench.app.selection == both)
        bench.end()
    }

    @Test func aSqueezeOverCanvasPlacesTheNewScreenThere() async throws {
        let bench = Bench()
        bench.app.selection = bench.button
        bench.runner.holds = true
        #expect(await bench.hold(at: Bench.overCanvas))
        #expect(bench.app.selection == nil)
        bench.routes[0].send(.command("a settings screen"))
        #expect(await eventually { bench.runner.commands == ["a settings screen"] })
        // The view is unscrolled and unzoomed, so the pen's point is the canvas point.
        let anchor = Bench.overCanvas
        #expect(bench.app.newScreenAnchor == anchor)
        #expect(bench.app.voiceHint == "(The person pointed at empty canvas: a description of a screen means a new screen there.)")

        // The model's createScreen comes here, and the screen goes at the pen's point.
        let device = bench.app.store.canvas.sketchDevice
        #expect(DesignActions.placementForNewScreen(device, in: bench.app, near: anchor).origin == anchor)
        bench.app.generateScreen(from: "a settings screen")
        let made = try #require(bench.app.store.screens.last)
        #expect(made.origin == anchor)
        bench.app.stopGenerating()
        await bench.app.waitForGeneration()

        bench.runner.holds = false
        #expect(await eventually { bench.app.newScreenAnchor == nil && bench.app.voiceHint == nil })
        bench.end()
    }

    @Test func aNewScreenAtAPointMovesRightPastAScreenThere() throws {
        let (app, screen) = VoiceFixture.login()
        let login = try #require(app.store.screen(screen))
        let placement = DesignActions.placementForNewScreen(.iPhone, in: app, near: CGPoint(x: 3900, y: 4100))
        #expect(placement.origin == CGPoint(x: (login.canvasFrame.maxX + 60).rounded(), y: 4100))
        // With no point, as before: to the right of the rightmost screen, level with it.
        let usual = DesignActions.placementForNewScreen(.iPhone, in: app)
        #expect(usual.origin == CGPoint(x: (login.canvasFrame.maxX + 60).rounded(), y: login.origin.y))
    }

    @Test func aToggleLeftSilentCloses() async {
        let bench = Bench()
        #expect(await bench.toggle())
        bench.now += .seconds(19)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        // Words heard start the wait again.
        bench.routes[0].send(.hearing("make the"))
        #expect(await eventually { bench.pencil.call?.caption?.kind == .hearing })
        try? await Task.sleep(for: .milliseconds(50))
        bench.now += .seconds(19)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        bench.now += .seconds(2)
        #expect(await eventually { bench.routes[0].isStopped && bench.pencil.bubble == nil })
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    @Test func anUnavailableModelSaysSoInTheBubble() async {
        let bench = Bench(readiness: .unavailable("Apple Intelligence is turned off in Settings."))
        bench.pencil.hovered()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.state == .problem("Apple Intelligence is turned off in Settings."))
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.routes.isEmpty && bench.runner.warmUps == 0)
        bench.end()
    }

    @Test func hoveringWarmsOnce() async {
        let bench = Bench()
        bench.pencil.hovered()
        bench.pencil.hovered()
        #expect(await eventually { bench.runner.warmUps == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.warmUps == 1 && bench.routes.isEmpty)
        bench.end()
    }

    @Test func aSqueezeWhileGettingReadyListensOnceReady() async {
        // The agent captures the canvas while it gets ready, and the call can't listen
        // until it has. A squeeze then waits for it rather than being lost.
        let slow = SlowWarmingRunner()
        let bench = Bench(runner: slow)
        bench.pencil.hovered()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.now += .milliseconds(200)
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .gettingReady && bench.routes.isEmpty)
        slow.holdsWarmUp = false
        #expect(await eventually { bench.state == .listening && bench.routes.count == 1 })
        bench.end()
    }

    @Test func aHoldLetGoBeforeTheMicrophoneIsOnSaysSo() async {
        let bench = Bench()
        bench.routesHoldStart = true
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.routes.count == 1 })
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        let problem = PencilVoice.State.problem("Didn't catch that. Wait for the tap, then speak.")
        #expect(await eventually { bench.state == problem })
        #expect(bench.routes[0].isStopped)
        bench.routes[0].holdsStart = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == problem && bench.runner.commands.isEmpty)
        bench.end()
    }

    @Test func tappingTheBubbleCancels() async {
        let bench = Bench()
        #expect(await bench.toggle())
        bench.pencil.tapBubble()
        #expect(bench.routes[0].isStopped && bench.pencil.bubble == nil)
        bench.routes[0].send(.command("make it blue"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    @Test func leavingTheScreenStopsListening() async {
        let bench = Bench()
        bench.runner.holds = true
        // One command running, and the next being listened for.
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(await bench.toggle())
        bench.app.windowLeftTheScreen()
        #expect(bench.routes[1].isStopped && bench.pencil.bubble == nil)
        // The running command is left to finish.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.cancelled.isEmpty)
        bench.runner.holds = false
        bench.end()
    }
}

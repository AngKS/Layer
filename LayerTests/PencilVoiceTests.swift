import Foundation
import SwiftUI
import Testing
import UIKit
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
        // Other suites' calls run alongside: only this design's own call counts, unless a
        // test says otherwise.
        pencil.phoneCallIsUp = { false }
        // Nor do other suites' designs count as other windows.
        pencil.otherWindows = { [] }
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

    /// The open route hears some words, and the call shows them.
    func hear(_ words: String, on route: Int = 0) async -> Bool {
        routes[route].send(.hearing(words))
        return await eventually { self.pencil.call?.caption?.kind == .hearing && self.pencil.call?.caption?.text == words }
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
        #expect(await bench.hear("make it blue"))

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
        #expect(await bench.hear("make it blue"))
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
        // The pencil taps where it squeezed, to say the target moved.
        #expect(bench.pencil.retarget?.point == Bench.overButton)
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
        // The view is unscrolled and unzoomed, so the pen's point is the canvas point. It
        // goes with the command, not into anything another command could read.
        let anchor = Bench.overCanvas
        #expect(bench.runner.targets == [.canvas(anchor)])

        // The model's createScreen comes here, and the screen goes at the pen's point.
        let device = bench.app.store.canvas.sketchDevice
        #expect(DesignActions.placementForNewScreen(device, in: bench.app, near: anchor).origin == anchor)
        bench.app.generateScreen(from: "a settings screen", near: anchor)
        let made = try #require(bench.app.store.screens.last)
        #expect(made.origin == anchor)
        bench.app.stopGenerating()
        await bench.app.waitForGeneration()

        bench.runner.holds = false
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
        // Speech may be made ready, but no route is started: hovering never turns the microphone on.
        #expect(bench.runner.warmUps == 1 && !bench.routes.contains { $0.wasStarted })
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
        #expect(bench.state == .gettingReady && !bench.routes.contains { $0.wasStarted })
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

    // MARK: Fix round 1

    @Test func anEarlierCommandsProblemDoesNotEndAListenThatIsStarting() async {
        let bench = Bench()
        bench.runner.holds = true
        bench.runner.outcomes = [VoiceOutcome(problem: "Can't reach the internet.")]
        // A runs, on the button.
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        // B is squeezed for over the title while its microphone is still coming on.
        bench.routesHoldStart = true
        bench.pencil.squeezeBegan(at: Bench.overTitle, azimuth: nil)
        #expect(await eventually { bench.routes.count == 2 })
        // A ends with a problem in the meantime.
        bench.runner.holds = false
        #expect(await eventually { bench.pencil.call?.caption?.kind == .problem })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .gettingReady)
        // B's microphone comes on, and letting go sends B, about the title.
        bench.routes[1].holdsStart = false
        #expect(await eventually { bench.state == .listening })
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        #expect(bench.routes[1].finishCount == 1)
        bench.routes[1].send(.command("make it red"))
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red"] })
        #expect(bench.app.selection == bench.title)
        bench.end()
    }

    @Test func leavingWhileTheMicrophoneComesOnTurnsItOff() async {
        let bench = Bench()
        bench.routesHoldStart = true
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.routes.count == 1 })
        bench.pencil.call?.captionTimes = (.seconds(60), .seconds(60))
        bench.app.windowLeftTheScreen()
        #expect(bench.routes[0].isStopped && bench.pencil.bubble == nil)
        bench.end()
    }

    @Test func theSameProblemTwiceIsStillShown() async {
        let bench = Bench()
        bench.routesHoldStart = true
        let problem = PencilVoice.State.problem("Didn't catch that. Wait for the tap, then speak.")
        for attempt in 1...2 {
            bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
            #expect(await eventually { bench.routes.count == attempt })
            bench.now += .seconds(1)
            bench.pencil.squeezeEnded()
            #expect(await eventually { bench.state == problem })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(bench.state == problem)
        }
        bench.end()
    }

    /// Whether anything was said is the route's to say: it answers a finish at once when
    /// nothing was.
    @Test func aToggleWithNothingSaidClosesAtOnce() async {
        let bench = Bench()
        #expect(await bench.toggle())
        bench.pencil.call?.finishWait = .seconds(60)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.routes[0].finishCount == 1)
        bench.pencil.squeezeEnded()
        bench.routes[0].send(.nothingHeard)
        #expect(await eventually { bench.pencil.bubble == nil && bench.routes[0].isStopped })
        #expect(bench.runner.commands.isEmpty && !(bench.pencil.call?.isHearing ?? true))
        bench.end()
    }

    /// "Undo" said just before the second squeeze, before the recogniser showed it: the
    /// route still has it, so it is sent, not dropped for want of a caption (D-M1).
    @Test func aToggleSendsWordsNotYetShown() async {
        let bench = Bench()
        #expect(await bench.toggle())
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.routes[0].finishCount == 1 && !bench.routes[0].isStopped)
        bench.pencil.squeezeEnded()
        bench.routes[0].send(.command("undo"))
        #expect(await eventually { bench.runner.commands == ["undo"] })
        bench.end()
    }

    @Test func aPencilCallIsLetGoOf() async {
        let (app, _) = VoiceFixture.login()
        // Out of Draw, where hovering warms nothing.
        app.tool = .select
        var pencil: PencilVoice? = PencilVoice(model: app, makeRoute: { FakeRoute() }, makeRunner: { _ in FakeRunner() })
        pencil?.readiness = { .ready }
        pencil?.phoneCallIsUp = { false }
        pencil?.hovered()
        #expect(await eventually { pencil?.call?.phase == .listening })
        try? await Task.sleep(for: .milliseconds(50))
        weak var call = pencil?.call
        pencil = nil
        #expect(await eventually { call == nil })
    }

    @Test func closingTheDesignEndsThePencilCallOnceIdle() async {
        let bench = Bench()
        bench.runner.holds = true
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        let call = bench.pencil.call
        bench.app.close()
        try? await Task.sleep(for: .milliseconds(50))
        // The running command is left to finish, and then the call ends.
        #expect(call?.phase == .working && bench.runner.cancelled.isEmpty)
        bench.runner.holds = false
        #expect(await eventually { call?.phase == .ended && bench.pencil.call == nil })
        // An idle call ends at once.
        let idle = Bench()
        idle.pencil.hovered()
        #expect(await eventually { idle.pencil.call?.phase == .listening })
        let idleCall = idle.pencil.call
        idle.app.close()
        #expect(idleCall?.phase == .ended)
    }

    @Test func hoveringDuringAPhoneCallMakesNoPencilCall() async {
        let bench = Bench()
        await bench.app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        bench.pencil.hovered()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call == nil && bench.runner.warmUps == 0)
        bench.end()
    }

    // MARK: Where the bubble goes

    private static let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private static let bubbleSize = CGSize(width: 200, height: 56)

    private static func bubbleFrame(at tip: CGPoint, azimuth: Angle?, topInset: CGFloat = 80) -> CGRect {
        CGRect(origin: PencilVoiceBubble.origin(anchor: tip, azimuth: azimuth, size: bubbleSize, in: bounds, topInset: topInset), size: bubbleSize)
    }

    /// How far a rectangle is from a point, 0 when it holds it.
    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    @Test func aRightHandedPencilPutsTheBubbleUpAndLeft() {
        // The barrel points down and right of the tip, so the hand is there.
        let tip = CGPoint(x: 500, y: 400)
        let frame = Self.bubbleFrame(at: tip, azimuth: .degrees(45))
        #expect(frame.midX < tip.x && frame.midY < tip.y)
        #expect(Self.distance(from: tip, to: frame) >= 28 - 0.01)
    }

    @Test func aLeftHandedPencilPutsTheBubbleUpAndRight() {
        let tip = CGPoint(x: 500, y: 400)
        let frame = Self.bubbleFrame(at: tip, azimuth: .degrees(135))
        #expect(frame.midX > tip.x && frame.midY < tip.y)
        #expect(Self.distance(from: tip, to: frame) >= 28 - 0.01)
    }

    @Test func theGripMeasuredOnTheIPadPutsTheBubbleLeft() {
        // About 0.06–0.17 rad on the iPad mini: the barrel points right of the tip.
        let tip = CGPoint(x: 500, y: 400)
        let frame = Self.bubbleFrame(at: tip, azimuth: .radians(0.1))
        #expect(frame.maxX <= tip.x - 28 + 0.01)
        #expect(abs(frame.midY - tip.y) < 28)
    }

    @Test func aTipNearTheTopKeepsTheBubbleBelowTheBar() {
        let tip = CGPoint(x: 500, y: 90)
        let frame = Self.bubbleFrame(at: tip, azimuth: .degrees(45), topInset: 80)
        #expect(frame.minY >= 80)
        #expect(frame.minX >= 12 && frame.maxX <= 1000 - 12 && frame.maxY <= 800 - 12)
        // And a tip by a corner keeps it inside the window.
        let corner = Self.bubbleFrame(at: CGPoint(x: 5, y: 795), azimuth: .degrees(-45))
        #expect(corner.minX >= 12 && corner.maxY <= 800 - 12)
    }

    @Test func noAzimuthPutsTheBubbleBelow() {
        let tip = CGPoint(x: 500, y: 400)
        let frame = Self.bubbleFrame(at: tip, azimuth: nil)
        #expect(frame.origin == CGPoint(x: 400, y: 428))
    }

    // MARK: Seen in the simulator

    @Test func belowTheBarTheBubbleSwivelsOffTheTip() {
        // The barrel points down, so the bubble would go straight up, into the bar.
        let tip = CGPoint(x: 400, y: 110)
        let frame = Self.bubbleFrame(at: tip, azimuth: .degrees(90), topInset: 80)
        #expect(frame.minY >= 80)
        #expect(Self.distance(from: tip, to: frame) >= 14 - 0.01)
    }

    @Test func byTheRightEdgeTheBubbleSwivelsOffTheTip() {
        // The barrel points left, so the bubble would go right, past the edge.
        let tip = CGPoint(x: 980, y: 400)
        let frame = Self.bubbleFrame(at: tip, azimuth: .degrees(180))
        #expect(frame.maxX <= 1000 - 12)
        #expect(Self.distance(from: tip, to: frame) >= 14 - 0.01)
    }

    @Test func theBubbleKeepsOffTheSelectionsActions() {
        let tip = CGPoint(x: 500, y: 400)
        let preferred = Self.bubbleFrame(at: tip, azimuth: .degrees(45))
        // The actions over what the squeeze selected lie where the bubble would go.
        let actions = preferred.insetBy(dx: -20, dy: 10)
        let origin = PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(45), size: Self.bubbleSize, in: Self.bounds, topInset: 80, avoiding: [actions])
        let frame = CGRect(origin: origin, size: Self.bubbleSize)
        #expect(!frame.intersects(actions))
        #expect(Self.distance(from: tip, to: frame) >= 28 - 0.01)
        // With nothing in the way it goes where it always did.
        let free = PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(45), size: Self.bubbleSize, in: Self.bounds, topInset: 80, avoiding: [])
        #expect(free == preferred.origin)
    }

    @Test func theBubbleKeepsOffWhatIsSpokenAboutAndTheActionsOverIt() {
        // A button, squeezed in its middle, with its actions just above it.
        let tip = CGPoint(x: 500, y: 400)
        let button = CGRect(x: 390, y: 385, width: 220, height: 30)
        let actions = CGRect(x: 370, y: 320, width: 260, height: 50)
        let origin = PencilVoiceBubble.origin(
            anchor: tip, azimuth: .degrees(45), size: Self.bubbleSize, in: Self.bounds, topInset: 80, avoiding: [actions], subject: button)
        let frame = CGRect(origin: origin, size: Self.bubbleSize)
        #expect(!frame.intersects(button) && !frame.intersects(actions))
        // A whole screen can't be kept clear of: the actions and the tip still are.
        let screen = CGRect(x: 300, y: 100, width: 400, height: 650)
        let onScreen = CGRect(origin: PencilVoiceBubble.origin(
            anchor: tip, azimuth: .degrees(45), size: Self.bubbleSize, in: Self.bounds, topInset: 80, avoiding: [actions], subject: screen), size: Self.bubbleSize)
        #expect(!onScreen.intersects(actions))
        #expect(Self.distance(from: tip, to: onScreen) >= 28 - 0.01)
    }

    @Test func theBubbleKeepsItsSideFromStateToState() {
        // The squeeze in sheet A3: the Sign in button, its actions above it, a right-hander.
        let tip = CGPoint(x: 605, y: 436)
        let button = CGRect(x: 499, y: 422, width: 212, height: 29)
        let actions = CGRect(x: 468, y: 360, width: 274, height: 52)
        let bounds = CGRect(x: 0, y: 0, width: 1210, height: 834)
        // Listening, listening with words, working, done and a problem, as measured there.
        let sizes = [CGSize(width: 200, height: 48), CGSize(width: 262, height: 62), CGSize(width: 78, height: 48),
                     CGSize(width: 90, height: 48), CGSize(width: 300, height: 48)]
        // Chosen afresh for each size, the side changed as the bubble did: what was seen.
        let afresh = Set(sizes.map {
            PencilVoiceBubble.turn(anchor: tip, azimuth: .degrees(45), size: $0, in: bounds, topInset: 88, avoiding: [actions], subject: button)
        })
        #expect(afresh.count > 1)
        // Chosen once, for every size it takes, every state stays on that side, clear of the
        // tip, the actions and the button.
        let planned = PencilVoiceBubble.plannedSizes(showsWords: true, largestMeasured: .zero)
        let turn = PencilVoiceBubble.turn(anchor: tip, azimuth: .degrees(45), sizes: planned, in: bounds, topInset: 88, avoiding: [actions], subject: button)
        var sides: Set<[Bool]> = []
        for size in sizes {
            #expect(!PencilVoiceBubble.isBlocked(turn: turn, anchor: tip, azimuth: .degrees(45), size: size, in: bounds, topInset: 88, avoiding: [actions]))
            let frame = CGRect(origin: PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(45), turn: turn, size: size, in: bounds, topInset: 88), size: size)
            #expect(!frame.intersects(actions) && !frame.intersects(button))
            sides.insert([frame.midX < tip.x, frame.midY < tip.y])
        }
        #expect(sides.count == 1)
    }

    @Test func inATightSpotTheSideIsTheOneForTheBubblesActualSize() {
        // A narrow window, the pencil held level, chrome close above and below the tip:
        // the widest planned bubble can't be kept off both the tip and the chrome.
        let bounds = CGRect(x: 0, y: 0, width: 330, height: 800)
        let tip = CGPoint(x: 165, y: 400)
        let chrome = [CGRect(x: 0, y: 300, width: 330, height: 60), CGRect(x: 0, y: 440, width: 330, height: 60)]
        let working = CGSize(width: 80, height: 48)
        let sizes = PencilVoiceBubble.plannedSizes(showsWords: false, largestMeasured: .zero)
        let planned = PencilVoiceBubble.turn(anchor: tip, azimuth: .degrees(0), sizes: sizes, in: bounds, topInset: 80, avoiding: chrome)
        let plannedFrame = CGRect(origin: PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(0), turn: planned, size: working, in: bounds, topInset: 80), size: working)
        #expect(Self.distance(from: tip, to: plannedFrame) < 14 || chrome.contains { $0.intersects(plannedFrame) })
        // With the actual size given, the bubble is clear of both.
        let turn = PencilVoiceBubble.turn(anchor: tip, azimuth: .degrees(0), sizes: sizes, actual: working, in: bounds, topInset: 80, avoiding: chrome)
        let frame = CGRect(origin: PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(0), turn: turn, size: working, in: bounds, topInset: 80), size: working)
        #expect(Self.distance(from: tip, to: frame) >= 14 - 0.01)
        #expect(!chrome.contains { $0.intersects(frame) })
        // And the side it was given isn't then taken for blocked.
        #expect(!PencilVoiceBubble.isBlocked(turn: turn, anchor: tip, azimuth: .degrees(0), size: working, in: bounds, topInset: 80, avoiding: chrome))
    }

    @Test func aSideOnWhatIsSpokenAboutIsBlockedOnlyIfAnotherSideMissesIt() {
        let tip = CGPoint(x: 500, y: 400)
        let size = CGSize(width: 200, height: 52)
        let opposite = CGRect(origin: PencilVoiceBubble.origin(anchor: tip, azimuth: .degrees(45), turn: 0, size: size, in: Self.bounds, topInset: 80), size: size)
        // Something spoken about where the bubble went, which another side misses.
        #expect(PencilVoiceBubble.isBlocked(turn: 0, anchor: tip, azimuth: .degrees(45), size: size, in: Self.bounds, topInset: 80, avoiding: [], subject: opposite))
        // A whole screen round the tip, which no side misses, blocks nothing.
        let screen = CGRect(x: 100, y: 0, width: 800, height: 800)
        #expect(!PencilVoiceBubble.isBlocked(turn: 0, anchor: tip, azimuth: .degrees(45), size: size, in: Self.bounds, topInset: 80, avoiding: [], subject: screen))
    }

    @Test func theBubbleShowsTheNewestWholeWords() {
        #expect(PencilVoiceBubble.newestWords(of: "make it blue") == "make it blue")
        let said = "make the sign in button blue and give it a little more space above"
        let shown = PencilVoiceBubble.newestWords(of: said)
        // The newest eight words, between ellipses, as the person asked: "…words…".
        #expect(shown == "…and give it a little more space above…")
        #expect(shown.dropFirst().dropLast().split(separator: " ").count == PencilVoiceBubble.wordLimit)
        // Exactly the limit is shown whole.
        #expect(PencilVoiceBubble.newestWords(of: "one two three four five six seven eight") == "one two three four five six seven eight")
    }

    // MARK: Fix round 1 of the bubble

    @Test func theSqueezeIsThePencilsWhileAToggleIsOpenOrBeingSent() async {
        let bench = Bench()
        #expect(!bench.pencil.ownsSqueeze)
        // A held squeeze over the canvas isn't one the panel could have.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(!bench.pencil.ownsSqueeze)
        bench.now += .milliseconds(200)
        bench.pencil.squeezeEnded()
        #expect(await eventually { bench.state == .listening })
        // A toggle is open: the next squeeze is the pencil's, wherever the pen is.
        #expect(bench.pencil.ownsSqueeze)
        #expect(await bench.hear("make it blue"))
        bench.pencil.squeezeBegan(at: CGPoint(x: 10, y: 10), azimuth: nil)
        #expect(bench.state == .working && bench.pencil.ownsSqueeze)
        bench.pencil.squeezeEnded()
        #expect(!bench.pencil.ownsSqueeze)
        bench.end()
    }

    @Test func turningOnDrawMidSqueezeStopsListening() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        // Draw comes on, and the squeeze's end never arrives.
        bench.app.tool = .draw
        #expect(bench.pencil.bubble == nil && bench.routes[0].isStopped)
        #expect(!bench.pencil.ownsSqueeze)
        // Back in Select, the next squeeze starts afresh.
        bench.app.tool = .select
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening && bench.routes.count == 2 })
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    @Test func theBubbleShowsOnlyWordsHeardForThisListen() async {
        let bench = Bench()
        bench.runner.holds = true
        // An earlier listen's words are still the call's caption when the next begins.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        #expect(await bench.hear("make it"))
        #expect(bench.pencil.wordsHeard == "make it")
        // Let go of, so it is sent, with the words still the call's caption.
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        #expect(bench.state == .working && bench.pencil.wordsHeard == nil)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.pencil.call?.caption?.kind == .hearing && bench.pencil.call?.caption?.text == "make it")
        #expect(bench.pencil.wordsHeard == nil)
        #expect(await eventually { bench.state == .listening })
        #expect(await bench.hear("make it red", on: 1))
        #expect(bench.pencil.wordsHeard == "make it red")
        bench.runner.holds = false
        bench.end()
    }

    @Test func hoveringWhileTheModelIsUnavailableChecksSeldom() async {
        let bench = Bench()
        var checks = 0
        bench.pencil.readiness = { checks += 1; return .unavailable("No key.") }
        for _ in 0..<50 { bench.pencil.hovered() }
        #expect(checks == 1)
        bench.now += PencilVoice.readinessRetry
        bench.pencil.hovered()
        #expect(checks == 2)
        // A change in Settings is looked at on the next hover.
        NotificationCenter.default.post(name: ModelPreferences.changed, object: nil)
        bench.pencil.hovered()
        #expect(checks == 3)
        bench.end()
    }

    // MARK: Wave 2: one microphone, one command at a time, and a clean life-cycle

    /// A phone call takes the microphone: the pencil stops listening, and sends nothing.
    /// Its call shares the design's turns with the phone call's (D-I1, B-I2).
    @Test func startingAPhoneCallStopsAPencilListen() async {
        let bench = Bench()
        #expect(await bench.toggle())
        #expect(bench.pencil.call?.gate === bench.app.voiceCommands)
        await bench.app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        #expect(bench.routes[0].isStopped && bench.pencil.bubble == nil)
        #expect(bench.app.voice?.gate === bench.app.voiceCommands)
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    /// A phone call in another window has the microphone, and its commands are about that
    /// window's design: a squeeze here does nothing, and taps nothing (final fix 9).
    @Test func aSqueezeDuringAnotherWindowsCallDoesNothing() async {
        let bench = Bench()
        let other = VoiceFixture.login().app
        // Two windows of the app: one line.
        other.phoneLine = bench.app.phoneLine
        await other.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        let call = other.voice
        bench.pencil.phoneCallIsUp = { [line = bench.app.phoneLine] in line.call === call && call != nil }
        #expect(bench.app.phoneLine.call === other.voice)
        bench.pencil.hovered()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call == nil && bench.routes.isEmpty && bench.pencil.bubble == nil)
        #expect(bench.app.selection == nil)
        #expect(bench.pencil.retarget == nil)
        other.endVoiceCall()
        bench.end()
    }

    /// A held squeeze whose end never comes stops listening after a minute, and says so (D-C1).
    @Test func aHoldWhoseEndNeverComesStopsAfterAMinute() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        bench.now += .seconds(59)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        bench.now += .seconds(2)
        #expect(await eventually { bench.routes[0].isStopped && bench.state == .problem(PencilVoice.heldTooLong) })
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    /// A squeeze whose gesture fails was never said to be over: a held one sends nothing (D-C1).
    @Test func aHeldSqueezeThatFailsSendsNothing() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        #expect(await bench.hear("make it blue"))
        bench.now += .seconds(1)
        bench.pencil.squeezeFailed()
        #expect(bench.routes[0].isStopped && bench.routes[0].finishCount == 0 && bench.pencil.bubble == nil)
        // The next squeeze starts afresh.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening && bench.routes.count == 2 })
        bench.end()
    }

    /// The device sends a squeeze's start over and over: only the first one listens (D-M9).
    @Test func aSqueezeStartedAgainListensOnce() async {
        let bench = Bench()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.routes.count == 1 && !bench.routes[0].isStopped && bench.state == .listening)
        bench.end()
    }

    /// Closing while a sent route still settles stops it: nothing more is sent, and the
    /// microphone is let go of (D-I5).
    @Test func closingWhileARouteSettlesStopsIt() async {
        let bench = Bench()
        #expect(await bench.hold())
        #expect(bench.routes[0].finishCount == 1 && !bench.routes[0].isStopped)
        bench.app.close()
        #expect(bench.routes[0].isStopped)
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.pencil.call == nil })
        #expect(bench.runner.commands.isEmpty)
    }

    /// A sent bubble follows its own command: the one before it finishing isn't this one done (D-M3).
    @Test func aSentBubbleDoesNotShowAnEarlierCommandsOutcome() async {
        let bench = Bench()
        bench.runner.holds = true
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        // The second is sent while the first still runs.
        #expect(await bench.hold())
        #expect(bench.state == .working)
        bench.pencil.call?.captionTimes = (.seconds(60), .seconds(60))
        bench.runner.holds = false
        #expect(await eventually { bench.pencil.call?.caption?.kind == .done })
        try? await Task.sleep(for: .milliseconds(50))
        // The first's tick is no tick for the second, which hasn't even been heard yet.
        #expect(bench.state == .working)
        bench.routes[1].send(.command("make it red"))
        #expect(await eventually { bench.state == .done })
        bench.end()
    }
    // MARK: Final fix wave

    /// A squeeze over the last bubble, still showing, is a new squeeze: it opens a bubble
    /// of its own in place of the old one (final fix 1).
    @Test func aSqueezeOverTheLastBubbleStartsANewListen() async {
        let bench = Bench()
        #expect(await bench.hold())
        bench.pencil.call?.captionTimes = (.seconds(60), .seconds(60))
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.state == .done })
        // The bubble reports where it is, over the button.
        bench.app.chromeFrames[PencilVoiceBubble.chromeName] = CGRect(x: 4000, y: 4200, width: 250, height: 120)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening && bench.routes.count == 2 })
        // Other chrome there still keeps a squeeze off.
        bench.pencil.squeezeFailed()
        bench.app.chromeFrames["format"] = CGRect(x: 4000, y: 4200, width: 250, height: 120)
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.bubble == nil && bench.routes.count == 2)
        bench.end()
    }

    /// Talk in the room keeps a toggle's silence from coming, but it still stops after a
    /// minute, as a hold does (final fix 2).
    @Test func aToggleStopsAfterAMinuteThoughWordsKeepComing() async {
        let bench = Bench()
        #expect(await bench.toggle())
        for words in ["the radio", "is on", "in the kitchen"] {
            bench.now += .seconds(15)
            #expect(await bench.hear(words))
            try? await Task.sleep(for: .milliseconds(30))
        }
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        // Sixteen seconds since the last words: the toggle's silence hasn't run out, but
        // the minute has.
        bench.now += .seconds(16)
        #expect(await eventually { bench.routes[0].isStopped && bench.state == .problem(PencilVoice.heldTooLong) })
        #expect(bench.runner.commands.isEmpty)
        bench.end()
    }

    /// The first listen's words arrive only after the second was sent: its tick is still
    /// its own, not the second bubble's (final fix 3, D-M3).
    @Test func aCommandWhoseWordsArriveLateIsNotTheNextBubbles() async {
        let bench = Bench()
        #expect(await bench.hold())
        // The first still settles as the second is squeezed and sent.
        #expect(await bench.hold())
        #expect(bench.routes.count == 2 && bench.state == .working)
        bench.pencil.call?.captionTimes = (.seconds(60), .seconds(60))
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(await eventually { bench.pencil.call?.caption?.kind == .done })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .working)
        bench.routes[1].send(.command("make it red"))
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red"] && bench.state == .done })
        bench.end()
    }

    /// An earlier listen's failure, which came while it settled, isn't the next bubble's
    /// problem (final fix 3).
    @Test func anEarlierListensFailureIsNotTheNextBubbles() async {
        let bench = Bench()
        #expect(await bench.hold())
        #expect(await bench.hold())
        bench.pencil.call?.captionTimes = (.seconds(60), .seconds(60))
        bench.routes[0].send(.failed("The microphone stopped. Squeeze to try again."))
        #expect(await eventually { bench.pencil.call?.caption?.kind == .problem })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.state == .working)
        bench.routes[1].send(.command("make it red"))
        #expect(await eventually { bench.state == .done })
        bench.end()
    }

    /// A toggle sent with nothing said closes, even while another command runs: it used to
    /// spin for as long as that one did (final fix 4).
    @Test func aToggleWithNothingSaidClosesWhileAnotherCommandRuns() async {
        let bench = Bench()
        bench.runner.holds = true
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(await bench.toggle())
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        #expect(bench.state == .working)
        bench.routes[1].send(.nothingHeard)
        #expect(await eventually { bench.pencil.bubble == nil && bench.routes[1].isStopped })
        #expect(bench.pencil.call?.phase == .working)
        bench.runner.holds = false
        bench.end()
    }

    /// One microphone at a time across windows: a squeeze here stops a pencil listening in
    /// another, which sends nothing (final fix 8).
    @Test func aSqueezeStopsAPencilListeningInAnotherWindow() async {
        let bench = Bench()
        let other = Bench()
        bench.pencil.otherWindows = { [other.app] }
        #expect(await other.toggle())
        #expect(await other.hear("make it"))
        #expect(await bench.toggle())
        #expect(other.routes[0].isStopped && other.pencil.bubble == nil)
        #expect(other.runner.commands.isEmpty && !other.pencil.ownsSqueeze)
        other.end()
        bench.end()
    }

    /// The pen hovering in Draw isn't on its way to a squeeze, which is PencilKit's there:
    /// no pencil call is made ready (final fix 10).
    @Test func hoveringInDrawMakesNoPencilCall() async {
        let bench = Bench()
        bench.app.tool = .draw
        bench.pencil.hovered()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call == nil && bench.runner.warmUps == 0)
        bench.app.tool = .select
        bench.pencil.hovered()
        #expect(await eventually { bench.runner.warmUps == 1 })
        bench.end()
    }

    /// A drawing that is part of the selection is part of it like anything else: a squeeze
    /// on it is about the whole selection, not what lies beneath it (final fix 13).
    @Test func aSqueezeOnADrawingInTheSelectionKeepsTheWholeSelection() async {
        let bench = Bench()
        var ink = DesignStore.newElement(.drawing)
        ink.frame = CGRect(x: 4050, y: 4200, width: 150, height: 100)
        ink.isLocked = true
        let drawing = bench.app.store.addFloating(ink, scale: 1)
        let both = CanvasSelection([.element(drawing), bench.title])
        bench.app.selection = both
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.app.selection == both)
        bench.end()
    }

    // MARK: Squeeze to Talk

    @Test func squeezeToTalkIsOnUntilTurnedOffInSettings() {
        withOwnSettings { settings in
            let open = AppModel(document: LayerDocument(), settings: settings)
            #expect(open.squeezesToTalk)
            settings.set(false, forKey: AppModel.squeezesToTalkKey)
            // A design opened afterwards has it off, and one already open once it reads it again.
            #expect(!AppModel(document: LayerDocument(), settings: settings).squeezesToTalk)
            open.readSqueezesToTalk()
            #expect(!open.squeezesToTalk)
            settings.set(true, forKey: AppModel.squeezesToTalkKey)
            open.readSqueezesToTalk()
            #expect(open.squeezesToTalk)
        }
    }

    /// The board's Magic Pen tab and Settings › Voice are one setting, the app's: either
    /// writes where both read, and every open design follows at once, unasked.
    @Test func theMagicPenTabAndSettingsShareSqueezeToTalk() {
        // Watched by key, and a dot in a key is a key path to whatever watches it.
        #expect(!AppModel.squeezesToTalkKey.contains("."))
        withOwnSettings { settings in
            let design = AppModel(document: LayerDocument(), settings: settings)
            let other = AppModel(document: LayerDocument(), settings: settings)
            let elsewhere = AppModel(document: LayerDocument())
            design.openDesigns = { [design, other, elsewhere] }
            // From the tab: this design, the other window's, and the setting itself.
            design.setSqueezesToTalk(false)
            #expect(!design.squeezesToTalk && !other.squeezesToTalk)
            #expect(settings.object(forKey: AppModel.squeezesToTalkKey) as? Bool == false)
            // A design whose settings are kept elsewhere, as in a test, keeps its own.
            #expect(elsewhere.squeezesToTalk)
            // From Settings: both again.
            AppModel.setSqueezesToTalk(true, in: settings, designs: [design, other])
            #expect(design.squeezesToTalk && other.squeezesToTalk)
            #expect(settings.object(forKey: AppModel.squeezesToTalkKey) as? Bool == true)
        }
    }

    /// On, the canvas has the squeeze in Select, and PencilKit has it in Draw, as before.
    @Test func withSqueezeToTalkOnTheCanvasHasTheSqueezeOutsideDraw() {
        let bench = Bench()
        #expect(bench.app.squeezesToTalk && bench.app.squeezeRouter.hearsSqueezes)
        bench.app.tool = .draw
        #expect(!bench.app.squeezeRouter.hearsSqueezes)
    }

    /// Off, the squeeze is the system's: the canvas has no squeeze action at all, and a
    /// squeeze anywhere, over an element, a screen or the open canvas, starts nothing.
    @Test func withSqueezeToTalkOffASqueezeStartsNothing() async {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        bench.app.squeezesToTalk = false
        #expect(!router.hearsSqueezes)
        bench.app.tool = .draw
        #expect(!router.hearsSqueezes)
        bench.app.tool = .select
        #expect(!router.hearsSqueezes)
        // The pen coming near gets nothing ready either.
        bench.pencil.hovered()
        for point in [Bench.overButton, Bench.overScreen, Bench.overCanvas] {
            router.began(at: point, azimuth: nil, roll: nil)
            #expect(router.taker == .nobody)
            #expect(bench.pencil.bubble == nil && !bench.pencil.ownsSqueeze)
            bench.now += .milliseconds(200)
            router.ended()
            #expect(bench.pencil.bubble == nil && !bench.pencil.ownsSqueeze)
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call == nil && bench.routes.isEmpty && bench.runner.warmUps == 0)
        #expect(bench.app.selection == nil)
        #expect(bench.runner.commands.isEmpty)
    }

    /// Turned off mid-listen, the listen ends unsent, and nothing is left on screen or
    /// listening: a toggle waiting for the squeeze that sends it, or a squeeze still held.
    @Test func turningSqueezeToTalkOffMidListenStopsListening() async {
        let bench = Bench()
        #expect(await bench.toggle())
        #expect(await bench.hear("make it blue"))
        bench.app.squeezesToTalk = false
        #expect(bench.pencil.bubble == nil && bench.routes[0].isStopped)
        // The squeeze that would have sent it is the system's now.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeEnded()
        #expect(bench.pencil.bubble == nil && bench.routes[0].finishCount == 0)

        // Back on, a held squeeze listens, and turning it off again lets go of that too.
        bench.app.squeezesToTalk = true
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening && bench.routes.count == 2 })
        bench.app.squeezesToTalk = false
        #expect(bench.pencil.bubble == nil && bench.routes[1].isStopped)
        // Its end, should it still come, sends nothing.
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        #expect(bench.routes[1].finishCount == 0)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.isEmpty && bench.pencil.bubble == nil)
        bench.end()
    }

    /// Turned off, the pencil's call goes too, once it has nothing left to finish: the
    /// next squeeze, with it back on, starts another.
    @Test func turningSqueezeToTalkOffEndsThePencilsCall() async throws {
        let bench = Bench()
        bench.pencil.hovered()
        #expect(await eventually { bench.runner.warmUps == 1 })
        #expect(bench.pencil.call != nil)
        bench.app.squeezesToTalk = false
        #expect(await eventually { bench.pencil.call == nil })

        // A command still running when it goes off is left to finish, and then the call ends.
        bench.app.squeezesToTalk = true
        bench.runner.holds = true
        #expect(await bench.hold())
        // The new call's route: each call gets one ready as it starts.
        try #require(bench.routes.last).send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        bench.app.squeezesToTalk = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call != nil)
        bench.runner.holds = false
        #expect(await eventually { bench.pencil.call == nil })

        // Back on, a squeeze starts a call of its own.
        bench.app.squeezesToTalk = true
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening && bench.pencil.call != nil })
        bench.end()
    }

    /// The window's squeeze router gives the scrubber every squeeze over a number field, and
    /// leaves one to the pencil only while the pencil owns it. Off, the pencil owns none.
    @Test func withSqueezeToTalkOffTheScrubberHasEverySqueeze() async {
        let bench = Bench()
        #expect(await bench.toggle())
        #expect(await bench.hear("make it blue"))
        // The squeeze that sends, still held when the setting goes off.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(bench.pencil.ownsSqueeze)
        bench.app.squeezesToTalk = false
        #expect(!bench.pencil.ownsSqueeze)
        bench.pencil.squeezeEnded()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(!bench.pencil.ownsSqueeze)
        bench.pencil.squeezeEnded()
        #expect(!bench.pencil.ownsSqueeze)
        bench.end()
    }

    /// The system's own squeeze setting comes first: turned off, or running a shortcut,
    /// the squeeze isn't Layer's, and the pen hovering gets nothing ready for one.
    @Test func theSystemsSqueezeSettingComesFirst() async {
        #expect(PencilVoice.systemKeepsSqueeze(.ignore))
        #expect(PencilVoice.systemKeepsSqueeze(.runSystemShortcut))
        for action: UIPencilPreferredAction in [.switchEraser, .switchPrevious, .showColorPalette, .showInkAttributes, .showContextualPalette] {
            #expect(!PencilVoice.systemKeepsSqueeze(action))
        }
        let bench = Bench()
        bench.pencil.squeezeIsOff = { true }
        bench.pencil.hovered()
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.bubble == nil && bench.pencil.call == nil && bench.routes.isEmpty)
    }
}

/// The window's one squeeze handler, which decides once per squeeze who has it: a ruler
/// (a field's or the zoom's), push-to-talk, or nobody. SwiftUI calls every visible view's
/// squeeze action, in no fixed order, so two handlers could both act on one squeeze.
@Suite("Routing Apple Pencil Pro's squeeze", .serialized)
@MainActor
struct SqueezeRouterTests {
    /// The W field of a Format panel at the window's top left, where a pen at (100, 100) is
    /// over the panel.
    private func field(on bench: Bench) -> Scrubber.Target {
        bench.app.chromeFrames["format"] = CGRect(x: 0, y: 0, width: 300, height: 600)
        return ScrubbedField(10).target("W", at: .zero, range: 0...100)
    }

    private let overField = CGPoint(x: 100, y: 100)

    @Test func aSqueezeOverAHoveredFieldBringsUpItsRulerNotTheBubble() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        #expect(router.taker == .ruler)
        router.ended()
        scrubber.end()
        bench.end()
    }

    /// Review focus 1: the squeeze that keeps a ruler's value, with the pen drifted over the
    /// canvas, puts the ruler away and does nothing else.
    @Test func theSqueezeThatKeepsAValueStartsNothingElse() async {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.begin(field(on: bench))
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        router.ended()
        #expect(scrubber.target == nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        #expect(bench.app.selection == nil)
        bench.end()
    }

    @Test func aSqueezeOverTheCanvasListens() async {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        #expect(router.taker == .voice)
        #expect(await eventually { bench.state == .listening })
        bench.now += .seconds(1)
        router.ended()
        #expect(bench.routes[0].finishCount == 1)
        #expect(router.taker == nil)
        bench.end()
    }

    /// A toggle left listening is sent by the next squeeze, even with the pen over a field.
    @Test func aToggleListeningIsSentWhereverThePenIs() async {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        bench.now += .milliseconds(200)
        router.ended()
        #expect(await eventually { bench.state == .listening })
        scrubber.hovered = field(on: bench)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(bench.routes[0].finishCount == 1)
        #expect(scrubber.target == nil)
        #expect(router.taker == .voice)
        router.ended()
        bench.end()
    }

    /// A squeeze's `.active` comes every 10–20 ms while it lasts: only the first acts.
    @Test func oneSqueezesRepeatedStartsActOnce() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        for _ in 0..<3 { router.began(at: overField, azimuth: nil, roll: .degrees(0)) }
        #expect(scrubber.target?.label == "W")
        router.ended()
        scrubber.end()
        bench.end()
    }

    /// Off, a squeeze is the system's, except over a field (or the zoom) or with a ruler up:
    /// the handler is there only then.
    @Test func withSqueezeToTalkOffOnlyARulerTakesASqueeze() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        bench.app.squeezesToTalk = false
        #expect(!router.talks && !router.hearsSqueezes)
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        #expect(router.taker == .nobody)
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        router.ended()

        scrubber.hovered = field(on: bench)
        #expect(router.hearsSqueezes)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        #expect(router.taker == .ruler)
        bench.app.tool = .draw
        #expect(!router.hearsSqueezes)
        bench.end()
    }

    @Test func theHandlerIsThereOnlyWhileDrawIsOffAndSomethingWouldTakeIt() {
        #expect(!SqueezeRouter.wantsHandler(drawIsOn: true, talks: true, rulerWantsSqueeze: true))
        #expect(SqueezeRouter.wantsHandler(drawIsOn: false, talks: true, rulerWantsSqueeze: false))
        #expect(!SqueezeRouter.wantsHandler(drawIsOn: false, talks: false, rulerWantsSqueeze: false))
        #expect(SqueezeRouter.wantsHandler(drawIsOn: false, talks: false, rulerWantsSqueeze: true))
    }

    /// Review focus 2: a field's hover left behind when its panel went isn't taken for a
    /// field under a squeeze over the canvas.
    @Test func aHoverLeftByAFieldThatWentAwayIsntARuler() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        #expect(scrubber.target == nil && scrubber.hovered == nil)
        #expect(bench.pencil.bubble != nil)
        router.ended()
        bench.end()
    }

    @Test func aHoverLeftBehindWithThePenOutOfRangeIsntARulerEither() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        router.began(at: nil, azimuth: nil, roll: nil)
        #expect(scrubber.target == nil && scrubber.hovered == nil)
        #expect(router.taker == .voice)
        // Push-to-talk starts nothing with the pen out of range.
        #expect(bench.pencil.bubble == nil)
        router.ended()
        bench.end()
    }

    @Test func drawComingOnPutsAPencilRulerAway() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target != nil)
        bench.app.tool = .draw
        #expect(scrubber.target == nil)
        #expect(router.taker == nil)
        bench.end()
    }
}

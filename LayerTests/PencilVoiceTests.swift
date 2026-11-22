import Foundation
import os
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

    /// A change for one screen leaves the selection as it is when it starts: its scope is
    /// its own, and the screen was selected when it was typed or held for. Selected again,
    /// it would take away whatever field the person has moved on to (final review I1).
    @Test func aChangeForAScreenLeavesTheSelectionAsItIs() async {
        let bench = Bench()
        #expect(await bench.toggle())
        bench.pencil.call?.captionTimes = (.milliseconds(100), .milliseconds(100))
        #expect(bench.app.selection == bench.button)
        #expect(bench.pencil.call?.submit("make it blue", about: .screenEdit(UUID())) != nil)
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(bench.app.selection == bench.button)
        #expect(bench.pencil.call?.submit("make it green", about: .screenEdit(bench.screen)) != nil)
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it green"] })
        #expect(bench.app.selection == bench.button)
        bench.pencil.tapBubble()
        bench.end()
    }

    /// The scenario of final review I1: a change typed for Login waits behind a spoken
    /// command, the person selects Profile and starts on its field, and Login's change
    /// starts. Profile stays selected, so its field, and a hold or words typed there, stay
    /// too. A spoken command about a thing still selects it as it starts: the agent reads
    /// what was pointed at from the selection.
    @Test func aQueuedChangeForLoginLeavesProfileSelected() async {
        let bench = Bench()
        let profile = bench.app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 4600, y: 4000), scale: 0.6)).id
        bench.runner.holds = true
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(bench.app.selection == bench.button)
        // Typed in Login's field while that runs.
        bench.app.selection = .screen(bench.screen)
        #expect(await bench.pencil.submit("make it dark", about: .screenEdit(bench.screen)) != nil)
        // Then Profile, whose field is held.
        bench.app.selection = .screen(profile)
        bench.pencil.holdBegan(about: profile, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        bench.runner.holds = false
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it dark"] })
        #expect(bench.runner.targets.last == .screenEdit(bench.screen))
        #expect(bench.app.selection == .screen(profile))
        #expect(bench.state == .listening && bench.routes[1].finishCount == 0)
        bench.pencil.holdEnded()
        #expect(bench.routes[1].finishCount == 1)
        bench.end()
    }

    // MARK: A screen's field

    /// Pressing and holding a screen's field listens for a change to that screen, with
    /// push-to-talk's bubble at the field, and letting go sends it.
    @Test func holdingTheFieldListensAboutItsScreenAndLettingGoSends() async {
        let bench = Bench()
        let screen = bench.screen
        bench.pencil.holdBegan(about: screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        #expect(bench.app.selection == .screen(screen))
        #expect(bench.pencil.bubble?.anchor == CGPoint(x: 500, y: 300))
        bench.pencil.holdEnded()
        #expect(bench.routes[0].finishCount == 1)
        bench.routes[0].send(.command("make it dark"))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        #expect(bench.runner.targets == [.screenEdit(screen)])
        bench.end()
    }

    /// Holding the field isn't a squeeze: neither Squeeze to Talk, nor the system's squeeze
    /// setting, nor Draw has a say in it.
    @Test func holdingTheFieldIsntASqueeze() async {
        let bench = Bench()
        bench.pencil.squeezeIsOff = { true }
        bench.app.tool = .draw
        bench.app.squeezesToTalk = false
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        bench.pencil.holdEnded()
        #expect(bench.routes[0].finishCount == 1)
        bench.end()
    }

    /// A Pencil squeeze while a finger holds the field is the squeeze's own: it neither
    /// turns the hold into a toggle nor sends or drops it, whether it ends or fails.
    @Test func aSqueezeDuringAHoldLeavesItListening() async {
        let bench = Bench()
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.now += .milliseconds(100)
        bench.pencil.squeezeEnded()
        #expect(bench.state == .listening && !bench.pencil.ownsSqueeze)
        #expect(bench.routes[0].finishCount == 0)
        #expect(bench.app.selection == .screen(bench.screen))
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        bench.pencil.squeezeFailed()
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        bench.pencil.holdEnded()
        #expect(bench.routes[0].finishCount == 1)
        bench.end()
    }

    /// Squeeze to Talk going off leaves a hold listening, and its call up: its command and
    /// its reply need it.
    @Test func turningSqueezeToTalkOffLeavesAHoldListening() async {
        let bench = Bench()
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        bench.app.squeezesToTalk = false
        #expect(bench.state == .listening && !bench.routes[0].isStopped)
        #expect(bench.pencil.call != nil)
        bench.pencil.holdEnded()
        #expect(bench.routes[0].finishCount == 1)
        bench.routes[0].send(.command("make it dark"))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        bench.end()
    }

    /// With this window's phone call up, the call hears everything: holding the field only
    /// says what the next command is about, as a squeeze does.
    @Test func holdingDuringAPhoneCallOnlySelects() async {
        let bench = Bench()
        await bench.app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(bench.app.selection == .screen(bench.screen))
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        #expect(bench.pencil.retarget?.point == CGPoint(x: 500, y: 300))
        bench.pencil.holdEnded()
        #expect(bench.pencil.bubble == nil && bench.routes.isEmpty)
        bench.end()
    }

    /// A phone call in another window has the microphone, and its commands are about that
    /// window's design: holding the field here does nothing.
    @Test func holdingDuringAnotherWindowsCallDoesNothing() async {
        let bench = Bench()
        bench.pencil.phoneCallIsUp = { true }
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        bench.pencil.holdEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call == nil && bench.routes.isEmpty && bench.pencil.bubble == nil)
        #expect(bench.app.selection == nil && bench.pencil.retarget == nil)
    }

    /// The field a finger holds goes away before the finger lets go: its screen deselected,
    /// locked or deleted, or the bar hidden. Nobody said the change was over, so nothing
    /// heard is sent, the microphone goes off, and the bubble says nothing was sent. The
    /// hold's end, should it still come, sends nothing either (final review I1).
    @Test func aHoldWhoseFieldWentAwaySendsNothing() async {
        let bench = Bench()
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        #expect(await bench.hear("make the title"))
        bench.pencil.holdLost()
        #expect(bench.routes[0].finishCount == 0 && bench.routes[0].isStopped)
        #expect(!bench.pencil.isListening && bench.pencil.call?.isListeningAsAsked != true)
        #expect(bench.state == .problem(PencilVoice.holdLost))
        bench.pencil.holdEnded()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.isEmpty && bench.routes[0].finishCount == 0)
        #expect(bench.pencil.call?.settling.isEmpty != false)
        // A squeeze's listen isn't a field's to lose.
        #expect(await bench.toggle())
        bench.pencil.holdLost()
        #expect(bench.state == .listening && !bench.routes[1].isStopped)
        bench.pencil.tapBubble()
        bench.end()
    }

    /// One listen at a time: a second hold while one listens is the same one.
    @Test func aSecondHoldWhileListeningIsIgnored() async {
        let bench = Bench()
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 600, y: 300))
        #expect(await eventually { bench.state == .listening })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.routes.count == 1)
        #expect(bench.pencil.bubble?.anchor == CGPoint(x: 500, y: 300))
        bench.end()
    }

    /// A finger let go of the field before the microphone came on. A hold gets no Pencil
    /// tap to wait for, so it is told to keep holding rather than to wait for the tap:
    /// whether the call was still getting ready or the microphone was coming on.
    @Test func aHoldLetGoBeforeTheMicrophoneIsOnSaysToKeepHolding() async {
        let hold = PencilVoice.State.problem(PencilVoice.tooSoonForAHold)
        #expect(PencilVoice.tooSoonForAHold != VoiceCall.tooSoon)
        // The microphone coming on.
        let bench = Bench()
        bench.routesHoldStart = true
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.routes.count == 1 })
        bench.pencil.holdEnded()
        #expect(await eventually { bench.state == hold })
        #expect(bench.runner.commands.isEmpty)
        bench.end()
        // The call still getting ready.
        let slow = SlowWarmingRunner()
        let ready = Bench(runner: slow)
        ready.pencil.holdBegan(about: ready.screen, at: CGPoint(x: 500, y: 300))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(ready.state == .gettingReady)
        ready.pencil.holdEnded()
        #expect(ready.state == hold)
        slow.holdsWarmUp = false
        ready.end()
        // A squeeze's line is still the squeeze's.
        let squeeze = Bench()
        squeeze.routesHoldStart = true
        squeeze.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { squeeze.routes.count == 1 })
        squeeze.now += .seconds(1)
        squeeze.pencil.squeezeEnded()
        #expect(await eventually { squeeze.state == .problem(VoiceCall.tooSoon) })
        squeeze.end()
    }

    /// A squeeze listening keeps the microphone: a hold then is ignored, and its end sends
    /// nothing of the squeeze's, held or toggled.
    @Test func aHoldsEndLeavesASqueezesListenAlone() async {
        let bench = Bench()
        // A squeeze still held.
        bench.pencil.squeezeBegan(at: Bench.overButton, azimuth: nil)
        #expect(await eventually { bench.state == .listening })
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        bench.pencil.holdEnded()
        #expect(bench.state == .listening && bench.routes[0].finishCount == 0)
        #expect(bench.app.selection == bench.button)
        // Its own end sends it.
        bench.now += .seconds(1)
        bench.pencil.squeezeEnded()
        #expect(bench.routes[0].finishCount == 1)

        // A toggle.
        #expect(await bench.toggle())
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        bench.pencil.holdEnded()
        #expect(bench.state == .listening && bench.routes[1].finishCount == 0)
        #expect(bench.pencil.ownsSqueeze)
        bench.end()
    }

    /// One microphone at a time, in every window: holding the field stops a pencil listening
    /// in another, which sends nothing.
    @Test func holdingTheFieldStopsAPencilListeningInAnotherWindow() async {
        let bench = Bench()
        let other = Bench()
        bench.pencil.otherWindows = { [other.app] }
        #expect(await other.toggle())
        #expect(await other.hear("make it"))
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(other.routes[0].isStopped && other.pencil.bubble == nil)
        #expect(await eventually { bench.state == .listening })
        #expect(other.runner.commands.isEmpty)
        other.end()
        bench.end()
    }

    /// Typed words go through the pencil's call, about the screen, without the microphone.
    @Test func typedWordsGoThroughThePencilsCall() async {
        let bench = Bench()
        let number = await bench.pencil.submit("make the title red", about: .screenEdit(bench.screen))
        #expect(number != nil)
        #expect(await eventually { bench.runner.commands == ["make the title red"] })
        #expect(bench.runner.targets == [.screenEdit(bench.screen)])
        // The selection is left as it was: the change's screen goes with it.
        #expect(bench.app.selection == nil)
        #expect(!bench.routes.contains { $0.wasStarted })
        #expect(await bench.pencil.submit("   ", about: .screenEdit(bench.screen)) == nil)
        bench.end()
    }

    /// Typed words wait their turn behind a command spoken a moment earlier (Review Focus 5).
    @Test func typedWordsWaitTheirTurnBehindAHeldCommand() async {
        let bench = Bench()
        bench.runner.holds = true
        #expect(await bench.hold())
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue"] })
        #expect(await bench.pencil.submit("make it red", about: .screenEdit(bench.screen)) != nil)
        #expect(bench.pencil.call?.queuedCount == 1)
        bench.runner.holds = false
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red"] })
        bench.end()
    }

    /// A command spoken a moment earlier whose words are still settling was given first, and
    /// goes first: typed words wait for it, and go anyway when it turns out to be nothing.
    @Test func typedWordsWaitBehindASpokenCommandStillSettling() async {
        let bench = Bench()
        #expect(await bench.hold())
        #expect(bench.pencil.call?.settling.isEmpty == false)
        let typed = Task { await bench.pencil.submit("make it red", about: .screenEdit(bench.screen)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.isEmpty && bench.pencil.call?.queuedCount == 0)
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red"] })
        #expect(await typed.value != nil)

        // Nothing heard: the typed words don't wait on it any longer.
        #expect(await bench.hold())
        let next = Task { await bench.pencil.submit("make it green", about: .screenEdit(bench.screen)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.count == 2)
        bench.routes[1].send(.nothingHeard)
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red", "make it green"] })
        #expect(await next.value != nil)
        bench.end()
    }

    /// A typed change keeps the pencil's call until its reply has shown, though Squeeze to
    /// Talk goes off while it runs: the field shows that reply.
    @Test func aTypedChangeKeepsItsCallUntilItsReplyHasShown() async {
        let bench = Bench()
        bench.pencil.prepare()
        #expect(await eventually { bench.pencil.call?.phase == .listening })
        bench.pencil.call?.captionTimes = (.seconds(1), .seconds(1))
        bench.runner.holds = true
        let number = await bench.pencil.submit("make it red", about: .screenEdit(bench.screen))
        #expect(await eventually { bench.runner.commands == ["make it red"] })
        bench.app.squeezesToTalk = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call != nil)
        bench.runner.holds = false
        #expect(await eventually { bench.pencil.call?.caption?.kind == .done && bench.pencil.call?.caption?.command == number })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(bench.pencil.call?.caption?.command == number)
        // Once it has shown, the call goes, as Squeeze to Talk going off asked.
        #expect(await eventually { bench.pencil.call == nil })
        bench.end()
    }

    /// A held change keeps the call until its reply has shown, in the same way.
    @Test func aHeldChangeKeepsItsCallUntilItsReplyHasShown() async {
        let bench = Bench()
        bench.runner.holds = true
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        bench.pencil.call?.captionTimes = (.seconds(1), .seconds(1))
        bench.pencil.holdEnded()
        bench.routes[0].send(.command("make it dark"))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        bench.app.squeezesToTalk = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call != nil && bench.state == .working)
        bench.runner.holds = false
        #expect(await eventually { bench.state == .done })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(bench.pencil.call != nil && bench.state == .done)
        #expect(await eventually { bench.pencil.call == nil && bench.pencil.bubble == nil })
        bench.end()
    }

    /// Typed words still waiting on the call to get ready keep it, though Squeeze to Talk
    /// goes off meanwhile.
    @Test func typedWordsWaitingOnTheCallKeepIt() async {
        let runner = SlowWarmingRunner()
        let bench = Bench(runner: runner)
        let typed = Task { await bench.pencil.submit("make it red", about: .screenEdit(bench.screen)) }
        #expect(await eventually { bench.pencil.call != nil })
        bench.app.squeezesToTalk = false
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.pencil.call != nil)
        runner.holdsWarmUp = false
        #expect(await typed.value != nil)
        #expect(await eventually { runner.commands == ["make it red"] })
        bench.end()
    }

    /// The field coming up gets the model ready, once, without the microphone. A phone call
    /// up stops it, as it stops a hover; Squeeze to Talk and the system's setting don't.
    @Test func preparingGetsTheModelReadyOnce() async {
        let bench = Bench()
        bench.pencil.prepare()
        bench.pencil.prepare()
        #expect(await eventually { bench.runner.warmUps == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.warmUps == 1 && !bench.routes.contains { $0.wasStarted })
        bench.end()

        let duringACall = Bench()
        duringACall.pencil.phoneCallIsUp = { true }
        duringACall.pencil.prepare()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(duringACall.pencil.call == nil && duringACall.runner.warmUps == 0)

        let squeezeOff = Bench()
        squeezeOff.app.squeezesToTalk = false
        squeezeOff.pencil.squeezeIsOff = { true }
        squeezeOff.app.tool = .draw
        squeezeOff.pencil.prepare()
        #expect(await eventually { squeezeOff.runner.warmUps == 1 })
        squeezeOff.end()
    }

    /// Whether the pencil is listening, for VoiceOver's "Speak a change", whose second use sends.
    @Test func isListeningFollowsAHeldListen() async {
        let bench = Bench()
        #expect(!bench.pencil.isListening)
        bench.pencil.holdBegan(about: bench.screen, at: CGPoint(x: 500, y: 300))
        #expect(await eventually { bench.state == .listening })
        #expect(bench.pencil.isListening)
        bench.pencil.holdEnded()
        #expect(!bench.pencil.isListening)
        bench.end()
    }

    /// A typed change's reply is its own line, which can outlast the call's caption when
    /// the next command takes that at once: Squeeze to Talk going off ends the call only
    /// once the reply has gone too.
    @Test func aFieldsReplyKeepsTheCallThoughTheCaptionHasMovedOn() async throws {
        let bench = Bench()
        bench.pencil.prepare()
        #expect(await eventually { bench.pencil.call?.phase == .listening })
        let call = try #require(bench.pencil.call)
        call.captionTimes = (done: .milliseconds(100), problem: .milliseconds(1500))
        bench.runner.holds = true
        bench.runner.outcomes = [VoiceOutcome(problem: "No connection."), VoiceOutcome(lines: ["Done"])]
        let first = try #require(await bench.pencil.submit("make it red", about: .screenEdit(bench.screen)))
        let second = try #require(await bench.pencil.submit("make it blue", about: .screenEdit(bench.screen)))
        #expect(await eventually { bench.runner.commands == ["make it red"] })
        bench.app.squeezesToTalk = false
        bench.runner.holds = false
        #expect(await until { call.progress(of: second) == .done("Done") || call.phase == .ended })
        // The second's reply has come and gone; the first's problem is still shown.
        #expect(await until { call.caption == nil || call.phase == .ended })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(bench.pencil.call === call)
        #expect(call.progress(of: first) == .problem("No connection."))
        // Once it has gone, so does the call, as Squeeze to Talk going off asked.
        #expect(await until { bench.pencil.call == nil })
        bench.end()
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
        for _ in 0..<4 {
            router.began(at: overField, azimuth: nil, roll: .degrees(0))
            // Not put away by the second, nor brought up again by the third.
            #expect(scrubber.target?.label == "W")
        }
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
        // A squeeze under way keeps it until it ends, except in Draw.
        #expect(SqueezeRouter.wantsHandler(drawIsOn: false, talks: false, rulerWantsSqueeze: false, squeezeUnderWay: true))
        #expect(!SqueezeRouter.wantsHandler(drawIsOn: true, talks: false, rulerWantsSqueeze: false, squeezeUnderWay: true))
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

    /// Step 1 is push-to-talk's only with no ruler up: with a finger's ruler up while a toggle
    /// listens, the squeeze keeps the ruler's value and the toggle goes on listening.
    @Test func aRulerUpTakesTheSqueezeThoughAToggleListens() async {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        bench.now += .milliseconds(200)
        router.ended()
        #expect(await eventually { bench.state == .listening })
        scrubber.begin(field(on: bench))
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        #expect(router.taker == .ruler)
        #expect(scrubber.target == nil)
        #expect(bench.routes[0].finishCount == 0 && bench.state == .listening)
        router.ended()
        bench.end()
    }

    /// The handler stays until the squeeze under way ends: with Squeeze to Talk off, the
    /// squeeze that puts a ruler away with the pen off its field would otherwise take the
    /// handler with it, and the same squeeze, brought back as the pen crossed another field,
    /// would bring that field's ruler up.
    @Test func theHandlerStaysForTheWholeSqueeze() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        bench.app.squeezesToTalk = false
        let width = field(on: bench)
        scrubber.hovered = width
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        router.ended()
        // The pen leaves the field: the ruler keeps the handler.
        scrubber.hovered = nil
        #expect(router.hearsSqueezes)

        // The squeeze that keeps the value, over the canvas: the ruler goes, the handler stays.
        router.began(at: Bench.overButton, azimuth: nil, roll: nil)
        #expect(scrubber.target == nil)
        #expect(router.hearsSqueezes)
        // Still squeezed, the pen crosses a field: that squeeze brings no ruler up.
        scrubber.hovered = width
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target == nil)
        scrubber.hovered = nil
        #expect(router.hearsSqueezes)
        // Only its end lets the handler go, and a view reading it hears so.
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking { _ = router.hearsSqueezes } onChange: { changed.withLock { $0 = true } }
        router.ended()
        #expect(!router.hearsSqueezes)
        #expect(changed.withLock { $0 })
        bench.end()
    }

    /// A field's hover goes with the selection it was for: the pen still over the panel
    /// doesn't scrub the element that was selected before.
    @Test func aNewSelectionForgetsTheFieldThePenWasOver() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        bench.app.selection = bench.button
        let width = ScrubbedField(10)
        bench.app.chromeFrames["format"] = CGRect(x: 0, y: 0, width: 300, height: 600)
        scrubber.hovered = width.target("W", at: .zero, range: 0...100)
        bench.app.selection = bench.title
        #expect(scrubber.hovered == nil)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target == nil && width.sets.isEmpty)
        router.ended()
        // A panel ruler up as the selection changes goes too.
        scrubber.begin(width.target("W", at: .zero, range: 0...100))
        bench.app.selection = bench.button
        #expect(scrubber.target == nil)
        bench.end()
    }

    /// A Format field's hover is a field's only while the pen is over the Format panel, not
    /// over other chrome; the zoom's hover is the zoom's over the controls.
    @Test func aFieldsHoverIsAFieldsOnlyOverTheFormatPanel() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        let controls = CGRect(x: 20, y: 700, width: 200, height: 50)
        bench.app.chromeFrames["view controls"] = controls
        scrubber.hovered = field(on: bench)
        router.began(at: CGPoint(x: controls.midX, y: controls.midY), azimuth: nil, roll: nil)
        #expect(scrubber.target == nil && scrubber.hovered == nil)
        router.ended()

        // In a narrow window the panel is a sheet, reported as "panel sheet".
        bench.app.chromeFrames["format"] = nil
        bench.app.chromeFrames["panel sheet"] = CGRect(x: 0, y: 400, width: 800, height: 400)
        scrubber.hovered = ScrubbedField(10).target("W", at: .zero, range: 0...100)
        router.began(at: CGPoint(x: 100, y: 500), azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        router.ended()
        scrubber.end()

        // The zoom's hover, over the controls, brings up the zoom's ruler.
        scrubber.hovered = ZoomStops.target(frame: controls, current: { 1 }, zoom: { _ in })
        router.began(at: CGPoint(x: controls.midX, y: controls.midY), azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.owner == .zoom)
        router.ended()
        scrubber.end()
        bench.end()
    }

    /// The system's Apple Pencil setting comes first for the rulers too: with squeezing
    /// turned off there, or running a shortcut, a squeeze neither brings a ruler up nor puts
    /// one away.
    @Test func theSystemsSqueezeSettingKeepsTheRulersAwayToo() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        bench.pencil.squeezeIsOff = { true }
        scrubber.hovered = field(on: bench)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target == nil)
        #expect(router.taker == .nobody)
        router.ended()
        scrubber.begin(field(on: bench))
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target != nil)
        router.ended()
        scrubber.end()
        bench.end()
    }

    /// A squeeze whose end was lost (the handler torn down, the gesture's end never
    /// delivered) doesn't leave every later squeeze ignored: once its `.active` has stopped
    /// coming for as long as a squeeze can listen, the next squeeze is a new one.
    @Test func aSqueezeWhoseEndWasLostIsOverOnceItsStartsStop() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        router.clock = { [unowned bench] in bench.now }
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        // Its end never comes. A moment later, it is still the same squeeze.
        bench.now += .seconds(1)
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        // After that long, a squeeze is a new one: this one keeps the value.
        bench.now += SqueezeRouter.longestSqueeze
        router.began(at: overField, azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target == nil)
        #expect(router.taker == .ruler)
        router.ended()
        bench.end()
    }

    /// A squeeze held on, whose `.active` keeps coming, is never taken for a new one.
    @Test func aSqueezeHeldOnIsOneSqueezeHoweverLong() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        router.clock = { [unowned bench] in bench.now }
        let scrubber = bench.app.scrubber
        scrubber.hovered = field(on: bench)
        for _ in 0..<200 {
            router.began(at: overField, azimuth: nil, roll: .degrees(0))
            bench.now += .milliseconds(500)
        }
        #expect(scrubber.target?.label == "W")
        router.ended()
        scrubber.end()
        bench.end()
    }

    /// In a narrow window the Format panel is a sheet, and the sheet's handler has the
    /// squeeze rather than the window's: exactly one is there at a time.
    @Test func inANarrowWindowThePanelsSheetHasTheSqueeze() {
        let bench = Bench()
        let router = bench.app.squeezeRouter
        bench.app.isInspectorOpen = true
        #expect(!bench.app.panelIsASheet)
        #expect(router.windowHandlerIsOn && !router.sheetHandlerIsOn)
        bench.app.isCompactSizeClass = true
        #expect(bench.app.panelIsASheet)
        #expect(!router.windowHandlerIsOn && router.sheetHandlerIsOn)
        bench.app.isInspectorOpen = false
        bench.app.isLayersOpen = true
        #expect(bench.app.panelIsASheet && router.sheetHandlerIsOn)
        bench.app.isLayersOpen = false
        #expect(!bench.app.panelIsASheet)
        #expect(router.windowHandlerIsOn && !router.sheetHandlerIsOn)
        // With nothing to take a squeeze, neither is there.
        bench.app.isInspectorOpen = true
        bench.app.squeezesToTalk = false
        #expect(!router.windowHandlerIsOn && !router.sheetHandlerIsOn)
        bench.end()
    }

    /// The sheet's squeeze comes in the sheet's own points: it is put in the window's by the
    /// sheet's place in the window before it is routed.
    @Test func aSqueezeInThePanelsSheetIsInWindowPoints() {
        #expect(SqueezeRouter.windowPoint(CGPoint(x: 100, y: 40), offsetBy: CGPoint(x: 10, y: 500)) == CGPoint(x: 110, y: 540))
        #expect(SqueezeRouter.windowPoint(nil, offsetBy: CGPoint(x: 10, y: 500)) == nil)

        let bench = Bench()
        let router = bench.app.squeezeRouter
        let scrubber = bench.app.scrubber
        #expect(router.sheetOrigin == .zero)
        bench.app.chromeFrames["panel sheet"] = CGRect(x: 0, y: 500, width: 800, height: 400)
        #expect(router.sheetOrigin == CGPoint(x: 0, y: 500))
        // Over a field near the sheet's top: over the sheet in the window, so a field's.
        scrubber.hovered = ScrubbedField(10).target("W", at: .zero, range: 0...100)
        router.began(at: SqueezeRouter.windowPoint(CGPoint(x: 100, y: 40), offsetBy: router.sheetOrigin), azimuth: nil, roll: .degrees(0))
        #expect(scrubber.target?.label == "W")
        router.ended()
        scrubber.end()
        bench.end()
    }
}

/// A selected screen's field, "Describe a change…": what it sends, through the pencil's
/// call, and how each screen's change is getting on, which the field shows in place of
/// the words typed.
@Suite("What a screen's field sends and shows", .serialized)
@MainActor
struct ScreenEditorTests {
    /// A second screen, Profile, to the right of Login.
    private func addProfile(to bench: Bench) -> DesignScreen.ID {
        let profile = bench.app.store.addScreen(.iPhone, at: Placement(origin: CGPoint(x: 4600, y: 4000), scale: 0.6))
        bench.app.store.updateScreen(profile.id) { $0.name = "Profile" }
        return profile.id
    }

    @Test func aChangeShowsItsStepThenItsReplyThenClears() async throws {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        let screen = bench.screen
        bench.runner.holds = true
        #expect(await editor.send("make it dark", to: screen))
        let call = try #require(bench.pencil.call)
        call.captionTimes = (done: .milliseconds(100), problem: .milliseconds(100))
        #expect(editor.isBusy(for: screen))
        guard case .working = editor.progress(for: screen) else {
            Issue.record("a change just sent is on its way")
            return
        }
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        #expect(bench.runner.targets == [.screenEdit(screen)])
        call.showStep("Restyling…")
        #expect(editor.progress(for: screen) == .working("Restyling…"))
        #expect(editor.line(for: screen) == .working("Restyling…"))
        bench.runner.outcomes = [VoiceOutcome(lines: ["Restyled the screen."])]
        bench.runner.holds = false
        #expect(await until { editor.progress(for: screen) == .done("Restyled the screen.") })
        #expect(editor.line(for: screen) == .reply("Restyled the screen."))
        #expect(!editor.isBusy(for: screen))
        #expect(await until { editor.progress(for: screen) == .over })
        #expect(editor.line(for: screen) == nil)
        bench.end()
    }

    @Test func aBlankChangeSendsNothing() async {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        #expect(await !editor.send("  ", to: bench.screen))
        #expect(await !editor.send("\n", to: bench.screen))
        #expect(bench.runner.commands.isEmpty && bench.pencil.call == nil)
        #expect(editor.progress(for: bench.screen) == .over)
    }

    @Test func aSecondChangeToTheSameScreenWaitsForTheFirst() async {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        bench.runner.holds = true
        #expect(await editor.send("make it dark", to: bench.screen))
        #expect(await !editor.send("make it light", to: bench.screen))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.count == 1 && bench.pencil.call?.queuedCount == 0)
        // Once the first is done, its reply showing, the next goes.
        bench.runner.holds = false
        #expect(await until { !editor.isBusy(for: bench.screen) })
        #expect(await editor.send("make it light", to: bench.screen))
        #expect(await eventually { bench.runner.commands == ["make it dark", "make it light"] })
        bench.end()
    }

    /// A change still being sent, waiting on the call to get ready, keeps its screen busy:
    /// a second one isn't sent behind it.
    @Test func aChangeStillBeingSentKeepsItsScreenBusy() async {
        let runner = SlowWarmingRunner()
        let bench = Bench(runner: runner)
        let editor = ScreenEditor(model: bench.app)
        let first = Task { await editor.send("make it dark", to: bench.screen) }
        #expect(await until { editor.isBusy(for: bench.screen) })
        #expect(editor.progress(for: bench.screen) == .working(nil))
        // No step of its own yet: the field says it is under way all the same.
        #expect(editor.line(for: bench.screen) == .working(ScreenEditor.noStepYet))
        #expect(await !editor.send("make it light", to: bench.screen))
        runner.holdsWarmUp = false
        #expect(await first.value)
        #expect(await eventually { runner.commands == ["make it dark"] })
        bench.end()
    }

    @Test func changesToTwoScreensAreFollowedApart() async {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        let second = addProfile(to: bench)
        bench.runner.holds = true
        #expect(await editor.send("make it dark", to: bench.screen))
        #expect(editor.progress(for: second) == .over)
        #expect(editor.isBusy(for: bench.screen) && !editor.isBusy(for: second))
        // The second screen's change waits its turn behind the first's, with no step yet.
        #expect(await editor.send("make it light", to: second))
        #expect(editor.isBusy(for: second))
        #expect(editor.line(for: second) == .working(ScreenEditor.noStepYet))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        bench.pencil.call?.showStep("Restyling…")
        #expect(editor.progress(for: bench.screen) == .working("Restyling…"))
        #expect(editor.progress(for: second) == .working(nil))
        bench.runner.holds = false
        #expect(await eventually { bench.runner.targets == [.screenEdit(bench.screen), .screenEdit(second)] })
        bench.end()
    }

    @Test func theFieldSaysWhyWhenNoModelCanBeAsked() async {
        let bench = Bench(readiness: .unavailable("Turn on Apple Intelligence."))
        let editor = ScreenEditor(model: bench.app)
        #expect(editor.whyUnavailable() == "Turn on Apple Intelligence.")
        #expect(await !editor.send("make it dark", to: bench.screen))
        #expect(bench.pencil.call == nil && bench.runner.commands.isEmpty)
        #expect(editor.progress(for: bench.screen) == .over)
        let ready = Bench()
        #expect(ScreenEditor(model: ready.app).whyUnavailable() == nil)
    }

    /// A screen that has gone, or a design that has closed, takes no change.
    @Test func aGoneScreenOrAClosedDesignTakesNoChange() async {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        let second = addProfile(to: bench)
        bench.app.store.deleteScreen(second)
        #expect(await !editor.send("make it dark", to: second))
        bench.app.close()
        #expect(await !editor.send("make it dark", to: bench.screen))
        #expect(bench.pencil.call == nil && bench.runner.commands.isEmpty)
    }

    /// Words heard for another listen take the call's caption while a change runs: the
    /// field still shows the step its change is on (carried from Task 5).
    @Test func aChangesStepStaysWhileWordsAreHeard() async throws {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        bench.runner.holds = true
        #expect(await editor.send("make it dark", to: bench.screen))
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        bench.pencil.call?.showStep("Restyling…")
        #expect(await bench.toggle())
        #expect(await bench.hear("make the title"))
        #expect(editor.progress(for: bench.screen) == .working("Restyling…"))
        #expect(editor.line(for: bench.screen) == .working("Restyling…"))
        bench.pencil.tapBubble()
        bench.end()
    }

    /// The next change starting the moment one is over takes the call's caption at once:
    /// each field still shows its own change's reply (carried from Task 5).
    @Test func eachChangeKeepsItsOwnReply() async throws {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        let second = addProfile(to: bench)
        bench.runner.holds = true
        #expect(await editor.send("make it dark", to: bench.screen))
        let call = try #require(bench.pencil.call)
        call.captionTimes = (done: .seconds(1), problem: .seconds(1))
        #expect(await editor.send("make it light", to: second))
        bench.runner.outcomes = [VoiceOutcome(lines: ["Restyled Login."]), VoiceOutcome(problem: "No connection.")]
        bench.runner.holds = false
        #expect(await until { editor.progress(for: second) == .problem("No connection.") })
        #expect(editor.line(for: second) == .problem("No connection."))
        #expect(editor.progress(for: bench.screen) == .done("Restyled Login."))
        #expect(await until { editor.progress(for: bench.screen) == .over && editor.progress(for: second) == .over })
        bench.end()
    }

    /// Numbers start again with each call: a change is followed on the call it was sent
    /// on, never by its number on the next, and is over once that call ends (carried from
    /// Task 5).
    @Test func aChangeIsFollowedOnTheCallItWasSentOn() async throws {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        let second = addProfile(to: bench)
        #expect(await editor.send("make it dark", to: bench.screen))
        let call = try #require(bench.pencil.call)
        call.captionTimes = (done: .seconds(30), problem: .seconds(30))
        #expect(await until { editor.progress(for: bench.screen) == .done("Done") })
        call.end()
        #expect(editor.progress(for: bench.screen) == .over)
        // The next call numbers its first command as the last one's was numbered.
        bench.runner.holds = true
        #expect(await editor.send("make it light", to: second))
        #expect(bench.pencil.call !== call)
        #expect(editor.isBusy(for: second))
        #expect(editor.progress(for: bench.screen) == .over)
        bench.end()
    }

    /// A send whose field went away, cancelling the task it was sent from, still waits
    /// its turn behind a command spoken a moment earlier whose words are still settling
    /// (carried from Task 8).
    @Test func aSendCancelledByItsFieldStillWaitsItsTurn() async {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        #expect(await bench.hold())
        #expect(bench.pencil.call?.settling.isEmpty == false)
        let typed = Task { await editor.send("make it red", to: bench.screen) }
        try? await Task.sleep(for: .milliseconds(50))
        typed.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(bench.runner.commands.isEmpty && bench.pencil.call?.queuedCount == 0)
        bench.routes[0].send(.command("make it blue"))
        #expect(await eventually { bench.runner.commands == ["make it blue", "make it red"] })
        #expect(await typed.value)
        bench.end()
    }

    /// Words typed in a screen's field are kept by the design's editor, screen by screen,
    /// not by the field: the field goes whenever its screen stops being selected or the bar
    /// hides, and they are there when it comes back (final review I1, Task 10's minor).
    @Test func aDraftOutlivesItsField() {
        let bench = Bench()
        let editor = bench.app.screenEditor
        let profile = addProfile(to: bench)
        #expect(editor.draft(for: bench.screen).text.isEmpty)
        editor.setDraft("make the title", for: bench.screen)
        // Login's field goes, and Profile's is typed in.
        bench.app.selection = .screen(profile)
        editor.setDraft("add a photo", for: profile)
        // Login's comes back.
        bench.app.selection = .screen(bench.screen)
        #expect(editor.draft(for: bench.screen).text == "make the title")
        #expect(editor.draft(for: profile).text == "add a photo")
        editor.setDraft("", for: profile)
        #expect(editor.draft(for: profile) == ScreenEditor.Draft())
    }

    /// A draft sent clears as it goes, and comes back if it couldn't be sent, unless more
    /// has been typed since; blank, it is cleared and nothing is sent.
    @Test func aDraftIsSentFromTheEditor() async {
        let unavailable = Bench(readiness: .unavailable("Turn on Apple Intelligence."))
        let refused = unavailable.app.screenEditor
        refused.setDraft("make it dark ", for: unavailable.screen)
        let sending = refused.sendDraft(for: unavailable.screen)
        #expect(refused.draft(for: unavailable.screen).text.isEmpty && refused.draft(for: unavailable.screen).isSending)
        #expect(await sending?.value == false)
        #expect(refused.draft(for: unavailable.screen) == ScreenEditor.Draft(text: "make it dark "))

        let bench = Bench()
        let editor = bench.app.screenEditor
        editor.setDraft("make it dark", for: bench.screen)
        let sent = editor.sendDraft(for: bench.screen)
        #expect(await sent?.value == true)
        #expect(editor.draft(for: bench.screen) == ScreenEditor.Draft())
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        editor.setDraft("  ", for: bench.screen)
        #expect(editor.sendDraft(for: bench.screen) == nil)
        #expect(editor.draft(for: bench.screen) == ScreenEditor.Draft())
        bench.end()
    }

    /// The design's field model, made once.
    @Test func theDesignHasOneScreenEditor() {
        let bench = Bench()
        #expect(bench.app.screenEditor === bench.app.screenEditor)
    }
}

/// What is typed in a screen's field, as it is sent.
@MainActor
struct ScreenEditFieldTests {
    /// Sent, the field clears; a change that couldn't be sent puts its words back, rather
    /// than leaving the field blank and the words lost.
    @Test func aChangeThatCouldNotBeSentIsPutBack() async throws {
        let bench = Bench(readiness: .unavailable("Turn on Apple Intelligence."))
        let editor = ScreenEditor(model: bench.app)
        var draft = ScreenEditor.Draft()
        draft.text = "make it dark "
        let taken = draft.takeForSending()
        let words = try #require(taken)
        #expect(words == "make it dark")
        #expect(draft.text.isEmpty && draft.isSending)
        draft.sendEnded(await editor.send(words, to: bench.screen))
        #expect(draft.text == "make it dark " && !draft.isSending)
    }

    @Test func aChangeSentLeavesTheFieldClear() async throws {
        let bench = Bench()
        let editor = ScreenEditor(model: bench.app)
        var draft = ScreenEditor.Draft()
        draft.text = "make it dark"
        let taken = draft.takeForSending()
        let words = try #require(taken)
        draft.sendEnded(await editor.send(words, to: bench.screen))
        #expect(draft.text.isEmpty && !draft.isSending)
        #expect(await eventually { bench.runner.commands == ["make it dark"] })
        bench.end()
    }

    /// Blank words aren't sent, and leave nothing in the field.
    @Test func blankWordsAreNotSent() {
        var draft = ScreenEditor.Draft()
        draft.text = "  \n"
        let taken = draft.takeForSending()
        #expect(taken == nil)
        #expect(draft.text.isEmpty && !draft.isSending)
    }

    /// Words typed while a change was being sent aren't replaced by its words.
    @Test func wordsTypedSinceStay() {
        var draft = ScreenEditor.Draft()
        draft.text = "make it dark"
        let taken = draft.takeForSending()
        #expect(taken == "make it dark")
        draft.text = "make it light"
        draft.sendEnded(false)
        #expect(draft.text == "make it light")
    }
}

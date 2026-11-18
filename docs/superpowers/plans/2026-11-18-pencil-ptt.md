# Pencil push-to-talk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Squeezing an Apple Pencil Pro while hovering opens a voice bubble at the tip that edits the hovered thing or makes new screens. Typed screen generation moves into the library's search, which now shows results from every tab at once.

**Architecture:** `VoiceCall` learns a second listening style, `.onRequest`, where listening is opened per squeeze with a fresh route that only ends a command when told to (`finish()`), and each queued command carries its target. A new `PencilVoice` controller on `AppModel` turns squeeze phases into listen/send/cancel, captures targets, places the bubble, and owns one warm pencil call per design. The library gets mixed search and a generate empty state, and the wand goes.

**Tech Stack:** Swift 6, SwiftUI (`onPencilSqueeze`, `PencilHoverPose`), UIKit (`UIPencilInteraction`, `UICanvasFeedbackGenerator`), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-18-pencil-ptt-design.md`

## Global Constraints

- Work in `.claude/worktrees/pencil-ptt` on `feature/pencil-ptt`. Simulator: "Layer iPad Pro 11 (pencil-ptt)" `D46460E1-5CC0-42B2-B134-D5C21174380D`.
- Unit tests: `xcodebuild -project Layer.xcodeproj -scheme Layer -testPlan CI -destination "platform=iOS Simulator,id=D46460E1-5CC0-42B2-B134-D5C21174380D" -only-testing:LayerTests/<Suite> test`.
- Run `xcodegen generate` after adding or removing files, and commit `Layer.xcodeproj`.
- Callbacks from system frameworks off the main thread are made in `nonisolated` functions and marked `@Sendable` (the device crash on main-actor closures handed to `AVAudioEngine`).
- The microphone is on only between a squeeze and its send or cancel. Hovering never turns it on.
- A running command is never cancelled by a new squeeze or by a phone call starting.
- Values from the spec: quick/hold threshold 0.35 s; toggle silence timeout 20 s; bubble words at most two lines; words toggle off by default.
- Code comments follow the codebase's plain-English, "why"-first style.

## Review Focus

1. **A squeeze while a pencil command is running:** the new command queues and the running one finishes on its own target. Pinned in Task 4 (`queuedCommandRunsOnItsOwnTarget`).
2. **A toggle left open while the pen drifts out of range:** the second squeeze sends with no hover pose. Pinned in Task 5 (`theSecondSqueezeSendsWithoutAHoverPose`).
3. **A thinking pause in a held squeeze:** nothing is sent until release. Pinned in Task 3 (`aPauseDoesNotEndACommandWhenOnlyFinishDoes`).
4. **A squeeze during a phone-button call:** it retargets with no second microphone. Pinned in Task 5 (`aSqueezeDuringACallOnlyRetargets`).
5. **A library search matching nothing but a symbol name** ("cloud.sun.rain"): the Icons group shows it, and generate isn't offered. Pinned in Task 2 (`aSymbolNameIsAMatchNotAScreen`).

---

### Task 1: Device check, does squeeze reach the canvas in select mode?

The one unknown that could change the build: whether PencilKit's squeeze-to-palette takes the squeeze when Draw is off.

**Files:**
- Modify: `Layer/Canvas/CanvasScreen.swift` (temporary `.onPencilSqueeze` logging to `VoiceLog.log`)

- [ ] **Step 1:** Add `.onPencilSqueeze { phase in VoiceLog.log.info("squeeze: \(String(describing: phase))") }` on the canvas `ZStack`, plus a log of `UIPencilInteraction.preferredSqueezeAction`.
- [ ] **Step 2:** Build Release for "AKS Mini" and install (commands in the device-install memory). Launch with the console attached, logging to the scratchpad.
- [ ] **Step 3:** Ask the user to squeeze, with Draw off, over a screen, over the canvas, and with Draw on. Expected: log lines for the Draw-off squeezes, and no palette popping up at the tip with Draw off. If the palette appears, the fix (for example, resigning the canvas as first responder while Draw is off) becomes part of Task 6, and the finding is recorded in the spec.
- [ ] **Step 4:** Remove the logging. Nothing is committed from this task except a line in the spec's Constraints recording the result.

If the iPad isn't reachable, note it, carry on, and run this check as part of Task 8.

---

### Task 2: Mixed library search, generate empty state, and the wand goes

**Files:**
- Modify: `Layer/Chrome/AssetLibrary.swift` (search API and `AssetLibraryView`)
- Modify: `Layer/Chrome/TopBar.swift` (drop the wand from `ToolsBar` and `ToolsMenu`; `LibraryPopover` passes a generate action)
- Modify: `Layer/Chrome/GenerateScreenPanel.swift` (delete `GenerateScreenPanel`; keep `GenerationStatus`)
- Test: `LayerTests/AssetLibraryTests.swift`

**Interfaces:**
- Produces: `AssetLibrary.searchEverywhere(_ search: String) -> [AssetLibrary.ResultGroup]`, with `struct ResultGroup: Equatable { let tab: AssetTab; let assets: [Asset] }`, groups non-empty and ordered by their strongest score. `AssetLibrary.offersGeneration(for search: String) -> Bool`: true when the query has words and `searchEverywhere` is empty.
- Produces: `AssetLibraryView(onPick:onDragStart:onGenerate:)`, with `onGenerate: ((String) -> Void)?`. When nil, the empty state keeps today's text.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func macFindsTheIconAndTheWireframes() {
    let groups = AssetLibrary.searchEverywhere("mac")
    #expect(groups.contains { $0.tab == .icons && !$0.assets.isEmpty })
    #expect(groups.contains { $0.tab == .wireframes && !$0.assets.isEmpty })
    #expect(groups.allSatisfy { !$0.assets.isEmpty })
}
@Test func groupsAreOrderedByTheirStrongestMatch() {
    // "toggle" is a component by name, and only a term elsewhere.
    #expect(AssetLibrary.searchEverywhere("toggle").first?.tab == .components)
}
@Test func aSentenceWithNoMatchOffersAScreen() {
    #expect(AssetLibrary.searchEverywhere("a checkout screen with apple pay and a summary").isEmpty)
    #expect(AssetLibrary.offersGeneration(for: "a checkout screen with apple pay and a summary"))
    #expect(!AssetLibrary.offersGeneration(for: "   "))
}
@Test func aSymbolNameIsAMatchNotAScreen() {
    #expect(AssetLibrary.searchEverywhere("cloud.sun.rain").first?.tab == .icons)
    #expect(!AssetLibrary.offersGeneration(for: "cloud.sun.rain"))
}
```

- [ ] **Step 2:** Run `-only-testing:LayerTests/AssetLibraryTests`. Expected: FAIL, `searchEverywhere` not defined.
- [ ] **Step 3:** Implement `searchEverywhere` and `offersGeneration`, reusing `matching(_:in:)` per tab and `topScore` for the order (the custom symbol counts as the Icons group's score, as `bestMatch` scores it).
- [ ] **Step 4:** Rework `AssetLibraryView`:
  - While searching, show one section per group (header = `tab.title` plus the count) instead of the tab's results. Remove the `onChange(of: search)` tab jump.
  - Return places the first asset of the first group.
  - With `offersGeneration` and `onGenerate` set, Return calls `onGenerate(query)`, and the empty area shows the generate empty state:
    - a small diagram in a row: the query in a rounded chip, then an arrow, then a struck-through `square.on.circle` labelled "No component", then an arrow, then a phone-frame drawing labelled "New screen";
    - under it, "Press Return to generate this screen with <model name>";
    - a prominent "Generate Screen" button (`wand.and.sparkles`).
  - The view reads `AppModel` from the environment for the model's name and `isGenerating`. While generating, the button is disabled and the text reads "A screen is being written. Stop it, or wait for it to finish, to start another."
- [ ] **Step 5:** In `TopBar.swift`, remove the wand `ToolButton`, its `isGenerating` state, the `ToolsMenu` "Generate Screen" item and its popover. `LibraryPopover` passes `onGenerate: { isPresented = false; model.generateScreen(from: $0) }`. Delete `GenerateScreenPanel`.
- [ ] **Step 6:** Run `AssetLibraryTests` and build. Expected: PASS, and `grep -rn GenerateScreenPanel Layer` is empty.
- [ ] **Step 7:** Launch in the simulator, open the library, and screenshot: "mac" showing two groups, and the generate empty state for a sentence. Check that Return generates a screen.
- [ ] **Step 8:** Commit: "Library: results from every tab, and a search that finds nothing writes a screen; the wand goes".

---

### Task 3: A route that ends a command only when told to

**Files:**
- Modify: `Layer/Voice/VoiceRoute.swift` (`VoiceRoute` protocol, `UtteranceAssembler`)
- Modify: `Layer/Voice/DictationRoute.swift`
- Modify: `LayerTests/VoiceCallTests.swift` (`FakeRoute` gains `finish()`)
- Test: `LayerTests/DictationRouteTests.swift`

**Interfaces:**
- Produces: `VoiceRoute.finish()`: settle what has been heard and emit it as one `.command` (or nothing if no words), then keep running until `stop()`. The protocol extension default does nothing.
- Produces: `UtteranceAssembler(endsOnPause: Bool = true, …)`. With `false`, `next(at:)` never returns `.settle` on its own. `mutating func finishNow(at:)` makes the next `next(at:)` go down the settle path (`.settle`, then `.command` after `settled(at:)`), with the same patience fallback.
- Produces: `DictationRoute(endsOnPause: Bool = true, …)`.

- [ ] **Step 1: Write the failing tests** (assembler-level, driven with explicit instants as the existing `DictationRouteTests` do)

```swift
@Test func aPauseDoesNotEndACommandWhenOnlyFinishDoes() {
    var assembler = UtteranceAssembler(endsOnPause: false)
    let t0 = ContinuousClock.now
    assembler.sound(level: 0.5, at: t0)
    assembler.heard("make the header", isFinal: true, at: t0)
    #expect(assembler.next(at: t0 + .seconds(10)) == .wait)
    assembler.finishNow(at: t0 + .seconds(10))
    #expect(assembler.next(at: t0 + .seconds(10)) == .settle)
    assembler.settled(at: t0 + .seconds(10))
    #expect(assembler.next(at: t0 + .milliseconds(10_300)) == .command("make the header"))
}
@Test func finishWithNothingHeardSendsNothing() {
    var assembler = UtteranceAssembler(endsOnPause: false)
    let t0 = ContinuousClock.now
    assembler.finishNow(at: t0)
    #expect(assembler.next(at: t0 + .seconds(3)) == .wait)
}
```

- [ ] **Step 2:** Run `-only-testing:LayerTests/DictationRouteTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement `endsOnPause` and `finishNow` in `UtteranceAssembler`. Add `finish()` to `VoiceRoute` with a default, and implement it in `DictationRoute` (call `assembler.finishNow(at: .now)`; the existing `tick` loop does the rest). Make `FakeRoute.finish()` record `finishCount += 1`.
- [ ] **Step 4:** Run `DictationRouteTests` and `VoiceCallTests`. Expected: PASS.
- [ ] **Step 5:** Commit: "Voice: a route that ends a command only when told to".

---

### Task 4: A call that listens on request, with a target per command

**Files:**
- Modify: `Layer/Voice/VoiceCall.swift`
- Test: `LayerTests/VoiceCallTests.swift`

**Interfaces:**
- Consumes: `VoiceRoute.finish()` (Task 3).
- Produces:
  - `enum VoiceTarget: Equatable, Sendable { case thing(CanvasSelection); case canvas(CGPoint) }`, where the point is in canvas coordinates.
  - `VoiceCall(listening: .onRequest(makeRoute: @MainActor () -> any VoiceRoute), runner:vocabulary:)` alongside the existing initialiser (which becomes `.continuous(route)`).
  - On an `.onRequest` call:
    - `start()` warms the runner and goes to `.listening` without a route.
    - `func listen(for target: VoiceTarget?) async`: starts a fresh route and stamps its commands with `target`. Calling it again before `send` replaces the route.
    - `func send()`: calls `route.finish()`; the route is stopped once its command arrives, or after 2 s if none does.
    - `func cancelListening()`: stops the route; nothing is queued.
    - `private(set) var isHearing: Bool`: true from the route starting until it stops.
  - `var onCommandStarts: ((VoiceTarget?) -> Void)?`: called just before each queued command runs.
  - The queue becomes `[(text: String, target: VoiceTarget?)]`. `.continuous` calls queue with `target: nil`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func anOnRequestCallListensOnlyWhenAsked() async {
    var routes: [FakeRoute] = []
    let runner = FakeRunner()
    let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
    await call.start()
    #expect(routes.isEmpty && call.phase == .listening && runner.warmUps == 1)
    await call.listen(for: nil)
    #expect(routes.count == 1 && call.isHearing)
    call.send()
    #expect(routes[0].finishCount == 1)
    routes[0].send(.command("make it blue"))
    #expect(await eventually { runner.commands == ["make it blue"] && routes[0].isStopped && !call.isHearing })
    call.end()
}
@Test func queuedCommandRunsOnItsOwnTarget() async {
    // Two squeezes on different targets while the first command is still running:
    // each command starts with its own target.
    var routes: [FakeRoute] = []
    let runner = FakeRunner(); runner.holds = true
    let call = VoiceCall(listening: .onRequest { let r = FakeRoute(); routes.append(r); return r }, runner: runner)
    var started: [VoiceTarget?] = []
    call.onCommandStarts = { started.append($0) }
    await call.start()
    let a = VoiceTarget.canvas(CGPoint(x: 1, y: 1)), b = VoiceTarget.canvas(CGPoint(x: 2, y: 2))
    await call.listen(for: a); call.send(); routes[0].send(.command("make a login screen"))
    #expect(await eventually { runner.commands.count == 1 })
    await call.listen(for: b); call.send(); routes[1].send(.command("make a settings screen"))
    #expect(await eventually { call.queuedCount == 1 })
    runner.holds = false
    #expect(await eventually { runner.commands.count == 2 })
    #expect(started == [a, b])
    #expect(runner.cancelled.isEmpty)
    call.end()
}
@Test func cancellingListeningQueuesNothing() async { /* listen, cancelListening, then the route sends a command: nothing runs, route stopped */ }
```

- [ ] **Step 2:** Run `-only-testing:LayerTests/VoiceCallTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement. Keep `VoiceCall.current`'s "one call at a time" rule for `.continuous` calls only. A pencil call and a phone call may coexist, and neither's `start()` ends the other.
- [ ] **Step 4:** Run `VoiceCallTests` and `VoiceAgentTests`. Expected: PASS, with the existing tests unchanged.
- [ ] **Step 5:** Commit: "Voice: a call that listens when asked, each command with its own target".

---

### Task 5: `PencilVoice`, squeezes into listening

**Files:**
- Create: `Layer/Voice/PencilVoice.swift`
- Modify: `Layer/App/AppModel.swift` (own a `PencilVoice`; a `hoverTarget(at:skippingDrawings:)` variant; `newScreenAnchor: CGPoint?`; `voiceHint: String?`)
- Modify: `Layer/Intents/DesignActions.swift` (`placementForNewScreen(_:in:near:)`)
- Modify: `Layer/Voice/VoiceAgent.swift` (prepend and clear `model.voiceHint` in `run`)
- Test: `LayerTests/PencilVoiceTests.swift` (new)

**Interfaces:**
- Consumes: `VoiceCall(listening: .onRequest…)`, `listen(for:)`, `send()`, `cancelListening()`, `onCommandStarts`, `VoiceTarget` (Task 4).
- Produces: `@Observable @MainActor final class PencilVoice`:
  - `init(model: AppModel, makeRoute: @escaping @MainActor () -> any VoiceRoute = { DictationRoute(endsOnPause: false) }, makeRunner: @escaping @MainActor (AppModel) -> any VoiceCommandRunner = { VoiceAgent(model: $0) }, clock: @escaping () -> ContinuousClock.Instant = { .now })`.
  - `func squeezeBegan(at viewPoint: CGPoint?, azimuth: Angle?)`, where nil means no hover pose; `func squeezeEnded()`; `func hovered()` (first call warms the model and prepares speech; later calls do nothing); `func tapBubble()` (cancels).
  - `private(set) var bubble: Bubble?`, with `struct Bubble: Equatable { var anchor: CGPoint; var azimuth: Angle?; var state: State }` and `enum State: Equatable { case gettingReady, listening, working, done, problem(String) }`.
  - `static let holdThreshold: Duration = .milliseconds(350)`; `static let silenceTimeout: Duration = .seconds(20)`.
- The rules, each one a test:
  - **Began with no hover pose and nothing open:** ignored.
  - **Began over chrome** (a point in `model.chromeFrames` or above `topBarBottom`): ignored.
  - **Began while `model.tool == .draw`:** ignored.
  - **Began with `UIPencilInteraction.preferredSqueezeAction == .ignore`:** ignored. Injected as `var squeezeIsOff: () -> Bool` for tests.
  - **Began while the phone call (`model.voice`) is up:** sets `model.selection` to the target and opens no bubble.
  - **Began, nothing open:**
    - Captures the target: `hoverTarget(at:skippingDrawings: true)`. A hit inside the current multi-selection means the whole selection. Nil means `.canvas(viewport.canvasPoint(for:))`.
    - Sets the selection (cleared for canvas).
    - Opens the bubble (`.gettingReady`), starts the pencil call lazily, and calls `listen(for:)`. `.listening` follows once `isHearing`.
  - **Ended less than 0.35 s after began:** toggle, stays listening, and the 20 s silence timer starts. The timer resets on each `.hearing` caption and cancels on timeout.
  - **Ended at 0.35 s or more:** `send()`.
  - **Began while a toggle is open:** `send()`, needing no hover pose. Its `ended` is ignored.
  - **On send:** the bubble goes `.working`, then `.done` or `.problem` from the call's caption, then nil after the caption clears.
  - **Command starts (`onCommandStarts`):**
    - `.thing` sets the selection.
    - `.canvas(p)` clears the selection, sets `model.newScreenAnchor = p`, and sets `model.voiceHint = "(The person pointed at empty canvas: a description of a screen means a new screen there.)"`.
    - The anchor clears when the command ends.
  - **The window leaves the screen** (`AppModel.windowLeftTheScreen`) or the design closes: `cancelListening()`, and the bubble closes. A running command is left to finish. Test: `leavingTheScreenStopsListening`.
  - **Model unavailable** (`modelChoice.sketchProvider.readiness()`): the bubble opens with `.problem(reason)` and doesn't listen.
- `placementForNewScreen(_:in:near:)`: with a point, the new screen's top-left goes at the point, nudged right past any screen it would overlap. `AppModel.generateScreen` uses `newScreenAnchor` when set.

- [ ] **Step 1: Write the failing tests** with `VoiceFixture.login()`, `FakeRoute`, `FakeRunner`, and an injected clock. Test names:
  - `aQuickSqueezeTogglesAndTheNextSends`
  - `aHeldSqueezeSendsOnRelease`
  - `theSecondSqueezeSendsWithoutAHoverPose`
  - `aSqueezeOutOfRangeStartsNothing`
  - `aSqueezeOverChromeOrInDrawStartsNothing`
  - `aSqueezeDuringACallOnlyRetargets` (no route made, selection set)
  - `aSqueezeOverAnElementSelectsIt`
  - `aSqueezeOverADrawingTargetsWhatIsBeneath`
  - `aSqueezeOnPartOfASelectionKeepsTheWholeSelection`
  - `aSqueezeOverCanvasPlacesTheNewScreenThere` (asserts `newScreenAnchor` while running and the screen origin from `placementForNewScreen(near:)`)
  - `aToggleLeftSilentCloses` (advance the clock 20 s: route stopped, nothing run)
  - `anUnavailableModelSaysSoInTheBubble`
  - `hoveringWarmsOnce` (`runner.warmUps == 1` after two `hovered()` calls, no route made)
- [ ] **Step 2:** Run `-only-testing:LayerTests/PencilVoiceTests`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement. `xcodegen generate`.
- [ ] **Step 4:** Run `PencilVoiceTests`, `VoiceCallTests`, `VoiceAgentTests` and `VoiceToolsTests`. Expected: PASS.
- [ ] **Step 5:** Commit: "Voice: a Pencil Pro squeeze listens for the thing under the tip".

---

### Task 6: The bubble, the squeeze on the canvas, haptics, and the words setting

**Files:**
- Create: `Layer/Chrome/PencilVoiceBubble.swift`
- Modify: `Layer/Canvas/CanvasScreen.swift` (`.onPencilSqueeze` feeding `PencilVoice`; `hovered()` from the existing hover handler; the bubble overlay)
- Modify: `Layer/Chrome/ModelSettingsView.swift` (Voice section: `Toggle("Show Words in the Pencil Bubble", isOn: $showsWords)`, with `@AppStorage("pencilVoice.showsWords") = false`)
- Test: `LayerTests/PencilVoiceTests.swift` (placement)

**Interfaces:**
- Consumes: `PencilVoice.bubble`, `squeezeBegan(at:azimuth:)`, `squeezeEnded()`, `hovered()`, `tapBubble()` (Task 5); `CallWaveform`; the pencil call's `levels`, `caption` and `queuedCount`.
- Produces: `PencilVoiceBubble.origin(anchor: CGPoint, azimuth: Angle?, size: CGSize, in bounds: CGRect, topInset: CGFloat) -> CGPoint`, the bubble's top-left.
  - It sits 28 pt from the tip, in the direction opposite the azimuth (the barrel's direction from the tip).
  - It is clamped inside `bounds` inset by 12, and below `topInset`.
  - With no azimuth, it goes below the tip.

- [ ] **Step 1: Write the failing placement tests**
  - A right-handed pose (azimuth 45°, barrel toward bottom-right) puts the bubble up and left of the tip.
  - Azimuth 135° (left-handed) puts it up and right.
  - A tip near the top edge is clamped below `topInset`.
  - A nil azimuth puts it below.
- [ ] **Step 2:** Run them. Expected: FAIL.
- [ ] **Step 3:** Implement `origin`, then the view:
  - **Content:** a glass capsule tinted like `CallPill` (`canvas.resolvedBackground`), with the model icon (`model.modelChoice.symbol`) beside `CallWaveform`. `.gettingReady` dims the waveform to 0.4 opacity.
  - **Words:** with the setting on, the heard caption shows under the waveform (two lines, tail-truncated at the head so the newest words show).
  - **After sending:** `.working` collapses to icon plus `ProgressView`. `.done` shows a green tick. `.problem` shows a one-line orange message regardless of the setting. A `+N` shows when commands are queued.
  - **Entrance:** a spring from scale 0.2 at the anchor with a −12° rotation to identity, anchored on the tip side. The exit reverses it.
  - **Tap:** `tapBubble()`.
  - **Accessibility:** the label is "Listening with <model>".
- [ ] **Step 4:** In `CanvasScreen`:
  - Add `.onPencilSqueeze` mapping `.active(value)` to `squeezeBegan(at: value.hoverPose?.location, azimuth: value.hoverPose?.azimuth)`, firing once per squeeze as `Scrubber` does, and `.ended`/`.failed` to `squeezeEnded()`.
  - Call `pencilVoice.hovered()` in the existing `onContinuousHover` `.active` branch.
  - Haptics: `UICanvasFeedbackGenerator` `.alignmentOccurred(at:)` when the bubble turns `.listening`, and `.pathCompleted(at:)` on send, at the anchor.
  - **The squeeze handler is only attached while `model.tool != .draw`** (a conditional `ViewModifier`). Task 1 found that a canvas `.onPencilSqueeze` stops PencilKit's palette appearing on squeeze in Draw, which the user requires. `.active` repeats during one squeeze, so act on its first only.
- [ ] **Step 5:** Run `PencilVoiceTests` and build. Expected: PASS.
- [ ] **Step 6:** Commit: "The pencil bubble: model and waveform at the tip, words if asked for".

---

### Task 7: A demo hook, and a look in the simulator

**Files:**
- Modify: `Layer/Debug/VoiceDemo.swift`

**Interfaces:**
- Consumes: `PencilVoice(model:makeRoute:makeRunner:)`, `squeezeBegan`, `squeezeEnded`.
- Produces: launch arguments `-LayerPencilDemo "<x>,<y>,<azimuthDegrees>,<hold|toggle> => <spoken> => <outcome>"`. Optional extras: `-LayerVoiceDemoFreeze listening|working|done|problem`, `-LayerVoiceDemoDesign login`, and `-LayerPencilDemoWords YES`. The demo drives the squeeze sequence with the existing scripted route and runner.

- [ ] **Step 1:** Implement, reusing `VoiceDemo`'s scripted route and runner.
- [ ] **Step 2:** In the simulator, screenshot the bubble listening (words off and on) over an element and over the canvas, at 45° and 135°, working, done, and with a problem. Check it's clear of the top bar near the top edge, and in the light and dark canvas. Fix what looks wrong.
- [ ] **Step 3:** Run the whole CI test plan. Expected: everything passes except the known flaky `CoreHandwriting` crash, which, if it appears, is re-run once.
- [ ] **Step 4:** Commit: "Debug: a scripted Pencil squeeze, for looking at the bubble".

---

### Task 8: On the iPad

- [ ] **Step 1:** Build Release for "AKS Mini", install, and launch with the console logged to the scratchpad.
- [ ] **Step 2:** Ask the user to try (including: with Draw on, a squeeze shows PencilKit's palette):
  - a held squeeze over an element ("make this blue");
  - a quick squeeze toggle over the canvas ("a settings screen with notifications and dark mode toggles");
  - a squeeze while a command runs;
  - a squeeze with the pen far away;
  - the words setting both ways.
- [ ] **Step 3:** From the log, measure the time from squeeze to `route: microphone on`. If it's over 0.5 s, report it with the numbers and propose buffering. That's not built unless the user says so.
- [ ] **Step 4:** Record findings in `docs/benchmarks/voice-on-device.md` under "Pencil push-to-talk", and update memory.

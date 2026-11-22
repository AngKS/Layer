# Zoom Ruler and Typed Screen Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The zoom percentage scrubs through zoom stops with the format panel's ruler (finger hold-and-drag, or Pencil Pro squeeze-and-roll) and loses its −/+ buttons; a selected screen's bar gets a "Describe a change…" field whose typed (or held-to-speak) change goes to the voice agent, scoped to that screen, as one undo step.

**Architecture:** The format panel's `Scrubber` moves up to `AppModel.scrubber`, shared by the panel's fields and the zoom control. Each ruler has an owner (`.panel` or `.zoom`); only a panel scrub is an edit. One window-level `.onPencilSqueeze`, driven by a new `SqueezeRouter`, decides per squeeze whether it belongs to a ruler or to push-to-talk, replacing today's two handlers that fire in no fixed order. Typed edits go through the pencil's own `VoiceCall` (`submit`), in turn with every spoken command, to the same `VoiceAgent` with a new target `VoiceTarget.screenEdit(screen)`: the agent tells the model that screen in full and the others by name, the toolbox refuses anything off that screen, and the command's held edit is named "Change Screen". The field's press-and-hold reuses `PencilVoice`'s listening (`holdBegan` / `holdEnded`).

**Tech Stack:** Swift 6, SwiftUI, UIKit, PencilKit, Foundation Models, Swift Testing (unit), XCUITest (UI), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-18-zoom-ruler-screen-edits-design.md`. Read it first. Background: `/Users/angks/projects/personal/Layer/reports/Rotation grouping selection and zoom.md`, `/Users/angks/projects/personal/Layer/research_notes/Rotation grouping selection and zoom/` (`pencil_pro_zoom_control.md`, `typed_screen_edits.md`, `layer_codebase_audit.md` §6), the push-to-talk design `docs/superpowers/specs/2026-11-18-pencil-ptt-design.md`, and the audit of 2026-11-22 (`/Users/angks/projects/personal/Layer/reports/Layer audit 2026-11-22/SUMMARY.md`, `fixes-generation.md`, `fixes-voice.md`, `fixes-canvas-chrome.md`, `fixes-finish-a.md`).

## Global Constraints

- Work in `/Users/angks/projects/personal/Layer/.claude/worktrees/zoom-screen-edits` (branch `feature/zoom-screen-edits`). Never `cd` to the main checkout. Never use bare `git stash`.
- iPadOS 27, Xcode 27.2, Swift 6 strict concurrency. No new `@unchecked Sendable` or `nonisolated(unsafe)`. Unit tests are Swift Testing; UI tests are XCUITest. Run `xcodegen generate` after adding or removing a file.
- **Zoom stops:** 10, 15, 20, 25, 33, 50, 67, 75, 100, 125, 150, 200, 250, 300, 400 (%), inside `Viewport.zoomRange` (0.1...4). A stop's scale is its percent / 100 (33 → 0.33).
- **16 pt of finger per stop; 10° of barrel per stop; a haptic tick per stop** (`ticksEvery: 1`). The ruler's ticks are 16 pt apart, one per stop; the menu's levels (25, 50, 100, 200, 400) are the longer marks.
- A scrub starts at the stop nearest the current zoom, nearest by ratio. The ruler shows that stop at once; the zoom itself moves on the first step, one stop from there. The canvas zooms about the middle of the view (`InkCanvas.Coordinator.zoom(to:)`, which glides).
- The −/+ buttons go. The percentage stays, and a tap opens the same menu as today: Lock Canvas, Zoom to Fit Content, 25/50/100/200/400%.
- **Zooming isn't an edit.** A zoom scrub calls neither `AppModel.beginScrubbing()` nor `endScrubbing()`, makes no undo step, and never ends or joins a panel edit. Scrubbing works with Lock Canvas on, as the menu's levels do.
- **One squeeze handler for the window, present only while Draw is off.** From Task 3 on there is exactly one `.onPencilSqueeze` in `Layer/` (in `CanvasScreen.swift`). It is absent in Draw, so PencilKit's palette gets the squeeze there (a handler that is present, even one that ignores the squeeze, stops the palette: seen on the iPad). A squeeze push-to-talk owns (`PencilVoice.ownsSqueeze`) is left to it. One ruler is up at a time.
- **Hold threshold: 0.35 s** for the zoom's hold, the field's hold, and the number fields (as `PencilVoice.holdThreshold`).
- The scrubber's audit fixes stay as they are (M8): a barrel roll counts only while the pencil stays in hover range (`Scrubber.hover(_:roll:)`), and a finger holding another field, or the zoom, puts the pencil's ruler away first (`Scrubber.hold(_:)`). `TypedNumber` (I1: only a newly typed value is set) isn't touched.
- **Typed edit = one undo step**: a command edit (`DesignStore.beginHeldEdit()` in `VoiceAgent.run`), with its own identity, named "Change Screen" in the Edit menu, never ending or joining an edit by hand. Spoken/typed "undo" stays the Undo button; "No, …" stays a correction of the command's own step only (V1, V3: `VoiceAgent.correction(in:)` unchanged). Tools of one answer still run in the model's order (V2: unchanged).
- **Scope:** the model is told the selected screen in full, every other screen by name only, and no loose elements. The toolbox refuses any change to another screen, an element off the screen, or a new screen.
- **The field:** shown when exactly one unlocked screen is selected. Placeholder "Describe a change…"; a send arrow ("Send change") while there is text. On send, the text clears; while the command waits or runs, the field shows the agent's step ("Thinking…", "Restyling…"); after, the command's reply line for as long as the call's caption lasts (done 3 s; problem or what the model said 6 s). Typed text is sent as typed: none of speech's filters (one-word, "stop", "hang up").
- **Hold to speak:** press and hold the field (0.35 s) while it is a plain line, not while it is being typed in. It listens while held, with push-to-talk's bubble at the field, and sends on release. It reuses `PencilVoice` (one listener at a time; with a phone call up in this window, holding only selects the screen, as a squeeze does). It is not a squeeze: Squeeze to Talk, the system squeeze setting and Draw have no say.
- Without a model that can be asked (`PencilVoice.readiness()` is `.unavailable(reason)`), the field is disabled and shows the reason.
- **VoiceOver:** the zoom control is adjustable: increment and decrement go to the next stop above or below (a zoom within 2% of a stop counts as on it); its default action still opens the menu. The field is "Describe a change"; activating it starts typing; the action "Speak a change" starts listening and a second use sends.
- Keyboard and palette (C5): the canvas doesn't take first responder while the field is typed in, and in Draw the palette comes back when typing ends. Both are handled already by `InkCanvas.Coordinator` following `UITextField` notifications; don't add focus code that fights it.
- Voice tests use `VoiceFixture` (each design on its own `PhoneLine`), set `pencil.phoneCallIsUp = { false }` and `pencil.otherWindows = { [] }`, and never write the app's settings (`AppSettings.defaults` is the tests' own suite already).
- **Non-goals:** a zoom slider or dial elsewhere; any change to pinch zoom; typed edits for elements, several things or the open canvas; regenerating a whole screen from a prompt; a rename tool.
- Don't install to the user's iPad ("AKS Mini") without the user's go-ahead.

**Commands used throughout.** Make this branch its own simulator once (Task 1, Step 0), then:

```bash
cd /Users/angks/projects/personal/Layer/.claude/worktrees/zoom-screen-edits
SIM=$(xcrun simctl list devices | grep "Layer iPad Pro 11 (zoom-screen-edits)" | grep -oE '[0-9A-F-]{36}')
# one unit suite (Swift Testing: the suite's type name)
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,id=$SIM" -only-testing:LayerTests/<SuiteType> 2>&1 | tail -30
# all unit tests
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI -destination "platform=iOS Simulator,id=$SIM" 2>&1 | tail -30
# one UI test
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan Layer \
  -destination "platform=iOS Simulator,id=$SIM" -only-testing:LayerUITests/<Class>/<testMethod> 2>&1 | tail -30
```

Known before this work: 4 unit tests time out now and then on a cold simulator (`aQuickSqueezeTogglesAndTheNextSends`, `aSliderMovedAndLetGoDuringACommandLeavesTheStepToTheCommand`, `aDesignStillComingUpIsPutAwayOnceItIsUp`, `aGenerationWhoseScreenIsTakenAwayStillFinishes`; a rerun passes), and 2 UI tests fail on untouched main in a fresh simulator (`testMagicPenSketchesBecomeADesignWithCode`, `testTheReferenceDesignFitsTheCanvas`).

## Review Focus

1. **The squeeze that keeps a ruler's value, with the pen drifted over the canvas** (rolling is followed anywhere in the window, so this is the usual case for the zoom). Expected: the ruler goes and nothing else happens. Today the panel's handler and push-to-talk's both fire, in no fixed order, and the second can start listening. → Task 3, `theSqueezeThatKeepsAValueStartsNothingElse`.
2. **The selection changing, or the panel closing, while the zoom's ruler is up; a field's hover left behind when its panel goes.** Expected: only the panel's ruler ends; a squeeze over the canvas is never taken for a field that has gone. → Task 1, `endingOneOwnersRulerLeavesTheOthers`; Task 3, `aHoverLeftByAFieldThatWentAwayIsntARuler`.
3. **A zoom between stops** (after a pinch, Zoom to Fit or a spoken "zoom in"). Expected: a scrub starts at the nearest stop by ratio and moves one stop per step from there; VoiceOver goes to the next stop above or below and never skips one. → Task 2, `aZoomBetweenStopsStartsAtTheNearestByRatio`, `voiceOverStepsToTheNextStopAboveOrBelow`.
4. **One word, or "stop", typed into the field.** Expected: sent as typed ("blue" restyles; "stop" is a command, not a cancel of whatever is running). Speech's filters drop both today. → Task 5, `typedWordsAreTakenAsTheyAre`.
5. **A typed change while a finger drags something, or behind a command spoken a moment earlier.** Expected: the typed change is its own one step and the drag stays its own open step; the typed change waits its turn behind the spoken one. → Task 7, `aScreenChangeLeavesADragByHandItsOwnStep`; Task 8, `typedWordsWaitTheirTurnBehindAHeldCommand`.

## Merging the "Squeeze to Talk" branch

Another branch adds a Magic Pen setting, **Squeeze to Talk** (on by default). Off: squeezing never starts push-to-talk, and the canvas's push-to-talk handler is removed so the squeeze goes to the system action, but a squeeze over a Format number field still scrubs. This plan is built so that holds once the two meet:

- This plan does **not** touch `Layer/App/AppSettings.swift` or `Layer/Chrome/ModelSettingsView.swift`.
- `SqueezeRouter.talks` (Task 3) is the setting's seam. Until that branch is on main it is `{ true }`. On merge, set it where `AppModel.squeezeRouter` is made: `router.talks = { [weak self] in self?.<the setting> ?? true }`. The setting must be observable where `WindowSqueeze` reads it (an `@Observable` `AppModel` property, or `@AppStorage` read in `WindowSqueeze`), so the handler comes and goes with it.
- With `talks` false, `SqueezeRouter.wantsHandler` keeps the window's handler only while a field or the zoom is hovered or a ruler is up, so scrubbing (zoom included) still works and every other squeeze goes to the system. That is the behaviour that branch asks for.
- `CanvasScreen.SqueezeToSpeak` is deleted in Task 3 (replaced by `WindowSqueeze`). Their change to its `isOn` maps to the `talks` seam above; take this branch's `CanvasScreen` and port the condition.
- `StylePanel`: this branch deletes the panel's own `.onPencilSqueeze` (Task 3). If theirs keeps it, take this branch's.
- `PencilVoice`: Task 3 makes its private `isOverChrome` call `AppModel.isOverChrome`; Task 7 adds a `.screenEdit` case to `select` and `commandStarts`; Task 8 extracts `beginListening(about:at:azimuth:)` from the tail of `squeezeBegan` and adds `holdBegan`, `holdEnded`, `isListening`, `prepare`, `submit`. A setting check that branch adds to `squeezeBegan`'s first guard or to `hovered()` stays there. `holdBegan`, `prepare` and `submit` must **not** check the setting.
- After merging, rerun `SqueezeRouterTests` and `PencilVoiceTests`, with `talks` wired to the real setting.

---

### Task 1: The scrubber learns owners, its own words and squeeze entry points

**Files:**
- Modify: `Layer/Chrome/Scrubber.swift`
- Modify: `LayerTests/FormatPanelTests.swift` (make `ScrubbedField` internal; new tests in `ScrubbingAFieldTests`)

**Interfaces:**
- Produces:
  - `enum Scrubber.Owner: Hashable { case panel, zoom }`
  - New `Scrubber.Target` fields, added at the **end** so existing call sites still compile: `var owner: Owner = .panel`; `var text: ((CGFloat) -> String)? = nil` (the ruler's words for a value; nil gives `"\(Int(value)) \(unit)"`); `var majorMarks: Set<Int>? = nil`. Methods `func shown(_ value: CGFloat) -> String` and `func isMajor(_ unit: Int) -> Bool` (with `majorMarks`, membership; else every `ticksEvery` when it is above 1, else every 10).
  - `Scrubber.onBegin` / `onEnd` are called only for a `.panel` target's scrub (a zoom scrub is no edit).
  - `func end(_ owner: Owner)`: ends the ruler only if it is that owner's. `func forgetHovered(_ owner: Owner)`: clears `hovered` only if it is that owner's.
  - `private(set) var wantsSqueeze: Bool` (observed): true while `hovered` or `target` is set. Kept current from `hovered`'s and `target`'s `didSet`, written only when it changes (the pen hovers many times a second).
  - `@discardableResult func squeezeBegan(roll: Angle?) -> Bool`: with a ruler up, ends it; else with a field hovered, begins it and counts the barrel from `roll`; returns whether it took the squeeze. It doesn't filter repeats (the router does, Task 3).
  - `squeeze(_ phase:)` stays for now, rebuilt on `squeezeBegan(roll:)` with its own repeat guard; Task 3 deletes it.
  - `ScrubberRuler(value: CGFloat, text: String, spacing: CGFloat, isMajor: @escaping (Int) -> Bool)`, replacing `unit` and `majorEvery`. `ScrubberOverlay(owner: Scrubber.Owner = .panel)` shows only that owner's ruler.

- [ ] **Step 0: Make the branch's simulator** (once): `xcrun simctl clone F8362E19-7F0C-42CB-8FE0-1F949F7C2950 "Layer iPad Pro 11 (zoom-screen-edits)"` (a clone of "iPad Pro 11-inch (M5)"), then `xcodegen generate`. Run all unit tests once and note which fail, as the baseline.
- [ ] **Step 1: Write the failing tests** in `ScrubbingAFieldTests` (remove `private` from `ScrubbedField` first; later tasks use it):
  - `aZoomScrubIsNoEdit`: count `onBegin`/`onEnd`. A target with `owner: .zoom` (`label: "Zoom", unit: "%", range: 0...14`) begun, scrubbed to 2 and ended: begins 0, ends 0, its value set to start+2. A `.panel` target the same way: begins 1, ends 1.
  - `endingOneOwnersRulerLeavesTheOthers`: begin a zoom target; `end(.panel)` leaves `target?.owner == .zoom`; `end(.zoom)` gives nil. Set `hovered` to a panel field; `forgetHovered(.zoom)` leaves it; `forgetHovered(.panel)` clears it.
  - `aSqueezeKeepsTheValueOrBringsUpTheHoveredRuler`: nothing hovered, `squeezeBegan(roll: .degrees(30))` is false. With `hovered` = `ScrubbedField(10).target("Rotation", at: .zero)` (1° a step), it is true and the Rotation ruler is up; `rolled(to: .degrees(35))` makes the value 15. `squeezeBegan(roll: nil)` is true and the ruler is gone, the value kept at 15.
  - `theScrubberSaysWhenASqueezeWouldBeItsOwn`: `wantsSqueeze` false; true with `hovered` set; false again with it nil; true after `begin`; false after `end()`.
  - `aRulerShowsItsOwnWordsAndMarks`: a target with `unit: "W"` shows `shown(12) == "12 W"`; with `text: { "\(Int($0))%" }`, `shown(8) == "8%"`. `isMajor`: default target, 10 yes, 5 no; `ticksEvery: 15`, 30 yes, 10 no; `majorMarks: [3, 8]`, 8 yes, 10 no.
- [ ] **Step 2:** Run `-only-testing:LayerTests/ScrubbingAFieldTests`. Expected: fails to compile (`owner`, `end(_:)`, `squeezeBegan` undefined).
- [ ] **Step 3:** Implement the interfaces above. `ScrubberOverlay` passes `target.shown(value)` and `target.isMajor` to the ruler.
- [ ] **Step 4:** Run `ScrubbingAFieldTests`, `ScrubbingTests` and `PanelChangesBesideADragTests`. Expected: all pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Zoom ruler: the scrubber has owners, words of its own and a squeeze entry point"`

### Task 2: Zoom stops

**Files:**
- Create: `Layer/Chrome/ZoomStops.swift`
- Create: `LayerTests/ZoomRulerTests.swift` (suite `ZoomStopsTests`)

**Interfaces:**
- Consumes: `Scrubber.Target` with `owner`, `text`, `majorMarks` (Task 1).
- Produces `enum ZoomStops`:
  - `static let percents: [Int]` (the 15 stops), `static let menuLevels = [25, 50, 100, 200, 400]`, `static let pointsPerStop: CGFloat = 16`, `static let degreesPerStop = 10.0`.
  - `static func scale(at index: Int) -> CGFloat`: the stop's scale, the index clamped to the list.
  - `static func nearestIndex(to scale: CGFloat) -> Int`: nearest by ratio (`abs(log(scale / stop))`), a tie going to the lower stop; below or above the list, its end.
  - `static func step(from scale: CGFloat, by stops: Int) -> CGFloat`: for VoiceOver. On a stop (within 2% by ratio) it moves `stops` stops from it; between stops, the first step lands on the next stop in that direction. Clamped to the ends.
  - `static func target(frame: CGRect, current: @escaping @MainActor () -> CGFloat, zoom: @escaping @MainActor (CGFloat) -> Void) -> Scrubber.Target`: `label: "Zoom"`, `unit: "%"`, `range: 0...14` (indices), `get` = `CGFloat(nearestIndex(to: current()))`, `set` = `zoom(scale(at: Int(index)))`, `pointsPerStep: 16`, `degreesPerStep: 10`, `ticksEvery: 1`, `owner: .zoom`, `text` = `"\(percents[i])%"`, `majorMarks` = the indices of `menuLevels`.

- [ ] **Step 1: Write the failing tests** in `ZoomStopsTests`:
  - `theStopsRunFrom10To400Percent`: 15 stops, first 10, last 400; `scale(at: 8) == 1`; `scale(at: -3) == 0.1`; `scale(at: 99) == 4`; every stop's scale is inside `Viewport.zoomRange`.
  - `aZoomBetweenStopsStartsAtTheNearestByRatio`: `nearestIndex(to:)` gives 8 for 0.9 and 1.0; 7 for 0.8; 4 for 0.29 and for 1/3; 0 for 0.05; 14 for 5.
  - `voiceOverStepsToTheNextStopAboveOrBelow`: `step(from: 0.9, by: 1) == 1`; `step(from: 0.9, by: -1) == 0.75`; `step(from: 1, by: 1) == 1.25`; `step(from: 1, by: -1) == 0.75`; `step(from: 1.0 / 3, by: -1) == 0.25` (1/3 counts as on 33); `step(from: 0.5, by: 2) == 0.75`; `step(from: 4, by: 1) == 4`; `step(from: 0.1, by: -1) == 0.1`.
  - `theZoomsRulerStepsThroughStopsAndShowsPercent`: a `Scrubber` begun with `target(frame: .zero, current: { 0.9 }, zoom: { zooms.append($0) })`: `scrubber.value == 8` and nothing zoomed yet; `scrub(to: 1)`, `scrub(to: 2)`, `scrub(to: -1)` give zooms `[1.25, 1.5, 0.75]`; `scrub(to: 50)` ends at 4. The target's `shown(8) == "100%"`, `isMajor(8)` true, `isMajor(9)` false, `owner == .zoom`.
  - `sixteenPointsOfFingerOrTenDegreesOfBarrelIsAStop`: `Scrubber.steps(forDrag: 40, pointsPerStep: ZoomStops.pointsPerStop) == 2`; `Scrubber.steps(forRoll: .degrees(25), degreesPerStep: ZoomStops.degreesPerStop) == 2`.
- [ ] **Step 2:** `xcodegen generate`; run `-only-testing:LayerTests/ZoomStopsTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement `ZoomStops`.
- [ ] **Step 4:** Run `ZoomStopsTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Zoom ruler: zoom stops, nearest by ratio, and the zoom's ruler target"`

### Task 3: One scrubber and one squeeze handler for the window

The riskiest task: it replaces both of today's squeeze handlers (`StylePanel`'s and `CanvasScreen.SqueezeToSpeak`) with one that routes each squeeze.

**Files:**
- Create: `Layer/Canvas/SqueezeRouter.swift`
- Modify: `Layer/App/AppModel.swift` (`scrubber`, `squeezeRouter`, `isOverChrome`, the `tool` `didSet`, the end of `init`)
- Modify: `Layer/Canvas/CanvasScreen.swift` (delete `SqueezeToSpeak`; add `WindowSqueeze`; host `PencilBridge`)
- Modify: `Layer/Chrome/StylePanel.swift` (use the shared scrubber; drop its handler, bridge and wiring)
- Modify: `Layer/Chrome/Scrubber.swift` (delete `squeeze(_:)` and its `isSqueezing`; `BridgeView.isUserInteractionEnabled = false`)
- Modify: `Layer/Voice/PencilVoice.swift` (its private `isOverChrome` calls the model's)
- Test: `LayerTests/PencilVoiceTests.swift` (new suite `SqueezeRouterTests`, using the file's private `Bench`), `LayerTests/FreeformTests.swift` (`ScrubbingTests`)

**Interfaces:**
- Consumes: Task 1's scrubber API; `ZoomStops.target` (Task 2) in one test; `PencilVoice.squeezeBegan(at:azimuth:)`, `squeezeEnded()`, `squeezeFailed()`, `ownsSqueeze`.
- Produces:
  - `AppModel.scrubber: Scrubber` (a `let`). At the end of `init`: `onBegin` calls `beginScrubbing()`, `onEnd` calls `endScrubbing()`, both through `[weak self]`.
  - `AppModel.isOverChrome(_ viewPoint: CGPoint) -> Bool`: above `topBarBottom`, or inside any `chromeFrames` value except `PencilVoiceBubble.chromeName` (today's `PencilVoice.isOverChrome`, moved).
  - `AppModel.squeezeRouter: SqueezeRouter`, made on first use, as `pencilVoice` is (`@ObservationIgnored private var squeezeRouterIfMade`). The `tool` `didSet` calls `squeezeRouterIfMade?.drawTurnedOn()` when Draw comes on, beside `pencilVoiceIfMade?.drawTurnedOn()`.
  - `@MainActor final class SqueezeRouter`:
    - `init(model: AppModel)` (weak); reads `model.scrubber` and `model.pencilVoice` at each call, never captured (tests swap `pencilVoice`).
    - `enum Taker: Equatable { case ruler, voice, nobody }`; `private(set) var taker: Taker?` (the squeeze under way).
    - `var talks: @MainActor () -> Bool = { true }`: the Squeeze to Talk seam (see "Merging").
    - `func began(at viewPoint: CGPoint?, azimuth: Angle?, roll: Angle?)`, `func ended()`, `func failed()`, `func drawTurnedOn()`.
    - `nonisolated static func wantsHandler(drawIsOn: Bool, talks: Bool, rulerWantsSqueeze: Bool) -> Bool`: `!drawIsOn && (talks || rulerWantsSqueeze)`.
  - `began` decides once per squeeze, in this order (a repeat `.active` while `taker != nil` does nothing):
    1. `pencil.ownsSqueeze` and no ruler up: push-to-talk's (`pencil.squeezeBegan`), `taker = .voice`.
    2. No ruler up, a field hovered, and `viewPoint` not over chrome: that hover was left behind by a field that went away; forget it.
    3. `scrubber.squeezeBegan(roll:)` took it: `taker = .ruler`.
    4. `talks()`: push-to-talk's, `taker = .voice`.
    5. Otherwise `taker = .nobody`.
  - `ended()`: `.voice` calls `pencil.squeezeEnded()`; `failed()`: `.voice` calls `pencil.squeezeFailed()`; both clear `taker`. `drawTurnedOn()` clears `taker` and ends any ruler (its keeping squeeze can't come in Draw).
  - `CanvasScreen`'s background becomes a private view `WindowSqueeze`: a `ZStack` of `PencilBridge(scrubber: model.scrubber)` and the `Color.black.opacity(0.001)` layer (not `Color.clear`), which gets `.onPencilSqueeze` only while `SqueezeRouter.wantsHandler(drawIsOn: model.tool == .draw, talks: router.talks(), rulerWantsSqueeze: model.scrubber.wantsSqueeze)`. A modifier that is absent, not one that ignores. `.active(value)` → `began(at: value.hoverPose?.location, azimuth: value.hoverPose?.azimuth, roll: value.hoverPose?.roll)`; `.ended` → `ended()`; `.failed` → `failed()`. When the handler goes away (`onChange` to false) or the view disappears, `router.failed()`: that squeeze's end will never arrive. Keep a `VoiceLog` line for the handler coming and going.
  - `StylePanel`: `private var scrubber: Scrubber { model.scrubber }`. Keep `.overlay { ScrubberOverlay(owner: .panel) }`, `.coordinateSpace(.named(Scrubber.space))` and `.environment(scrubber)`. `.scrollDisabled` only for a panel ruler. `onDisappear`: `scrubber.end(.panel)` and `scrubber.forgetHovered(.panel)`. `onChange(of: model.selection)`: `scrubber.end(.panel)`. Delete its `.background { PencilBridge }`, `.onPencilSqueeze` and `.onAppear` wiring.

- [ ] **Step 1: Write the failing tests.** In `SqueezeRouterTests` (in `PencilVoiceTests.swift`), each starting from `let bench = Bench()` and `let router = bench.app.squeezeRouter`, with a field from `ScrubbedField(10).target("W", at: .zero, range: 0...100)` and `bench.app.chromeFrames["format"] = CGRect(x: 0, y: 0, width: 300, height: 600)`, so the field's point is `(100, 100)`. Call `bench.end()` at the end of each.
  - `aSqueezeOverAHoveredFieldBringsUpItsRulerNotTheBubble`: `scrubber.hovered = field`; `began(at: (100, 100), azimuth: nil, roll: .degrees(0))`: `scrubber.target?.label == "W"`, `pencil.bubble == nil`, `bench.routes.isEmpty`, `taker == .ruler`.
  - `theSqueezeThatKeepsAValueStartsNothingElse` (Review Focus 1): a ruler up (`scrubber.begin(field)`); `began(at: Bench.overButton, …)` then `ended()`: the ruler is gone, `pencil.bubble == nil`, `bench.routes.isEmpty`, `bench.app.selection == nil`.
  - `aSqueezeOverTheCanvasListens`: nothing hovered; `began(at: Bench.overButton, …)`: `await eventually { bench.state == .listening }`; then `bench.now += .seconds(1)`, `ended()`: `routes[0].finishCount == 1`.
  - `aToggleListeningIsSentWhereverThePenIs`: start a toggle through the router (`began` over the button, `bench.now += .milliseconds(200)`, `ended()`, wait for `.listening`); set `hovered = field`; `began(at: (100, 100), …)`: `routes[0].finishCount == 1` and no ruler.
  - `oneSqueezesRepeatedStartsActOnce`: hovered field; `began` three times at `(100, 100)`: the ruler is up (not put away by the second).
  - `withSqueezeToTalkOffOnlyARulerTakesASqueeze`: `router.talks = { false }`; `began` over the button: `taker == .nobody`, no bubble, no route; `ended()`; then a hovered field and `began` at `(100, 100)`: the ruler is up.
  - `theHandlerIsThereOnlyWhileDrawIsOffAndSomethingWouldTakeIt`: `wantsHandler(drawIsOn:talks:rulerWantsSqueeze:)` is false for `(true, true, true)`, true for `(false, true, false)`, false for `(false, false, false)`, true for `(false, false, true)`.
  - `aHoverLeftByAFieldThatWentAwayIsntARuler` (Review Focus 2): `hovered = field`; `began(at: Bench.overButton, …)`: no ruler, `scrubber.hovered == nil`, `pencil.bubble != nil`.
  - `drawComingOnPutsAPencilRulerAway`: a ruler up through `began` at `(100, 100)`; `bench.app.tool = .draw`: no ruler, `taker == nil`.

  In `ScrubbingTests` (`FreeformTests.swift`):
  - `scrubbingTheZoomLeavesNoUndoStep`: an `AppModel` with its own `UndoManager` (`groupsByEvent = false`), as `aScrubUndoesAsOneStep` builds it. `model.scrubber.begin(ZoomStops.target(frame: .zero, current: { 1 }, zoom: { _ in }))`, `scrub(to: 2)`, `end()`: `undo.canUndo == false`, `model.store.isEditing == false`. Then a panel field through `model.scrubber`, whose `set` changes the title's width inside `model.adjusting { … }`, begun, scrubbed to 3 and ended: one `undo.undo()` puts the width back.
- [ ] **Step 2:** Run `-only-testing:LayerTests/SqueezeRouterTests -only-testing:LayerTests/ScrubbingTests`. Expected: fails to compile.
- [ ] **Step 3:** `xcodegen generate`. Implement the interfaces above.
- [ ] **Step 4:** Run `SqueezeRouterTests`, `ScrubbingTests`, `ScrubbingAFieldTests`, `PanelChangesBesideADragTests` and `PencilVoiceTests`. Expected: all pass. Then `grep -rn "onPencilSqueeze" Layer | wc -l` prints `1`, and all unit tests show no new failures against the baseline.
- [ ] **Step 5: Look** (simulator): open a design, select a button, open the Format panel, hold the W field and drag: the ruler shows above the field as before.
- [ ] **Step 6: Commit:** `git add -A && git commit -m "Zoom ruler: one scrubber and one squeeze handler for the window, which routes each squeeze"`

### Task 4: The zoom control scrubs, and loses its −/+ buttons

**Files:**
- Modify: `Layer/Chrome/StatusChrome.swift` (`ZoomControl`, `ViewControls`)
- Modify: `LayerUITests/SketchFlowUITests.swift` (a new test; `testTheCanvasPansZoomsLocksAndFramesCanBeMoved`; `testTheReferenceDesignFitsTheCanvas`'s list)
- Modify: `LayerUITests/CanvasBenchmarkUITests.swift` (`workout()`)

**Interfaces:**
- Consumes: `AppModel.scrubber`, `Scrubber.fingerDragged(_:by:)`, `end(.zoom)`, `forgetHovered(.zoom)`, `ScrubberRuler` (Task 1); `ZoomStops.target`, `ZoomStops.step` (Task 2); the window's squeeze routing (Task 3: a squeeze while the zoom is hovered brings its ruler up with no further work here).
- Produces: `ZoomControl` with no `step(...)` buttons. The percentage `Menu` (same items, same label and value) also:
  - takes a finger hold: `.simultaneousGesture` of `LongPressGesture(minimumDuration: 0.35)` sequenced before `DragGesture(minimumDistance: 0, coordinateSpace: .global)`, with `@GestureState isHeld`, calling `model.scrubber.fingerDragged(target, by: translation.width)`; when `isHeld` goes false, `scrubber.end(.zoom)` (the `NumberField` pattern);
  - follows the pencil's hover: `.active` sets `scrubber.hovered = target`; `.ended` clears it if it is the zoom's;
  - reads its global frame for the target (`onGeometryChange`), and on disappearing ends and forgets the zoom's ruler (the controls go during a call);
  - `.accessibilityAdjustableAction`: `model.ink?.zoom(to: ZoomStops.step(from: model.zoomScale, by: ±1))`.
  - `target` = `ZoomStops.target(frame: frame, current: { model.zoomScale }, zoom: { model.ink?.zoom(to: $0) })`.
- `ViewControls` draws the zoom's ruler: `ScrubberRuler` for a `.zoom` target only, `min(280, model.canvasSize.width - 40)` wide, its leading edge at the control's leading edge and its bottom 8 pt above the control's top. `allowsHitTesting(false)`.
- **Fallback, decided by Step 4's UI test:** if the `Menu` either opens on the hold or stops opening on a tap, replace it with a `Button` that shows a `.popover` (`.presentationCompactAdaptation(.popover)`) holding the same items as plain buttons, with Lock Canvas a `Button` showing a checkmark while on, so `app.buttons["Lock Canvas"]` and `app.buttons["100%"]` still find them. The hold, hover, adjustable action and labels stay as above. Write which one shipped in the commit message.

- [ ] **Step 1: Write the failing UI test** `testTheZoomScrubsWhenHeldAndOpensItsMenuWhenTapped` in `SketchFlowUITests`, starting as `testTheCanvasPansZoomsLocksAndFramesCanBeMoved` does (`openNewDesign()`, `box(sketch)`, `convert()`, zoom "100 percent"):
  1. `let start = control("Zoom").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))`; `start.press(forDuration: 0.6, thenDragTo: start.withOffset(CGVector(dx: 40, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.3)`: zoom becomes "150 percent" (two stops) and `app.buttons["Lock Canvas"].exists` is false (no menu opened).
  2. The same from the control's middle, 40 pt left: "100 percent".
  3. `control("Zoom").tap()`: "Lock Canvas" appears; tap "200%": "200 percent".
  4. `control("Zoom in").exists` and `control("Zoom out").exists` are both false.
- [ ] **Step 2:** Run it. Expected: fails (the zoom doesn't change on a hold; the −/+ buttons exist).
- [ ] **Step 3:** Implement `ZoomControl` and the ruler in `ViewControls` as above.
- [ ] **Step 4:** Run the new test. If it fails because the `Menu` opens on the hold or a tap no longer opens it, switch to the fallback and run it again. Expected: pass.
- [ ] **Step 5: Update the existing UI tests:** in `testTheCanvasPansZoomsLocksAndFramesCanBeMoved`, replace the "Zoom in"/"Zoom out" taps with a hold-and-drag 20 pt right ("125 percent") and 20 pt back ("100 percent"). In `testTheReferenceDesignFitsTheCanvas`, take "Zoom out" and "Zoom in" out of `controls`. In `CanvasBenchmarkUITests.workout()`, replace the four steps with menu levels: for each of `["200%", "100%", "50%", "100%"]`, `control("Zoom").tap()`, then tap the level, then `usleep(400_000)`.
- [ ] **Step 6:** Run `testTheZoomScrubsWhenHeldAndOpensItsMenuWhenTapped` and `testTheCanvasPansZoomsLocksAndFramesCanBeMoved`. Expected: pass. Take a simulator screenshot of the bottom-left control without −/+.
- [ ] **Step 7: Commit:** `git add -A && git commit -m "Zoom ruler: the percentage scrubs through zoom stops when held, squeezed or rolled; no more −/+ (<Menu|popover>)"`

### Task 5: A call takes typed words, and says how each command is getting on

**Files:**
- Modify: `Layer/Voice/VoiceCall.swift`
- Test: `LayerTests/VoiceCallTests.swift` (suite "A voice call", `VoiceCallTests`)

**Interfaces:**
- Produces:
  - `enum VoiceCall.Progress: Equatable { case working(String?), done(String), said(String), problem(String), over }`.
  - `func submit(_ text: String, about target: VoiceTarget?) -> Int?`: trims; nil for blank text or an ended call. Otherwise it numbers the command (`commandsTaken += 1`), queues it with its target and starts the worker. None of speech's filters apply: no `localAction`, no `isWorthAsking`, no fragment holding. It works in any phase but `.ended` (a call still `.starting` runs it once the worker starts).
  - `func progress(of number: Int) -> Progress`: when `caption?.command == number`, `.hearing`/`.working` → `.working(text)`, `.done` → `.done(text)`, `.said` → `.said(text)`, `.problem` → `.problem(text)`. Otherwise `.working(nil)` while `isUnderWay(number)`, else `.over`. It reads `queuedCount` too, so a view observing it hears a command leave the queue.

- [ ] **Step 1: Write the failing tests**, each with `VoiceCall(listening: .onRequest { FakeRoute() }, runner: runner)` and `await call.start()`, ending with `call.end()`:
  - `typedWordsAreACommandOfTheirOwn`: `submit("make it blue", about: .canvas(CGPoint(x: 1, y: 2)))` returns 1; eventually `runner.commands == ["make it blue"]` and `runner.targets == [.canvas(CGPoint(x: 1, y: 2))]`. `submit("  \n", about: nil) == nil`. After `call.end()`, `submit("make it red", about: nil) == nil`.
  - `typedWordsAreTakenAsTheyAre` (Review Focus 4): `submit("blue")`, `submit("stop")`, `submit("hang up")` (target nil): eventually `runner.commands == ["blue", "stop", "hang up"]`; `call.phase != .ended`.
  - `aCommandsProgressFollowsItsOwnLines`: `captionTimes = (done: .milliseconds(100), problem: .milliseconds(100))`; `runner.holds = true`; `let n = submit(...)!`; `await until { call.progress(of: n) == .working("Thinking…") }`; `call.showStep("Restyling…")` gives `.working("Restyling…")`; `progress(of: n + 1) == .over`; `runner.outcomes = [VoiceOutcome(lines: ["Restyled the button."])]`, `runner.holds = false`: `until` `.done("Restyled the button.")`, then `until` `.over`.
  - `aCommandsProblemAndWhatTheModelSaidAreFollowedToo`: outcomes `[VoiceOutcome(problem: "No connection."), VoiceOutcome(said: "I can only change the design.")]`; two submissions: `.problem("No connection.")` for the first, `.said("I can only change the design.")` for the second.
  - `typedWordsWaitBehindASpokenCommand`: `runner.holds = true`; a spoken command through a listen (`await call.listen(for: nil)`, `call.send()`, `routes[0].send(.command("make it blue"))`) is running; `let typed = submit("make it red", about: nil)!`: `call.queuedCount == 1` and `progress(of: typed) == .working(nil)`; `runner.holds = false`: `runner.commands == ["make it blue", "make it red"]`. (Collect the routes in an array, as `anOnRequestCallListensOnlyWhenAsked` does.)
- [ ] **Step 2:** Run `-only-testing:LayerTests/VoiceCallTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement `submit` beside `take` (it needs the private queue), and `Progress` / `progress(of:)`.
- [ ] **Step 4:** Run `VoiceCallTests` and `PencilVoiceTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Screen edits: a call takes typed words as they are, and says how each command is getting on"`

### Task 6: A change for one screen is told that screen, and touches nothing else

**Files:**
- Modify: `Layer/Voice/CanvasPicture.swift`
- Modify: `Layer/Voice/VoiceToolbox.swift`
- Modify: `LayerTests/VoiceCallTests.swift` (`VoiceFixture.loginAndProfile()`)
- Test: `LayerTests/VoiceToolsTests.swift` (`CanvasPictureTests`, `VoiceToolsTests`)

**Interfaces:**
- Produces:
  - `CanvasPicture.scope: String?`: a screen's handle. When set, `text(_:)` tells that screen in full and every other screen by its brief line (name, size and element count), whatever the detail, and leaves out "Loose on the canvas". Nil keeps today's text exactly.
  - `CanvasPicture.screenInWords(_ handle: String) -> String?`: `S1, the screen "Login"`; nil for a handle it doesn't have.
  - `VoiceToolbox.scope: DesignScreen.ID?`; `reset()` sets it to nil (the agent sets it after resetting, Task 7). With a scope:
    - `find(screen:)` refuses any other screen: `Only S1 “Login” can be changed here.`
    - `find(element:)` refuses an element not on the scope's screen, loose ones included: `E4 isn't on S1 “Login”, the screen this change is for.`
    - `createScreen` refuses with the same line as another screen.
    - `screenMeant` with no screen named gives the scope's screen, whatever is selected.
    - Handles and names come from `handles.handle(forScreen:)` and the screen's `name`.
  - `VoiceFixture.loginAndProfile() -> (app: AppModel, login: DesignScreen.ID, profile: DesignScreen.ID)`: `undoableLogin()` plus an iPhone screen "Profile" at `Placement(origin: CGPoint(x: 4600, y: 4000), scale: 0.6)` holding one title, "Your profile". Captured, the handles are S1 Login (E1 title, E2 button, E3 image) and S2 Profile (E4 title).

- [ ] **Step 1: Write the failing tests:**
  - `CanvasPictureTests.aChangeForOneScreenIsToldThatScreenAndTheOthersByName`: `loginAndProfile()` plus a loose sticky note (`app.store.addFloating(.stickyNote, from: CGRect(x: 3000, y: 3000, width: 160, height: 160))`). Captured: `text(.full)` contains "Loose on the canvas". With `scope = "S1"`: `text(.full)` contains `E2 button "Sign in"`, contains a line starting `S2 "Profile" 393x852` and ending `, 1 element`, and contains neither `Your profile` nor `Loose on the canvas`. `text(.compact)` is the same text.
  - `CanvasPictureTests.aScreenIsNamedInWordsByItsHandle`: `screenInWords("S2") == #"S2, the screen "Profile""#`; `screenInWords("S9") == nil`.
  - `VoiceToolsTests.aChangeForOneScreenTouchesNothingElse`: from `loginAndProfile()`, with handles captured and `box.scope = login`:
    - `styleElement(element: "E2", look: "green")` works: the button is green.
    - `styleElement(element: "E4", look: "red")` returns a line containing "isn't on S1"; the profile title's tint is unchanged; `box.lastFailed`.
    - `renameScreen(screen: "S2", name: "Settings")` and `deleteScreen(screen: "S2", named: nil)` are refused; "Profile" is still there, so named.
    - `try await createScreen(name: nil, description: "a settings screen", device: nil)` is refused; still 2 screens.
    - With `app.selection = .screen(profile)`, `addElement(screen: nil, kind: "button", text: "Next", look: nil, relation: nil, target: nil)` adds the button to Login, not Profile.
    - `show(target: "S2")` is refused.
    - `box.reset()` leaves `box.scope == nil`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/CanvasPictureTests -only-testing:LayerTests/VoiceToolsTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement the interfaces above. Keep `Tools/VoiceBenchmarkHarness` building: `scope` has a default value, and nothing new is needed from the app.
- [ ] **Step 4:** Run both suites and `VoiceAgentTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Screen edits: a change for one screen is told that screen in full and can touch nothing else"`

### Task 7: The agent carries out a change to a screen

**Files:**
- Modify: `Layer/Voice/VoiceCall.swift` (`VoiceTarget`)
- Modify: `Layer/Voice/VoiceAgent.swift`
- Modify: `Layer/Voice/PencilVoice.swift` (`select` and `commandStarts` handle the new case)
- Modify: `Layer/Model/DesignStore.swift` (`screenEditStepName`; naming order in `register`)
- Modify: `Layer/Debug/ScriptedLanguageModel.swift` (find a script behind a hint)
- Test: `LayerTests/VoiceAgentTests.swift`

**Interfaces:**
- Consumes: `CanvasPicture.scope`, `screenInWords`, `VoiceToolbox.scope`, `VoiceFixture.loginAndProfile()` (Task 6).
- Produces:
  - `VoiceTarget.screenEdit(DesignScreen.ID)`: a change typed or held-to-speak about one screen and everything on it. In `PencilVoice.select` and `commandStarts` it selects `.screen(id)`.
  - `VoiceAgent.run(_:about: .screenEdit(id))`: after `toolbox.reset()`, sets `toolbox.scope = id` and the agent's own scoped screen, which `lookAtTheCanvas()` writes into the picture as `scope` (its handle) for every look during the command. Both are nil for any other target and for `warmUp`. The prompt is `screenEditHint(words) + " " + command`, where `words` is `picture.screenInWords(handle)`.
  - `static func screenEditHint(_ screen: String) -> String`: `(The person is changing \(screen) and what is on it, and nothing else. "This", "it" and a change that names nothing mean that screen or what is on it.)`
  - The command's held edit is named before its first change: `model.store.name(edit, DesignStore.screenEditStepName)` for a `.screenEdit` target.
  - `DesignStore.screenEditStepName = String(localized: "Change Screen")`. In `register`, a step's own name now wins over `commandStepName` (`if let name = step.name { … } else if step.isCommand { … }`). No step is named that way today, so "Voice Command" is unchanged for every other command.
  - `ScriptedModelExecutor` finds a command's steps by the whole prompt (as today), or else by the prompt with its leading parenthesised hints taken off (each `(…)` at the start, and the space after it), so a hint put before a command doesn't hide its script. Existing keys that include a hint still match first. DEBUG only.

- [ ] **Step 1: Write the failing tests** (each `@Test(.enabled(if: HostedLanguageModel.isSupported, Comment(rawValue: supported)))`, building `VoiceAgent(model: app, testModel: ScriptedLanguageModel(script:closing:recorder:))` as `bench(_:)` does, on `VoiceFixture.loginAndProfile()`):
  - `aScreenChangeIsToldItsScreenInFullAndTheRestByName`: `run("make the title red", about: .screenEdit(login))` with an empty script. The first request's instructions contain `E2 button "Sign in"` and not `Your profile`. Its last prompt starts `(The person is changing S1, the screen "Login"` and ends ` make the title red`. `app.selection` isn't required (the hint doesn't read it).
  - `aScreenChangeCantReachAnotherScreen`: script `["make the profile title red": [styleElement E4 red]]`; `run(...about: .screenEdit(login))`: `outcome.problem` contains "isn't on S1"; the profile title's tint is unchanged.
  - `aScreenChangeIsOneUndoStepNamedChangeScreen`: for `groupsByEvent` in `[false, true]`, script `["make the button green and say continue": [styleElement E2 green, setText E2 Continue]]`: both happen; `undo.undoActionName == "Change Screen"`; one `undo.undo()` makes `app.store.content` equal to before; `undo.redoActionName == "Change Screen"`.
  - `aScreenChangeLeavesADragByHandItsOwnStep` (Review Focus 5): `let drag = app.store.beginEdit()`; inside `app.store.act(for: drag)`, move the button 10 pt right; then run the green-and-Continue command about `.screenEdit(login)`. `drag.isOpen` is still true and `app.store.isEditing(by: .hand)`. `app.store.endEdit(drag)`; one undo puts "Sign in" back and leaves the button 10 pt right; a second undo moves it back.
  - `aSpokenCommandStillSaysVoiceCommand`: `aCommandsUndoStepIsNamed` passes unchanged (run it; no edit).
  - `aCommandIsFoundInTheScriptBehindItsHint`: select the button; script `["make it blue": [styleElement E2 blue]]`; `run("make it blue", about: .thing(.element(button)))`: the button is blue.
- [ ] **Step 2:** Run `-only-testing:LayerTests/VoiceAgentTests`. Expected: fails to compile (`screenEdit` undefined).
- [ ] **Step 3:** Implement the interfaces above.
- [ ] **Step 4:** Run `VoiceAgentTests`, `VoiceToolsTests`, `UndoNameTests`, `ConcurrentEditTests`, `HostedToolCallingTests` and `PencilVoiceTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Screen edits: the agent changes one screen and what is on it, as one step named Change Screen"`

### Task 8: Push-to-talk listens for the field, and sends typed words

**Files:**
- Modify: `Layer/Voice/PencilVoice.swift`
- Test: `LayerTests/PencilVoiceTests.swift` (suite `PencilVoiceTests`)

**Interfaces:**
- Consumes: `VoiceCall.submit(_:about:)` (Task 5); `VoiceTarget.screenEdit` (Task 7).
- Produces (all on `PencilVoice`):
  - `private func beginListening(about target: VoiceTarget, at anchor: CGPoint, azimuth: Angle?)`: the tail of today's `squeezeBegan`, from selecting the target on (selection; retarget when this window's phone call is up; unavailable model → problem bubble; stopping other windows' pencils; `startCall`; opening the bubble `.gettingReady`; `mode = .listening(began:toggled: false:stale:)`; `listen`; `startHoldTimer`). `squeezeBegan` calls it unchanged in behaviour.
  - `func holdBegan(about screen: DesignScreen.ID, at anchor: CGPoint)`: ignored while a listen is open (`mode` is `.listening`) or while a phone call is up in another window; otherwise `beginListening(about: .screenEdit(screen), at: anchor, azimuth: nil)`. It doesn't check `squeezeIsOff()`, the tool, chrome, or the Squeeze to Talk setting.
  - `func holdEnded()`: sends a held listen (`.listening(_, toggled: false, _)`), however long it was held; otherwise nothing.
  - `var isListening: Bool`: whether `mode` is `.listening` (held or toggled). Not observed; read by VoiceOver's action.
  - `func prepare()`: starts the pencil's call (which warms the model) when none is up, no phone call is up here or elsewhere, and `readiness()` is `.ready`. As `hovered()`, without its Draw guard or throttle.
  - `func submit(_ text: String, about target: VoiceTarget) async -> Int?`: nil for blank text or a closed design; otherwise `startCall()`, `await starting?.value`, and, if the call is still this one, `call.submit(text, about: target)`.

- [ ] **Step 1: Write the failing tests** (with `Bench()`; `screen` is `bench.screen`; end each with `bench.end()`):
  - `holdingTheFieldListensAboutItsScreenAndLettingGoSends`: `holdBegan(about: screen, at: CGPoint(x: 500, y: 300))`: `eventually { bench.state == .listening }`; `bench.app.selection == .screen(screen)`; `pencil.bubble?.anchor == CGPoint(x: 500, y: 300)`. `holdEnded()`: `routes[0].finishCount == 1`. `routes[0].send(.command("make it dark"))`: eventually `runner.commands == ["make it dark"]` and `runner.targets == [.screenEdit(screen)]`.
  - `holdingTheFieldIsntASqueeze`: `pencil.squeezeIsOff = { true }`, `bench.app.tool = .draw`; `holdBegan(...)`: eventually `.listening`.
  - `holdingDuringAPhoneCallOnlySelects`: `await bench.app.startVoiceCall(route: FakeRoute(), runner: FakeRunner())`; `holdBegan(about: screen, at: CGPoint(x: 500, y: 300))`: `selection == .screen(screen)`, no bubble, `routes.isEmpty`, `pencil.retarget?.point == CGPoint(x: 500, y: 300)`.
  - `aSecondHoldWhileListeningIsIgnored`: two `holdBegan` calls: one route.
  - `typedWordsGoThroughThePencilsCall`: `let n = await pencil.submit("make the title red", about: .screenEdit(screen))`: not nil; eventually `runner.commands == ["make the title red"]`, `runner.targets == [.screenEdit(screen)]`, and `bench.app.selection == .screen(screen)` (selected as it started). `await pencil.submit("   ", about: .screenEdit(screen)) == nil`.
  - `typedWordsWaitTheirTurnBehindAHeldCommand` (Review Focus 5): `runner.holds = true`; `await bench.hold()`, `routes[0].send(.command("make it blue"))`, eventually running; `await pencil.submit("make it red", about: .screenEdit(screen))`: `pencil.call?.queuedCount == 1`; `runner.holds = false`: `runner.commands == ["make it blue", "make it red"]`.
  - `preparingGetsTheModelReadyOnce`: `prepare()` twice: eventually `runner.warmUps == 1` and no route started. A fresh `Bench()` with `pencil.phoneCallIsUp = { true }`: `prepare()` makes no call.
  - `voiceOverSpeaksAChangeWithOneUseAndSendsWithTheNext`: `isListening` false; `holdBegan(...)`; eventually `.listening` and `isListening`; `holdEnded()`: `routes[0].finishCount == 1`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/PencilVoiceTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement the interfaces above. Every existing `PencilVoiceTests` test must pass unchanged: `squeezeBegan`'s behaviour doesn't change.
- [ ] **Step 4:** Run `PencilVoiceTests`, `SqueezeRouterTests` and `VoiceCallTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Screen edits: push-to-talk listens while the field is held, and sends typed words in turn"`

### Task 9: The field's model

**Files:**
- Create: `Layer/Voice/ScreenEditor.swift`
- Modify: `Layer/App/AppModel.swift` (`screenEditor`, made on first use, as `pencilVoice` is)
- Test: `LayerTests/PencilVoiceTests.swift` (new suite `ScreenEditorTests`, using the file's `Bench`)

**Interfaces:**
- Consumes: `PencilVoice.submit`, `call`, `readiness` (Task 8); `VoiceCall.Progress`, `progress(of:)` (Task 5).
- Produces `@MainActor @Observable final class ScreenEditor`:
  - `init(model: AppModel)` (weak).
  - `func send(_ text: String, to screen: DesignScreen.ID) async -> Bool`: false, sending nothing, when the text is blank, `whyUnavailable()` isn't nil, that screen's last change is still under way, the screen is gone, or the design has closed. Otherwise it marks the screen as sending (observed), awaits `model.pencilVoice.submit(trimmed, about: .screenEdit(screen))`, and keeps the command's number for the screen (observed).
  - `func progress(for screen: DesignScreen.ID) -> VoiceCall.Progress`: `.working(nil)` while sending; `.over` with no number kept, or with no pencil call; else `call.progress(of: number)`.
  - `func isBusy(for screen: DesignScreen.ID) -> Bool`: `progress(for:)` is `.working`.
  - `func whyUnavailable() -> String?`: the reason when `model.pencilVoice.readiness()` is `.unavailable(reason)`. It can read the Keychain: the field calls it when it appears, when the selection changes, and on `ModelPreferences.changed`, never in `body`.
  - `AppModel.screenEditor: ScreenEditor`.

- [ ] **Step 1: Write the failing tests** (`let editor = ScreenEditor(model: bench.app)`; once `pencil.call` exists, set its `captionTimes = (done: .milliseconds(100), problem: .milliseconds(100))`):
  - `aChangeShowsItsStepThenItsReplyThenClears`: `runner.holds = true`; `await editor.send("make it dark", to: screen)` is true; `progress(for: screen)` is `.working`; `pencil.call?.showStep("Restyling…")` gives `.working("Restyling…")`; `runner.outcomes = [VoiceOutcome(lines: ["Restyled the screen."])]`, `runner.holds = false`: `until` `.done("Restyled the screen.")`, then `.over`.
  - `aBlankChangeSendsNothing`: `send("  ", to: screen)` is false and `runner.commands.isEmpty`.
  - `aSecondChangeToTheSameScreenWaitsForTheFirst`: `runner.holds = true`; first send true; second send to the same screen false; `runner.commands.count == 1`.
  - `changesToTwoScreensAreFollowedApart`: add a second screen through the store; `runner.holds = true`; send to the first: `progress(for: second) == .over`, `isBusy(for: first)` true.
  - `theFieldSaysWhyWhenNoModelCanBeAsked`: `Bench(readiness: .unavailable("Turn on Apple Intelligence."))`: `whyUnavailable() == "Turn on Apple Intelligence."`; `send` is false; no call is made.
- [ ] **Step 2:** `xcodegen generate`; run `-only-testing:LayerTests/ScreenEditorTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `ScreenEditorTests` and `PencilVoiceTests`. Expected: pass.
- [ ] **Step 5: Commit:** `git add -A && git commit -m "Screen edits: what the field sends and how it is getting on"`

### Task 10: The field in a screen's bar

**Files:**
- Create: `Layer/Chrome/ScreenEditField.swift`
- Modify: `Layer/Chrome/SelectionActions.swift`
- Modify: `Layer/Debug/VoiceDemo.swift` (`ScreenEditDemo`, and its branch in `VoiceDemo.runIfRequested`)
- Modify: `LayerUITests/VoiceModeUITests.swift` (three tests)

**Interfaces:**
- Consumes: `AppModel.screenEditor` (Task 9); `PencilVoice.holdBegan`, `holdEnded`, `isListening`, `prepare`, `script(route:runner:)`, `readiness` (Task 8); `VoiceDemo.runner(for:freeze:model:step:)`, `VoiceDemo.prepareCanvas(of:)` and the file's private `DemoRoute(lines:freeze:endsWhenTold:isBusy:)`.
- Produces:
  - `struct ScreenEditField: View { let screen: DesignScreen.ID }`, 44 pt tall, 240 pt wide (150 when `model.isCompactWidth`), showing one of:
    - **unavailable**: the reason in secondary text; disabled (no tap, no hold, no actions);
    - **working**: the step text (`.working(nil)` shows "Thinking…");
    - **reply**: the `.done`, `.said` or `.problem` text, a problem in the secondary style;
    - **typing**: a plain `TextField("Describe a change…")`, focused, `submitLabel(.send)`, with a `ToolButton(symbol: "arrow.up.circle.fill", label: "Send change")` after it while the text isn't blank;
    - **idle**: the placeholder "Describe a change…" as plain text.
  - Idle or reply: a tap starts typing; a 0.35 s hold (`LongPressGesture` sequenced before `DragGesture(minimumDistance: 0)`, `@GestureState isHeld`, enabled only when not typing, unavailable or working) calls `holdBegan(about: screen, at: the field's global centre)` as `isHeld` turns true and `holdEnded()` as it turns false (released or cancelled: both send).
  - Send (Return or the arrow): keep the text, clear the field, end typing (focus off), then `Task { await model.screenEditor.send(text, to: screen) }`. Typing that ends with blank text goes back to idle.
  - On appear: `model.pencilVoice.prepare()` and read `whyUnavailable()`; read it again on `ModelPreferences.changed`.
  - Accessibility: label "Describe a change", value the line shown; the idle line is a button whose action starts typing; a named action "Speak a change" calls `holdEnded()` when `pencil.isListening`, else `holdBegan(...)`.
  - `SelectionActions`: in the single-selection branch, before "Format selection", `if case .screen(let id) = model.selection { ScreenEditField(screen: id).id(id) }`. Nothing else in the bar changes. A locked screen keeps its Unlock-only bar.
  - `ScreenEditDemo` (DEBUG): launch with `-LayerVoiceDemoDesign login -LayerScreenEditDemo "<typed or said> => <what comes of it>"` (results written as for `-LayerVoiceDemo`), and optionally `-LayerScreenEditDemoUnavailable "<reason>"`. It prepares the canvas, scripts the pencil (route: a `DemoRoute` with `endsWhenTold: true`; runner: `VoiceDemo.runner`, its steps shown through `model.pencilVoice.call?.showStep`), sets `readiness` (`.unavailable(reason)` or `.ready`), sets the tool to Select, waits for the canvas to be laid out and fits it (as `PencilDemo.run` does), and **only then** selects the first screen: the field's appearing starts the pencil's call, which must already be scripted.

- [ ] **Step 1: Write the failing UI tests** in `VoiceModeUITests` (full width; no resize), launching with `["-convertsAutomatically", "NO", "-LayerVoiceDemoDesign", "login", "-LayerScreenEditDemo", "make the button green and say Continue => styleElement element=E2 look=green && setText element=E2 text=Continue"]` (no apostrophes in launch arguments):
  - `testATypedChangeToAScreenIsMadeAndUndoneInOneStep`: `control("Describe a change")` appears within 20 s; tap it; `app.typeText("make the button green and say Continue\n")`. `app.staticTexts["Continue"]` appears within 15 s, and the field's value contains "Reworded". `control("Undo").tap()` once: "Sign in" is back and "Continue" is gone. `shoot("screen-edit-reply")` before the undo.
  - `testHoldingTheChangeFieldSpeaksTheChange`: `control("Describe a change").press(forDuration: 5)`; "Continue" appears within 15 s.
  - `testTheChangeFieldSaysWhyItCannotBeUsed`: also `"-LayerScreenEditDemoUnavailable", "Apple Intelligence is turned off"`; the field's value contains "Apple Intelligence is turned off" and `isEnabled` is false.
- [ ] **Step 2:** Run the three tests. Expected: fail (no field).
- [ ] **Step 3:** `xcodegen generate`. Implement `ScreenEditField`, the bar's branch and `ScreenEditDemo`.
- [ ] **Step 4:** Run the three tests. Expected: pass. Run `testThePaletteComesBackWhenTypingEndsInDraw` (`SketchFlowUITests`) and `testASpokenCommandChangesTheCanvas`: still pass.
- [ ] **Step 5: Look** (simulator, `-LayerScreenEditDemo` as above): the bar for a selected screen at full width and at 375 pt wide (`resizeWindow(toWidth:)` in the UI tests, or by hand): the field fits beside Format, Duplicate, Lock and Delete, and the bar stays in the window. While typing, the bar sits above the keyboard.
- [ ] **Step 6: Commit:** `git add -A && git commit -m "Screen edits: a selected screen's bar takes a typed change, or a held one spoken"`

### Task 11: The whole suite, pictures, README and the device checklist

**Files:**
- Modify: `README.md` ("A real canvas" and "Freeform-style objects")
- Modify: this plan (an **Outcome** line under the header)

- [ ] **Step 1:** Run all unit tests twice. Expected: no failures beyond the baseline's known timeouts (rerun a timeout alone; it must pass).
- [ ] **Step 2:** Run the whole UI suite (`-testPlan Layer -only-testing:LayerUITests`). Compare failures with the two known on main; report every failure and say which are new. New ones are fixed before going on.
- [ ] **Step 3: Pictures** (attach with `shoot`, or `xcrun simctl io "$SIM" screenshot`): the bottom-left control without −/+; the zoom menu open; the screen's bar idle, typing, working and with a reply; the field unavailable. The zoom ruler itself is photographed on the device (XCUITest can't pause mid-hold).
- [ ] **Step 4: README.** In "A real canvas": hold the zoom percentage and drag, or hover the Pencil Pro over it, squeeze and roll the barrel, to step through zoom stops; tap it for the menu. In "Freeform-style objects": a selected screen's bar takes a typed change to the screen and everything on it ("make the buttons rounded"), applied straight away as one undo step; hold the field to say it instead.
- [ ] **Step 5:** Commit: `git add -A && git commit -m "Zoom ruler and typed screen edits: README and outcome"`
- [ ] **Step 6: Device checklist** (the user's iPad mini with Apple Pencil Pro, only with the user's go-ahead; merge to main first and install main, as the voice-mode work did):
  - [ ] Hover the Pencil over the zoom percentage and squeeze: the ruler comes up; rolling steps one stop per 10°, with a tick each; squeezing again keeps the zoom, **with no bubble**, including with the pen moved over the canvas.
  - [ ] A finger held 0.35 s on the percentage and dragged: 16 pt a stop feels right; letting go never opens the menu; a tap does.
  - [ ] Squeeze over a Format field (Select): its ruler, as before. With Draw on, a squeeze anywhere (Format panel open or not) brings up PencilKit's palette; nothing scrubs.
  - [ ] A squeeze over the canvas still starts push-to-talk; a toggle is still sent by the next squeeze over a field.
  - [ ] VoiceOver: the zoom control adjusts stop by stop and opens its menu; the field's "Speak a change" listens, and a second use sends.
  - [ ] Typed change: the keyboard stays while typing; in Draw the palette comes back when typing ends; one Undo takes the whole change back; the reply shows for a few seconds.
  - [ ] Hold the field: the bubble opens at the field, listens while held, sends on release. During a phone call (narrow window), holding only selects the screen.
  - [ ] At full width, the field is the way into voice: say a change and see it made.
  - [ ] After the Squeeze to Talk branch is merged, with it off: a squeeze over the canvas does the system's action; a squeeze over a Format field or the zoom still scrubs. Note how long the pen must hover a field before a squeeze is caught (the window's handler comes when the hover begins).
  - Record the results in this plan's Outcome line.

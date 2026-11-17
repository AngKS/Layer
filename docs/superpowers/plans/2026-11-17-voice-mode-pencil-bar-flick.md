# Voice Mode, Part 6: Flicking the Pencil Bar Away

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In a narrow window, a flick sideways or downward on the pencil bar puts the bar away and ends drawing, so the bottom-right corner is the phone button's again.

**Architecture:** PencilKit gives the narrow window's bar no flick of its own and no word when it is touched. A gesture recogniser that only watches, and never takes a touch from anything, notices a touch that begins on the bar and ends a flick away. Whether touches on the system's bar reach a recogniser on the app's window was the open question, and the simulator test settled it: they don't. The bar is in a system window of the same scene, so there is one recogniser on each window of the scene, and each asks the canvas whether a touch began where the bar is.

**Outcome (2026-11-17):** Built and passing in the simulator. Two things differ from the plan below. The recogniser is told whether a touch is on the bar (`isOnBar`) and is not given the bar's frame, because it sits on windows whose coordinates aren't the canvas's. And, decided while this was being built: while Draw is on there is no phone button at all, where before it sat under the bar (`AppModel.offersVoiceMode`).

**Tech Stack:** UIKit gesture recognisers, PencilKit (`PKToolPicker.frameObscured(in:)`), XCUITest.

**Spec:** `docs/superpowers/specs/2026-11-17-voice-mode-design.md` ("The pencil bar in the narrow window", build order stage 6, and the risk "Catching a flick on the system's pencil bar may not be possible").

## Global Constraints

- The bar is not moved, restyled or covered. The recogniser sets `cancelsTouchesInView = false` and recognises alongside everything.
- Only in a narrow window (`isCompactSizeClass`). A wider window's floating palette tucks itself away.
- If the flick can't be caught, nothing ships for it: Draw in the "…" menu stays the way to put the bar away, as the spec's fallback says.

## Review Focus

1. **A tap or a drag on a tool in the bar** (choosing a pen, dragging the colour): must not put the bar away. → Task 1, `aFlickAsideOrDownIsOneAndAnythingElseIsNot`.
2. **A stroke drawn on the canvas that starts just above the bar and crosses it:** isn't a flick on the bar, because it didn't begin there. → Task 1, the recogniser only follows touches that begin inside the bar's frame.
3. **A wider window:** unchanged. → Task 1, `aWiderWindowKeepsItsPalette`.

---

### Task 1: Catch the flick

**Files:** Modify `Layer/Canvas/InkCanvas.swift` (new `PaletteFlick` recogniser beside `PencilDetector`; wiring in the coordinator), `Layer/App/AppModel.swift`. Test: `LayerTests/VoiceCallTests.swift` (`PencilBarFlickTests`), `LayerUITests/VoiceModeUITests.swift`.

**Interfaces:**
- `final class PaletteFlick: UIGestureRecognizer` with `var isOnBar: (UITouch) -> Bool` (never true while the bar isn't up; as first planned, `var barFrame: () -> CGRect`), `var onFlick: () -> Void`, and `static func isFlick(_ translation: CGSize) -> Bool`: sideways by at least 50 points and more sideways than up or down, or downward by at least 40 points and more downward than sideways. A flick is also quick: under 0.6 s from touching down to lifting.
- `AppModel.pencilBarFlickedAway()`: in a narrow window with Draw on, sets `tool = .select`; otherwise nothing.
- `AppModel.offersVoiceMode: Bool`: whether the phone button is shown. True only in a narrow window with Draw off, no call up and no panel open.

- [ ] **Step 1: Write the failing tests.** Unit: `aFlickAsideOrDownIsOneAndAnythingElseIsNot`, `flickingTheBarAwayInANarrowWindowEndsDrawing`, `aWiderWindowKeepsItsPalette`. Simulator: `testFlickingThePencilBarAsidePutsItAway` (Draw on in a narrow window, flick along the bar, the bar is gone and the phone button can be tapped; Draw brings it back; a flick down puts it away again).
- [ ] **Step 2:** Run `PencilBarFlickTests`. Expected: fails to compile (`PaletteFlick` undefined).
- [ ] **Step 3:** Implement `PaletteFlick`, add it to the window where `PencilDetector` is added, enable it only while the bar is up in a narrow window, and implement `pencilBarFlickedAway()`.
- [ ] **Step 4:** Run `PencilBarFlickTests`. Expected: pass.
- [ ] **Step 5:** Run `testFlickingThePencilBarAsidePutsItAway` in the simulator. This is the spike.
  - **Passes:** the flick can be caught. Run the other voice UI tests and `SketchFlowUITests` to see drawing and the bar's own controls are untouched. Commit: "Narrow window: a flick on the pencil bar puts it away".
  - **Fails because the recogniser never sees the touch:** the system's bar takes its touches where the app can't see them. Remove `PaletteFlick`, its wiring and its simulator test; keep nothing that doesn't work. Record the finding in the spec's risk and in the ledger. Commit: "Pencil bar flick: not catchable; Draw in the menu stays the way".

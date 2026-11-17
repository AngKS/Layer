# Pencil push-to-talk: design

Date: 2026-11-18. Status: awaiting approval. Branch: `feature/pencil-ptt`.

## Intent

Voice mode today is a call: a phone button in the narrow window, a pill along the bottom, and
commands that end when the speaker pauses. At full width on an iPad there is no way into it at
all (`AppModel.offersVoiceMode` requires a compact size class).

This brings voice to the Pencil, where the person's attention already is. With Draw off, the
Pencil keeps acting as a selector, as it does now. Hovering outlines what is under the tip (as
it does now). **Squeezing an Apple Pencil Pro** while hovering swivels a small bubble out of the
pen tip: the model's icon beside a live waveform. The person speaks, and the command goes to
voice mode's agent:

- hovering an **element or a screen**: the command is an edit to that thing;
- hovering **empty canvas**: the command makes new screen(s), placed where the pen was.

Typed screen generation leaves the top bar (the magic wand goes) and moves into the component
library's search: a search that finds nothing becomes a request for a screen.

## Goals

1. **Two squeeze styles (the user's decision):**
   - **Quick squeeze toggles.** A squeeze released quickly starts listening; the next squeeze
     sends what was said.
   - **Hold is push-to-talk.** A squeeze held past the quick threshold listens for as long as it
     is held; releasing sends.
   - The microphone starts on the squeeze's start in both cases, since which kind it is is only
     known at release.
2. **The target is what the pen hovered at the squeeze's start** and does not follow the pen
   while speaking. It becomes the selection (the agent already reads `[selected]` as "this").
   Over empty canvas the selection is cleared and the pen's canvas point is remembered as where
   new screens go.
3. **The bubble** opens at the squeeze point, on the side **opposite the barrel** (from the
   hover pose's azimuth), so the hand doesn't cover it, kept inside the window and clear of the
   top bar. It stays where it opened even if the pen leaves hover range. Contents: the model's
   icon and the live waveform (`CallWaveform`), nothing else by default.
4. **A setting toggles words in the bubble** (the user's decision, to try both): off, waveform
   and icon only; on, the words heard so far appear under the waveform and the bubble grows to
   fit (two lines at most, newest words kept). The user will decide after trying it.
5. **After sending**, the bubble collapses to the model icon with a spinner, then a tick, then
   fades. A problem shows as one short line even with words off, so a failure is never silent.
6. **The model stays warm across squeezes.** One agent (and its language model session) lives
   for the design, so only the first command of the design pays the cold start (14–19 s on the
   iPad mini; 0.7 s warm). Warming starts on the first Pencil hover over the canvas. Speech
   recognition is prepared then too. The **microphone is only on between squeeze and send**:
   hover never turns it on.
7. **Feedback through the Pencil Pro's haptics**: a tap when listening has actually begun, and
   one when the command is sent.
8. **The wand goes** from the top bar (`ToolsBar`) and from the narrow window's tools menu
   (`ToolsMenu`). `GenerateScreenPanel` goes; `GenerationStatus` stays.
9. **Library search generates.** When a search finds nothing in any tab, the empty result shows
   a small diagram and an instruction instead of today's "Nothing matches" text:
   `"<query>" → no component → [a new screen]`, with "Press Return to generate this screen
   with <model>" and a Generate button. Return or the button calls
   `AppModel.generateScreen(from:)`, closes the library, and the screen appears as it does today.
   When the search does find something, Return still places the best match.
10. **Library search shows mixed results (the user's decision).** A search looks in every tab at
    once: "mac" shows the Mac icon and the Mac wireframes together. Today a search shows only the
    current tab's matches and jumps to the tab with the strongest match
    (`AssetLibrary.bestMatch`, the `onChange(of: search)` in `AssetLibraryView`). That jump goes.
    My calls on how it looks: while searching, the results are grouped under a heading per kind
    (Icons, Wireframes, Shapes, Components), each group in its best-first order, and the groups
    ordered by their strongest match. Empty groups aren't shown. The tab picker stays visible but
    doesn't filter while a search is typed; clearing the search returns to the tab that was open.
    Return places the strongest match overall. "Nothing in any tab" (the condition for goal 9) is
    every group being empty.

## Non-goals

- Pencils without squeeze (Apple Pencil 2, USB-C, first generation) and fingers get no
  push-to-talk. They keep the phone button (narrow window) and the library's typed generation.
- No phone button at full width in this work.
- Draw mode is unchanged: there, squeeze is PencilKit's (the palette at the tip).
- The model doesn't speak back.

## Anti-goals

- The microphone lighting up from hovering.
- A squeeze that silently does nothing visible (no bubble, no haptic) while the person talks.
- Controls repositioned around the palette or the bubble (see the interaction preferences: plain
  corners, system behaviour first).
- Losing work in flight: a new squeeze, or a phone call starting, must never cancel a command
  that is already running.

## Edge cases and how they behave

| Case | Behaviour |
|---|---|
| Squeeze over a Format panel slider | The scrubber keeps it, as today. Squeezes over any chrome (`chromeFrames`, top bar) don't start voice. |
| Squeeze with Draw on | PencilKit's, unchanged. |
| Squeeze with the pen out of hover range (no hover pose) | Ignored: there is no target and nowhere to put the bubble. |
| Hovering a drawing | Drawings are skipped for targeting (voice can't edit ink): the target is the screen or canvas beneath. |
| Hovering one thing in a multi-selection | The target is the whole selection. |
| Hovering an element in a screen | The element (topmost wins, as `hoverTarget` does now). The screen is targeted by hovering its frame or name. |
| Quick squeeze, then nothing said, then squeeze | Nothing is sent; the bubble closes. |
| Toggle mode left listening | Ends after 20 s with nothing heard, sending nothing (my call on the length). |
| Saying "cancel" / "stop" | Discards what is being heard, as in a call. Tapping the bubble with a finger also cancels. |
| A squeeze while the last command is still running | Listening starts; the new command queues behind the running one (the bubble shows `+1`, as the pill does). The new bubble replaces the old one's place. |
| A squeeze while a phone-button call is up | No bubble, no second microphone: the squeeze only retargets (sets the selection to the hovered thing, with a haptic). The call hears the command. |
| Starting a phone call while a pencil command runs | The command finishes; the call starts listening alongside. |
| First squeeze ever | The microphone/speech permission prompts appear; nothing is recorded on that squeeze. |
| Model unavailable (Apple Intelligence off, no key) | The bubble opens with the problem line and doesn't listen. |
| Words before the microphone is on | The bubble shows a dim waveform until listening has begun, then the haptic. How long that gap is on the iPad is measured; if it loses words, audio is buffered from the squeeze's start. |
| System squeeze preference set to "off" (`UIPencilInteraction.preferredSqueezeAction == .ignore`) | Respected: no push-to-talk. |
| The design closes or the app goes to the background | Listening stops and nothing is sent; a running command is left to finish as it does today. |
| Locked target | Whatever voice mode does today for locked elements. |

## Constraints

- Squeeze, hover pose and Pencil haptics exist only on a real iPad with an Apple Pencil Pro. The
  simulator can't produce them. The user's iPad mini ("AKS Mini") is the test device.
- It's unknown whether PencilKit's own squeeze handling (palette at the tip) fires in select mode
  while `PKCanvasView` is first responder. That's checked on the device first, before the rest is
  built on it.
- Swift 6 main-actor isolation: framework callbacks off the main thread (microphone tap) must
  stay `nonisolated`/`@Sendable`, the crash the first device run found.
- Speech recognition and Apple Intelligence fail in the simulator. Logic is unit-tested with the
  existing fakes, and the UI is driven by a DEBUG launch hook.

## Approaches

- **A. Teach `VoiceCall` a second way to end a command (chosen by the user).** A route can be
  told to settle and emit now (`finish`) instead of waiting for a pause, and a call can be shown
  as the pencil bubble instead of the pill. One pencil call lives for the design, idle between
  squeezes, with its listening opened per squeeze, so its queue, warm agent, captions and
  "stop" handling carry over. Cost: the call learns about a presentation and a fixed target.
- **B. A separate pencil session beside the call.** Simpler bubble code, but it duplicates the
  queue/caption half of `VoiceCall` and needs its own wiring for squeezing during a call.
- **C. Keep the microphone open while hovering.** The fastest start, but the microphone indicator
  would light up on hover. Rejected.

## Decided by the user

- Quick squeeze toggles; hold is push-to-talk.
- Over an element or screen: edit it. Over canvas: make new screens.
- The bubble: model icon and waveform only, swivelling out at the tip; a toggle to try showing
  words; placed opposite the barrel.
- The wand leaves the top bar; typed generation moves into the library search, with an empty
  state diagram/instruction.
- Library search shows mixed results across tabs ("mac" shows the Mac icon and Mac wireframes).
- Approach A. Branch `feature/pencil-ptt`.

## My calls (correct any of them)

- The target becomes the selection; over canvas, the selection is cleared and new screens are
  placed at the pen's point (an anchor passed to the screen placement), not in the middle of the
  view.
- Over canvas, the agent is told "the person pointed at empty canvas, so a description means a
  new screen there". Commands like "zoom out" or "show the login screen" still work.
- Drawings are skipped as targets.
- The words toggle lives in Model Settings under a Voice heading, off by default (the user's
  original look).
- A problem line shows even with words off.
- Toggle mode times out after 20 s of silence.
- During a phone call, a squeeze only retargets.
- The quick/hold threshold starts at 0.35 s and is tuned on the device.
- **A pause never ends a pencil command.** While a squeeze is listening (held, or toggled on),
  the pause-based ending is switched off: only the second squeeze or the release sends, so a
  thinking pause mid-sentence doesn't send half a command. The route needs a mode where only
  `finish` ends a command. The phone call keeps pause-based ending.
- **Each pencil command carries its own target.** A queued command keeps the target (or the
  canvas anchor) captured at its squeeze and has it restored as the selection when it starts
  running, so a later squeeze can't redirect it. The selection on screen follows the latest
  squeeze until an earlier queued command starts, then shows that command's target while it
  runs. That changes the call's queue from words to words-plus-target.
- **Only starting needs the pen in hover range.** The squeeze that ends a toggle, or the release
  that ends a hold, sends whatever the hover pose, so a toggle can't get stuck when the pen
  drifts away.

## Left to the builder

- The swivel animation (a spring from the tip with a slight rotation is the intent).
- The bubble's exact offset and size, and the diagram's drawing (SF Symbols or a small SwiftUI
  drawing, in the library's existing style).
- How the pencil call is held on `AppModel` and how listening is opened and closed on it, within
  approach A.
- How the DEBUG launch hook simulates a squeeze (start/end at a point, with an azimuth).
- Tests: unit tests for the route's `finish`, quick-vs-hold classification, target capture,
  bubble placement from azimuth and the library's generate condition; UI tests updated where they
  used the wand; a device checklist for the squeeze, haptics, the palette conflict and the
  latency to listening.

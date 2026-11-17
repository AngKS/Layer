# Voice mode: design

Date: 2026-11-17. Status: awaiting approval.

## Intent

Voice mode lets someone design hands-free. They put the iPad down, watch the canvas, and speak:
"I want a simple login screen", "make the button half width", "show me the first screen". The
model does the work on the canvas while they watch. Now and then a finger pans the canvas to
look around.

It is presented as a call. A phone button starts it, a call pill shows that Layer is listening,
and a red button ends it.

## Goals

1. In the narrow window, a phone button sits in the bottom-right corner, in place of the marker
   button (`PaletteToggle`).
2. Tapping it starts a call. The zoom and undo control goes, and a call pill sits along the
   bottom: glass tinted from the canvas background colour, the model's icon, the call time, a
   live waveform under the time, and a red end button.
3. While the call is up, spoken commands:
   - create whole screens from a description;
   - change what is on a screen: colour, size, position, alignment, words (including rewriting
     them in a style), adding, duplicating and deleting elements;
   - move the canvas: show a named, numbered, first, newest or "other" screen, show an element,
     zoom, and undo or redo.
4. An edit pans the canvas to its element before changing it.
5. It works with every model Layer offers. OpenAI gets the audio itself, live. Every other
   provider gets the words: speech is turned into text on the iPad, and the text goes to the
   model. Text is also the fallback whenever live audio can't be used.
6. It is hands-free once started. A pause ends a command. The next command can be spoken while
   the last one is still running; they run in order.
7. Each spoken command is one undo step, and "undo that" works by voice.

## Non-goals

- The model speaking back. Feedback is on screen only.
- Wide windows. The phone button exists only in the narrow window for now. A call that is
  already up stays up if the window is widened.
- Private Cloud Compute as a model. Layer doesn't offer it yet. The design leaves it a slot.
- Listening in the background, or a wake word.
- Drawing ink, making images, or managing design files by voice.
- A setting for which OpenAI realtime model is used.

## Anti-goals

These would make voice mode a failure even if it worked.

- **A change nobody can see or take back.** Every command shows what was heard and what was
  done, and every change goes through `DesignStore` exactly as the same change made by hand.
- **A microphone that is on without it being obvious.** Listening only happens while the pill is
  up and Layer is at the front.
- **Controls that shuffle around the pencil bar.** Corner controls keep plain margins, as agreed
  on 2026-11-16. The system's bar may sit over them.
- **A canvas that freezes while the model thinks.** Panning and zooming stay live throughout.

## Constraints

Checked on 2026-11-17 against the iPhoneOS 27.2 SDK's `FoundationModels` and `Speech` interfaces,
Apple's documentation, and OpenAI's documentation.

- Deployment target is iPadOS 27.0. Dynamic profiles are available from 27.0. Layer's hosted
  models need 27.2 (`HostedLanguageModel.isSupported`); on earlier systems a hosted choice already
  falls back to Apple Intelligence.
- Apple Intelligence can't answer in the simulator, so the agent must be testable without it.
- Anthropic's API has no audio input. OpenAI takes live audio only through its Realtime API and
  its realtime models (`gpt-realtime-2.1` in the current documentation), not through the chat
  model a design has picked.
- The on-device model has a small context. Its size is `SystemLanguageModel.default.contextSize`
  and `tokenCount(for:)` measures instructions, tools and transcript entries.
- PencilKit decides the pencil bar's style in a narrow window: a bar fixed across the bottom,
  with no public way to move it or to be told about a flick on it.
- Layer has no microphone permission text yet. `NSMicrophoneUsageDescription` goes in
  `project.yml`. Speech recognition assets may need downloading on first use (`AssetInventory`).
- API keys are the person's own, in the Keychain (`APIKeyStore`).

## Checked by experiment

A throwaway harness on macOS 27.2 ran a scripted custom `LanguageModel` through
`LanguageModelSession`. It is not part of the project. With that model:

- **The framework's tool loop works for custom models.** The session runs tool calls that a
  custom executor sends on its channel, then calls the executor again with the calls and their
  outputs in the transcript.
- **Dynamic instructions are re-evaluated between tool rounds** inside one `respond` call, not
  only between commands. A session property written by a tool appeared in the instructions of the
  very next request.
- **A profile switch takes effect on the next request.** Changing a session property that the
  profile's body reads deactivated one profile, activated the other, and sent the next request to
  the other model with the history intact.
- **Several tool calls in one answer run at the same time, in no fixed order.** Two tools writing
  one session property at once crashed the process.
- **`historyTransform` is handed the instructions entry along with the history.** A transform
  that keeps only the last few entries drops the instructions.
- **Cancelling the task that awaits `respond` cancels the running tool at once.** `respond` throws
  a `ToolCallError` wrapping `CancellationError`.
- **A throwing `onToolCall` hook skips the tool,** and `respond` throws.

Not yet run: the same on iPadOS, and with the on-device model.

## Approaches

How a spoken sentence becomes changes on the canvas.

1. **One answer holding a list of commands.** The model is given the sentence and what is on the
   canvas, and answers once in a fixed structure that Layer runs. It works with every model
   today and costs one wait per sentence, but the model can't look, act and correct itself.
2. **Tools the model calls one at a time.** The model is given Layer's actions as tools and calls
   them. It handles long, many-part requests better. It costs a wait per step, needs tool calling
   built for the hosted models, and Layer's sketch benchmark found the on-device model slower and
   no more accurate with a tool round trip.
3. **Phrase rules for canvas moves, a model for the rest.** Dropped: speech varies too much for
   rules to hold. It could be added later for speed.

**Chosen: 2**, by the user, who also pointed at Foundation Models' dynamic profiles as the way to
build it. Dynamic profiles remove most of what approach 2 costs:

- Instructions are re-evaluated before every request to the model, so the model always holds a
  current picture of the canvas. It never spends a round trip looking things up; tools are only
  for acting.
- `historyTransform` trims what is sent to the model without touching the stored transcript,
  which keeps the on-device model within its context on a long call.
- One profile can switch model, instructions and tool set as the design's model or the canvas
  changes.

## Design

### What the person sees

**The phone button.** Bottom-right corner of the narrow window, pinned with the existing
`BottomCorner` margins. A 56-point glass circle with a phone symbol, shown when the window is
narrow, no call is up and no panel sheet is open. It is not moved for the pencil bar.

**The pill.** Bottom centre, in place of `ViewControls`, which is hidden for the length of the
call.

```
+----------------------------------------------+
| (model)  0:42                          (end) |
|  icon    ..:|||:..:|:.                  red  |
+----------------------------------------------+
```

- Glass tinted with `store.canvas.resolvedBackground`. Text and symbols must stay readable on
  light and dark backgrounds.
- Left: the design's model symbol (`ModelChoice.symbol`) in a circle. Middle: the call time, with
  a waveform beneath it that follows the microphone level. Right: a red circular end button.
- The pill grows by one line, in the manner of the Dynamic Island, when there is something to
  say, and shrinks back afterwards:
  - **Hearing:** the words as they are recognised.
  - **Working:** "Thinking…", then each step as a tool runs. A screen being generated shows its
    progress here, and the separate `GenerationStatus` capsule stays hidden during a call.
  - **Done:** what was done, for about three seconds.
  - **Problem:** what went wrong, in plain words, for about six seconds.
- The pill reports its frame with `reportsChromeFrame`, so a Pencil touch on it isn't a canvas
  touch.

**Starting.** Tapping the phone button asks for the microphone the first time, fetches speech
assets if needed (the pill says it is getting ready), turns Draw off so the pencil bar goes and a
finger pans, then starts listening. The timer starts when listening does. If the microphone is
refused, or the design's model can't be used (Apple Intelligence off, no API key), the call
doesn't start and the person is told why, with the existing readiness wording.

**Ending.** The red button, saying so ("hang up"), closing the design, Layer leaving the front,
or an audio interruption. Ending stops the microphone at once. Work already under way finishes or
is cancelled; either way the design is left in a state one undo step can reverse.

**Stopping a command.** Saying "stop" or "cancel" on its own cancels the running command and
clears the queue. It is matched on the iPad and never sent to a model. It cancels the task that
is waiting on the model, which cancels the running tool. The create screen tool passes the
cancellation on to the generator, which keeps what it has written so far. `onToolCall` refuses
any further tool call for a cancelled command. What the command did before it was stopped is
still one undo step.

**The pencil bar in the narrow window.** `PaletteToggle` and `isPaletteCollapsed` are removed.
Draw in the "…" menu puts the bar up; turning it off puts the bar away. A flick sideways or
downward on the bar also puts it away and ends drawing, so nothing is left behind and a finger
goes back to selecting and panning. During a call the Draw item is disabled. Drawing and voice
mode are one or the other: while Draw is on there is no phone button, and it comes back when
the bar is put away. A design opens with Draw on, so that is how a call is reached.

### How it is built

Suggested home: a new `Layer/Voice/` folder. Names below are suggestions.

**`VoiceCall`.** Main-actor, observable, owned by `AppModel`. It holds the call's state (starting,
listening, hearing, working, ended), start time, microphone levels for the waveform, the caption,
and the queue of spoken commands. There is one call at a time across all windows: starting a
call in another window ends the first, which needs a small piece of app-wide state.

**`MicrophoneTap`.** `AVAudioSession` and `AVAudioEngine`. It publishes audio buffers and levels.
It sits behind a protocol so tests and a debug hook can feed recorded or synthesised audio.

**Two routes behind one protocol.** A route turns audio into events for `VoiceCall`: words being
heard, a finished command, a tool starting, a tool finishing, something the model said, a
failure. The route is chosen when the call starts.

- **Dictation route**, for every provider. `SpeechAnalyzer` with a progressive transcriber gives
  words as they are heard and a final text at each pause. Screen names and element words are given
  to the recogniser as context so it hears them correctly. Each final text is a command and goes
  to the voice agent below.
- **Live audio route**, for OpenAI. A WebSocket to the Realtime API: 24 kHz PCM in, text only
  out, server-side detection of pauses with automatic replies turned off. When a turn is
  committed, Layer asks for a reply and supplies the current canvas picture with that request.
  The model answers with function calls, which run the same tools. Input transcription is on so
  the pill can show what was heard. If the connection can't be made, the call falls back to the
  dictation route with the design's own OpenAI model and says so in the pill.

**The tools.** One set of Foundation Models `Tool`s, used by both routes. Each is a thin
main-actor wrapper over what the Siri actions already call (`DesignActions`, `DesignStore`,
`AppModel`), so behaviour matches the intents.

| Tool | Does |
|---|---|
| create screen | Adds a screen and writes it with the design's own model, through the existing streaming generator. Returns when the screen is finished. |
| add element | Adds an element of a kind to a screen. |
| set text | Changes an element's words. The model writes the new words. |
| style element | Applies look words ("blue, bold, 18pt, text white"), using the look parser Layer already has. |
| move or resize element | Sets position and size, in points or as a share of the screen. |
| align element | Left, centre, right, top, middle or bottom of its screen. |
| duplicate element, delete element | As named. |
| rename screen, delete screen | As named. |
| show | Glides the canvas to a screen, an element, or everything. |
| zoom | In, out, or to a level. |
| undo, redo | The design's own undo history. |
| end call | Hangs up. |

Principles for the tools:

- Few tools, each with a few flat arguments. The on-device model is small.
- Screens and elements are named by short handles (S1, E7) that stay fixed for the whole call. A
  table kept by `VoiceCall` maps them to real identifiers.
- A tool that changes an element first selects and reveals it (`DesignActions.reveal`), which
  gives the pan-then-edit behaviour and makes "it" refer to that element next time.
- Each tool returns one short line saying what it did. The pill shows that line; the model's own
  closing words are shown only when no tool ran.
- One at a time. Hosted providers are asked not to make parallel tool calls (OpenAI
  `parallel_tool_calls: false`, Anthropic `disable_parallel_tool_use`). Every tool does its work
  in a single main-actor step, and session properties are written only on the main actor, so
  calls that do arrive together are safe in either order.

**The canvas picture.** A `DynamicInstructions` type that lists the screens and their elements
with handles, kinds, words, frames and colours, and marks what is in view and what is selected.
It reads a sendable snapshot from a custom session property (`@SessionPropertyEntry`), which
`VoiceCall` refreshes from the store before each command and after each tool finishes. It comes
in two levels of detail: full, and compact (the screen in view in full, the others by name and
element count). The compact form is measured with `tokenCount(for:)` and cut down further if it
would not fit.

**The voice agent.** One `LanguageModelSession(profile:)` per call. `VoiceProfile` is a
`DynamicProfile` whose body picks one `Profile` from the design's model choice, itself a session
property:

- **Hosted model:** the rules, the full canvas picture and the tools, with `.model(…)` set to the
  `HostedLanguageModel`, and a history transform that keeps the instructions entry and the
  recent turns.
- **Apple Intelligence:** shorter rules, the compact canvas picture, only the tools that make
  sense for the canvas as it is (an empty design gets create, show and zoom), a tighter history
  transform and a low response limit.
- **Private Cloud Compute, later:** a third branch with `.model(PrivateCloudComputeLanguageModel())`.

`onToolCall` and `onToolOutput` drive the pill's working line and refresh the canvas picture.
Commands are sent one at a time from the queue with `respond(to:)`.

**Tool calling for hosted models.** `HostedModelExecutor` currently sends text only. It gains:

- the request's `enabledToolDefinitions` sent as the provider's tools (Anthropic `tools` with
  `input_schema`; OpenAI and LM Studio `tools` of type `function`);
- transcript `toolCalls` and `toolOutput` entries written in each provider's own shape;
- streamed tool calls parsed and passed to the framework with the channel's `.toolCalls` events;
- the `.toolCalling` capability on `HostedLanguageModel`.

The existing structured-answer path for Anthropic, which uses a forced tool, stays as it is. An
LM Studio model that can't call tools will answer in words, and the pill will show them. If a
server rejects the request because it carries tools, the pill says this model can't take voice
commands. Layer doesn't retry without tools, since nothing could be done without them.

**One undo step per command.** Today `DesignStore.endEdit()` closes the edit group at the first
call, so several tool calls in one command would each become an undo step. The store needs a way
to hold a group open across a command and close it when the command ends. Undo and redo tools
run outside any open group.

### Build order

Each stage leaves something that works.

1. **Corner and pill.** Phone button, the Draw menu change, the pill with timer and live
   waveform, starting and ending. No model yet.
2. **Voice agent.** Tools, canvas picture, profile, hosted tool calling. Driven by typed or
   scripted commands through a debug hook.
3. **Dictation route.** Speech to commands, the queue, captions, "stop".
4. **On-device measurement.** A set of command transcripts run through the Mac harness, with
   accuracy and latency recorded in `docs/benchmarks/`, and tuning from the results.
5. **OpenAI live audio.** Starts with a short spike on the protocol points listed under Risks.
6. **The flick on the pencil bar.** Starts with a spike. If the flick can't be caught, Draw in
   the menu remains the way to put the bar away.

### Testing

- **Unit tests.** Each tool against a `DesignStore`. The handle table. The canvas picture's text
  and its fit to a budget. Hosted tool-call requests and stream parsing for both formats, in the
  style of `HostedModelTests`. Realtime event encoding and decoding against a fake socket. The
  whole agent loop against a scripted `LanguageModel` that replays tool calls, asserting the
  design's final state and a single undo step.
- **In the simulator.** A debug launch hook, in the style of `DemoScript`, starts a call with a
  scripted model and scripted commands, so the pill and its states can be looked at without a
  microphone or a model. Checked in narrow, medium and full-screen windows.
- **By hand, on an iPad.** The microphone, speech recognition, Apple Intelligence and OpenAI live
  audio need a real device, a real voice and, for OpenAI, a key. The user's own example sentences
  are the script.

## Risks, and what settles each

- **The on-device model may call tools poorly.** It is unmeasured for this job, and the sketch
  benchmark was not encouraging. Stage 4 measures it. Mitigations: fewer tools per profile,
  requiring a tool call, worked examples in the rules.
- **Realtime protocol details read from documentation but not yet run:** whether instructions
  given with a reply request apply to that reply only, the exact events that carry a finished
  function call, and whether turning automatic replies off still commits the turn at a pause.
  The stage 5 spike settles them.
- **Catching a flick on the system's pencil bar** may not be possible. The stage 6 spike settled
  it: it is possible, in the simulator. The bar is in a system window of the same scene, so the
  app watches each window of the scene for a touch that begins where the bar is. Not yet tried
  on an iPad, and it would stop working, without a word, if iPadOS moved the bar elsewhere.
- **Speech assets may be missing in the simulator.** The scripted debug hook covers the UI
  regardless.
- **The experiments above ran on macOS with a scripted model.** Stage 2's tests repeat them in the
  app on iPadOS.

## Left to the builder

- Exact tool arguments and wording, the canvas picture's text format, and the rules text.
- Thresholds: how long a pause ends a command, how much history each profile keeps.
- Pill dimensions, the grow and shrink animation, and how queued commands are shown.
- Which speech locale to use when the device's own isn't supported.
- Reconnecting a realtime session that reaches its 60-minute limit.
- File and type names.

## Calls made without the user

Each is the author's call and can be overturned.

- The pill grows a line for captions.
- The call timer and waveform use the reference's layout; the timer is green, as in the reference.
- The phone button is plain glass, like the other controls.
- Flicking the pencil bar away also ends drawing, and the Draw item is disabled during a call.
- "Stop" and "cancel" are handled on the iPad; "hang up" ends the call by voice.
- Live audio is used whenever the design's model is OpenAI, with `gpt-realtime-2.1`.
- Input transcription is switched on for live audio, which OpenAI bills separately.
- A call continues, with the pill hidden, while a panel sheet is open.
- Starting a call in a second window ends the call in the first.
- A local server that rejects tools gets a plain message, not a retry without them.
- New screens asked for over live audio are written by the design's chosen chat model.

## Changed after the first session on an iPad (2026-11-18)

The first real use, logged and written up in `docs/benchmarks/voice-on-device.md`, led
to five changes the user asked for. Where they differ from the design above, these stand.

- **The model is warmed as a call starts**, and again after a command is stopped or
  fails, so the first command doesn't wait on it.
- **A command ends after 1.2 s of quiet**, not 0.8 s, and a word alone that is no command
  ("So", "make") is let go. Only "undo", "redo", "delete", "duplicate", "bigger",
  "larger", "smaller", "bold" and "centre" are commands in one word.
- **Handles stay between the app and the model.** What the model says, and what the
  pill shows, has each handle put as the thing it stands for. A new screen is given a
  short name by the model.
- **Two more tools:** `pan` (up, down, left, right, or "a bit" of any) and
  `stackElements` (a column or a row, 12 points apart). Seventeen in all.
- **The on-device model is told about the canvas once for a command**, not again after
  each step, which is what made its closing word take three seconds. A hosted model is
  still told again after each step.

## Sources

- iPhoneOS 27.2 SDK: `FoundationModels.swiftinterface` (`LanguageModelSession.DynamicProfile`,
  `Profile`, `DynamicInstructions`, `SessionProperty`, `LanguageModelExecutorGenerationRequest`,
  `LanguageModelExecutorGenerationChannel`), `Speech.swiftinterface`.
- Apple: [Composing dynamic sessions with instructions and profiles](https://developer.apple.com/documentation/foundationmodels/composing-dynamic-sessions-with-instructions-and-profiles),
  [DynamicProfile](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/dynamicprofile).
- OpenAI: [Realtime conversations](https://developers.openai.com/api/docs/guides/realtime-conversations),
  [Realtime VAD](https://developers.openai.com/api/docs/guides/realtime-vad),
  [Realtime with tools](https://developers.openai.com/api/docs/guides/realtime-mcp),
  [pricing](https://developers.openai.com/api/docs/pricing).

# Voice Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A hands-free "call" in Layer's narrow window: a phone button starts it, a call pill shows it, and spoken commands create screens, edit elements and move the canvas.

**Architecture:** One `LanguageModelSession(profile:)` per call. A `DynamicProfile` picks the model, the instructions (which carry a live picture of the canvas) and the tools. The tools are thin wrappers over `DesignStore` and `DesignActions`. Speech reaches the agent as text from `SpeechAnalyzer`; OpenAI's live audio is a second route added later that reuses the same tools.

**Tech Stack:** Swift 6 toolchain (Xcode 27.2), SwiftUI, Foundation Models (dynamic profiles, custom `LanguageModelExecutor`), Speech (`SpeechAnalyzer`), AVFoundation, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-17-voice-mode-design.md`

## Global Constraints

- Deployment target iPadOS 27.0. `FoundationModels` is imported with `@_weakLinked`. Anything that runs a model of the app's own is gated on `HostedLanguageModel.isSupported` (27.2).
- Every change to a design goes through `DesignStore` / `DesignActions`, on the main actor, and is undoable. Each spoken command is one undo step.
- Listening only happens while the pill is up and Layer is at the front.
- Corner controls keep the `BottomCorner` margins. Nothing is repositioned for the pencil bar.
- The canvas stays live while a model works: no main-actor work longer than a store edit.
- Tools run one at a time. Session properties are written only on the main actor.
- A `historyTransform` must keep the instructions entry.
- New files go under `Layer/Voice/` (chrome under `Layer/Chrome/`, debug under `Layer/Debug/`). Run `xcodegen generate` after adding or removing files and commit `Layer.xcodeproj`.
- Tests use Swift Testing, in `LayerTests/`. Run one suite with:
  `xcodebuild -project Layer.xcodeproj -scheme Layer -skipPackagePluginValidation -testPlan CI -destination "platform=iOS Simulator,id=$VOICE_SIM" -only-testing:LayerTests/<Suite> test`
  where `$VOICE_SIM` is the UDID of the simulator "Layer iPad Pro 11 (voice-mode)" on iOS 27.2.
- Chrome changes are looked at in a narrow (about 375 pt), a medium (about 675 pt) and a full-screen window before a task is called done.
- Work happens on branch `feature/voice-mode`. Commit after each task. Do not push.
- Code comments follow the codebase: doc comments that say why, British spelling.

## Review Focus

1. **A handle that doesn't exist** (the model invents `E99`, or names an element deleted earlier in the call): the tool answers with a plain line saying so, nothing changes, nothing crashes. → Task 4.
2. **"Stop" while a command runs with others queued:** the running command is cancelled, the queue is emptied, and what was done so far is one undo step. → Tasks 6 and 9.
3. **The call ends mid-command** (red button, design closed, app leaves the front): the microphone stops, the held edit group is closed, the design is left one undo away from where it started. → Task 9.
4. **A model that answers in words, names an unknown tool, or sends arguments that aren't valid JSON:** the pill shows a problem line and the next command still works. → Task 6.
5. **Nothing to act on** (an empty canvas, a locked element): edit tools say there is nothing to change or that it is locked, as the Siri actions do. → Task 4.

---

## File Structure

| File | Responsibility |
|---|---|
| `Layer/Voice/VoiceCall.swift` | The call: state, caption, levels, queue, local "stop" and "hang up", one call across windows. |
| `Layer/Voice/VoiceRoute.swift` | `VoiceRoute` protocol, `VoiceRouteEvent`, `UtteranceAssembler`. |
| `Layer/Voice/MicrophoneTap.swift` | `AVAudioSession` and `AVAudioEngine`: buffers and levels. |
| `Layer/Voice/DictationRoute.swift` | `SpeechAnalyzer` route. |
| `Layer/Voice/VoiceHandles.swift` | Short handles (S1, E7) for a call. |
| `Layer/Voice/CanvasPicture.swift` | Snapshot of the canvas and its text at two levels of detail. |
| `Layer/Voice/VoiceTools.swift` | `VoiceActing` protocol and the `Tool` types (pure: no UIKit). |
| `Layer/Voice/VoiceToolbox.swift` | `VoiceActing` on a real `AppModel`. |
| `Layer/Voice/VoiceProfile.swift` | Session properties, rules text, `VoiceProfile`, history trimming. |
| `Layer/Voice/VoiceAgent.swift` | Runs one command through the session; outcome for the pill. |
| `Layer/Chrome/CallPill.swift` | `PhoneButton`, `CallPill`, `CallWaveform`. |
| `Layer/Debug/ScriptedLanguageModel.swift` | DEBUG model that replays tool calls, for tests and the demo hook. |
| `Layer/Debug/VoiceDemo.swift` | DEBUG launch hook `-LayerVoiceDemo`. |
| Modified | `DesignStore.swift`, `AppModel.swift`, `CanvasScreen.swift`, `StatusChrome.swift`, `TopBar.swift`, `HostedModelClient.swift`, `HostedLanguageModel.swift`, `HostedProvider.swift`, `project.yml`. |

---

## Part 1: Corner and pill

### Task 1: The pencil bar without the marker button

**Files:** Modify `Layer/Chrome/StatusChrome.swift` (delete `PaletteToggle`), `Layer/App/AppModel.swift` (delete `isPaletteCollapsed`), `Layer/Canvas/CanvasScreen.swift` (the `PaletteToggle` overlay and `hidesPalette`), `Layer/Chrome/TopBar.swift` (`ToolsMenu` Draw toggle). Test: `LayerTests/VoiceCallTests.swift`.

**Interfaces:**
- Produces: `AppModel.tool` is the only state for the bar in a narrow window: bar up exactly when `tool == .draw` and no panel sheet is open.

- [ ] **Step 1:** Remove `PaletteToggle`, `isPaletteCollapsed` and its UserDefaults key use. In `CanvasScreen`, `hidesPalette` becomes `usesSheets && (model.isLayersOpen || model.isInspectorOpen)`. In `InkCanvas.Coordinator.refresh()` remove the unused `isTuckedAway`.
- [ ] **Step 2:** Build the app target (`xcodebuild -skipPackagePluginValidation … build`). Expected: succeeds with no reference to `PaletteToggle` or `isPaletteCollapsed` (`grep -rn` finds none).
- [ ] **Step 3:** Commit: "Narrow window: the Draw menu item alone shows and hides the pencil bar".

### Task 2: The call's state

**Files:** Create `Layer/Voice/VoiceCall.swift`, `Layer/Voice/VoiceRoute.swift`. Modify `Layer/App/AppModel.swift`. Test: `LayerTests/VoiceCallTests.swift`.

**Interfaces:**
- Produces:
  ```swift
  enum VoiceRouteEvent: Sendable, Equatable {
      case level(Float)            // 0...1, about 20 a second
      case hearing(String)         // words so far in the command being spoken
      case command(String)         // a finished command
      case failed(String)          // the route can't go on; ends the call
  }
  @MainActor protocol VoiceRoute: AnyObject {
      /// Words that help the recogniser: screen names and element text.
      func start(vocabulary: [String]) async throws -> AsyncStream<VoiceRouteEvent>
      func stop()
  }
  @MainActor protocol VoiceCommandRunner: AnyObject {
      func run(_ command: String) async -> VoiceOutcome
  }
  struct VoiceOutcome: Equatable, Sendable {
      var lines: [String] = []      // one per tool that ran
      var said = ""                 // the model's own closing words
      var problem: String?
      var wasCancelled = false
      var endsCall = false
  }
  @MainActor @Observable final class VoiceCall {
      enum Phase: Equatable { case starting, listening, working, ended }
      struct Caption: Equatable { enum Kind { case hearing, working, done, problem }; var kind: Kind; var text: String }
      private(set) var phase: Phase
      private(set) var caption: Caption?
      private(set) var startedAt: Date?
      private(set) var levels: [Float]          // newest last, at most VoiceCall.levelCount (28)
      private(set) var queuedCount: Int
      init(route: any VoiceRoute, runner: any VoiceCommandRunner, vocabulary: @escaping @MainActor () -> [String] = { [] })
      func start() async
      func end()
      func showStep(_ text: String)             // called by the runner while a tool runs
      static weak var current: VoiceCall?       // one call across windows
      static func localAction(for command: String) -> LocalAction?   // .stop, .hangUp
  }
  ```
  `AppModel`: `private(set) var voice: VoiceCall?`, `func startVoiceCall()`, `func endVoiceCall()`, `var isInVoiceCall: Bool`.
- Caption timings: done 3 s, problem 6 s. `localAction`: after lowercasing and stripping punctuation, `stop` / `cancel` / `stop that` / `cancel that` → `.stop`; `hang up` / `end call` / `end the call` / `goodbye` → `.hangUp`.

- [ ] **Step 1: Write failing tests** in `VoiceCallTests` with a `FakeRoute` (yields events on demand) and a `FakeRunner` (records commands, returns queued outcomes, can suspend until released):
  - `commandsRunInOrderOneAtATime`: two `.command` events while the first is suspended → runner sees them in order, `queuedCount == 1` meanwhile.
  - `stopCancelsTheRunningCommandAndEmptiesTheQueue`: commands A, B, then `.command("Stop.")` → A's task is cancelled, B never runs, `queuedCount == 0`, "stop" is never passed to the runner.
  - `hangUpEndsTheCall`: `.command("hang up")` → `phase == .ended`, route stopped.
  - `anEmptyCommandIsIgnored`: `.command("  ")` → runner not called.
  - `aProblemIsShown`: outcome with `problem` → `caption?.kind == .problem`.
  - `aSecondCallEndsTheFirst`: starting call 2 → call 1 `phase == .ended`.
  - `levelsKeepTheLatest`: 40 `.level` events → `levels.count == 28`, last is the newest.
  - `endingStopsTheRouteAndCancelsWork`: `end()` while a command is suspended → route stopped, runner task cancelled.
- [ ] **Step 2:** Run `-only-testing:LayerTests/VoiceCallTests`. Expected: fails to compile (`VoiceCall` undefined).
- [ ] **Step 3:** Implement `VoiceRoute.swift` and `VoiceCall.swift`. One task consumes the route's stream; one worker task drains the queue.
- [ ] **Step 4:** Run the suite. Expected: all pass.
- [ ] **Step 5:** Commit: "Voice call state: queue, captions, stop and hang up".

### Task 3: Phone button and pill

**Files:** Create `Layer/Chrome/CallPill.swift`, `Layer/Voice/MicrophoneTap.swift`, `Layer/Debug/VoiceDemo.swift`. Modify `Layer/Canvas/CanvasScreen.swift`, `Layer/Chrome/TopBar.swift`, `Layer/App/AppModel.swift`, `project.yml`.

**Interfaces:**
- Consumes: `VoiceCall`, `VoiceRoute`.
- Produces: `struct PhoneButton: View`, `struct CallPill: View` (reads `model.voice`), `final class MicrophoneTap` with `func start() throws -> AsyncStream<AVAudioPCMBuffer>`, `func stop()`, `static func level(of: AVAudioPCMBuffer) -> Float`, and `static func requestAccess() async -> Bool`. `VoiceDemo.runIfRequested(on:)` (DEBUG): `-LayerVoiceDemo "<spoken> => <tool> <json>; …"` starts a call on a scripted route.
- Layout: phone button 56 pt glass circle, symbol `phone.fill`, shown when `model.isCompactWidth && model.isCompactSizeClass && !model.isInVoiceCall` and no panel is open; label "Start voice mode". Pill: bottom centre, max width 420, 64 pt tall, 20 pt side and 12 pt bottom margins, shape `.rect(cornerRadius: 32, style: .continuous)`, `.glassEffect(.regular.tint(background), in:)` with `store.canvas.resolvedBackground`; 44 pt model icon circle; timer `0:42` in green monospaced digits; waveform of 28 bars beneath; 44 pt red circle `phone.down.fill` labelled "End voice mode". The caption line appears above the row and grows the pill by one line. `ViewControls` and `GenerationStatus` are hidden while `model.isInVoiceCall`. The pill reports its frame as `"call pill"`.
- Starting a call sets `tool = .select`. The Draw menu item is disabled while `isInVoiceCall`.
- `project.yml`: `NSMicrophoneUsageDescription: Layer listens while voice mode is on, so you can design by speaking.` and `NSSpeechRecognitionUsageDescription: Layer turns what you say in voice mode into text on this iPad.`

- [ ] **Step 1:** Add the two usage strings; `xcodegen generate`.
- [ ] **Step 2:** Implement `MicrophoneTap`, `PhoneButton`, `CallPill`, the overlays in `CanvasScreen`, the menu change, and `AppModel.startVoiceCall()` / `endVoiceCall()` (until Task 9 the route is a level-only microphone route and the runner reports "Voice commands aren't connected yet").
- [ ] **Step 3:** Implement `VoiceDemo` with a scripted route (fake levels, hearing words, then the command).
- [ ] **Step 4:** Add tests to `VoiceCallTests`: `startingACallLeavesDrawMode` (`AppModel` with `tool == .draw` → after `startVoiceCall()` with a fake route, `tool == .select`), `closingTheDesignEndsTheCall` (`prepareToClose()` → `voice == nil`). Run; expected pass.
- [ ] **Step 5:** Run the app in the voice-mode simulator with `-LayerVoiceDemo`, in narrow, medium and full-screen windows; take screenshots of the phone button, the pill listening, and the pill with each caption kind on a light and a dark canvas background.
- [ ] **Step 6:** Commit: "Phone button and call pill in the narrow window".

---

## Part 2: The voice agent

### Task 4: Handles, canvas picture and tools

**Files:** Create `Layer/Voice/VoiceHandles.swift`, `Layer/Voice/CanvasPicture.swift`, `Layer/Voice/VoiceTools.swift`, `Layer/Voice/VoiceToolbox.swift`. Modify `Layer/Model/DesignStore.swift`, `Layer/App/AppModel.swift`. Test: `LayerTests/VoiceToolsTests.swift`.

**Interfaces:**
- `DesignStore`: `func beginHeldEdit()`, `func endHeldEdit()`. While held, `beginEdit()` / `endEdit()` pairs inside change nothing; `endHeldEdit()` registers one undo step if the content changed.
- `AppModel`: `func waitForGeneration() async` (returns when `generationTask` finishes); `generateScreen(from:)` unchanged.
- ```swift
  @MainActor final class VoiceHandles {
      func handle(forScreen id: DesignScreen.ID) -> String          // "S1", stable for the call
      func handle(forElement id: DesignElement.ID) -> String        // "E7"
      func screen(_ handle: String) -> DesignScreen.ID?             // accepts "s1", " S1 ", "#S1"
      func element(_ handle: String) -> DesignElement.ID?
  }
  struct CanvasPicture: Sendable, Equatable {
      enum Detail: Sendable { case full, compact }
      static let empty: CanvasPicture
      var screens: [Screen]; var loose: [Element]
      var hasScreens: Bool { get }
      func text(_ detail: Detail) -> String
      @MainActor static func capture(from model: AppModel, handles: VoiceHandles) -> CanvasPicture
  }
  protocol VoiceActing: AnyObject, Sendable {
      @MainActor func createScreen(description: String) async throws -> String
      @MainActor func addElement(screen: String?, kind: String, text: String?, look: String?) -> String
      @MainActor func setText(element: String, text: String) -> String
      @MainActor func styleElement(element: String, look: String) -> String
      @MainActor func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String
      @MainActor func alignElement(element: String, alignment: String) -> String
      @MainActor func duplicateElement(element: String) -> String
      @MainActor func deleteElement(element: String) -> String
      @MainActor func renameScreen(screen: String, name: String) -> String
      @MainActor func deleteScreen(screen: String) -> String
      @MainActor func show(target: String) -> String
      @MainActor func zoom(to: String) -> String
      @MainActor func undo() -> String
      @MainActor func redo() -> String
      @MainActor func endCall() -> String
  }
  enum VoiceTools {
      static func all(_ actor: any VoiceActing) -> [any Tool]
      static func forEmptyCanvas(_ actor: any VoiceActing) -> [any Tool]   // createScreen, show, zoom, undo, redo, endCall
  }
  @MainActor final class VoiceToolbox: VoiceActing {
      init(model: AppModel, handles: VoiceHandles)
      var lines: [String]            // what each tool did, for the outcome; reset per command
      var failures: [String]
      var endsCall: Bool
  }
  ```
- Tool names are the method names above. Each `Arguments` is a flat `@Generable` struct of strings (optional where the method's are). Each tool returns the acting method's line.
- Picture text, full detail:
  ```
  Screens in order (S1 is the first, the last is the newest):
  S1 "Login" 393x852 [in view] [selected]
    E1 title "Welcome back" x20 y75 w353 h41
    E2 button "Sign in" x20 y420 w353 h50 colour blue [selected]
  Loose on the canvas:
    E9 sticky note "Ask about fonts"
  ```
  Compact detail lists only the in-view (else selected, else newest) screen's elements; other screens are one line with an element count. An empty canvas reads `The canvas has no screens yet.`
- Rules for the acting methods: a mutating method reveals its element first (`DesignActions.reveal`), refuses a locked element ("E2 is locked."), and answers an unknown handle with `There is no E99.` Sizes accept points (`"180"`) or a share of the screen (`"50%"`). `alignment` accepts left, centre/center, right, top, middle, bottom. `show` accepts a handle or `all`. `zoom` accepts `in`, `out`, `fit` or a percentage. `undo` and `redo` close the held edit, act, and hold again.

- [ ] **Step 1: Write failing tests** in `VoiceToolsTests` (each builds `AppModel(document: LayerDocument())`, adds a screen with `store.addScreen` and elements with `store.setElements`):
  - `handlesAreStableAndForgiving`: same id → same handle; `"e1"`, `" E1 "`, `"#E1"` resolve; a new element gets the next number; a deleted element's handle is not reused.
  - `thePictureListsScreensAndElements`: text contains `S1 "Login"`, `E1 title "Welcome back"`, and `[selected]` on the selected element.
  - `theCompactPictureSummarisesOtherScreens`: with two screens, the far one appears as one line ending `2 elements` and its elements are absent.
  - `anEmptyCanvasSaysSo`.
  - `stylingAppliesLookWords`: `styleElement("E2", look: "text blue, bold")` → `textColor == ColourWords.parse("blue")`, `fontWeight == .bold`, and the element is selected.
  - `resizingAcceptsAShareOfTheScreen`: `moveElement("E2", width: "50%")` on a 393-wide screen → width 196.5 rounded to 197 (use `.rounded()`), x unchanged.
  - `aligningCentresOnTheScreen`: `alignElement("E2", "centre")` → `frame.midX == 196.5`.
  - `settingTextChangesTheWords`, `duplicatingAndDeleting`, `renamingAndDeletingAScreen`.
  - `anUnknownHandleChangesNothing`: `styleElement("E99", …)` returns `There is no E99.` and `store.content` is unchanged. (Review Focus 1)
  - `aLockedElementIsRefused`: returns a line containing `locked`; content unchanged. (Review Focus 5)
  - `editingAnEmptyCanvasSaysThereIsNothing`: `setText("E1", …)` with no screens → `There is no E1.` (Review Focus 5)
  - `aHeldEditIsOneUndoStep`: `beginHeldEdit()`, three tool calls, `endHeldEdit()`, then one `undoManager.undo()` restores the original content.
  - `undoInsideACommandUndoesTheLastCommand`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/VoiceToolsTests`. Expected: fails to compile.
- [ ] **Step 3:** Implement the four files and the store and model additions.
- [ ] **Step 4:** Run the suite, and `DesignTests` and `SiriIntentsTests` for the store change. Expected: all pass.
- [ ] **Step 5:** Commit: "Voice tools, handles and the canvas picture".

### Task 5: Tool calling for hosted models

**Files:** Modify `Layer/Providers/HostedModelClient.swift`, `Layer/Providers/HostedLanguageModel.swift`, `Layer/Providers/HostedProvider.swift`. Test: `LayerTests/HostedToolCallingTests.swift` (reuses `StubProvider`).

**Interfaces:**
- ```swift
  struct HostedTool: Equatable, Sendable { var name: String; var description: String; var schema: Data }
  struct HostedToolCall: Equatable, Sendable { var id: String; var name: String; var arguments: String }
  struct HostedToolResult: Equatable, Sendable { var callID: String; var name: String; var text: String }
  // HostedConversation gains: var tools: [HostedTool] = []; var requiresTool = false
  // HostedConversation.Message gains: var toolCalls: [HostedToolCall] = []; var toolResults: [HostedToolResult] = []
  // HostedModelClient.StreamEvent gains: case toolCall(id: String, name: String, arguments: String)   // a fragment
  // HostedModelError gains: case toolsUnsupported(HostedProvider)
  //   "This model can't take voice commands. Choose another in Settings."
  ```
- Wire shapes. Anthropic: `tools: [{name, description, input_schema}]`, `tool_choice: {type: "auto" | "any", disable_parallel_tool_use: true}`; an assistant turn with calls has `content: [{type:"text",text}, {type:"tool_use",id,name,input}]`; results are a user turn `content: [{type:"tool_result",tool_use_id,content}]`. OpenAI and LM Studio: `tools: [{type:"function",function:{name,description,parameters}}]`, `parallel_tool_calls: false`, `tool_choice: "required"` when required; assistant `tool_calls: [{id,type:"function",function:{name,arguments}}]`; results are `{role:"tool",tool_call_id,content}`.
- A request with a schema keeps today's behaviour (Anthropic's forced `respond` tool, `input_json_delta` as text). A request with tools and no schema reports tool-use blocks as `.toolCall`.
- `HostedLanguageModel.capabilities` becomes `[.guidedGeneration, .toolCalling]`.

- [ ] **Step 1: Write failing tests** in `HostedToolCallingTests`:
  - `anthropicIsSentTheToolsAndAnswersWithACall`: stub SSE with `content_block_start` (`tool_use`, id `toolu_1`, name `setText`) and two `input_json_delta`s; a session on `HostedLanguageModel(provider: .anthropic, …)` with one recording `Tool` → the tool receives the joined arguments; the first request body has `tools[0].input_schema` and `tool_choice.disable_parallel_tool_use == true`; the second request's messages end with a `tool_result` for `toolu_1`.
  - `openAIIsSentTheToolsAndAnswersWithACall`: same with `delta.tool_calls` fragments; second request has a `role: tool` message with `tool_call_id`.
  - `aStructuredAnswerStillComesBackAsText`: the existing schema path is unchanged.
  - `aLocalServerThatRejectsToolsSaysSo`: LM Studio stub answering 400 with a message mentioning tools → `HostedModelError.toolsUnsupported(.lmStudio)`.
  (`StubProvider.canInit` gains the LM Studio default host; `StubProvider` gains a list of replies answered in turn.)
- [ ] **Step 2:** Run the suite. Expected: fails to compile.
- [ ] **Step 3:** Implement request building, stream parsing and the executor's transcript mapping (`.toolCalls`, `.toolOutput`, `request.enabledToolDefinitions`, `generationOptions.toolCallingMode`, `channel.send(.toolCalls(…))`).
- [ ] **Step 4:** Run `HostedToolCallingTests` and `HostedModelTests`. Expected: all pass.
- [ ] **Step 5:** Commit: "Hosted models call tools through Foundation Models".

### Task 6: Profile and agent

**Files:** Create `Layer/Voice/VoiceProfile.swift`, `Layer/Voice/VoiceAgent.swift`, `Layer/Debug/ScriptedLanguageModel.swift`. Test: `LayerTests/VoiceAgentTests.swift`.

**Interfaces:**
- ```swift
  extension SessionPropertyValues {
      @SessionPropertyEntry var canvasPicture: CanvasPicture = .empty
      @SessionPropertyEntry var voiceModel: ModelChoice = .appleIntelligence
  }
  enum VoiceRules { static let full: String; static let compact: String }
  struct VoiceProfile: LanguageModelSession.DynamicProfile {
      init(actor: any VoiceActing, hooks: VoiceHooks, testModel: (any LanguageModel)? = nil)
      static func trimmed(_ entries: [Transcript.Entry], keepingCommands count: Int) -> [Transcript.Entry]
  }
  struct VoiceHooks: Sendable { var willRun: @Sendable (String) async -> Void; var didRun: @Sendable () async -> Void; var mayRun: @Sendable () async -> Bool }
  @MainActor final class VoiceAgent: VoiceCommandRunner {
      init(model: AppModel, testModel: (any LanguageModel)? = nil)
      var onStep: ((String) -> Void)?
      func run(_ command: String) async -> VoiceOutcome
  }
  #if DEBUG
  struct ScriptedLanguageModel: LanguageModel {
      struct Step: Hashable, Sendable { var tool: String; var arguments: String }
      init(script: [String: [Step]], closing: String = "Done.")   // key: the command, lowercased
  }
  #endif
  ```
- Profile branches: `testModel` if given (full rules and picture, all tools); a hosted choice when `HostedLanguageModel.isSupported` (full, all tools, `.model(HostedLanguageModel)`, keep 6 commands); otherwise Apple Intelligence (compact rules and picture, `VoiceTools.forEmptyCanvas` when `!picture.hasScreens`, keep 2 commands, `maximumResponseTokens(200)`). `trimmed` keeps every `.instructions` entry and everything from the Nth-last `.prompt` on.
- `run`: refresh both session properties, `store.beginHeldEdit()`, `respond(to:)`, `store.endHeldEdit()` in every exit path. `mayRun` is false once the command's task is cancelled; a refused or cancelled tool gives `wasCancelled`. Errors become `problem` using `LocalizedError.errorDescription`. A reply with no tool run puts the model's words in `said`.
- Step text for the pill, per tool: createScreen "Writing a screen…", addElement "Adding…", setText "Rewording…", styleElement "Restyling…", moveElement "Resizing…", alignElement "Aligning…", duplicateElement "Duplicating…", deleteElement / deleteScreen "Deleting…", renameScreen "Renaming…", show "Showing…", zoom "Zooming…", undo "Undoing…", redo "Redoing…", endCall "Hanging up…".

- [ ] **Step 1: Write failing tests** in `VoiceAgentTests` (all `.enabled(if: HostedLanguageModel.isSupported)`), each with an `AppModel` holding a "Login" screen and a `ScriptedLanguageModel`:
  - `aCommandRunsItsToolsInOrder`: script two steps for "make the button blue and say ahoy" → both changes are in the store; `outcome.lines.count == 2`.
  - `aCommandIsOneUndoStep`: after the two-step command, one `undo()` restores the content.
  - `thePictureIsFreshBetweenSteps`: script step 1 `duplicateElement E2`, step 2 `setText E3 "Copy"` (E3 only exists after step 1) → the copy's text is "Copy".
  - `wordsWithoutAToolAreShown`: empty script → `outcome.said == "Done."`, `lines.isEmpty`, content unchanged. (Review Focus 4)
  - `anUnknownToolIsAProblemNotACrash`: step naming `paintEverything` → `outcome.problem != nil`; a following valid command still works. (Review Focus 4)
  - `argumentsThatAreNotJSONAreAProblem`: step with arguments `{"element":` → `problem != nil`; next command works. (Review Focus 4)
  - `cancellingStopsTheCommandAndKeepsOneUndoStep`: script three steps with a slow second (the scripted model sleeps before it); cancel after the first → `wasCancelled`, third never ran, one `undo()` restores. (Review Focus 2)
  - `trimmingKeepsTheInstructions`: `VoiceProfile.trimmed` on instructions + 4 commands with tool entries, keeping 2 → first entry is the instructions, the rest starts at the third command's prompt.
- [ ] **Step 2:** Run the suite. Expected: fails to compile.
- [ ] **Step 3:** Implement the three files.
- [ ] **Step 4:** Run `VoiceAgentTests`. Expected: all pass.
- [ ] **Step 5:** Wire `AppModel.startVoiceCall()` to a `VoiceAgent`, and `VoiceDemo` to a scripted model built from the launch argument. Run the demo in the simulator: a spoken line appears, the canvas pans to the element, it changes, the pill says what was done.
- [ ] **Step 6:** Commit: "Voice agent: a dynamic profile that runs commands with tools".

### Task 7: The agent against real hosted models

**Files:** Test: `LayerTests/VoiceAgentLiveTests.swift`.

- [ ] **Step 1:** Add a suite enabled only when `LAYER_LMSTUDIO` is set (as `LMStudioLiveTests` is): with a "Login" screen, run "make the sign in button green" and "show me the first screen" through `VoiceAgent` with `.hosted(.lmStudio, model:)`; expect the button's tint to equal `ColourWords.parse("green")` and no problem. Print latency and the outcome.
- [ ] **Step 2:** If LM Studio is running on this Mac with a tool-capable model, run it and record the result in `docs/benchmarks/voice-agent.md`. If not, record that it wasn't run.
- [ ] **Step 3:** Commit: "Voice agent live test against LM Studio".

---

## Part 3: Dictation

### Task 8: Assembling commands from recognised speech

**Files:** Modify `Layer/Voice/VoiceRoute.swift`. Test: `LayerTests/VoiceCallTests.swift`.

**Interfaces:**
- ```swift
  struct UtteranceAssembler {
      init(pause: Duration = .milliseconds(900))
      /// Recognised text for the phrase in progress; `isFinal` when the recogniser has settled it.
      mutating func heard(_ text: String, isFinal: Bool, at now: ContinuousClock.Instant)
      /// The words to show while speaking.
      var hearing: String { get }
      /// A finished command, once the speaker has paused. Nil until then.
      mutating func command(at now: ContinuousClock.Instant) -> String?
  }
  ```
- [ ] **Step 1: Write failing tests:** `aPauseEndsACommand` (heard at t0, nothing by t0+0.9 s → command), `speechThatContinuesIsOneCommand` (finals at t0 and t0+0.5 s → one command joining both), `volatileTextIsShownButReplaced` (two volatile results → `hearing` is the latest), `silenceGivesNothing`.
- [ ] **Step 2:** Run; expected to fail. **Step 3:** Implement. **Step 4:** Run; expected pass.
- [ ] **Step 5:** Commit: "Assemble spoken commands from recognised phrases".

### Task 9: The dictation route

**Files:** Create `Layer/Voice/DictationRoute.swift`. Modify `Layer/App/AppModel.swift`, `Layer/Voice/VoiceCall.swift`. Test: `LayerTests/VoiceCallTests.swift`.

**Interfaces:**
- `@MainActor final class DictationRoute: VoiceRoute { init(source: MicrophoneTap = MicrophoneTap(), locale: Locale = .current) }`. It asks for the microphone, installs speech assets if needed (yielding nothing until ready; `VoiceCall` shows "Getting ready to listen…" while `phase == .starting`), feeds converted buffers to `SpeechAnalyzer`, gives the vocabulary to the recogniser as contextual strings, and yields `.level`, `.hearing` and `.command`. Locale falls back to `en_US` when the device's isn't supported.
- `AppModel.startVoiceCall()` checks the model's readiness first (existing `ProviderReadiness` wording) and sets `voiceNotice` (shown as an alert) instead of starting when the microphone is refused or the model can't be used. The call ends when the scene leaves `.active`, on `AVAudioSession` interruption, and in `prepareToClose()`.

- [ ] **Step 1: Write failing tests:** `endingMidCommandLeavesOneUndoStep` (a real `VoiceAgent` with a slow scripted step; `call.end()` during it → route stopped, `store` has no open edit, one `undo()` restores) (Review Focus 3); `stopWithAQueueKeepsOneUndoStep` (Review Focus 2, with the real agent); `aCallDoesNotStartWithoutAUsableModel` (hosted choice with no key → `voice == nil`, `voiceNotice` is the provider's missing-key text).
- [ ] **Step 2:** Run; expected to fail.
- [ ] **Step 3:** Implement `DictationRoute` and the model checks.
- [ ] **Step 4:** Run `VoiceCallTests`, then the whole `CI` test plan. Expected: all pass.
- [ ] **Step 5:** In the simulator, start a call from the phone button and speak through the Mac's microphone if speech assets are available there; otherwise note that this step waits for a device.
- [ ] **Step 6:** Commit: "Dictation route: speech on the iPad becomes voice commands".

---

## Part 4: Measuring Apple Intelligence

### Task 10: On-device benchmark

**Files:** Create `Tools/voice-benchmark/` (a macOS harness that compiles `VoiceTools.swift`, `CanvasPicture.swift`'s pure part and the rules with a recording `VoiceActing`), `docs/benchmarks/voice-agent.md`.

- [ ] **Step 1:** Write 30 commands with the expected tool and key arguments: the user's examples, plus variants over three canvas pictures (empty, one screen, three screens).
- [ ] **Step 2:** Run them through `SystemLanguageModel.default` on this Mac with the compact profile's rules, picture and tools. Record per command: tools called, whether they match, and latency.
- [ ] **Step 3:** Write up accuracy and p50/p95 latency. If accuracy is under 80%, try in turn: `toolCallingMode(.required)`, fewer tools per state, two worked examples in the rules; keep what the numbers support and record each result.
- [ ] **Step 4:** Commit: "Benchmark voice commands on the on-device model".

---

## Part 5: OpenAI live audio

Planned in detail after its spike, in `docs/superpowers/plans/` as its own plan. The spike settles, against the live API with the user's key: whether `response.create` instructions apply to one reply, which events carry a finished function call, and whether a turn is committed at a pause with automatic replies off. Then: `RealtimeRoute` (WebSocket, 24 kHz PCM16, text out, the same tools through `VoiceActing`), falling back to `DictationRoute` when the connection fails.

## Part 6: The flick on the pencil bar

Planned after its spike. The spike tries a pan recogniser on the window, recognising alongside PencilKit's own, over the area `PKToolPicker.frameObscured(in:)` reports. If a sideways or downward flick can be seen, it sets `tool = .select`. If not, the Draw menu item stays the only way and the spec's fallback stands.

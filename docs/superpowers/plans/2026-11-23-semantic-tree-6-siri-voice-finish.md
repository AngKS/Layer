# Semantic tree, plan 6 of 6: Siri, voice, the last of the projection, and measuring. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the last callers onto the tree, delete the flat model, and measure the result. After this plan:
- Siri and Shortcuts work on the tree:
  - entity ids keep the form `design|host|uuid`, and queries and entities still show leaves only;
  - Get Design Layout's JSON keeps every key it has today and gains the tree: containers with their children, layout, padding and sizing, and each node's parent and rotation. Frames are in screen points on screens and canvas points on the canvas;
  - Add Element and Move Element work in screen points through the index, and Move on a laid-out child follows the drag rule;
  - the device choices take the design's own devices by name.
- Voice works on the tree:
  - the canvas picture lists nodes in reading order, indented by nesting, and containers have handles and their layout in words;
  - there are four new tools: `groupElements`, `setLayout`, `ungroup` and `reorder`;
  - `moveElement` on a laid-out child answers with a line saying what to do instead;
  - devices are chosen by name, the design's own included;
  - the on-device and hosted pictures both carry the nesting, and the voice harness and the LM Studio live tests build.
- What a generation or an A2UI import couldn't fix is reported in the import sheet and the generation's status (spec §9; Task 9b, F1).
- The flat model is gone. That covers the projection (`Layer/Model/Projection/`), `DesignContent`'s wrapper, `DesignElement`, `DesignScreen`, `FloatingElement`, `ElementRef` (renamed `NodeRef`), `keepGroupsSound`, `pendingPointers`, `place(_:centeredAt:)`, both `addFloating`s, `DesignStore.newElement` (F2), and every other name the gate lists. `scripts/check-flat-model.sh --strict` finds nothing in `Layer/`, `LayerTests/`, `LayerUITests/` or `Tools/`, and the three macOS harnesses build.
- Every row of spec §13 is measured after the change against plan 2 Task 1's baseline, in the same simulator ("Layer iPad Pro 11 (st2-lane-c)") on a quiet machine (1-minute load under 20). The results go in `docs/benchmarks/semantic-tree.md`. The hosted format is measured on LM Studio, and the default is kept or flipped by My call 8.
- The iPad device checklist (below) is ready for the user.
- The branch is ready for the controller's next steps: the performance optimisation sweep, then the merge to main (from the primary worktree, where main is checked out) and the push. This plan does neither.

**Architecture:** Siri (`Layer/Intents/`) reads `TreeContent` snapshots and the store's index, and writes through plan 2's and plan 4's verbs (`place`, `move`, `update`, `resizeLaidOut`, `add`, `delete(nodes:)`, `duplicate(node:)`). A laid-out child's Move goes through plan 4's pure `TreeDrop`. Voice (`Layer/Voice/`) captures a nested `CanvasPicture` from the index. Its handles name every node, and its four new tools reuse plan 4's `group(_:as:)` numbers, plan 2's `setLayout` and `unwrap`, and plan 5's declining `ungroup`. The rules Siri and voice share (the drag rule for a host frame, a new leaf's defaults, a custom device by name) are written once, in Task 1, before the lanes are cut (F13). The test port runs in all three lanes behind one gate script, whose per-lane allowlists only shrink. Task 9b reports what a generation or an import couldn't fix (spec §9). Once every caller has left, one task deletes the projection and the flat types, makes `DesignStore.content` a `TreeContent`, and renames `ElementRef` to `NodeRef`. A last task runs one measuring script and writes the results.

**Tech Stack:** Swift 6 (strict concurrency), `@Observable`, App Intents (`AppEntity`, `IndexedEntity`, `DynamicOptionsProvider`), Foundation Models (`Tool`, `LanguageModelSession`, `HostedLanguageModel`), PencilKit (ink only), Swift Testing, XCUITest, XcodeGen, SwiftPM (the screen harness), `swiftc` (the sketch and voice harnesses), LM Studio (hosted measuring), Instruments (only if a budget is missed, and then in the sweep).

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read:
- §11, all of it;
- §13 (the performance table);
- §14 (Siri's and voice's device choices, custom frames by name);
- My calls 8, 9, 17 and 19;
- the Anti-goals, especially "the flat list survives as a second model";
- the Edge cases "Old files in Files and Spotlight" and "Siri Move Element on a node inside a turned container";
- Verification (benchmarks before and after, the iPad checklist);
- "How the work is split", item 6.

Plans 1–5 (`docs/superpowers/plans/2026-11-23-semantic-tree-{1-foundations,2-store-cutover,3-structured-generation,4-canvas-panels,5-sketch-path}.md`) are the source of every tree, store, export, canvas and sketch name used here. `reports/Semantic tree 2026-11-23/recon/sketch-generation-code-intents.md` §4 in the main checkout lists today's intents, entities, queries, voice tools and error lines.

**Starts when:**
- plan 5 is complete and merged into `feature/semantic-tree`;
- its Task 12 has filled the "After plan 5" column of `docs/benchmarks/semantic-tree.md`;
- `scripts/check-generated-swiftui.sh`, `Tools/SketchBenchmarkHarness/run.sh check` and `Tools/ScreenBenchmarkHarness/run.sh check` pass on the branch;
- `grep -rln "PROJECTION: deleted in plan 6" Layer` lists exactly plan 5's end-state set.

## Pre-flight amendments 2026-11-23

The pre-flight scan is in `.superpowers/sdd/2026-11-23-semantic-tree-6-siri-voice-finish/preflight.md`. The controller accepted every ruling, and each is written into the tasks below.

- **F1.** Spec §9's reporting of what can't be fixed in generated and imported trees is the new lane-A Task 9b. Task 11 also waits for it.
- **F2.** Task 9 moves the library drops off `place(_:centeredAt:)` onto a tree verb `place(_:centredAt:)`. Task 5's canvas Add uses `add(_:to: .canvas)`. Task 11 deletes `place(_:centeredAt:)`, both `addFloating`s and `newElement`. Clause (q) and the gate's tier 1 name them.
- **F3.** The policy carries plan 4's (i)–(l) and plan 5's (o)–(p). Plan 6's own clauses are (q)–(v). Plan 2's (f)–(h) don't apply. An added `print` with no assertion changed is allowed. The Global Constraints name the only projection-reading lines this plan adds.
- **F4.** Plan 2's clause (h) tolerances must be gone before Task 1 (plan 4's MUST-DOs). Task 9 ports those tests exactly, and Tasks 11 and 12 grep for any left.
- **F5.** Every recorded number runs in "Layer iPad Pro 11 (st2-lane-c)" at a 1-minute load under 20. The workout is a Release build in a temporary worktree with `LayerTests` taken out, the app uninstalled first, and the median of 3 runs.
- **F6.** The hand-off merges from the primary worktree, names the bench simulator and re-runs the earlier deletion greps. The Global Constraints name the UI baseline set. Spec §6 records call 11.
- **F7.** The fixture's label is at (20, 324, 80, 24): the engine snaps laid-out frames to whole points.
- **F8.** Siri's Move writes nothing when each given number is within 0.05 of what Get Design Layout reports. The turned-card landing uses plan 4's `place` tolerance.
- **F9.** Task 4 deletes Task 3's exact-JSON test. Task 3 records its golden with `TEST_RUNNER_LAYER_RECORD_LAYOUT`.
- **F10.** New clause (v): Get Design Layout's key record in `Goldens/ComponentKinds.txt`. Task 3 ports `ComponentCatalogueTests`' snapshot line under (q).
- **F11.** Task 1 splits `groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed` by owner. `DeviceReflowTests` is lane B's. Task 5 keeps the static signatures other lanes call, and Task 9 keeps every app signature lanes B and C call.
- **F12.** Task 1 provides `sketched(_:from:to:)`. Task 9 converts its 12 wrapper call sites, and Task 10 its 15 and the 5 `changeKind` ones.
- **F13.** Task 1 writes the drag rule for a host frame, a new leaf's defaults and a custom device by name once. Tasks 5, 7 and 9 use them.
- **F14.** Siri's Arrange refuses only a row's, column's or grid's child, and arranges in an overlay. Align refuses in any laid-out parent.
- **F15.** A laid-out screen root's child is reordered, never taken out: voice says so, and Siri's Move throws `.laidOut` when the position can't be kept.
- **F16.** `DesignActions.swift`, `AppModel.swift` and `Groups.swift` are listed in `a.txt` for Task 11, with the hits each may keep. Task 1's bridge line becomes a recorded literal, so Task 5 deletes `frameForNewElement`. Task 2 owns `StoreChangeBenchmarkTests`, and the lane list names lane A's other directories.
- **F17.** The fixture saves to a unique temporary `.layer` and takes its `designID` from it. No test reads `OpenDesigns.shared.current` across an await.
- **F18.** Both new "lowers nothing" tests count per screen with `lowerings(of:)` and prove the counter live first.
- **F19.** The Global Constraints gain the struct table. `HostedToolCallingTests` reads `HostedModelTests`. Task 2's file is `CanvasDragLandingTests.swift`.
- **F20.** Tasks 6 and 7 run the UI suite.
- **F21.** Tasks 1 and 9 run the sketch harness check, and the voice harness list adds Task 7.
- **F22.** The rules edit and the sketch accuracy print `BENCH` lines. The reading row uses `BENCH sketch reading`.
- **F23.** Siri's custom-device parameters are in each `parameterSummary`. The dialog takes "a" or "an" by the name's first letter. `deviceName` is a custom device's name, else the built-in's display name.
- **F24.** Task 5 ports two `LookWordsEverywhereTests` cases to nodes and retires the adapter one.
- **F25.** Task 11 renames with `perl`, not `sed`. New clause (u) covers the rename in tests.
- **F26.** Task 11's (s) list is every line the strict gate's `TreeProjection` pattern finds. Task 9 deletes the marked `CanvasDrags` adapters.
- **F27.** Call 10's numbers are corrected. Task 8 records the context size and the whole `newtools` table, and compares the controls on "Right".
- **F28.** `newElementFrame` goes below the visible root children's host shapes, containers whole.
- **F29.** Task 3's interface adds `DesignEntity.init(id:content: TreeContent, …)` and one conversion between the two `Host` enums.
- **F30.** Siri's one-step test adds Edit Text and Move to Screen, and a node moved to another screen leaves its container.

## Depends on plans 4 and 5

These names are assumed as plans 4 and 5 left them. If one is spelled otherwise, use the spelling in the ledger and change nothing else.
1. **Plan 4:**
   - `TreeIndex.ownPose(of:in:)`, `placement(of:in:)`, and `Entry.hostShape` (a `TurnedRect` in screen points, or canvas points on the canvas);
   - `PlacedNode`, `store.placed(_:)`, `store.place(_:at:)`, `store.ref(of:)` and `store.treeScreen(_:)`;
   - `AppModel.selectedNode`, `selectedScreenID` and `selectedLeafNodes`;
   - `TreeDrop.target(for:at:centre:in:index:)` and `.Target`;
   - `store.resizeLaidOut(_:to:from:)` and `setCanvasPoses(_:)`;
   - `GroupShape`, `store.group(_:as:)`, `canGroup(_:as:)` and `TreeEdit.groupedLayout(of:as:rhythm:)`;
   - `addCustomDevice`, `setDevice(of:to:)`, `CanvasSettings.customDevices` and `device(named:)`;
   - `AppModel.hoverTarget(at:skippingDrawings:)` answering with node refs.
2. **Plan 5:**
   - `store.changeDevice(of:to:)`, `store.tidy(_:)`, `store.addSketched(_:from:confidence:decidedBy:adjust:)` and `store.changeKind(of:to:fallback:adjust:)`;
   - `store.ungroup(_:)`, which declines a structure the pass made (plan 5 Task 9), and `declineStructure(_:)`;
   - the two sketch wrappers marked `// PROJECTION: deleted in plan 6` in `DesignStore.swift`;
   - `place(_:centeredAt:)` (library drops) and `addFloating`, still on the projection in `DesignStore.swift` (plan 5 F15). Task 9 moves their callers and Task 11 deletes them (F2);
   - `DeviceReflowTests.everyPathChangesTheDeviceTheSameWay`, which drives the panel, Siri and voice paths.
3. **Plan 3:**
   - `BuildScreenIntent.build(_:on:name:device:in:undoManager:)`;
   - `ScreenGenerator.hostedFormat` and `format(for:)`;
   - `A2UIPrompt.instructions(for:)` and its pin `theA2UIPromptIsUnchanged`;
   - `Tools/ScreenBenchmarkHarness/run.sh hosted <model> <outline|a2ui> [runs]`;
   - `LookWords.look(from:)` with `Look.apply(to: inout LayerNode)`;
   - `LayerTests/Support/CodeOfElements.swift`;
   - `TreeValidator.check(_:on:)` and `fixGenerated`, `A2UIImportReport`, `AppModel.importA2UI`, `ScreenGeneration.leftOut` and `GenerationStatus` (Task 9b).
4. **Plan 4's ledger, from plan 2's Task 7:** the five tests plan 2's clause (h) made tolerant are exact again: `GroupTests` `aTurnedGroupsBoxIsAtItsAngle`, `aTurnedGroupResizesWithoutShear`, `turningAGroupTurnsItsMembersAboutItsMiddleAndKeepsItsAngle` and `manyTurnsOfAGroupAddUpWithoutDrift`, and `StoreOnTheTreeTests.undoAndRedoGoThroughTheTree` (F4).

## Calls made in this plan

1. **One gate, with two tiers and allowlists that only shrink.** `scripts/check-flat-model.sh` greps for the flat model's names.
   - **Tier 1** is every flat type and projection member.
   - **Tier 2** is `ElementRef` and `TreeProjection`'s counter, which Task 11 renames or removes.
   - Without `--strict`, tier 1 is checked against `scripts/flat-model-allowlist/{a,b,c}.txt`, one file per lane. Each lane only ever removes its own lines.
   - `--strict` checks both tiers with no allowlist. After Task 11 that is the only mode.
   - Why: the post-plan-5 call sites can't be known when this is written, and the spec's "the flat list must not survive" needs a check, not a promise. Lists per lane can't conflict when lanes merge. `ElementRef` is in hundreds of lines and is renamed once, at the end, so it would keep every allowlist full until then.
2. **Who ports what is a rule by file name, written into the ledger by Task 1.** It covers every file that the gate's first run lists.
   - Siri files and their tests (`Layer/Intents/*` but `DesignActions.swift`'s Task 11 hits, `Layer/Canvas/ImagePlaygroundSupport.swift`, `Layer/Debug/DemoScript.swift`, `Siri*Tests`, `BuildScreenTests`, `LookWords*Tests`, `DeviceReflowTests`): lane B, Tasks 3–5 (F11).
   - Voice files and their tests (`Layer/Voice/*`, `Layer/Debug/VoiceDemo.swift`, `Tools/VoiceBenchmarkHarness/*`, `Voice*Tests`, `Pencil*Tests`, `Dictation*Tests`, `HostedToolCalling*Tests`): lane C, Tasks 6–8.
   - The projection, `Design.swift`, `DesignFile.swift`, the store's projection members, the plan-5 wrappers, `place(_:centeredAt:)`, `addFloating`, `newElement`, `Look+Element.swift`, `CodeOfElements.swift`, the harness stubs, and tests of the projection or of T1's bridge: Task 11.
   - **Files whose hits belong to two tasks (F16)** go in `a.txt`, for Task 11, and the ledger records the hits each may keep. The earlier owner ports every other hit and checks with a grep that leaves those out:
     - `Layer/Intents/DesignActions.swift`: `TakenAction`'s `DesignContent` (lane B ports the rest in Tasks 3–5);
     - `Layer/App/AppModel.swift`: the four marked accessors `selectedElement`, `selectedScreen`, `selectedElements` and `selectedLeaves` (Task 9 ports the rest, and Task 6 `voiceVocabulary`);
     - `Layer/Model/Groups.swift`: the `keepGroupsSound` shim (Task 9 ports the rest).
   - Every other app file: Task 9.
   - The test files named `Group*`, `Design*`, `Flat*`, `LayerOrder*`, `Concurrent*`, `Undo*`, `Drawing*`, `Rotation*`, `MultiSelection*`, `Canvas*`, `Performance*`, `Store*`, `Tree*`, `Layout*` and `Node*`: Task 9. The exception is `StoreChangeBenchmarkTests`, which is Task 2's (F16).
   - Every other test file: Task 10.
   - Why: the port is the plan's largest piece and parallelises by file. A fixed rule means no file has two owners, and the shared files' leftover hits are named.
3. **Siri's frames are host shapes.** Get Design Layout writes each node's `TreeIndex.Entry.hostShape`: its upright frame centred on what is seen, with its summed angle. That is in screen points on a screen, and canvas points on the canvas. Add Element and Move Element take the same numbers, through `place(_:at:)` (canvas points ÷ the node's scale on the canvas).
   - Why: a free screen's numbers are today's exactly, a node inside a turned container lands where asked (spec Edge cases), and what Get Design Layout reports can be moved back with no change.
4. **Get Design Layout adds keys and changes none.**
   - `elements` and `canvasElements` stay the leaves, each with every key it has today.
   - Each leaf gains `sizing`, `parent` (its nearest container's id, when it has one) and `rotation` (when turned).
   - Each screen gains `deviceName`, `layout`, `padding` and `containers`, and the top level gains `canvasContainers`.
   - A container lists `children` (ids, in order), `layout`, `padding`, `sizing`, its frame, `parent` and `rotation`.
   - `layout` and `sizing` are written as `design.json` writes them (plan 1 Task 1).
   - `device` is the device's id. That is unchanged for built-ins, and a custom one's id where today's code wrote `"iphone"`.
   - Why: Shortcuts that read `elements[i].x` keep working, and Siri still sees leaves (My call 9). The tree is there without repeating every leaf, as the spec asks: "each node lists its children, layout and sizing".
5. **A laid-out child under Siri:**
   - **Move** with a position takes `TreeDrop.target` at the new frame's centre, kept to the node's own host. `.insert` reorders it or puts it in that row, column or grid. `.free`, or a container on another host, puts it on its host's root at the frame, `.fixed` on both axes. All of it is Task 1's `move(_:toHostFrame:)` (F13).
   - **A laid-out screen root's child** is reordered, never taken out: a position that resolves to `.free` under a column root throws `.laidOut` and changes nothing (F15).
   - **Move** with a size alone fixes those axes (`resizeLaidOut`).
   - **Move** writes nothing when every given number is within 0.05 of what Get Design Layout reports for the node, which rounds to a tenth. So a frame read back is a no-op (F8).
   - **Align** throws the new `.laidOut` in any laid-out parent (§10: align applies in free parents only). **Arrange** throws it only in a row, column or grid, and arranges in an overlay (My call 15, F14).
   - **Add Element** on a laid-out root appends. A given width or height fixes that axis, and a given x or y is dropped.
   - Why: spec §11 says "following the drag rule". A Move must not fly a node to another screen, which today's Move can't do either. On a column screen the rule reorders, as plan 4's drop does. Today Align would silently take the child out, and Arrange would give the wrong "within its group" message.
6. **Custom devices for Siri are an optional "Custom Device" text parameter, with the design's devices as options.** It is added to Add Screen, Change Screen Device and Build Screen, and as "Custom Device for New Screens" to Update Canvas Settings. When given, it wins over Device. An unknown name throws the new `.deviceNotFound(name)`.
   - Why: an `AppEnum` can't list a design's own frames. Changing `device`'s type, or making it optional, risks every saved Shortcut. Parameter titles can't use Apple trademarks (ITMS-90626).
7. **Voice sees containers.**
   - One E handle sequence names every node, containers included. A screen's root has no handle of its own: its S handle stands for it.
   - Containers are told with their layout in words, and their children are indented under them, in layout order in a row, column or grid, and top to bottom otherwise.
   - A selected container is marked `[selected]` itself, not its leaves.
   - A look given to a plain `.group` goes to its leaves, in one step. A card takes the look itself.
   - Why: the spec gives containers handles, a second letter would cost the small model rules it must learn, and "make these blue" with a group selected must still recolour what is in it.
8. **`moveElement` on a laid-out child:**
   - A position with no `takeOut` changes nothing. It answers: `E6 is in the row E5, which places it. To change its place in E5, call reorder. To take it out of E5, call moveElement again with takeOut yes and where it goes.`
   - With `takeOut: "yes"` and a position, it is taken out as Siri's Move is (call 5), through the same `move(_:toHostFrame:)` (F13).
   - A size alone resizes it (`resizeLaidOut`).
   - `alignElement`, `stackElements` and `placeElement` on a laid-out child answer with the same kind of line.
   - **A laid-out screen root's child** has nowhere to be taken out to. A position, with or without `takeOut`, answers `E3 is in the column S1, which places it. To change its place in S1, call reorder.` (F15).
   - Why: spec §11 asks for a line that points to reorder "or to say where to take it out to", and a model needs a way to do the second. An explicit optional argument is safer for a small model than hidden state across two calls, and "half width" in a row keeps working.
9. **The four new tools reuse the verbs the panels use.**
   - `groupElements` is plan 4's `group(_:as:)`, with its numbers and its `canGroup` rules.
   - `setLayout` is plan 2's `setLayout`. Free to a row, column or grid takes `TreeEdit.groupedLayout`'s spacing unless one is said. A screen root takes free or column only (plan 4 call 10). Grid columns are clamped to 1–12.
   - `ungroup` is `store.ungroup`, so a structure the pass made is declined (plan 5 Task 9).
   - `reorder` moves within one parent only.
   - A spacing number is the person's own words, relayed. §14's "no model picks a number" is about generation, and voice sets no number unasked.
   - Why: one behaviour whether the finger or the voice asks, and no second set of layout rules.
10. **The on-device profile is measured before it grows.**
    - All 25 tools of a call (24 for the pencil, which has no end-call tool) go to the on-device model if two things hold, measured by the voice harness on this Mac:
      - the older-tool controls score no worse than the last recorded result in `docs/benchmarks/voice-on-device.md` (15 of 25, the "Right" column) by more than 2 of 25, so at least 13 of 25;
      - the profile of a call with one screen is at most 3,400 tokens.
    - Otherwise the on-device model is offered every tool but `setLayout` and `reorder`, and the report says so. Hosted models always get all of them.
    - Why: the profile was 2,792 tokens with one screen when there were 20 tools, against a context `voice-on-device.md` gives as 8,192 tokens; the harness prints the model's `contextSize`, and Task 8 records it (F27). A tool list that crowds out the command would quietly break voice (anti-goal).
11. **No screen is told to a model as A2UI.** Spec §6 lists "telling a hosted model a screen" among A2UI's uses, and plan 3 call 22 left it here. But §11 makes the indented canvas picture what voice and typed edits are told. No hosted path in this plan regenerates or edits a screen whole. The exporter stays for Share and the round-trip tests.
    - Why: a second description of the same screen costs tokens and gives no new information. This is flagged to the user in the hand-off, and recorded in spec §6 as an amendment (F6).
12. **The names after the flat model:**
    - `DesignStore.ElementRef` becomes a top-level `NodeRef { var host: TreeIndex.Host; var node: UUID }` in Task 11, after every lane has merged.
    - `TreeContent` and `TreeScreen` keep their names.
    - `DesignStore.content` becomes a `TreeContent`, and `store.tree` stays as its observed read.
    - `CanvasSelection.element(_:)` keeps its case name.
    - Why: plan 4 promised the rename. Done once and last, it conflicts with nothing. Renaming the tree's types back to `DesignContent` and `DesignScreen` would empty the gate of meaning and touch every line plans 2–5 wrote.
13. **How this plan measures:**
    - One script, `scripts/measure-semantic-tree.sh`, runs every §13 measurement, so the sweep can re-run it after each change.
    - **The same simulator:** "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47), plan 2 Task 1's. If it is gone, a fresh clone of the same device type and runtime measures main again beside the branch, and both baselines are recorded. The 5% bar is judged against the one from the same simulator.
    - **A quiet machine** for every timed run: no other lane, `xcodebuild` or LM Studio download running, and a 1-minute load average under 20 (`sysctl -n vm.loadavg`) before each run (F5).
    - **The workout as the baseline ran it:** a Release build in a temporary worktree (or a temporary copy of the scheme and `TestPlans/Layer.xctestplan`) with `LayerTests` taken out, never in the committed files; the app uninstalled first; 3 runs of 5 iterations, medians reported.
    - **Hosted runs are interleaved** per brief, alternating which format goes first, and compared on medians.
    - **A missed budget is recorded and handed to the optimisation sweep, not fixed here.** The always-on budget tests must still pass.
    - Why: the sweep is the user's next step and comes before the merge. Changing code while measuring would blur what each change bought.
14. **The hosted prompts are measured as they are.** Neither prompt's wording changes in this plan, so `theA2UIPromptIsUnchanged` stays. A better A2UI prompt, if the numbers ask for one, goes in the hand-off.
15. **The test-fallout policy gains (q)–(v)** (Global Constraints). It carries plan 4's (i)–(l) and plan 5's (o)–(p), so plan 6's own clauses are lettered after (p) (F3).
16. **What Siri and voice share is written once, first (F13).** Task 1 makes the drag rule for a host frame (`DesignStore.move(_:toHostFrame:)`), a new leaf with today's defaults (`LayerNode.standard(_:symbol:)`) and a custom device by name (`CanvasSettings.customDevice(named:)`). Tasks 5, 7 and 9 use them.
    - Why: lanes B and C run side by side, and each would otherwise write the same rule.

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding or deleting files, and commit `Layer.xcodeproj/project.pbxproj` with the task.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text.
  - New: `Layer/Voice/CanvasPicture.swift`, `VoiceTools.swift` and `VoiceRules.swift` are compiled by the voice harness with nothing but `Tools/Shared/RotationStub.swift`. They name no `Layer/Tree/` or `Layer/Model/` type. Layout words are made in `CanvasPicture+Capture.swift`, which the app alone compiles.
- **Type names:** every new type that could clash with SwiftUI is nested in `LayerNode`: `LayerNode.Layout`, `.Stack`, `.Grid`, `.Alignment`, `.Padding`, `.Sizing`.
- **Every `xcodebuild` command** (in this plan, in scripts and in docs) passes `-skipPackagePluginValidation`, and `-skipMacroValidation` too if plan 1's ledger says so.
- **Limits:**
  - tree depth 32;
  - 5,000 nodes per design;
  - grid columns 1–12.
- **Layer's numbers:**
  - rhythm 8, 12, 16, 24, 32;
  - margins 20 (phone), 32 (tablet), 48 (desktop), 8 (watch), 20 (other);
  - desktop column at most 1080;
  - card: radius 16, padding 16, fill `RGBColor(hex: 0xF2F2F7)`.

  These are `DesignTokens.standard` and the devices' tokens.
- **The file:**
  - Version is 4, and `design.json` is encoded with `.sortedKeys`.
  - The older-version message is exactly: `This design was made by an earlier version of Layer and can't be opened by this one.`
  - The newer-version message stays exactly: `This design was saved by a newer version of Layer. Update Layer to open it.`
- **Undo semantics stay.**
  - Every step is a three-way, per-property revert of only its own changes.
  - Gestures, Format runs, voice commands and generations each stay one step.
  - These stay: `putOnTop`, `markNeedsSaving`, `onlyScreen(changedBy:)`, withdrawing steps that change nothing, and the cap of 50.
  - New: every Siri write is one step through `DesignActions.edit`, with its `TakenAction` for the system's undo, withdrawn once what it changed is changed again. Every voice command, the four new tools included, is one held edit.
- **Ids are stable.** No verb changes a node's id, except duplicate, which makes new ones. Entity ids keep the form `design|<screen uuid or canvas>|<node uuid>`. Voice handles stay stable for a call and are never reused.
- **No layout in a SwiftUI `body`**, and no whole-tree layout on an edit. Layout runs only in `TreeRules`, in the store's change, on read, and off the main actor before a commit.
- **No new projection code.** Nothing added in this plan reads or writes the projection, and every new test builds and reads the tree through `LayerTests/Support/TreeBuilders*.swift`. The only exceptions are Task 1's bridge test `aLeafLowersToTheElementItReplaces` and the lowering lines of `readingDoesNotLower` (Task 3) and `aCommandLowersNothing` (Task 7). Task 11 retires each under (s) (F3).
- **Siri's contract:**
  - Queries and entities show leaves only (My call 9), and a selected container is invisible to Siri.
  - No existing parameter's type, title or identifier changes. New parameters are optional.
  - App Intents titles and descriptions never name Apple products (ITMS-90626).
  - The errors are today's, plus exactly two new ones:
    - `laidOut`: `That element's place comes from the row, column or grid it's in. Change its order in the Layers panel, or move it out of the container first.`
    - `deviceNotFound(name)`: `This design has no device called “<name>”. Make one with Custom Size… in the device picker.`
- **Voice's contract:**
  - The tool names are exact.
  - A delete needs the person's own word (`VoiceNaming.fits`).
  - A correction undoes only voice's last step, if no hand has changed it.
  - A scoped (typed) edit touches one screen.
  - A change to the rules' or the tools' wording is measured with the voice harness and recorded in `docs/benchmarks/voice-on-device.md`.
- **Measuring (F5):**
  - Timed runs happen only while no other lane, `xcodebuild` or LM Studio download is running, and with a 1-minute load average under 20 (`sysctl -n vm.loadavg`) before each run. The ledger records the load of each.
  - They use "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47), or call 13's clone if it is gone.
  - The canvas workout is built for Release in a temporary worktree (or a temporary copy of the scheme and `TestPlans/Layer.xctestplan`) with `LayerTests` taken out of the scheme's build entries and the `Layer` test plan, as the baseline was. Committed files are never changed, and `git status --porcelain` is the same before and after a run. The app is uninstalled before the runs. It is 3 runs of 5 iterations, with medians reported.
  - Never record a better number than was measured.
- **The finish stops short.** Nothing in this plan merges to main or pushes. Task 12 ends with the hand-off.
- **Green.** After every task:
  - the app builds;
  - the full unit suite passes;
  - the UI suite fails no test outside plan 1's recorded baseline set (spec My call 19).

  The UI suite runs at the end of Tasks 5, 6, 7, 8, 9, 9b, 10, 11 and 12 (F20). `scripts/check-generated-swiftui.sh` passes at the end of Tasks 9, 9b, 10, 11 and 12.

  The baseline set (F6): failing `testAChangeIsKeptWhenTheAppGoesToTheBackgroundAndIsEnded`, `testMagicPenSketchesBecomeADesignWithCode` and `testTheReferenceDesignFitsTheCanvas`; flaky `testACloseCallOffersWhatItNearlyWasAndBecomesThatWhenTapped`, which counts as failing only if it fails again when run on its own. The set is fixed (My call 19).
- **The gate.** `scripts/check-flat-model.sh` exits 0 at the end of every task, and `--strict` at the end of Tasks 11 and 12.
- **The test-fallout policy.** A test written before this plan may be changed or retired only if it asserts one of these:
  - (a) the v1–v3 file or its readers: the JSON keys `elements` or `floating`, a top-level `canvas` object of settings, `drawing.data`, or a version below 4;
  - (b) a flat-list state the tree can't hold:
    - a group pointer to a missing group, a group on another host, or a group that makes a loop;
    - a drawing inside a group's block;
    - a group item that isn't just in front of its members;
  - (c) members of one canvas group at different scales;
  - (d) a write count the tree lowers, such as a container moved as one write instead of one write per member;
  - (e) floating-point noise below 1e-9 from composing transforms through a turned container. Switch to the file's `close` helper, or add one with tolerance 1e-6;
  - (f)–(h) as in plan 3: a replaced generation or export API, a stubbed hosted answer in the written form, and a record of something plan 3 deleted;
  - (i)–(l) as in plan 4: a replaced canvas or panel API, a counter's lower bound, a counter narrowed to the test's own ids or a fixed wait made a poll, and a record of something plan 4 deleted;
  - (o) and (p) as in plan 5: a `ScreenTidy` test retired, and a `ScreenTidy` result through voice rewritten to the structure pass's or the placement intents' result;
  - New in plan 6 (F3). It letters its own clauses after (p), so plan 4's and plan 5's keep theirs:
  - (q) it builds or reads a design through the flat API this plan deletes. Only the setup and the reads change, to their tree equivalents in `TreeBuilders`. Frames are read in host points through `store.ownFrame(_:)`, and what is asserted stays. The flat API is `DesignElement`, `DesignScreen`, `FloatingElement`, `DesignContent`'s element members, `store.screens`, `floating`, `element`, `resolve`, `update(ref)`, `setElements`, `addFloating`, `place(_:centeredAt:)`, `DesignStore.newElement`, the plan-5 wrappers and `CodeOfElements` (F2);
  - (r) it counts or lists voice tools, or pins a picture line or a picture's list of elements, that the four tools, container handles or the devices line lengthen. Only the count, the list or that line changes;
  - (s) it tests the projection or an adapter this plan deletes: `TreeProjection*`, `TreeLift`, `ElementConversion`, `Look+Element`, `CodeOfElements`, Task 1's bridge tests, or `TreeProjection.lowerings`. It is retired, or only its lowering lines go when it asserts more;
  - (t) it pins the hosted default, which Task 12's measurement flipped. Only the expected format and the stubbed answers' form change;
  - (u) it names a type or member Task 11 renames or retypes: `ElementRef` → `NodeRef` and its `element` → `node`, `content.tree` → `content`, `DesignContent(tree: t)` → `t`. Only the names change (F25);
  - (v) it records Get Design Layout's keys (`Goldens/ComponentKinds.txt`'s "layout data" lines), which call 4's new keys lengthen. Only those lines are recorded again, and the ledger shows that the difference is the new keys alone (F10).

  Plan 2's (f)–(h) don't apply in plan 6. In particular, plan 2's (h), a container box rounded to whole points, was undone by plan 4 and is never ported (F4). A "(h)" in this plan means plan 3's.

  **Instrumentation (F3).** A `print` of what a test already measures may be added with no assertion changed. The ledger records it.

  No clause covers a Siri, voice, selection, hit-test, move, turn, Format or Layers behaviour: the ported suites pass with their assertions unchanged. Each change is listed in its task, or recorded in the ledger with its clause. Every other failure is a bug to fix, not a test to change.
- **Test commands.** `<Suite>` is the `@Suite` struct's name.
  - Lane A, this worktree:

    ```
    xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
      -destination "platform=iOS Simulator,name=Layer iPad Pro 11 (semantic-tree)" \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-semantic-tree" \
      -skipPackagePluginValidation -only-testing:LayerTests/<Suite>
    ```

  - The full unit suite is the same command without `-only-testing`.
  - The UI suite is the same command with `-testPlan Layer -only-testing:LayerUITests`.
  - **Suite names (F19).** Where a step names a test file rather than a suite struct, run every struct the table lists, each with its own `-only-testing:LayerTests/<Struct>`. A suite nested in `HostedWindowSuites` runs as `-only-testing:LayerTests/HostedWindowSuites/<Struct>`. Plans 2–5 may have renamed or split some of these, so expand them as the branch has them when the step runs. A run that executes 0 tests counts as a failure. Every new suite in this plan is one struct named as its file.

    | Name in this plan | Structs to run |
    |---|---|
    | SiriIntentsTests | EntityKeyTests, ColourTests, DesignLibraryTests, DesignIndexTests, OpeningDesignTests, DesignActionTests, ImagePlaygroundTests, StrokeScriptTests, LookWordTests, MovingTests, and the suite plan 3 renamed ScreenBlueprintTests to |
    | VoiceToolsTests | VoiceHandlesTests, CanvasPictureTests, VoiceToolsTests |
    | PencilVoiceTests | PencilVoiceTests, SqueezeRouterTests, ScreenEditorTests, ScreenEditFieldTests |
    | VoiceCallTests | VoiceCallTests, UtteranceAssemblerTests, VoiceDemoTests, PencilBarFlickTests, CallPillPartsTests |
    | DictationRouteTests | MicrophoneTapTests, PreparedOnceTests, DictationRouteTests |
    | HostedModelTests (and the tests in `HostedToolCallingTests.swift`, which extend it; there is no `HostedToolCallingTests` suite) | HostedModelTests, ModelChoiceTests |
    | DrawingTests | DrawingElementTests, DrawingSyncTests, DrawingStoreTests, DrawingFileTests, TurnedDrawingTests, MagicPenPutAwayTests, InkFollowedAtTheEndTests |
    | CanvasDragWorkTests | CanvasDragWorkTests, HostedWindowSuites/CanvasTargetsWorkTests |
    | NodeViewTests | NodeViewTests, HostedWindowSuites/NodeViewWorkTests |
    | LayoutDragTests | LayoutDragTests (in `CanvasDragLandingTests.swift`) |
    | ScreenGenerationTests | ScreenStreamParsingTests, ScreenPromptTests, SketchHintTests, ScreenGenerationLifecycleTests, as plan 3 leaves them (LMStudioLiveTests is gated) |
    | GroupTests | GroupModelTests, GroupCommandTests, SelectingGroupsTests, GroupGeometryTests, GroupAsOneThingTests, LayerTreeTests (as plan 4 re-expresses it) |
    | DesignTests | ElementLayoutTests, ViewportTests, DesignStoreTests, AppModelTests, DesignFileTests, CodeGenerationTests, SymbolCatalogTests, DesignFileNameTests, CloudFileTests, ResourceTests, ClosingTests, FormatPanelEditTests, FileCheckTests, TurnedCodeTests |
    | FlatStoreTests | FlatStoreTests, GradualEditStepTests, FlatFormatTests |
    | LayerOrderTests | LayerOrderTests, MovingLayersTests |
    | ConcurrentEditTests | ConcurrentEditTests, ConcurrentEditsGroupedByEventTests |
    | RotationTests | RotationGeometryTests, TurnedThingsOnTheBoardTests, TurningOneElementTests, TurningSeveralThingsTests, RotationFieldTests, TwistTests, TwistOnTheInkCanvasTests |
    | MultiSelectionTests | SeveralThingsSelectedTests, LiningUpTests, EnclosureTests, PickedByALoopTests, SeveralThingsChangedTogetherTests, SeveralThingsOnTheCanvasTests, TapToAddTests, CanvasDragTests, PencilOnChromeTests |
    | PerformanceTests | DesignIndexerPerformanceTests, DesignFilePerformanceTests, InkCanvasPerformanceTests, InkBoardPerformanceTests, LibrarySearchPerformanceTests |
    | PerformanceFixTests | PerformanceFixTests, HostedWindowSuites/ShareMenuWorkTests, HostedWindowSuites/PencilBridgeWorkTests |
    | FreeformTests | SettingsTests, FreeformBehaviourTests, MoreMagicPenTests, MoreCodeTests, ScrubbingTests |
    | SketchReadingTests | SketchAnalyzerTests, RuleInterpreterTests, SketchEngineTests, BoardTitleTests, SketchPromptTests, AskedReadingTests, HandwritingRecognizerTests |
    | MagicPenComponentTests | InnerMarkTests, SmallControlTests, SketchedLayoutTests, NewControlCodeTests |
    | CorrectedReadingTests | ChangedKindTests, KindSuggestionTests, SketchReadingLogTests |
    | FormatPanelTests | HostedWindowSuites/TypingIntoTheFormatPanelTests, ScrubbingAFieldTests, PanelChangesBesideADragTests, HostedWindowSuites/PanelOriginTests, NumberDraftTests |
    | LayersPanelTests | HostedWindowSuites/LayersPanelWorkTests |
    | AssetLibraryTests | AssetLibraryTests, AddingAssetsTests, ShapeTests |
    | ZoomRulerTests | ZoomStopsTests |
    | CanvasBenchmarkUITests (UI) | `-only-testing:LayerUITests/CanvasBenchmarkUITests/testCanvasWorkout` |

    Every other name in this plan is a struct of that name.
  - **Lanes B and C** run in their own worktrees (`.claude/worktrees/st6-lane-b`, `.claude/worktrees/st6-lane-c`). Their branches are `st6/lane-b` and `st6/lane-c`, cut from `feature/semantic-tree` after Task 1 is merged. Their commands are the same with:
    - simulator `Layer iPad Pro 11 (st6-lane-b)` or `Layer iPad Pro 11 (st6-lane-c)`, each cloned from `iPad Pro 11-inch (M5)`;
    - DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st6-lane-b` or `-st6-lane-c`.
  - A lane's task is reviewed, then merged into `feature/semantic-tree`. Resolve `project.pbxproj` conflicts by re-running `xcodegen generate`.
- **The harnesses build (F21).**
  - `Tools/ScreenBenchmarkHarness/run.sh check` passes at the end of Tasks 2, 11 and 12, and of Tasks 1, 9 and 9b if they change a file the screen package copies.
  - `Tools/VoiceBenchmarkHarness/run.sh check` passes at the end of Tasks 6, 7, 8, 11 and 12.
  - `Tools/SketchBenchmarkHarness/run.sh check` passes at the end of Tasks 1, 9, 11 and 12.
- **Counters (F18).** No test asserts a value of a global counter that other suites also raise. `TreeProjection.lowerings(of:)` is counted per screen. A "lowers nothing" test first changes the design through a tree verb and shows the counter is live (a `store.screens` read raises it by 1), as plan 4's F11 does.

## Review Focus

1. **Siri sees leaves, under the ids it always used.** Containers are never entities, a selected container is invisible, a lock above a leaf locks it, and no existing key of Get Design Layout changes its value. Owned by:
   - Task 3: `elementEntitiesAreLeavesOnly`, `anEntityIDKeepsItsForm`, `aSelectedContainerIsInvisibleToSiri`, `lockedByAnAncestorIsLocked`;
   - Task 4: `todaysKeysKeepTheirValues`.
2. **Points through the tree.** Get Design Layout's frames are host shapes; Add and Move take the same points through turned containers; a laid-out child follows the drag rule on its own host. Owned by:
   - Task 4: `framesAreScreenPointsOnScreensAndCanvasPointsOnTheCanvas`, `rotationIsTheTurnSeen`;
   - Task 5: `aLayoutsFrameMovedBackChangesNothing`, `aMoveInsideATurnedCardLandsWhereAsked`, `movingARowChildTakesItOutWhereAsked`, `onAColumnScreenAMoveReorders`, `aLaidOutChildStaysOnItsScreen`.
3. **Voice on containers.** The picture tells the nesting in reading order. A laid-out child isn't moved by accident. The new tools refuse what can't be done, and voice's `ungroup` declines. Owned by:
   - Task 6: `childrenAreIndentedUnderTheirContainer`, `aRowIsToldInItsOrderAndAFreeContainerTopToBottom`;
   - Task 7: `movingARowChildSaysToReorder`, `takingARowChildOut`;
   - Task 8: `thingsOfTwoParentsArentGrouped`, `reorderingAcrossContainersIsRefused`, `voicesUngroupDeclinesAStructureThePassMade`.
4. **One step each.** Every Siri write is one step with the system's undo. Every voice command is one step. Custom devices are chosen by name, in one step. Owned by:
   - Task 5: `everyWriteIsOneStepWithSystemUndo`, `aCustomDeviceIsChosenByName`;
   - Task 7: `customDevicesAreChosenByName`;
   - Task 8: `eachNewToolIsOneVoiceCommandStep`.
5. **One model, nothing lost, measured.** The strict gate finds nothing, the harnesses build, the suites and the compile check pass, and every §13 row is recorded honestly. Owned by:
   - Task 11: `scripts/check-flat-model.sh --strict`, `OneModelTests`;
   - Task 12: `StoreChangeBudgetTests`, `SketchConversionBudgetTests`, and the "After plan 6" column with the hosted decision.
6. **What can't be fixed is said (spec §9).** A generation or an import that still runs off the screen after the fixes says so, and a hand-made screen is never checked. Owned by Task 9b: `anImportThatRunsOffTheScreenSaysSo`, `aGenerationSaysWhatItCouldntFix`, `whatWasFixedIsNotReported`, `aHandMadeScreenIsNeverChecked`.

**Order and lanes:**
- Lane A (this worktree): Tasks 1, 2, 9, 9b, 11, 12.
- Lane B (`st6-lane-b`): Tasks 3, 4, 5, 10.
- Lane C (`st6-lane-c`): Tasks 6, 7, 8.
- Waits:
  - every task waits for Task 1 to be merged;
  - lane A runs 2 → 9 → 9b; lane B runs 3 → 4 → 5 → 10, and lane C runs 6 → 7 → 8;
  - Task 11 waits for Tasks 1–10 and 9b to be merged, and Task 12 for Task 11.
- No two lanes edit the same file.
  - Lane A owns `scripts/`, `LayerTests/Support/TreeBuilders.swift`, `Layer/Model/`, `Layer/Document/`, `Layer/Canvas/` (except `ImagePlaygroundSupport.swift`), `Layer/Chrome/`, `Layer/App/AppModel.swift` (except one property) and `Layer/App/AppModel+*.swift`, `Layer/Tree/`, `Layer/Sketch/`, `Layer/Code/`, `Layer/A2UI/`, `Tools/ScreenBenchmarkHarness/`, `Tools/SketchBenchmarkHarness/`, `docs/benchmarks/semantic-tree.md` and `docs/benchmarks/screen-prompt.md` (F16).
  - Lane B owns `Layer/Intents/`, `Layer/Canvas/ImagePlaygroundSupport.swift` and `Layer/Debug/DemoScript.swift`.
  - Lane C owns `Layer/Voice/`, `Layer/Debug/VoiceDemo.swift`, `Tools/VoiceBenchmarkHarness/`, `docs/benchmarks/voice-on-device.md`, and `AppModel.voiceVocabulary` (Task 6's one edit to `AppModel.swift`, in a hunk of its own).
  - Test files belong to the lane call 2 gives them. A later task adds support files (`TreeBuilders+<Area>.swift`) and never edits another lane's. Task 1 splits the one test three lanes would touch (F11).
  - **Signatures other lanes call stay (F11).** Task 5 keeps `ArrangeElementIntent.arrange(_:in:_:undoManager:)`, `MoveElementIntent.move`, `DeleteElementIntent.delete`, `SetElementHiddenIntent.setHidden`, `SetElementLockedIntent.setLocked`, `DesignActions.edit` and `placementForNewScreen(_:in:near:)`, with `ElementRef` in them until Task 11's rename. Task 9 keeps every app signature a lane B or C file calls. A retype is Task 11's.
  - Each lane edits only its own `scripts/flat-model-allowlist/<lane>.txt`.

---

### Task 1: The gate, the tree's test builders, and who ports what

**Lane:** A (first; every other task waits for it to be merged)

**Files:**
- Create: `scripts/check-flat-model.sh`, `scripts/flat-model-allowlist/a.txt`, `b.txt`, `c.txt`
- Create: `Layer/Tree/LayerNode+Leaves.swift`, `Layer/Model/DesignStore+NewElement.swift`, `Layer/Model/DesignStore+HostFrame.swift`
- Modify: `Layer/Model/ElementLayout.swift` (`newElementFrame`), `Layer/Intents/DesignActions.swift` (`frameForNewElement` calls it; done before lane B is cut), `Layer/Tree/TreeContent+Devices.swift` (`customDevice(named:)`)
- Create: `LayerTests/Support/TreeBuilders.swift`
- Modify (a move, assertions unchanged, F11): `LayerTests/GroupTests.swift`, `LayerTests/VoiceToolsTests.swift` and `LayerTests/SiriIntentsTests.swift`. `GroupTests.groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed` is split by owner before the lanes are cut:
  - its four "Voice's picture of the board" lines become `CanvasPictureTests.aGroupsMembersAreToldInItsPlace` in `VoiceToolsTests.swift` (lane C);
  - its three "Siri's elements are the members too" lines become `EntityKeyTests.aGroupsMembersAreSirisElements` in `SiriIntentsTests.swift` (lane B);
  - the rest stays in `GroupTests` (Task 9).

  Each moved test builds the same `OrderBoard` design. The ledger records the move.
- Test: `LayerTests/TreeBuildersTests.swift`

**Interfaces:**
- Consumes: plan 1's `TreeIndex` and `TreeContent`; plan 2's `add(_:to:at:)`, `addScreen(_:)`, `move(_:to:at:)`, `NodeParent` and `DesignTokens`; plan 4's `ownPose(of:in:)`, `TreeScreen.placement`, `place(_:at:)`, `resizeLaidOut(_:to:from:)` and `TreeDrop.target`; plan 5's `addSketched`; today's `ElementLayout.frame(for:sketch:on:)`, `ElementLayout.size(for:sketch:)`, `keepsSketchedPosition`, `kind.placeholder` and `kind.spec.tint`.
- Produces:
  ```swift
  // scripts/check-flat-model.sh [--strict]: prints each hit as file:line, then
  //   "flat model: N references in M files" (and ", all allowed" when they are). Exits 1 on any hit not allowed.
  // Tier 1: \b(DesignElement|DesignScreen|FloatingElement|DesignContent|TreeLift|ElementConversion|pendingPointers|
  //         keepGroupsSound|keptTargets|SiblingLists|CodeOfElements)\b, \bprojected(Update|Add|Remove|Move|Reorder|SetHost)\b,
  //         PROJECTION:, Model/Projection, \bselected(Element|Elements|Leaves|Screen)\b, \bstore\.(screens|floating|resolve|element)\b,
  //         LayerNode\(element:, ElementView\(element:, \bsetElements\(, \baddFloating\(, \bTreeProjection\.(lower|lowerHost|pose)\b,
  //         \bplace\([^)]*centeredAt:, \bnewElement\(   (F2)
  // Tier 2 (--strict only): \bElementRef\b, \bTreeProjection\b
  // Searched: Layer/ LayerTests/ LayerUITests/ Tools/ (*.swift, *.sh), skipping .build/ and Sources/*/App/ copies.
  extension LayerNode {                                     // Layer/Tree/LayerNode+Leaves.swift
      /// Every leaf under it (itself when it is one), depth first, back to front: the order a screen's elements had.
      var leaves: [LayerNode] { get }
  }
  extension TreeContent {
      func leaves(on screenID: TreeScreen.ID) -> [LayerNode]
      var canvasLeaves: [LayerNode] { get }                 // the canvas's nodes' leaves in order, drawings included
  }
  extension ElementLayout {
      /// Today's `frameForNewElement`, moved: 16 below the lowest of `visible` (screen points) or the safe top,
      /// held above the bottom safe area, centred for kinds that keep their sketched place.
      static func newElementFrame(for kind: ElementKind, on device: DeviceFrame, below visible: [CGRect]) -> CGRect
  }
  extension DesignStore {                                   // Layer/Model/DesignStore+NewElement.swift
      /// Where a new leaf goes on a screen: `newElementFrame` below the host shapes of the root's visible children,
      /// containers whole, so a card's padding below its last leaf isn't taken (F28). Nil for an unknown screen.
      func newElementFrame(_ kind: ElementKind, on screenID: TreeScreen.ID) -> CGRect?
  }
  extension LayerNode {                                     // Layer/Model/DesignStore+NewElement.swift (it reads ElementLayout)
      /// A new leaf as today's `DesignStore.newElement` made one: the kind's placeholder text, `style.tint` the kind's
      /// tint, its standard size, `.fixed` on both axes, at the origin. Siri's Add, voice's add and the library use it (F13).
      static func standard(_ kind: ElementKind, symbol: String? = nil) -> LayerNode
  }
  enum MoveOutcome: Equatable { case placed, reordered, takenOut, resized, unchanged, refused }
  extension DesignStore {                                   // Layer/Model/DesignStore+HostFrame.swift
      /// The drag rule for a frame given in host points (screen points; on the canvas, canvas points ÷ the top-level
      /// node's scale), one change (F13). A free parent: `place`. A laid-out child: a size alone → `resizeLaidOut`;
      /// a position → `TreeDrop.target` at the frame's centre, kept to its own host: `.insert` on that host → `move`
      /// (`.reordered`); otherwise its host's root at the frame, `.fixed` on both axes (`.takenOut`). Under a laid-out
      /// root that can't take it free: `.refused`, and nothing changes (F15). Siri's Move and voice's `takeOut` call it.
      @discardableResult func move(_ id: UUID, toHostFrame frame: CGRect, size sizeOnly: Bool = false) -> MoveOutcome
  }
  extension CanvasSettings {                                // Layer/Tree/TreeContent+Devices.swift
      /// The design's own device whose name equals `name`, ignoring case and surrounding space; nil when none (F13).
      func customDevice(named name: String) -> DeviceFrame?
  }
  // LayerTests/Support/TreeBuilders.swift (test target only)
  extension LayerNode {
      /// A leaf with `DesignElement.init`'s labels, so a ported setup reads as it did. `.fixed` on both axes; a nil tint
      /// leaves `style.tint` nil (the kind's own).
      static func leaf(_ kind: ElementKind, frame: CGRect, text: String = "", tint: RGBColor? = nil, symbol: String? = nil,
                       shape: ShapeKind? = nil, imageID: UUID? = nil, fontSize: CGFloat? = nil, fontWeight: FontWeightChoice? = nil,
                       textColor: RGBColor? = nil, cornerRadius: CGFloat? = nil, opacity: Double? = nil,
                       textAlignment: TextAlignmentChoice? = nil, borderColor: RGBColor? = nil, borderWidth: CGFloat? = nil,
                       hasShadow: Bool = false, rotation: Double? = nil, name: String? = nil, isLocked: Bool = false,
                       isHidden: Bool = false, isOn: Bool = true, value: Double? = nil, buttonLook: ButtonLook? = nil,
                       id: UUID = UUID()) -> LayerNode
      static func container(_ kind: ElementKind = .group, layout: LayerNode.Layout? = nil, frame: CGRect = .zero,
                            width: LayerNode.Sizing = .init(.fit), height: LayerNode.Sizing = .init(.fit), padding: CGFloat = 0,
                            rotation: Double? = nil, children: [LayerNode], id: UUID = UUID()) -> LayerNode
  }
  @MainActor extension DesignStore {
      @discardableResult func addFreeScreen(_ nodes: [LayerNode], name: String = "Screen 1", device: DeviceFrame = .iPhone,
                                            origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen.ID
      @discardableResult func addColumnScreen(_ nodes: [LayerNode], name: String = "Screen 1", spacing: CGFloat = 24,
                                              device: DeviceFrame = .iPhone, origin: CGPoint = .zero, scale: CGFloat = 1) -> TreeScreen.ID
      @discardableResult func addCanvasNode(_ node: LayerNode, scale: CGFloat = 1) -> UUID
      func ownFrame(_ id: UUID) -> CGRect?                 // ownPose's frame: what a test read as `element.frame`
      func screenLeaves(_ screenID: TreeScreen.ID) -> [LayerNode]   // what `screen.elements` held
      /// What the plan-5 wrapper `addElement(_:from:to:)` gave a test (F12): the node `addSketched(kind, from: sketch,
      /// confidence: 1, decidedBy: .rules)` made (sketch in canvas points), with its frame in screen points. Nil off `screenID`.
      func sketched(_ kind: ElementKind, from sketch: CGRect, to screenID: TreeScreen.ID) -> (id: UUID, frame: CGRect)?
  }
  enum TreeFixture {
      struct Login { var model: AppModel; var undo: UndoManager; var designID: String
          var screen: TreeScreen.ID; var title, card, about, body, row, label, toggle, note: UUID }
      /// The design Tasks 3–8 share. See "The fixture".
      @MainActor static func loginWithACardAndARow() -> Login
  }
  ```
- **The fixture.** An `AppModel` with an undo manager. It is saved to a unique temporary `.layer`, and the model's `fileURL` is set to it. So its `designID` is that file's id (`DesignLibrary.id(for:)`), and the model registers itself with `OpenDesigns` (F17). Tests write `"\(login.designID)|…"` for an entity id, and never read `OpenDesigns.shared.current` across an await. It has one iPhone screen "Login" at origin (0, 0), scale 1, zoom 1, on a free root holding:
  - `title`: a title "Welcome" at (20, 80, 228, 40);
  - `card`: a free card at (20, 140, 353, 160), `.fixed` on both axes, padding 16, holding:
    - `about`: a text "About me" at (16, 16, 200, 24);
    - `body`: a body "Designing better experiences." at (16, 48, 321, 40);
  - `row`: a group at origin (20, 320), fit on both axes, laid out as `.stack(horizontal, spacing 12, alignment .center)`, holding:
    - `label`: a text "Wi-Fi", 80 × 24 and fixed;
    - `toggle`: a toggle, 51 × 31, fixed and on.

  The canvas holds `note`: a sticky note "Idea" at (600, 100, 150, 150) with scale 0.5.

- [ ] **Step 1: Check the start, and take the inventory.**
  - Plan 2's clause (h) tolerances are gone (F4). `grep -rni "clause (h)\|framesWithin\|func holds(" LayerTests` finds nothing, and plan 4's ledger records both MUST-DOs done. If not, stop: it is plan 4's unfinished work, fixed as a bug before the lanes are cut, and never ported.
  - Record, before any change, `DesignActions.frameForNewElement` of a button on a free iPhone screen holding only the title (20, 80, 228, 40). Its minY is 136. It is written in Step 2 as a literal (F16).
  - Write `scripts/check-flat-model.sh` as above, without the allowlists, and run it.
  - Every file listed goes into its lane's allowlist by call 2. Files with tier-2 hits only aren't listed. `DesignActions.swift`, `AppModel.swift` and `Groups.swift` go in `a.txt` (call 2's shared files).
  - Record in the ledger the table of each file and its owning task, with the hits each shared file may keep. Record the counts too: `flat model: N references in M files`.
  - Split `groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed` as Files says, and run its three parts. Expected: PASS, assertions unchanged.

- [ ] **Step 2: Write the failing tests** in `TreeBuildersTests` (`@MainActor`):
  - `aLeafLowersToTheElementItReplaces` (a bridge, retired in Task 11 under (s)). For six elements, `DesignElement(node: .leaf(…the same arguments…), frame: e.frame, rotation: e.rotation, parent: nil, scale: nil, group: nil) == e`, ids included. `.leaf`'s labels are in its own order, so a port moves `rotation:` and `id:` to theirs. The six are:
    - a button with every field set;
    - a text with font size 20, `.bold`, text colour `0x333333` and `.center`;
    - a symbol `heart.fill`;
    - an image with an `imageID`;
    - a toggle that is off;
    - a progress bar at 0.3.
  - `aFreeScreenHoldsWhatItWasGiven`:
    - `addFreeScreen([a, b])` gives `root.children.map(\.id) == [a.id, b.id]` and `root.layout == nil`.
    - `ownFrame(a.id) == CGRect(x: 20, y: 80, width: 228, height: 40)`.
    - One undo removes the screen.
  - `aColumnScreenLaysItsChildrenOut`: two 100 × 24 texts on `addColumnScreen` give the root `.stack(vertical, spacing 24)`. The first's minX is 20, and the second's minY is the first's maxY + 24.
  - `screenLeavesAreDepthFirst`: in the fixture, `screenLeaves(screen).map(\.id) == [title, about, body, label, toggle]`, and `tree.canvasLeaves.map(\.id) == [note]`.
  - `theFixtureIsAsDescribed`:
    - The row's frame is (20, 320, 143, 31).
    - `ownFrame(label) == (20, 324, 80, 24)`: centred in the row it is 3.5 down, and the engine snaps a laid-out frame to whole points (F7). `ownFrame(toggle) == (112, 320, 51, 31)`.
    - The note's `hostShape` rect is (300, 50, 75, 75).
    - `login.designID` is the id of the fixture's file, and `OpenDesigns.shared.model(forDesign: login.designID) === login.model`.
  - `aNewElementGoesWhereItWentBefore`:
    - On a free screen holding only the title, `newElementFrame(.button, on:)` equals the rect Step 1 recorded from today's `frameForNewElement`, written as a literal (F16).
    - Its minY is 136.
  - `aNewElementGoesBelowACardWhole` (F28): on a free screen holding a card at (20, 80, 353, 200) whose one text ends at y 140, the new button's minY is 296 (the card's maxY 280 + 16).
  - `aStandardLeafIsTodaysNewElement` (F13): `LayerNode.standard(.button)` has the button's placeholder text, `style.tint == ElementKind.button.spec.tint`, today's standard size, and `.fixed` on both axes. `.standard(.symbol, symbol: "heart.fill")` keeps the symbol.
  - `aHostFrameFollowsTheDragRule` (F13), in the fixture:
    - About moved to (60, 160, 200, 24) gives `.placed`, and about stays in the card.
    - The label moved to (40, 600, 80, 24) gives `.takenOut`, and it is the root's last child, `.fixed`.
    - The toggle moved to (10, 320, 51, 31), its centre before the label's mid-x, gives `.reordered`, and the row holds `[toggle, label]`.
    - The label at width 120 with `size: true` gives `.resized`, and it stays in the row.
    - On a column screen, a child moved to (500, 900, 100, 24), outside the root, gives `.refused`, and `store.tree` is unchanged (F15).
    - Each is one undo step.
  - `aCustomDeviceIsFoundByItsName` (F13): with "Kiosk" made, `customDevice(named: " kiosk ")` is Kiosk, and `"Wall"` gives nil.
  - `sketchedIsWhatTheWrapperGave` (F12): `sketched(.title, from: sketch, to: screen)` gives the same frame as plan 5's wrapper `addElement(.title, from: sketch, to: screen)` on a twin store. This is a bridge line, removed in Task 11 under (s).

- [ ] **Step 3: Run them.** Run `TreeBuildersTests`. Expected: FAIL (the builders, `newElementFrame`, `standard`, `move(_:toHostFrame:)` and `customDevice(named:)` don't exist).

- [ ] **Step 4: Implement** the producing files. `DesignActions.frameForNewElement` becomes a one-line call of `ElementLayout.newElementFrame` with its screen's visible element frames, until Task 5 deletes it.

- [ ] **Step 5: Run them, and the gate.**
  - Run `TreeBuildersTests`, `SiriIntentsTests`, `VoiceToolsTests` and `GroupTests` (their structs, as the Global Constraints' table lists them), then the full unit suite. Expected: PASS, and TEST SUCCEEDED.
  - `Tools/SketchBenchmarkHarness/run.sh check` passes, since `ElementLayout.swift` is a harness file (F21).
  - `scripts/check-flat-model.sh` prints `…, all allowed` and exits 0.
  - `--strict` exits 1, listing at least the files of Step 1.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Plan 6's gate: the flat model's names found and allowed per lane, test builders for the tree, and the shared fixture"`

---

### Task 2: Measuring, prepared

**Lane:** A (after Task 1)

**Files:**
- Create: `scripts/measure-semantic-tree.sh`
- Modify: `Tools/ScreenBenchmarkHarness/Sources/ScreenBenchmarkHarness/Harness.swift` and `Score.swift`, and `Tools/ScreenBenchmarkHarness/run.sh` (the `both` mode, and rule cases in `check`)
- Modify (q): `LayerTests/StoreChangeBenchmarkTests.swift`, on the tree. It is Task 2's, not Task 9's (F16).
- Modify (instrumentation, F3): `LayerTests/CanvasDragWorkTests.swift`, `LayerTests/CanvasDragLandingTests.swift` (its `LayoutDragTests` suite, F19) and `LayerTests/NodeViewTests.swift`. Each gets one `print("BENCH drag …")` of what it already counts. `LayerTests/TreeRulesTests.swift` (`oneEditOnAHundredNodeScreenIsQuick`) gets `print("BENCH rules edit p50=… p95=…")`, and `LayerTests/SketchBenchmarkTests.swift` (`printsTheFullBenchmarkReport`) gets `print("BENCH sketch accuracy …")` (F22). No assertion changes.
- Modify: `docs/benchmarks/semantic-tree.md` (a "How to measure" paragraph naming the script and its conditions)

**Interfaces:**
- Consumes:
  - plan 2: `StoreChangeBenchmarkTests` (its commit holds the version that runs on main) and `StoreChangeBudgetTests`;
  - plan 1: `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick`;
  - plan 5: `SketchConversionBudgetTests` and `SketchBenchmarkTests/printsTheFullBenchmarkReport`;
  - plan 3: `GenerationThroughTheReconcilerTests`;
  - `CanvasBenchmarkUITests/testCanvasWorkout`;
  - plan 3's harness `Score` and summaries.
- Produces:
  ```
  scripts/measure-semantic-tree.sh [--quick] [--simulator <name>] [--main <worktree>]
    Runs each §13 measurement (test command flags as in Global Constraints), quietly, and prints only:
      the 1-minute load before each timed run; every "BENCH …" line; the workout's "CPU Time", "Peak Physical Memory"
      and "Clock Monotonic Time" medians of 3 runs, each run the average of 5 iterations with its relative standard
      deviation (Release, testCanvasWorkout); then "measure ok: <n> lines". Exit non-zero on any failure.
    The simulator is "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47) unless --simulator says
    otherwise. Without --quick it refuses to time anything at a 1-minute load of 20 or more (`sysctl -n vm.loadavg`) (F5).
    The workout's Release build happens in a temporary worktree (or a temporary copy of the scheme and
    TestPlans/Layer.xctestplan) with LayerTests taken out of the scheme's build entries and the Layer test plan, as the
    baseline was. `kahshin.Layer` is uninstalled first. Committed files are never changed: `git status --porcelain` is
    the same before and after.
    --quick   leaves out the workout, and the load check.
    --main    runs, in that worktree, the store benchmark from plan 2 Task 1's own file (found with
              `git log --diff-filter=A --format=%H -- LayerTests/StoreChangeBenchmarkTests.swift | tail -1`) and the
              workout, under the same conditions.
  Tools/ScreenBenchmarkHarness/run.sh hosted <model> both [runs]
    Per brief, both formats one after the other; A2UI first on odd briefs. Each format's summary as today, then:
      hosted default: <a2ui|outline> — valid <a>/<n> vs <o>/<n>; first content p50 <a> ms vs <o> ms (<+x|−x>%)
  ```
  ```swift
  enum HostedFormatRule {            // Score.swift, in the harness: My call 8, in one place
      struct Result: Sendable { var valid: Int; var screens: Int; var firstContentP50: Double }
      /// "a2ui" unless A2UI has fewer valid screens, or its first-content median is more than 25% above the outline's.
      static func decide(outline: Result, a2ui: Result) -> String
  }
  ```

- [ ] **Step 1: Write the failing checks.**
  - `run.sh check` gains four rule cases, and prints `rule ok: 4/4` only when all hold. Each case is (outline valid, A2UI valid, outline p50, A2UI p50, over 24 screens):
    - (24, 23, 1000, 1000) gives `outline`;
    - (24, 24, 1000, 1300) gives `outline`;
    - (24, 24, 1000, 1250) gives `a2ui`, since it is not *more* than 25%;
    - (22, 24, 1000, 1200) gives `a2ui`.
  - Port `StoreChangeBenchmarkTests` under (q). The layout is the same: an iPhone free root of 25 rows, each a text, a body, a toggle and a divider at plan 2's frames. The four ops are the same:
    - move: `update(id) { $0.frame.origin.x += 1 }`;
    - resize: `update(id) { $0.frame.size.width += 1 }`;
    - text: `update(id) { $0.content.text += "a" }`;
    - add: `add(text, to: .screen(id))`, then `delete(nodes:)`.

    So are the same `BENCH store <op> p50=<ms> p95=<ms>` lines and the sanity bound.

- [ ] **Step 2: Run them.** `Tools/ScreenBenchmarkHarness/run.sh check`. Expected: FAIL (no rule).

- [ ] **Step 3: Implement** `HostedFormatRule`, the `both` mode, the script and the six `print`s.

- [ ] **Step 4: Run them.**
  - `run.sh check` prints `harness ok: outline 1/1 valid, a2ui 1/1 valid` and `rule ok: 4/4`, and exits 0.
  - `StoreChangeBenchmarkTests` without the variable is skipped, and the build succeeds.
  - `scripts/measure-semantic-tree.sh --quick` prints lines beginning with each of these, then `measure ok`, and exits 0:
    - `BENCH store move`, `BENCH store resize`, `BENCH store text`, `BENCH store add`;
    - `BENCH tree`, four times;
    - `BENCH rules edit` (F22);
    - `BENCH sketch reading`, `BENCH structure pass` and `BENCH sketch accuracy`;
    - `BENCH drag line`, `BENCH drag group`, `BENCH drag row child` and `BENCH node views`.

    These numbers aren't recorded: the machine isn't quiet.
  - `git status --porcelain` is the same as before the script ran.
  - Remove `LayerTests/StoreChangeBenchmarkTests.swift` from `a.txt`. `scripts/check-flat-model.sh` exits 0.
  - Run the full unit suite. Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Measuring, prepared: one script for every §13 row, the hosted formats run side by side with My call 8's rule, and the store benchmark on the tree"`

---

### Task 3: Siri reads the tree

**Lane:** B (first; waits for Task 1)

**Files:**
- Modify:
  - `Layer/Intents/DesignActions.swift`: `DesignSnapshot` holds `TreeContent`. The node lookups and `selectedLeaf(in:)` are added, and `reveal`, `suggested`, `entity(for:)`, `DesignDescriber` and `DesignLayoutWriter`'s reads move to the tree, with the JSON unchanged.
  - `Layer/Intents/LayerEntities.swift`: `ScreenEntity(design:designName:screen:settings:)` and its `deviceName`, `ElementEntity(design:host:hostName:node:isLocked:isHidden:)`, and `DesignEntity(id:content: TreeContent, fallbackName:modified:)` (F29).
  - `Layer/Intents/DesignLibrary.swift`: `DesignSummary.content` becomes a `TreeContent`.
  - `Layer/Intents/DesignIndexer.swift`, `Layer/Intents/OnscreenContext.swift`, and `Layer/Intents/OpenDesigns.swift` where it reads content.
- Modify (q): the `SiriIntentsTests` structs `EntityKeyTests` (with Task 1's moved `aGroupsMembersAreSirisElements`), `DesignLibraryTests`, `DesignIndexTests` and `OpeningDesignTests`; `ComponentCatalogueTests`' `DesignSnapshot` line (F10); `DeviceReflowTests`, only where it builds a `ScreenEntity` (F11)
- Create: `LayerTests/Goldens/DesignLayout-sketch.json`, recorded in Step 1 before any change
- Test: `LayerTests/SiriOnTheTreeTests.swift`

**Interfaces:**
- Consumes: Task 1 (`leaves`, `TreeFixture`), plan 1's `TreeIndex(_:)`, plan 4's `selectedNode`, `selectedScreenID`, `ref(of:)` and `Entry.hostShape`.
- Produces:
  ```swift
  struct DesignSnapshot: Sendable {
      let id: String; let name: String; let content: TreeContent; let modified: Date?; var isRead = true
      var elements: [ElementEntity] { get }   // every screen's leaves, then the canvas's (My call 9)
  }
  extension ScreenEntity {
      init(design: String, designName: String, screen: TreeScreen, settings: CanvasSettings)
      /// A design's own device's name, else the built-in's display name ("Phone", "Tablet"…), never `DeviceChoice.name`,
      /// which is the trademark (F23).
      @Property(title: "Device Name") var deviceName: String
  }
  extension ElementEntity {
      init(design: String, host: TreeIndex.Host, hostName: String, node: LayerNode, isLocked: Bool, isHidden: Bool)
  }
  extension DesignEntity {
      init(id: String, content: TreeContent, fallbackName: String, modified: Date? = nil)   // F29
  }
  // Until Task 11's rename, `TreeIndex.Host` and `DesignStore.ElementRef.Host` are two enums of one shape. They are
  // converted in one place, where `EntityKey.element` is called; Task 11 removes the conversion (F29).
  extension DesignActions {
      static func node(_ entity: ElementEntity) async throws -> (model: AppModel, ref: DesignStore.ElementRef, node: LayerNode)
      static func nodeOrSelected(_ entity: ElementEntity?) async throws -> (model: AppModel, ref: DesignStore.ElementRef, node: LayerNode)
      /// The one leaf selected. Nil for a container, several things or nothing: Siri sees what is in a container (My call 9).
      static func selectedLeaf(in model: AppModel) -> PlacedNode?
      static func treeScreenOrCurrent(_ entity: ScreenEntity?) async throws -> (model: AppModel, screen: TreeScreen)
  }
  enum DesignDescriber {
      static func summary(of screen: TreeScreen, in content: TreeContent) -> String   // visible leaves by minY, today's words
      static func describe(_ node: LayerNode) -> String
      static func describe(_ snapshot: DesignSnapshot) -> String
  }
  ```
  The old lookups that hand back a `DesignElement` (`element(_:)`, `elementOrSelected`, `selected(in:)`, `selectedElement(in:)`, `screenOrCurrent`) stay until Task 5 moves their callers.

- [ ] **Step 1: Record today's JSON, and write the failing tests.**
  - Before changing anything, record `DesignLayoutWriter.json(for:)` of plan 1's `design-sketch.json` design as `LayerTests/Goldens/DesignLayout-sketch.json`. Record it the way Task 4 records its golden, with `TEST_RUNNER_LAYER_RECORD_LAYOUT=<dir>`, from the unchanged writer (F9).
  - Then write `SiriOnTheTreeTests` (`@MainActor`, `TreeFixture.loginWithACardAndARow()`):
  - `elementEntitiesAreLeavesOnly`:
    - `snapshot.elements.map(\.kind) == [.title, .text, .body, .text, .toggle, .stickyNote]`.
    - Their ids end with the uuids of title, about, body, label, toggle and note, in that order.
    - None ends with the card's or the row's uuid.
  - `anEntityIDKeepsItsForm`:
    - about's id is `"\(login.designID)|\(screen.uuidString)|\(about.uuidString)"`, and note's is `"\(login.designID)|canvas|\(note.uuidString)"` (F17).
    - `EntityKey.parseElement` gives each one's host and id back.
  - `aSelectedContainerIsInvisibleToSiri`:
    - With the card selected, `selectedLeaf(in:)` is nil, and `suggested(…)`'s first is the title, as listed.
    - With `about` selected, both are `about`.
  - `lockedByAnAncestorIsLocked`: with the card locked:
    - about's entity has `isLocked == true`;
    - `requireUnlocked` on about's ref throws `.locked`;
    - the title's entity has `isLocked == false`.
  - `aScreensElementsAreItsLeaves`: the screen's entity has `elementCount == 5` and `summary == "title “Welcome”, text “About me”, body “Designing better experiences.”, toggle, text “Wi-Fi”"`. It is sorted by minY, as today: the toggle's 320 comes before the label's 324 (F7).
  - `aCustomDevicesScreenSaysItsName`: a screen on a custom device "Kiosk" (1080 × 1920) has `deviceName == "Kiosk"`, and the iPhone screen has `"Phone"`.
  - `onscreenEntitiesAreLeavesAtTheirViewFrames`:
    - At zoom 1, at the canvas origin, about's onscreen bounds are (36, 156, 200, 24).
    - With the card turned 90, they are (236.5, 59.5, 24, 200): the box round its turned shape.
  - `aClosedDesignIsReadFromItsFile`: the fixture is saved to a temporary `.layer` and closed. `DesignActions.snapshots(with:)` of its summary gives the same six entity ids.
  - `todaysJSONIsUnchangedWithoutContainers`: the JSON of the `design-sketch.json` design equals the golden. Task 4 deletes it, because its new keys break exact equality; `todaysKeysKeepTheirValues` replaces it (F9).
  - `readingDoesNotLower` (F18), synchronous:
    - After a tree-verb change, a `store.screens` read raises `TreeProjection.lowerings(of: screen)` by 1, which shows the counter is live.
    - After another change, building `snapshot.elements` and the JSON raises it by 0.

    Its lowering lines go in Task 11 under (s).

- [ ] **Step 2: Run them.** Run `SiriOnTheTreeTests`. Expected: FAIL (`DesignSnapshot.content` isn't a `TreeContent`, and the initialisers don't exist).

- [ ] **Step 3: Implement.**
  - Snapshots read `store.tree` and `DesignFile.content(at:).tree`.
  - Leaves' frames come from `TreeIndex(content)[id].hostShape`.
  - Lock and hide come from the index, folding ancestors but not the screen.
  - `reveal` frames a node by its canvas shape.
  - `DesignLayoutWriter` still writes today's keys only, from the tree.

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run `SiriOnTheTreeTests`, then `SiriIntentsTests` (its structs), `BuildScreenTests`, `ComponentCatalogueTests` and `DeviceReflowTests`, which must pass apart from the (q) changes listed. Then run the full unit suite. Expected: PASS, and TEST SUCCEEDED. Remove this task's files from `b.txt`. The gate exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Siri reads the tree: snapshots of the tree, leaves as entities under the ids they always had, and a container invisible to Siri"`

---

### Task 4: Get Design Layout shows the tree

**Lane:** B (after Task 3)

**Files:**
- Create: `Layer/Intents/DesignLayoutWriter.swift`, moved out of `DesignActions.swift`
- Modify: `Layer/Intents/DesignIntents.swift` (`GetDesignLayoutIntent`'s description names containers, parent, layout, sizing and rotation)
- Create: `LayerTests/Goldens/DesignLayout-containers.json` (recorded in Step 3)
- Modify: `LayerTests/SiriOnTheTreeTests.swift`, deleting Task 3's `todaysJSONIsUnchangedWithoutContainers`, which `todaysKeysKeepTheirValues` replaces (F9)
- Modify (v): `LayerTests/Goldens/ComponentKinds.txt`, its 16 "layout data" lines, which gain `sizing` (F10)
- Test: `LayerTests/DesignLayoutTreeTests.swift`

**Interfaces:**
- Consumes: Task 3, plan 1's `LayerNode.Layout` and `Sizing` coding, and `TreeIndex`.
- Produces:
  ```swift
  enum DesignLayoutWriter {
      /// Today's JSON, plus the tree (call 4). Leaves gain "sizing", "parent" and "rotation"; screens gain "deviceName",
      /// "layout", "padding" and "containers"; the top level gains "canvasContainers". "device" is the device's id.
      /// Frames are host shapes: screen points on screens, canvas points on the canvas (call 3). Sorted keys.
      static func json(for snapshot: DesignSnapshot, ink: (count: Int, bounds: CGRect?)? = nil, hasUnreadSketch: Bool = false) -> String
  }
  ```
  A container's entry has these keys:
  - `id`: the entity form;
  - `kind`: `"group"` or `"card"`;
  - `name`;
  - `x`, `y`, `width` and `height`;
  - `layout`: as `design.json` writes it, with nil written as `{"type":"free"}`;
  - `padding`: `{"top","leading","bottom","trailing"}`;
  - `sizing`: `{"width":{"mode":…},"height":{"mode":…}}`, with `weight`, `min` and `max` when set;
  - `children`: ids, in order;
  - and, when present, `parent`, `rotation`, `locked` and `hidden`.

  `containers` lists the containers in pre-order. A screen's `deviceName` is a custom device's name, else the built-in's display name ("Phone", "Tablet"…), as `ScreenEntity.deviceName` (F23).

- [ ] **Step 1: Write the failing tests** in `DesignLayoutTreeTests` (`@MainActor`, the fixture):
  - `todaysKeysKeepTheirValues`: every key and value in `Goldens/DesignLayout-sketch.json` is present and equal in the new JSON of the same design, compared recursively, objects as subsets. It is the Shortcuts contract.
  - `leavesKeepTodaysKeysAndGainTheirPlaceInTheTree`:
    - about's entry has `x` 36, `y` 156, `width` 200, `height` 24, `kind` "text", `text` "About me", and `parent` equal to the card's id.
    - The title's entry has no `parent`.
    - The label's has `sizing == {"width":{"mode":"fixed"},"height":{"mode":"fixed"}}`.
  - `containersListTheirChildrenLayoutAndSizing`:
    - The screen's `containers` ids are `[card, row]`.
    - The row's entry has:
      - `kind` "group";
      - `layout == {"type":"stack","axis":"horizontal","spacing":12,"alignment":"center","justify":"start"}`;
      - `children` == [label, toggle];
      - x 20, y 320, width 143, height 31;
      - `sizing.width.mode == "fit"`.
    - The card's entry has `layout == {"type":"free"}`, padding 16 on each edge, and `children` == [about, body].
  - `framesAreScreenPointsOnScreensAndCanvasPointsOnTheCanvas`:
    - The note in `canvasElements` has x 300, y 50, width 75 and height 75.
    - A canvas group at (100, 100, 200, 200), scale 0.5, is in `canvasContainers` at (50, 50, 100, 100).
  - `rotationIsTheTurnSeen`: with the card turned 90, the card's entry has `rotation` 90, and about's has x 148.5, y 147.5, width 200, height 24 and `rotation` 90.
  - `theScreenTellsItsLayoutAndDevice`:
    - A column screen has `layout.type == "stack"`, `axis` "vertical" and `spacing` 24.
    - A screen on a custom "Kiosk" has `device` equal to Kiosk's id (beginning `custom-`), `deviceName` "Kiosk", and width 1080 and height 1920.
    - The iPhone screen has `device` "iphone" and `deviceName` "Phone".
  - `theContainersGoldenHolds`: the fixture's JSON equals `Goldens/DesignLayout-containers.json`.

- [ ] **Step 2: Run them.** Run `DesignLayoutTreeTests`. Expected: FAIL, except `todaysKeysKeepTheirValues`.

- [ ] **Step 3: Implement**, then record the containers golden with `TEST_RUNNER_LAYER_RECORD_LAYOUT=<dir>` and check it by eye: every number above appears, and nothing else is in it.

- [ ] **Step 4: Run them.**
  - Delete `todaysJSONIsUnchangedWithoutContainers` (F9).
  - Record `Goldens/ComponentKinds.txt` again under (v). The ledger shows that each changed line gained `sizing` and nothing else (F10).
  - Run `DesignLayoutTreeTests`, `SiriOnTheTreeTests`, `SiriIntentsTests` and `ComponentCatalogueTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED. The gate exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Get Design Layout shows the tree: containers with their children, layout and sizing, every node's parent and turn, and every key Shortcuts read before kept"`

---

### Task 5: Siri's actions write the tree, and choose devices by name

**Lane:** B (after Task 4)

**Files:**
- Modify:
  - `Layer/Intents/ElementIntents.swift`: every intent works on nodes. `AddElementIntent.add` and `MoveElementIntent.move` follow calls 3–5, through Task 1's `move(_:toHostFrame:)` and `LayerNode.standard`. Align throws `.laidOut` in any laid-out parent, and Arrange in a row, column or grid only (F14). The canvas Add uses `add(_:to: .canvas)` at the new node's scale, not `addFloating` (F2). The static helpers other lanes call keep their signatures (F11).
  - `Layer/Intents/ScreenIntents.swift`: Add Screen, Change Screen Device and Build Screen get `customDevice`, and the other intents act on `TreeScreen`. `ChangeScreenDeviceIntent` gets a `static func change(…)`, and its description now says the screen's contents follow where they were drawn.
  - `Layer/Intents/CanvasIntents.swift`: `UpdateCanvasSettingsIntent` gets `customSketchDevice`. `DrawStrokesIntent` describes the tree.
  - Each new parameter is listed in its intent's `parameterSummary`, or Shortcuts wouldn't show it. Change Screen Device's summary gains a closure for it (F23).
  - `Layer/Intents/ImageIntents.swift` and `Layer/Canvas/ImagePlaygroundSupport.swift`: a picture goes into an image node.
  - `Layer/Intents/LayerEntities.swift`: the two errors, and `CustomDeviceOptions`.
  - `Layer/Intents/DesignActions.swift`: `device(_:custom:in:)` through `CanvasSettings.customDevice(named:)` (F13). The old `DesignElement` lookups are deleted, and so is `frameForNewElement` (F16). `placementForNewScreen(_:in:near:)` and `edit` keep their signatures (F11). `TakenAction` stays as it is, for Task 11.
  - `Layer/Debug/DemoScript.swift`.
- Modify (q): `SiriIntentsTests` (`DesignActionTests`, `ImagePlaygroundTests`, `LookWordTests`, `MovingTests`), `SiriIntentsLiveTests`, `BuildScreenTests` and `DeviceReflowTests` (its Siri path, F11)
- Modify (q) and (s) (F24): `LookWordsEverywhereTests`:
  - `aLookCanBeGivenToAnElementAlone` and `controlsTakeTheirStateFromLookWords` move to a node under (q), their assertions kept;
  - `aLookOnANodeAndOnAnElementAgree` tests the `Look+Element` adapter Task 11 deletes. It is retired under (s), and the ledger names the two ported tests as what covers its node half.
- Test: `LayerTests/SiriWritesTheTreeTests.swift`

**Interfaces:**
- Consumes:
  - Tasks 1 and 3, Task 1's `move(_:toHostFrame:)`, `LayerNode.standard(_:symbol:)` and `CanvasSettings.customDevice(named:)` (F13) included;
  - plan 2's `add`, `move`, `update`, `delete(nodes:)` and `duplicate(node:)`;
  - plan 4's `place`, `resizeLaidOut`, `TreeDrop.target`, `placed` and `setDevice`;
  - plan 5's `changeDevice(of:to:)`;
  - plan 3's `BuildScreenIntent.build` and `Look.apply(to: inout LayerNode)`.
- Produces:
  ```swift
  extension LayerIntentError { case laidOut; case deviceNotFound(String) }     // messages: Global Constraints
  struct CustomDeviceOptions: DynamicOptionsProvider {
      func results() async throws -> [String]           // `names(in:)` of the front design
      /// The design's own devices' names, in the order made. What tests call, with the model (F17).
      @MainActor static func names(in model: AppModel) -> [String]
  }
  extension DesignActions {
      /// `custom`, through `settings.customDevice(named:)`, when given (call 6); else `choice`'s frame.
      static func device(_ choice: DeviceChoice?, custom: String?, in model: AppModel) throws -> DeviceFrame?
  }
  extension AddElementIntent {
      /// One step (call 5). The node is `LayerNode.standard`. A free root: at the frame given, else
      /// `store.newElementFrame`. A laid-out root: appended, each given size fixing its axis, any given x or y dropped.
      /// The canvas: `add(_:to: .canvas)`, canvas points ÷ the new node's scale.
      @MainActor static func add(_ node: LayerNode, to host: TreeIndex.Host, in model: AppModel, x: Double?, y: Double?,
                                 width: Double?, height: Double?, undoManager: UndoManager?) throws -> DesignStore.ElementRef
  }
  extension MoveElementIntent {
      /// One step (calls 3 and 5), through `move(_:toHostFrame:)`. Each given number within 0.05 of what Get Design
      /// Layout reports for the node counts as unchanged, and when all do nothing is written (F8). `.refused` (a laid-out
      /// root's child sent where it can't be kept) throws `.laidOut` (F15).
      @MainActor static func move(_ ref: DesignStore.ElementRef, in model: AppModel, x: Double?, y: Double?,
                                  width: Double?, height: Double?, undoManager: UndoManager?) throws
  }
  extension ChangeScreenDeviceIntent {
      /// The dialog takes "an" before a device name that starts with a vowel letter, and "a" otherwise: "an iPhone",
      /// "an iPad", "a MacBook Air 13″", "a Kiosk" (F23).
      @MainActor static func change(_ screen: TreeScreen.ID, to choice: DeviceChoice, custom: String?, in model: AppModel,
                                    undoManager: UndoManager?) throws -> String       // the dialog
  }
  // New optional parameters, never in place of one:
  //   AddScreenIntent / ChangeScreenDeviceIntent / BuildScreenIntent:
  //     @Parameter(title: "Custom Device", description: "One of this design's own devices, by name. Used instead of Device when given.",
  //                optionsProvider: CustomDeviceOptions()) var customDevice: String?
  //   UpdateCanvasSettingsIntent: @Parameter(title: "Custom Device for New Screens", …) var customSketchDevice: String?
  ```

- [ ] **Step 1: Write the failing tests** in `SiriWritesTheTreeTests` (`@MainActor`, the fixture, through the static helpers as `DesignActionTests` calls them):
  - `aLayoutsFrameMovedBackChangesNothing`:
    - The card is turned 30.
    - About's `x`, `y`, `width` and `height` are read from `DesignLayoutWriter.json` and passed to `MoveElementIntent.move`. They are rounded to a tenth there: about's x is 70.106…, written 70.1.
    - `store.tree` is unchanged, and the store's undo manager has nothing to undo (F8).
  - `aMoveInsideATurnedCardLandsWhereAsked`:
    - The card is turned 30, and about is moved to x 160, y 150.
    - About's `hostShape` rect is within the tolerance of plan 4's `placingUnderATurnedContainerLandsWhereAsked`, as plan 4's ledger records it, of (160, 150, 200, 24). That is 1e-6 if `place` is exact under a turned parent, else 1 pt (F8).
    - Its own `rotation` is still nil, and its parent is still the card.
  - `movingARowChildTakesItOutWhereAsked`:
    - The label is moved to x 40, y 600.
    - It is the root's last child, with `ownFrame` (40, 600, 80, 24), `.fixed` on both axes. The row holds `[toggle]`.
    - One undo step, named "Move Text", puts it back as the row's first child.
  - `movingWithinItsRowReorders`: the label moved to x 120, y 324 (its centre past the toggle's mid-x, inside the row) leaves the row holding `[toggle, label]` (F7).
  - `onAColumnScreenAMoveReorders`:
    - A column screen holds `[t1, t2, t3]`, three 100 × 24 fixed texts.
    - t1 moved to y = `ownFrame(t3).maxY + 10` leaves the root `[t2, t3, t1]`.
    - t1 moved to x 500, y 900, off the screen, throws `.laidOut`, and `store.tree` is unchanged (F15).
  - `aLaidOutChildStaysOnItsScreen`:
    - A second free iPhone screen sits at (453, 0).
    - The label moved to x 500, y 100 is the Login root's last child at (500, 100, 80, 24). The second screen is unchanged.
  - `resizingARowChildFixesItsAxis`: width 120 alone gives the label `width == .fixed` and `frame.width == 120`. Its height stays `.fixed` 24, and the row's width becomes 183.
  - `alignAndArrangeRefuseALaidOutChild`:
    - Align Left on the label throws `.laidOut`, and Bring Forward on it throws `.laidOut`.
    - The message is exactly the Global Constraints' line, and `store.tree` is unchanged.
    - In an overlay of two texts, Bring Forward on the back one arranges it in front, and Align Left on it throws `.laidOut` (My call 15, F14).
  - `arrangingInAFreeCardStillWorks`: Bring Forward on about leaves the card holding `[body, about]`.
  - `addingToAFreeScreenGoesWhereItWent`: a button added with no frame has `ownFrame.minY == 367`, which is the toggle's maxY 351 + 16. It equals `newElementFrame(.button, on:)` taken before the add.
  - `addingToAColumnScreenAppendsIt`:
    - On `[t1, t2]`, a text "More" with width 200, x 40 and y 600 is added.
    - The root becomes `[t1, t2, more]`, with more's width `.fixed` at 200 and `ownFrame(more).minX == 20`.
  - `aCustomDeviceIsChosenByName`:
    - The design holds a custom "Kiosk" (1080 × 1920, family `.other`).
    - `ChangeScreenDeviceIntent.change(screen, to: .iPhone, custom: " kiosk ", …)` gives `deviceID == kiosk.id` and a root frame of (0, 0, 1080, 1920), as one step.
    - Its dialog is `Login is now a Kiosk screen.` Back to the iPad without `custom`, it is `Login is now an iPad screen.` (F23).
  - `anUnknownCustomDeviceIsRefused`: `custom: "Wall"` throws `.deviceNotFound("Wall")`, whose message is exact, and `store.tree` is unchanged.
  - `theOptionsAreTheDesignsOwnDevices`: with "Kiosk" then "Watch" made, `CustomDeviceOptions.names(in: login.model) == ["Kiosk", "Watch"]` (F17).
  - `newScreensCanBeOnACustomDevice`:
    - Add Screen with `customDevice` "Kiosk" makes a screen whose `deviceID == kiosk.id`.
    - So does `BuildScreenIntent.build(…, device: kiosk, …)`.
    - Update Canvas Settings with `customSketchDevice` "Kiosk" makes the new-screen device Kiosk.
  - `everyWriteIsOneStepWithSystemUndo`:
    - Each of these runs on a node inside the card or the row, with a separate `UndoManager` as the system's: Add, Edit Text, Move, Move to Screen, Style, Duplicate, Delete, Set Hidden, Set Locked, Rename, and Change Screen Device with `custom` (F30).
    - Each adds exactly one step to the store's history and one to that manager.
    - That manager's `undo()` restores `store.tree` to before.
    - After a later hand edit to the same node, the action is withdrawn, as `DesignActionTests` checks today.
  - `movingToAnotherScreenTakesItOutOfItsContainer` (F30): with a second free iPhone screen, Move to Screen of about at x 40, y 40 puts it on that screen's root at (40, 40, 200, 24), `.fixed` on both axes, as one step. The card keeps body.
  - `aPictureGoesIntoAnImageInACard`: Image Playground's placement onto an image leaf inside the card sets its `content.imageID` and keeps its frame and parent.

- [ ] **Step 2: Run them.** Run `SiriWritesTheTreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - Every intent reads through Task 3's node lookups and writes through the tree's verbs inside `DesignActions.edit`.
  - Delete `element(_:)`, `elementOrSelected`, `selected(in:)`, `selectedElement(in:)`, the old `screenOrCurrent` and `frameForNewElement` (F16). Rename `treeScreenOrCurrent` to `screenOrCurrent`.
  - Keep the signatures F11 names: `ArrangeElementIntent.arrange(_:in:_:undoManager:)`, `MoveElementIntent.move`, `DeleteElementIntent.delete`, `SetElementHiddenIntent.setHidden`, `SetElementLockedIntent.setLocked`, `DesignActions.edit` and `placementForNewScreen(_:in:near:)`.
  - `cantGoFurther(withinGroup:)` is true when the node's parent is a container.
  - `grep -n "DesignElement\|DesignScreen\|store\.resolve\|store\.screens\|selectedElement\|addFloating\|LookWords.look(from:.*).apply(to: &element" Layer/Intents Layer/Canvas/ImagePlaygroundSupport.swift Layer/Debug/DemoScript.swift` finds nothing. `TakenAction`'s `DesignContent` is Task 11's, and this grep doesn't look for it (F16).

- [ ] **Step 4: Run them, and the suites that must pass unchanged.**
  - Run `SiriWritesTheTreeTests`, `SiriIntentsTests` (its structs), `BuildScreenTests`, `LookWordsEverywhereTests`, `DeviceReflowTests` (including `everyPathChangesTheDeviceTheSameWay`), `UndoNameTests`, `SiriOnTheTreeTests` and `DesignLayoutTreeTests`. Apart from the (q) and (s) changes listed, they pass unchanged.
  - Run `GroupTests`, `LayerOrderTests`, `ConcurrentEditTests` and `PencilVoiceTests`, which call this lane's statics. They pass unchanged (F11).
  - Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.
  - Remove the Siri files from `b.txt`. `DesignActions.swift` stays in `a.txt` for Task 11. The gate exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Siri writes the tree: Add and Move in screen points through the index, a laid-out child moved by the drag rule, and devices chosen by name, the design's own included"`

---

### Task 6: Voice sees the tree

**Lane:** C (first; waits for Task 1)

**Files:**
- Modify:
  - `Layer/Voice/CanvasPicture.swift`: the nesting, the `layout` words, the `devices` line, and the brief count of leaves;
  - `Layer/Voice/CanvasPicture+Capture.swift`: captured from the tree and the index, with `words(for:)`;
  - `Layer/Voice/VoiceHandles.swift`: node ids and `TreeScreen.ID`s;
  - `Layer/Voice/PencilVoice.swift`: the pointed thing and `isPart`, on nodes;
  - `Layer/App/AppModel.swift`: `voiceVocabulary` only, from leaves' words;
  - `Tools/VoiceBenchmarkHarness/Harness.swift` and `run.sh`: it builds with the new fields, and a `check` mode builds and prints `harness ok: 21 tools` without calling a model.
- Modify (q)(r): `PencilVoiceTests`, only where it builds the design or reads a pointed group
- Modify (q)(r): `VoiceToolsTests`' `CanvasPictureTests.aGroupsMembersAreToldInItsPlace`, the picture lines Task 1 moved out of `GroupTests` (F11). The group is now told with a handle, its two members indented under it, so the screen's top-level elements are four. Every member is still told once.
- Test: `LayerTests/CanvasPictureTreeTests.swift`

**Interfaces:**
- Consumes: Task 1's fixture and `leaves`, plan 4's `ownPose`, `selectedNode`, `hoverTarget(at:skippingDrawings:)` and `canvasShape(of:in:)`, and plan 2's `CanvasSettings.customDevices`.
- Produces:
  ```swift
  struct CanvasPicture {
      struct Element {   // new fields; defaults keep the harness's literals compiling
          var layout: String? = nil        // a container's layout in words; nil for a leaf, a free group or a free card
          var isContainer = false
          var children: [Element] = []     // reading order: layout order in a row, column, grid or overlay; else (minY, minX)
      }
      struct Screen { var layout: String? = nil }   // its root's, when not free
      var devices: [String] = []           // the design's own, as "\"Kiosk\" 1080x1920"
  }
  extension CanvasPicture {                // CanvasPicture+Capture.swift
      @MainActor static func capture(from model: AppModel, handles: VoiceHandles) -> CanvasPicture
      /// "row, spacing 12, centred"; "column, spacing 16"; "grid of 2, spacing 12" (or "…, spacing 12 across, 16 down");
      /// "overlay"; nil for free. Alignment is told only when it isn't start: rows say top/centred/bottom/stretched,
      /// columns left/centred/right/stretched.
      static func words(for layout: LayerNode.Layout?) -> String?
  }
  @MainActor final class VoiceHandles {
      func handle(forScreen id: TreeScreen.ID) -> String
      func handle(forNode id: UUID) -> String      // one E sequence for every node (call 7)
      func screen(_ handle: String) -> TreeScreen.ID?
      func node(_ handle: String) -> UUID?
  }
  ```
- **How a line reads:**
  - A leaf's line is today's, with its frame in screen points from `ownPose` and its summed angle.
  - A container's line is its handle, then its kind word, then its frame and flags as a leaf's, then `:`. Its children follow, indented two more spaces. The kind word is:
    - a `.group`'s layout words, or `group`;
    - for a card, `card`, then `, ` and its layout words when it has them.
  - A brief screen line counts its leaves.
  - The devices line comes last, before the scope line: `This design's own devices: "Kiosk" 1080x1920.`

- [ ] **Step 1: Write the failing tests** in `CanvasPictureTreeTests` (`@MainActor`, the fixture, `text(.full)` unless the test says otherwise):
  - `childrenAreIndentedUnderTheirContainer`. The text holds these lines exactly:
    - `  E1 title "Welcome" x20 y80 w228 h40`
    - `  E2 card x20 y140 w353 h160:`
    - `    E3 text "About me" x36 y156 w200 h24`
    - `    E4 body "Designing better experiences." x36 y188 w321 h40`
    - `  E5 row, spacing 12, centred x20 y320 w143 h31:`
    - `    E6 text "Wi-Fi" x20 y324 w80 h24`

    It also holds a line beginning `    E7 toggle x112 y320 w51 h31`.
  - `aRowIsToldInItsOrderAndAFreeContainerTopToBottom`:
    - With the row reordered to `[toggle, label]`, the E7 line comes before the E6 line, and the handles are unchanged.
    - With the card's children stored as `[body, about]`, E3 is still told before E4.
  - `aScreensRootLayoutIsOnItsLine`: a column screen "Feed" is told as `S2 "Feed" 393x852 column, spacing 24`.
  - `theCompactPictureTellsOneScreenWithItsNesting`: with Login and Feed both present and Feed in view, `text(.compact)` tells Feed in full, nested. The Login line ends with `, 5 elements`.
  - `aSelectedContainerIsSelectedItself`:
    - With the card selected, the card's line is `  E2 card x20 y140 w353 h160 [selected]:`.
    - No E3 or E4 line holds `[selected]`, and `selectionInWords == "E2, the card on S1"`.
  - `framesAreScreenPointsThroughTurnedContainers`: with the card turned 90, its line is `  E2 card x20 y140 w353 h160 turned 90°:` and E3's is `    E3 text "About me" x149 y148 w200 h24 turned 90°`.
  - `drawingsStayUntold`: a drawing on the canvas gives no line and no handle.
  - `theDesignsOwnDevicesAreTold`: with "Kiosk" (1080 × 1920), the text holds `This design's own devices: "Kiosk" 1080x1920.` Without it, no such line.
  - `handlesSurviveARegroup`: after the label and the toggle are ungrouped by hand, a new capture in the same call still calls them E6 and E7.
  - `thePencilNamesTheContainerItPointsAt`: pointed at the card's empty area (canvas (300, 280)), `thingHint` contains `E2, the card`.
  - `theVocabularyIsTheLeavesWords`: `voiceVocabulary` contains "Welcome", "About me" and "Wi-Fi".

- [ ] **Step 2: Run them.** Run `CanvasPictureTreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `CanvasPicture.swift` names no app type, so `run.sh check` still builds it with `RotationStub.swift` alone.

- [ ] **Step 4: Run them, and the suites that must pass unchanged.**
  - Run `CanvasPictureTreeTests`, `VoiceToolsTests`, `VoiceAgentTests`, `PencilVoiceTests` and `VoiceCallTests` (their structs). The login fixture they use has no containers, so their picture lines are unchanged. The one moved group case changes as Files says.
  - `Tools/VoiceBenchmarkHarness/run.sh check` prints `harness ok: 21 tools` and exits 0.
  - Then run the full unit suite and the UI suite: `VoiceModeUITests` drive the pencil and the pill (F20). Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set. The gate exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Voice sees the tree: the canvas picture tells containers with their layout in words and their children indented in reading order, and every node has a handle"`

---

### Task 7: Voice's tools act on the tree, and choose devices by name

**Lane:** C (after Task 6)

**Files:**
- Modify:
  - `Layer/Voice/VoiceToolbox.swift`: every tool resolves handles through the index and writes through the tree's verbs. It holds the laid-out rules (call 8), looks on groups and cards (call 7), `addElement` into laid-out parents, deleting containers, and `device(named:preferring:custom:)`. A take-out goes through Task 1's `move(_:toHostFrame:)`, a new element is `LayerNode.standard`, and the exact-name step is `customDevice(named:)` (F13).
  - `Layer/Voice/VoiceTools.swift`: `MoveElementTool` gains `takeOut`, and the device guides of `CreateScreenTool` and `ChangeScreenDeviceTool` add "or one of this design's own devices by name".
  - `Layer/Voice/ScreenEditor.swift`, `VoiceAgent.swift` and `VoiceCall.swift`, where they read the flat model;
  - `Layer/Debug/VoiceDemo.swift`;
  - `Tools/VoiceBenchmarkHarness/Harness.swift`: the recorder takes `takeOut`.
- Modify (q)(r): `VoiceToolsTests`, `VoiceAgentTests`, `VoiceCallTests`, `PencilVoiceTests`, `HostedToolCallingTests.swift`, `VoiceAgentLiveTests`, `VoiceScreenLayoutTests` and `DictationRouteTests`
- Test: `LayerTests/VoiceOnTheTreeTests.swift`

**Interfaces:**
- Consumes:
  - Task 6;
  - Task 1's `newElementFrame`, `move(_:toHostFrame:)`, `LayerNode.standard` and `customDevice(named:)` (F13);
  - plan 2's `update`, `add`, `move`, `delete(nodes:)` and `duplicate(node:)`;
  - plan 4's `place`, `resizeLaidOut`, `setCanvasPoses` and `TreeDrop.target`;
  - plan 5's `changeDevice(of:to:)` and `tidy(_:)`;
  - Task 3's `DesignActions.reveal`, whose signature is unchanged.
- Produces:
  ```swift
  protocol VoiceActing {   // changed requirement
      @MainActor func moveElement(element: String, x: String?, y: String?, width: String?, height: String?, takeOut: String?) -> String
  }
  extension VoiceActing {  // today's call keeps working
      @MainActor func moveElement(element: String, x: String?, y: String?, width: String?, height: String?) -> String
  }
  struct MoveElementTool { struct Arguments { …
      @Guide(description: "Only to take it out of the row, column or grid it is in: yes. Give x and y for where it goes.")
      var takeOut: String? } }
  extension VoiceToolbox {
      /// A name that is exactly one of `custom`'s, then the built-ins as today, then a custom name the words contain.
      static func device(named words: String, preferring usual: DeviceFrame = .iPhone, custom: [DeviceFrame] = []) -> DeviceFrame?
  }
  ```
- **The lines**, where `<E>` is the child and `<C>` its container, with its word: row, column, grid or overlay.
  - moveElement with a position on a laid-out child, and stackElements or placeElement on one: `<E> is in the <word> <C>, which places it. To change its place in <C>, call reorder. To take it out of <C>, call moveElement again with takeOut yes and where it goes.`
  - The same on a child of a laid-out screen root, with or without `takeOut`, where `<S>` is the screen: `<E> is in the column <S>, which places it. To change its place in <S>, call reorder.` (F15).
  - alignElement on one: `<E> is in the <word> <C>, which places it. To line things up in <C>, call setLayout on <C> with an alignment, such as <word> centred.`
  - takeOut with no x or y: `Say where <E> goes: x and y.`
  - Taken out: `Took <E> out of <C>.`
  - setText on a container: `<E> is a <card|row|…>, which has no words of its own.`
  - A device not found:
    - with custom devices, `I can make it an iPhone, iPad or Mac screen, or <names joined by ", ">, not “<words>”.`;
    - without, today's line, unchanged.

- [ ] **Step 1: Write the failing tests** in `VoiceOnTheTreeTests` (`@MainActor`, the fixture, a `VoiceToolbox` with fresh handles after one capture, so the handles are those of Task 6):
  - `movingARowChildSaysToReorder`: `moveElement(element: "E6", x: "40", y: "600", width: nil, height: nil, takeOut: nil)` returns exactly the move line for E6 in the row E5. `store.tree` is unchanged.
  - `takingARowChildOut`: the same with `takeOut: "yes"` returns `Took E6 out of E5.` The label is the root's last child at `ownFrame` (40, 600, 80, 24), `.fixed` on both axes.
  - `resizingARowChildFixesItsWidth`: `width: "120"` alone gives the label `width == .fixed` and `frame.width == 120`, and it stays in the row.
  - `aRowChildCanStillTurn`: `rotateElement(element: "E6", angle: "20", by: nil)` gives `label.rotation == 20`. The row's frames are unchanged.
  - `aContainerMovesWhole`: `moveElement(element: "E2", x: "30", …)` gives the card `ownFrame.minX == 30`, and its children's local frames are unchanged.
  - `aLookOnAGroupGoesToWhatItHolds`: `styleElement(element: "E5", look: "blue")` gives the label and the toggle `style.tint == ColourWords.named["blue"]`. The row's style is unchanged.
  - `aLookOnACardIsTheCards`: `styleElement(element: "E2", look: "#FFEECC, radius 24")` gives the card `style.tint == RGBColor(hex: 0xFFEECC)` and `cornerRadius == 24`. Its children are unchanged.
  - `setTextOnAContainerSaysItHasNoWords`: `setText(element: "E2", text: "Hi")` returns `E2 is a card, which has no words of its own.` and changes nothing.
  - `aLaidOutChildCantBeAligned`: `alignElement(element: "E6", alignment: "left")` returns the align line, with `such as row centred`.
  - `addingBesideARowChildJoinsTheRow`: `addElement(screen: nil, kind: "text", text: "Bluetooth", look: nil, relation: "right of", target: "E6")` leaves the row holding `[label, bluetooth, toggle]`.
  - `addingToAColumnScreenAppends`: on a column screen, `addElement` of a button puts it last in the root.
  - `aColumnScreensChildIsReorderedNotTakenOut` (F15): on a column screen S2 holding `[t1, t2]`, `moveElement` of t1 to x 40, y 600, with `takeOut: nil` and with `takeOut: "yes"`, each returns exactly the laid-out root line for S2, and `store.tree` is unchanged.
  - `deletingAContainerNeedsItsWord`:
    - `deleteElement(element: "E2", named: "card")` removes the card with both texts.
    - `named: "button"` is refused with today's line, and nothing changes.
  - `customDevicesAreChosenByName`, with a custom "Kiosk" and a custom "iPad Kiosk":
    - "Kiosk" gives Kiosk, and "the kiosk screen" gives Kiosk.
    - "iPad" gives `.iPad`, because a built-in wins over a name the words only contain.
    - "iPad Kiosk" gives the custom one.
    - `changeScreenDevice(screen: "S1", device: "kiosk")` makes S1 a Kiosk screen in one step.
    - "Wall" returns `I can make it an iPhone, iPad or Mac screen, or Kiosk, iPad Kiosk, not “Wall”.`
  - `handlesOfGoneThingsSayTheyAreGone`: after the card is deleted by hand, `setText(element: "E3", …)` returns today's `There is no E3` line.
  - `aScopedEditKeepsToItsScreen`: with the scope S1, `moveElement` on a node of a second screen returns today's `A change for one screen can't touch another` line.
  - `aCommandLowersNothing` (F18):
    - After a tree-verb change, a `store.screens` read raises `TreeProjection.lowerings(of: screen)` for the fixture's screen by 1, which shows the counter is live.
    - After another change, one `VoiceAgent` command with a scripted model raises it by 0. The command awaits the model, so only the fixture's screen is counted.

    Its lowering lines go in Task 11 under (s).

- [ ] **Step 2: Run them.** Run `VoiceOnTheTreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement**, then port the lane's test files under (q) and (r).
  - `grep -n "DesignElement\|DesignScreen\|store\.screens\|store\.floating\|store\.resolve\|selectedLeaves\|addFloating" Layer/Voice Layer/Debug/VoiceDemo.swift` finds nothing.

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run `VoiceOnTheTreeTests`, `CanvasPictureTreeTests`, `VoiceToolsTests`, `VoiceAgentTests`, `VoiceCallTests`, `PencilVoiceTests`, `HostedModelTests` (which holds `HostedToolCallingTests.swift`'s tests, F19), `DictationRouteTests`, `VoiceScreenLayoutTests` and `DeviceReflowTests` (their structs). Apart from the (q) and (r) changes listed, they pass unchanged.
  - That includes the tidy and device lines, scoping, corrections, "gone", the delete naming and the one-step assertions.
  - Then run the full unit suite and the UI suite: `VoiceModeUITests` drive `VoiceDemo` and the toolbox (F20). Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set. `Tools/VoiceBenchmarkHarness/run.sh check` passes, and the gate exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Voice acts on the tree: a laid-out child is reordered or taken out only when asked, looks go to a group's contents or a card itself, and devices are chosen by name"`

---

### Task 8: Four new voice tools: groupElements, setLayout, ungroup and reorder

**Lane:** C (after Task 7)

**Files:**
- Modify:
  - `Layer/Voice/VoiceTools.swift`: four requirements, four `Tool`s, both lists, and the step words "Grouping…", "Changing the layout…", "Ungrouping…" and "Reordering…";
  - `Layer/Voice/VoiceToolbox.swift`: the four implementations;
  - `Layer/Voice/VoiceRules.swift`: the lines below;
  - `Layer/Voice/VoiceProfile.swift`, only if call 10's bar fails;
  - `Tools/VoiceBenchmarkHarness/Harness.swift` and `run.sh`: the recorder's four methods, a nested canned picture, a `structure [runs] [baseline|sampled]` mode, and `check` printing `harness ok: 25 tools, 8 structure cases`;
  - `docs/benchmarks/voice-on-device.md`: a dated section "Structure tools (plan 6)".
- Modify (r): `VoiceAgentTests` (`told.tools.count` 21 → 25 and 20 → 24) and `HostedToolCallingTests.swift` (the tool list, 21 → 25)
- Test: `LayerTests/NewVoiceToolsTests.swift`; `LayerTests/VoiceAgentLiveTests.swift` gets two live cases

**Interfaces:**
- Consumes: Tasks 6 and 7, plan 4's `group(_:as:)`, `canGroup(_:as:)`, `GroupShape` and `TreeEdit.groupedLayout`, plan 2's `setLayout(_:_:)`, `update` and `move`, and plan 5's declining `store.ungroup(_:)`.
- Produces:
  ```swift
  protocol VoiceActing {   // four new requirements
      /// `elements`: handles, comma separated (two or more; one for a card). `shape`: group, row, column, grid or card.
      @MainActor func groupElements(elements: String, as shape: String) -> String
      /// `target`: a container's E handle or a screen's S handle. Nil `layout` keeps the kind; nil `spacing` keeps it.
      @MainActor func setLayout(target: String, layout: String?, spacing: String?) -> String
      @MainActor func ungroup(element: String) -> String
      /// `position`: before or after; above and left of read as before, below and right of as after.
      @MainActor func reorder(element: String, position: String, target: String) -> String
  }
  struct GroupElementsTool: Tool   // name "groupElements"; description "Puts elements in a new group, row, column, grid or card."
  struct SetLayoutTool: Tool       // name "setLayout"; "Changes how a row, column, grid, card, group or screen lays out what it holds."
  struct UngroupTool: Tool         // name "ungroup"; "Takes a row, column, grid, card or group apart, leaving what it held in place."
  struct ReorderTool: Tool         // name "reorder"; "Moves an element before or after another in the row, column, grid or group they share."
  ```
  The guides:
  - `elements`: "The handles, comma separated, such as E3, E4. They must be in the same place."
  - `as`: "group, row, column, grid or card."
  - `target` (setLayout): "A row, column, grid, card or group, such as E5, or a screen, such as S1."
  - `layout`: "free, row, column, grid of 2 (any number), or overlay; may add left, centred, right, top, bottom or stretched. Leave out to keep it."
  - `spacing`: "The gap between the things in it, in points, such as 16. Leave out to keep it."
  - `element` (ungroup): "The row, column, grid, card or group to take apart, such as E5."
  - reorder's three: "The element to move, such as E7.", "before or after." and "The element it goes before or after, such as E6."
- **The lines:**
  - **groupElements:**
    - done: `Put E8 and E9 in a row, E10.` With three, `Put E3, E4 and E5 in a column, E10.` A card of one: `Put E1 in a card, E10.`
    - two parents: `E1 and E3 aren't in the same place, so they can't be grouped.`
    - too few: `Name two or more elements to group.`
    - an unknown shape: `I can group them as a group, row, column, grid or card, not “pile”.`
    - locked: today's `E3 is locked.`
  - **setLayout:**
    - done: `E2 is now a column, spacing 12.`, `E5's spacing is now 24.`, `S1 is now a column, spacing 24.` or `E5 is now free: what it holds stays where it is.`
    - a screen asked for anything but free or column: `A screen can be free or a column, not a row.`
    - a leaf: `E1 is a title, which holds nothing. To put things in a row, call groupElements.`
    - `I didn't understand the spacing.` and `I didn't understand the layout “zigzag”.`
  - **ungroup:**
    - done: `Took E6 and E7 out of E5.`
    - a leaf: `E1 isn't a row, column, grid, card or group.`
  - **reorder:**
    - done: `Moved E7 before E6.`
    - two parents: `E6 and E3 aren't in the same row, column, grid or group.`
    - `Say before or after.` and `E6 can't go before itself.`
- **The rules' new lines:**
  - `VoiceRules.full`, after the handles paragraph: `Elements indented under another are inside it: a row, column, grid or card. groupElements puts elements in a new one; ungroup takes one apart; setLayout changes how one, or a screen, lays out what it holds; reorder changes an element's place among those it shares one with. stackElements only lines elements up and makes nothing new. An element inside a row, column or grid is placed by it: change its place with reorder; moveElement only resizes it unless the person asks to take it out.`
  - `VoiceRules.compact`, as one bullet: `- Indented elements are inside the one above. groupElements makes a row, column, grid or card; ungroup undoes one; reorder changes the order inside one; setLayout changes one's layout or spacing.`

- [ ] **Step 1: Write the failing tests** in `NewVoiceToolsTests` (`@MainActor`, the fixture, plus texts X (20, 400, 100, 24) and Y (140, 400, 100, 24) on the root, told as E8 and E9):
  - `groupingTwoTextsAsARow`: `groupElements(elements: "E8, E9", as: "row")` returns `Put E8 and E9 in a row, E10.` The root's last child is a group with:
    - `.stack(horizontal, spacing 16, alignment .start)`: the 20-pt gap ties 16 and 24, and the smaller wins (plan 4 call 8);
    - children `[X, Y]`, each `.fixed`;
    - `ownFrame(X).origin == (20, 400)`.
  - `aCardCanHoldOne`: `groupElements(elements: "E1", as: "card")` makes a card holding the title.
  - `thingsOfTwoParentsArentGrouped`: `"E1, E3"` returns the two-parents line, and `store.tree` is unchanged.
  - `anUnknownShapeIsRefused`: `as: "pile"` returns the unknown-shape line.
  - `aCardBecomesAColumn`: `setLayout(target: "E2", layout: "column", spacing: "12")`:
    - returns `E2 is now a column, spacing 12.`;
    - gives the card `.stack(vertical, spacing 12)`, holding `[about, body]` in top-to-bottom order, each `.fixed` at its size.
  - `spacingAloneKeepsTheLayout`: `setLayout(target: "E5", layout: nil, spacing: "24")` returns `E5's spacing is now 24.`. The row is still horizontal and centred, and its width is 155 (80 + 24 + 51).
  - `aScreenIsFreeOrAColumn`:
    - `setLayout(target: "S1", layout: "column", spacing: nil)` makes the root a vertical stack, with the rhythm step `groupedLayout` gives.
    - `layout: "row"` returns the screen line, and nothing changes.
  - `gridColumnsComeFromTheWords`: "grid of 3" gives `columns == 3`, "grid 3" the same, and "grid of 20" gives 12.
  - `alignmentWordsAreRead`: "column centred" gives alignment `.center`, and "row stretched" gives `.fill`.
  - `badWordsAreRefused`: spacing "-4" and "lots" give the spacing line, and layout "zigzag" gives the layout line.
  - `aLeafHasNoLayout`: `setLayout(target: "E1", …)` returns the leaf line.
  - `freeKeepsWhereThingsAre`: `setLayout(target: "E5", layout: "free", spacing: nil)` gives the row `layout == nil` (or `.free`), and the label's and toggle's `ownFrame`s are unchanged.
  - `ungroupingARowPutsItsThingsBack`: `ungroup(element: "E5")` returns `Took E6 and E7 out of E5.`. The root holds the label and the toggle in the row's slot, at unchanged `ownFrame`s.
  - `ungroupingATurnedCardKeepsPlaces`: with the card turned 90, each child's canvas centre is unchanged within 0.001.
  - `aLeafCantBeUngrouped`.
  - `voicesUngroupDeclinesAStructureThePassMade`: a row built by `store.build(_:)` (plan 5), ungrouped by voice, leaves its children with `sketch?.structureDeclined == true`.
  - `reorderingInARow`: `reorder(element: "E7", position: "before", target: "E6")` returns `Moved E7 before E6.`, and the row holds `[toggle, label]`.
  - `reorderingAcrossContainersIsRefused`: E6 before E3 returns the two-parents line.
  - `reorderingInAFreeParentChangesOnlyTheOrder`: E1 after E5 changes the root's order. Every `ownFrame` is unchanged.
  - `positionWordsAreTolerated`: "above" and "left of" act as before, and "below" and "right of" act as after. "sideways" returns `Say before or after.`.
  - `theNewToolsKeepToTheScreenInScope`: with the scope S1, `groupElements` naming a node of S2 returns today's other-screen line.
  - `eachNewToolIsOneVoiceCommandStep`:
    - `VoiceAgent` runs a scripted model answering `groupElements(E8, E9, row)`.
    - It makes one undo step named "Voice Command", and one undo restores `store.tree`.
  - `theToolListsGrew`:
    - `VoiceTools.all(box).count == 25`, and `all(box, canEndCall: false).count == 24`.
    - `forEmptyCanvas` is unchanged.
    - The names include `groupElements`, `setLayout`, `ungroup` and `reorder`.

  `VoiceAgentLiveTests` (gated by `TEST_RUNNER_LAYER_LMSTUDIO`, as its others are):
  - `liveGroupsTwoTextsAsARow`: "put the two texts at the bottom in a row" leaves a row of X and Y.
  - `liveReordersInARow`: "move the toggle before the label" leaves the row as `[toggle, label]`.

- [ ] **Step 2: Run them.** Run `NewVoiceToolsTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the tools, the lines, the rules' lines and the harness changes.

- [ ] **Step 4: Measure on this Mac** (call 10).
  - Run `Tools/VoiceBenchmarkHarness/run.sh check`. It prints `harness ok: 25 tools, 8 structure cases`.
  - Run `run.sh structure 5`. The eight cases are:
    - "put these in a column", with two fields selected;
    - "make these a row";
    - "make the card a grid of two";
    - "space the row out more";
    - "ungroup the row";
    - "move the toggle before the label";
    - "take the toggle out of the row";
    - "make the button half width", in a column.
  - Run `run.sh newtools 5`, which holds the older-tool controls.
  - Record in `voice-on-device.md` (F27):
    - each structure case's score;
    - the whole `newtools` table (tidy, change device, new screen, controls), beside 2026-11-21's, since Task 7 reworded two device guides and added `takeOut`;
    - the profile's size for a call with one screen (25 tools) and for the pencil (24);
    - the model's `contextSize`, as the harness prints it.
  - A fall of more than 2 of 25 in the change-device or new-screen rows goes in the hand-off. It isn't acted on here.
  - If the controls score below 13 of 25 "Right" (the last recorded result is 15 of 25), or the profile of a call with one screen is over 3,400 tokens:
    - add `VoiceTools.compact(_:canEndCall:)`, which is every tool but `setLayout` and `reorder`;
    - use it in `VoiceProfile`'s on-device branch;
    - add `theOnDeviceModelIsSparedTwoTools`;
    - measure again, and record both runs.
  - If Apple Intelligence doesn't answer on this Mac, record that and leave the profile as built.
  - If `curl -s http://localhost:1234/v1/models` answers, run `VoiceAgentLiveTests` with `TEST_RUNNER_LAYER_LMSTUDIO=1` and record the result. Otherwise record "LM Studio not running".

- [ ] **Step 5: Run them, and the suites.** Run `NewVoiceToolsTests`, `VoiceOnTheTreeTests`, `VoiceToolsTests`, `VoiceAgentTests` (after the (r) change), `HostedModelTests` (with `HostedToolCallingTests.swift`'s tests), `PencilVoiceTests` and `VoiceCallTests` (their structs). Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set. Remove the voice files from `c.txt`: it is empty. The gate exits 0.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Voice's structure tools: groupElements, setLayout, ungroup and reorder, measured on the on-device model with the older tools as controls"`

---

### Task 9: The model's and the canvas's suites leave the projection

**Lane:** A (after Task 2)

**Files:**
- Modify (q)(s): every test file call 2 gives Task 9, as the ledger's table lists them. That covers `GroupTests`, `DesignTests`, `FlatStoreTests`, `LayerOrderTests`, `ConcurrentEditTests`, `UndoNameTests`, `DrawingTests`, `RotationTests`, `MultiSelectionTests`, the `Canvas*Tests`, `PerformanceFixTests`, `PerformanceTests`, `GroupFinalFixTests` and `StoreOnTheTreeTests`, and any others the table names.
  - `DesignTests`' 9 and `FlatStoreTests`' 3 call sites of plan 5's `addElement(_:from:to:)` wrapper become Task 1's `sketched(_:from:to:)` (F12).
  - `DesignTests`' five `place(…centeredAt:)` tests and `StoreOnTheTreeTests`' one move to the tree verb below, under (q), their assertions kept (F2).
  - The five tests plan 2's clause (h) once loosened keep their exact comparisons, as before 3584470: `==`, `close` at its default, and `within: 0.001`. They are `GroupTests` `aTurnedGroupsBoxIsAtItsAngle`, `aTurnedGroupResizesWithoutShear`, `turningAGroupTurnsItsMembersAboutItsMiddleAndKeepsItsAngle` and `manyTurnsOfAGroupAddUpWithoutDrift`, and `StoreOnTheTreeTests.undoAndRedoGoThroughTheTree`. No `holds` or `alike` helper is ported (F4).
- Modify: every app file the table gives Task 9. Expected among them:
  - `Layer/Canvas/DrawingSync.swift`: `Changes.apply(to: inout TreeContent)`, its caller passing `&content.tree`;
  - `Layer/Document/DrawingInk.swift`: `visibleInk` and `adopt(_:)` on `TreeContent`;
  - `Layer/Canvas/PhoneScreenView.swift`: `ElementView(element:)` deleted if it is still there;
  - `Layer/Canvas/SelectionLayer.swift`: the `CanvasDrags` adapters marked `// PROJECTION: deleted in plan 6` (plan 4 F12, F21) are deleted once their test callers are ported (F26);
  - `Layer/App/AppModel.swift`: the library's drops (`add(_:at:)`) go through `store.place(_:centredAt:)` with `LayerNode.standard` (F2). The four marked accessors stay for Task 11. Task 6's `voiceVocabulary` hunk isn't touched;
  - `Layer/Model/DesignStore+Place.swift` (created): the verb below;
  - `Layer/Model/Groups.swift`: every hit but the `keepGroupsSound` shim, which is Task 11's;
  - any `Layer/Chrome/`, `Layer/Code/`, `Layer/Sketch/` or `Layer/Model/` reader still listed.
- Create: `LayerTests/Support/TreeBuilders+Model.swift`, only for helpers these files need beyond Task 1's
- Modify: `scripts/flat-model-allowlist/a.txt`

**Interfaces:**
- Consumes: Task 1's builders, `sketched(_:from:to:)` and `LayerNode.standard`, and the tree's verbs. Code tests use plan 3's `SwiftUICodeGenerator.code(for:in:settings:)` on a free root of the same leaves. That is what `CodeOfElements` did for them, so their expected code is unchanged.
- Produces (F2):
  ```swift
  extension DesignStore {                                  // Layer/Model/DesignStore+Place.swift
      /// A new node centred on `point` (canvas points), as the library drops it. For a kind that belongs on screens, the
      /// topmost screen holding the point takes it: a free root centred and clamped inside as today, a laid-out root
      /// appended (as Siri's Add Element, call 5). Otherwise the canvas, at `looseScale`. One step. Nil if refused.
      @discardableResult func place(_ node: LayerNode, centredAt point: CGPoint) -> ElementRef?
  }
  ```
  No other new API. Every app signature a lane B or C file calls is kept (F11).

- [ ] **Step 1: Make the gate fail for this task.**
  - Remove this task's files from `a.txt`, leaving only Task 11's, which include the shared files of call 2 (`DesignActions.swift`, `AppModel.swift`, `Groups.swift`).
  - Run `scripts/check-flat-model.sh`. Expected: exit 1, listing exactly those files.

- [ ] **Step 2: Port, a file at a time.**
  - Port each file under (q), retiring under (s) only what tests the projection itself.
  - After each file, run its suites (the Global Constraints' table expands file names into structs). Expected: PASS with the assertions unchanged.
  - Record every change and its clause in the ledger.

- [ ] **Step 3: Move the app files** the table names. `DrawingSync` writes through `inout TreeContent`.
  - The library's drops go through `place(_:centredAt:)`.
  - The marked `CanvasDrags` adapters go.
  - In `AppModel.swift` and `Groups.swift`, `grep -n` for the tier-1 patterns finds only the hits call 2 leaves for Task 11.
  - Run `DrawingTests`, `InkOnTheTreeTests`, `CanvasDragWorkTests`, `DesignTests`, `AssetLibraryTests` and `LibraryOnTheTreeTests`. Expected: PASS.

- [ ] **Step 4: Run everything.**
  - `grep -rni "clause (h)\|framesWithin\|func holds(" LayerTests` finds nothing (F4).
  - `scripts/check-flat-model.sh` exits 0, and `a.txt` lists only Task 11's files.
  - `Tools/SketchBenchmarkHarness/run.sh check` passes, and `Tools/ScreenBenchmarkHarness/run.sh check` too if a file the screen package copies changed (F21).
  - The full unit suite and the UI suite pass: TEST SUCCEEDED, and no UI failure outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "The model's and the canvas's tests build and read the tree, with every assertion kept; ink writes the tree's content directly, and the library drops a node"`

---

### Task 9b: What a generation or an import couldn't fix is said

**Lane:** A (after Task 9; Task 11 waits for it)

Spec §9: generated and imported trees are validated before they are committed; "fixable problems are fixed … the rest are reported in the import sheet or the generation's status". Plan 3 fixes them and reports A2UI's own diagnostics, but never what is still wrong after the fix and the layout, such as a node clipped by the screen (plan 3 F20, F1).

**Files:**
- Modify:
  - `Layer/App/AppModel+A2UI.swift`: `importA2UI` checks each laid-out root;
  - `Layer/Chrome/A2UIImportSheet.swift`: the new groups' titles;
  - `Layer/App/AppModel.swift`: `ScreenGeneration.unfixed`;
  - `Layer/Chrome/GenerateScreenPanel.swift`: `GenerationStatus` says it;
  - `Layer/Sketch/ScreenGenerator.swift`, only if the writer's update must carry the count.
- Test: `LayerTests/UnfixedIssuesTests.swift`

**Interfaces:**
- Consumes: plan 1's `TreeValidator.check(_:on:)`, `fixGenerated` and `LayoutEngine`'s overflow diagnostics; plan 3's `TreeRules.laidOut`, `A2UIImportReport`, `importA2UI(_:near:)`, `ScreenGeneration` and `GenerationStatus`.
- Produces:
  ```swift
  enum UnfixedIssue: String, CaseIterable, Sendable {
      case runsOffTheScreen, overflowsItsContainer, textTooSmall, controlTooSmall
      var title: String { get }    // "Runs off the screen", "Doesn't fit its row, column or grid", "Text too small",
                                   // "Control too small"
      /// What `TreeValidator.check(laidOut, on: device)` and the engine's overflow report for a generated or imported
      /// root after `fixGenerated` and the layout. What was fixed isn't in it.
      static func found(in laidOut: LayerNode, on device: DeviceFrame) -> [UnfixedIssue: [UUID]]
  }
  extension A2UIImportReport { var unfixed: [UnfixedIssue: [UUID]] }   // `needsShowing` is true when it isn't empty
  extension AppModel.ScreenGeneration { var unfixed: Int }             // nodes with an issue, once complete
  ```
  - `GenerationStatus` says "Finished. 1 thing runs off the screen." (or "N things …", one clause per kind present), after plan 3's left-out words when both apply.
  - Nodes the person made are never checked here, and nothing is corrected (§9).

- [ ] **Step 1: Write the failing tests** in `UnfixedIssuesTests` (`@MainActor`):
  - `anImportThatRunsOffTheScreenSaysSo`: an A2UI column whose fixed-width image is 600 wide, imported onto an iPhone, gives a report whose `unfixed[.runsOffTheScreen]` holds the image's id, and `needsShowing` is true.
  - `aGenerationSaysWhatItCouldntFix`: a scripted generation whose root has the same image finishes with `generation?.unfixed == 1`, and the status line is `Finished. 1 thing runs off the screen.`
  - `whatWasFixedIsNotReported`: a generated button fixed at 30 high is raised to 44 by `fixGenerated`, and the report and the status say nothing of it.
  - `aHandMadeScreenIsNeverChecked`: an image dragged half off a hand-made screen is left where it is, and no report or status mentions it.

- [ ] **Step 2: Run them.** Run `UnfixedIssuesTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** The check runs off the main actor on the root `TreeRules.laidOut` already made, so the commit still lays nothing out.

- [ ] **Step 4: Run them, and the suites.**
  - Run `UnfixedIssuesTests`, `A2UIImportFlowTests`, `A2UIGenerationTests`, `GenerationThroughTheReconcilerTests` and `ScreenGenerationTests` (their structs). Expected: PASS. Plan 3's tests pass unchanged: their designs fit their screens.
  - Then run the full unit suite and the UI suite, and `scripts/check-generated-swiftui.sh`. `Tools/ScreenBenchmarkHarness/run.sh check` also passes if `ScreenGenerator.swift` changed. Expected: PASS, TEST SUCCEEDED, no UI failure outside the baseline set, and `N files typecheck`.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "What a generation or an import couldn't fix is said in the import sheet and the generation's status, and a hand-made screen is never checked"`

---

### Task 10: The sketch, generation, code and panel suites leave the projection

**Lane:** B (after Task 5)

**Files:**
- Modify (q)(s): every test file call 2 gives Task 10, as the ledger's table lists them. That covers `FreeformTests`, `SystemSymbolTests`, `ScreenGenerationTests`, `HostedModelTests`, `CorrectedReadingTests`, `SketchReadingTests`, `MagicPenComponentTests`, `FormatPanelTests`, `PanelStepTests`, `LayersPanelTests`, `AssetLibraryTests`, `ComponentCatalogueTests` and `ZoomRulerTests`, and any others the table names.
  - 15 call sites of plan 5's `addElement(_:from:to:)` wrapper become Task 1's `sketched(_:from:to:)`: `CorrectedReadingTests`' 7, `FreeformTests`' 6 and `MagicPenComponentTests`' 2. `CorrectedReadingTests`' 5 `changeKind` sites become `changeKind(of:to:fallback:)`. Frames are read with `ownFrame`. `DesignTests`' 9 and `FlatStoreTests`' 3 are Task 9's (F12).
- Create: `LayerTests/Support/TreeBuilders+Sketch.swift`, only for what these files need beyond Task 1's `sketched(_:from:to:)`
- Modify: `scripts/flat-model-allowlist/b.txt`

**Interfaces:**
- Consumes: Task 1's builders and `sketched(_:from:to:)`, plan 5's `addSketched` and `changeKind(of:to:fallback:adjust:)`, and plan 3's export call.
- Produces: nothing new outside tests.

- [ ] **Step 1: Make the gate fail for this task.** Remove this task's files from `b.txt`, which leaves it empty (`DesignActions.swift` is in `a.txt`, and `LookWordsEverywhereTests` was cleared in Task 5). Run `scripts/check-flat-model.sh`. Expected: exit 1, listing exactly those files.

- [ ] **Step 2: Port, a file at a time**, as Task 9 Step 2 does.
  - The sketch suites keep their exact frames, which shows today's placement is kept. They include `MagicPenComponentTests`' `SketchedLayoutTests`, `CorrectedReadingTests` and `SketchReadingTests`.
  - The code suites keep their exact expected code, which shows a free screen's Structure code is today's.
  - `SketchHintTests` and `ScreenPromptWordingTests` aren't touched.

- [ ] **Step 3: Run everything.**
  - `scripts/check-flat-model.sh` exits 0, with `b.txt` empty.
  - The full unit suite and the UI suite pass: TEST SUCCEEDED, and no UI failure outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.

- [ ] **Step 4: Commit.** `git add -A && git commit -m "The sketch, generation, code and panel tests build and read the tree, with every assertion kept"`

---

### Task 11: The projection, DesignContent's flat API, DesignElement and ElementRef deleted

**Lane:** A (waits for Tasks 1–10 and 9b to be merged)

**Files:**
- Delete:
  - `Layer/Model/Projection/` (all of it, plan 3's `Look+Element.swift` included);
  - `LayerTests/Support/CodeOfElements.swift`;
  - the `TreeProjection*Tests` files.
- Create: `Layer/Tree/NodeRef.swift`
- Modify:
  - `Layer/Document/DesignFile.swift`: `DesignContent` is deleted. `DesignFile.content` and `content(at:)` are `TreeContent`.
  - `Layer/Model/DesignStore.swift` and its extensions:
    - `content` is a `TreeContent`, and `apply`, `restore` and `HistoryStep` take one;
    - the lowered memo, `screens`, `floating`, `element(_:)`, `resolve(_:)` and `update(ref)` are deleted;
    - plan 5's two wrappers are deleted;
    - `place(_:centeredAt:)`, `addFloating(_:from:)`, `addFloating(_:scale:)` and `newElement(_:symbol:)` are deleted (F2).
  - `Layer/Model/Groups.swift`: the `keepGroupsSound` shim is deleted.
  - `Layer/Model/Design.swift`: `DesignElement`, `DesignScreen` and `FloatingElement` are deleted, with their extensions. `ElementKind`, `DeviceFrame`, `CanvasSettings` and the rest stay.
  - `Layer/App/AppModel.swift`: `selectedElement`, `selectedScreen`, `selectedElements` and `selectedLeaves` are deleted.
  - `Layer/Intents/DesignActions.swift`: `TakenAction` holds `TreeContent`. (`frameForNewElement` went in Task 5.) The conversion between the two `Host` enums goes with the rename (F29).
  - every file naming `ElementRef`, for the rename;
  - `Tools/SketchBenchmarkHarness/Stubs.swift`, `Tools/Shared/RotationStub.swift`'s comment, and each harness `run.sh`'s file list: no projection file, and no flat stub.
  - `scripts/check-flat-model.sh`: strict only. `scripts/flat-model-allowlist/` is deleted.
- Modify (s) (F26): every line the strict gate's `\bTreeProjection\b` pattern finds, and the bridge tests and lines of Tasks 1, 3 and 7. That includes:
  - plan 4's `CanvasNeverLowersTests`, `CanvasOnTheTreeTests`, `InkOnTheTreeTests`, `LibraryOnTheTreeTests`, `LayoutDragTests`, `TreeTargetsTests` (`findingTargetsDoesNotLower`), `FormatPanelLayoutTests` (`aScreensFieldsAreWrittenOnTheTree`) and `LayerRowsTests` (`listingDoesNotLower`);
  - plan 5's `StructurePassTests` (`theSuggestionsPlaceIsReadFromTheTree`);
  - plan 2's `StoreOnTheTreeTests` and `CanvasDragWorkTests`.
- Modify (u) (F25): the test lines the rename and the retype change: `ElementRef` → `NodeRef`, `element:` → `node:`, `content.tree` → `content`, and `DesignContent(tree: t)` → `t`.
- Test: `LayerTests/OneModelTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces:
  ```swift
  struct NodeRef: Hashable, Sendable {          // Layer/Tree/NodeRef.swift: what DesignStore.ElementRef was (call 12)
      typealias Host = TreeIndex.Host
      var host: Host
      var node: UUID
  }
  // DesignStore (the same @Observable class):
  //   private(set) var content: TreeContent;  var tree: TreeContent { content }
  //   func apply(_ body: (inout TreeContent) -> Void);  func restore(_ content: TreeContent)
  // DesignFile: var content: TreeContent;  nonisolated static func content(at url: URL) throws -> TreeContent
  // TakenAction: init(name:before: TreeContent, after: TreeContent, model:undoManager:); canTakeBack(from: TreeContent)
  ```

- [ ] **Step 1: Check the start.**
  - `scripts/check-flat-model.sh` exits 0. `b.txt` and `c.txt` are empty, and `a.txt` lists only this task's files, call 2's shared files among them.
  - `grep -rln "PROJECTION: deleted in plan 6" Layer LayerTests` lists only files this task deletes or changes. `SelectionLayer.swift` isn't among them: Task 9 deleted its adapters (F26).

- [ ] **Step 2: Write the failing tests** in `OneModelTests` (`@MainActor`, the fixture):
  - `theStoreHoldsTheTreeItself`: `let held: TreeContent = store.content` compiles, and `held == store.tree`.
  - `aFileReadsAsTheTree`: the fixture saved to a temporary `.layer` gives `let read: TreeContent = try DesignFile.content(at: url)`, which equals `store.tree` (after the rules on read).
  - `aRefNamesANode`: `NodeRef(host: .screen(screen), node: about)` round-trips through `EntityKey.element` and `parseElement`.
  - `siriUndoStillTakesBack`: a `MoveElementIntent.move` with a system undo manager, then `TakenAction.takeBack()`, gives `store.tree` as before.
  - `undoAndRedoStillGoThroughTheTree`: a group turned 30 and moved 10 right undoes and redoes to frames within 1e-6, as plan 2's `undoAndRedoGoThroughTheTree` does.

- [ ] **Step 3: Run them.** Run `OneModelTests`. Expected: FAIL (it doesn't compile: `content` is a `DesignContent`, and there is no `NodeRef`).

- [ ] **Step 4: Delete and retype, in this order, building after each.**
  1. Delete AppModel's four accessors.
  2. Delete the store's projection members, the plan-5 wrappers, `place(_:centeredAt:)`, both `addFloating`s and `newElement` (F2).
  3. Make `content` a `TreeContent`, with `apply`, `restore`, `HistoryStep` and `TakenAction` on it. `content.tree` becomes `content` everywhere.
  4. Delete `DesignContent`, the shim, `pendingPointers`, `Layer/Model/Projection/` and `CodeOfElements.swift`.
  5. Delete `DesignElement`, `DesignScreen` and `FloatingElement`.
  6. Rename `ElementRef` to `NodeRef` (F25):
     - macOS `sed` has no `\b`, and `sed -E 's/\bElementRef\b/…/'` changes nothing. Use `perl -pi -e 's/\bDesignStore\.ElementRef\b/NodeRef/g; s/\bElementRef\b/NodeRef/g'` over the files the gate's tier 2 lists, or `sed -E` with `[[:<:]]ElementRef[[:>:]]`;
     - rename the stored property `element` to `node`, and fix each build error the compiler lists;
     - never substitute `.element`: it is also `CanvasSelection.element(_:)`'s case, which keeps its name;
     - `NodeRef(host: …, element: …)` labels become `node:`.
     - Test lines that change only by these names are recorded under (u).
  7. Fix the harness stubs and file lists.
  8. Delete the comments that name a deleted type.
  9. Retire the (s) tests and lines, and record each in the ledger.
  10. Make the script strict only, and delete the allowlists.

- [ ] **Step 5: Run them, and verify.**
  - `OneModelTests` passes.
  - `scripts/check-flat-model.sh` prints `flat model: 0 references in 0 files` and exits 0.
  - `grep -rn "DesignElement\|DesignScreen\|FloatingElement\|DesignContent\|ElementRef\|TreeProjection\|keptTargets\|SiblingLists\|centeredAt:\|addFloating\|newElement(" Layer LayerTests LayerUITests Tools` finds nothing, except `centeredAt:` in `AppModel.addFrame` and `addTemplate`, which are tree code.
  - `grep -rni "clause (h)\|framesWithin\|func holds(" LayerTests` finds nothing (F4).
  - These print their ok lines and exit 0: `Tools/SketchBenchmarkHarness/run.sh check`, `Tools/ScreenBenchmarkHarness/run.sh check`, and `Tools/VoiceBenchmarkHarness/run.sh check` (25 tools).
  - The full unit suite and the UI suite pass: TEST SUCCEEDED, and no UI failure outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "One model: the projection, DesignContent's flat API, DesignElement, DesignScreen and FloatingElement deleted, the store holds TreeContent, and ElementRef is NodeRef"`

---

### Task 12: Measured after, and the plan's finish

**Lane:** A (after Task 11)

**Files:**
- Modify: `docs/benchmarks/semantic-tree.md` (the "After plan 6" column, a "Budgets" table of met and missed, and the hosted decision), `docs/benchmarks/screen-prompt.md` (a dated "Hosted formats (plan 6)" section)
- Modify, only if the decision flips:
  - `Layer/Sketch/ScreenGenerator.swift`: `hostedFormat = .outline`;
  - (t): `A2UIGenerationTests.hostedModelsWriteA2UIAndTheDeviceTheOutline`'s expected format, and the stubbed answers in `HostedModelTests`' two ported tests.

**Interfaces:**
- Consumes: Task 2's script and harness mode, every budget test, and plan 2 Task 1's baseline and the simulator it names.
- Produces: the measurements, the decision, the hand-off, and nothing in the app unless the decision flips.

- [ ] **Step 1: Prepare a quiet machine (F5).**
  - No other lane, `xcodebuild`, LM Studio download or indexing is running.
  - The 1-minute load average (`sysctl -n vm.loadavg`) is under 20 before each timed run. The script prints it and refuses at 20 or more. Record each in the ledger.
  - `curl -s http://localhost:1234/v1/models` lists `google/gemma-4-26b-a4b` (plan 3's model). If it doesn't, stop and ask the controller to start LM Studio. No decision is recorded without a run.

- [ ] **Step 2: Choose the simulator** (call 13).
  - Use "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47), the baseline's, named under the doc's table.
  - Only if it is gone, clone `Layer iPad Pro 11 (st6-bench)` from `iPad Pro 11-inch (M5)` on the runtime the doc names, and record its UDID and runtime. Then measure main again in it: make a temporary worktree at the baseline hash and run `scripts/measure-semantic-tree.sh --main <worktree> --simulator "Layer iPad Pro 11 (st6-bench)"`. Record that as "Before (same simulator)" beside plan 2's "Before".
  - The workout's Release build happens in the script's temporary worktree, with `LayerTests` taken out of the scheme and the `Layer` test plan, never in committed files. The app is uninstalled first, and the median of 3 runs of 5 iterations is reported, as the baseline was.

- [ ] **Step 3: Measure the branch.** Run `scripts/measure-semantic-tree.sh --simulator <that simulator>`. It must print `measure ok`. Fill the "After plan 6" column, row by row:
  - **Reading after the pen rests:** `BENCH sketch reading` (the rules' reading, the landing and the pass) and `BENCH structure pass` p50 and p95, with `BENCH sketch accuracy` beside them. The budget is p95 under 100 ms (F22).
  - **Layout of one edit on a 100-node screen:** `BENCH store` and `BENCH tree` p50 and p95 for move, resize, text and add, and `BENCH rules edit`. The budget is p95 under 16 ms.
  - **A drag frame:** the `BENCH drag` and `BENCH node views` counters. The budget is plan 2's numbers or better: a line drag writes 60, and a group drag 60.
  - **Streaming generation:** `GenerationThroughTheReconcilerTests` passing, which means 100% stable, one commit per update, and no main-actor layout.
  - **Canvas workout:** CPU, memory and clock, each with its RSD and its change from the same-simulator "Before". The budget is no worse by more than 5%.

  Mark each row met or missed in the Budgets table. A miss is recorded and not fixed here (call 13), but `StoreChangeBudgetTests` and `SketchConversionBudgetTests` must still pass.

- [ ] **Step 4: Measure generation, and decide the hosted format.**
  - `Tools/ScreenBenchmarkHarness/run.sh outline 3` is the on-device outline. Record first content and completion p50 and p95, and output tokens where known.
  - `run.sh hosted google/gemma-4-26b-a4b both 3` is 24 screens of each format, interleaved. Record both summaries and the harness's `hosted default:` line.
  - If the line says `a2ui`, nothing changes.
  - If it says `outline`:
    - set `hostedFormat = .outline`;
    - change the (t) tests;
    - run `A2UIGenerationTests`, `HostedModelTests` and `ScreenGenerationTests`, then the full unit suite. Expected: PASS.
  - Record the rule, the numbers and the decision in both docs.

- [ ] **Step 5: Check the sketch corpus.**
  - `Tools/SketchBenchmarkHarness/run.sh run LayerTests/Fixtures` reports 87.8% (137/156), and `run.sh structure LayerTests/Fixtures` reports its plan-5 line.
  - If Apple Intelligence answers on this Mac, `run.sh run LayerTests/Fixtures --model` reports 89.1% (139/156). Otherwise record that it didn't.

- [ ] **Step 6: Verify the plan's end state.**
  - The full unit suite passes, and the UI suite fails nothing outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.
  - `scripts/check-flat-model.sh` prints `flat model: 0 references in 0 files`.
  - The earlier plans' deletion greps still find nothing, since the merge is where Goal 1 is judged (F6): `grep -rn "ScreenBlueprint\|writeGenerated\|ScreenTidy\|sketchedElement" Layer LayerTests Tools`.
  - `grep -rni "clause (h)\|framesWithin\|func holds(" LayerTests` finds nothing (F4).
  - The three harnesses' `check` modes pass.
  - `git status --porcelain` is empty after the commit.

- [ ] **Step 7: Commit.** `git add -A && git commit -m "Benchmarks after the semantic tree: every §13 row against main in the same simulator, budgets met and missed, and the hosted format decided on LM Studio"`

- [ ] **Step 8: Clean up.**
  - Delete the lane B and lane C worktrees and branches, which are merged, with their simulators (`xcrun simctl delete "Layer iPad Pro 11 (st6-lane-b)"` and `"Layer iPad Pro 11 (st6-lane-c)"`) and their DerivedData.
  - Delete the temporary main worktree and its DerivedData, `/tmp/VoiceBenchmarkHarness`, `/tmp/SketchBenchmarkHarness`, and `Tools/ScreenBenchmarkHarness/.build`.
  - Keep `Layer iPad Pro 11 (semantic-tree)`, the bench simulator ("Layer iPad Pro 11 (st2-lane-c)", or the clone) and their DerivedData for the sweep. The hand-off says so.

- [ ] **Step 9: Write the hand-off** as the ledger's last entry, and include it in the final report. Don't merge or push. It holds:
  - the branch head, the unit and UI test counts, and any baseline UI failures;
  - **the sweep's starting list:**
    - every missed budget first, largest miss first;
    - then the three slowest `BENCH` p95s within budget;
    - the instruction: "re-run `scripts/measure-semantic-tree.sh` after each change, in the bench simulator ("Layer iPad Pro 11 (st2-lane-c)", or the clone), at a 1-minute load under 20". The script needs no edits to be re-run, and changes no committed file (F5);
  - the hosted decision, the on-device tool profile (all 25 of a call, or compact), the measured `contextSize`, any fall in the voice device or new-screen rows (F27), and whether Apple Intelligence and LM Studio answered;
  - **open items for the user:**
    - telling a hosted model a screen as A2UI is not built (call 11, recorded in spec §6);
    - a better A2UI prompt, if the numbers suggest one (call 14);
    - Xcode Cloud's `-skipPackagePluginValidation` (spec Constraints);
    - iCloud still unverified off-device;
  - **the controller's next steps, not run here:**
    1. the performance sweep, on this branch;
    2. the merge, from the primary worktree (`/Users/angks/projects/personal/Layer`, where main is checked out; this worktree can't check main out): `git merge --no-ff feature/semantic-tree`, then the full suites on main, before any install (F6);
    3. a build-number bump before installing (the last was 0.2.0 (5));
    4. `git push`, which the user has authorised;
    5. installing on the iPad, then the checklist below;
    6. deleting the bench simulator, the semantic-tree simulator and their DerivedData after the sweep.

---

## The iPad device checklist

For the user, after the merge and an install on the iPad (`devicectl`, as in the device-install notes). Each line says what to do and what should happen. Anything else is a bug: note it with the time, so the session log and crash reports can be fetched.

0. **Before installing:** this build can't open designs saved by the one on the iPad now (My call 14). Open each design you want to keep in the current build, and share it as an image or as code.
1. **The old-file message.** In Files, tap a design saved by the previous build. Layer shows exactly *This design was made by an earlier version of Layer and can't be opened by this one.*, and nothing else opens. Searching Spotlight for that design's name doesn't list it.
2. **Pencil latency while sketching rows.**
   - On a new phone screen, quickly draw three small boxes side by side, then a 2 × 2 grid of image boxes one cell at a time with short pauses.
   - Ink keeps up with the Pencil with no visible lag. Each reading appears about a second after the pen rests.
   - The three boxes become a row, and the grid becomes one grid, not two rows.
   - Layers lists "Row" and "Grid".
3. **"Make a row?"** Draw three texts in a ragged line. The pill offers "Make a row?". Tap ✕, then draw near them again: it isn't offered for them again. Accepting an offer elsewhere is one Undo.
4. **A card drawn round things.** Write two lines of text, then draw a big rounded box round both. They become a card holding them, where they were.
5. **Drag-reorder in a row**, with a finger.
   - Drag a row's middle thing past its neighbour: an insertion line shows, and the drop reorders.
   - Drag one out of the row: it lands where you let go.
   - On a column screen, drag a thing between two others: it joins there.
6. **A turned container.**
   - Turn a card 30° with the knob: its contents turn with it.
   - Move one thing inside it: it moves where your finger goes.
   - Ungroup it: nothing moves on screen.
7. **Group as.** Select two things, hold Group, and choose Card, then Grid: each is made where the things were, and is one Undo.
8. **A device change, custom frames included.**
   - In Format's device picker, choose Custom Size…, then 300 × 500, then Save. The screen becomes 300 × 500.
   - Choose Save as Device… on a screen, then pick that device for another screen.
   - Change a sketched phone screen to a tablet: things drawn at the left stay left, at the right stay right, centred stay centred, and full-width ones stretch. Change it back: everything returns.
9. **Siri and Shortcuts.**
   - Run Change Screen Device with Custom Device set to your saved device's name. The screen changes, and Undo in Layer undoes it.
   - Run Get Design Layout on a design with a card. The JSON lists `containers`, and the card's texts have its id as `parent`.
   - Run Move or Resize Element on a thing in a row with X and Y. It comes out of the row there.
   - Run Build Screen with `title: Hi` / `card:` / `  text: A` / `button: Go`. A screen with a card appears.
10. **Voice** (Squeeze to Talk, and the voice call).
    - Select two texts and say "put these in a row". Say "make the card a column", "move the toggle before the label", "ungroup the row" and "make this screen a <your device name>".
    - Each happens, and each is one Undo.
    - Squeezing at a card names the card in the pill.
    - After the session, fetch crash reports. None should be from the audio callback.
11. **A2UI from Files**, and paste.
    - Import A2UI… from the add menu, and pick one of the official example `.json` files (copied to iCloud Drive). A screen appears, with a sheet of anything it couldn't bring in.
    - Paste the same JSON on the canvas. Another screen appears.
12. **Token editing.** In canvas settings, set the title size to 34 and the card radius to 24. Every card and title redraws at once. Reset brings them back.
13. **Generation.** With a hosted model chosen, generate "a profile screen". It streams in as a column with a card and one primary button. A long title wraps inside the screen.
14. **The code.** On the sketched card-and-grid screen, open Code. It shows `Grid(` and `.background(.background.secondary`, and Share › SwiftUI Code gives the same.

---

## Self-review against the spec

- **§11, Siri:**
  - the `design|host|uuid` ids, and leaves only (Task 3);
  - Get Design Layout's tree, with children, layout, sizing and rotation, frames in screen points for screen nodes and canvas points for canvas nodes, and every key kept (Task 4, calls 3 and 4);
  - Build Screen through the reconciler (plan 3; custom devices in Task 5);
  - Add and Move in screen points through the index, and Move on a laid-out child following the drag rule (Task 5, call 5).
- **§11, voice:**
  - the picture in reading order, indented by nesting, with container handles and layout in words (Task 6);
  - `groupElements`, `setLayout`, `ungroup` and `reorder` (Task 8);
  - `moveElement`'s line on a laid-out child (Task 7, call 8);
  - `tidyScreen` (plan 5, unchanged lines checked in Task 7);
  - `changeScreenDevice` through placement intents (plan 5) and custom names (Task 7);
  - typed edits, Squeeze to Talk, corrections and scoping unchanged (Tasks 6–8, `aScopedEditKeepsToItsScreen`, `theNewToolsKeepToTheScreenInScope`).
- **§9:** what a generation or an import couldn't fix is reported in the import sheet and the generation's status, and a hand-made screen is never checked (Task 9b; plan 3 F20).
- **§10 and My call 15:** Siri's Arrange still works in an overlay, and Align applies only in free parents (Task 5, F14).
- **§13:** every row is measured against the baseline in the same simulator, "Layer iPad Pro 11 (st2-lane-c)", at a load under 20, with the workout in Release built in a temporary worktree (Tasks 2 and 12, call 13). The hosted default is chosen by My call 8's rule (Task 12; plan 3 call 8, My call 17).
- **§14:** Siri's (Task 5) and voice's (Task 7) device choices include custom frames by name, and the picture tells the design's own devices (Task 6).
- **My call 9:** Siri sees leaves; Get Design Layout shows the tree (Tasks 3 and 4).
- **My call 19:** green means no UI failure outside plan 1's baseline set, in every task.
- **Anti-goals:**
  - The flat list doesn't survive: the strict gate in Task 11, and the grep the user asked for.
  - No feature quietly stops working: every key Shortcuts read is kept (`todaysKeysKeepTheirValues`), and the on-device voice budget is measured (call 10).
  - Nothing moves unasked: a laid-out child under voice moves only with `takeOut`, and under Siri only by the drag rule.
- **Edge cases:**
  - Siri Move inside a turned container lands where asked (`aMoveInsideATurnedCardLandsWhereAsked`).
  - Old files in Files and Spotlight: plan 2 owns the code; checklist item 1 checks it on the iPad.
- **Verification:**
  - Siri and voice suites ported with their assertions (Tasks 3–8);
  - the benchmarks before and after (Task 12);
  - the iPad checklist (above). It covers Pencil latency sketching rows, drag-reorder in a row, a turned container, device change with custom frames, A2UI import from Files, the old-file message and token editing, plus the checks plans 3–5 left for it.
- **"How the work is split", item 6:** Siri and voice on the tree with the new tools (Tasks 3–8); the projection and `DesignElement` deleted (Tasks 9–11); the benchmarks, the report and the checklist (Task 12).
- **Not in this plan:**
  - telling a hosted model a screen as A2UI (call 11, recorded in spec §6), and rewording either generation prompt (call 14), both flagged in the hand-off;
  - fixing a missed budget, which is the sweep's (call 13);
  - the merge to main and the push, which are the controller's, from the primary worktree, after the sweep.

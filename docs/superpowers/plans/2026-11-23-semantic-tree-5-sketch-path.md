# Semantic tree, plan 5 of 6: the sketch path. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Pencil's readings land in the tree as nodes that remember their sketch, and find the structure the person drew. After this plan:
- every reading becomes a node in the deepest visible, unlocked container under its sketch's centre, with a saved `SketchIntent` (original and normalised bounds, confidence, who decided, placement intent);
- an outline drawn round two or more things reads as a card holding them;
- after each batch of readings settles, a **structure pass** builds rows, columns, grids and a card's column when it is sure and nothing moves more than 8 pt, offers "Make a row?" when it isn't, and never touches what it mustn't;
- "Did you mean" re-lays the node out from its saved bounds;
- a device change follows each node's placement intent on a free screen and re-lays a column screen, from the panel, Siri and voice alike;
- voice's "tidy up" is the structure pass, and `ScreenTidy` is deleted;
- the first milestone works from a sketch: a card round two texts and a two-column grid become the tree at once, and export as SwiftUI with `Grid` and the card's background.

**Architecture:** The cascade is unchanged up to the reading; only the card reading is added to the rules. Pure pieces live in `Layer/Tree/`: `StructureConventions`, placement intents, `SketchLanding`, `StructureInference` and `DeviceReflow`. `Layer/Sketch/SketchedNode.swift` turns a reading into a node, shared by the store and the macOS harness. The store commits through plan 2's `reconcile(_:_:)` (one change, one rules pass) in `DesignStore+Sketch`, `+Structure`, `+Device` and `+Tidy`. `AppModel+Structure` keeps the batch, runs the pass and holds the offer. The sketch path reads the tree, not the projection, except two old entry points kept as marked wrappers.

**Tech Stack:** Swift 6 (strict concurrency), `@Observable`, PencilKit (ink only), Foundation Models (the cascade's escalation, unchanged), Core Text, Swift Testing, XCUITest, XcodeGen, `swiftc` (the sketch harness).

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read Intent (Pencil latency first; drawn geometry is an instruction), Goal 4, the Anti-goals, §5 (all of it), §14 (the rhythm comes from the design's tokens), My calls 6, 7, 15 and 16, the Edge cases, Verification (the structure tests, the first milestone), the Performance table's first row, and "How the work is split" item 5. Plans 1–3 (`docs/superpowers/plans/2026-11-23-semantic-tree-1-foundations.md`, `…-2-store-cutover.md`, `…-3-structured-generation.md`) are the source of every tree, store, reconciler and export name used here.

**Starts when:** plan 4 is complete and merged into `feature/semantic-tree`; the "After plan 4" column of `docs/benchmarks/semantic-tree.md` is filled; `scripts/check-generated-swiftui.sh` and `Tools/ScreenBenchmarkHarness/run.sh check` pass on the branch.

## Pre-flight amendments 2026-11-23

The pre-flight scan is in `.superpowers/sdd/2026-11-23-semantic-tree-5-sketch-path/preflight.md`. The controller accepted every ruling, and each is written into the tasks below.

- **F1.** Task 5 keeps `sketchedElement` for today's `changeKind`. Task 7 deletes it when `changeKind` becomes the wrapper.
- **F2.** A sketched card (a reading, or Did you mean) has `style.tint == nil`, so it draws and exports the design's card fill, and it has no placeholder text.
- **F3.** Plan 4's `setDevice(of:to:)` and the screen part of `addCustomDevice(_:forScreen:)` call `changeDevice`. `updateCustomDevice(_:)` reflows its free screens by intent in the same step. `changeDevice` writes through `updateTreeScreen` and lives in plan 4's `DesignStore+Devices.swift`.
- **F4.** A move out of a container the pass made is declined by one check in the store's change pipeline, written outside the step. `ungroup` keeps its own decline. Tests go through `move`, `moveLayer` and plan 4's lift dropped free.
- **F5.** A structure never holds one of its own shape: a row never takes a row, a column never takes a column, and a grid takes only leaves and cards.
- **F6.** `aRaggedRowIsOfferedNotBuilt` uses 100 × 24 texts, and the accepted row's spacing is 16.
- **F7.** No test reads a global counter. `neighbourhoodSizes(of:)` is kept per receiving container, and layout counts use `LayoutEngine.timesLaidOut(id)`.
- **F8.** `-only-testing` takes struct names (the table in the Global Constraints). A run of 0 tests fails, and each new suite is one struct named as its file.
- **F9.** The landing, a card's take and the pass stay within depth 32. At 5,000 nodes `addSketched` returns nil, and `convert` treats the strokes as unread.
- **F10.** "As it made it" (call 2) is the container's whole value, children included, as it was after `build`. `TreeReconciler.Record` stays the reconciler's.
- **F11.** The person's group in Task 9 holds two things, and drawings stay in Task 1's test. Task 6's locked image sits below the login's image.
- **F12.** Task 11 converts batch 1's two waves as two batches, so their order is fixed.
- **F13.** Task 11's UI test must pass. If simulated touches can't make the readings, it calls `XCTSkip` with the reason, which the ledger records.
- **F14.** Task 12's marker set is plan 4's end-state set plus `DesignStore.swift`, which holds the two sketch wrappers, `addFloating` and `place(_:centeredAt:)`.
- **F15.** Task 9 moves the suggestion's `place(of:)` onto the tree. `place(_:centeredAt:)` and `addFloating` stay marked, and Task 12 records them for plan 6.
- **F16.** The fallout policy carries plan 4's (i)–(l). Plan 5's new clauses are (o) and (p).
- **F17.** `CardReadingTests` asserts against `SketchConventions`' card constants. Task 8's tuning changes only the constants.
- **F18.** Task 8 lists its 32 fixtures by count per variant.
- **F19.** Recorded timings run on a quiet machine in "Layer iPad Pro 11 (st2-lane-c)". The always-on budget test measures up to three times.
- **F20.** A column takes leading on a tie; a row takes centres.
- **F21.** Call 8's placement reading is recorded in spec §5.
- **F22.** Before a task that waits on another lane's task, its lane merges `feature/semantic-tree` into its branch.
- **F23.** Task 7 runs the UI suite.
- **F24.** `printsTheStructureReport` asserts the counts it prints.
- **F25.** `SketchLanding` takes a laid-out parent's slot from plan 4's `TreeDrop.slot`.
- **F26.** The sketch harness gets `TurnedRect`, `Rotation.rotate` and `DesignElement.shapeBounds` the way plan 3's screen package does, or from the shared stub, copied unchanged.
- **F27.** The `addElement` wrapper passes confidence 1 and `.rules`.

## Depends on plan 4

Plan 5 uses plan 2's store verbs (`reconcile`, `replaceChildren`, `add`, `move`, `update`, `parent(of:)`, `index`, `tree`, `device(of:)`) and none of plan 4's UI, except at four call sites. Assumed:

1. **The device picker** is plan 4's `DevicePicker`, which writes through `DesignStore.setDevice(of:to:)` (nil is the iPhone). Plan 4 also changes a screen's device through `addCustomDevice(_:forScreen:)`, and resizes every screen on a custom frame through `updateCustomDevice(_:)`, which plan 4's F16 allows while screens use it. Task 4 makes `setDevice` and the screen part of `addCustomDevice` call `store.changeDevice(of:to:)`, and makes `updateCustomDevice` reflow each free screen on the device by intent, in the same step (F3). `MagicPenTab`'s New Screens picker sets the default for new screens, and isn't a device change.
2. **Moves and Ungroup.** A node leaves a container through plan 2's `move(_:to:at:)` (plan 4's drops and `place`), `moveLayer(_:to:before:)` (the Layers panel), `position` (several things dragged), or the projection's My call 20 take-out (Siri and voice until plan 6). So Task 9 declines a move out of a container the pass made in one check in the store's change pipeline, which every path passes (call 11, F4). The popover's Ungroup reaches `DesignStore.ungroup(_:)` in `Groups.swift`, which declines on its own; plan 6's voice `ungroup` relies on it.
3. **The selection and its rect:** `AppModel.selection` has one case for a single node, and `AppModel.viewRect(of:)` answers for it. This plan writes that case as `.element(ref)`; use plan 4's spelling. The structure pill computes its own rect from `TreeIndex.canvasShape(of:in:)` and the viewport.
4. **The Layers panel** lists a container under its kind's or layout's name ("Card", "Grid"), as plan 4's F7 has it. The milestone UI test (Task 11) looks for those labels.
5. **What plan 4 leaves on the projection for plan 5** (its Task 12 Step 4), and where each goes (F15):
   - `AppModel.convert`: Task 5 moves it to the tree;
   - the suggestion's `place(of:)`: Task 9 moves it to the tree;
   - `DesignStore.addElement` and `changeKind`: Tasks 5 and 7 make them marked wrappers;
   - `addFloating` and `place(_:centeredAt:)` (library drops): they stay, marked, and Task 12 records them for plan 6;
   - `ScreenTidy`: Task 10 deletes it.
6. **The projection-marker set** is plan 4's end-state set, as its Task 12 and its F21 leave it (with `SelectionLayer.swift` and `PhoneScreenView.swift`). Task 12 adds `DesignStore.swift` to it (F14).

## Calls made in this plan

1. **The pass runs once a batch settles, inside the last conversion's step.** A batch is the readings in flight together. When a conversion commits and no other group is in flight, the pass runs over the batch's nodes inside that conversion's edit, so an automatic structure undoes with it. If that last sketch made nothing, the pass's changes are a step of their own.
   - Why: §5 says "after a conversion batch settles" and "it joins the conversion's undo step". Each reading stays its own step, as today.
2. **Every structure holds a new node, and the structures the pass made can grow.**
   - A container the pass made in this session, still as it made it, is read as its members. "As it made it" means its whole value (`LayerNode ==`, its children included) is still the one recorded after `build` (F10). Plan 3's `TreeReconciler.Record` isn't used here: it leaves out `children`, and leaves out the frame of a container sized to fit, which every container the pass makes is.
   - A candidate that holds any of those members must hold all of them, plus a new node, and be bigger: more members, or a grid over a row or column. It replaces the old container.
   - The record lives in memory only, so after reopening nothing grows.
   - Why: a grid drawn a cell at a time with pauses arrives in four batches, and without growing it would end as two rows. Supersets only, so the pass never breaks up what it made, and any edit by the person stops it growing.
3. **The order of inference:** a new card's inside, then grids, then rows, then columns, in which a row just built counts as one item. That gives one level of nesting per run (a column holding a row). Candidates are taken greedily by member count, then confidence, then reading order, and applied inner first.
   - A structure never holds one of its own shape: a row never takes a row, a column never takes a column, and a grid takes only leaves and cards. A column may hold rows and grids (F5). A container the pass made that can't grow is therefore left alone by a structure of its shape.
   - Why: the hierarchy appears at once for the common form (a label and a toggle in a row, inside a column); a grid is never split into rows; the result is deterministic.
4. **Confidence** is the product of three factors (§5): alignment, gaps and sizes. Each is `clamp(1 − error / (2 × limit), 0.5, 1)`, with the spec's tolerance as the limit.
   - Rows compare heights, columns compare widths, and grids compare both.
   - Gap regularity is measured per axis.
   - Why: a candidate at the edge of every tolerance scores 0.125, so nothing happens. A perfect one scores 1.
5. **Proposals are laid out by the engine.** The pass builds the proposed container with members `.fixed` at their sizes (My call 16), lays it out with `LayoutEngine`, and measures how far each member moves. The container's origin keeps the shared line or edge at its median. `StructureInference.applying` builds it, and the store commits that through `reconcile`, so the container keeps its proposed id and a column can name a row proposed just before it.
   - Why: movement is measured on exactly what will be drawn, and one pure function builds what both the automatic path and an accepted offer apply.
6. **The card reading** is rules only:
   - Two or more things already on the screen, each at least 90% inside a big outline: card scores 0.95 and the outline's other readings are halved.
   - One thing inside: card scores 0.6, and the others are unchanged.
   - Nothing inside: nothing changes.
   - The card is `.fixed` at the drawn box (whole points, grown to hold what it takes), free, and padded by the design's card padding. It takes the arrangeable siblings at least 90% inside only when it lands in a free container.
   - The card has `style.tint` nil, so it draws and exports the design's card fill, and it has no placeholder text (F2). The accent other sketched kinds take would be its fill.
   - Why: two or more things inside make a container the likely meaning; one is as likely a button round its label. No corpus fixture has anything inside its outline, so no corpus reading can change. A card drawn in a row takes nothing, since taking a member out of a row is the person's choice.
7. **Where a sketch lands** (§5, Edge cases):
   - The topmost screen under the sketch's centre, then the deepest container there whose turned shape holds the centre. A locked or hidden one hands it to its nearest unlocked, visible ancestor.
   - A card's sketch skips containers it encloses: they become its children, not its parent.
   - In a free container, `ElementLayout.sketched` places it. On the root it is given the screen's device. In a nested container it works in that container's own space, with a stand-in `DeviceFrame.custom` of the container's size.
   - In a row, column or grid, it takes the slot nearest its centre (by x, by y, or in reading order), which plan 4's `TreeDrop.slot(for:among:skipping:layout:)` gives (F25). It is sized like the nearest sibling of its kind, else by the kind's natural sizing.
   - It lands in the deepest container whose child stays within depth 32, and a card takes no sibling whose subtree would pass it (F9).
   - Why: the stand-in keeps today's rules (two columns, centring, leading text) meaningful inside a card, and matching a sibling keeps a grid's cells alike.
8. **Placement intents** are classified from the drawn box in screen points. The first match wins:
   - proportional: it spans at least 90% of the *content* width, which is the screen's width less its margin token on each side;
   - centred: its centre is within 6% of the screen's width of the middle;
   - leading: it starts before the margin plus 15% of the content width (`ElementLayout`'s "drawn leading" rule, with the device's margin token where `ElementLayout` uses a fixed 20);
   - trailing: it ends past the mirror of that;
   - fixed: none of these.

   Canvas nodes get normalised bounds of zero and `.fixed`. Spec §5 records this reading of its placement list (F21).
   - Why: a button drawn across a phone between its margins spans 84–100% of the content but only 76–90% of the screen. Measured against the screen, almost nothing would be proportional.
9. **Device changes:**
   - Only a free root's direct children move, and containers carry their insides.
   - Locked children stay.
   - A node with no saved intent is classified from its frame at the change.
   - y is kept, and a node that isn't fixed is clamped inside the new screen by its turned shape.
   - A centred node keeps its offset from the middle.
   - Turned nodes, and containers sized to fit, keep their size. Proportional moves a turned node's centre instead.
   - Frames are whole points.
   - Why: §5. Classifying unsketched nodes keeps a placed, centred button centred. Resizing a turned or fitting node would fight its turn or the engine (today's `aTurnedElementKeepsItsAngleAndSizeOnANewDevice` pins the size).
10. **Tidy** is the pass in tidy mode, over the screen's free root and its sketched free cards:
    - every arrangeable child counts as new;
    - every container the pass made can grow;
    - the bar is 0.5, and there is no 8 pt limit;
    - a column's gaps needn't be regular, and its gap factor is left out.
    - Why: the person asked ("tidy up", "space things out"), and evening out gaps is what they ask for. With the sketch's bar a typical screen has nothing that qualifies, so an existing feature would quietly stop working (anti-goal).
11. **Declines:** three things mark `structureDeclined`: ✕ on the offer, Ungroup of a container the pass made, and moving a node out of one to another parent.
    - Moving out is caught by one check in the store's change pipeline, whichever verb moved it (F4). After a change that isn't an undo or a redo, each node whose parent before the change was a container the pass made (`sketch?.decidedBy == .structure`), that container still existing, and whose parent now differs, is declined. A container that is gone (grown into another, undone, ungrouped) declines nothing this way. `ungroup` declines on its own.
    - A node with no intent gets one that carries the mark: its frame as its bounds, `decidedBy .structure`, its placement classified.
    - A decline is written without an undo step, as a suggested title is (`setTitle(undoable: false)`).
    - Why: §5, "the pass never fights the user". An undo step that only un-declined would be an Undo that seems to do nothing.
12. **One pill at a time.**
    - "Did you mean" shows first. A structure offer waits for it, and its 8 seconds start when it shows.
    - An offer goes when a member is deleted, moved, resized, turned or reparented, or its screen moves.
    - Accepting builds it with the rhythm's spacing, as a step of its own named "Make Row", "Make Column" or "Make Grid".
    - Why: two pills over one sketch would cover each other, and what a thing is comes before how it is grouped.
13. **"Did you mean"** re-lays the node out in its current parent from `sketch.originalBounds`, and its intent then says `.asked` with confidence 1.
    - `KindSuggestion` keeps its fields. Its `sketch` is only a fallback for a node with no intent.
    - A card that becomes a leaf gives back what it held, where it was. A leaf that becomes a card takes what its bounds enclose.
    - Why: §5. Keeping the struct keeps today's `CorrectedReadingTests` unchanged.
14. **Turned nodes are left out of structures.**
    - Why: rows and columns line up frames, and a turned node's frame isn't what is seen.
15. **The sketch path reads the tree.** `convert` finds the screen and the reading's `existing` list from the tree. `addElement(_:from:to:adjust:)` and `changeKind(of:to:sketchedAt:adjust:)` keep their signatures as thin wrappers over the new verbs, marked `// PROJECTION: deleted in plan 6`. `addElement`'s wrapper passes confidence 1 and `.rules`, as plan 6 converts its call sites (F27).
    - Why: 27 and 5 test call sites keep passing unchanged, which shows today's placement is kept.
16. **Structure fixtures** are generated by the corpus generator beside the 156, named `structure-…`. The sketch corpus loader skips them, and the 156 stay byte for byte.
    - Why: the corpus style, deterministic. `generate` rewrites the folder, so both must come from one run.
17. **The test-fallout policy gains (o) and (p)**, below. Plan 4's (i)–(l) still apply (F16).

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding files, and commit `Layer.xcodeproj/project.pbxproj` with the task.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text. The projection lives in `Layer/Model/Projection/`, never in `Layer/Tree/`.
  - New: `Layer/Tree/` never refers to `Layer/Sketch/` or `Layer/Model/` types beyond those plan 3's screen harness already compiles. The sketch harness compiles `Layer/Tree/`, `Layer/Sketch/` (including the new `SketchedNode.swift`) and `Layer/Model/ElementLayout.swift`, so they stay free of UIKit and SwiftUI too.
- **Type names:** every new type that could clash with SwiftUI is nested in `LayerNode`: `LayerNode.Layout`, `.Stack`, `.Grid`, `.Alignment`, `.Padding`, `.Sizing`.
- **Every `xcodebuild` command** (in this plan, in scripts and in docs) passes `-skipPackagePluginValidation`, and `-skipMacroValidation` too if plan 1's ledger says so.
- **Limits:**
  - tree depth 32;
  - 5,000 nodes per design;
  - grid columns 1–12.

  New: the store's actions refuse past depth 32 and 5,000 nodes (plan 1's fix). The sketch path and the pass keep within them: the landing and a card's take (call 7, Task 5), the structures the pass proposes (Task 3), and a refused `addSketched` leaving the strokes unread (Task 5) (F9).
- **Layer's numbers:**
  - rhythm 8, 12, 16, 24, 32;
  - margins 20 (phone), 32 (tablet), 48 (desktop), 8 (watch), 20 (other);
  - desktop column at most 1080;
  - card: radius 16, padding 16, fill `RGBColor(hex: 0xF2F2F7)`.

  These are `DesignTokens.standard` and the devices' tokens. New: the structure pass reads the rhythm and the card's padding from the design's own tokens (§14), through `DesignTokens.spacing(nearest:)` (plan 3).
- **Undo semantics stay.**
  - Every step is a three-way, per-property revert of only its own changes.
  - Gestures, Format runs, voice commands and generations each stay one step. New: a reading and the automatic structure it settles are one step; an accepted offer, a tidy and a device change are one step each.
  - These stay: `putOnTop`, `markNeedsSaving`, `onlyScreen(changedBy:)`, withdrawing steps that change nothing, and the cap of 50.
- **Ids are stable.** No verb or projection write changes a node's id, except duplicate, which makes new ones. New: a structure built, grown or undone never changes a member's id, and "Did you mean" keeps the node's id.
- **No layout in a SwiftUI `body`**, and no whole-tree layout on an edit. Layout runs only in `TreeRules`, in the store's change, on read, and off the main actor before a commit.
- **Projection code** carries the comment `// PROJECTION: deleted in plan 6` on every type and extension that exists only for it.
- **The sketch cascade keeps its rules and numbers** (spec Constraints):
  - rules first, confidence-gated model escalation, a 4-second limit, then fallback;
  - top-1 accuracy of 87.8% with rules alone and 89.1% with the model;
  - the 156-fixture corpus;
  - the prompts' measured wording (`SketchHintTests`).

  No test lowers them. New: each fixture's reading is pinned by `LayerTests/Goldens/SketchReadings.txt` (Task 2).
- **Pencil latency comes first.** Nothing in this plan runs per stroke or per touch. The pass runs once per settled batch, only on the containers that received nodes, looking only at the new nodes' neighbourhood. There is no model call and no A2UI anywhere in the sketch path.
- **Nothing moves unasked by more than 8 pt** (§5, anti-goals). Only an accepted offer, voice's tidy and a device change, each asked for, move things further.
- **One place for the numbers.** The pass's thresholds and bars are `StructureConventions`, and the card reading's scores are `SketchConventions`. The spec's numbers aren't tuned. Only the builder's own (the reach, the card scores) may be, against the structure fixtures, and each change is recorded.
- **The pass never touches** locked, hidden, turned or drawing nodes, a container the person made (any container whose `sketch` is nil), or a declined node.
- **Green.** After every task:
  - the app builds;
  - the full unit suite passes;
  - the UI suite fails no test outside plan 1's recorded baseline set (spec My call 19).

  The UI suite runs in Tasks 4, 5, 7, 9, 10, 11 and 12 (F23). `scripts/check-generated-swiftui.sh` passes at the end of Tasks 11 and 12.

  The baseline set: failing `testAChangeIsKeptWhenTheAppGoesToTheBackgroundAndIsEnded`, `testMagicPenSketchesBecomeADesignWithCode` and `testTheReferenceDesignFitsTheCanvas`; flaky `testACloseCallOffersWhatItNearlyWasAndBecomesThatWhenTapped`, which counts as failing only if it fails again when run on its own. The set is fixed (My call 19). A new UI test that simulated touches can't drive calls `XCTSkip` with its reason, recorded in the ledger. It never joins the set (F13).
- **The test-fallout policy.** A test written before this plan may be changed or retired only if it asserts one of these:
  - (a) the v1–v3 file or its readers: the JSON keys `elements` or `floating`, a top-level `canvas` object of settings, `drawing.data`, or a version below 4;
  - (b) a flat-list state the tree can't hold:
    - a group pointer to a missing group, a group on another host, or a group that makes a loop;
    - a drawing inside a group's block;
    - a group item that isn't just in front of its members;
  - (c) members of one canvas group at different scales;
  - (d) a write count the tree lowers, such as a container moved as one write instead of one write per member;
  - (e) floating-point noise below 1e-9 from composing transforms through a turned container. Switch to the file's `close` helper, or add one with tolerance 1e-6.
  - (f)–(h) as in plan 3: a replaced generation or export API, a stubbed hosted answer in the written form, and a record of something plan 3 deleted;
  - (i)–(l) as in plan 4: a replaced canvas or panel API, a counter's lower bound, a counter narrowed to the test's own ids or a fixed wait made a poll, and a record of something plan 4 deleted.
  - New in plan 5 (F16; plan 6 uses (k)–(n) for its own, so these are (o) and (p)):
  - (o) it tests `ScreenTidy`'s one-column relayout, which this plan deletes (§5: the structure pass and placement intents replace it). It is retired.
  - (p) it asserts `ScreenTidy`'s result through voice's `tidyScreen` or `changeScreenDevice` (frames, margins, the column, the rhythm). It is rewritten to assert the structure pass's or the placement intents' result. The voice lines and the one-step assertions stay.

  Each change is listed in its task, or recorded in the ledger with its clause. Every other failure is a bug to fix, not a test to change.
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
  - **Suite names (F8).** Where a step names a test file rather than a suite struct, run every struct the table lists, each with its own `-only-testing:LayerTests/<Struct>`. A suite nested in `HostedWindowSuites` runs as `-only-testing:LayerTests/HostedWindowSuites/<Struct>`. Plans 2–4 may rename or split some of these, so expand them as the branch has them when the step runs. A run that executes 0 tests counts as a failure. Every new suite in this plan is one struct named as its file.

    | Name in this plan | Structs to run |
    |---|---|
    | SketchReadingTests | SketchAnalyzerTests, RuleInterpreterTests, SketchEngineTests, BoardTitleTests, SketchPromptTests, AskedReadingTests, HandwritingRecognizerTests |
    | MagicPenComponentTests | InnerMarkTests, SmallControlTests, SketchedLayoutTests, NewControlCodeTests |
    | ScreenGenerationTests (with SketchHintTests) | ScreenStreamParsingTests, ScreenPromptTests, SketchHintTests, ScreenGenerationLifecycleTests, as plan 3 leaves them (LMStudioLiveTests is gated) |
    | HostedModelTests | HostedModelTests, ModelChoiceTests |
    | CorrectedReadingTests | ChangedKindTests, KindSuggestionTests, SketchReadingLogTests |
    | SiriIntentsTests | EntityKeyTests, ColourTests, DesignLibraryTests, DesignIndexTests, OpeningDesignTests, DesignActionTests, ImagePlaygroundTests, StrokeScriptTests, LookWordTests, MovingTests, and the suite plan 3 renamed ScreenBlueprintTests to |
    | FormatPanelTests | HostedWindowSuites/TypingIntoTheFormatPanelTests, ScrubbingAFieldTests, PanelChangesBesideADragTests, HostedWindowSuites/PanelOriginTests, NumberDraftTests |
    | DesignTests | ElementLayoutTests, ViewportTests, DesignStoreTests, AppModelTests, DesignFileTests, CodeGenerationTests, SymbolCatalogTests, DesignFileNameTests, CloudFileTests, ResourceTests, ClosingTests, FormatPanelEditTests, FileCheckTests, TurnedCodeTests |
    | FlatStoreTests | FlatStoreTests, GradualEditStepTests, FlatFormatTests, as plan 2 leaves them |
    | FreeformTests | SettingsTests, FreeformBehaviourTests, MoreMagicPenTests, MoreCodeTests, ScrubbingTests |
    | GroupTests | GroupModelTests, GroupCommandTests, SelectingGroupsTests, GroupGeometryTests, GroupAsOneThingTests, LayerTreeTests (as plan 4 re-expresses it) |
    | ConcurrentEditTests | ConcurrentEditTests, ConcurrentEditsGroupedByEventTests |
    | VoiceToolsTests | VoiceToolsTests (the tidy lines), VoiceHandlesTests, CanvasPictureTests |
    | already structs | SketchBenchmarkTests, LayoutEngineTests, VoiceScreenLayoutTests, DeviceFrameTests, VoiceAgentTests, PencilVoiceTests |
  - **Counters (F7).** No test asserts a value of a global or process-wide counter, because suites run side by side. `StructureInference.neighbourhoodSizes(of:)` is kept per receiving container, and a test reads its own parent's entries. Layout is counted with `LayoutEngine.timesLaidOut(id)`, never `containersLaidOut`.
  - **Timings (F19).** Every number written to the ledger or `docs/benchmarks/semantic-tree.md` (Task 8's pass timings, Task 12's measurements) is measured with no other lane or `xcodebuild` running, in "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47), the baseline's simulator. The ledger records that the machine was quiet. An always-on timing test measures again, up to three times, while it is over budget, and fails only if all three are.
  - **Lanes B and C** run in their own worktrees (`.claude/worktrees/st5-lane-b`, `.claude/worktrees/st5-lane-c`). Their branches are `st5/lane-b` and `st5/lane-c`, cut from `feature/semantic-tree` after Task 1 is merged. Their commands are the same with:
    - simulator `Layer iPad Pro 11 (st5-lane-b)` or `Layer iPad Pro 11 (st5-lane-c)`, each cloned from `iPad Pro 11-inch (M5)`;
    - DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st5-lane-b` or `-st5-lane-c`.
  - A lane's task is reviewed, then merged into `feature/semantic-tree`. Resolve `project.pbxproj` conflicts by re-running `xcodegen generate`.
  - When the plan ends, delete the lane worktrees, their simulators and their DerivedData.
- **The harnesses build.** `Tools/SketchBenchmarkHarness/run.sh check` passes at the end of Tasks 2, 8 and 12, and `Tools/ScreenBenchmarkHarness/run.sh check` at the end of Task 12.

## Review Focus

1. **Nothing moves unasked by more than 8 pt.** No corner of any member of an automatic structure moves more than 8 pt: the rhythm's spacing is tried, then the exact median, then it is offered. Growing takes supersets only. Owned by:
   - Task 3: `decideFollowsTheBars`, `theExactMedianIsTriedBeforeOffering`, `aRaggedRowIsOffered`;
   - Task 6: `aGrownStructureMustHoldAllOfIt`;
   - Task 9: `aRaggedRowIsOfferedNotBuilt`.
2. **The pass never fights the person.** Locked, hidden, turned, drawn and declined nodes, and the person's containers, are never taken. ✕, Ungroup and taking a member out decline, a declined node is never offered again, and an offer goes when a member changes. Owned by:
   - Task 1: `whatThePassMayTake`;
   - Task 3: `rowNearMissesDontGroup`;
   - Task 8: `nearMissesNeverGroup`;
   - Task 9: `decliningMarksThemAndTheyAreNeverOfferedAgain`, `anUngroupedStructureIsDeclined`, `takingOneOutOfARowDeclinesIt`, `theOfferGoesWhenAMemberIsDeletedOrMoved`.
3. **Undo.** An automatic structure undoes with its conversion, and an accepted one on its own. A tidy and a device change are one step each. One undo returns the members to their parent and frames and drops the container. Owned by:
   - Task 5: `aCardTakesWhatItEncloses`;
   - Task 9: `aRowDrawnInOneBatchUndoesWithItsLastReading`, `aRaggedRowIsOfferedNotBuilt`;
   - Task 4: `aDeviceChangeIsOneUndoStep`; Task 10: `tidyingIsOneStep`.
4. **Where things land, and where they go.** A reading lands in the deepest visible, unlocked container under its centre, and locked or hidden ones hand it on. It goes into a row only when its centre is inside, and turned containers map its centre. A device change follows each intent, clamped, while fixed nodes overhang. Owned by:
   - Task 5: every `SketchLandingTests` case;
   - Task 4: every `DeviceReflowTests` case;
   - Task 7: `acceptingReLaysOutFromTheNodesOriginalBounds`.
5. **Latency and accuracy.** The reading's p95 stays under 100 ms with the pass, and the pass stays local. The corpus reads exactly as before (137/156 rules, 139/156 with the model on macOS), `SketchHintTests` is unchanged, and the harnesses build. Owned by:
   - Task 2: `theCorpusReadsAsBefore`;
   - Task 9: `aPassLaysOutOnlyWhatItBuilt`;
   - Task 12: `aReadingLandsWithinBudget`, `thePassLooksOnlyAtTheReceivingContainer`.

**Order and lanes:**
- Lane A (this worktree): Tasks 1, 2, 5, 7, 9, 11, 12.
- Lane B (`st5-lane-b`): Tasks 3, 6, 8.
- Lane C (`st5-lane-c`): Tasks 4, 10.
- Waits:
  - every task waits for Task 1 to be merged;
  - Task 8 waits for Tasks 2 and 5 (the harness's file list, and `SketchedNode`);
  - Task 9 waits for Tasks 3 and 6;
  - Task 10 waits for Task 9 (`build`);
  - Task 11 waits for Tasks 1–10, and Task 12 for all.
  - Before a task that waits on another lane's task, its lane merges `feature/semantic-tree`, with the awaited tasks merged, into its own branch, and re-runs `xcodegen generate` on a project-file conflict (F22). That is lane B before Task 8 (Tasks 2 and 5), and lane C before Task 10 (Tasks 6 and 9).
- No two lanes edit the same file at the same time. `Tools/SketchBenchmarkHarness/` is edited by Task 2, then by Task 8 after it. `VoiceToolbox.swift`, `ScreenTidyTests.swift` and plan 4's `DesignStore+Devices.swift` are lane C's. `AppModel.swift` and `DesignStore.swift` are lane A's.

---

### Task 1: The structure conventions, and what a sketch remembers

**Lane:** A (first; every other task waits for it to be merged)

**Files:**
- Create: `Layer/Tree/StructureConventions.swift`, `Layer/Tree/SketchIntent+Making.swift`
- Test: `LayerTests/SketchIntentTests.swift`

**Interfaces:**
- Consumes: plan 1's `LayerNode.SketchIntent`, `.PlacementIntent` and `.DecidedBy`, and plan 2's `DeviceFrame.margin`.
- Produces:
  ```swift
  enum StructureConventions {                       // spec §5 and My call 6: not settings
      static let rowCentreTolerance: CGFloat = 6
      static let rowEdgeTolerance: CGFloat = 4
      static let rowHeightRatio: CGFloat = 2
      static let rowLargestGap: CGFloat = 32
      static let columnLeast = 3
      static let columnEdgeTolerance: CGFloat = 4
      static let columnGapVariation: CGFloat = 4
      static let gridLeastRows = 2
      static let gridLeastColumns = 2
      static let gridEdgeTolerance: CGFloat = 4
      static let gridCellSizeVariation = 0.2
      static let enclosedShare = 0.9
      static let automatic = 0.8
      static let offered = 0.5
      static let tidyAutomatic = 0.5                // call 10
      static let furthestAutomaticMove: CGFloat = 8
      static let offerLifetime: Duration = .seconds(8)
      static let reach: CGFloat = 48                // the builder's: a sibling this close to the neighbourhood joins it
      static let centredShare = 0.06                // of the screen's width
      static let proportionalShare = 0.9            // of the content width (call 8)
      static let marginZoneShare = 0.15             // of the content width, past the margin
  }
  extension LayerNode.PlacementIntent {
      /// §5's rules, first match: proportional, centred, leading, trailing, fixed. `rect` in screen points (call 8).
      static func of(_ rect: CGRect, screenWidth: CGFloat, margin: CGFloat) -> Self
  }
  extension LayerNode.SketchIntent {
      /// What a reading remembers. `screen` nil means the open canvas: normalised bounds zero, placement `.fixed`.
      init(sketched bounds: CGRect, on screen: CGSize?, margin: CGFloat, confidence: Double, decidedBy: LayerNode.DecidedBy)
  }
  extension LayerNode {
      /// Whether the structure pass may take it: upright, not hidden, not locked, not a drawing, not declined,
      /// and, for a container, one with a `sketch` (a sketched card, or one the pass made), never the person's.
      var isArrangeable: Bool { get }
  }
  ```

- [ ] **Step 1: Write the failing tests** in `SketchIntentTests`:
  - `theConventionsAreTheSpecs`: each spec number above is what §5 says. That is 6, 4, 2, 32, 3, 4, 4, 2, 2, 4, 0.2, 0.9, 0.8, 0.5, 8 and 8 seconds.
  - `placementFollowsTheRulesInOrder`, on the iPhone (393 wide, margin 20):
    - (20, 300, 170, 120) is `.leading`;
    - (203, 300, 170, 120) is `.trailing`;
    - (96, 80, 200, 40) is `.centered`;
    - (30, 700, 330, 50) is `.proportional`, ahead of centred: 330 ≥ 0.9 × 353;
    - (230, 400, 51, 31) is `.fixed`;
    - (60, 400, 100, 30) is `.leading`: it starts before 72.95.
  - `onAnIPadTheZonesWiden` (820 wide, margin 32): (100, 0, 100, 50) is `.leading`, and (500, 300, 100, 100) is `.fixed`.
  - `anIntentRemembersTheSketch`: bounds (39.3, 85.2, 196.5, 42.6) on a 393 × 852 screen give `normalizedBounds` (0.1, 0.1, 0.5, 0.05) within 1e-9. Confidence 0.73 and `.model` are kept, and `structureDeclined` is false.
  - `onTheCanvasThereIsNoScreen`: with `screen` nil, `normalizedBounds == .zero` and the placement is `.fixed`.
  - `whatThePassMayTake`:
    - A text is arrangeable.
    - It isn't when it is locked, hidden, turned 10° or declined.
    - A drawing isn't.
    - A `.group` with `sketch == nil` isn't, but one with an intent whose `decidedBy` is `.structure` is.
    - A sketched card is.

- [ ] **Step 2: Run them.** Run `SketchIntentTests`. Expected: FAIL (the types don't exist).

- [ ] **Step 3: Implement** both files. The rules are call 8's. `isArrangeable` reads the node's own flags; callers check ancestors through the index.

- [ ] **Step 4: Run them.** Run `SketchIntentTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Structure conventions and placement intents: the pass's numbers in one place, and what a sketch remembers"`

---

### Task 2: The card reading, and what a reading carries

**Lane:** A (after Task 1)

**Files:**
- Modify: `Layer/Sketch/ComponentRule.swift` (the card candidate), `Layer/Sketch/SketchInterpreter.swift` (`SketchConventions`' card scores), `Layer/Sketch/SketchEngine.swift` (`SketchOutcome.confidence` and `.decidedBy`)
- Modify: `Tools/SketchBenchmarkHarness/run.sh` and `Harness.swift`:
  - The build adds `Layer/Tree/*.swift` and the model, projection and `Tools/Shared/` files that `Tools/ScreenBenchmarkHarness/run.sh` compiles (plan 3 Task 12), but not `Layer/A2UI/`, the screen prompt or the hosted client.
  - A `check` mode is added.
  - A type still missing on macOS gets a stub in `Tools/Shared/`. No app file changes to suit the harness.
  - `TreeIndex` needs `TurnedRect`, and Task 8's `ElementLayout.swift` also needs `Rotation.rotate` and `DesignElement.shapeBounds`. All three live in `Layer/Model/Rotation.swift`. Do what plan 3's screen package does for `TurnedRect`: if it compiles the real `Rotation.swift` (with what that needs, such as `Viewport.swift`), the sketch harness compiles it too and drops `Tools/Shared/RotationStub.swift`; otherwise the stub gains them, copied unchanged, as its header asks (F26).
- Create: `LayerTests/Goldens/SketchReadings.txt` (recorded in Step 1, before any rule changes), `LayerTests/CardReadingTests.swift`

**Interfaces:**
- Consumes: Task 1's `StructureConventions.enclosedShare`, and plan 1's `ElementKind.card` and `LayerNode.DecidedBy`.
- Produces:
  ```swift
  extension SketchConventions {                 // call 6
      static let cardAroundSeveral = 0.95       // two or more things inside: card's score…
      static let cardElsewhere = 0.5            // …and every other reading of the outline is scaled by this
      static let cardAroundOne = 0.6            // one thing inside: card's score; the others unchanged
  }
  struct SketchOutcome {                        // new fields
      var confidence: Double = 1                // the rules' score for `reading`; 1 when asked for by name
      var decidedBy: LayerNode.DecidedBy = .rules
  }
  ```
- **The rule.** It applies in `onScreenScoredReadings`' enclosure branch, after the progress-bar, small-control and cross checks, so only big outlines are affected.
  - n is the number of `existing` frames with at least `enclosedShare` of their area inside `local`.
  - If n is 0, nothing changes.
  - Otherwise `.element(.card)` is added with call 6's scores.
  - The card has no `sketchHint` and isn't in `hintOrder`, so the instructions don't change.
- **Who decided:**
  - the rules → `.rules`, except `.handwriting` when `recognizedText` is set and the reading is a title, body or text;
  - a provider's answer → `.model`;
  - an asked reading → `.asked`.

- [ ] **Step 1: Record today's readings, and write the failing tests.** Write `CardReadingTests` first, then record the golden on the unchanged rules.
  - `theCorpusReadsAsBefore`:
    - Each of the 156 fixtures gives one line: `id`, the rules' top reading, its candidates highest first with scores to four places, and whether it is a close call.
    - The lines must equal `Goldens/SketchReadings.txt`.
    - With `TEST_RUNNER_LAYER_RECORD_READINGS=<dir>` set, the test writes the file there instead. Record it now, before Step 3, and commit it with the tests.
    - No fixture's candidates contain `card`.
  - The card tests name the constants, not their values, so a tuning in Task 8 changes only `SketchConventions` (F17).
  - `anOutlineRoundTwoThingsIsACard`:
    - Existing are a title (96, 120, 200, 40) and a body (20, 170, 353, 40). The sketch is `StrokeScript` `box 10 100 373 130 16`.
    - The top reading is `.element(.card)` at `SketchConventions.cardAroundSeveral` (0.95). Every other score is at most `cardElsewhere` (0.5) times its score without the card, and `RuleInterpreter().isCloseCall` is false.
  - `anOutlineRoundOneThingMightBeACard`: a 260 × 56 pill round one text gives `.button` on top, and `.card` among the candidates at `SketchConventions.cardAroundOne` (0.6).
  - `nothingInsideMeansNoCard`: the same box with the title at (20, 400, 200, 40) gives exactly today's candidates and scores.
  - `aThingHalfInsideIsNotInside`: a body straddling the outline with 50% inside gives no card.
  - `anOutcomeSaysHowSureAndWhoDecided`. It uses `SketchEngine(provider:)` with stub providers, as `SketchReadingTests` builds them.
    - A clean button fixture read by the rules gives `confidence == request.scoredReadings[0].score` and `.rules`.
    - A wave with `readHandwriting` returning "Sign in" gives `.handwriting`.
    - A close call that a stub answers gives `.model`.
    - A drawing asked for "a toggle" gives `.asked` and confidence 1.

- [ ] **Step 2: Run them.** Run `CardReadingTests`. Expected: FAIL, except `theCorpusReadsAsBefore`, which passes against what was just recorded.

- [ ] **Step 3: Implement** the rule, the scores and the outcome's fields.

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run `CardReadingTests`, then these, which must pass unchanged:
  - `SketchReadingTests`, `MagicPenComponentTests`, `SketchBenchmarkTests`;
  - `ScreenGenerationTests`, including `SketchHintTests`;
  - `HostedModelTests`, `CorrectedReadingTests`.

  Then run the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Build and run the harness.**
  - `Tools/SketchBenchmarkHarness/run.sh check` prints `harness ok: 156 fixtures read` and exits 0.
  - `run.sh run LayerTests/Fixtures` reports top-1 87.8% (137/156).
  - If Apple Intelligence answers on this Mac, `run.sh run LayerTests/Fixtures --model` reports 89.1% (139/156). Record both in the ledger, or record that the model wasn't available.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Card reading: an outline round two or more things reads as a card; a reading says how sure it is and what decided it; the corpus reads exactly as before"`

---

### Task 3: Rows and columns

**Lane:** B (first; waits for Task 1)

**Files:**
- Create: `Layer/Tree/StructureInference.swift`
- Test: `LayerTests/StructureInferenceTests.swift`

**Interfaces:**
- Consumes: Task 1, plan 1's `LayoutEngine.layOut(_:previous:measure:diagnostics:)` and `TextMeasure`, and plan 3's `DesignTokens.spacing(nearest:)`.
- Produces:
  ```swift
  enum StructureInference {
      enum Mode: Sendable { case sketch, tidy }
      struct Structure: Equatable, Sendable {
          enum Kind: Equatable, Sendable { case row, column, grid(columns: Int), cardColumn }
          var kind: Kind
          var parent: UUID                // the receiving container (a screen root's id included)
          var members: [UUID]             // reading order (My call 15); a row built just before may be one
          var replacing: [UUID] = []      // containers the pass made that this one takes the place of (Task 6)
          var container: LayerNode        // proposed: layout, padding, frame in the parent's space, both sizings .fit;
                                          // members inside at their laid-out frames, each .fixed (My call 16).
                                          // For .cardColumn it is the card itself with its new layout and padding.
          var confidence: Double
          var movement: CGFloat           // the furthest any member moves, as proposed
          var title: String { get }       // "Make a row?", "Make a column?", "Make a grid?"
      }
      enum Decision: Equatable, Sendable { case apply(Structure), offer(Structure) }
      enum Outcome: Equatable, Sendable { case applyRhythm, applyMedian, offer }
      /// Pure and deterministic. `parent` as it is now; `new` the batch's nodes in it; `grows` the containers the pass
      /// made that may grow (Task 6). In the order to apply: inner structures first.
      static func infer(in parent: LayerNode, new: Set<UUID>, grows: Set<UUID> = [], tokens: DesignTokens,
                        mode: Mode = .sketch, measure: TextMeasure = .shared) -> [Decision]
      /// My call 16: the rhythm's spacing, else the exact median, else an offer. Nil: nothing.
      static func decide(confidence: Double, rhythmMove: CGFloat, medianMove: CGFloat, mode: Mode) -> Outcome?
      /// `parent` with `structure` built in it: members as they are now, each .fixed at its size and at the proposed
      /// frame, inside the proposed container (its id kept) at the frontmost member's slot. Nil when a member is gone,
      /// no longer `parent`'s child, or not arrangeable.
      static func applying(_ structure: Structure, to parent: LayerNode) -> LayerNode?
      #if DEBUG
      /// One entry per run in that receiving container, counted under a lock (F7).
      static func neighbourhoodSizes(of parent: UUID) -> [Int]
      #endif
  }
  ```
- **The algorithm:**

  ```
  arrangeable(c) = c.isArrangeable (Task 1)
  neighbourhood = the new nodes, then every arrangeable child of `parent` whose frame, grown by `reach`, meets one already
                  in it, repeated until nothing joins
  rows: sort the neighbourhood by minX; a run grows while the next one
        - is 0…32 pt past the last (gap ≥ 0), and within 2× of every height in the run,
        - shares one line with the whole run: centres within 6, tops within 4, or bottoms within 4,
        - and no other visible child of `parent` meets the gap between them;
        when more than one line fits, the one whose error is smallest against its tolerance, centres on a tie;
        a row needs ≥ 2 members, one of them new
  columns: the items are the rows just applied (as one item, at their container's frame) and the rest; sort by minY;
        ≥ 3 items, gaps ≥ 0, one shared edge (leading, centre or trailing within 4), the largest and smallest gaps within
        4 of each other (not required in tidy), nothing else between, one item new or a row holding one;
        when more than one edge fits, the one whose error is smallest against its tolerance, leading on a tie (F20)
  never (F5, F9): a row holding a row, a column holding a column, a grid holding anything but leaves and cards, or a
        structure that would put a member's subtree past depth 32
  confidence = alignment × gaps × sizes, each f(e, limit) = clamp(1 − e / (2·limit), 0.5, 1)    (call 4)
        alignment: e = the largest distance of the shared line or edge from its median, limit = its tolerance
        gaps:      e = largest gap − smallest; limit 32 for rows, 4 for columns (left out in tidy)
        sizes:     e = largest / smallest − 1, of heights for rows and widths for columns; limit 1
  proposal: alignment from the shared line or edge (.center, .start or .end); spacing tried in order:
        tokens.spacing(nearest: median gap), then the median gap rounded to a whole point;
        the container's origin: a row starts at the first member's minX, with its shared line at the members' median;
        a column starts at the first member's minY, with its shared edge at the members' median; whole points;
        LayoutEngine.layOut gives the members' frames; movement = the largest distance any member's origin moves
        (members are upright and keep their sizes, so every corner moves as the origin does)
  decide (both spacings' movements): sketch → confidence ≥ 0.8 and rhythm ≤ 8 → applyRhythm;
        confidence ≥ 0.8 and median ≤ 8 → applyMedian; confidence ≥ 0.5 → offer (with the rhythm's spacing); else nothing.
        tidy → confidence ≥ 0.5 → applyRhythm; else nothing
  ```

- [ ] **Step 1: Write the failing tests** in `StructureInferenceTests`. The parent is a free iPhone root, nodes are `.fixed` texts unless named, and every node is new unless the test says otherwise.
  - `decideFollowsTheBars`:
    - In sketch mode: (0.9, 3, 0) is `.applyRhythm`; (0.9, 12, 2) is `.applyMedian`; (0.9, 12, 9) is `.offer`; (0.6, 0, 0) is `.offer`; (0.49, 0, 0) is nil.
    - In tidy mode: (0.6, 40, 40) is `.applyRhythm`, and (0.49, 0, 0) is nil.
  - `twoTextsSideBySideMakeARow`: A (20, 100, 100, 24) and B (132, 100, 100, 24) give exactly one `.apply`:
    - kind `.row`, members `[A, B]`;
    - layout `.stack(horizontal, spacing 12, alignment .center)`;
    - container frame (20, 100, 212, 24);
    - confidence 1 and movement 0.
  - `rowsAreReadLeftToRight`: with B first in `parent.children`, the members are still `[A, B]`.
  - `membersAreFixedAtTheirSize`: when A's width is `.fit`, it is `.fixed` in the proposal and its frame size is unchanged.
  - `aRowSnapsItsGapToTheRhythm`: B at x 134 gives spacing 12 (14 is as near 12 as 16, and the smaller wins) and movement 2, applied.
  - `theRhythmIsTheDesigns`: with tokens of rhythm `[4, 10, 20, 40]`, B at x 133 gives spacing 10.
  - `theExactMedianIsTriedBeforeOffering`:
    - Five 56 × 24 texts at x 20, 96, 172, 248 and 324 have gaps of 20.
    - The rhythm's 16 would move the last one 16 pt, so it is applied with spacing 20 and movement 0.
    - The container frame is (20, 100, 360, 24).
  - `aRaggedRowIsOffered`: three 100 × 24 texts at x 20, 124 and 254 (gaps 4 and 30) give one `.offer` with confidence 0.59375 and title "Make a row?".
  - `rowNearMissesDontGroup`. Each case gives no decision:
    - a gap of 40;
    - heights of 20 and 50;
    - centres 10 apart, with tops and bottoms more than 4 apart;
    - a locked divider lying in the gap;
    - two established texts (neither new);
    - a partner that is locked, hidden, turned 10°, declined, or a `.group` the person made (`sketch == nil`);
    - a partner farther than 48 from the neighbourhood.
  - `threeAlignedFieldsMakeAColumn`: text fields (20, 200, 353, 44), (20, 260, 353, 44) and (20, 320, 353, 44) give a column `.start` (all three edges tie, so leading: F20), spacing 16, container (20, 200, 353, 164), confidence 1, applied.
  - `twoStackedThingsAreNotAColumn`.
  - `irregularGapsAreNotAColumnUnlessTidying`:
    - Fields at y 200, 260 and 328 (gaps 16 and 24) give nothing in sketch mode.
    - In tidy mode they give a column with spacing 16 (20 is as near 16 as 24, and the smaller wins), at y 200, 260 and 320.
  - `aCentredColumnOfUnevenWidthsIsOffered`: a title (96, 80, 200, 40), a field (20, 136, 353, 44) and a button (20, 196, 353, 50) give an `.offer`. Its alignment is `.center` and its confidence 0.5789 to four places (0.9375 × 1 × 0.6175).
  - `aRowInsideAColumnIsBuiltFirst`:
    - A title (20, 80, 353, 40), a label (20, 139, 240, 24), a toggle (272, 136, 51, 31) and a button (20, 183, 353, 50).
    - The decisions are `[.apply(row), .apply(column)]`.
    - The row holds `[label, toggle]` with spacing 12 in frame (20, 136, 303, 31), with confidence ≥ 0.8 and movement ≤ 1.
    - The column holds `[title, row.container.id, button]` with spacing 16 in frame (20, 80, 353, 153).
  - `applyingBuildsInTheFrontmostSlot`:
    - The root is `[X, A, Y, B]`, and the row is `[A, B]`.
    - The result is `[X, Y, row[A, B]]`: the row takes B's slot.
    - A's and B's ids are kept, the row's id is the proposal's, and the members' frames are the proposal's.
    - `applying` returns nil once B is deleted from the parent.
  - `thePassLooksOnlyAtTheNeighbourhood`: a root of 60 established texts, none within 48 pt of another or of one new text, gives no decision, and the last entry of `neighbourhoodSizes(of: root.id)` is 1 (F7).
  - `aRowNeverHoldsARow` (F5): a row R the pass made, not in `grows`, and a new text beside it give no decision.
  - `nothingIsBuiltPastDepth32` (F9): two new texts side by side in a free group whose children sit at depth 32 give no decision.

- [ ] **Step 2: Run them.** Run `StructureInferenceTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `infer` for rows and columns, `decide`, and `applying`.

- [ ] **Step 4: Run them.** Run `StructureInferenceTests` and `LayoutEngineTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Structure inference: rows and columns found among a batch's neighbours, with confidence, spacing on the design's rhythm, and nothing moved more than 8 pt"`

---

### Task 4: Device changes by placement intent, from every path

**Lane:** C (first; waits for Task 1)

**Files:**
- Create: `Layer/Tree/DeviceReflow.swift`
- Modify:
  - `Layer/Model/DesignStore+Devices.swift` (plan 4's): `changeDevice(of:to:)` goes here. `setDevice(of:to:)` and the screen part of `addCustomDevice(_:forScreen:)` call it, and `updateCustomDevice(_:)` reflows each free screen on the device by intent in its own step (Depends on plan 4, item 1; F3);
  - `Layer/Intents/ScreenIntents.swift`: `ChangeScreenDeviceIntent.perform`;
  - `Layer/Voice/VoiceToolbox.swift`: `changeScreenDevice`, whose words are unchanged.
- Modify (fallout p): `LayerTests/ScreenTidyTests.swift`, only `VoiceScreenLayoutTests.changingTheDeviceReflowsTheScreen`
- Test: `LayerTests/DeviceReflowTests.swift`

**Interfaces:**
- Consumes: Task 1; plan 2's `reconcile(_:_:)`, `asOneStep(_:)` and `device(of:)`; plan 4's `updateTreeScreen(_:_:)`, `setDevice(of:to:)`, `addCustomDevice(_:forScreen:)` and `updateCustomDevice(_:)`; plan 1's `TreeValidator.check(_:on:)`.
- Produces:
  ```swift
  enum DeviceReflow {   // pure
      /// New frames for a free root's children when its screen goes from `old` to `new` (§5, call 9). Unmoved ones aren't listed.
      static func frames(for root: LayerNode, from old: DeviceFrame, to new: DeviceFrame) -> [UUID: CGRect]
  }
  extension DesignStore {   // Layer/Model/DesignStore+Devices.swift
      /// One step: the screen's device, and its contents by placement intent (a free root) or re-laid by the rules (any
      /// other root). An iPhone is kept as no device, as today. Nothing happens for the same device.
      func changeDevice(of screenID: TreeScreen.ID, to device: DeviceFrame)
  }
  ```
- **The rules** (W and W′ are the old and new widths). The intent is `sketch?.placement`, else `PlacementIntent.of(frame, screenWidth: W, margin: old.margin)`.
  - leading: x is kept;
  - trailing: the right inset is kept, so x = W′ − (W − maxX) − width;
  - centred: x = ((W′ − width) / 2 + (midX − W / 2)).rounded();
  - proportional: x = (x · W′/W).rounded(), and the width becomes (width · W′/W).rounded() when the node is upright and `.fixed` across. A turned or fitting node moves its centre by the same ratio and keeps its size;
  - fixed: unchanged, and it may overhang;
  - locked: unchanged.

  y is kept. A node that isn't fixed is then clamped inside 0…W′ and 0…H′ by its turned shape's bounds, with the leading and top edges winning when it can't fit.

- [ ] **Step 1: Write the failing tests** in `DeviceReflowTests`. Frames go from the iPhone (393 × 852, margin 20) to the iPad (820 × 1180, margin 32) unless the test says otherwise.
  - `leadingKeepsItsLeftInset`: (20, 300, 170, 120) is unchanged.
  - `trailingKeepsItsRightInset`: (203, 300, 170, 120) becomes (630, 300, 170, 120).
  - `centredStaysCentred`: (96, 80, 200, 40) becomes (310, 80, 200, 40).
  - `proportionalScalesItsXAndWidth`: (20, 700, 353, 50) becomes (42, 700, 737, 50), and back on the iPhone it is (20, 700, 353, 50) again.
  - `fixedStaysPut`: (230, 400, 51, 31) is unchanged.
  - `aSavedIntentWinsOverTheFrame`: the same frame with `sketch.placement == .trailing` goes to x 657.
  - `lockedStaysPut`: a locked trailing node is unchanged.
  - `aTurnedNodeKeepsItsSize`: a proportional node turned 90 keeps its 353 × 50 and its angle, and its turned shape lies inside the iPad.
  - `goingSmallerClampsButFixedOverhangs` (iPad to iPhone):
    - A leading (40, 100, 500, 60) becomes (0, 100, 500, 60).
    - A fixed (500, 300, 100, 100) is unchanged, and `TreeValidator.check(root, on: .iPhone)` reports `.clipped` for it.
  - `aColumnScreenIsLaidOutAgain`: a column root's fill-width child is at minX 32 with width 756 on the iPad, and the root's frame is (0, 0, 820, 1180).
  - `aDeviceChangeIsOneUndoStep`: one undo restores every frame and the `deviceID`.
  - `everyPathChangesTheDeviceTheSameWay`:
    - Three identical free screens are each changed to the iPad, one through `store.setDevice(of:to:)` (which plan 4's picker calls), one through `ChangeScreenDeviceIntent`'s `perform` and one through voice's `changeScreenDevice(screen:device:)`.
    - Their roots' children have equal frames, each `deviceID` is `"ipad"`, and each made one undo step.
  - `editingACustomDeviceReflowsItsFreeScreens` (F3): a free screen on a 393 × 852 custom frame holds (203, 300, 170, 120). `updateCustomDevice` to 820 × 1180 moves it to (630, 300, 170, 120), in one undo step.
  - Rewrite `VoiceScreenLayoutTests.changingTheDeviceReflowsTheScreen` (fallout p):
    - The line stays "Made S1 an iPad screen (820 × 1180)."
    - The login's title becomes (42, 75, 737, 41), its button (42, 420, 737, 50), and its image stays (20, 500, 200, 200).
    - Back to the iPhone, every frame is as it was and `deviceID` is nil.
    - "watch" is still refused with "I can make it…".

- [ ] **Step 2: Run them.** Run `DeviceReflowTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `changeDevice` is `asOneStep`:
  1. `updateTreeScreen` sets the `deviceID`, never the projection's `updateScreen`.
  2. For a free root, `reconcile` writes `DeviceReflow.frames` (computed from the old device).

  Point `setDevice(of:to:)`, the screen part of `addCustomDevice(_:forScreen:)`, the intent and voice's tool at it. `updateCustomDevice(_:)` reflows each free screen on that device by `DeviceReflow.frames` from the device's old size, in its own step; column screens re-lay through the rules, as plan 4 has them. `MagicPenTab`'s New Screens picker is left alone.

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run `DeviceReflowTests`, then these, which must pass unchanged apart from the rewritten test:
  - `VoiceScreenLayoutTests`, including `aTurnedElementKeepsItsAngleAndSizeOnANewDevice`;
  - `SiriIntentsTests`, `FormatPanelTests`, `DeviceFrameTests`, and plan 4's `CustomDevicesAndTokensTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Device changes: a free screen's contents follow their placement intents and a column screen re-lays, the same from the panel, Siri and voice"`

---

### Task 5: Where a sketch lands, and nodes that remember it

**Lane:** A (after Task 2)

**Files:**
- Create: `Layer/Tree/SketchLanding.swift`, `Layer/Sketch/SketchedNode.swift`, `Layer/Model/DesignStore+Sketch.swift`
- Modify:
  - `Layer/Sketch/SketchInterpreter.swift`: `LayerNode.adoptMarks(of:)`;
  - `Layer/Model/DesignStore.swift`: `addElement(_:from:to:adjust:)` becomes a wrapper (confidence 1, `.rules`: F27). `sketchedElement` stays, private, because today's `changeKind` still calls it until Task 7 (F1);
  - `Layer/App/AppModel.swift`: `convert` reads the tree's screen and `existing`, writes through `addSketched`, and gives canvas readings an intent.
- Test: `LayerTests/SketchLandingTests.swift`, `LayerTests/SketchToNodeTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2, plan 1's `TreeIndex`, `NaturalSize` and `TurnedRect`, plan 2's `reconcile`, `update`, `device(of:)` and `DeviceFrame.custom`, plan 4's `TreeDrop.slot(for:among:skipping:layout:)` (F25), and today's `ElementLayout.sketched`.
- Produces:
  ```swift
  struct SketchLanding: Equatable, Sendable {      // pure, Layer/Tree
      var screen: TreeScreen.ID
      var parent: UUID                  // the receiving container; a screen root's id included
      var isLaidOut: Bool
      var local: CGRect                 // the sketch in the parent's space; through a turned container, same size, centre mapped
      var index: Int?                   // laid out: the slot nearest its centre; free: nil, in front
      /// The topmost screen under the sketch's centre (canvas points), then the deepest visible, unlocked container there;
      /// a locked or hidden one hands it to its nearest unlocked, visible ancestor. `forCard` skips containers the sketch
      /// encloses (call 7). Nil off every screen.
      static func of(_ sketch: CGRect, in content: TreeContent, index: TreeIndex, forCard: Bool = false) -> SketchLanding?
      /// The arrangeable children of `parent` at least 90% inside `rect` (the parent's space), back to front.
      static func enclosed(by rect: CGRect, in parent: LayerNode) -> [UUID]
  }
  enum SketchedNode {                              // pure, Layer/Sketch
      struct Made: Equatable, Sendable { var node: LayerNode; var landing: SketchLanding; var takes: [UUID] }
      /// The node a reading of `kind` becomes where `sketch` (canvas points) lands, with its SketchIntent (call 7, call 8).
      static func make(_ kind: ElementKind, sketch: CGRect, in content: TreeContent, index: TreeIndex,
                       confidence: Double, decidedBy: LayerNode.DecidedBy) -> Made?
      /// The root with `made` put in: at its slot, a card holding what it takes at their places on screen.
      static func inserting(_ made: Made, into root: LayerNode) -> LayerNode
  }
  extension DesignStore {
      /// One change: the reading's node where it lands (§5). Nil off every screen. `adjust` finishes it in the same change.
      @discardableResult
      func addSketched(_ kind: ElementKind, from sketch: CGRect, confidence: Double, decidedBy: LayerNode.DecidedBy,
                       adjust: (inout LayerNode) -> Void = { _ in }) -> UUID?
      func screenID(under sketch: CGRect) -> TreeScreen.ID?
      /// A reading's `existing`: the screen's leaves at their screen frames, hidden ones included, as today.
      func sketchNeighbours(on screenID: TreeScreen.ID) -> [ExistingElement]
      // PROJECTION: deleted in plan 6
      @discardableResult func addElement(_ kind: ElementKind, from sketch: CGRect, to screenID: DesignScreen.ID,
                                         adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement?   // unchanged
  }
  extension LayerNode { mutating func adoptMarks(of observation: SketchObservation) }   // today's rule, on `content`
  ```
- **The node:**
  - In a free parent:
    - It has today's fields: placeholder text and `style.tint = Theme.accent`.
    - Its frame and text alignment come from `ElementLayout.sketched`, among the parent's visible children (call 7). It is `.fixed` on both axes.
    - A second button on a screen that has a filled one becomes bordered "Cancel", as today.
  - In a laid-out parent: the slot is call 7's, given by `TreeDrop.slot` with a fresh id to skip (F25), and so is the sizing; the engine places it.
  - A card is as in call 6, with `padding` from the design's card padding. Its `style.tint` is nil and it has no placeholder text, so it draws and exports the design's card fill (F2).
  - Every node carries `SketchIntent(sketched: <sketch in screen points>, on: device.size, margin: device.margin, …)`.
- **Limits (F9):**
  - The landing stops at the deepest container whose child stays within depth 32.
  - A card takes no sibling whose subtree would pass depth 32.
  - At 5,000 nodes `addSketched` returns nil, and `convert` treats the strokes as unread (`reject(keys)`), as it does a sketch it can't read.
- **`convert`:**
  - Off a screen, the reading goes through `addFloating` as today, then gets `SketchIntent(sketched: bounds, on: nil, …)` in the same act.
  - The reading-log link, the recognised words (`content.text`) and the "Did you mean" offer stay as they are.
  - The drawing read on request is selected as before (Depends on plan 4, item 3).

- [ ] **Step 1: Write the failing tests.** In `SketchLandingTests` (pure, on hand-built `TreeContent`; the screen is an iPhone at origin (0, 0), scale 1, unless the test says otherwise):
  - `aSketchOnAFreeScreenLandsOnItsRoot`: the parent is the root, and `local` equals the sketch.
  - `itLandsInTheDeepestContainerUnderItsCentre`:
    - The root holds a free card at (20, 100, 353, 200), which holds a free group at (20, 20, 200, 100).
    - A 40 × 20 sketch centred at (100, 150) lands in the group with `local` (40, 20, 40, 20).
  - `aSketchAcrossAnEdgeLandsWhereItsCentreIs`: with its centre just outside the card, it lands on the root.
  - `aLockedOrHiddenContainerHandsItOn`: a locked group gives the card, and a hidden card gives the root.
  - `aTurnedContainerMapsTheCentre`: in a group at (100, 100, 200, 100) turned 90, a 20 × 20 sketch centred at canvas (240, 60) has `local` (0, 0, 20, 20).
  - `aRowGivesTheSlotNearestTheCentre`:
    - A row at (20, 300) holds children at local x 0, 112 and 224, each 100 wide. A sketch centred at canvas x 190 gets index 2.
    - A column gives its slot by y, and a grid in reading order.
  - `onlyACentreInsideTheRowGoesIn`: a sketch centred 4 pt below the row lands on the root.
  - `offEveryScreenThereIsNoLanding`: nil.
  - `aCardSkipsWhatItEncloses`: a card sketch (10, 100, 373, 140) round a free group at (20, 110, 353, 100) lands on the root.
  - `aSketchPastDepth32LandsInItsParent` (F9): a sketch over an empty free card at depth 32, whose child would sit at 33, lands in the card's parent.

  In `SketchToNodeTests` (`@MainActor`, with a store and an undo manager):
  - `aSketchedButtonIsANodeWithItsIntent`:
    - `addSketched(.button, from: (30, 700, 330, 56), confidence: 0.91, decidedBy: .rules)` makes the root's last child.
    - Its frame is `ElementLayout.sketched(.button, sketch: …, on: .iPhone, among: []).frame`, and it is `.fixed` on both axes.
    - Its `sketch` has `originalBounds` (30, 700, 330, 56), `normalizedBounds` (30/393, 700/852, 330/393, 56/852), confidence 0.91, `.rules` and `.proportional`.
  - `onAHalfScaleScreenTheIntentIsInScreenPoints`: with the screen at (1000, 0) and scale 0.5, the canvas sketch (1015, 350, 165, 28) gives `originalBounds` (30, 700, 330, 56).
  - `inAFreeCardItIsPlacedInTheCardsSpace`:
    - A fixed free card is at (20, 100, 353, 200). A text sketched at canvas (60, 140, 120, 24) becomes the card's child.
    - Its frame is `ElementLayout.sketched(.text, sketch: (40, 40, 120, 24), on: <a 353 × 200 custom frame>, among: <the card's children's frames>).frame`.
  - `inARowItTakesItsSlotAndItsSiblingsSize`:
    - A button sketched between two `.fixed` 100 × 44 buttons in a row takes index 1, `.fixed` at 100 × 44.
    - A text in a row with no text takes `NaturalSize.defaultSizing(for: .text)`.
  - `aCardTakesWhatItEncloses`:
    - A title and a body sit on a free root. A card is sketched at (10, 100, 373, 120) round them, inside `asOwnStep`.
    - The root's children are `[card]`, and the card's are `[title, body]`, with the same ids and order and unchanged screen frames.
    - The card's frame is the drawn box grown to hold them, `.fixed`, with layout nil, padding 16 and `style.tint == nil` (F2).
    - One undo leaves the root `[title, body]` at their frames.
  - `aCardInARowTakesNothing`, and `aCardLeavesLockedThingsWhereTheyAre`.
  - `theSecondButtonIsBorderedCancel`.
  - `aConversionMakesANodeWithItsReading`:
    - An `AppModel` has an iPhone screen at (0, 0), scale 1, and zoom 1.
    - `sketchChanged` with `StrokeScript.parse("pill 30 700 330 56")`, then `convertNow()`, then `await waitForConversions()`.
    - The root's last child is a `.button` whose `sketch.decidedBy` is `.rules` and whose confidence is that request's top score.
    - One undo removes it.
  - `aSketchOnTheCanvasRemembersItsBounds`: a wave off every screen gives a canvas text whose `originalBounds` are the sketch's canvas bounds, with `normalizedBounds == .zero` and `.fixed`.
  - `aSketchOnAFullDesignIsLeftUnread` (F9): on a design of 5,000 nodes, `addSketched` returns nil, and after a conversion the strokes are still on the canvas, unread.

- [ ] **Step 2: Run them.** Run `SketchLandingTests` and `SketchToNodeTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `SketchLanding`, `SketchedNode`, the store verbs (`addSketched` is `reconcile` with `SketchedNode.inserting`), the wrapper, and `convert`'s changes. Leave `sketchedElement` in place for `changeKind` (F1).

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run both suites, then these, which must pass unchanged (the wrapper keeps their 27 calls):
  - `SketchReadingTests`, `MagicPenComponentTests`, `CorrectedReadingTests`;
  - `DesignTests`, `FlatStoreTests`, `FreeformTests`;
  - `ConcurrentEditTests`, `SiriIntentsTests` (`DrawStrokesIntent`).

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Sketch to node: a reading lands in the deepest container under it, laid out there, and remembers its sketch; a card takes what it encloses"`

---

### Task 6: Grids, a card's inside, growing structures, and tidying

**Lane:** B (after Task 3)

**Files:**
- Modify: `Layer/Tree/StructureInference.swift`
- Test: `LayerTests/StructureGridTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces: no new names. `infer` and `applying` gain grids, `.cardColumn`, `grows` and `replacing`, and tidy mode in full.
- **The rules:**

  ```
  grids (before rows), on the neighbourhood with each `grows` container read as its members:
    rows of the grid: tops within 4; columns: leading edges within 4; ≥ 2 rows and ≥ 2 columns; one member per cell;
    every row full, except that a grid in `grows` may gain a short last row filling its first columns
    cell sizes: each width and height within 20% of the median's; ≥ 1 new member
    columnSpacing and rowSpacing: the medians of the gaps between columns and between rows, through the rhythm as rows'
      spacing is; alignment (start, start)
    confidence = alignment (e = the largest edge distance from its cluster's median, limit 4)
               × gaps (e = the larger of the column gaps' and the row gaps' spread, limit 4)
               × sizes (e = the largest relative difference from the median, limit 0.2)
  a new card's inside (`new` = its children): a column only. The card's layout becomes that column; its leading and top
    padding are the design's card padding where that moves nothing more than 8 pt, else the insets as drawn; trailing
    and bottom are the card padding
  growing: a candidate that holds any member of a `grows` container holds them all, plus a new node, and is bigger
    (more members, or a grid over a row or column); it lists the container in `replacing`. `applying` opens replaced
    containers first, their members keeping their places on screen
  tidy: every arrangeable child is new; the column rule drops its gap check and its gap factor; the bar is 0.5; no limit
  ```

- [ ] **Step 1: Write the failing tests** in `StructureGridTests`. The images are `.fixed` and new unless the test says otherwise.
  - `fourBoxesMakeATwoColumnGrid`:
    - Images at (30, 300, 160, 120), (203, 300, 160, 120), (30, 436, 160, 120) and (203, 436, 160, 120).
    - One `.apply`: `.grid(columns: 2)`, with the members in reading order.
    - `columnSpacing` 12 (from 13), `rowSpacing` 16, and alignment (start, start).
    - Container frame (30, 300, 332, 256), confidence 1, movement 1.
  - `aGridGrowsFromItsRow`: a row R the pass made holds the top two images and is in `grows`. With the bottom two new, the result is one `.apply` grid of all four with `replacing == [R.id]`.
  - `aRowGrowsLonger`: R holds `[a, b]` and is in `grows`. A new `c` beside `b` gives a row `[a, b, c]` replacing R.
  - `aRowNotInGrowsIsLeftAlone`: the same with R not in `grows` gives nothing, since a row never takes a row (F5).
  - `aGrownStructureMustHoldAllOfIt`: a candidate holding one of R's members and a new node gives nothing.
  - `anLOfThreeIsNotAGrid`, and `aGridGrowsIntoAShortLastRow`: a growing 2 × 2 plus a new fifth image under its first column gives a 2-column grid of five.
  - `gridNearMisses`. Each case gives no grid:
    - cell sizes 30% apart;
    - a column edge 6 pt off;
    - two images in one cell's place.
  - `threeThingsInANewCardBecomeItsColumn`:
    - A new card at (20, 100, 353, 200) holds texts at local (16, 16, 200, 24), (16, 56, 200, 24) and (16, 96, 200, 24).
    - The result is `.apply(.cardColumn)`: the card's layout is `.stack(vertical, spacing 16, alignment .start)`, its padding 16 on every side, and movement 0.
  - `aCardsColumnKeepsTheInsetsAsDrawn`: with the texts at local x 30, the leading padding is 30 and the top 16.
  - `twoThingsInACardStayFree`: no decision.
  - `tidyingTheLoginMakesOneColumn`:
    - In tidy mode, a free iPhone root holds a title (20, 75, 353, 41), a button (20, 420, 353, 50) and an image (20, 500, 200, 200).
    - The result is one `.apply(column)`: spacing 32 (the rhythm's nearest to the median gap, 167) and alignment `.start`.
    - The frame is (20, 75, 353, 355): the button's minY is 148 and the image's 230.
    - The confidence is 0.6175.
  - `tidyingStillLeavesTheUntouchable` (F11): a locked image at (20, 720, 120, 100), below the login's image and between no two members, stays a root child, unchanged, and the column of three is built above it.
  - `applyingAGrowthOpensTheOldContainer`: the result holds the grid, not R, and every image keeps its id.

- [ ] **Step 2: Run them.** Run `StructureGridTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**

- [ ] **Step 4: Run them.** Run `StructureGridTests` and `StructureInferenceTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Structure inference: grids, a card's column, structures that grow as more is drawn, and tidying"`

---

### Task 7: "Did you mean" from the node's own bounds

**Lane:** A (after Task 5)

**Files:**
- Modify:
  - `Layer/Model/DesignStore+Sketch.swift`: `changeKind(of:to:fallback:adjust:)`;
  - `Layer/Sketch/SketchedNode.swift`: `remade`;
  - `Layer/Model/DesignStore.swift`: `changeKind(of:to:sketchedAt:adjust:)` becomes a wrapper, and `sketchedElement` is deleted (F1);
  - `Layer/App/AppModel.swift`: `acceptSuggestion`.
- Test: `LayerTests/DidYouMeanTests.swift`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  ```swift
  extension SketchedNode {
      /// `node` as `kind`, laid out afresh in its current parent from `node.sketch.originalBounds` (or `fallback`, screen
      /// points, when it has none). Its id, slot, name and lock are kept, and so are its words when both kinds show words.
      /// `takes`: what a new card encloses. Nil when it has neither bounds.
      static func remade(_ node: LayerNode, as kind: ElementKind, fallback: CGRect?, in content: TreeContent, index: TreeIndex) -> Made?
  }
  extension DesignStore {
      /// One change (call 13). A card becoming a leaf gives back what it held, where it was; a leaf becoming a card takes
      /// what it encloses. Its intent then says `.asked`, confidence 1. Nil when it is gone or not on a screen.
      @discardableResult
      func changeKind(of id: UUID, to kind: ElementKind, fallback: CGRect? = nil, adjust: (inout LayerNode) -> Void = { _ in }) -> UUID?
      // PROJECTION: deleted in plan 6
      @discardableResult func changeKind(of ref: ElementRef, to kind: ElementKind, sketchedAt sketch: CGRect,
                                         adjust: (inout DesignElement) -> Void = { _ in }) -> DesignElement?   // unchanged
  }
  ```

- [ ] **Step 1: Write the failing tests** in `DidYouMeanTests` (`@MainActor`):
  - `acceptingReLaysOutFromTheNodesOriginalBounds`:
    - A text field is sketched from (30, 300, 330, 44). It is offered as `KindSuggestion(…, kind: .button, sketch: .zero, …)`, so the suggestion's own rect is wrong.
    - Accepting gives a button whose frame equals a fresh `addSketched(.button, from: (30, 300, 330, 44), …)`'s.
  - `theIntentSaysThePersonChose`: after accepting, `decidedBy` is `.asked`, confidence 1, and `originalBounds` is unchanged.
  - `aNodeInACardIsReLaidInTheCard`: its parent is still the card, and its frame comes from the card's stand-in device.
  - `aCardThatBecomesAButtonGivesBackWhatItHeld`: its two texts are back in the card's slot, at unchanged screen frames.
  - `aButtonThatBecomesACardTakesWhatItEncloses`.
  - `theOfferStillLastsEightSeconds`: `AppModel.suggestionLifetime == .seconds(8)`, and it equals `StructureConventions.offerLifetime`.
  - `aCorrectionIsStillLogged`: `SketchReadingLog`'s entry records the corrected kind, as `CorrectedReadingTests` checks.

- [ ] **Step 2: Run them.** Run `DidYouMeanTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** `acceptSuggestion` calls `changeKind(of: suggestion.ref.element, to:, fallback: <suggestion.sketch in screen points>) { $0.adoptMarks(of: suggestion.observation) }`.

- [ ] **Step 4: Run them.** Run `DidYouMeanTests` and `CorrectedReadingTests`, which passes unchanged, then the full unit suite and the UI suite: accepting "Did you mean" is a UI path (F23). Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Did you mean: the node is laid out again from the sketch it remembers, in the container it is in"`

---

### Task 8: Structure fixtures, in the corpus's style

**Lane:** B (after Task 6; waits for Tasks 2 and 5, which lane B merges in from `feature/semantic-tree` first: F22)

**Files:**
- Modify:
  - `Tools/SketchBenchmarkHarness/Generate.swift`: structure fixtures written beside the 156;
  - `Tools/SketchBenchmarkHarness/Harness.swift`: a `structure <fixtures-dir>` mode;
  - `Tools/SketchBenchmarkHarness/run.sh`: adds `Layer/Model/ElementLayout.swift`, `Layer/Sketch/SketchedNode.swift` and `Layer/Debug/StructureBenchmark.swift`. `ElementLayout.swift` needs `Rotation.rotate`, `TurnedRect` and `DesignElement.shapeBounds`, which come as Task 2 settled (F26);
  - `Layer/Debug/SketchBenchmark.swift`: `SketchFixtureCorpus.load` also skips `structure-`.
- Create: `Layer/Debug/StructureBenchmark.swift`, `LayerTests/Fixtures/structure-*.json` (generated), `LayerTests/StructureFixtureTests.swift`
- Modify: `docs/benchmarks/semantic-tree.md` (a "Structure pass" section)

**Interfaces:**
- Consumes: `SketchSamples`, `SeededGenerator`, `SketchFixture.ExistingFixture`, `RuleInterpreter`, `SketchedNode` (Task 5) and `StructureInference` (Task 6).
- Produces:
  ```swift
  #if DEBUG
  struct StructureFixture: Codable, Sendable, Identifiable {
      enum Variant: String, Codable, Sendable { case clean, jittered, noisy, nearMiss }
      var id: String                     // "structure-row_clean_1"
      var label: String                  // "row", "column", "grid", "card", "none"
      var variant: Variant
      var screenSize: [Double]
      var existing: [SketchFixture.ExistingFixture]   // on the screen before the batch
      var sketches: [[[[Double]]]]       // one batch, in order: each sketch's strokes
      var expected: String               // "apply", "offer" or "none"
  }
  enum StructureBenchmark {
      static func load(from directory: URL) throws -> [StructureFixture]
      /// Each sketch is read by the rules, placed with `SketchedNode` on a free root built from `existing`, then the pass
      /// runs over the batch. Returns the structure kind found ("none" when there isn't one), the decision, and the pass's time.
      static func run(_ fixture: StructureFixture) -> (label: String, decision: String, passSeconds: Double)
  }
  #endif
  ```
- **The fixtures** number 32, drawn with `SketchSamples`' strokes and seeded jitter, like the corpus. Each holds things already on the screen (`existing`) and one batch of new sketches, using kinds that `ElementLayout.sketched` can put side by side. The counts per variant are fixed (F18):
  - rows (8): three bases (a sketched toggle beside an existing label, two half-width images, three avatars); 3 clean, 3 jittered (one of each base), 2 noisy (the toggle and the images);
  - columns (6): two bases (three wide boxes as text fields, four stacked-line bodies); 2 clean, 2 jittered, 2 noisy;
  - grids (6): two bases (2 × 2 and 2 × 3 half-width images); 2 clean, 2 jittered, 2 noisy;
  - cards (4): two bases, an outline round two existing texts and round three; 2 clean, 1 jittered (round two), 1 noisy (round three). A card fixture's label is "card" when the reading made a card holding everything enclosed, and its decision is that of the card's inside: "none" for two, "apply" (a column) for three;
  - near misses (8):
    - a title 120 pt above a button;
    - two texts 40 apart;
    - heights 2.5× apart;
    - a locked divider between two texts;
    - an L of three images;
    - a column edge 6 pt off;
    - an outline half over a text;
    - a lone text.

- [ ] **Step 1: Write the failing tests** in `StructureFixtureTests`:
  - `theStructureFixturesLoaded`: there are 32, and `SketchFixtureCorpus` still loads 156.
  - `cleanAndJitteredFixturesBecomeTheirStructure`: the label and the decision equal what each fixture expects.
  - `nearMissesNeverGroup`: every near miss gives "none".
  - `noisyFixturesAreNeverTheWrongStructure`: the label found is the expected one, or "none".
  - `printsTheStructureReport`: prints the counts, and the pass's p50 and p95, and asserts what it prints: 32 fixtures ran, and near misses grouped 0 (F24).

- [ ] **Step 2: Run them.** Run `StructureFixtureTests`. Expected: FAIL (no fixtures).

- [ ] **Step 3: Generate.**
  - Write the generator and `StructureBenchmark`.
  - Run `Tools/SketchBenchmarkHarness/run.sh generate LayerTests/Fixtures`.
  - `git status --porcelain LayerTests/Fixtures` must list only new `structure-` files: the 156 are byte for byte (call 16).

- [ ] **Step 4: Run them, and tune within the limits.** Run `StructureFixtureTests`.
  - If a fixture fails, tune only the builder's numbers: `reach`, and the card scores, by their constants in `SketchConventions` alone, re-running `CardReadingTests`, which names the constants (F17).
  - The spec's thresholds and bars don't move.
  - Record each change, with before and after counts, in the doc's new section.

  Expected: PASS.

- [ ] **Step 5: Run the harness.** `run.sh check` passes. `run.sh structure LayerTests/Fixtures` prints `structure: 32 fixtures, 32 as expected, near misses grouped 0` and the pass's p50 and p95. Record them in `docs/benchmarks/semantic-tree.md`, measured on a quiet machine, and say so in the ledger (F19). The simulator p50 and p95 that `printsTheStructureReport` prints are recorded the same way, in "Layer iPad Pro 11 (st2-lane-c)".

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Structure fixtures: rows, columns, grids, cards and near misses drawn in the corpus's style, run through the rules and the pass on macOS and in the simulator"`

---

### Task 9: The pass after a batch, its offer, and declines

**Lane:** A (after Task 7; waits for Tasks 3 and 6)

**Files:**
- Create: `Layer/Model/DesignStore+Structure.swift`, `Layer/App/AppModel+Structure.swift`
- Modify:
  - `Layer/App/AppModel.swift`: `convert` adds its node to the batch and ends the batch; `dropSelectionOfMissingThings` drops a stale offer; the kind suggestion's `place(of:)` reads the tree (`store.placed(_:)` and the index), so `dropSelectionOfMissingThings` never lowers the projection (F15). The stored state (`structureOffer`, the batch, the recorded values of the containers built) is declared in the class here; `AppModel+Structure.swift` holds the methods;
  - `Layer/Model/Groups.swift`: `ungroup` declines (Depends on plan 4, item 2);
  - `Layer/Model/DesignStore.swift`: the change pipeline declines a node moved out of a container the pass made, whichever verb moved it (call 11, F4);
  - `Layer/Chrome/SuggestionPill.swift`: shows the structure offer when no kind suggestion is up.
- Test: `LayerTests/StructurePassTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 5, 6 and 7, plan 2's `reconcile` and `update`, and plan 4's `placed(_:)`.
- Produces:
  ```swift
  extension DesignStore {
      /// One step's worth of change: `StructureInference.applying` committed through `reconcile`, then the container's
      /// SketchIntent (its frame on the screen as bounds, `.structure`, the structure's confidence). Nil when it can't be built.
      @discardableResult func build(_ structure: StructureInference.Structure) -> UUID?
      /// Marks the pass's refusal on each (call 11). Not an undo step.
      func declineStructure(_ ids: [UUID])
  }
  struct StructureOffer: Identifiable, Equatable {
      let id: UUID
      var structure: StructureInference.Structure
      var screen: TreeScreen.ID
  }
  extension AppModel {
      private(set) var structureOffer: StructureOffer?
      var shownStructureOffer: StructureOffer? { get }   // nil while a kind suggestion is up (call 12)
      func acceptStructureOffer()                         // own step: "Make Row", "Make Column" or "Make Grid"
      func declineStructureOffer()
      /// The pass over `nodes`' receiving containers (call 1); the batch's end calls it. Internal, for tests too.
      func structurePass(over nodes: [UUID])
  }
  ```
- **The pass:**
  - **The receiving containers** are each batch node's parent that is free and is either a screen root or a container with a `sketch`, plus every new card, whose children count as new.
  - **`grows`** holds the containers this model built in this session whose value (`LayerNode ==`, children included) is still the one it recorded after building (F10).
  - **Declines** (call 11, F4): the move-out check runs after a change that isn't an undo or a redo, and writes its marks outside that change's step, as `setTitle(undoable: false)` does. A container that is gone declines nothing this way, so growth and undo stay clean.
  - **`.apply` decisions** are built in order. An `.offer` decision is kept only if it beats the one already kept on confidence: one offer per pass.
  - **The batch** is the nodes made since the batch began. It ends at the commit of a conversion while no other group is in flight. The pass then runs inside that conversion's `act`, or as a step of its own if that conversion made nothing (call 1).
  - **The offer goes** when a member's place, parent or presence changes, or its screen's place does: the same check as for a kind suggestion. Accepting builds the structure with the rhythm's spacing.

- [ ] **Step 1: Write the failing tests** in `StructurePassTests` (`@MainActor`). Each uses an `AppModel` with an iPhone screen at (0, 0), scale 1, zoom 1, and an undo manager.
  - `aRowDrawnInOneBatchUndoesWithItsLastReading`:
    - `box 40 300 140 120 8; cross 40 300 140 120; box 213 300 140 120 8; cross 213 300 140 120` is converted as one batch.
    - The root's children are `[row]`, a `.stack(horizontal, spacing 12, .center)`, and `row.sketch.decidedBy == .structure`.
    - One undo leaves one image on the root at its frame, (30, 300, 160, 120) or (203, 300, 160, 120). A second undo leaves the root empty.
  - `aRaggedRowIsOfferedNotBuilt`:
    - Three 100 × 24 texts added by `store.add` at x 20, 124 and 254 (as in `aRaggedRowIsOffered`) go through `structurePass(over:)`.
    - The root is unchanged, `shownStructureOffer?.structure.title == "Make a row?"`, and no undo step was added.
    - `acceptStructureOffer()` builds the row as one step named "Make Row", with spacing 16 (the median gap, 17, on the rhythm: F6), and one undo puts all three back.
  - `decliningMarksThemAndTheyAreNeverOfferedAgain`:
    - After `declineStructureOffer()`, each member's `sketch?.structureDeclined` is true, and `undoManager.canUndo` is as before.
    - A second pass over them gives no offer.
  - `anUngroupedStructureIsDeclined`: after a built row is ungrouped with `store.ungroup`, its children are declined, and a pass makes nothing.
  - `takingOneOutOfARowDeclinesIt`: after `store.move(member, to: .screen(id))`, that member is declined. So is one taken out through `store.moveLayer(_:to:before:)` (the Layers panel), and one taken out by plan 4's lift dropped free (F4).
  - `undoingABuiltRowDeclinesNothing`: one undo of a built row returns its members to the root, and none is declined.
  - `theOfferGoesWhenAMemberIsDeletedOrMoved`: one case each for deleted, moved, resized, turned, reparented and the screen moved.
  - `aStructureOfferWaitsForTheKindSuggestion`: while a kind suggestion is up, `shownStructureOffer` is nil. After `dismissSuggestion()` it is the offer.
  - `lockedHiddenTurnedDrawnAndThePersonsAreNeverTouched`: a pass over a root holding a locked, a hidden, a turned and a declined text, and a free `.group` of two the person made, beside a new text, never lists one of them as a member. A drawing never sits on a screen (the rules move it to the canvas), so Task 1's `whatThePassMayTake` covers it (F11).
  - `aGridDrawnCellByCellIsOneGrid`:
    - The four cells of `fourBoxesMakeATwoColumnGrid` are drawn as `box … ; cross …` in four separate batches.
    - After the second there is a row. After the fourth, the root holds one grid of the four images, every image id unchanged, and no row.
  - `buildingAGridFromARowDeclinesNothing`.
  - `aPassLaysOutOnlyWhatItBuilt`: on a free screen of 100 nodes, one pass that builds a row raises `LayoutEngine.timesLaidOut` by at most 1 for the new row and for the root, and by 0 for every other container on the screen (F7).
  - `theSuggestionsPlaceIsReadFromTheTree` (F15): with a kind suggestion up, a tree-verb change elsewhere on the screen raises that screen's `TreeProjection.lowerings(of:)` by 0, the counter first shown to be live as plan 4's F11 does it.

- [ ] **Step 2: Run them.** Run `StructurePassTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `build` is `reconcile` plus `update`. After building, the model records the container's value.
  - The pill shows `shownStructureOffer` with the label "Make a row?" (or column or grid), and the hint "Lays these out as a row".
  - Its ✕ has the label "Keep them as drawn". It is placed under the members' union, from `TreeIndex.canvasShape` through the viewport (Depends on plan 4, item 3).

- [ ] **Step 4: Run them.** Run `StructurePassTests`, `SketchToNodeTests`, `GroupTests`, `CorrectedReadingTests` and `ConcurrentEditTests`, then the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Structure pass: after a batch settles it builds what it is sure of with the conversion, offers what it isn't, and never offers again what the person declined"`

---

### Task 10: Tidy is the structure pass, and ScreenTidy is gone

**Lane:** C (waits for Tasks 6 and 9, which lane C merges in from `feature/semantic-tree` first: F22)

**Files:**
- Create: `Layer/Model/DesignStore+Tidy.swift`
- Modify: `Layer/Voice/VoiceToolbox.swift` (`tidyScreen`; its words and the tool's description are unchanged)
- Delete: `Layer/Model/ScreenTidy.swift`
- Modify (fallout o, p): rename `LayerTests/ScreenTidyTests.swift` to `LayerTests/VoiceScreenLayoutTests.swift`:
  - retire the suite "Tidying a screen's layout" (o);
  - rewrite `VoiceScreenLayoutTests.tidyingLaysTheScreenOutAsOneUndoStep` (p).
- Test: `LayerTests/TidyTests.swift`

**Interfaces:**
- Consumes: Task 6's tidy mode, and Task 9's `build`.
- Produces:
  ```swift
  extension DesignStore {
      /// Voice's "tidy up" (§5, call 10): the pass in tidy mode over the screen's free root and its sketched free cards,
      /// every arrangeable child new, every container the pass made growing; each structure built. Inside the caller's
      /// step. False when nothing qualified.
      @discardableResult func tidy(_ screenID: TreeScreen.ID) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests** in `TidyTests`:
  - `tidyingTheLoginMakesOneColumn`:
    - The root's children are `[column]`, holding `[title, button, image]`.
    - Their minY values are 75, 148 and 230, and every minX is 20.
  - `aTidyScreenHasNothingLeftToTidy`: a second `tidy` returns false.
  - `aColumnScreenHasNothingToTidy`.
  - `tidyingLeavesTheUntouchableAlone`: a locked image stays a root child, where it was.

  Rewrite `tidyingLaysTheScreenOutAsOneUndoStep` (p):
  - The line stays "Tidied the layout of S1."
  - The login's root holds one column of `[title, button, image]`, with the button's minY 148 and the image's 230.
  - One undo restores `content` exactly.

- [ ] **Step 2: Run them.** Run `TidyTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `tidy`, and point `tidyScreen` at it. It answers "There is nothing on S1 that can be tidied." when `tidy` returns false. Then delete `ScreenTidy.swift` and retire its suite.
  - `grep -rn "ScreenTidy" Layer LayerTests Tools` finds nothing.
  - Record the 27 retired tests in the ledger under (o).

- [ ] **Step 4: Run them, and the suites that must pass unchanged.** Run `TidyTests` and `VoiceScreenLayoutTests`, then these, which must pass unchanged: `VoiceToolsTests` (its `tidyScreen` lines, the scope and "gone"), `VoiceAgentTests` (the tool list) and `PencilVoiceTests`. Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Tidy up: voice's tidying runs the structure pass and the engine lays out what it builds; ScreenTidy is removed"`

---

### Task 11: The first milestone, from a sketch

**Lane:** A (waits for Tasks 1–10)

**Files:**
- Create: `LayerTests/FirstMilestoneTests.swift`, `LayerTests/Fixtures/Designs/design-sketched-milestone.json` (recorded by the test in Step 3)
- Modify: `LayerUITests/SketchFlowUITests.swift` (`testASketchedCardAndGridExportAGridAndACard`)
- Modify: `LayerTests/GeneratedCodeExportTests.swift`, only if it lists its fixture designs by name

**Interfaces:**
- Consumes: everything above, plan 3's `SwiftUICodeGenerator.code(for:in:settings:)` and `Context`, and plan 2's `TreeManifest.encode`.
- Produces: no new API.

- [ ] **Step 1: Write the failing tests.** `FirstMilestoneTests.aCardAndAGridSketchedBecomeTheTreeAndItsCode` (`@MainActor`):
  - **Setup:** an `AppModel` with an iPhone screen at (0, 0), scale 1, and zoom 1. The strokes come from `StrokeScript`, and each batch is converted with `sketchChanged`, `convertNow()` and `await waitForConversions()`.
  - **Batch 1:** `wave 140 120 110 30 3`, converted, then `wave 30 170 330 34 4`, converted. They are two conversions, one after the other, because conversions in one batch commit in no fixed order (F12). The root's kinds are `[.title, .body]`.
  - **Batch 2:** `box 10 100 373 130 16`.
    - The root's kinds are `[.card]`, and the card's are `[.title, .body]`, with their ids unchanged.
    - The card's layout is nil.
  - **Batch 3:** `box 40 300 140 120 8; cross 40 300 140 120` and the same at (213, 300), (40, 440) and (213, 440).
    - The root's kinds are `[.card, .group]`.
    - The group's layout is `.grid(columns: 2, columnSpacing: 12, rowSpacing: 16)`, holding four `.image`s.
  - **The code:** the screen's code (`CodeSettings()`) contains these lines:
    - `Grid(horizontalSpacing: DesignTokens.rhythm[1], verticalSpacing: DesignTokens.rhythm[2]) {`;
    - `GridRow {` exactly twice;
    - `.background(.background.secondary, in: .rect(cornerRadius: DesignTokens.cardRadius))`;
    - `enum DesignTokens {` once.
  - **Recording:** with `TEST_RUNNER_LAYER_RECORD_DESIGN=<dir>` set, the test writes the version-4 manifest of `store.tree` as `design-sketched-milestone.json`.

  UI: `SketchFlowUITests.testASketchedCardAndGridExportAGridAndACard`, with the file's helpers:
  - Draw a screen and `convert()`.
  - Draw the two zigzags as above, with a `convert()` after each.
  - Draw the card's box and `convert()`.
  - Draw four boxes, each with its two crossing strokes, and `convert()`.
  - In Layers, "Card" and the grid's row are listed (Depends on plan 4, item 4).
  - In Code, a line containing `Grid(` and one containing `.background(.background.secondary` exist.

- [ ] **Step 2: Run them.** Run `FirstMilestoneTests`. Expected: PASS if Tasks 1–10 are right. A failure here is a bug in those tasks, never a change to the expected tree. Run the UI test.
  - The UI test must pass. If simulated touches can't make the readings (the memory notes on stuck touches and pixel checks), the test calls `XCTSkip` with the reason, and the ledger records it. It never joins the baseline set (F13).
  - The unit test stays the gate.

- [ ] **Step 3: Record the design.** Record `design-sketched-milestone.json` and commit it. Run `scripts/check-generated-swiftui.sh`: it prints `N files typecheck`, counting the new design, and exits 0.

- [ ] **Step 4: Run everything.** Run the full unit suite and the UI suite. Expected: TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "First milestone: a card drawn round two texts and a two-column grid become the tree at once and export as SwiftUI with Grid and the card's background"`

---

### Task 12: Measured, and the plan's finish

**Lane:** A (waits for every other task)

**Files:**
- Create: `LayerTests/SketchConversionBudgetTests.swift`
- Modify: `docs/benchmarks/semantic-tree.md` (the "After plan 5" column, and the reading row)

**Interfaces:**
- Consumes: everything above, `SketchFixtureCorpus`, `RuleInterpreter`, `StructureInference.neighbourhoodSizes(of:)` and `LayoutEngine.timesLaidOut(_:)` (F7).
- Produces: the measurements, and two always-on budget tests.

- [ ] **Step 1: Write the budget tests** in `SketchConversionBudgetTests`:
  - `aReadingLandsWithinBudget`:
    - The screen is a free iPhone screen of 100 sketched nodes: 25 rows of a text, a body, a toggle and a divider, each with an intent.
    - Each of the 156 fixtures placed `.onScreen` whose rules reading is an element is timed with `ContinuousClock`. The timing covers the rules' reading plus `asOwnStep { addSketched; structurePass(over: [id]) }`; an untimed undo follows.
    - The timing leaves out the 900 ms rest and the 750 ms re-trace, which are deliberate pauses.
    - The p95 is under 100 ms. While it is over, it is measured again, up to three times, and the test fails only if all three are (F19). It prints `BENCH sketch reading p50 p95` and `BENCH structure pass p50 p95`.
  - `thePassLooksOnlyAtTheReceivingContainer`:
    - Two such screens, and one reading on screen A.
    - The last entry of `neighbourhoodSizes(of:)` A's root is at most the number of A's root children within `reach` of the new node, plus 1.
    - `timesLaidOut` rises only for A's root and any container built, and by 0 for every container on screen B (F7).

- [ ] **Step 2: Run them.** Run `SketchConversionBudgetTests`. Expected: PASS. If the time fails, profile the conversion (the landing, `reconcile`, the pass, `TreeRules`) and fix it before going on: the budget is the spec's.

- [ ] **Step 3: Measure, and check the harnesses.**
  - Measure with no other lane or `xcodebuild` running, in "Layer iPad Pro 11 (st2-lane-c)" (19CD922B-1564-4FEF-A86A-4AF37B114B47), the simulator the baseline used, and record in the ledger that the machine was quiet (F19).
  - `SketchBenchmarkTests.printsTheFullBenchmarkReport` gives the rules' p95.
  - `Tools/SketchBenchmarkHarness/run.sh check`, `run.sh run LayerTests/Fixtures` (87.8%, 137/156) and `run.sh structure LayerTests/Fixtures` pass.
  - `run.sh run LayerTests/Fixtures --model` gives 89.1% (139/156) if Apple Intelligence answers on this Mac; otherwise say so.
  - `Tools/ScreenBenchmarkHarness/run.sh check` passes, with the new `Layer/Tree/` files.
  - Fill the reading row's "After plan 5" cell: the rules' p95, the conversion and pass p95, and the corpus numbers. Never record a better number than was measured.

- [ ] **Step 4: Verify the plan's end state.**
  - The full unit suite passes, and the UI suite fails nothing outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.
  - `grep -rn "ScreenTidy\|sketchedElement" Layer LayerTests Tools` finds nothing. Comments don't name either.
  - `grep -rln "PROJECTION: deleted in plan 6" Layer` lists plan 4's end-state set, as plan 4's ledger records it (with `SelectionLayer.swift` and `PhoneScreenView.swift`), plus `Layer/Model/DesignStore.swift`, for the two sketch wrappers, `addFloating` and `place(_:centeredAt:)` (F14, F15).
  - Record that exact list in the ledger for plan 6, naming `addFloating` and `place(_:centeredAt:)` (library drops) as the projection callers plan 6 must move. Plan 6's text gains a line naming `place(_:centeredAt:)` before it runs (F15).
  - Record in the ledger the iPad checks plan 6's checklist must carry:
    - Pencil latency while sketching rows and a grid cell by cell;
    - "Make a row?" offered and declined;
    - a card drawn round things;
    - a device change of a free screen.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Benchmarks after the sketch path: a reading with its structure pass within 100 ms, the pass local to its container, and the corpus as before"`

- [ ] **Step 6: Clean up.**
  - Delete the lane B and lane C worktrees and branches once merged.
  - Delete their simulators: `xcrun simctl delete "Layer iPad Pro 11 (st5-lane-b)"` and `"Layer iPad Pro 11 (st5-lane-c)"`.
  - Delete their DerivedData, and the harness binary `/tmp/SketchBenchmarkHarness`.

---

## Self-review against the spec

- **§5, where it lands:** the deepest visible, unlocked container under the centre is Task 5's `SketchLanding`. A free container uses `ElementLayout.sketched` with its siblings (Task 5); a laid-out one takes the nearest slot (Task 5); no container means the root, and off every screen means the canvas (Task 5).
- **§5, what it remembers:** all five fields of `SketchIntent` (Tasks 1 and 5); the placement rules (Task 1, call 8); "Did you mean" from `originalBounds`, still 8 seconds (Task 7).
- **§5, device changes:** each placement intent, column roots re-laid, and every path (Task 4).
- **§5, the structure pass:** the card drawn round things (Tasks 2 and 5); rows, columns and grids at the spec's thresholds (Tasks 3 and 6); confidence (call 4); auto-apply at 0.8 within 8 pt, then the exact median, then an offer (Task 3); the pill and its 8 seconds (Task 9); never touching what it mustn't (Tasks 1, 3 and 9); `structureDeclined` (Task 9); tidy (Task 10).
- **§5, when and where:** after the batch settles (call 1), local to the receiving container (Tasks 9 and 12).
- **§14:** the pass's rhythm and the card's padding come from the design's tokens (Tasks 3, 5 and 6).
- **My calls 6, 7, 15 and 16:** Global Constraints and Task 1; Task 4; `rowsAreReadLeftToRight` and the grids' reading order; `membersAreFixedAtTheirSize` and the movement rule.
- **Edge cases:** a sketch across an edge, locked or hidden containers, and a sketch over a row (Task 5); undoing a structure (Task 9); a smaller device (Task 4); a node deleted while its offer shows (Task 9).
- **Verification:** the structure tests, including near misses, movement capped at 8 pt, declines remembered and one undo step (Tasks 3, 6, 8 and 9); the first milestone end to end (Task 11).
- **Performance:** the reading's p95 under 100 ms with the pass (Task 12).
- **Constraints:** the corpus, the 87.8% and 89.1%, and `SketchHintTests` (Tasks 2 and 12); the harness builds (Tasks 2, 8 and 12).
- **Anti-goals:** nothing moves unasked by more than 8 pt (Review Focus 1); no model call or A2UI on a stroke (Global Constraints); no feature quietly lost: tidy stays useful (call 10) and `addElement`'s callers keep working (call 15).
- **Not in this plan:**
  - Siri's and voice's new tools (`groupElements`, `setLayout`, `ungroup`, `reorder`), their device choices of custom frames, and the projection's removal, all plan 6's. Plan 6's voice `ungroup` must decline as Task 9's does.
  - A model for structure (spec Non-goals).

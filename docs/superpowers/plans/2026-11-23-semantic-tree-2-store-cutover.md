# Semantic tree, plan 2 of 6: the store cutover. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the tree the only thing the app keeps, saves, undoes and edits. After this plan:
- `DesignStore.content` holds a `TreeContent`, and plan 1's rules (`TreeRules`) run inside every change, undo, redo and read;
- undo is the three-way per-property revert, on nodes in a parent's list;
- designs are saved and read as version 4, and older files are refused with the exact message;
- every caller not yet moved keeps working through a temporary **projection**: a flat, `DesignElement`-shaped view of the tree whose writes become tree edits;
- the store has the tree verbs plan 3 builds on;
- designs can hold custom device frames and design tokens (data only);
- the performance baseline is recorded on main first, and the same measurements run at the end.

**Architecture:** `DesignContent` keeps its name and API but becomes a thin wrapper round a stored `TreeContent`. Its old members read a lowered, flat copy of the tree and write through per-node edits or a host-at-a-time "lift". The projection's code lives in `Layer/Model/Projection/` and is deleted in plan 6. Pure tree code (undo records, tree edits, tokens) lives in `Layer/Tree/` and builds on macOS. The store memoises a `TreeIndex` and the lowered projection once per content version. The store verbs that rebuild structure (delete, duplicate, group, ungroup, arrange, layer moves, rehost, position) move onto the tree in this plan. Resize and turn stay on the projection with two guards until plan 4.

**Tech Stack:** Swift 6 (strict concurrency), `@Observable`, Swift Testing, XCUITest, XcodeGen, PencilKit (ink files only).

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read Approaches ("How the branch gets there"), §1–§3, §8, §10 (only where the store verbs are named), §12, §13, and My calls 15–21. Plan 1 (`docs/superpowers/plans/2026-11-23-semantic-tree-1-foundations.md`) is the source of every tree name used here.

**Starts when:** plan 1 is complete and merged into `feature/semantic-tree`. Its Task 13 recorded the UI baseline set in the ledger.
- **Exception, lane C:** Tasks 5 and 6 may start before plan 1's Tasks 11–13 finish. They run in `st2-lane-c`, cut from f306eed, which holds everything they consume.
- After plan 1's Tasks 11–13 and lane C have both merged, run the full unit suite. A new exhaustive `switch` on `DeviceFrame.Family` in that code would stop compiling.

## Pre-flight amendments 2026-11-23

The pre-flight scan is in `.superpowers/sdd/2026-11-23-semantic-tree-2-store-cutover/preflight.md`. The controller accepted every ruling, and each is written into the tasks below.

- **F1.** Lanes B and C are `st2-lane-b` and `st2-lane-c` (branches `st2/lane-b`, `st2/lane-c`), never plan 1's `st-lane-b` and `st-lane-c`.
- **F2.** Task 8 waits for Tasks 5 and 6, and consumes them.
- **F3.** `unreadCanvas` is Task 8's: it adds it to `TreeChange.board`, the revert, `takeBack` and the canvas tidy in `TreeRules`. Task 4 leaves it out.
- **F4.** Policy clause (f), the one list's order across hosts, covers four `FlatStoreTests` cases in Task 7.
- **F5.** Policy clause (g), call sites of a deleted or retyped API, covers more tests:
  - the SiriIntentsTests unwraps and the `rawOrder` test;
  - Task 8's table gains `aDrawingsInkIsSavedBesideTheDesignUnderItsIdentifier` and drops `elementsThatShareAnIdentifier…`;
  - `groupsSurviveTheFile` is expected to change;
  - `listed` keeps its default `isDownloaded:`.
- **F6.** "Unchanged" in a later task means as left by the changes already recorded in the ledger.
- **F7.** Suite names that are file names expand to their structs (table in the Global Constraints), and a run of 0 tests is a failure.
- **F8.** Layout counts use `LayoutEngine.timesLaidOut(id)`. `TreeProjection.lowerings` counts on the main thread only, and the tests that count `ListWork` or lowerings are `@MainActor` and synchronous.
- **F9.** `take(_:shown:)` writes only the fields that differ from `shown`, and never takes a container's kind from a `.group` element. W1 passes the raw lowering as `shown`.
- **F10.** The lift orders the non-drawings with `gathered`, and keeps each drawing at its index.
- **F11.** When the host's root isn't free, an origin written to a laid-out child is dropped. My call 20 applies exactly under a free root.
- **F12.** `CanvasSettings` writes its own unknown keys (Task 5), so `TreeContent` keeps them in the file.
- **F13.** Task 6 adds `DesignTokens.swift` (and `LookWords.swift`) to the harness scripts, and typechecks the sketch harness.
- **F14.** Task 1's and Task 12's measurements run on a quiet machine, in lane C's simulator. Lane C may run 5 → 6 → 1.
- **F15.** Task 3 shares today's flat operations instead of copying them. Task 4's copy of the list revert is temporary, and Task 7 deletes the original.
- **F16.** `plan1sMarginsAreUnchanged` is not a test. Step 4's `TreeRulesTests` run checks it.
- **F17.** Task 9 moves the card and rhythm numbers in `Layer/A2UI/` onto `DesignTokens.standard`.
- **F18.** Comments don't name the functions Task 12's grep looks for.
- **F19.** The `keepGroupsSound` rules are numbered as the code numbers them: rules 2, 3 and 5 go to `TreeRules`, and rules 1 and 4 to the lift.
- **F20.** Task 2 leaves `resolvedDevice` nil, and Task 9 sets it.
- **F21.** ScreenTidy's margin reads `device.margin`. The device-picker sentence is dropped.
- **F22.** A malformed custom frame is written back equal as JSON, not byte for byte.
- **F23.** The lift doesn't apply My call 20. Whole-host setters are bulk rewrites that the engine re-lays (recorded, accepted).
- **F24.** `undoAndRedoGoThroughTheTree` checks the leaves' frames within 1e-6.
- **F25.** `fieldListNamesEveryField`'s per-field loop skips `id`. When the field under test is `name`, the concurrent edit changes `isHidden`.

## Calls made in this plan

1. **`DesignContent` keeps its name, and wraps the tree.** It becomes `struct DesignContent { var tree: TreeContent; var pendingPointers }`, and every old member keeps its signature, implemented on the projection.
   - Why: 31 app files and 33 test files use `content.screens`, `store.floating`, `element(_:)`, `resolve(_:)`, `update(ref) {…}` and `apply { content in … }`. A new type would move every area in this plan, but the spec moves them one at a time in plans 3–6. Plan 6 deletes the wrapper.
2. **How the tree lowers to a flat list.**
   - Each host is lowered in **post-order block order**: a container's children's blocks first, back to front, then the container itself. That is today's "members, then the group item just in front" (`SiblingLists`).
   - Every container, a card included, lowers as a `.group` element. Its children point at it with `group`. A screen root is not lowered; its children have `group == nil`.
   - Screens are lowered in order, then the canvas.
   - Why: `Groups.swift`, `LayerOrder.swift`, the hit-testing and the Layers panel all read contiguous blocks and `group` pointers. Lowered this way, they work unchanged until plan 4 rebuilds them.
   - A card's look is not drawn through the projection. Plan 3, the first plan that makes cards, may draw it from the tree.
3. **Absolute poses, exactly.**
   - A lowered frame is the node's centre carried through its ancestors' translations and turns, its own size, and its summed angle. Containers never scale.
   - When every ancestor is upright, the frame is computed by adding origins, so integer frames stay exact. Through a turned ancestor, the frame goes through `transformToParent`.
   - On the canvas, every descendant shares its top-level node's `scale`.
   - Why: the spec's exactness argument (Approaches). One scale per canvas subtree is §1's model, so today's mixed-scale floating groups ("L5") become one scale, with the same size on the canvas.
4. **How writes come back.**
   - **Field and geometry edits** (`update`) go straight to the one node: an O(depth) path copy, counted once by `ListWork`. Drag frames depend on this.
   - **Structural flat edits** go through "lower, mutate, lift" on the affected host:
     - `add`, `remove`, `move` and `reorder`;
     - a changed `group` pointer;
     - the `screens` and `floating` setters, `setChildren` and `updateScreen`.

     These run today's flat logic on the host's lowered list, then lift it back. The lift reuses today's stray and gather rules.
   - **A pointer the tree can't hold yet** is kept in `pendingPointers` until the change ends. That covers a pointer to a group added later in the same change, to another host, or one that makes a loop. Then it is cut, as `keepGroupsSound` cut strays at the end of a change.
   - Why: `duplicate` adds members before their group, and `rehostGroup` moves the item and its members one at a time. Both are correct today only because the rules run at the end of the change.
5. **Writing a container's frame or angle depends on its layout.**
   - **A free container (B):** its children keep their places on screen, and the container is re-hugged by `TreeRules`. Old code always writes a free group's members alongside it (`TurnSession`, `resizeGroup`), so this makes the writes order-independent.
   - **A laid-out container (A):** it moves and turns whole, with its children. A size change sets `fixed` sizing, and the engine re-lays its children. Old code never writes a laid-out container's members once the Task 11 guards are in.
6. **My call 20, with one addition.** A frame written to a child of a row, column, grid or overlay works like this:
   - A size change sets `fixed` on the changed axis.
   - An origin change takes the child out to its host's root at that place: free, `fixed` on both axes, on top.
   - **Addition:** under a laid-out *screen root* there is nowhere to take a child out to, so an origin change is dropped and the engine lays it back. The drop's rehost to another host still works.
   - **Addition (F11):** the same holds for any laid-out child on a host whose root isn't free, a row's child in a column root included: its origin change is dropped. My call 20 applies exactly when the host's root is free.
   - **Not through the lift (F23):** frames written through a whole-host setter (`screens`, `floating`, `setChildren`) aren't put through this rule. Those setters are bulk rewrites, and the engine re-lays their laid-out children.
7. **The store verbs that rebuild structure move onto the tree in this plan.** That is delete, duplicate, group, ungroup, arrange, layer moves, rehost and position. Plan 3 adds rows, columns and cards to live designs, and pointer surgery would tear them apart: moving a row's leaves one by one would take each one out.
   - Resize and turn stay on the projection with two guards (Task 11): a laid-out container is one rigid part with no contents, and its frame is written in a several-things turn. Plan 4 rewrites both.
8. **What happens to the flat-list machinery:**
   - `keepGroupsSound()` becomes a shim that cuts pending pointers and runs `TreeRules.apply(to:after: nil)`. Its rules 2 (an empty group), 3 (a group of one) and 5 (the box) are now `TreeRules`; rules 1 (strays) and 4 (the gather) are now the lift. These are the numbers in `Groups.swift`'s comment (F19).
   - `fitGroupBoxes`, `dissolveHollowGroups`, `ungroupStrays` and `gatherMembers` are deleted (Task 7).
   - `gathered` moves into `TreeLift` (Task 3).
   - `rawOrder` is deleted when arrange moves (Task 11).
   - `SiblingLists` stays only for `layerTree(on:)`, reading the projection, until plan 4 rebuilds the Layers panel.
9. **Undo records are node fields without children, plus the parent, merged per field.**
   - Order within a parent is restored by today's predecessor rule, list by list.
   - When a node's parent differs among current, after and before, its frame and angle are merged as **host poses**, then put back into its parent's space. Without this, undoing a regroup after a drag would make the node jump.
   - A node whose parent is gone lands on the canvas where it was (today's `rehostElementsOnMissingScreens`).
10. **The file moves in two steps.**
    - Task 7 keeps version 3 through the projection: a "v3 bridge", plus a temporary `legacyUnread`. This keeps the cutover's test fallout to the projection.
    - Task 8 switches to version 4 and deletes the bridge, the v1–v3 readers and `drawing.data` adoption.
    - `DesignFile.ReadError` becomes a typealias of `TreeManifest.ReadError`, and `DesignFile.currentVersion == 4`.
    - `TreeContent` gains `unreadCanvas`. Today one unknown kind among the canvas's nodes makes the whole file unreadable, which breaks §12.
11. **`TreeRules` runs on read**, inside `DesignFile(wrapper:)` and `DesignFile.content(at:)`, off the main actor (My call 18). It runs inside the store's `change` after the body, and after undo and redo. Its diagnostics are not used in plan 2.
12. **The memo.** A `TreeIndex` and a `TreeProjection.Lowered` are kept per content version, each built lazily, and replace `Views` and `index`.
    - `keptTargets` stays until plan 4, because it memoises the hit-test walk, which plan 4 rewrites. Its counter tests pass unchanged.
    - `TreeIndex` stops folding a screen's lock into its nodes. Today a locked screen's elements stay editable; plan 1 folds the lock in.
13. **The counters.**
    - `ListWork` moves to `Layer/Tree/ListWork.swift`. `elementsWritten` now counts **nodes** written by store verbs and projection writes, and the engine's frames are not counted.
    - The engine's work is counted by plan 1's `LayoutEngine` counters. Tests read `timesLaidOut(id)` per container, not the global `containersLaidOut` (F8).
    - `CanvasWork`, `LayersPanelWork` and `CodeWork` are unchanged, because their producers still read the projection.
    - One assertion lowers: a group drag now writes the group alone (60 writes, not 240).
14. **Custom device frames (the user's scope addition, data only).**
    - `DeviceFrame` becomes `Codable`. It gains:
      - leading and trailing safe insets;
      - `hasStatusBar`;
      - the `watch` and `other` families;
      - two layout tokens: `margin`, which defaults by family (20, 32, 48, 8, 20), and `maxContentWidth` (1080 on a desktop, else nil).
    - A design keeps `CanvasSettings.customDevices`. Lookup goes through `CanvasSettings.device(named:)`: built-ins, then custom frames, then the iPhone.
    - `TreeRules` resolves screens through the design's settings, and reads `margin` and `maxContentWidth` instead of literals.
    - The projected `DesignScreen` carries its resolved device, so old code sees custom frames.
    - A custom frame that can't be read is kept raw and written back, and its screens use the iPhone.
    - UI is plan 4's, and code export is plan 3's.
15. **Design tokens (the user's scope addition).**
    - `DesignTokens` is stored in `CanvasSettings.tokens`. It holds the rhythm, corner radii, the card's padding, radius and fill, and the text sizes. Its defaults are today's numbers.
    - `DesignTokens.standard` becomes the one source of plan 1's literals for text sizes, the card and the rhythm.
    - Per-design use starts where it is a one-line change: Task 9's Group as Card pads from the design's tokens. Plans 3 and 5 pass tokens to generation and the structure pass.
16. **The test-fallout policy** (Global Constraints). A failing test may change only under a named clause, and every other failure is a bug.
17. **The baseline is measured on main through a temporary worktree.** It uses a store-change unit benchmark written against today's API only, so the same file measures main now and the branch in Task 12.

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding files, and commit `Layer.xcodeproj/project.pbxproj` with the task.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text. The projection lives in `Layer/Model/Projection/`, never in `Layer/Tree/`.
- **Type names:** every new type that could clash with SwiftUI is nested in `LayerNode`: `LayerNode.Layout`, `.Stack`, `.Grid`, `.Alignment`, `.Padding`, `.Sizing`.
- **Every `xcodebuild` command** (in this plan, in scripts and in docs) passes `-skipPackagePluginValidation`, and `-skipMacroValidation` too if plan 1's ledger says so.
- **Limits:**
  - tree depth 32;
  - 5,000 nodes per design;
  - grid columns 1–12.
- **Layer's numbers:**
  - rhythm 8, 12, 16, 24, 32;
  - margins 20 (phone), 32 (tablet), 48 (desktop), and new: 8 (watch), 20 (other);
  - desktop column at most 1080;
  - card: radius 16, padding 16, fill `RGBColor(hex: 0xF2F2F7)`.

  From Task 6 these are `DesignTokens.standard` and the devices' tokens.
- **The file:**
  - Version is 4, and `design.json` is encoded with `.sortedKeys`.
  - The older-version message is exactly: `This design was made by an earlier version of Layer and can't be opened by this one.`
  - The newer-version message stays exactly: `This design was saved by a newer version of Layer. Update Layer to open it.`
- **Undo semantics stay.**
  - Every step is a three-way, per-property revert of only its own changes.
  - Gestures, Format runs, voice commands and generations each stay one step.
  - These stay: `putOnTop`, `markNeedsSaving`, `onlyScreen(changedBy:)`, withdrawing steps that change nothing, and the cap of 50.
- **Ids are stable.** No verb or projection write changes a node's id, except duplicate, which makes new ones.
- **No layout in a SwiftUI `body`**, and no whole-tree layout on an edit. Layout runs only in `TreeRules`, in the store's change, on read, and off the main actor before a commit.
- **Projection code** carries the comment `// PROJECTION: deleted in plan 6` on every type and extension that exists only for it.
- **Green.** After every task:
  - the app builds;
  - the full unit suite passes;
  - the UI suite fails no test outside plan 1's recorded baseline set (spec My call 19).

  The UI suite runs in Tasks 7, 8, 10, 11 and 12. The other tasks add code that no UI path reaches.
- **The test-fallout policy.** A test written before this plan may be changed or retired only if it asserts one of these:
  - (a) the v1–v3 file or its readers: the JSON keys `elements` or `floating`, a top-level `canvas` object of settings, `drawing.data`, or a version below 4;
  - (b) a flat-list state the tree can't hold:
    - a group pointer to a missing group, a group on another host, or a group that makes a loop;
    - a drawing inside a group's block;
    - a group item that isn't just in front of its members;
  - (c) members of one canvas group at different scales;
  - (d) a write count the tree lowers, such as a container moved as one write instead of one write per member;
  - (e) floating-point noise below 1e-9 from composing transforms through a turned container. Switch to the file's `close` helper, or add one with tolerance 1e-6;
  - (f) the order of the one flat list across hosts (which host's elements come first in `content.elements`), which the tree doesn't hold. Only the whole-list lines change, to per-host order, and per-host assertions stay (F4);
  - (g) a call site of an API this plan deletes or retypes, when the assertion is kept (for example a `try #require` unwrap), or is carried over by a test the task names (F5).
  - (h) a container box rounded to whole points: the engine fits a free container's box out to whole points (spec §4), where the flat list fitted a group's box exactly, so a turned group's box differs by up to a point and a turn and back drifts by up to two. A box is compared within 1 pt and a turn-and-back's frames within 2 pt. Plan 4's group-turn rewrite restores exact equality (Task 7 ruling).

  Each change is listed in its task, or recorded in the ledger with its clause. Every other failure is a bug to fix, not a test to change.
- **"Unchanged" (F6).** When a later task says a suite passes unchanged, it means as left by the changes already recorded in the ledger under this policy.
- **Counters (F8).** Tests never assert exact values of a global counter that other suites also raise while they run in parallel:
  - Layout is counted with `LayoutEngine.timesLaidOut(id)`, summed over the test design's own containers.
  - `ListWork` and `TreeProjection.lowerings` count on the main thread only, and tests that assert on them are `@MainActor` and synchronous.
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
  - **Suite names (F7).** Where this plan names a test file rather than a suite struct, run every struct below with `-only-testing:LayerTests/<Struct>`. A run that executes 0 tests counts as a failure.

    | Name in this plan | Structs to run |
    |---|---|
    | DesignTests | ElementLayoutTests, ViewportTests, DesignStoreTests, AppModelTests, DesignFileTests, CodeGenerationTests, SymbolCatalogTests, DesignFileNameTests, CloudFileTests, ResourceTests, ClosingTests, FormatPanelEditTests, FileCheckTests, TurnedCodeTests |
    | MultiSelectionTests | SeveralThingsSelectedTests, LiningUpTests, EnclosureTests, PickedByALoopTests, SeveralThingsChangedTogetherTests, SeveralThingsOnTheCanvasTests, TapToAddTests, CanvasDragTests, PencilOnChromeTests |
    | CanvasHitTestTests | HiddenHitTestTests, InkOverAnElementTests, CanvasFocusTests, PaletteAndTypingTests, GlideAndFingerTests, PaletteStateInTestsTests, SelectionAreaTapTests |
    | RotationTests | RotationGeometryTests, TurnedThingsOnTheBoardTests, TurningOneElementTests, TurningSeveralThingsTests, RotationFieldTests, TwistTests, TwistOnTheInkCanvasTests |
    | FormatPanelTests | TypingIntoTheFormatPanelTests, ScrubbingAFieldTests, PanelChangesBesideADragTests, PanelOriginTests, NumberDraftTests, and the file's other `@Suite` structs |
    | LayersPanelTests | LayersPanelWorkTests, and the file's other `@Suite` structs |
    | SiriIntentsTests | ScreenBlueprintTests, EntityKeyTests, ColourTests, DesignLibraryTests, DesignIndexTests, OpeningDesignTests, DesignActionTests, ImagePlaygroundTests, StrokeScriptTests, LookWordTests, MovingTests |
    | ScreenGenerationTests | ScreenStreamParsingTests, ScreenPromptTests, SketchHintTests, ScreenGenerationLifecycleTests |
    | DrawingTests | DrawingElementTests, DrawingSyncTests, DrawingStoreTests, DrawingFileTests, TurnedDrawingTests, MagicPenPutAwayTests, InkFollowedAtTheEndTests |
    | FreeformTests | SettingsTests, FreeformBehaviourTests, MoreMagicPenTests, MoreCodeTests, ScrubbingTests |
    | MagicPenComponentTests | InnerMarkTests, SmallControlTests, SketchedLayoutTests, NewControlCodeTests |
    | ZoomRulerTests | ZoomStopsTests |
    | HostedModelTests | ModelChoiceTests, and the file's other `@Suite` structs |
    | PerformanceTests | the XCTest classes DesignIndexerPerformanceTests and DesignFilePerformanceTests |
    | GroupTests | GroupModelTests, GroupCommandTests ("Group commands"), SelectingGroupsTests, GroupGeometryTests ("Group geometry"), GroupAsOneThingTests ("A group as one thing"), LayerTreeTests |

  - **Lanes B and C** run in their own worktrees (`.claude/worktrees/st2-lane-b`, `.claude/worktrees/st2-lane-c`). Their branches are `st2/lane-b` and `st2/lane-c`, cut from `feature/semantic-tree` when plan 2 starts (lane C may be cut from f306eed; see Starts when).
    - They are never plan 1's `st-lane-b` and `st-lane-c` worktrees or `st/lane-*` branches (F1).
    - Their commands are the same with:
      - simulator `Layer iPad Pro 11 (st2-lane-b)` or `Layer iPad Pro 11 (st2-lane-c)`, each cloned from `iPad Pro 11-inch (M5)`;
      - DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st2-lane-b` or `-st2-lane-c`.
  - A lane's task is reviewed, then merged into `feature/semantic-tree`. Resolve `project.pbxproj` conflicts by re-running `xcodegen generate`.
  - When the plan ends, delete the lane worktrees, their simulators and their DerivedData. Lane C's simulator stays until Task 12 has measured in it (F14).
- **Measuring (F14).** Task 1 Steps 3–4 and Task 12 Step 3 run only while no other lane or `xcodebuild` is running. Record in the ledger that the machine was quiet. Both workouts run in lane C's simulator.
- **Comments (F18).** Comments and doc comments don't name the functions Task 12's grep looks for, so "the slot rule arrange used" rather than "rawOrder".

## Review Focus

1. **Undo among concurrent edits on the tree.**
   - Per-field revert must hold, including `content` and `style` sub-fields.
   - A regroup must undo back to the place on screen another edit left.
   - Orphans must land where they were.
   - Steps by others must survive.
   - Owned by:
     - Task 4: `aStepsOwnFieldGoesBackAndAnothersStays`, `aReparentGoesBackToWhereAnotherEditLeftIt`, `aNodeWhoseParentIsGoneLandsOnTheCanvasWhereItWas`, `fieldListNamesEveryField`;
     - Task 7: `ConcurrentEditTests`, unchanged.
2. **The projection's exactness.**
   - Integer frames under upright containers round-trip exactly.
   - A write moves only the node written.
   - A free container's turn leaves its children in place.
   - `lift(lower(x)) == x`.
   - Owned by:
     - Task 2: `absolutePosesAddUpTranslationsExactly`, `absolutePosesTurnWithTheirContainerAndNeverScale`;
     - Task 3: `writingAMembersFrameMovesOnlyIt`, `aFreeContainersTurnKeepsItsChildrenWhereTheyAre`, `aHostSetWholeAsItIsChangesNothing`.
3. **Laid-out containers reached by old code.**
   - My call 20 applies to their children.
   - The column-root exception applies.
   - Rows move, resize and turn as one.
   - Owned by:
     - Task 3: `aSizeWrittenToARowChildFixesThatAxis`, `aPositionWrittenToARowChildTakesItOut`, `aPositionWrittenToAColumnRootsChildIsLaidBack`;
     - Task 11: `aRowDraggedMovesWhole`, `aRowTurnedAloneSetsOnlyItsAngle`, `aGroupHoldingARowResizesTheRowAsOnePiece`.
4. **Refused and damaged input.**
   - Older and newer files must be refused with their exact messages.
   - Unknown kinds must be kept at their place on the canvas and in containers.
   - Duplicate ids must not trap.
   - Malformed custom frames must be kept but not used.
   - Siri and Spotlight must skip refused files.
   - Owned by:
     - Task 8: `anOlderDesignIsRefusedWithItsMessage`, `anUnknownKindOnTheCanvasIsKeptAtItsPlace`, `aFileWithTwoNodesOfOneIDOpensAndSavesBoth`, `siriAndSpotlightSkipADesignTheyCannotOpen`;
     - Task 5: `aMalformedCustomFrameIsKeptButNotUsed`.
5. **The cost of a change.**
   - A drag frame writes one node, and lays out only its screen's dirty path.
   - A store change on 100 nodes has p95 under 16 ms.
   - The canvas workout is within 5% of main.
   - Owned by:
     - Task 11: `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves` (60 writes);
     - Task 12: `aLeafDragLaysOutOnlyItsDirtyPath`, `aStoreChangeOnAHundredNodeScreenIsWithinBudget`, and the workout recorded in `docs/benchmarks/semantic-tree.md`.

**Order and lanes:**
- Lane A: Tasks 2, 3, 7, 8, 9, 10, 11, 12.
- Lane B: Task 4.
- Lane C: Tasks 1, 5, 6. They may run as 5 → 6 → 1, so that Task 1 measures on a quiet machine (F14).
- Waits:
  - Task 7 waits for Tasks 1–4 to be merged.
  - Task 8 waits for Tasks 5 and 6 to be merged (F2).
  - Task 9 waits for Tasks 5 and 6.
  - Task 12 waits for everything.

---

### Task 1: The baseline, measured on main

**Lane:** C. It must be committed before Task 7 begins. It may come after Tasks 5 and 6 so that it measures on a quiet machine (F14).

**Files:**
- Create: `LayerTests/StoreChangeBenchmarkTests.swift`. It uses today's API only, so the same file builds on main and on the branch.
- Create: `docs/benchmarks/semantic-tree.md`

**Interfaces:**
- Consumes:
  - today's `DesignStore` API: `addScreen(_:at:)`, `setElements(_:on:replacing:)`, `update(_:_:)` and `delete(_:)`;
  - `CanvasBenchmarkUITests.testCanvasWorkout`;
  - the p50 and p95 of plan 1's `TreeRulesTests.oneEditOnAHundredNodeScreenIsQuick`, from its ledger: at 130a4f1 they are p50 0.957 ms and p95 1.292 ms (task-7-report).
- Produces:
  - `@Suite struct StoreChangeBenchmarkTests`, enabled only when `ProcessInfo.processInfo.environment["LAYER_BENCHMARK"] != nil`;
  - `docs/benchmarks/semantic-tree.md`, with the spec §13 table and a filled "Before" column.

- [ ] **Step 1: Write the benchmark** in `StoreChangeBenchmarkTests`, test `aStoreChangeOnAHundredElementScreen`.
  - The screen is an iPhone with 100 elements, in 25 rows (`y = 60 + 80·row`). Each row holds:
    - a text at (20, y, 228, 24);
    - a body at (20, y + 28, 353, 40);
    - a toggle at (322, y, 51, 31);
    - a divider at (20, y + 72, 353, 1).
  - It times 50 runs of each with `ContinuousClock`:
    - **move:** `update(ref) { $0.frame.origin.x += 1 }`;
    - **resize:** `$0.frame.size.width += 1`;
    - **text:** `$0.text += "a"`;
    - **add:** one text added with `setElements([text], on:, replacing: false)`, then deleted.
  - It prints `BENCH store <op> p50=<ms> p95=<ms>` for each op.
  - It asserts that every p95 is finite and under 1,000 ms. That is a sanity bound, not the budget.

- [ ] **Step 2: Make a temporary worktree of main.**
  - Run `git worktree add --detach .claude/worktrees/st2-bench-main main` and record `git -C .claude/worktrees/st2-bench-main rev-parse HEAD`. It was 8d00fc7 when this plan was written.
  - Copy the benchmark file in, and run `xcodegen generate` there.

- [ ] **Step 3: Run the unit benchmark on main.**
  - Steps 3 and 4 run only while no other lane or `xcodebuild` is running. Record that in the ledger (F14).
  - Use lane C's simulator, with DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st2-bench-main`.
  - Run `TEST_RUNNER_LAYER_BENCHMARK=1` plus the test command with `-only-testing:LayerTests/StoreChangeBenchmarkTests`.
  - Expected: TEST SUCCEEDED, with four `BENCH` lines. Record them.

- [ ] **Step 4: Run the canvas workout on main.**
  - Run `TEST_RUNNER_LAYER_BENCHMARK=1 xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan Layer -configuration Release -destination "platform=iOS Simulator,name=Layer iPad Pro 11 (st2-lane-c)" -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Layer-st2-bench-main-release" -skipPackagePluginValidation -only-testing:LayerUITests/CanvasBenchmarkUITests/testCanvasWorkout`.
  - Record CPU time, peak physical memory and clock time: each average and relative standard deviation, as XCTest prints them.

- [ ] **Step 5: Write `docs/benchmarks/semantic-tree.md`.**
  - The table has the columns What | How | Budget | Before (main `<hash>`) | After plan 2 | After plan 6.
  - Its rows are spec §13's.
  - "Before" holds:
    - the four store-change p50 and p95 values;
    - the workout's CPU, memory and clock;
    - today's drag counters: a 60-frame drag of a group of three writes 240 elements, and a line drag writes 60 (`CanvasDragWorkTests`);
    - plan 1's rules p50 and p95 for one edit on a 100-node screen.
  - The "After" cells are "—". One line under the table gives the simulator, Xcode version and date.

- [ ] **Step 6: Clean up.** Remove the temporary worktree and both of its DerivedData folders. On the branch, run `StoreChangeBenchmarkTests` without the variable. Expected: the test is skipped, and the build succeeds.

- [ ] **Step 7: Commit.** `git add -A && git commit -m "Benchmarks: the semantic tree's baseline on main, with a store-change benchmark that runs on both"`

---

### Task 2: The projection, reading

**Lane:** A

**Files:**
- Create: `Layer/Model/Projection/TreeProjection.swift`, `Layer/Model/Projection/ElementConversion.swift`
- Test: `LayerTests/TreeProjectionTests.swift`

**Interfaces:**
- Consumes:
  - `LayerNode`, `TreeContent`, `TreeScreen` and `transformToParent` (plan 1);
  - `TreeIndex.Host` (plan 1);
  - `DesignElement`, `DesignScreen`, `FloatingElement` and `Rotation.kept` (today).
- Produces:
  ```swift
  // PROJECTION: deleted in plan 6
  extension LayerNode {
      /// What an element says, as a node. A `.group` element becomes a free container sized to fit (both axes);
      /// a leaf is `.fixed` on both axes. The frame is the element's, as given.
      init(element: DesignElement)
      /// `element`'s mapped fields written over this node; tree-only fields kept (F9). Every mapped field is written
      /// only where `element` differs from `shown`, this node's own lowering; for lock and hide that is today's
      /// `DesignContent.written(_:over:groups:)` rule. With `shown` nil (a new node) every field is written. A
      /// container's kind is never taken from a `.group` element: a card stays a card. A tint equal to the
      /// lowered one leaves `style.tint` as it is, nil included.
      mutating func take(_ element: DesignElement, shown: DesignElement?)
  }
  extension DesignElement {
      init(node: LayerNode, frame: CGRect, rotation: Double?, parent: DesignScreen.ID?, scale: CGFloat?, group: UUID?)
  }
  enum TreeProjection {
      struct Pose: Equatable, Sendable { var frame: CGRect; var rotation: Double?; var scale: CGFloat? }
      struct Lowered: Sendable {
          var elements: [DesignElement]           // raw: own flags, containers as .group items, block order
          var screens: [DesignScreen]             // views: leaves only, shown flags; resolvedDevice left nil here, Task 9 sets it (F20)
          var floating: [FloatingElement]         // views
          var position: [UUID: Int]               // index in `elements`, first wins
          func children(of host: DesignScreen.ID?) -> [DesignElement]
      }
      static func lower(_ content: TreeContent, pending: [UUID: UUID] = [:]) -> Lowered
      static func lowerHost(_ host: TreeIndex.Host, in content: TreeContent, pending: [UUID: UUID] = [:]) -> [DesignElement]
      /// A node's pose in its host's points (canvas: its top-level node's own points) and that node's scale.
      static func pose(of id: UUID, in content: TreeContent) -> Pose?
      #if DEBUG
      static var lowerings: Int { get }       // whole-design lowerings; counted on the main thread only, as ListWork is (F8)
      #endif
  }
  ```
- **The field mapping:**

  | `DesignElement` | `LayerNode` |
  |---|---|
  | `id`, `kind`, `name`, `isLocked`, `isHidden`, `unknownKeys` | the same. A container lowers as `.group` |
  | `text`, `symbol`, `shape`, `imageID`, `isOn`, `value`, `buttonLook`, `ink` | `content.*` |
  | `tint` | `style.tint ?? kind.spec.tint` |
  | `fontSize`, `fontWeight`, `textColor`, `cornerRadius`, `opacity`, `textAlignment`, `borderColor`, `borderWidth`, `hasShadow` | `style.*` |
  | `parent`, `scale`, `frame`, `rotation`, `group` | derived: host, top-level scale (canvas only), absolute pose, nearest container ancestor (or `pending[id]`) |

- **The lowering:**
  - **Order** is block order, per host:

    ```swift
    func emit(_ node: LayerNode, group: UUID?) {          // the root's children are emitted with group nil
        for child in node.children { emit(child, group: node.id) }
        list.append(element(for: node, group: pending[node.id] ?? group))
    }
    ```

    Unread children are not lowered.
  - **Poses** are composed top-down: the absolute centre comes from the parent's transform, the size stays the node's own, and the angle is the sum, through `Rotation.kept`.
    - Upright chains add origins.
    - On the canvas, the top-level node's `scale` is left out of the transform and reported as each descendant's `scale`.
  - **Flags:** raw elements carry their own flags. View elements OR in their container ancestors' flags, but never the screen's lock. Work them out in the lowering's own walk: until Task 9, `TreeIndex.isLockedWithAncestors` folds the screen's lock in.
  - **Screens:** each view `DesignScreen` copies the screen's fields and `unknownKeys`. Its `elements` are the leaves of its host.

- [ ] **Step 1: Write the failing tests** in `TreeProjectionTests`:
  - `aScreensLeavesAreItsElementsInDrawingOrder`:
    - A free root holds a title at (20, 80, 228, 40) and an image at (200, 140, 160, 120).
    - The screen's view has kinds `[.title, .image]`, with those exact frames.
  - `aContainerIsAGroupItemJustInFrontOfItsChildren`:
    - Root children are `[A, G[B, C], D]`.
    - The raw ids are `[A, B, C, G, D]`.
    - `B.group == G.id`, `G.group == nil` and `G.kind == .group`.
    - The view holds `[A, B, C, D]`.
  - `aCardLowersAsAGroupItem`: a card holding a text lowers as `.group`, and the text points at it.
  - `absolutePosesAddUpTranslationsExactly`: G is free at (100, 200, 50, 50) with a child at (10, 20, 30, 40). The child lowers to exactly (110, 220, 30, 40).
  - `absolutePosesTurnWithTheirContainerAndNeverScale`:
    - G is at (100, 100, 200, 100), turned 90, with a 20×20 child at (0, 0).
    - The child's centre is (240, 60) within 1e-9.
    - Its size is 20×20 and its rotation is 90.
  - `canvasDescendantsShareTheirTopLevelsScale`: a canvas group at (100, 100, 200, 200) with scale 0.5 holds a child at (10, 10, 40, 40). The floating element has frame (110, 110, 40, 40) and scale 0.5.
  - `shownFlagsComeFromContainersButNotTheScreen`:
    - A locked group's child is locked in the view and unlocked in the raw list.
    - A leaf on a locked screen is unlocked in both.
  - `screensComeFirstThenTheCanvas`: the raw list holds screen 1's nodes, then screen 2's, then the canvas's.
  - `aLeafRoundTripsThroughAnElement`:
    - An element has every `DesignElement` field set, ink included.
    - `DesignElement(node: LayerNode(element: e), frame: e.frame, rotation: e.rotation, parent: e.parent, scale: e.scale, group: e.group) == e`.
  - `aNodeWithoutATintTakesItsKindsTint`: a button node with `style.tint == nil` lowers with `tint == ElementKind.button.spec.tint`.
  - `aPendingPointerIsLoweredAsTheGroup`: for a top-level X, `lower(content, pending: [X: G])` gives `X.group == G`.
  - `takingAnUnchangedElementChangesNothing` (F9):
    - A card, and a button whose `style.tint` is nil, each take their own lowering with `shown` set to it.
    - Each node is unchanged: the card is still `.card`, and the tint is still nil.

- [ ] **Step 2: Run them.** Run `TreeProjectionTests`. Expected: FAIL (the types don't exist).

- [ ] **Step 3: Implement** the conversions and `TreeProjection`.

- [ ] **Step 4: Run them.** Run `TreeProjectionTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Projection: the tree lowered to today's flat list, block by block, with absolute poses and shown flags"`

---

### Task 3: The projection, writing

**Lane:** A

**Files:**
- Create: `Layer/Model/Projection/TreeLift.swift`, `Layer/Model/Projection/TreeProjection+Writes.swift`
- Create: `Layer/Tree/ListWork.swift`. `ListWork` moves here from `Layer/Document/DesignFile.swift`.
- Modify:
  - `Layer/Document/DesignFile.swift`: remove `ListWork`. Today's flat list operations that W5 runs (the reorder slot logic, `placed(on:scale:)`) become shared static helpers on `[DesignElement]`, which `DesignContent` and the projection both call. Don't copy them (F15).
  - `Layer/Model/Groups.swift`: `gathered` moves to `TreeLift.gathered`, and `gatherMembers` calls it.
- Test: `LayerTests/TreeProjectionWriteTests.swift`. Tests that assert on `ListWork` are `@MainActor` and synchronous, because `ListWork` counts on the main thread only (F8).

**Interfaces:**
- Consumes: Task 2, `LayoutEngine` (plan 1), `TreeRules` (plan 1, used in tests only)
- Produces:
  ```swift
  // PROJECTION: deleted in plan 6
  enum TreeLift {
      /// Today's gather (Groups.swift rule 4), moved unchanged. It is given the non-drawings, as today.
      static func gathered(_ things: [DesignElement]) -> [DesignElement.ID]
      /// A host's flat list as its top-level nodes. Pointers it can't honour now are returned in `pending`.
      static func nodes(from elements: [DesignElement], host: TreeIndex.Host, keeping content: TreeContent)
          -> (nodes: [LayerNode], pending: [UUID: UUID])
  }
  extension TreeContent {
      mutating func projectedUpdate(_ id: UUID, pending: inout [UUID: UUID], _ body: (inout DesignElement) -> Void)
      @discardableResult
      mutating func projectedAdd(_ element: DesignElement, to host: DesignScreen.ID?, scale: CGFloat?,
                                 pending: inout [UUID: UUID]) -> DesignElement
      mutating func projectedRemove(_ ids: Set<UUID>, pending: inout [UUID: UUID])
      mutating func projectedMove(_ id: UUID, to host: DesignScreen.ID?, scale: CGFloat?, frame: CGRect,
                                  pending: inout [UUID: UUID])
      mutating func projectedReorder(_ host: DesignScreen.ID?, to order: [UUID], pending: inout [UUID: UUID])
      mutating func projectedSetHost(_ host: DesignScreen.ID?, to elements: [DesignElement], pending: inout [UUID: UUID])
  }
  #if DEBUG
  enum ListWork {   // Layer/Tree: counts nodes written by store verbs and projection writes, on the main thread
      static var elementsWritten: Int { get }
      static func wrote(_ count: Int = 1)
  }
  #endif
  ```
- **The write rules:**
  - **W1. Fields.** `projectedUpdate` lowers the node raw, runs `body`, and restores `id`, `parent` and `scale`. If nothing changed it returns. Otherwise it writes each changed mapped field onto the node with `take(_:shown:)`, with `shown` set to the raw lowering it started from (F9), and calls `ListWork.wrote()` once.
  - **W2. Geometry under a free parent** (a free container, a free screen root, or the canvas top level). The new absolute pose goes into the parent's space through the inverse of the parent's host transform, and the angle becomes absolute minus the parent's summed angle.
    - If the node is a **free container (B)**, each child's absolute pose is recorded first and put back after, so nothing in it moves.
    - If it is a **laid-out container (A)**, its children ride along. A size change sets `.fixed` on the changed axes.
  - **W3. Geometry under a laid-out parent** (My call 20):
    - **Origin changed, host's root free (or on the canvas), parent not a screen root:** the node goes to the end of its host's root children, or of the canvas's top level. It keeps its absolute pose, and becomes `.fixed` on both axes.
    - **Origin changed when the host's root isn't free:** the origin is dropped, and the engine lays the node back. That covers the laid-out root's own children and any deeper laid-out child, such as a row's child in a column root (F11).
    - **Size changed:** `.fixed` on each changed axis, with the new size.
    - **Angle:** absolute minus the parent's summed angle.

    W2's container rule then applies to the node itself.
  - **W4. Pointers.** A changed `group` goes through W5 with the element replaced in its host's list.
  - **W5. Structural edits.** The host or hosts are lowered raw, then today's flat code runs on the list, then the lift (W6) runs:
    - `add` appends, with `placed(on:scale:)`;
    - `remove` takes out only the listed ids;
    - `move` takes it out of the old host and appends it to the new one;
    - `reorder` uses today's slot logic;
    - `setHost` replaces the list.

    `ListWork` counts them as today's flat operations did: one per add or move, the number removed, the slots changed, and nothing for a whole-host set.
  - **W6. The lift** (`TreeLift.nodes`):
    1. **Valid pointers.** `e.group` is kept when it names a `.group` element in the list, `e` isn't a drawing, and following pointers from it never comes back to `e`. Any other non-nil pointer that isn't a drawing's goes to `pending`.
    2. **Order** is `gathered` over the list's non-drawings, with only valid pointers. Each drawing keeps its slot in the list, which is today's slot rule for drawings. On the canvas it therefore stays between the same top-level nodes (F10).
    3. **Nodes.** Each is `content`'s node with that id, with its children emptied, or else `LayerNode(element:)`. Then `take(e, shown: <the shown element of that id in content's lowering>)`, which writes only what differs (F9).
    4. **Nesting.** Each node is appended to its valid parent's children, in order. Those with no valid parent are the top level.
    5. **Geometry**, top-down: each child's local pose is its absolute pose seen from its parent's absolute pose (as in W2). A canvas child whose element `scale` differs from its top-level node's has its frame converted through canvas points into that scale, so its size scales.
    6. Containers new to the tree are free, and fit on both axes.

    Pending pointers whose target now exists in the same host are honoured in step 1. `pending` loses every id the lift honoured.

    The lift doesn't apply W3 (My call 20). A laid-out child whose frame comes through a whole-host set is re-laid by the engine (F23).

- [ ] **Step 1: Write the failing tests** in `TreeProjectionWriteTests`. Leaves are fixed unless the test says otherwise.
  - `writingAFieldWritesOnlyThatNode`:
    - Set a text node's `text`.
    - `ListWork.elementsWritten` rises by exactly 1.
    - The node's `width`, `sketch` and `source` are unchanged.
  - `writingAMembersFrameMovesOnlyIt`:
    - G is free at (100, 200, 200, 200), holding X at (10, 20, 30, 40) and Y.
    - Writing X's frame as (130, 250, 30, 40) gives X a local frame of (30, 50, 30, 40). Y is unchanged.
  - `aFreeContainersTurnKeepsItsChildrenWhereTheyAre`: writing G's rotation as 30 makes `G.rotation == 30`, and each child's lowered frame and rotation are unchanged within 1e-9.
  - `aLaidOutContainerMovesWithItsChildren`: a row at (40, 200) written at origin (60, 200) has its local origin at (60, 200), and its children's local frames are unchanged.
  - `aSizeWrittenToARowChildFixesThatAxis`:
    - A row child with width `.fit` is written 120 wide, at the same origin.
    - `width == .fixed`, `frame.width == 120`, and the height's mode is unchanged.
  - `aPositionWrittenToARowChildTakesItOut`:
    - The row is inside a free root. A child is written at origin (5, 5).
    - Its parent is now the screen root, and it is the root's last child.
    - Its lowered frame starts at (5, 5), and it is `.fixed` on both axes.
  - `aPositionWrittenToAColumnRootsChildIsLaidBack`: after the write and `TreeRules.apply(to:after:)`, the child is still the root's child, with the frame it had before.
  - `aPositionWrittenToARowChildInAColumnRootStaysInTheRow` (F11): after the write and `TreeRules.apply(to:after:)`, the text is still the row's child, with the frame it had before.
  - `aDrawingKeepsItsPlaceThroughTheLift` (F10): for the canvas `[note, drawing, G[a, b]]`, `projectedSetHost(nil, to: <its raw lowering>)` keeps the drawing at index 1 among the canvas's nodes, between the note and G.
  - `aGroupPointerWriteGathersAsTheListDid`:
    - Root children are `[A, B, C, D, E]`. In one sequence, G is added, then `B.group = G` and `D.group = G`.
    - The raw ids are `[A, C, B, D, G, E]`, and G's children are `[B, D]`.
  - `membersAddedBeforeTheirGroupJoinItWhenItComes`:
    - Copies B′ and D′ point at G′, which doesn't exist yet. Then G′ is added.
    - B′ and D′ are G′'s children, and `pending` is empty.
  - `aClearedPointerTakesTheFrontmostOutInFront`: in G[B, D], clearing `D.group` gives the raw ids `[B, G, D]`.
  - `pointersTheTreeCantHoldWait`:
    - A pointer to a missing id, to a leaf, to a group on another host, or one that makes a loop leaves the node at the top level, with its pointer in `pending`.
    - A drawing's pointer is dropped, and never kept in `pending`.
  - `removingAContainerThroughTheListLeavesItsChildren`: removing only G leaves B and D at G's slot, at their absolute frames, with pointers in `pending`.
  - `aHostSetWholeAsItIsChangesNothing`: for a tree with nested free groups, sizing, sketch intents and a turned group, `projectedSetHost` with its own raw lowering leaves the tree equal (`lift(lower(x)) == x`).
  - `aMemberAtAnotherScaleJoinsAtItsGroupsScale`:
    - A canvas group has scale 0.5. A member whose element has scale 1 and frame (0, 0, 100, 100) joins it.
    - The member's stored size is 200×200, its canvas size is unchanged, and its lowered `scale` is 0.5.
  - `aStructuralEditCountsAsTheListDid`: removing two elements adds 2 to `ListWork`, and setting a host whole adds 0.

- [ ] **Step 2: Run them.** Run `TreeProjectionWriteTests`. Expected: FAIL.

- [ ] **Step 3: Move `ListWork`**, and move `gathered`, which `gatherMembers` now calls. Run `CanvasDragWorkTests` and `GroupTests`. Expected: PASS, unchanged.

- [ ] **Step 4: Implement** `TreeLift` and the `projected…` writes.

- [ ] **Step 5: Run them.** Run `TreeProjectionWriteTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Projection: flat writes become tree edits, one node at a time or a host lifted whole, with pointers kept until a change ends"`

---

### Task 4: Undo on the tree

**Lane:** B

**Files:**
- Create: `Layer/Tree/TreeRevert.swift`, `Layer/Tree/TreeChange.swift`
- Test: `LayerTests/TreeRevertTests.swift`

**Interfaces:**
- Consumes: `LayerNode`, `TreeContent`, `TreeScreen`, `TreeIndex` and `transformToParent` (plan 1)
- Produces:
  ```swift
  extension LayerNode {
      /// Every field but `children`, three-way: a field the step changed goes back unless changed since.
      /// `content` and `style` are merged per sub-field. A field missing here makes undo restore the whole node.
      static func reverting(_ current: LayerNode, after: LayerNode, to before: LayerNode) -> LayerNode
      /// The names `reverting` covers, as `Mirror` labels: "kind", "content.text", "style.tint", …
      static let revertedFields: Set<String>
  }
  extension TreeScreen {
      /// Its own fields and its root's own fields (layout, padding, name, flags, …), never the root's children.
      static func reverting(_ current: TreeScreen, after: TreeScreen, to before: TreeScreen) -> TreeScreen
  }
  extension TreeContent {
      /// The change `before`→`after` taken back from this content, and only that change.
      func reverting(_ after: TreeContent, to before: TreeContent) -> TreeContent
      /// Siri's late undo: takes back what the change did as far as each thing is still as the change left it.
      mutating func takeBack(_ after: TreeContent, to before: TreeContent)
  }
  struct TreeChange: Sendable {           // today's DesignStore.Touched, on the tree
      var nodes: Set<UUID> = []; var screens: Set<TreeScreen.ID> = []; var board = false
      init()
      init(from before: TreeContent, to after: TreeContent)
      mutating func formUnion(_ other: TreeChange)
      func meets(_ other: TreeChange) -> Bool
      /// The host of every node in `content`, for `onlyScreen`.
      static func hosts(in content: TreeContent) -> [UUID: TreeIndex.Host]
  }
  ```
- **What it does:**
  - A **record** is a node's fields without children, its parent key (`.node(id)`, which includes a screen root's id, or `.canvas`), and its host pose from `TreeIndex`.
  - **`TreeChange`:**
    - `nodes` are the ids whose record differs. A pure reorder touches nothing, as today.
    - `screens` are the screens whose record differs, plus the hosts a node was added to, removed from or moved between.
    - `board` is a change to the title, the settings, `unknownKeys` or `manifestUnknownKeys`. Task 8 adds `unreadCanvas`, which doesn't exist yet (F3).
- **The revert** (`reverting(after, to: before)`) is today's algorithm (`DesignContent.reverting`, DesignFile.swift:293–368), generalised:

  ```
  if self == after { return before }
  title: back only if it is still the one the step gave. Settings and unknown keys: whole, as today.
  screens: today's list algorithm on screen records (TreeScreen.reverting), the root's children left out.
  R = records of self
  for id added by the step (in after, not before): remove from R
  for id in before, in before's pre-order:
      a = after[id], b = before[id]
      if a == nil:              R[id] = b                                 // removed by the step: back as it was
      else if a != b, R[id] != nil:
          R[id] = merge(R[id], a, b)                                      // per field, parent included
          if the parents of R[id], a and b aren't all one: frame and angle are merged as host poses,
             and the result is put into its result parent's space after step 5
      // altered by the step and since removed by another: stays away
  order: for each parent P in R, start from self's order of the ids R puts under P.
      For each id in before's list of P (in order) that was moved, restored, or reparented back to P:
      take it out, and put it just after the nearest earlier id of before's P-list still in P, or first.
      "Moved" = in both before's and after's P-lists, with a different predecessor among those in both (today's rule).
  orphans: a record whose parent isn't in the result goes to the canvas's top level, last. Its canvas pose is
      taken from self, else before, through the screen's placement then; its scale is that screen's. A record whose
      result parents would form a loop: the one later in before's pre-order is an orphan.
  rebuild: from each screen root and the canvas, top-down, children in their result order. Poses merged as
      host poses go into their parent's space now.
  ```

  `takeBack` follows today's `DesignContent.takeBack` (DesignFile.swift:388–440), with records in place of elements:
  - a record goes back to before's only if its current record equals after's;
  - an added node goes only if it is unchanged since;
  - a removed node comes back where it was, if its parent is still there;
  - screens go back the same way, and an added screen goes only once it is empty;
  - an order goes back only if it is still after's.
- **A temporary duplicate (F15).** This lane may write its own version of the generic list revert (DesignFile.swift:308) in `Layer/Tree/`, beside today's. Task 7 deletes today's, and reviewers accept the duplicate until then.

- [ ] **Step 1: Write the failing tests** in `TreeRevertTests`:
  - `fieldListNamesEveryField`:
    - `Mirror` over a `LayerNode` whose fields are all set, and over its `content` and `style`, gives labels (prefixed `content.` and `style.`, `children` excluded).
    - Every label is in `LayerNode.revertedFields`.
    - For each field, a step changing only that field, with another edit changing `name` since, reverts that field and keeps the new `name`. If it restored the whole node, the test fails and names the field.
    - The per-field loop skips `id`, because a changed id is a removal and an addition. When the field under test is `name`, the other edit changes `isHidden` instead. Both are still in the label check (F25).
  - `aStepsOwnFieldGoesBackAndAnothersStays`:
    - Before: text "A", frame (0, 0, 10, 10).
    - The step changes the text to "B". Another edit then changes the frame to (5, 5, 10, 10).
    - The revert has text "A" and frame (5, 5, 10, 10).
  - `anAddedNodeGoesAndARemovedOneComesBackWhereItWas`:
    - Before: root `[A, B, C]`. After: `[A, C, D]`. Current: `[A, C, D, E]`.
    - The revert is `[A, B, C, E]`.
  - `aReorderGoesBackAmongWhatWasAddedSince`:
    - Before: `[A, B, C]`. The step reorders to `[C, A, B]`. Another edit then adds D: `[C, A, B, D]`.
    - The revert is `[A, B, C, D]`.
  - `aReparentGoesBackToWhereAnotherEditLeftIt`:
    - Before: X on a free root at (50, 50, 10, 10).
    - The step moves X into G at (40, 40, 30, 30), at local (10, 10, 10, 10).
    - Another edit then drags X to local (20, 20, 10, 10), which is host (60, 60).
    - The revert puts X on the root at (60, 60, 10, 10).
  - `aNodeWhoseParentIsGoneLandsOnTheCanvasWhereItWas`:
    - The step added screen S, at origin (1000, 0) and scale 0.5. Another edit then put N on S's root at (10, 10, 20, 20).
    - The revert has no S. N is the canvas's last node, with frame (2010, 10, 20, 20) and scale 0.5.
  - `revertingWithNothingElseChangedGivesBefore`.
  - `twoParentsRevertedIntoEachOtherMakeNoLoop`: the result's index reaches every node once, and no node is its own ancestor.
  - `aScreenRootsLayoutGoesBackWithItsScreen`:
    - The step sets the root's layout to a vertical stack. Another edit then adds a child.
    - The revert has layout `nil` and the new child kept.
  - `takingBackLeavesWhatChangedSince`:
    - Before: A has text "x". The change sets A's text to "y", removes E, and adds B.
    - Since then, C was added and A's frame was moved.
    - `takeBack` leaves A as it is now (text "y", moved), because its record isn't after's. It removes B, brings E back where it was, and keeps C.
  - `touchedNamesNodesScreensAndTheBoard`:
    - Changing N's text on screen S touches nodes `{N}` and no screen.
    - Moving N to screen T touches `{N}` and screens `{S, T}`.
    - Renaming the board sets `board`.
  - `aReorderAloneTouchesNothing`.

- [ ] **Step 2: Run them.** Run `TreeRevertTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `TreeRevert.swift` and `TreeChange.swift`.

- [ ] **Step 4: Run them.** Run `TreeRevertTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Undo on the tree: node records reverted per field among others' changes, reparents through host poses, orphans to the canvas"`

---

### Task 5: Custom device frames, and each device's layout tokens

**Lane:** C (after Task 1)

**Files:**
- Modify: `Layer/Model/Design.swift`. It changes:
  - `DeviceFrame` becomes `Codable`, gains new fields and the families `watch` and `other`;
  - `CanvasSettings` gains `customDevices`, `unreadDevices` and `device(named:)`, and `sketchDevice` goes through `device(named:)`;
  - `CanvasSettings` gets its own `encode(to:)`, which leaves out an empty `customDevices` and writes the settings' unknown keys itself, as `TreeScreen` does. Then `TreeContent`, which encodes the settings unwrapped, keeps them in the file (F12);
  - `DesignScreen.resolvedDevice` is added.
- Modify: every exhaustive `switch` on `DeviceFrame.Family` (`Layer/Model/ScreenTidy.swift`, `Layer/Tree/TreeRules.swift`, `Family.name`, and any others the compiler finds). `watch` and `other` behave as `phone`, except for margins: ScreenTidy's margin reads `device.margin`, which equals today's numbers for every built-in (F21).
- Modify: `Layer/Tree/TreeRules.swift`. The changes:
  - screens resolve through `content.device(of:)`, both when padding a root and when deciding whether a screen's device changed since `previous`;
  - `margin(for:)` returns `device.margin`;
  - the column limit reads `device.maxContentWidth`.
- Create: `Layer/Tree/TreeContent+Devices.swift`
- Test: `LayerTests/DeviceFrameTests.swift`

**Interfaces:**
- Consumes: `TreeRules`, `TreeScreen.keepRootToDevice()` and `TreeManifest` (plan 1)
- Produces:
  ```swift
  struct DeviceFrame: Identifiable, Equatable, Sendable, Codable {
      let id: String; let name: String; let size: CGSize
      let safeTop: CGFloat; let safeBottom: CGFloat
      var safeLeading: CGFloat; var safeTrailing: CGFloat          // default 0
      let cornerRadius: CGFloat
      var hasStatusBar: Bool                                       // default: phone, tablet, other
      let hasIsland: Bool; let hasHomeIndicator: Bool
      var family: Family
      var margin: CGFloat                                          // token; default family.defaultMargin
      var maxContentWidth: CGFloat?                                // token; default 1080 for desktop, else nil
      var unknownKeys: UnknownKeys
      enum Family: String, CaseIterable, Sendable, Codable {
          case phone, tablet, desktop, watch, other
          var defaultMargin: CGFloat                               // 20, 32, 48, 8, 20
      }
      /// Today's memberwise parameters, with the new ones defaulted from the family:
      /// the built-in table doesn't change.
      init(id:name:size:safeTop:safeBottom:cornerRadius:hasIsland:hasHomeIndicator:family:
           safeLeading:safeTrailing:hasStatusBar:margin:maxContentWidth:)
      var isCustom: Bool { get }                                   // id has the prefix "custom-"
      static func custom(name: String, size: CGSize, family: Family) -> DeviceFrame   // id "custom-<uuid>"
      static func named(_ id: String?) -> DeviceFrame             // built-ins only, as today
      static func named(_ id: String?, among custom: [DeviceFrame]) -> DeviceFrame   // built-in, custom, iPhone
  }
  extension CanvasSettings {
      var customDevices: [DeviceFrame]      // coded as "customDevices"; omitted when empty
      var unreadDevices: [JSONValue]        // custom frames this build can't read, written back after the others
      func device(named id: String?) -> DeviceFrame
  }
  extension DesignScreen {
      var resolvedDevice: DeviceFrame?      // not coded; set by the projection (Task 9). `device` returns it ?? .named(deviceID)
  }
  extension TreeContent { func device(of screen: TreeScreen) -> DeviceFrame }      // settings.device(named:)
  extension TreeScreen { mutating func keepRootToDevice(_ device: DeviceFrame) }
  ```
- **Reading a custom frame:**
  - It is unreadable, and kept in `unreadDevices`, when any of these hold:
    - its `id` doesn't have the prefix `custom-`, or is a built-in's id, or repeats an earlier custom frame's id;
    - a side of `size` isn't finite and positive.
  - Insets that aren't finite, or are negative, read as 0.
  - A `margin` that isn't finite, or is negative, reads as the family's default.
  - A `maxContentWidth` of 0 or less reads as nil.
  - An unknown family reads as `.other`.
  - Unknown keys are kept.
- **`TreeRules`:**
  - Every apply keeps each root to `content.device(of:)`.
  - A column root's padding is:
    - top: `safeTop + margin`;
    - bottom: `safeBottom + margin`;
    - leading: `safeLeading + margin`;
    - trailing: `safeTrailing + margin`.
  - The sides widen to keep the content at most `maxContentWidth`, centred.

- [ ] **Step 1: Write the failing tests** in `DeviceFrameTests`:
  - `builtInsKeepTheirSizesAndTakeTheirFamiliesTokens`:
    - Every built-in's `size` and safe insets are as today.
    - The iPhone's margin is 20 and the iPad's 32.
    - The MacBook Air's margin is 48, and its `maxContentWidth` is 1080.
    - The iPhone's `maxContentWidth` is nil, and its `hasStatusBar` is true.
  - `aCustomFrameRoundTripsInTheDesign`:
    - A `TreeContent` holds a custom watch frame of 198×242, with margin 8, safe insets 10/10/4/4 and no status bar.
    - `TreeManifest.decode(TreeManifest.encode(…))` gives back equal settings.
  - `aScreenOnACustomFrameIsKeptToItsSize`: after `TreeRules.apply(to:after: nil)`, the root's frame is (0, 0, 198, 242).
  - `aCustomFramesMarginIsUsed`:
    - The custom frame has margin 12 and `safeTop` 30, and a column root holds a text.
    - The text's minX is 12 + `safeLeading`, and its minY is 30 + 12.
  - `aCustomFramesMaxContentWidthLimitsTheColumn`: on a 1600-wide frame with `maxContentWidth` 900, a fill-width child is 900 wide, centred.
  - Plan 1's margins are unchanged. This is not a test to write: Step 4 runs `TreeRulesTests`, whose `aColumnRootIsInsetBySafeAreasAndMargin` must pass unchanged (F16).
  - `anUnknownDeviceIDFallsBackToTheIPhone`.
  - `aSettingThisBuildDoesNotKnowSurvivesTheFile` (F12): settings with an unknown key `"hologram": {"x": 1}` survive `TreeManifest.decode(TreeManifest.encode(…))`.
  - `aMalformedCustomFrameIsKeptButNotUsed`:
    - A frame with size `[0, -5]` lands in `unreadDevices`, and is written back equal as JSON (`JSONValue ==`, not byte for byte) (F22).
    - A screen naming it is iPhone-sized after the rules.
  - `aCustomFrameCantTakeABuiltInsID`.
  - `theSketchDeviceCanBeCustom`: with `sketchDeviceID` set to the custom id, `settings.sketchDevice` is the custom frame.
  - `aProjectedScreenUsesItsResolvedDevice`: a `DesignScreen` with `resolvedDevice` set reports that device from `device`.

- [ ] **Step 2: Run them.** Run `DeviceFrameTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the changes. Keep the built-in table's call sites unchanged.

- [ ] **Step 4: Run them.** Run `DeviceFrameTests`, `TreeRulesTests`, `ScreenTidyTests` and `FormatPanelTests` (its structs, per F7), then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Devices: custom device frames kept with the design, every frame's margin and widest column as tokens the rules read"`

---

### Task 6: Design tokens

**Lane:** C (after Task 5)

**Files:**
- Create: `Layer/Tree/DesignTokens.swift`
- Modify:
  - `Layer/Model/Design.swift`: `CanvasSettings.tokens`, coded as `"tokens"`;
  - `Layer/Tree/NaturalSize.swift`: font sizes come from `DesignTokens.standard.textSizes`;
  - `Layer/Components/Catalogue.swift`: `card`'s radius and tint come from `DesignTokens.standard.card`;
  - `Layer/Tree/Outline.swift`: a card's padding comes from `DesignTokens.standard.card.padding`;
  - `Layer/Model/ElementLayout.swift`: `rhythm` reads `DesignTokens.standard.rhythm`;
  - `Tools/SketchBenchmarkHarness/run.sh` and `Tools/ScreenBenchmarkHarness/run.sh`: compile `Layer/Tree/DesignTokens.swift`, because `Design.swift` and `Catalogue.swift` now need it. The screen harness also gets the missing `Layer/Tree/LookWords.swift` (F13).
- Test: `LayerTests/DesignTokensTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct DesignTokens: Equatable, Sendable, Codable {
      struct CornerRadii: Equatable, Sendable, Codable { var small: CGFloat = 8; var medium: CGFloat = 12; var large: CGFloat = 16 }
      struct Card: Equatable, Sendable, Codable { var padding: CGFloat = 16; var radius: CGFloat = 16; var fill = RGBColor(hex: 0xF2F2F7) }
      struct TextSizes: Equatable, Sendable, Codable { var title: CGFloat = 28; var body: CGFloat = 15; var text: CGFloat = 17 }
      var rhythm: [CGFloat] = [8, 12, 16, 24, 32]
      var cornerRadii = CornerRadii(); var card = Card(); var textSizes = TextSizes()
      var unknownKeys = UnknownKeys()
      static let standard = DesignTokens()
  }
  extension CanvasSettings { var tokens: DesignTokens }   // omitted from the file when standard
  ```
- **Reading:**
  - Every number that isn't finite, or is 0 or less, reads as the standard's.
  - `rhythm` is sorted, made unique, and keeps only its finite, positive entries. If none are left, it reads as the standard's.
  - A missing `tokens` reads as `.standard`. Unknown keys are kept: `DesignTokens` writes its own, as `CanvasSettings` does from Task 5 (F12).

- [ ] **Step 1: Write the failing tests** in `DesignTokensTests`:
  - `theStandardTokensAreTodaysNumbers`:
    - The values are those in the Interfaces.
    - `NaturalSize.fontSize(of: LayerNode(kind: .title)) == DesignTokens.standard.textSizes.title`, and likewise for body and text.
    - `ElementKind.card.spec.cornerRadius == .points(16)`, and `ElementLayout.rhythm == DesignTokens.standard.rhythm`.
  - `tokensRoundTripInTheDesign`: tokens with rhythm `[4, 8]` and card padding 20 survive `TreeManifest` encode and decode.
  - `aDesignWithoutTokensGetsTheStandardOnes`.
  - `badTokenNumbersReadAsTheStandardOnes`:
    - Card padding −1 reads as 16.
    - A rhythm of `[16, 8, 8, -2]` reads as `[8, 16]`, and `[]` reads as the standard.
  - `unknownTokenKeysSurvive`.

- [ ] **Step 2: Run them.** Run `DesignTokensTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the type and the setting, and point plan 1's literals at `standard`.

- [ ] **Step 4: Run them.**
  - Run `DesignTokensTests`, `TextMeasureTests`, `OutlineTests`, `ComponentCatalogueTests`, `ScreenGenerationTests` (including `SketchHintTests`) and `DesignTests` (their structs, per F7), then the full unit suite. Expected: PASS, and TEST SUCCEEDED. The prompts and the ComponentKinds golden are unchanged.
  - Typecheck the sketch harness: its `run.sh` source list, run through `swiftc -typecheck -D DEBUG -parse-as-library -target arm64-apple-macos27.0`. Expected: no errors, and no binary written (F13).

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Design tokens: one editable set per design, saved with it, today's numbers as the standard that plan 1's constants now read"`

---

### Task 7: The cutover: the store holds the tree

**Lane:** A (waits for Tasks 1–4 to be merged)

**Files:**
- Modify: `Layer/Document/DesignFile.swift`. `DesignContent` is rebuilt on the tree, with every member on the projection. Its `Codable` becomes the v3 bridge: lower and encode, decode and lift.
- Modify: `Layer/Model/DesignStore.swift`. It gets:
  - a memo of the index and the lowered projection;
  - `change` running `TreeRules`;
  - `HistoryStep` reverting the tree;
  - `Touched` replaced by `TreeChange`;
  - `takeBack` running `TreeRules`.

  `rehostElementsOnMissingScreens` is deleted.
- Modify: `Layer/Model/Groups.swift`. `keepGroupsSound()` becomes the shim, and `ungroupStrays`, `dissolveHollowGroups`, `gatherMembers` and `fitGroupBoxes` are deleted.
- Modify: `Layer/Document/DrawingInk.swift`, only if `visibleInk` or `adopt(_:)` reach the old storage.
- Modify: the tests listed in Step 6.
- Test: `LayerTests/StoreOnTheTreeTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4, and `TreeRules.apply(to:after:measure:)` and `TreeIndex` (plan 1)
- Produces:
  ```swift
  // PROJECTION: deleted in plan 6
  struct DesignContent: Equatable, Sendable, Codable {
      var tree = TreeContent()
      /// Pointers a flat write named that the tree can't hold yet; cut when the change ends. Not saved, not compared.
      var pendingPointers: [UUID: UUID] = [:]
      /// Version-3 elements this build couldn't read. Only until Task 8, which deletes the v3 bridge.
      var legacyUnread: [UnreadElement] = []
      init()
      init(tree: TreeContent)
      var title: String? { get set }                 // tree.title
      var canvas: CanvasSettings { get set }         // tree.settings
      /// Cuts pending pointers, then TreeRules.apply(to: &tree, after: nil).
      mutating func keepGroupsSound()
      static func == (a: DesignContent, b: DesignContent) -> Bool   // tree and legacyUnread
  }
  ```
  Every other member keeps its signature, now on the projection:
  - `elements`, `screens` (get and set), `floating` (get and set);
  - `screen(_:)`, `element(_:)`, `children(of:)`;
  - `add(_:to:scale:)`, `update(_:_:)`, `remove(_:)`, `move(_:to:scale:frame:)`, `reorder(_:to:)`, `setChildren(of:to:)`;
  - `addScreen(_:)`, `removeScreen(_:)`, `updateScreen(_:_:)`;
  - `screenFrames`, `elementsOnMissingScreens` (always empty now);
  - `boardDiffers(from:)`, `reverting(_:to:)`, `takeBack(_:to:)`;
  - `imageIDs`, `unreadNames`, `visibleInk`, `adopt(_:)`;
  - every reader in `Groups.swift` and `LayerOrder.swift`.
- **How each member maps:**
  - Reads lower the tree.
  - `add`, `update`, `remove`, `move`, `reorder` and `setChildren` call the matching `projected…` write.
  - `addScreen`, `removeScreen`, `updateScreen` and the `screens` and `floating` setters edit `tree.screens` (screen fields ↔ `TreeScreen`; a new screen gets a free root), then `projectedSetHost` with the host's given elements plus its containers that weren't given (today's `groupItems(besides:)`).
  - `reverting` is `tree.reverting`, plus `legacyUnread` whole. `takeBack` is `tree.takeBack`.
  - `DesignScreen ↔ TreeScreen` keeps the root's own fields by id.
- **The store:**
  - **The memo.** `private struct Kept { lazy index: TreeIndex; lazy lowered: TreeProjection.Lowered }` is kept per `changeCount`, and replaces `Views`. `screens`, `floating`, `element(_:)`, `resolve(_:)` and `indexInList(of:)` read `lowered`.
  - **A change:**

    ```swift
    private static func applying(_ body: (inout DesignContent) -> Void, to content: inout DesignContent, previous: DesignContent) {
        body(&content)
        content.pendingPointers = [:]
        TreeRules.apply(to: &content.tree, after: previous.tree)
    }
    ```

  - **Undo:** `takeBack` does `result = step.undone(from: current)`, then `result.pendingPointers = [:]` and `TreeRules.apply(to: &result.tree, after: current.tree)`.
  - `HistoryStep.record`, `touched` and `onlyScreen` use `TreeChange` and `TreeChange.hosts(in:)`.

- [ ] **Step 1: Write the failing tests** in `StoreOnTheTreeTests`:
  - `theStoreHoldsTheTree`: after `addScreen(from:)` and `place(_:centeredAt:)` of a button on it, `store.content.tree.screens[0].root.children.map(\.kind) == [.button]`.
  - `aGroupOfOneMadeInAChangeIsGoneByItsEnd`: one `apply` adds a group and points one member at it. Afterwards the member is a root child, and there is one undo step.
  - `pendingPointersEndWithTheChange`: one `apply` adds a member pointing at a group that never comes. Afterwards the member is a root child, and `content.pendingPointers` is empty.
  - `aLeafEditLaysOutOnlyItsScreen`: with two free screens, a leaf's frame changes on screen A. `LayoutEngine.timesLaidOut(A's root)` rises by 1, and `timesLaidOut(B's root)` by 0 (F8).
  - `theProjectionIsLoweredOncePerVersion` (`@MainActor`, synchronous): reading `screens`, `floating` and `element(_:)` ten times each raises `TreeProjection.lowerings` by 1 (F8).
  - `undoAndRedoGoThroughTheTree`:
    - A free group G, turned 30 and holding two leaves, is moved 10 points right with `position`.
    - Undo gives the tree as it was before, with G's frame within 1e-6.
    - Redo gives the tree after the move, with G's frame within 1e-6.
    - Neither leaf's local frame changes at any point, within 1e-6 (F24).

- [ ] **Step 2: Run them.** Run `StoreOnTheTreeTests`. Expected: FAIL (`DesignContent` has no `tree`).

- [ ] **Step 3: Rebuild `DesignContent`** on the tree, as in the Interfaces. Keep the v3 `Codable` through the bridge:
  - **encode:** today's keys (`screens`, `elements`, `title`, `canvas`), with `elements` the raw lowering and `legacyUnread` re-interleaved at their indices;
  - **decode:** today's reader, then a lift per host, with unread elements going to `legacyUnread`.

- [ ] **Step 4: Move the store onto it**, as in the Interfaces.
  - Delete `Views`, `rehostElementsOnMissingScreens`, `Touched` and the four group rules.
  - Delete today's generic list revert (DesignFile.swift:308), which Task 4's revert replaces (F15).

- [ ] **Step 5: Run the suites that must pass unchanged.** Names that are files run as their structs (F7). Run each:
  - `ConcurrentEditTests`, `UndoNameTests`, `DesignTests`, `FlatStoreTests` (except the four Step 6 changes under (f)), `MultiSelectionTests`;
  - `CanvasHitTestTests`, `CanvasDragLandingTests`, `CanvasDragWorkTests`, `RotationTests`;
  - `FormatPanelTests`, `LayersPanelTests`, `LayerOrderTests`, `GroupFinalFixTests`, `PerformanceFixTests`, `PanelStepTests`;
  - `SiriIntentsTests`, `VoiceToolsTests`, `VoiceAgentTests`, `PencilVoiceTests`;
  - `ScreenGenerationTests`, `ScreenTidyTests`, `AssetLibraryTests`, `DrawingTests`, `FreeformTests`, `MagicPenComponentTests`, `ZoomRulerTests`.

  Expected: PASS. Fix the projection until they do.

- [ ] **Step 6: Change only the tests the policy allows.** These `GroupTests` cases are expected:
  - `aDrawingAmongMembersKeepsItsSlot`, under (b): it becomes "a drawing beside a canvas group keeps its index among the canvas's nodes";
  - `aMemberIsFoundPastADrawingInsideItsGroupsBlock`, under (b): retired, since the setup can't exist;
  - `aFloatingGroupsBoxHoldsMembersOfMixedScales`, `aGroupOnTheOpenCanvasTakesItsFrontmostMembersScale` and `aGroupLandingWhereThingsAreDrawnAtAnotherScaleArrivesWhole`, under (c): assert in canvas points instead of own points and own scales;
  - turned-group geometry, under (e), where an exact `==` now differs below 1e-9.

  These `FlatStoreTests` cases are expected to change under (f) (F4):
  - `everythingOnTheBoardIsInOneListAndSaysWhatItIsOn`;
  - `movingToAnotherScreenChangesWhatItIsOnAndPutsItOnTopThere`;
  - `arrangingReordersOnlyAmongWhatSharesItsScreen`;
  - `deletingAScreenTakesWhatIsOnItOutOfTheList`.

  Their whole-list lines (`content.elements.map(\.id)`, and its `parent` and `scale` twins) become per-host orders (`children(of:)`, `store.screens`, `store.floating`). Their per-host assertions stay as they are.

  If one of these passes unchanged, leave it. Record every change in the ledger with its clause.

- [ ] **Step 7: Run everything.** Run `StoreOnTheTreeTests`, the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 8: Commit.** `git add -A && git commit -m "The store holds the tree: the rules and undo run on it, and every caller reads and writes it through the projection"`

---

### Task 8: The file, version 4

**Lane:** A (waits for Tasks 5 and 6 to be merged; F2)

**Files:**
- Modify: `Layer/Document/DesignFile.swift`. The changes:
  - `DesignFile` reads and writes v4;
  - `DesignContent`'s `Codable` is the tree's content coding;
  - the v3 bridge, `legacyUnread`, `Manifest`, `SingleFile`, `SingleFileContent`, `forgetUnknownKeys`, the v<3 paths, the `drawing.data` adoption and `DesignFile.unknownKeys` are deleted.
- Modify: `Layer/Tree/TreeContent.swift`. It gets `unreadCanvas` and `TreeManifest.encode(_:fileName:version:)`.
- Modify, for `unreadCanvas` (F3):
  - `Layer/Tree/TreeChange.swift`: `board` includes a change to `unreadCanvas`;
  - `Layer/Tree/TreeRevert.swift`: `reverting` takes `unreadCanvas` back whole, as it does unknown keys, and `takeBack` does the same;
  - `Layer/Tree/TreeRules.swift`: when the canvas tidy removes canvas nodes, the unread ones keep their places (`keepUnreadPlaces` for the canvas, instead of `_ = tidy(&content.canvas)`).
- Modify: `Layer/Document/DesignPackage.swift`. `drawing` is deleted, so a stray `drawing.data` is now an unknown part, which is kept.
- Modify: `Layer/Intents/DesignLibrary.swift` and its callers. A refused file is skipped.
- Modify: the tests listed in Step 6.
- Test: `LayerTests/DesignFileV4Tests.swift`

**Interfaces:**
- Consumes: `TreeManifest` and `TreeRules` (plan 1), Task 7, and Tasks 5 and 6 (`customDevices`, `unreadDevices`, `tokens`) (F2)
- Produces:
  ```swift
  struct DesignFile: Sendable {
      typealias ReadError = TreeManifest.ReadError
      static let currentVersion = TreeManifest.version            // 4
      var version = currentVersion                                // written as is: tests write a newer file
      var content = DesignContent(); var images: [String: Data] = [:]; var preview: Data?
      var fileName: String?; var unreadInk: [String: Data] = [:]; var unknownParts: [String: PackagePart] = [:]
      var drawing: PKDrawing { get }                              // content.visibleInk, as today
      init(content: DesignContent = DesignContent(), drawing: PKDrawing = PKDrawing(), images: [String: Data] = [:])
      init(wrapper: FileWrapper) throws        // v4 only; TreeRules.apply(to:after: nil) before returning (My call 18)
      func wrapper(replacing existing: FileWrapper? = nil) throws -> FileWrapper
      nonisolated static func content(at url: URL) throws -> DesignContent   // design.json only; rules applied
  }
  extension TreeContent { var unreadCanvas: [LayerNode.UnreadChild] }   // canvas nodes this build can't read, at their index
  extension TreeManifest { static func encode(_ content: TreeContent, fileName: String?, version: Int) throws -> Data }
  extension DesignLibrary {
      nonisolated static func read(_ url: URL) -> DesignSummary?        // nil when the file is refused (TreeManifest.ReadError)
      nonisolated static func listed(_ url: URL, isDownloaded: (URL) -> Bool = isDownloaded) -> DesignSummary?   // default kept (F5)
  }
  ```
- **Reading:**
  - A package's `design.json` goes through `TreeManifest.decode`, so versions below 4 throw `.olderVersion` and versions above 4 throw `.newerVersion`.
  - A single file is not a package. If its JSON says a version, it throws `.olderVersion(version)`; otherwise `.unreadable`.
  - Ink is read from `ink/<node-uuid>` for each drawing among `tree.canvas`.
  - These are unchanged: `unreadInk` (named by `unreadNames`), pictures, the thumbnail and unknown parts.
  - `unreadNames` gathers every string in:
    - the unknown keys of every node, screen, setting and the content;
    - `manifestUnknownKeys`;
    - every `unreadChildren` and `unreadCanvas` raw node;
    - `unreadDevices`.
- **Writing:** `TreeManifest.encode(content.tree, fileName:, version:)`, with sorted keys. Incremental reuse is unchanged: byte-equal parts keep their wrappers, and pictures are written once.

- [ ] **Step 1: Write the failing tests** in `DesignFileV4Tests`:
  - `aDesignIsSavedAsVersion4WithTreesAndCanvasNodes`:
    - `design.json` has `version == 4`.
    - `content.screens[0].root.children` holds the design's nodes, and `content.canvas` holds its floating ones.
    - There are no `elements` or `floating` keys.
  - `anOlderDesignIsRefusedWithItsMessage`:
    - A v3 package throws `.olderVersion(3)`, and its `localizedDescription` is exactly the older-version message.
    - A v1 single file throws `.olderVersion(1)`.
  - `drawingsInkIsSavedUnderTheirNodeIDs`: `ink/<id>` holds each drawing node's ink, and reads back equal.
  - `anUnknownKindOnTheCanvasIsKeptAtItsPlace`:
    - The canvas is `[note, {"id":…,"kind":"hologram","ink":"<uuid>"}, drawing]`.
    - It reads with canvas kinds `[.stickyNote, .drawing]`, and `unreadCanvas` holds index 1.
    - It is written back at index 1, and the ink file it names is kept.
  - `savedFramesAreLaidOutAgainOnOpening`: a column-root child saved at (0, 0, 1, 1) opens at the engine's frame, which is minX 20 and minY `safeTop + 20` on the iPhone.
  - `aFileWithTwoNodesOfOneIDOpensAndSavesBoth`.
  - `siriAndSpotlightSkipADesignTheyCannotOpen`:
    - A v3 package is written to a temporary folder.
    - `DesignFile.content(at:)` throws `.olderVersion(3)`, and `DesignLibrary.listed(url)` is nil.
    - The library's list of that folder doesn't include it.
  - `aCustomFrameAndTokensSurviveSaving`: Tasks 5 and 6's settings, through `DesignFile(wrapper:)`.
  - `anUndoKeepsAnUnreadCanvasNodeInItsPlace` (F3):
    - The canvas holds an unread node at index 1, and a change removes a canvas group in front of it.
    - After the rules, the unread node keeps its place among those left.
    - Undo brings the group back, and the unread node sits where it was before the change.

- [ ] **Step 2: Run them.** Run `DesignFileV4Tests`. Expected: FAIL.

- [ ] **Step 3: Implement** the reader, the writer, `unreadCanvas` (decoded one node at a time, like `LayerNode`'s children), the version parameter, and the library's skipping. Callers of `read` and `listed` drop nils.

- [ ] **Step 4: Run** `DesignTests`, `FlatStoreTests`, `DrawingTests`, `GroupTests`, `HostedModelTests`, `FreeformTests`, `PerformanceTests` and `SiriIntentsTests`. Names that are files run as their structs (F7).

- [ ] **Step 5: Run the unchanged file tests.** These pass unchanged:
  - `aDesignSurvivesBeingSavedAndOpened`, `savingAgainLeavesThePartsThatHaveNotChangedAlone`, `picturesNothingShowsAreLeftOutOfTheSavedFile`;
  - `aFileFromANewerVersionIsRefusedRatherThanHalfRead`, `somethingThatIsNotADesignFailsToOpen`, `aDocumentSavesWhatTheModelLastToldIt`;
  - `aSavedDesignReadsBackAsItWas`, `newSettingsSurviveSavingAndOpening`, `theChoiceIsSavedInTheDesignFileAndReadBack`;
  - every drawing-saving test except those in Step 6;
  - `FlatStoreTests.elementsThatShareAnIdentifierAreLeftInTheirOrderRatherThanTrapping`. It is in-memory, with no file, so clause (a) doesn't apply. The v4 file case is the new `aFileWithTwoNodesOfOneIDOpensAndSavesBoth` (F5).

- [ ] **Step 6: Change the tests the policy allows**, under clause (a) unless the table says otherwise:

  | Test | What happens |
  |---|---|
  | `FlatStoreTests.aDesignIsSavedAsItsScreensAndOneListOfElements` | Rewritten as `aDesignIsSavedAsScreensHoldingTreesAndCanvasNodes` |
  | `FlatStoreTests.aDesignSavedBeforeElementsWereOneListStillOpens`, `aPackageSavedByTheVersionBeforeOpens` | Retired: they are refused now, as `anOlderDesignIsRefusedWithItsMessage` pins |
  | `FlatStoreTests.anElementOfAKindThisVersionDoesNotKnowIsKeptAndWrittenBackWhereItWas` | Rewritten with v4 JSON (an unknown kind inside a container) |
  | `DesignTests.aDesignSavedBeforeFloatingElementsAndSymbolsStillOpens`, `keysEarlierVersionsDroppedAreNotKeptFromAnOlderFile` | Retired |
  | `DesignTests.savingKeepsThePictureAndInkOfElementsThisVersionCannotRead`, `keysThisVersionDoesNotKnowSurviveASave` | Rewritten with v4 JSON |
  | `DesignTests.aDesignIsWrittenAsAPackageWithItsPartsApart` | Only the assertions on `design.json`'s keys change |
  | `DrawingTests.aPackageSavedWithAllItsInkAsOneDrawingOpensWithDrawings`, and `PerformanceTests`' test that builds a `drawing.data` package | Retired |
  | `DrawingTests.aDrawingsInkIsSavedBesideTheDesignUnderItsIdentifier` | Its `DesignPackage.drawing` becomes the literal `"drawing.data"`. The assertion stays (F5) |
  | `SiriIntentsTests` call sites of `DesignLibrary.read` and `listed` (lines 138, 161, 166, 170, 212, 223, 227) | Clause (g): each gains a `try #require(…)` unwrap. The assertions stay (F5) |
  | `HostedModelTests.aDesignSavedBeforeThereWasAChoiceUsesTheDefault`, `aChoiceFromANewerLayerStillOpens`, `FreeformTests.designsSavedBeforeTheNewSettingsStillOpen` | Their JSON becomes v4 content (`"settings"` for settings, `"canvas": []`), and their assertions stay |
  | `GroupTests`: `aMemberOfAMissingGroupIsUngrouped`, `aGroupOfADrawingOrALoopIsUndone`, `aDesignSavedByABuildThatKnowsNoGroupsKeepsThem`, `aDesignWhoseMembersLostTheirPointersOpensUngrouped` | Retired under (a) and (b): v4 nests children, so these states can't be written |
  | `GroupTests.groupsSurviveTheFile` | Round-trips through v4. Expect it to change: its lines reading the `elements` key change under (a), and the rest stay (F5) |

- [ ] **Step 7: Run everything.** Run `DesignFileV4Tests`, the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 8: Commit.** `git add -A && git commit -m "The file: version 4 only, the tree saved as it is, older designs refused with their message and skipped by Siri and Spotlight"`

---

### Task 9: The tree's verbs, for plan 3

**Lane:** A (waits for Tasks 5 and 6)

**Files:**
- Create: `Layer/Model/DesignStore+Tree.swift`, `Layer/Tree/TreeEdit.swift`
- Modify:
  - `Layer/Model/DesignStore.swift`: the memo is exposed as `index`, and `tree` is added;
  - `Layer/Tree/TreeIndex.swift`: a screen's lock is no longer folded into its nodes;
  - `Layer/Model/Projection/TreeProjection.swift`: view screens get `resolvedDevice = settings.device(named:)`. Task 2 left it nil (F20);
  - `Layer/A2UI/*.swift`, if plan 1's importer or exporter holds the card's padding, radius or fill, or a rhythm number, as a literal: they read `DesignTokens.standard` instead (F17). The values are equal, so the A2UI tests pass unchanged.
- Test: `LayerTests/TreeVerbTests.swift`

**Interfaces:**
- Consumes: Tasks 5–8, and `TreeRules` and `TreeIndex` (plan 1)
- Produces, for plans 3–6:
  ```swift
  enum NodeParent: Hashable, Sendable { case node(UUID), screen(TreeScreen.ID), canvas }   // .screen = that screen's root

  enum TreeEdit {   // pure; Layer/Tree
      /// Left to right for a horizontal stack, top to bottom for a vertical one; row by row for a grid
      /// (a row starts at the topmost remaining node and takes those whose midY lies within its vertical extent).
      static func readingOrder(_ nodes: [LayerNode], for layout: LayerNode.Layout) -> [LayerNode]
      static func copyWithNewIDs(_ node: LayerNode) -> LayerNode
  }

  extension DesignStore {
      var tree: TreeContent { get }                       // reads `content`, so it is observed
      var index: TreeIndex { get }                        // the memo, once per version
      func node(_ id: UUID) -> LayerNode?
      func parent(of id: UUID) -> NodeParent?
      func device(of screenID: TreeScreen.ID) -> DeviceFrame?    // built-in, then custom
      func isLaidOut(_ id: UUID) -> Bool                  // a container whose layout isn't free
      /// Adds a whole subtree, ids as given. `index` nil = in front. Refused (false) for an unknown parent,
      /// a canvas-only kind on a screen, a depth over 32, or an id already in the design.
      @discardableResult func add(_ node: LayerNode, to parent: NodeParent, at index: Int? = nil) -> Bool
      @discardableResult func addScreen(_ screen: TreeScreen) -> TreeScreen.ID
      @discardableResult func replaceChildren(of parent: NodeParent, with children: [LayerNode]) -> Bool
      /// Reparents within or across hosts. In a free parent it keeps its place on the canvas (own size kept,
      /// as today's move); in a laid-out one `index` decides its place. Refused into its own subtree, a
      /// canvas-only kind onto a screen, a screen root, or past depth 32.
      @discardableResult func move(_ id: UUID, to parent: NodeParent, at index: Int? = nil) -> Bool
      func update(_ id: UUID, _ body: (inout LayerNode) -> Void)      // id and children stay as they were
      /// Siblings of one parent, wrapped in the frontmost one's slot. Free: nothing moves, the container fits on both
      /// axes. Stack or grid: reading order, each child fixed at its size (My calls 15, 16). A card pads by the
      /// design's tokens. On the canvas the container takes the frontmost one's scale. Nil when not one parent or < 1.
      @discardableResult func wrap(_ ids: [UUID], in kind: ElementKind, layout: LayerNode.Layout) -> UUID?
      /// Children into the container's slot, places on the canvas kept with its turn baked in, its lock and hide
      /// passed down; joining the parent at that slot if the parent is laid out. Returns their ids.
      @discardableResult func unwrap(_ id: UUID) -> [UUID]
      /// On a container or a screen root. Free → stack or grid: reading order first, children fixed at their size.
      /// Laid out → free: frames kept.
      func setLayout(_ id: UUID, _ layout: LayerNode.Layout)
      /// The point a reconciler commits through: one change, one rules pass. False when the screen is gone.
      @discardableResult func reconcile(_ screenID: TreeScreen.ID, _ body: (inout LayerNode) -> Void) -> Bool
      /// Subtrees removed; screen roots never. The reading log is told once.
      func delete(nodes ids: Set<UUID>)
      /// Copy with new ids, offset 16 of its own points, on top at the host's top level, else just in front of
      /// the original; unlocked; drawings get strokes of their own. Nil when it is gone or is a screen root.
      @discardableResult func duplicate(node id: UUID) -> UUID?
  }
  ```
  Every verb is one `change`: one undo step, or part of the acting edit, as today's verbs are.

- [ ] **Step 1: Write the failing tests** in `TreeVerbTests`:
  - `addingASubtreeKeepsItsIDsAndLaysItOut`:
    - A row of three texts is added to a screen whose root is a column.
    - The ids are unchanged, and the frames are the engine's.
    - One undo removes the whole row.
  - `replacingAScreensChildrenIsOneStep`: three children are replaced by two. One undo brings back the three, with their ids.
  - `movingKeepsThePlaceOnTheCanvasInAFreeParent`: X sits in a free G, at host (100, 100, 20, 20). After it moves to `.screen(s)`, its root frame is (100, 100, 20, 20).
  - `movingIntoARowTakesTheIndex`: moving to `.node(row)` at index 1 makes it the row's second child.
  - `movesTheTreeCantHoldAreRefused`: a container into its own child, a sticky note onto a screen, and depth 33 are each refused, and the tree is unchanged.
  - `wrappingInAFreeGroupMovesNothing`:
    - Two of `[A, B, C]` are wrapped: A and C.
    - The group takes C's slot, so the root holds `[B, G[A, C]]`. A's and C's host frames are unchanged.
    - The group is fit on both axes.
  - `wrappingAsARowSortsByXAndFixesSizes`:
    - Three texts sit at x 200, 20 and 110.
    - The row holds them in x order 20, 110, 200, and every child is `.fixed` at its old size.
  - `wrappingAsAGridReadsRowByRow`:
    - Four 50×50 nodes sit at (100, 0), (0, 0), (100, 60) and (0, 60).
    - A 2-column grid holds them in the order (0, 0), (100, 0), (0, 60), (100, 60).
  - `aCardTakesItsPaddingFromTheDesignsTokens`: with the design's card padding 24, a wrapped card's padding is 24 on all four sides.
  - `wrappingThingsOfTwoParentsIsRefused`: it returns nil, and the tree is unchanged.
  - `unwrappingBakesTheTurnAndPassesLockAndHideDown`:
    - G is turned 90 and locked. After unwrapping, each child's host centre is unchanged within 0.001.
    - Each child's angle is summed, and each child is locked.
  - `unwrappingIntoAColumnJoinsAtTheSlot`: unwrapping G in a column `[a, G[t1, t2], c]` gives `[a, t1, t2, c]`, laid out.
  - `settingAColumnOnAScreenRootSortsTopToBottom`: the root's children come out in minY order, fixed at their sizes.
  - `reconcileIsOneChangeAndOneRulesPass`: one undo step. `LayoutEngine.timesLaidOut(id)` rises only for the containers that changed, and by 0 for the screen's unchanged containers (F8).
  - `aDuplicatedContainerHasNewIDsThroughout`: no id in the copy's subtree appears in the original's, and the copy's frame is the original's moved by (16, 16).
  - `deletingAContainerTakesItsSubtreeAndTellsTheLogOnce`: `CanvasWork.readingLogTasks` rises by 1.
  - `aLockedScreensNodesAreNotLockedByIt`: `index[leaf].isLockedWithAncestors == false` when only the screen is locked.
  - `aScreenOnACustomDeviceResolvesIt`: `device(of:)` returns the custom frame, and so does the projected `DesignScreen.device`.

- [ ] **Step 2: Run them.** Run `TreeVerbTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `TreeEdit` and the verbs, the screen-lock change in `TreeIndex`, and `resolvedDevice` in the projection. Then move any `Layer/A2UI/` card or rhythm literals onto `DesignTokens.standard` (F17), and run `A2UIImportTests` and `A2UIExportTests`.

- [ ] **Step 4: Run them.** Run `TreeVerbTests`, `TreeIndexTests` and `ScreenTidyTests`, then the full unit suite. Expected: PASS, and TEST SUCCEEDED.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Tree verbs: add, replace, move, wrap, unwrap, set layout, reconcile, delete and duplicate, each one change"`

---

### Task 10: Delete, duplicate, group and ungroup on the tree

**Lane:** A

**Files:**
- Modify: `Layer/Model/DesignStore.swift`. On the tree verbs: `delete(_ refs:)`, `delete(_ ref:)`, `duplicate(_ ref:)`, `duplicateScreen(_:)`, and `setElements(_:on:replacing:)` (`replacing` uses `replaceChildren` with `LayerNode(element:)`; adding uses `add`). `withWhatIsInThem` is deleted.
- Modify: `Layer/Model/SeveralThings.swift`. `duplicate(_ selection:)` and `delete(_ selection:)` use the verbs.
- Modify: `Layer/Model/Groups.swift`. `group(_:)` becomes `wrap(…, in: .group, layout: .free)`, keeping today's `groupable` rules. `ungroup(_:)` becomes `unwrap`.
- Test: `LayerTests/TreeVerbOldCallerTests.swift`

**Interfaces:**
- Consumes: Task 9
- Produces: no new API. Today's verbs keep their signatures and results, as the existing tests pin.
- **The mapping:**
  - A selection's things become node ids, and each `ElementRef` maps to its node.
  - The result is the `ElementRef` or `CanvasSelection` of the same node ids, on the same host.
  - `changeKind` and `writeGenerated` stay on the projection until plans 5 and 3.

- [ ] **Step 1: Write the failing tests** in `TreeVerbOldCallerTests`:
  - `ungroupingAGroupInsideARowJoinsTheRow`: G sits in a row at index 1, holding two texts. After `ungroup`, the row holds `[a, t1, t2, c]`, laid out.
  - `duplicatingARowChildPutsTheCopyNextInTheRow`: duplicating b in a row `[a, b, c]` gives `[a, b, b′, c]`.
  - `deletingARowTakesItsChildrenAndLeavesTheColumnLaidOut`:
    - A column root holds `[t, row[x, y], u]`. The row is deleted.
    - The root holds `[t, u]`, and u's minY equals t's maxY plus the column's spacing.
  - `aGroupMadeFromTheSelectionIsAFreeWrap`: `store.group(selection)` gives a node with layout nil, fit on both axes, in the frontmost member's slot.
  - `setElementsReplacingKeepsTheScreensRootLayout`: on a column root, `setElements(…, replacing: true)` keeps the root's layout, and the new children are laid out.

- [ ] **Step 2: Run them.** Run `TreeVerbOldCallerTests`. Expected: FAIL.

- [ ] **Step 3: Move the verbs.**

- [ ] **Step 4: Run them**, then these, which must pass unchanged, meaning as left by the changes already recorded in the ledger (F6):
  - `GroupCommandTests` ("Group commands", including Task 7's (c) change) and `GroupAsOneThingTests` ("A group as one thing"), `GroupFinalFixTests`, `FreeformTests` (its structs, per F7);
  - `FlatStoreTests.aCopiedScreenBringsCopiesOfWhatIsOnIt`;
  - `SiriIntentsTests`, `VoiceToolsTests`, `AssetLibraryTests`, `ConcurrentEditTests`, `PerformanceFixTests` (`deletingAGroupStartsOneTaskForTheReadingLog`).

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Delete, duplicate, group and ungroup work on the tree: a group is a free wrap, and a row or card survives them"`

---

### Task 11: Order, hosts, moving, resizing and turning on the tree

**Lane:** A

**Files:**
- Modify: `Layer/Model/LayerOrder.swift`.
  - `arrange`, `canArrange`, `moveLayer` and `moveLayerToTop` reorder a parent's children. A `LayerList` becomes a `NodeParent`.
  - Drawings keep their indices among the canvas's nodes.
  - Bring Forward and its kin are off for children of a stack or grid (My call 15).
  - `rawOrder` is deleted. `SiblingLists` stays for `layerTree(on:)` only.
- Modify: `Layer/Model/DesignStore.swift` (`rehost(_:)`, `move(_:toScreen:origin:)`), `Layer/Model/Groups.swift` (`rehostGroup`, `resizeGroup`, `groupPose`), `Layer/Model/SeveralThings.swift` (`position`, `rehost(_ selection:)`). These go through the tree's `move` and node frames.
- Modify:
  - `Layer/Model/TurnSession.swift`: `form` treats a laid-out container as one rigid part with no contents;
  - `Layer/App/AppModel.swift`: `turn(_:to:)` and `turnEach` write a laid-out container's frame, using `store.isLaidOut`.
- Modify: `LayerTests/CanvasDragWorkTests.swift` (one assertion), `LayerTests/LayerOrderTests.swift` (`theRawOrderKeepsEachDrawingInItsSlot`)
- Test: `LayerTests/TreePlaceTests.swift`

**Interfaces:**
- Consumes: Tasks 9 and 10
- Produces:
  ```swift
  extension TreeEdit {
      /// `order` written into `children`, every drawing keeping its index (the slot rule arrange used, on nodes).
      /// Comments don't name the functions Task 12's grep looks for (F18).
      static func reordered(_ children: [LayerNode], to order: [UUID]) -> [LayerNode]
  }
  ```
- **The rules:**
  - `position`:
    - a container moves by its own frame, in one write, and everything in it rides along;
    - a leaf moves through its node frame, and My call 20 applies under a laid-out parent, with W3's rule for a host whose root isn't free (F11);
    - locked things stay, as today.
  - `rehost(_:)` and `rehostGroup` use `move(_:to:at:)` across hosts, keeping the canvas centre and the size in own points:
    - a container goes whole, so its contents scale about its middle;
    - a container holding a canvas-only kind stays put;
    - sticky notes and drawings stay on the canvas.
  - `resizeGroup` and `groupPose`:
    - the leaves scale about the box as today, but a laid-out container counts as one leaf;
    - a laid-out container resized itself becomes `fixed` at the new size, and its children re-lay.

- [ ] **Step 1: Write the failing tests** in `TreePlaceTests`:
  - `aRowDraggedMovesWhole`: `position` on a row moves its frame. `ListWork` rises by 1, and its children's local frames are unchanged.
  - `bringForwardIsOffInARowButOnInAnOverlay`: `canArrange(.forward)` is false for a row's middle child, and true for an overlay's child that isn't in front.
  - `aRowResizedBecomesFixedAndReLaysItsChildren`:
    - `resizeGroup` takes a fitting row to width 300.
    - Its width is `.fixed`, `frame.width == 300`, and its children lie within it, laid out.
  - `aGroupHoldingARowResizesTheRowAsOnePiece`: the row stays a row, with the same children.
  - `aRowTurnedAloneSetsOnlyItsAngle`: a turn session of 30° on a selected row writes `rotation == 30`, and its children's local frames are unchanged.
  - `aRowDroppedOnAnotherScreenGoesWhole`: `rehost` moves the row, with its three children, onto the other screen's root, and every id is unchanged.
  - `aDrawingKeepsItsIndexAmongTheCanvasNodes`: this replaces `theRawOrderKeepsEachDrawingInItsSlot`, and calls `TreeEdit.reordered`.

- [ ] **Step 2: Run them.** Run `TreePlaceTests`. Expected: FAIL.

- [ ] **Step 3: Move the verbs**, and add the two turning guards.

- [ ] **Step 4: Change the tests the policy allows:**
  - `CanvasDragWorkTests.aDragFrameWritesOnlyWhatItMoves`, under (d): the group drag now expects `groupWrites == 60`, and its comment says the group is written alone. The line drag still expects 60.
  - `LayerOrderTests.theRawOrderKeepsEachDrawingInItsSlot` is retired under (f) and (g) (F5). `rawOrder` is gone, the test asserts the one list's order across hosts, and `aDrawingKeepsItsIndexAmongTheCanvasNodes` carries its rule.

- [ ] **Step 5: Run the suites that must pass unchanged.** "Unchanged" means as left by the changes already recorded in the ledger (F6), and names that are files run as their structs (F7).
  - Run `LayerOrderTests` (the rest), `GroupGeometryTests` ("Group geometry", including Task 7's (c) change), `GroupCommandTests/aGroupArrangesAsOneBlock`, `RotationTests`, `CanvasDragLandingTests`, `MultiSelectionTests`, `FormatPanelTests`, `SiriIntentsTests`, `VoiceToolsTests` and `ConcurrentEditTests`. Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 6: Commit.** `git add -A && git commit -m "Order, hosts and moves work on the tree: a container moves, lands, resizes and turns as one, and drawings keep their places"`

---

### Task 12: Measured, and the plan's finish

**Lane:** A (waits for all the others)

**Files:**
- Create: `LayerTests/StoreChangeBudgetTests.swift`
- Modify: `docs/benchmarks/semantic-tree.md` (the "After plan 2" column)

**Interfaces:**
- Consumes: everything above, and `StoreChangeBenchmarkTests` (Task 1)
- Produces: the "After plan 2" measurements, and two always-on budget tests.

- [ ] **Step 1: Write the budget tests** in `StoreChangeBudgetTests`:
  - `aStoreChangeOnAHundredNodeScreenIsWithinBudget`:
    - The screen has a column root holding 25 rows, each a row of a text, a body, a toggle and a divider.
    - It times 50 runs each of: move a leaf (through `update(ref)`), resize one, edit a text, and add a text to a row (`store.add(_:to: .node(row), at: nil)`).
    - Each p95 is under 16 ms. It prints `BENCH tree <op> p50 p95`.
  - `aLeafDragLaysOutOnlyItsDirtyPath`: over a 60-frame drag of a leaf on a free screen, `LayoutEngine.timesLaidOut(root)` rises by at most 60, which is the root alone each frame. Every other container on that screen rises by 0 (F8).

- [ ] **Step 2: Run them.** Run `StoreChangeBudgetTests`. Expected: PASS. If the timing fails, profile the change pipeline before going on: the memo, the projection writes, `TreeRules`. The budget is the spec's.

- [ ] **Step 3: Measure.**
  - Run `TEST_RUNNER_LAYER_BENCHMARK=1` with `StoreChangeBenchmarkTests`, and with `TreeRulesTests/oneEditOnAHundredNodeScreenIsQuick`.
  - These measurements run only while no other lane or `xcodebuild` is running. Record that in the ledger (F14).
  - Run the canvas workout exactly as Task 1 Step 4 did, on the branch, in lane C's simulator (the one Task 1 used), with DerivedData `Layer-semantic-tree-release`.
  - Fill the "After plan 2" column. The workout's CPU time must be no worse than main's by more than 5%.
  - If it is worse, profile with Instruments' Time Profiler on the workout, fix it, and measure again. Never record a better number than was measured.

- [ ] **Step 4: Verify the plan's end state.**
  - The full unit suite passes.
  - The UI suite fails nothing outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.
  - `grep -rn "fitGroupBoxes\|dissolveHollowGroups\|ungroupStrays\|rawOrder\|forgetUnknownKeys\|DesignPackage.drawing\|legacyUnread" Layer LayerTests` finds nothing, comments included (F18).
  - `grep -rln "PROJECTION: deleted in plan 6" Layer` lists only `Layer/Model/Projection/`, `DesignContent`, and the `keepGroupsSound` shim.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Benchmarks after the store cutover: a change within 16 ms, a drag laying out only its path, and the canvas workout against main"`

- [ ] **Step 6: Clean up.** Delete the lane B and lane C worktrees and branches once merged, their simulators (`xcrun simctl delete "Layer iPad Pro 11 (st2-lane-b)"` and `"Layer iPad Pro 11 (st2-lane-c)"`), and their DerivedData, plus `Layer-semantic-tree-release`.

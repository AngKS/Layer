# Semantic tree, plan 4 of 6: the canvas and panels on the tree. Implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the canvas and its panels off the projection and onto the tree. After this plan:
- each screen draws its root through recursive, `Equatable` node views, and so do the open canvas's nodes, the thumbnail and the share picture. One edit re-evaluates only the views on its path (`CanvasWork.nodeViewsBuilt`);
- hit-testing, selection, hover, the lasso, the box, the resting finger and the near miss keep today's rules, with "group" read as any container;
- moving, snapping and rehosting in a free parent work as today, on node frames. A thing in a row, column or grid drags with an insertion line: the drop reorders it, takes it out, or puts it in another row, column or grid;
- resizing and turning work on the tree. A container turns whole, several things turn about the fixed pivot, and a laid-out child turns in place and resizes to a fixed size;
- the popover's Group button gains Row, Column, Grid and Card;
- the Format panel has a Layout section, Width and Height sizing for laid-out children, and a card's fill. X and Y are off for laid-out children;
- the Layers panel is built from the tree, with an icon for each container's layout;
- custom device frames appear in the device pickers and the library's Wireframes tab. They are made with "Custom Size…" or from a screen. The design's tokens are edited in the canvas settings, and its text sizes reach the engine;
- ink is read from and written to the tree;
- the canvas and the panels never lower the projection, and what still reads it is named for plan 6;
- the first milestone's UI test passes: a card holding two texts, and a two-column grid, both seen in Layers and exported to SwiftUI.

**Architecture:** The canvas reads `store.tree` and `store.index` directly. Plan 4's tree reads and writes (`PlacedNode`, `place`, `TreeTargets`, `TreeDrop`, turn poses) sit beside plan 2's verbs. Each pure piece lives in `Layer/Tree/` (`TreeTargets`, `TreeDrop`, `TreeIndex+Pose`, `TreeEdit+Group`) and builds on macOS. Views stay in `Layer/Canvas/` and `Layer/Chrome/`, store extensions in `Layer/Model/`.

The selection keeps `CanvasSelection` and `ElementRef`, whose element is a node id. The projection's accessors (`selectedElement`, `selectedScreen`, `store.screens`…) stay, marked, only for the callers plans 5 and 6 move: the sketch path, Siri and voice.

A drag in a laid-out container writes nothing until it drops. Plan 3's interim card drawing (`ScreenDrawing`) and template previews are deleted.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, UIKit, PencilKit (ink only), `@Observable`, Swift Testing, XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-23-semantic-tree-design.md`. Read:
- §1–§3 and §8;
- §10, all of it;
- §14's UI parts: the device picker, "Custom size…", the Frames tab and token editing;
- My calls 3, 5, 15, 16, 18, 19 and 20;
- the Edge cases ("Ungrouping a turned container") and Verification (UI tests, the first milestone);
- "How the work is split", item 4.

`reports/Semantic tree 2026-11-23/recon/canvas-interaction.md` in the main checkout (`/Users/angks/projects/personal/Layer/`) lists today's behaviours (§6), its flat-list assumptions (§7), and the UI tests and what each pins (§6.9). Plans 1–3 (`docs/superpowers/plans/2026-11-23-semantic-tree-{1,2,3}-*.md`) are the source of every tree, store and export name used here.

**Starts when:**
- plan 3 is complete and merged into `feature/semantic-tree`;
- its Task 13 has filled the "After plan 3" column of `docs/benchmarks/semantic-tree.md`;
- `scripts/check-generated-swiftui.sh` passes on the branch;
- `grep -rln "PROJECTION: deleted in plan 6" Layer` lists exactly plan 3's end-state set.

## Calls made in this plan

1. **The selection keeps its types.** `CanvasSelection` and `DesignStore.ElementRef` stay. An element ref's `element` is a node id. Its `host` is the node's host as the index has it, and `store.ref(of:)` makes one.
   - Why: the spec's "node ids and screen ids" is what a ref already holds, and about 700 test lines build refs. Plan 6 renames `ElementRef` when `DesignElement` goes.
2. **The tree's names sit beside the projection's.** The canvas and the panels read these:
   - `selectedNode`, `selectedScreenID` and `selectedLeafNodes`;
   - `store.treeScreen(_:)`, `store.placed(_:)` and `store.treeTargets(entered:)`.

   `selectedElement`, `selectedScreen`, `selectedElements` and `selectedLeaves` stay, marked `// PROJECTION: deleted in plan 6`. Voice, Siri, Image Playground and the sketch path still call them.
   - Why: plans 5 and 6 move those callers. The canvas must stop lowering the projection on every change, which Review Focus 2 measures.
3. **A drag in a row, column or grid writes nothing until the drop.**
   - The thing is *lifted*: it stays where it is, and a translucent copy (opacity 0.7) follows the finger in the selection layer.
   - The insertion line shows where it would go.
   - The drop is one change. A drag cut short lands as a drop would.
   - Why: My call 20 would take the child out of its container on the drag's first frame, but the spec reorders on the drop. A drag frame then costs no store change at all (§13, "A drag frame").
4. **One drop rule for one dragged thing, whatever its parent.**
   - The deepest visible, unlocked row, column or grid under the finger takes the drop and shows the line. It must not be the thing itself or inside it.
   - Anywhere else, placement is free, as today.
   - Several things dragged together keep plan 2's per-frame moves, and a laid-out one among them is taken out on the first frame.
   - Why: the spec makes "that container shows an insertion line under the finger" the signal to join. One rule for every source is Figma's convention (My call 5). It also lets a column screen take a dropped thing at a place rather than at its end. The spec doesn't say how several things drop into a layout.
5. **Resizing a laid-out child writes its size only.** An axis whose size changed by more than 0.5 pt becomes `.fixed` at the new size, and the engine places it. Its origin is never written.
   - Why: a corner handle moves the origin too, and My call 20 would read that as taking the child out.
6. **Turning works on canvas poses of the selected nodes.**
   - A `TurnSession`'s parts are the selected nodes. A container is one rigid part.
   - Each part's pose is its centre in canvas points and its summed angle. A pose is written back through its parent's inverse transform.
   - A laid-out child takes the angle only, and turns in place.
   - Why: the spec's §3 ("works in host coordinates and writes each node's local frame and angle through its parent's inverse transform"). Canvas points let things on two hosts turn about one pivot, as today.
7. **The Group button keeps its tap.**
   - It becomes a `Menu` with a primary action: a tap groups, and a hold shows Group, Row, Column, Grid and Card.
   - ⌘⌥G still groups.
   - Why: `testGroupingFromThePopoverAndGoingInWithADoubleTap` and the shortcut stay as they are. The menu is a hold away, as Freeform's menus are.
8. **The numbers Group as uses.** My call 16 leaves these to the builder.
   - **Spacing** is the rhythm step nearest the median gap in reading order, the smaller on a tie.
   - **Alignment** goes by the edges that line up best: the smallest spread of starts, centres and ends, with start on a tie.
   - **Grid columns** are the number of things in the first reading row, clamped to 1–12.
   - **A card's inside** is a row when everything shares one reading row, and a column otherwise. Its padding comes from the design's tokens.
   - **The new container** fits on both axes. Its frame is placed so that the first thing in reading order keeps its top-left.
   - **What can be grouped:** a card may hold one thing, and the other shapes need two.
   - **Today's refusal** to group every member of a free group stays for Group only, since it would dissolve. As a Row, Column, Grid or Card the result is meaningful.
   - Why: things should move as little as possible, and a card round one thing is common. Today's `groupable` already means one parent (one host and one group pointer), so §10's "one parent" changes no rule.
9. **The Layers panel lists a row's, column's or grid's children in layout order**, first at the top. Free and overlay containers list topmost first, as today.
   - Why: nothing overlaps in a laid-out container, so "topmost" means nothing on screen, while the order things appear in does.
10. **The Format panel:**
    - an overlay's children count as laid out: they get sizing, and their X and Y are off, because the engine places them as it does a row's;
    - a screen's root offers Free and Column only, because the rules pad and reflow those two from the device;
    - padding is four fields;
    - a fill weight stays 1;
    - X, Y, W and H are in the host's own points, as today.
11. **Custom devices** are added, edited, and deleted only while no screen uses them. All of it happens in one sheet, opened from the device pickers, or by "Save as Device…" on a screen. Sizes must be finite and 1–4,000 points.
12. **The design's text sizes reach the engine.**
    - `NaturalSize`, the engine and the rules read the design's tokens.
    - The node views draw with them.
    - A change of tokens lays every screen out once.
    - Why: §14 says the engine's defaults read the tokens, and no plan threads them. Without this, the token editor's text sizes would change nothing on the canvas. A token change is a design-wide change, not an edit, so laying everything out once is allowed.
13. **Ink reads and writes the tree.** `DrawingSync` finds the canvas's drawing nodes, and writes them, on the tree.
    - Why: it runs on every change. On the projection it would lower the design every time.
14. **Counter tests count; they never time.** A drag counter's lower bound, which holds only when SwiftUI renders every frame, goes. The upper bound stays exact. New counter tests assert upper bounds and "at least once" only, and retry up to three times while another suite has SwiftUI building every view, as `CanvasTargetsWorkTests` does.
    - Why: they have flaked under parallel CPU load, and under load SwiftUI folds frames, so fewer is never more work.
15. **The test-fallout policy gains clauses (i) and (j)**, below.
16. **What stays on the projection** is named in Task 12, with the plan that moves each part.

## Global Constraints

- **Platform:** iPadOS 27, Swift 6 strict concurrency, Swift Testing for unit tests (`@Suite`, `@Test`, `#expect`). Regenerate the project with `xcodegen generate` after adding files, and commit `Layer.xcodeproj/project.pbxproj` with the task.
- **macOS builds:** everything in `Layer/Tree/` must build on macOS too, because the harnesses compile app sources there. So there is no UIKit and no SwiftUI in `Layer/Tree/`, and text is measured with Core Text. The projection lives in `Layer/Model/Projection/`, never in `Layer/Tree/`.
  - New: `TreeTargets`, `TreeDrop`, `TreeIndex+Pose` and `TreeEdit+Group` are in `Layer/Tree/`. `NodeParent`, from plan 2, must be there too. If plan 2 left it in `Layer/Model/`, Task 1 moves it to `Layer/Tree/TreeEdit.swift`.
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
- **Undo semantics stay.**
  - Every step is a three-way, per-property revert of only its own changes.
  - Gestures, Format runs, voice commands and generations each stay one step.
  - These stay: `putOnTop`, `markNeedsSaving`, `onlyScreen(changedBy:)`, withdrawing steps that change nothing, and the cap of 50.
- **Ids are stable.** No verb or projection write changes a node's id, except duplicate, which makes new ones.
- **No layout in a SwiftUI `body`**, and no whole-tree layout on an edit. Layout runs only in `TreeRules`, in the store's change, on read, and off the main actor before a commit.
- **Projection code** carries the comment `// PROJECTION: deleted in plan 6` on every type and extension that exists only for it.
- **New: the canvas and panels never lower the projection.** Nothing in these reads `store.screens`, `store.floating`, `store.element(_:)`, `store.resolve(_:)` or `DesignContent`'s element members, except the callers Task 12 names:
  - `Layer/Canvas`;
  - `Layer/Chrome`;
  - `Layer/Model/{Groups,LayerOrder,SeveralThings,Enclosure,TurnSession}.swift`;
  - the parts of `AppModel` that run on a change, a tap or a drag frame.

  `TreeProjection.lowerings` is the check.
- **New: views compare values.** Every new canvas or panel view that is drawn per node or per row is `Equatable` over what it shows, and is used with `.equatable()`. It reads nothing from the model or environment that changes per frame.
- **Green.** After every task:
  - the app builds;
  - the full unit suite passes;
  - the UI suite fails no test outside plan 1's recorded baseline set (spec My call 19).

  The UI suite runs at the end of every task. XCUITest can't pinch, twist, rest a finger or make Pencil input, and a tap finding something doesn't prove ink is drawn there.
- **The test-fallout policy.** A test written before this plan may be changed or retired only if it asserts one of these:
  - (a) the v1–v3 file or its readers: the JSON keys `elements` or `floating`, a top-level `canvas` object of settings, `drawing.data`, or a version below 4;
  - (b) a flat-list state the tree can't hold:
    - a group pointer to a missing group, a group on another host, or a group that makes a loop;
    - a drawing inside a group's block;
    - a group item that isn't just in front of its members;
  - (c) members of one canvas group at different scales;
  - (d) a write count the tree lowers, such as a container moved as one write instead of one write per member;
  - (e) floating-point noise below 1e-9 from composing transforms through a turned container. Switch to the file's `close` helper, or add one with tolerance 1e-6;
  - (f) it calls an API plan 3 replaced, and only the call changes, to its replacement;
  - (g) a stubbed hosted model answers in the written form;
  - (h) a record of something plan 3 deleted.
  - New in plan 4:
  - (i) it calls a canvas or panel API this plan replaces, and only the call changes, to its replacement. What it asserts stays. The APIs are:
    - `PhoneScreenView(screen:)` and `FloatingElementView`, which become `ScreenView` and `CanvasNodeView`;
    - `ElementView(element:)` in a view test, which becomes `ElementView(node:)`;
    - `targetElements(entered:)`, `targets(on:entered:)` and `leaf(at:in:)`, which become `treeTargets(entered:)` and `TreeTargets.leaf(at:in:content:index:)`;
    - `layerTree(on:)`, `LayerListNode` and `drawings`, which become `LayerRows`;
    - `TurnSession.placed(turnedBy:)`'s result;
    - plan 3's `ScreenDrawing`, `DesignScreen.drawing` and `ElementView.init(element:isLaidOut:)` (`CardDrawingTests`), which become node views;
    - `AssetLibrary.templatePreview(named:)`, which becomes `templateRoot(named:)`.
  - (j) a counter's lower bound that holds only when SwiftUI renders every frame. The lower bound becomes `>= 1`, and the upper bound stays exactly as it was.

  No clause covers a selection, hit-test, move, turn, Format or Layers behaviour: the ported suites must pass with their assertions unchanged.

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
  - **Lanes B and C** run in their own worktrees (`.claude/worktrees/st4-lane-b`, `.claude/worktrees/st4-lane-c`). Their branches are `st4/lane-b` and `st4/lane-c`, cut from `feature/semantic-tree` once Task 1 is merged. Their commands are the same with:
    - simulator `Layer iPad Pro 11 (st4-lane-b)` or `Layer iPad Pro 11 (st4-lane-c)`, each cloned from `iPad Pro 11-inch (M5)`;
    - DerivedData `$HOME/Library/Developer/Xcode/DerivedData/Layer-st4-lane-b` or `-st4-lane-c`.
  - A lane's task is reviewed, then merged into `feature/semantic-tree`. Resolve `project.pbxproj` conflicts by re-running `xcodegen generate`.
  - When the plan ends, delete the lane worktrees, their simulators and their DerivedData.

## Review Focus

1. **A drag in a row, column or grid.**
   - The slot is the one the line shows.
   - The drop reorders, takes the thing out where it was let go (fixed on both axes), or puts it in the row under the finger.
   - Nothing is written until the drop, and the drag is one undo step.
   - Locked, hidden and its own subtree never take it.
   - Owned by:
     - Task 4: `TreeDropTests` (all), `draggingARowChildWritesNothingUntilTheDrop`, `droppingOutsideTakesItOutWhereItWasLetGo` and `aLiftCutShortLandsAsADropWould`;
     - Task 12: `testDraggingAThingInAColumnReordersIt`.
2. **Drawing only what changed, and never the projection.** One edit re-evaluates only the views on its path. A drag frame lowers nothing while the canvas, Layers and Format panels show. Owned by:
   - Task 2: `oneEditRebuildsOnlyTheViewsOnItsPath`;
   - Task 3: `findingTargetsDoesNotLower`;
   - Task 12: `aDragWithEveryPanelOpenLowersNothing`.
3. **Today's selection rules, with containers.** A tap picks the outermost container first, a double-tap goes in, a gap picks the container, turned shapes are hit as turned, the near miss holds, and the lasso picks whole. Owned by:
   - Task 3: `aContainerIsOneTargetUntilGoneInto`, `aCardOrRowIsPickedWholeUntilGoneInto`, `aGapInAContainerPicksIt` and `aTurnedContainersChildIsHitByItsTurnedShape`;
   - `MultiSelectionTests` and `GroupTests`' "Selecting groups", unchanged.
4. **Geometry through turned and nested containers.**
   - Placing, turning several things and ungrouping land exactly where asked, and turning back restores the tree exactly.
   - A laid-out child turns in place, and resizes only the axis it changed.
   - Owned by:
     - Task 1: `placingUnderATurnedContainerLandsWhereAsked`;
     - Task 5: `severalThingsTurnAboutTheFixedPivotAndBackExactly`, `aThingInsideATurnedContainerTurnsAboutTheSharedPivot` and `resizingARowChildFixesOnlyTheAxisItChanged`;
     - Task 6: `ungroupingATurnedCardFromThePopoverKeepsPlaces`.
5. **What people type into the panels.**
   - Format numbers keep their commit rules, and layout numbers that are bad or out of range are clamped.
   - A custom size of zero, negative, non-finite or over 4,000 is refused, and a device in use isn't deleted.
   - Token edits keep plan 2's reading rules.
   - Owned by:
     - Task 7: `badLayoutNumbersAreClamped`, and `FormatPanelTests`, unchanged;
     - Task 9: `aDraftWithABadSizeIsRefused`, `aDeviceInUseIsNotDeleted` and `tokensTypedAreReadAsPlan2Reads`.

**Order and lanes:**
- Lane A (this worktree): Tasks 1, 2, 3, 4, 5, 12.
- Lane B (`st4-lane-b`): Tasks 6, 7, 9.
- Lane C (`st4-lane-c`): Tasks 8, 10, 11.
- Waits:
  - Lanes B and C begin once Task 1 is merged.
  - Task 11 waits for Task 2 to be merged.
  - Task 12 waits for every other task.
- No two lanes edit the same file before Task 12.
  - Lane A owns:
    - `AppModel.swift`, `SelectionLayer.swift`, `CanvasScreen.swift` and `PhoneScreenView.swift`;
    - `Groups.swift`, `SeveralThings.swift`, `DesignStore.swift`, `TurnSession.swift`, `Enclosure.swift` and `ElementLayout.swift`.
  - Lane B owns `SelectionActions.swift`, `StylePanel.swift`, and the engine files `NaturalSize.swift`, `LayoutEngine.swift` and `TreeRules.swift`.
  - Lane C owns `LayersPanel.swift`, `DrawingSync.swift`, `InkCanvas.swift` and `AssetLibrary.swift`.
  - New files belong to the task that makes them.

---

### Task 1: The canvas's reads and writes on the tree

**Lane:** A (first; lanes B and C wait for it)

**Files:**
- Create: `Layer/Tree/TreeIndex+Pose.swift`, `Layer/Model/DesignStore+Canvas.swift`
- Modify:
  - `Layer/Model/SeveralThings.swift`: `canvasShape(of:)`, `canvasFrame(of:)`, `isLocked(_:)`, `things(in:)` and `canvasFrames(besides:)` read the index;
  - `Layer/App/AppModel.swift`:
    - `selectedNode`, `selectedScreenID` and `selectedLeafNodes` are added;
    - `dropSelectionOfMissingThings` reads the index;
    - `addAsset` resolves a frame's device through the design's settings;
    - the four projection accessors are marked `// PROJECTION: deleted in plan 6`.
  - `Layer/Tree/TreeEdit.swift` gets `NodeParent`, only if plan 2 left it in `Layer/Model/`.
- Test: `LayerTests/CanvasOnTheTreeTests.swift`

**Interfaces:**
- Consumes:
  - plan 1: `TreeIndex` (`Entry.toHost`, `hostShape`, `ancestors`, `canvasShape(of:in:)`), `transformToParent`, `TurnedRect`, `Placement`;
  - plan 2: `store.tree`, `store.index`, `node(_:)`, `parent(of:)`, `move(_:to:at:)`, `update(_:_:)`, `NodeParent`, `CanvasSettings.device(named:)`, `ListWork`, `TreeProjection.lowerings`.
- Produces:
  ```swift
  extension TreeIndex {                         // Layer/Tree/TreeIndex+Pose.swift
      /// Its upright frame in its host's own points (screen points; on the canvas, its top-level node's own points),
      /// centred on its turned shape's centre, with its summed angle: what the Format panel and the summary show.
      func ownPose(of id: UUID, in content: TreeContent) -> (frame: CGRect, degrees: Double)?
      /// How those own points sit on the canvas: the screen's origin and scale, or (0, 0) and the top-level node's scale.
      func placement(of id: UUID, in content: TreeContent) -> Placement?
  }
  struct PlacedNode: Equatable {
      var ref: DesignStore.ElementRef
      var node: LayerNode
      var frame: CGRect                         // its own pose
      var degrees: Double                       // summed with its ancestors'
      var placement: Placement
      var parentLayout: LayerNode.Layout        // .free under a free container, a free root, or at the canvas's top
      var isLocked: Bool                        // with its ancestors
      var isHidden: Bool
      var isLaidOut: Bool { get }               // parentLayout != .free
  }
  extension DesignStore {
      func treeScreen(_ id: TreeScreen.ID) -> TreeScreen?
      func ref(of id: UUID) -> ElementRef?      // nil for a screen root or an unknown id
      func placed(_ id: UUID) -> PlacedNode?
      /// A node's upright frame, given in its host's own points. Under a free parent: through the parent's inverse
      /// transform, its subtree riding along; whole points, drawings exact. Under a laid-out parent: My call 20.
      /// One write (`ListWork`).
      func place(_ id: UUID, at ownFrame: CGRect)
      /// A screen's own fields and its root's layout, in one change; the root's children stay as they are.
      func updateTreeScreen(_ id: TreeScreen.ID, _ body: (inout TreeScreen) -> Void)
  }
  extension TreeScreen {
      var placement: Placement { get }
      func canvasFrame(on device: DeviceFrame) -> CGRect
      func labelFrame(on device: DeviceFrame) -> CGRect          // today's DesignScreen.labelFrame numbers
  }
  extension AppModel {
      var selectedNode: PlacedNode? { get }
      var selectedScreenID: TreeScreen.ID? { get }
      /// What is selected, each container standing for its leaves at any depth; back to front, once each.
      var selectedLeafNodes: [PlacedNode] { get }
  }
  ```

- [ ] **Step 1: Write the failing tests** in `CanvasOnTheTreeTests` (`@MainActor`):
  - `ownPosesAddUpThroughUprightContainers`: a free G at (100, 200, 50, 50) holds X at (10, 20, 30, 40). `ownPose(X).frame == (110, 220, 30, 40)` exactly, and `degrees == 0`.
  - `ownPosesTurnWithTheirContainer`: G is at (100, 100, 200, 100), turned 90, holding a 20×20 child at (0, 0). The child's own frame is centred at (240, 60) within 1e-9, its size is 20×20, and its degrees are 90.
  - `aCanvasNodesOwnPoseIsInItsOwnPoints`: a sticky note at (100, 100, 150, 150) with scale 0.5 has own frame (100, 100, 150, 150), and `placement(of:) == Placement(origin: .zero, scale: 0.5)`.
  - `placingAFreeChildWritesOnlyIt`:
    - In the same G, `place(X, at: (130, 250, 30, 40))` gives X the local frame (30, 50, 30, 40), and its sibling is unchanged.
    - `ListWork.elementsWritten` rose by 1, and `TreeProjection.lowerings` by 0.
  - `placingAContainerCarriesItsSubtree`: placing G 10 points right moves its local origin by 10, and its children's local frames are unchanged.
  - `placingUnderATurnedContainerLandsWhereAsked`: G is turned 30. After `place(X, at: (150, 140, 20, 20))`, `ownPose(X).frame` is within 1e-6 of that, and X's own `rotation` is unchanged.
  - `placingARowChildFollowsMyCall20`:
    - The same origin with width + 40 gives `width == .fixed` and `frame.width` + 40, and it is still the row's child.
    - A new origin makes it the free root's last child, at that own frame, `.fixed` on both axes.
  - `refsComeFromTheIndex`:
    - A text inside a card on screen S gives `ref(of:) == ElementRef(host: .screen(S), element: id)`.
    - A canvas node gives `.canvas`.
    - The screen's root gives nil.
  - `theCanvasReadsTheSelectionWithoutLowering`: with a text inside a card selected, reading each of these ten times raises `TreeProjection.lowerings` by 0:
    - `selectedNode`, `selectedThings` and `selectedLeafNodes`;
    - `store.canvasShape(of: selection)` and `isSelectionLocked`.
  - `aContainerStandsForItsLeaves`: selecting `card[t1, row[t2, t3]]` gives `selectedLeafNodes.map(\.node.id) == [t1, t2, t3]`.
  - `aLaidOutChildIsPlacedAsLaidOut`: a column's child's `placed(_:)` has `isLaidOut == true`, and a free root's child has `false`.
  - `aCustomFrameFromTheLibraryMakesAScreenOfIt`: with `settings.customDevices == [watch]` (198×242), `model.addAsset` of `.frame(watch.id)` adds a screen whose `deviceID == watch.id` and whose root frame is (0, 0, 198, 242).
  - `aScreensOwnFieldsChangeInOneStep`: renaming through `updateTreeScreen` is one undo step, and the root's children are equal before and after.

- [ ] **Step 2: Run them.** Run `CanvasOnTheTreeTests`. Expected: FAIL (`ownPose`, `PlacedNode` and `place` don't exist).

- [ ] **Step 3: Implement.**
  - `ownPose`: the `hostShape` centre (divided by the top-level scale on the canvas) with the node's own size and summed angle.
  - `place(_:at:)`: the own centre through the inverse of the parent's `toHost` (identity for a root's child, ÷ scale at the canvas's top), then origin = centre − size / 2. Under a laid-out parent it uses plan 2's My call 20 path: `move` to the host's root, then the frame, `.fixed`.
  - `things(in:)`: screens first, then each host's nodes in draw order (depth first, children in order), things inside a selected container left out. That is today's order.
  - `PlacedNode` is built from one index entry and one `node(_:in:)`.
  - `addAsset`'s `.frame(id)` uses `store.tree.settings.device(named:)`.

- [ ] **Step 4: Run them.** Run `CanvasOnTheTreeTests`. Then run these, which must pass unchanged:
  - `MultiSelectionTests`, `GroupTests` and `RotationTests`;
  - `CanvasHitTestTests`, `FormatPanelTests` and `LayersPanelTests`;
  - `PerformanceFixTests` and `AssetLibraryTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Canvas reads and writes the tree: a node's own pose and placement from the index, place through the parent's inverse, and the selection read without the projection"`

---

### Task 2: Drawing the tree: node views, screens, the canvas and thumbnails

**Lane:** A

**Files:**
- Create: `Layer/Canvas/NodeView.swift` (`NodeView`, `ScreenView`, `CanvasNodeView`, and `CanvasWork.nodeViewsBuilt`), `Layer/Model/LayerNode+Look.swift`
- Modify:
  - `Layer/Canvas/PhoneScreenView.swift`:
    - `ElementView` holds a `LayerNode`;
    - the device chrome moves into `ScreenView`;
    - `PhoneScreenView` and `FloatingElementView` are deleted;
    - `ElementView(element:)` stays as a marked convenience.
  - `Layer/Canvas/CanvasScreen.swift`: screens from `store.tree.screens`, then canvas nodes; a locked drawing at zIndex 3; a screen being dragged from raised.
  - `Layer/Chrome/ShareMenu.swift`: `BoardSnapshot` draws `ScreenView` and `CanvasNodeView`.
  - `Layer/Model/DesignStore.swift`: `contentBounds` reads the index.
  - `Layer/Model/Design.swift`: `DesignScreen.drawing` is deleted.
  - `Layer/Model/Projection/TreeProjection.swift`: the lowering no longer fills `drawing`.
- Delete: `Layer/Model/Projection/ScreenDrawing.swift`
- Modify (fallout i): `LayerTests/CardDrawingTests.swift`, whose cases move into `NodeViewTests`, and `LayerTests/SystemSymbolTests.swift` (its `ElementView` call).
- Test: `LayerTests/NodeViewTests.swift`

**Interfaces:**
- Consumes:
  - Task 1: `treeScreen(_:)`, `TreeScreen.placement`, `canvasFrame(on:)`, `labelFrame(on:)`;
  - plan 2: `device(of:)`, `DesignTokens`;
  - plan 3: `ElementView.TextFit` and `textFit(for:isLaidOut:)`;
  - plan 1: `NaturalSize.fontSize(of:)`.
- Produces:
  ```swift
  struct NodeView: View, Equatable {
      let node: LayerNode
      let isLaidOut: Bool              // its parent lays it out: text whole, top-aligned, never shrunk (My call 18)
      let tokens: DesignTokens         // a card with no fill or radius of its own, and text with no size of its own
      // A container: a card's look filling its frame, then each visible child framed, turned about its centre and
      // offset to its origin in this node's space, in order. Nothing clips. A leaf: ElementView(node:).
  }
  struct ScreenView: View, Equatable {
      let screen: TreeScreen; let device: DeviceFrame; let tokens: DesignTokens; var showsName = true
  }
  struct CanvasNodeView: View, Equatable {   // framed, scaled by its scale, turned about its scaled centre, at its canvas origin
      let node: LayerNode; let tokens: DesignTokens
  }
  extension ElementView {
      init(node: LayerNode, isLaidOut: Bool = false, tokens: DesignTokens = .standard)
      init(element: DesignElement, isLaidOut: Bool = false)    // PROJECTION: deleted in plan 6
  }
  extension LayerNode {                      // the same values DesignElement's for the same fields
      var resolvedTint: RGBColor { get }
      func resolvedFontSize(tokens: DesignTokens) -> CGFloat   // style ?? tokens' title, body or text ?? NaturalSize's
      var resolvedFontWeight: FontWeightChoice { get }; var resolvedTextColor: RGBColor { get }
      func resolvedCornerRadius(tokens: DesignTokens) -> CGFloat   // a card with none: tokens.card.radius
      var resolvedOpacity: Double { get }; var resolvedButtonLook: ButtonLook { get }; var resolvedValue: Double { get }
      var resolvedTextAlignment: TextAlignmentChoice { get }
      var resolvedBorderWidth: CGFloat { get }; var resolvedBorderColor: RGBColor { get }
      var hasFill: Bool { get }; var hasCornerRadius: Bool { get }; var hasBorder: Bool { get }
      var displayName: String { get }
  }
  #if DEBUG
  extension CanvasWork { static var nodeViewsBuilt: Int }   // each NodeView body evaluated
  #endif
  ```

- [ ] **Step 1: Write the failing tests** in `NodeViewTests`. Pictures are made with `ImageRenderer` at scale 1, with `.environment(ImageLibrary())`. A colour matches when each channel is within 2/255.
  - `aChildIsDrawnFrameThenTurnThenOffsetInItsParent`:
    - A free root holds G at (100, 100, 200, 100), turned 90, which holds a filled red square shape at (0, 0, 20, 20).
    - In `ScreenView`'s picture, the pixel at (240, 60) is red, and the pixel at (110, 110) is not.
  - `aCardDrawsItsLookUnderWhatItHolds`: ported from `aCardsFillIsDrawnUnderItsText`. The pixel at (card.minX + 4, card.midY) is `0xF2F2F7`, and the pixel at (card.minX − 4, card.midY) is white.
  - `aCardWithoutItsOwnFillTakesTheDesignsTokens`: with tokens whose card fill is `0x112233`, that pixel is `0x112233`. A card whose `style.tint` is set keeps its own fill.
  - `hiddenNodesAreNotDrawnAndNothingClips`: a hidden child's pixel is white. A square at x 380 on a 393-wide screen is drawn at x 395, past the edge, when the picture is 420 wide.
  - `canvasNodesDrawAtTheirScale`: a filled red square at (100, 100, 100, 100) with scale 0.5. In `CanvasNodeView`'s picture, (75, 75) is red, and (125, 125) is not.
  - `laidOutTextIsDrawnWholeAndTopAligned`: plan 3's `textFit` assertions, unchanged, now through `ElementView(node:isLaidOut:)`.
  - `nodeLooksAreElementLooks`: for every leaf kind and a fully styled element `e`, every resolved value of `LayerNode(element: e)` equals `e`'s, with the standard tokens.
  - `theDesignsTextSizesAreDrawn`: with tokens whose title size is 34, `LayerNode(kind: .title).resolvedFontSize(tokens:) == 34`, and a title whose `style.fontSize` is 20 gives 20.
  - `theBoardSnapshotDrawsTheTree`: `BoardSnapshot.thumbnailParts(of: model)`'s picture shows the card's fill at its place.
  - In `HostedWindowSuites`, `.serialized`:
    - `oneEditRebuildsOnlyTheViewsOnItsPath`:
      - A free root holds `G[B, C]` and 40 lines. Show `ScreenView` in a window, and settle as `CanvasTargetsWorkTests` does.
      - Set C's text 20 times, settling after each.
      - `CanvasWork.nodeViewsBuilt` rose by at least 1, and by at most 20 × 3 + 10: the root, G and C each time, never the 40 lines.
      - It is measured up to three times while the count is over the bound.

- [ ] **Step 2: Run them.** Run `NodeViewTests`. Expected: FAIL (the views don't exist).

- [ ] **Step 3: Implement.**
  - `NodeView.body` counts itself (DEBUG), and draws per the comment in the Interfaces. Each child is `NodeView(...).equatable()`.
  - `ScreenView` is today's device chrome round `NodeView(root, isLaidOut: false, tokens:)`.
  - `CanvasNodeView` is today's `FloatingElementView` order.
  - An unlocked drawing draws nothing, because PencilKit draws it, and a locked one draws `InkPicture`, as today.
  - `CanvasScreen` reads `store.tree.screens` with `store.device(of:)`, and `store.tree.canvas`, each `.equatable()`.
  - `BoardSnapshot` uses the same views, and `contentBounds` is the union of the index's canvas shapes and the screens' frames.
  - Delete `ScreenDrawing`, `DesignScreen.drawing` and the lowering's fill.

- [ ] **Step 4: Run them.** Run `NodeViewTests`. Then run these, which must pass unchanged (except the fallout listed):
  - `CardDrawingTests` (ported), `CanvasDragWorkTests` and `CanvasHitTestTests`;
  - `DrawingTests`, `FreeformTests`, `SystemSymbolTests`, `PerformanceFixTests` and `DesignTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Canvas draws the tree: recursive node views compared by value, cards and laid-out text from the node, the canvas and thumbnails through the same views"`

---

### Task 3: Hit-testing and selection on the tree

**Lane:** A

**Files:**
- Create: `Layer/Tree/TreeTargets.swift`
- Modify:
  - `Layer/Model/Groups.swift`:
    - `pickTarget(for:entered:)`, `nextLevel(in:towards:)` and `groups(holding:)` read the index, and treat any container as a group;
    - `unlock(_:)` unlocks locked ancestors through the index;
    - `targets(on:entered:)`, `targetElements(entered:)` and `leaf(at:in:)` are deleted.
  - `Layer/Model/SeveralThings.swift`: `setLocked` writes the nodes' own flags.
  - `Layer/Model/DesignStore.swift`: `keptTargets` holds `TreeTargets`.
  - `Layer/Model/Enclosure.swift`: `things(enclosedBy:)` reads each host's top-level nodes.
  - `Layer/App/AppModel.swift`:
    - `hoverTarget`, `topmost`, `targetTapped`, `enteredGroups` and `isNearMiss` read the tree;
    - `toggleHidden` drops hidden descendants from the selection through the index.
  - `Layer/Canvas/SelectionLayer.swift`: `ElementTargets` are built from `TreeTargets`, and `SelectionSummary`, made internal, names a container's layout.
- Modify (fallout):
  - under (i), `LayerTests/PerformanceFixTests.swift`: `whatCanBeTouchedIsAsItWasForGroupsHiddenAndGoneInto` reads `treeTargets`, and its assertions stay;
  - under (j), `LayerTests/CanvasDragWorkTests.swift`: `aGroupDragBuildsOnlyItsOwnTarget` asserts `(1...70).contains(built)` instead of `(60...70)`, and its retry loop runs `where built > 70`.
- Test: `LayerTests/TreeTargetsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`placed`, `ref(of:)`, `ownPose`); plan 1 `TreeIndex`; today's `CanvasWork.targetPasses`, `targetsBuilt` and `GroupWork.leafWalks`.
- Produces:
  ```swift
  struct TreeTargets: Equatable, Sendable {      // Layer/Tree
      struct Target: Equatable, Sendable {
          var id: UUID; var shape: TurnedRect     // canvas points
          var isContainer: Bool; var isLocked: Bool
      }
      /// Each host's targets, back to front as drawn. A container not entered is one target, picked by its box; one
      /// entered gives way to its children; a screen's root is always entered. Hidden things, unlocked drawings and
      /// containers with nothing showing have none. On the canvas, locked drawings come last.
      init(_ content: TreeContent, index: TreeIndex, entered: Set<UUID>)
      private(set) var hosts: [TreeIndex.Host: [Target]]
      /// The topmost visible leaf inside `container` holding a canvas point, at any depth; nil in a gap.
      static func leaf(at point: CGPoint, in container: UUID, content: TreeContent, index: TreeIndex) -> UUID?
  }
  extension DesignStore {
      /// Memoised per design version and entered set. `CanvasWork.targetPasses` counts each build.
      func treeTargets(entered: Set<UUID>) -> TreeTargets
  }
  extension SelectionSummary {
      /// "W × H"; "Row · W × H", "Column", "Grid", "Overlay", "Card" or "Group · W × H"; "Drawing · N strokes";
      /// "N items · W × H"; "<screen> · W × H".
      @MainActor static func value(for model: AppModel) -> String?
  }
  ```

- [ ] **Step 1: Write the failing tests** in `TreeTargetsTests` (`@MainActor`). The board is a free root `[A, card[t1, row[t2, t3]]]` unless a test says otherwise.
  - `aContainerIsOneTargetUntilGoneInto`: the screen's targets' ids are:
    - `[A, card]` with nothing entered;
    - `[A, t1, row]` with `[card]` entered;
    - `[A, t1, t2, t3]` with `[card, row]` entered.
  - `aCardOrRowIsPickedWholeUntilGoneInto`:
    - A tap on t2 selects the card.
    - A second pick of the same point within 350 ms selects the row, and a third selects t2.
  - `aGapInAContainerPicksIt`: a point in the row's gap gives `hoverTarget == .element(card)` with nothing entered, and `.element(row)` with the card entered.
  - `aTurnedContainersChildIsHitByItsTurnedShape`: in a G turned 45, a point inside the child's turned shape but outside its upright box hits it. A point inside its upright box but outside the turned shape misses it.
  - `hiddenThingsAreLookedThroughAndLockedOnesCanBeGoneInto`:
    - A hidden card has no target, and A behind it is hit.
    - A locked card is picked, and a double-tap goes in to t1.
  - `aLockedDrawingIsTheCanvasesLastTarget`.
  - `theLassoPicksTopLevelContainersWhole`:
    - A loop round the card gives `[.element(card)]`.
    - A loop round half of it gives nothing.
    - A screen 90% inside gives `.screen`.
  - `aContainersSummaryNamesItsLayout`: `SelectionSummary.value(for:)` gives exactly:
    - `"Row · 220 × 44"` for a 220×44 row;
    - `"Card · 353 × 120"`, `"Column · …"`, `"Grid · …"` and `"Overlay · …"`;
    - `"Group · …"` for a free group;
    - `"200 × 24"` for a text.
  - `findingTargetsDoesNotLower`: `treeTargets(entered:)`, `hoverTarget(at:)` and `pick` raise `TreeProjection.lowerings` by 0.
  - `targetsAreBuiltOncePerVersionAndEntered`: ten reads raise `CanvasWork.targetPasses` by 1, and a change raises it by 1 more.
  - `unlockingAChildOfALockedCardUnlocksTheCard`: Ruling D.
  - `hidingAContainerDropsWhatIsInItFromTheSelection`.

- [ ] **Step 2: Run them.** Run `TreeTargetsTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `TreeTargets` walks each host once, in draw order. `leaf(at:)` walks one container front to back and counts `GroupWork.leafWalked()`.
  - `pickTarget` is the outermost container not entered; `enteredGroups` is the containers holding something selected.
  - `ElementTarget` compares its id, shape, lock and minimum, and its counter is unchanged.
  - `SelectionSummary` uses `selectedNode`, `selectedScreenID` and `value(for:)`.
  - Delete the three old target functions.

- [ ] **Step 4: Run them.** Run `TreeTargetsTests`. Then run these, which must pass unchanged (except the fallout listed):
  - `MultiSelectionTests`, `GroupTests` ("Selecting groups", and the rest), `GroupFinalFixTests` and `CanvasHitTestTests`;
  - `CanvasDragWorkTests`, `PerformanceFixTests` and `PencilVoiceTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Selection on the tree: targets from the index with any container picked whole until gone into, the lasso and box on each host's top level, a container's summary naming its layout"`

---

### Task 4: Moving: free moves on the tree, and drags in rows, columns and grids

**Lane:** A

**Files:**
- Create: `Layer/Tree/TreeDrop.swift`, `Layer/Canvas/LayoutDrag.swift` (the lifted copy and the insertion line)
- Modify:
  - `Layer/Canvas/SelectionLayer.swift`, in `CanvasDrags`:
    - free moves write through `place`;
    - `moveRule` snaps against the visible leaves on the same host, from the index, leaving out the thing's own subtree;
    - a laid-out child's drag lifts;
    - drops go through `TreeDrop`;
    - `SpacingOverlay` measures host-space frames.
  - `Layer/Model/ElementLayout.swift`: `SpacingGuides.measure(_ frame: CGRect, among: [CGRect], in container: CGRect?)`.
  - `Layer/App/AppModel.swift`: `rehost(_:)` renames through `ref(of:)`, and `screensBeingDraggedFrom` includes a lift's host.
  - `Layer/Canvas/CanvasScreen.swift`: the zIndex reads node ids.
- Test: `LayerTests/TreeDropTests.swift`, `LayerTests/LayoutDragTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3; plan 2's `move(_:to:at:)`, `rehost(_:)`, `position(_:)` and `NodeParent`; today's `CanvasDrags` API (`adjust`, `moveElement`, `dropElement`, `moveOnTarget`, `dropOnTarget`, `endAbandoned`), kept.
- Produces:
  ```swift
  enum TreeDrop {                                   // Layer/Tree; pure
      enum Target: Equatable, Sendable {
          case insert(into: NodeParent, at: Int, line: TurnedRect)   // the line in canvas points, 2 pt across the gap
          case free(on: TreeIndex.Host)                              // placed freely, as today
      }
      /// Where `id`, dragged to `point` (canvas points) with its centre at `centre`, would go: the deepest visible,
      /// unlocked row, column or grid under `point` that isn't `id` or inside it, at its slot; otherwise free on the
      /// screen under `centre` (the topmost), or the canvas.
      static func target(for id: UUID, at point: CGPoint, centre: CGPoint, in content: TreeContent, index: TreeIndex) -> Target
      /// The index among `children` without `skipping` that `point` (the container's own space) falls before:
      /// by mid-x in a row, mid-y in a column, and in a grid by row (the point's row band) then mid-x.
      static func slot(for point: CGPoint, among children: [LayerNode], skipping: UUID, layout: LayerNode.Layout) -> Int
  }
  extension CanvasDrags {
      struct Lift: Equatable {
          var ref: DesignStore.ElementRef
          var start: CGRect            // own frame as the drag began
          var translation: CGSize      // in the host's own points
          var target: TreeDrop.Target
      }
      var lift: Lift? { get }                  // a laid-out child's drag; nil otherwise
      var dropTarget: TreeDrop.Target? { get } // the line any single drag shows, free drags included
  }
  ```

- [ ] **Step 1: Write the failing tests.**

  In `TreeDropTests` (pure). The row is at (20, 100) on a free iPhone root at the canvas origin and scale 1. It holds a, b and c, each 80×40, at x 0, 100 and 200.
  - `aRowsSlotIsByMidX`: a, dragged to own x 150, gives slot 1. The order would then be `[b, a, c]`.
  - `aColumnsSlotIsByMidY`: a column holds a, b and c, each 100×30, at y 0, 40 and 80. a, dragged to own y 65, gives slot 1.
  - `aGridsSlotIsByRowThenX`: a 2-column grid holds four 100×30 cells at (0, 0), (110, 0), (0, 38) and (110, 38). d, dragged to own (40, 50), gives slot 2.
  - `theLineLiesInTheGap`: slot 1 in the row (b and c left in) gives the line `TurnedRect((209, 100, 2, 40), 0)`.
  - `theDeepestRowUnderThePointTakesIt`: a column root holds a row.
    - A point over the row gives `.insert(into: .node(row), …)`.
    - A point elsewhere on the screen gives `.insert(into: .screen(s), …)`.
  - `aThingNeverGoesIntoItself`: a row dragged over its own child gives its parent's slot, never `.node(row)`.
  - `lockedAndHiddenContainersTakeNothing`.
  - `offEveryLaidOutContainerItIsFree`:
    - On the free root outside the row it gives `.free(on: .screen(s))`.
    - Off every screen it gives `.free(on: .canvas)`.

  In `LayoutDragTests` (`@MainActor`, with `CanvasDragLandingTests`' board and helpers). The row is as above.
  - `draggingARowChildWritesNothingUntilTheDrop`:
    - Over 60 frames of b's drag, `ListWork.elementsWritten`, `store.contentVersion` and `TreeProjection.lowerings` are unchanged.
    - `drags.lift?.target` follows the finger.
  - `droppingInTheSameRowReorders`: a, dragged by (150, 0), drops as `[b, a, c]`. One undo, named "Move", restores `[a, b, c]`.
  - `droppingOutsideTakesItOutWhereItWasLetGo`:
    - b, dragged by (0, 200), is the free root's last child, with own frame (120, 300, 80, 40) and `.fixed` on both axes.
    - The row holds `[a, c]`.
  - `droppingIntoAnotherRowJoinsItAtTheLine`.
  - `aFreeThingDroppedOnAColumnScreenJoinsItAtTheLine`: a text on screen A (a free root), dropped over screen B (a column root) between B's second and third children, becomes B's root's child at index 2.
  - `aFreeThingDroppedOnAFreeScreenIsRehostedAsToday`: it lands on top, keeping its canvas place and own size.
  - `aMemberDraggedOutOfItsFreeGroupsBoxStaysInIt`: the box grows round it.
  - `snappingIsOnlyForFreePlacement`: while the lift is over the row, `drags.guides` is empty.
  - `aLockedRowChildIsNotDragged`.
  - `aLiftCutShortLandsAsADropWould`: `endAbandoned` mid-drag over slot 2 drops it at slot 2.

- [ ] **Step 2: Run them.** Run `TreeDropTests` and `LayoutDragTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `TreeDrop` walks the index's containers under the point, deepest first.
  - In `CanvasDrags.moveElement`, a laid-out child sets `lift`: no `act(for:)` per frame, only `translation` and `target`. A free thing places itself, and `dropTarget` is set for the line, with no guides while a line shows.
  - On a drop, `.insert` calls `move(_:to:at:)` and `.free` calls plan 2's `rehost`. A lift moved to `.free` is moved to the host's root and placed in the same change.
  - `LayoutDrag` draws the copy (`NodeView` at 0.7 opacity) at the lift's place, and the 2 pt accent line, in view points.

- [ ] **Step 4: Run them.** Run both suites. Then run these, which must pass unchanged:
  - `CanvasDragLandingTests`, `CanvasDragWorkTests` and `MultiSelectionTests` ("Dragging on the canvas");
  - `DrawingTests`, `FreeformTests` and `GroupTests` ("A group as one thing");
  - `ZoomRulerTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Moves on the tree: free things placed through their parent as today, and things in rows, columns and grids lifted to an insertion line, reordered, taken out or moved in on the drop"`

---

### Task 5: Resizing and turning on the tree

**Lane:** A

**Files:**
- Create: `Layer/Model/DesignStore+Turn.swift`
- Modify:
  - `Layer/Model/TurnSession.swift`: its parts are the selected nodes, with poses in canvas points. Plan 2's laid-out guard is folded in.
  - `Layer/App/AppModel.swift`: `turnSelection`, `turnEach`, `setAngle(of:to:)`, and `setGroupRotation` and `setGroupBox` for any container.
  - `Layer/Canvas/SelectionLayer.swift`: a laid-out child's handles resize through `resizeLaidOut`, and any container's through `resizeGroup`.
- Modify (fallout i): `LayerTests/RotationTests.swift` and `LayerTests/PerformanceFixTests.swift`, only where they read `placed(turnedBy:)`'s result.
- Test: `LayerTests/TurnAndResizeOnTheTreeTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4; plan 2's `resizeGroup(_:to:from:)`, `groupPose(of:)` and `isLaidOut(_:)`.
- Produces:
  ```swift
  struct TurnSession: Equatable {
      struct Pose: Equatable, Sendable { var centre: CGPoint; var degrees: Double }   // canvas points; summed angle
      struct Part: Equatable, Sendable { var id: UUID; var base: Pose; var turnsInPlace: Bool }  // a laid-out child
      var parts: [Part]
      static func form(for selection: CanvasSelection, in store: DesignStore) -> TurnSession?   // as today
      func placed(turnedBy degrees: Double) -> [UUID: Pose]
      // pivot, outline, turned, matches(_:), expect(_:), translate(by:), rehosted(as:in:), shape: as today
  }
  extension DesignStore {
      /// Each node to its canvas pose: its centre through its parent's inverse transform, its angle less its parent's
      /// summed angle. A laid-out child takes the angle only. One change.
      func setCanvasPoses(_ poses: [UUID: TurnSession.Pose])
      /// A laid-out child's handle: each axis whose size changed by more than 0.5 becomes `.fixed` at the new size.
      func resizeLaidOut(_ id: UUID, to size: CGSize, from start: CGSize)
  }
  ```

- [ ] **Step 1: Write the failing tests** in `TurnAndResizeOnTheTreeTests` (`@MainActor`):
  - `aContainerTurnedAloneSetsOnlyItsAngle`: a free card holds two texts. `beginTurn()`, then `turnSelection(by: 30, snaps: false)`, then `endTurn()`.
    - `card.rotation == 30`, and the texts' local frames are unchanged.
    - It is one step, "Rotate".
  - `severalThingsTurnAboutTheFixedPivotAndBackExactly`: a leaf and a card are selected. Turning 90, then back to 0 in the same session, leaves `store.tree` equal to before (`==`).
  - `aThingInsideATurnedContainerTurnsAboutTheSharedPivot`: X is in a free G turned 30, and Y is on the root, both selected. A turn of 45 puts X's canvas centre at `rotate(base, pivot, 45)` within 1e-6, and its canvas angle at base + 45 within 1e-9.
  - `aLaidOutChildTurnsInPlace`: in a row `[a, b, c]`, b turned 20 has `rotation == 20`. Every frame in the row, b's included, is unchanged.
  - `aFreeGroupStillHugsAMemberThatTurned`.
  - `resizingARowChildFixesOnlyTheAxisItChanged`: a fitting text, by `resizeLaidOut(to: (w + 40, h), from: (w, h))`, gets `width == .fixed` and `frame.width == w + 40`. Its height's mode stays `.fit`, and its origin is the engine's.
  - `aFreeCardResizesWhatItHoldsAsAGroupDoes`: a free card at (20, 100, 200, 100) holds a text at (16, 16, 100, 24) at 17 pt. Resized to width 400 from its pose, the text's own width is 200 and its font size is still 17.
  - `theRotationFieldTurnsAnyContainerAsOnePiece`: `setGroupRotation(card, to: 45)` gives `card.rotation == 45`, with its children's local frames unchanged.
  - `aTurnSessionIsFormedOncePerSelectionAndVersion`: `CanvasWork.turnSessionsFormed` rose by 1 over ten reads of `selectionShape`.

- [ ] **Step 2: Run them.** Run `TurnAndResizeOnTheTreeTests`. Expected: FAIL (`setCanvasPoses` and `Pose` don't exist).

- [ ] **Step 3: Implement.**
  - `form` makes one part per selected thing: an unlocked node, a container as one rigid part. The pivot and outline are as today.
  - `placed` turns each base about the pivot. A `turnsInPlace` part keeps its centre.
  - `matches` compares each part's current canvas pose with the expected one.
  - `setCanvasPoses` converts each pose to the host's own points, then into the parent's space, through `place` and `rotation` in one change.
  - The handle's rule is `resizeLaidOut` when `selectedNode.isLaidOut`, `resizeGroup` for a container, and today's `resizedTurned` for a leaf.

- [ ] **Step 4: Run them.** Run `TurnAndResizeOnTheTreeTests`. Then run these, which must pass unchanged (except the fallout listed):
  - `RotationTests` (every suite), `PerformanceFixTests` and `GroupTests` ("Group geometry");
  - `MultiSelectionTests`, `CanvasDragLandingTests` and `FormatPanelTests`.

  Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Turning and resizing on the tree: a container turns whole, several things about the fixed pivot through each parent's inverse, and a laid-out child turns in place and takes a fixed size"`

---

### Task 6: Group as Row, Column, Grid or Card, and lining up in laid-out parents

**Lane:** B (first)

**Files:**
- Create:
  - `Layer/Tree/TreeEdit+Group.swift`;
  - `Layer/Model/GroupAs.swift`;
  - `Layer/App/AppModel+Group.swift`;
  - `LayerUITests/LayoutUITests.swift`.
- Modify: `Layer/Chrome/SelectionActions.swift`. The changes:
  - the popover reads `selectedNode` and `selectedScreenID` to choose its buttons;
  - the Group button becomes a `Menu` with a primary action;
  - Ungroup is offered for any container;
  - the Align menu goes through `lineUpSelection`;
  - Distribute is off when the selection shares one laid-out parent.
- Test: `LayerTests/GroupAsTests.swift`; UI: `LayoutUITests.testGroupAsRowFromThePopoverMenu`

**Interfaces:**
- Consumes:
  - Task 1: `selectedNode`, `placed`;
  - plan 2: `wrap(_:in:layout:)`, `unwrap(_:)`, `update(_:_:)`, `asOneStep`, `TreeEdit.readingOrder(_:for:)`, `DesignTokens`;
  - today: `canGroup(_:)`'s rules (`groupable`), `ElementLayout.Alignment`, `alignSelection`, `canDistributeSelection`.
- Produces:
  ```swift
  enum GroupShape: String, CaseIterable, Sendable {      // Layer/Tree/TreeEdit+Group.swift
      case group, row, column, grid, card
      var title: String { get }                          // "Group", "Row", "Column", "Grid", "Card"
      var kind: ElementKind { get }                      // .card for card, else .group
  }
  extension TreeEdit {
      /// The layout `wrap` gets for siblings (parent space) grouped as `shape`: call 8's spacing, alignment, columns
      /// and card inside. `.free` for a group.
      static func groupedLayout(of nodes: [LayerNode], as shape: GroupShape, rhythm: [CGFloat]) -> LayerNode.Layout
      static func nearestStep(_ value: CGFloat, in rhythm: [CGFloat]) -> CGFloat     // the smaller on a tie
  }
  extension DesignStore {
      /// Today's `groupable` (one parent, unlocked, no drawings or screens), and a card may hold one thing.
      func canGroup(_ selection: CanvasSelection, as shape: GroupShape) -> Bool
      /// One step. Wrapped in reading order (stack, grid, card), each child fixed at its size, the container fitting on
      /// both axes, placed so the first thing in reading order keeps its top-left. Selects nothing; returns the container.
      @discardableResult func group(_ selection: CanvasSelection, as shape: GroupShape) -> ElementRef?
      /// When everything selected shares one laid-out parent: the layout that parent takes from an align button
      /// (a column: left, centres, right → start, centre, end; a row: top, middles, bottom; a grid or overlay: both).
      /// Nil when it doesn't apply, or the parent is free.
      func layoutAligned(_ selection: CanvasSelection, _ alignment: ElementLayout.Alignment) -> (parent: UUID, layout: LayerNode.Layout)?
  }
  extension AppModel {
      func groupSelection(as shape: GroupShape)                       // the new container becomes the selection
      func canGroupSelection(as shape: GroupShape) -> Bool
      /// In one laid-out parent: its alignment, as one step. Otherwise today's `alignSelection`.
      func lineUpSelection(_ alignment: ElementLayout.Alignment)
      func canLineUpSelection(_ alignment: ElementLayout.Alignment) -> Bool
  }
  ```

- [ ] **Step 1: Write the failing tests** in `GroupAsTests` (`@MainActor`, standard tokens):
  - `groupAsRowSortsByXFixesSizesAndKeepsTheFirstInPlace`:
    - Three 60×24 texts sit at (200, 100), (20, 100) and (110, 100).
    - The row's children are in x order (20, 110, 200), each `.fixed` at 60×24.
    - The spacing is 32: the gaps are 30, and the nearest step is 32.
    - The alignment is `.start`, and the first's own frame is still (20, 100, 60, 24).
  - `groupAsColumnReadsTopToBottom`: texts at y 300, 100 and 200 come out in y order, and leading edges that agree give `.start`.
  - `groupAsGridTakesItsColumnsFromTheFirstRow`:
    - Four 50×50 at (100, 0), (0, 0), (100, 60) and (0, 60) give `columns == 2`, in the order (0, 0), (100, 0), (0, 60), (100, 60).
    - `columnSpacing == 32` and `rowSpacing == 8`. A 10 gap ties between 8 and 12, so it takes the smaller.
    - Three in a row and one below give `columns == 3`.
  - `groupAsCardIsAColumnUnlessTheyShareARow`:
    - Two stacked texts give kind `.card` with a vertical stack, padding 16 on every side, and `.fit` on both axes.
    - Two side by side give a horizontal stack.
  - `aCardCanHoldOneThingAndTheOthersNeedTwo`: one text gives `canGroup(as: .card)` true, and false for `.row` and `.group`.
  - `thingsInDifferentContainersCantBeGrouped`: a root text and a card's text give false for every shape.
  - `allOfAFreeGroupIsRefusedOnlyAsAGroup`: both members of G[a, b] give false as `.group`, and true as `.row`.
  - `groupingIsOneUndoStep`: one undo leaves `store.tree` equal to before.
  - `lineUpInAColumnEditsItsAlignment`:
    - A column's child with Align Centres makes the column's `alignment == .center`, as one step.
    - With Align Top, `canLineUpSelection` is false, and nothing changes.
  - `lineUpInAFreeParentIsTodaysAlign`.
  - `arrangeIsOffForARowsChildAndOnInAnOverlay`: for a row's middle child, `model.canArrangeSelection(.forward)` is false. For an overlay's child that isn't frontmost, it is true (My call 15).
  - `ungroupingATurnedCardFromThePopoverKeepsPlaces`: for a card turned 90, `ungroupSelection()` leaves each child's canvas centre unchanged within 0.001, and selects the two children.

  `LayoutUITests.testGroupAsRowFromThePopoverMenu`:
  - Two sticky notes are tapped (as in `testGroupingFromThePopoverAndGoingInWithADoubleTap`).
  - `control("Group").press(forDuration: 1.0)`, then `app.buttons["Row"].tap()`.
  - The selection's value begins `'Row'`, and `layerRow("Row")` exists in Layers.

- [ ] **Step 2: Run them.** Run `GroupAsTests`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `groupedLayout` follows call 8.
  - `group(_:as:)` wraps inside `asOneStep`, then sets the container's origin.
  - `SelectionActions`: `Menu { ForEach(GroupShape.allCases) … } label: { ToolButton("Group") } primaryAction: { group() }`. The ⌘⌥G hidden button stays. Each item is disabled when `canGroupSelection(as:)` is false, with today's hint.

- [ ] **Step 4: Run them.** Run `GroupAsTests`. Then run `GroupTests` ("Group commands"), `GroupFinalFixTests` and `MultiSelectionTests`, which must pass unchanged. Then run the full unit suite and the UI suite, with `LayoutUITests`. `testGroupingFromThePopoverAndGoingInWithADoubleTap` must pass unchanged. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Group as Row, Column, Grid or Card from the popover's Group menu, laid out in reading order at their sizes; align in a laid-out parent sets its alignment"`

---

### Task 7: The Format panel: layout, sizing and a card's look

**Lane:** B (after Task 6)

**Files:**
- Create: `Layer/Chrome/LayoutSection.swift` (`LayoutSection`, `SizingSection`), `Layer/Model/DesignStore+Layout.swift`
- Modify: `Layer/Chrome/StylePanel.swift`. The changes:
  - `ElementSettings`, the containers' `ContainerSettings` (which was `GroupSettings`), `FrameSettings` and `SeveralSettings` read `selectedNode`, `selectedScreenID` and `selectedLeafNodes`;
  - they write with `update(_:_:)`, `place` and `updateTreeScreen`;
  - X and Y are off under a laid-out parent, and W and H go through sizing there;
  - the align row goes through `lineUpSelection`;
  - Several's Group button gets Task 6's menu.
- Test: `LayerTests/FormatPanelLayoutTests.swift`

**Interfaces:**
- Consumes:
  - Task 1: `PlacedNode`, `place`, `updateTreeScreen`, `selectedLeafNodes`;
  - Task 6: `GroupShape`, `groupedLayout`, `lineUpSelection`, `canLineUpSelection`;
  - plan 2: `setLayout(_:_:)`, `update(_:_:)`;
  - today: `NumberField`, `ColorField`, `model.adjusting`, `setGroupBox` and `setGroupRotation`.
- Produces:
  ```swift
  enum LayoutChoice: String, CaseIterable, Sendable {
      case free, row, column, grid, overlay
      init(_ layout: LayerNode.Layout)
      var title: String { get }
      static func choices(forScreenRoot: Bool) -> [LayoutChoice]          // [.free, .column] for a screen's root
      /// Row ↔ column keep spacing, alignment and justify; free → laid out takes Group as's layout; a grid keeps its
      /// columns, else Group as's; overlay is centred.
      func layout(from current: LayerNode.Layout, children: [LayerNode], rhythm: [CGFloat]) -> LayerNode.Layout
  }
  enum SizingChoice: String, CaseIterable, Sendable { case fit, fill, fixed; init(_ sizing: LayerNode.Sizing) }
  extension DesignStore {
      /// Spacing, alignment, justify, columns and axis of a laid-out container or a screen's root; non-finite or negative
      /// spacing reads as 0, and columns are clamped to 1–12. A free layout stays free.
      func updateLayout(_ id: UUID, _ body: (inout LayerNode.Layout) -> Void)
      func setPadding(_ id: UUID, _ padding: LayerNode.Padding)            // non-finite or negative sides read as 0
      /// One axis of a laid-out child: .fit, .fill(weight: 1), or .fixed at `points` (its size now when nil).
      func setSizing(_ id: UUID, axis: LayerNode.Axis, _ choice: SizingChoice, points: CGFloat? = nil)
  }
  struct LayoutSection: View, Equatable {   // picker; spacing; padding (not on a screen); alignment; distribution; columns
      let id: UUID; let layout: LayerNode.Layout; let padding: LayerNode.Padding; let isScreenRoot: Bool; let children: [LayerNode]
  }
  struct SizingSection: View, Equatable {    // Width and Height: Fit, Fill, Fixed + number
      let placed: PlacedNode
      /// Whether X and Y can be typed: false under a laid-out parent, overlays included (call 10).
      static func isPositionEditable(for placed: PlacedNode) -> Bool
  }
  ```
  The words are the spec's, plainly: alignment Start, Centre, End and Fill; distribution Start, Centre, End, Space Between, Space Around and Space Evenly. A grid has Columns (1–12), Column Spacing and Row Spacing, and a grid or overlay has horizontal and vertical alignment.

- [ ] **Step 1: Write the failing tests** in `FormatPanelLayoutTests` (`@MainActor`):
  - `aFreeCardBecomesARowSortedAndFixed`: `LayoutChoice.row` gives a horizontal stack, the children in x order, each `.fixed` at its size.
  - `rowToColumnKeepsSpacingAndAlignment`: spacing 12 and `.center` stay, and the axis flips.
  - `aRunOfLayoutChangesIsOneFormatStep`: spacing, padding and columns changed inside one `model.adjusting` run give one undo step, "Format".
  - `badLayoutNumbersAreClamped`:
    - Spacing −5 and `.nan` give 0.
    - Padding −1 gives 0.
    - Columns 40 give 12, and 0 give 1.
  - `aRowChildsSizingIsSetPerAxis`:
    - Fixed 120 gives `width == .fixed` and, after the rules, `frame.width == 120`.
    - Fill gives `.fill(weight: 1)`, and Fit gives `.fit`.
  - `xAndYAreOffForALaidOutChild`: `SizingSection.isPositionEditable(for:)` is false for a column's or an overlay's child, and true for a free root's.
  - `aScreenOffersFreeAndColumn`: `LayoutChoice.choices(forScreenRoot: true) == [.free, .column]`.
  - `aCardsFillIsItsOwnUntilReset`: Fill sets `style.tint`, and Default sets it to nil, so the card draws with the tokens.
  - `theAlignRowEditsAColumnsAlignment`.
  - `aScreensFieldsAreWrittenOnTheTree`: renaming a screen and changing its scale raise `TreeProjection.lowerings` by 0, as one step.

- [ ] **Step 2: Run them.** Run `FormatPanelLayoutTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the sections, the three store verbs, and the panel's reading from the tree. The typed-number rules (`TypedNumber`, `NumberDraft`, `Scrubber`, the ruler) are used as they are.

- [ ] **Step 4: Run them.** Run `FormatPanelLayoutTests`. Then run `FormatPanelTests` (every suite), `PanelStepTests`, `ZoomRulerTests` and `GroupTests`, which must pass unchanged. Then run the full unit suite and the UI suite. These must pass unchanged:
  - `testAGroupHasAFormatPanelOfItsOwn`;
  - `testATypedFormatNumberIsAppliedWhenTheCanvasIsTapped`;
  - `testThingsAreAddedFromTheBarAndStyledFromTheFormatPanel`.

  Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Format panel on the tree: a Layout section for containers and screens, Width and Height sizing for laid-out children, a card's fill, X and Y off where the engine places"`

---

### Task 8: The Layers panel from the tree

**Lane:** C (first)

**Files:**
- Create: `Layer/Model/LayerRows.swift`
- Modify: `Layer/Chrome/LayersPanel.swift`. The changes:
  - the rows come from `LayerRows`;
  - a container's row shows its layout's icon;
  - drops map to `moveLayer(_:to:before:)` on a `NodeParent`, through layout-order lists;
  - the Drawings section reads the tree;
  - `LayerListNode` is no longer used here.
- Modify (fallout i): `LayerTests/GroupTests.swift`'s suite "The layers tree" reads `LayerRows`, and its assertions stay.
- Test: `LayerTests/LayerRowsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`ref(of:)`); plan 2's `moveLayer(_:to:before:)`, `moveLayerToTop(_:of:)` and `NodeParent`; today's `pickInList`, `toggleLock`, `toggleHidden`, `enteredGroups` and `LayersPanelWork`.
- Produces:
  ```swift
  struct LayerLine: Equatable, Identifiable, Sendable {
      var id: UUID; var ref: DesignStore.ElementRef; var name: String; var symbol: String; var depth: Int
      var isContainer: Bool; var isOpen: Bool; var isLocked: Bool; var isHidden: Bool
      var isLockedByAncestor: Bool; var isDimmed: Bool
      var list: NodeParent               // the list the row is in
      var isLayoutOrder: Bool            // its list is a row's, column's or grid's: first at the top
  }
  enum LayerRows {
      /// A host's rows: its top-level things (a screen's root's children), each open container's children under it.
      /// Free and overlay lists topmost first; rows, columns and grids in layout order. Drawings are left out.
      static func lines(on host: TreeIndex.Host, in content: TreeContent, index: TreeIndex, open: Set<UUID>) -> [LayerLine]
      /// row "rectangle.split.3x1", column "rectangle.split.1x2", grid "square.grid.2x2", overlay "square.stack",
      /// card ElementKind.card.symbol, free group "rectangle.3.group"; a leaf, its own symbol or its kind's.
      static func symbol(for node: LayerNode) -> String
      static func drawings(in content: TreeContent) -> [UUID]          // the canvas's drawings, topmost first
      /// The `before` a drop above `row` means in `list`: the row itself in a topmost-first list, the next in layout order.
      static func before(_ row: UUID?, in list: [LayerLine], layoutOrder: Bool) -> UUID?
  }
  ```

- [ ] **Step 1: Write the failing tests** in `LayerRowsTests`:
  - `aScreensRowsFollowTheTree`: a free root `[A, G[B, C], D]` with G open gives ids `[D, G, C, B, A]` and depths `[0, 0, 1, 1, 0]`.
  - `aColumnsChildrenAreInLayoutOrder`: an open column `[x, y, z]` lists `[x, y, z]` under its row, with `isLayoutOrder` true.
  - `containersShowTheirLayout`: every case of the symbol table, and `UIImage(systemName:) != nil` for each.
  - `aRowDroppedInAColumnLandsWhereItWasDropped`: B, dropped above y in the column's list, gives the column `[x, B, y, z]`.
  - `theRefusalsAreTodays`: a locked thing, another screen's list, a container into itself and a drawing each leave the tree unchanged.
  - `lockAndHideComeFromAncestors`: a locked card's child has `isLockedByAncestor`, and a hidden row's child `isDimmed`.
  - `theDrawingsSectionListsTheCanvasesDrawingsTopmostFirst`.
  - `listingDoesNotLower`: `TreeProjection.lowerings` rose by 0.

- [ ] **Step 2: Run them.** Run `LayerRowsTests`. Expected: FAIL.

- [ ] **Step 3: Implement** `LayerRows` and the panel on it.
  - Rows stay `Equatable` over what they show.
  - `ContainerLayerRow` replaces `GroupLayerRow`, and shows its symbol.
  - `LayerDropList` carries the `NodeParent` and `isLayoutOrder`, so a drop's `before` is right in both orders.
  - The VoiceOver actions say "Move Into … Above" and "Move Out of …" with the container's name.

- [ ] **Step 4: Run them.** Run `LayerRowsTests`. Then run `LayersPanelTests` (all three, unchanged: 0 rows in a drag, ≤ 20 for ten hovers, code once), `LayerOrderTests` and `GroupTests`. Then run the full unit suite and the UI suite. `testLayersPanelRowsDragIntoAndOutOfGroups` and `testArrangeMenuSendsToBack` must pass unchanged. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Layers panel from the tree: a row for each node, an icon for each container's layout, laid-out containers in layout order, drags among containers with today's refusals"`

---

### Task 9: Custom device frames and design tokens in the panels

**Lane:** B (after Task 7)

**Files:**
- Create:
  - `Layer/Chrome/DevicePicker.swift`, `Layer/Chrome/CustomDeviceSheet.swift` and `Layer/Chrome/DesignTokensSection.swift`;
  - `Layer/Model/DesignStore+Devices.swift`.
- Modify:
  - `Layer/Chrome/StylePanel.swift`:
    - `FrameSettings` gets `DevicePicker` and "Save as Device…";
    - `MagicPenTab`'s New Screens picker gets `DevicePicker`;
    - `CanvasTab` gets `DesignTokensSection`.
  - `Layer/Tree/NaturalSize.swift`, `Layer/Tree/LayoutEngine.swift` and `Layer/Tree/TreeRules.swift`: the design's text sizes (call 12).
  - `LayerUITests/LayoutUITests.swift`: one test.
- Test: `LayerTests/CustomDevicesAndTokensTests.swift`

**Interfaces:**
- Consumes:
  - Task 1: `selectedScreenID`, `updateTreeScreen`;
  - Task 2: `LayerNode.resolvedFontSize(tokens:)`;
  - plan 2: `DeviceFrame` (custom fields, `custom(name:size:family:)`, `isCustom`), `CanvasSettings.customDevices`, `device(named:)`, `DesignTokens` and its reading rules, `updateCanvas`.
- Produces:
  ```swift
  extension DesignStore {
      /// One step, "Add Device"; returns its id. With `forScreen`, that screen takes it in the same step.
      @discardableResult func addCustomDevice(_ device: DeviceFrame, forScreen: TreeScreen.ID? = nil) -> String
      func updateCustomDevice(_ device: DeviceFrame)              // its screens are laid out again by the rules
      @discardableResult func deleteCustomDevice(_ id: String) -> Bool   // false while a screen uses it
      func setDevice(of screen: TreeScreen.ID, to deviceID: String?)    // nil = the iPhone
  }
  struct CustomDeviceDraft: Equatable {
      var name: String; var width: CGFloat; var height: CGFloat; var cornerRadius: CGFloat; var family: DeviceFrame.Family
      var safeTop, safeBottom, safeLeading, safeTrailing: CGFloat
      var hasStatusBar, hasIsland, hasHomeIndicator: Bool
      var margin: CGFloat; var maxContentWidth: CGFloat?
      init(from device: DeviceFrame, named name: String)
      var problems: [String] { get }       // a size not finite or outside 1…4000; an empty name
      func device(id: String?) -> DeviceFrame?    // nil when there are problems; a new id when `id` is nil
  }
  struct DevicePicker: View {             // built-ins by family, then "Custom" (the design's), then "Custom Size…"
      static func sections(_ settings: CanvasSettings) -> [(title: String, devices: [DeviceFrame])]
  }
  struct CustomDeviceSheet: View          // the draft's fields; Save, Cancel, and Delete Device for an unused custom one
  struct DesignTokensSection: View        // rhythm as "8, 12, 16, 24, 32"; radii; card padding, radius, fill; text sizes; Reset
  extension NaturalSize { static func fontSize(of node: LayerNode, tokens: DesignTokens) -> CGFloat }
  // LayoutEngine.size(of:proposal:measure:tokens:) and layOut(_:previous:measure:tokens:diagnostics:) gain
  // `tokens: DesignTokens = .standard`; TreeRules passes content.settings.tokens, and lays out every screen with no
  // `previous` when the tokens differ from previous's.
  ```

- [ ] **Step 1: Write the failing tests** in `CustomDevicesAndTokensTests` (`@MainActor`):
  - `aCustomSizeIsAddedAndTheScreenTakesItInOneStep`:
    - A 300×500 draft is added for screen S.
    - S's `deviceID` is the new id, and its root frame is (0, 0, 300, 500).
    - One undo removes the device and gives S its old device back.
  - `aDraftWithABadSizeIsRefused`: widths 0, −5, `.nan`, `.infinity` and 5000, or an empty name, give non-empty `problems` and `device(id:) == nil`.
  - `thePickerListsTheDesignsOwnFrames`: `DevicePicker.sections` ends with `("Custom", [watch])` after the built-in families.
  - `aDeviceInUseIsNotDeleted`: `deleteCustomDevice` returns false while S uses it, and true once S is on the iPhone.
  - `editingADeviceReLaysItsScreens`: on a column screen, the custom margin going from 12 to 24 moves the first child's minX from 12 to 24.
  - `saveAsDeviceStartsFromTheScreensDevice`: `CustomDeviceDraft(from: .iPhone, named: "iPhone (Custom)")` is 393×852, family `.phone`, with the iPhone's insets.
  - `tokensTypedAreReadAsPlan2Reads`:
    - A rhythm typed as "16, 8, 8, -2" reads `[8, 16]`, and "" reads the standard.
    - Card padding −1 reads 16.
    - Reset gives `.standard`.
    - Each edit inside `model.adjusting` is one "Format" step.
  - `theDesignsTitleSizeIsMeasuredAndDrawnAlike`:
    - With the title size 34, a column title's engine height equals `TextMeasure.shared.size(of:fontSize: 34, weight: NaturalSize.fontWeight(of:), width:)` at its width.
    - `NaturalSize.fontSize(of:tokens:)` equals `resolvedFontSize(tokens:)` for every leaf kind.
  - `aTokenChangeLaysOutEveryScreenOnce`: with two column screens, a title-size change raises `LayoutEngine.containersLaidOut` by every container of both, once.

  `LayoutUITests.testACustomSizeBecomesTheScreensDevice`:
  - Select Screen 1, then open Format, then the device picker, then "Custom Size…".
  - Type Width 300 and Height 500, then Save.
  - The selection's value is `'Screen 1 · 300 × 500'`.

- [ ] **Step 2: Run them.** Run `CustomDevicesAndTokensTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the verbs, the draft, the views and the engine's tokens.
  - The sheet is presented from the picker's "Custom Size…" and from "Save as Device…". Its number fields use `NumberField`, with ranges 1…4000.

- [ ] **Step 4: Run them.** Run `CustomDevicesAndTokensTests`. Then run `DeviceFrameTests`, `DesignTokensTests`, `LayoutEngineTests`, `LayoutEngineFreeTests`, `TreeRulesTests` (the 16 ms budget holds) and `FormatPanelTests`, which must pass unchanged. Then run the full unit suite and the UI suite. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Custom device frames in the device pickers, a Custom Size sheet and Save as Device; the design's tokens edited in the canvas settings, its text sizes measured and drawn"`

---

### Task 10: Drawings and ink on the tree

**Lane:** C (after Task 8)

**Files:**
- Modify:
  - `Layer/Canvas/DrawingSync.swift`: drawings are read from `tree.canvas`. `Changes.apply(to:)` writes canvas nodes on `content.tree`, keeping its `inout DesignContent` signature, which is marked for plan 6.
  - `Layer/Canvas/InkCanvas.swift`: its three reads of `model.store.content` pass `model.store.tree`.
  - `Layer/Document/DrawingInk.swift`: only where it reads the old storage.
- Test: `LayerTests/InkOnTheTreeTests.swift`

**Interfaces:**
- Consumes: plan 2's `store.tree`, `LayerNode.content.ink`, `add(_:to:at:)` and `ListWork`; today's `DrawingSync` stroke marks and `CanvasWork.strokesRead`.
- Produces:
  ```swift
  extension DrawingSync {
      /// The canvas's unlocked, visible drawing nodes, back to front.
      static func onCanvas(_ content: TreeContent) -> [LayerNode]
      func strokes(showing content: TreeContent, reading: () -> [PKStroke]) -> [PKStroke]?   // as today, on the tree
      func changes(for strokes: [PKStroke], in content: TreeContent, reach: CGFloat) -> Changes
  }
  extension DrawingSync.Changes {
      // PROJECTION: the DesignContent parameter becomes TreeContent in plan 6
      func apply(to content: inout DesignContent)   // new drawings appended to the canvas (scale 1); others written
  }
  ```

- [ ] **Step 1: Write the failing tests** in `InkOnTheTreeTests` (`@MainActor`):
  - `aStrokeMakesADrawingNodeOnTheCanvas`: a new stroke's changes, applied, give a last canvas node of kind `.drawing`, `scale == 1`, with its frame from the stroke's bounds, and its ink set.
  - `aStrokeNearADrawingJoinsIt`: the drawing's ink grows, and no node is added.
  - `aDrawingWithNoStrokesLeftGoes`.
  - `aTurnedDrawingKeepsItsAngleWhenExtended`: no double turn.
  - `showingDrawingsDoesNotLower`: `strokes(showing:)` after a change elsewhere raises `TreeProjection.lowerings` by 0, and `CanvasWork.strokesRead` by 0.

- [ ] **Step 2: Run them.** Run `InkOnTheTreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement** the three functions on the tree, and point `InkCanvas` at them.

- [ ] **Step 4: Run them.** Run `InkOnTheTreeTests`. Then run `DrawingTests`, `CanvasDragWorkTests` (`aDragOfAnElementReadsNoInkAndPutsOffNoTaskPerFrame`, `aDragOfADrawingStillMovesItsInk`), `RotationTests` ("The twist on the ink canvas") and `UndoNameTests`, which must pass unchanged. Then run the full unit suite and the UI suite. These must pass unchanged:
  - `testPaletteInkIsOrdinaryInkSharesUndoAndIsSaved` and `testDrawingsAreSelectedAndMoved`;
  - `testUndoGoesBackThroughMovingADrawingAndThroughDrawingIt` and `testATurnedDrawingIsDrawnWhereItIs`.

  Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Ink on the tree: drawings read and written as the canvas's nodes, so a change no longer lowers the design for PencilKit"`

---

### Task 11: The asset library's frames and templates on the tree

**Lane:** C (after Task 10; waits for Task 2)

**Files:**
- Modify: `Layer/Chrome/AssetLibrary.swift`. The changes:
  - the Wireframes tab gets a "Custom" section from the design's frames;
  - frame tiles look their device up through the design;
  - template thumbnails draw `ScreenView` of a laid-out template root;
  - `templatePreview(named:)` is deleted.
- Modify (fallout i): `LayerTests/OutlinePromptTests.swift`'s `aTemplatePreviewIsMadeOnce` reads `templateRoot(named:)`, and its counter assertion stays.
- Test: `LayerTests/LibraryOnTheTreeTests.swift`

The spec's "Frames tab" is today's Wireframes tab, where the device frames already are. It isn't renamed, so `testTheLibraryHasTabsAndThingsAreDraggedFromItOntoTheCanvas` keeps its four tab names.

**Interfaces:**
- Consumes: Task 1 (`addAsset` resolving custom frames), Task 2 (`ScreenView`); plan 3's `AssetLibrary.template(named:)`, `TreeRules.laidOut` and `templatePreviewsMade`; plan 2's `CanvasSettings.customDevices`.
- Produces:
  ```swift
  extension AssetLibrary {
      /// The design's own frames as assets: tab .wireframes, section "Custom", id "frame:<device id>".
      static func customFrames(_ devices: [DeviceFrame]) -> [Asset]
      /// A template laid out on the iPhone, once per name (counted by `templatePreviewsMade`), for its thumbnail.
      static func templateRoot(named name: String) -> LayerNode?
  }
  ```

- [ ] **Step 1: Write the failing tests** in `LibraryOnTheTreeTests` (`@MainActor`):
  - `theDesignsFramesAreInTheWireframesTab`: `customFrames([watch])` gives one asset with tab `.wireframes`, section "Custom", the watch's name, and id `"frame:\(watch.id)"`.
  - `searchFindsACustomFrameByName`.
  - `aCustomFramePickedMakesAScreenOfIt`: picking it through the library's pick adds a screen on that device.
  - `aTemplateThumbnailIsLaidOutOnce`: two calls of `templateRoot(named: "Product")` are equal, and `templatePreviewsMade` rose by 1. The root holds a card.
  - `theLibraryDrawsNoElements`: building the Wireframes tab for a design with templates raises `TreeProjection.lowerings` by 0.

- [ ] **Step 2: Run them.** Run `LibraryOnTheTreeTests`. Expected: FAIL.

- [ ] **Step 3: Implement.** The library view reads `model.store.tree.settings.customDevices`. Delete `templatePreview` and its `[DesignElement]` drawing.

- [ ] **Step 4: Run them.** Run `LibraryOnTheTreeTests`. Then run `AssetLibraryTests` and `OutlinePromptTests` (ported), then the full unit suite and the UI suite. `testTheLibraryHasTabsAndThingsAreDraggedFromItOntoTheCanvas` must pass unchanged. Expected: PASS, TEST SUCCEEDED, and no UI failure outside the baseline set.

- [ ] **Step 5: Commit.** `git add -A && git commit -m "Library on the tree: the design's own frames in the Wireframes tab, and template thumbnails drawn from their laid-out roots"`

---

### Task 12: The first milestone, the UI suite, and the plan's finish

**Lane:** A (waits for every other task)

**Files:**
- Create: `LayerTests/CanvasNeverLowersTests.swift`
- Modify: `LayerUITests/LayoutUITests.swift`, which gets two tests.
- Modify (dead code only):
  - `Layer/Model/Groups.swift`: `layerTree(on:)`, `LayerListNode` and `drawings` are deleted, along with every `DesignContent` group helper nothing calls;
  - `Layer/Model/LayerOrder.swift`: `SiblingLists` is deleted;
  - `Layer/App/AppModel.swift`: `groupSelection()` and `canGroupSelection` call Task 6's `(as: .group)`, and `alignSelection` is reached through `lineUpSelection`;
  - `Layer/Canvas/PhoneScreenView.swift`: `ElementView(element:)` is deleted if nothing calls it.
- Modify: `docs/benchmarks/semantic-tree.md` (an "After plan 4" column)

**Interfaces:**
- Consumes: everything above; plan 3's export (`Grid(`, the card's background line) and its Code tab.
- Produces: nothing new.

- [ ] **Step 1: Write the tests.**
  - In `CanvasNeverLowersTests`, inside `HostedWindowSuites`, `.serialized`: `aDragWithEveryPanelOpenLowersNothing`.
    - Show `CanvasScreen` with the Layers and Format panels open, on a board with a card, a row and 40 lines.
    - Over a 60-frame drag of a line, then a 60-frame lift of a row's child, `TreeProjection.lowerings` rises by 0.
    - It must still pass when the lines are drawings.
  - `LayoutUITests.testTheFirstMilestoneACardAndAGridSeenInLayersAndExported` (spec Verification, adapted: the card and grid are made with Group as, since sketching them is plan 5's):
    1. Open a new design, then `box(sketch)` and `convert()` to make Screen 1.
    2. Add four texts with `control("Text")`, dismissing each one's popover. Drag them to `onScreen((120, 200))`, `onScreen((120, 240))`, `onScreen((110, 400))` and `onScreen((290, 400))`.
    3. Tap the first two, so the selection is "2 items". Hold "Group" and tap "Card". The selection's value begins `'Card'`.
    4. Clear the selection, then tap the other two. Hold "Group" and tap "Grid". The selection's value begins `'Grid'`.
    5. Open Layers: `layerRow("Card")` and `layerRow("Grid")` exist.
    6. Open Code: a static text containing `Grid(` exists, and so does one containing `.background(.background.secondary`.
  - `LayoutUITests.testDraggingAThingInAColumnReordersIt`:
    - A text at `onScreen((200, 200))` and a heart symbol at `onScreen((200, 300))` are grouped as a Column.
    - Two quick presses on the text select it (`'200 × 24'`). It is dragged to the symbol's lower half.
    - In Layers, the "Symbol" row's minY is less than the "Text" row's.

- [ ] **Step 2: Run them.** Run `CanvasNeverLowersTests` and `LayoutUITests`.
  - If a lowering is counted, put a breakpoint on `TreeProjection.lower` and find the reader. Move it to the tree, or out of the per-change path, and record it in the ledger.
  - Expected after that: PASS.

- [ ] **Step 3: Delete the dead code** listed in Files, then build.
  - `grep -rn "layerTree(on:\|LayerListNode\|SiblingLists\|ScreenDrawing\|templatePreview(\|PhoneScreenView\|FloatingElementView\|targetElements(entered" Layer LayerTests` finds nothing.

- [ ] **Step 4: Name what stays on the projection.** Record in the ledger, with the plan that moves each part:
  - **Plan 5, the sketch path:**
    - `AppModel.convert` and the suggestion's `place(of:)`;
    - `DesignStore.addElement`, `addFloating`, `changeKind` and `place(_:centeredAt:)` (library drops land through it, appended to a column);
    - `ElementLayout.sketched` and `ScreenTidy`.
  - **Plan 6:**
    - Siri (`Layer/Intents/*`);
    - voice (`Layer/Voice/*`, `AppModel.voiceVocabulary`);
    - `ImagePlaygroundSupport.swift`, and `Layer/Debug/DemoScript.swift` and `VoiceDemo.swift`;
    - AppModel's four marked accessors, `DrawingSync.Changes.apply(to:)`'s parameter, `ElementView(element:)` if kept, `DesignContent` and the store's `screens`, `floating`, `element`, `resolve` and `update(ref)`.

  Then check:
  - `grep -nE "store\.(screens|floating|resolve|element)\b|selectedElement\b|selectedScreen\b" Layer/Canvas Layer/Chrome Layer/Model/{Groups,LayerOrder,SeveralThings,Enclosure,TurnSession}.swift` lists only lines in files the ledger names.
  - `grep -rln "PROJECTION: deleted in plan 6" Layer` lists:
    - `Layer/Model/Projection/`, `DesignContent` and the `keepGroupsSound` shim;
    - `AppModel.swift`, `DrawingSync.swift`, and `PhoneScreenView.swift` only if `ElementView(element:)` stayed.

    `ScreenDrawing`, `DesignScreen.drawing` and `AssetLibrary.templatePreview` are gone.

- [ ] **Step 5: Measure.**
  - Run `StoreChangeBudgetTests`, `NodeViewTests/oneEditRebuildsOnlyTheViewsOnItsPath`, `CanvasDragWorkTests` and `LayoutDragTests/draggingARowChildWritesNothingUntilTheDrop`.
  - Run the canvas workout exactly as plan 2's Task 1 Step 4 did, on the branch, in lane A's simulator, with DerivedData `Layer-semantic-tree-release`.
  - Fill the "After plan 4" column with:
    - the drag frame's counters: writes, targets, and node views per frame, for a line, a group and a row's child;
    - the store-change p95s;
    - the workout's CPU, memory and clock.

    The workout's CPU time must be no worse than main's by more than 5%. If it is, profile with Instruments' Time Profiler, fix it, and measure again. Never record a better number than was measured.
  - Record in the ledger the iPad checks plan 6's checklist must carry:
    - drag-reorder in a row and in a column screen, with a finger;
    - a turned card and its children;
    - Group as Card and Grid from the popover;
    - a custom device made from a screen;
    - a token edit redrawing cards and titles.

- [ ] **Step 6: Verify the plan's end state.**
  - The full unit suite passes.
  - The UI suite fails nothing outside the baseline set.
  - `scripts/check-generated-swiftui.sh` prints `N files typecheck` and exits 0.

- [ ] **Step 7: Commit.** `git add -A && git commit -m "Canvas and panels on the tree: the first milestone end to end, nothing on the canvas lowering the projection, and what is left on it named for plans 5 and 6"`

- [ ] **Step 8: Clean up.**
  - Delete the lane B and lane C worktrees and branches once merged.
  - Delete their simulators: `xcrun simctl delete "Layer iPad Pro 11 (st4-lane-b)"` and `"Layer iPad Pro 11 (st4-lane-c)"`.
  - Delete their DerivedData, and `Layer-semantic-tree-release`.

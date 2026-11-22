# Groups, Layer Order, Layers Panel and Tap-to-Add Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Revisions 2026-11-22

The plan was written against rotation at c0f7429. It has been checked against main 525477c, which holds rotation (da74d64), the overnight audit merges and build 0.2.0 (4). The spec is unchanged. The plan keeps its scope, its task order and what its tests are for. What changed, and why:

1. **Base, commands, names.**
   - The branch is rebased onto main 525477c, so nothing waits for rotation.
   - The simulator "Layer iPad Pro 11 (groups)" is made for this branch by the coordinator. Step 0 checks that it exists and doesn't clone one.
   - Suite names are fixed. `DesignTests`, `FreeformTests`, `SiriIntentsTests` and `RotationTests` are files, not suites. Hosted suites are run as `HostedWindowSuites/<Suite>`.
   - Commits now stage new files: `git commit -am` left them out.
   - Line hints are updated, and a code map is added.
2. **Undo is made of per-edit identities** (audit fixes-generation G4/C1, finish-b I2/M14/C18).
   - Every step is now an undo group of its own. "One undo step" therefore means one `apply { }` body, or several store calls inside `asOneStep { }`. It never means several bare store calls in a row, which would be several steps.
   - One-off commands follow Delete and Duplicate: Group, Ungroup, Arrange, a row move and the VoiceOver moves. Their step is named plain "Undo" (C18 left one-offs unnamed). Made while another finger drags, they join that drag's step (`implicitOwner`).
   - Gestures keep their own edits:
     - a group dragged: the drag's `Edit`, named "Move";
     - a handle resize: "Resize";
     - a turn: `turnEdit`, named "Rotate";
     - Format panel fields: through `AppModel.adjusting`, the panel's own edit (M14), named "Format".
3. **Where the soundness pass runs.**
   - `keepGroupsSound()` runs in three places:
     - inside `DesignStore.change`, in the same `inout` access as the body, so there is one `didSet` and one whole-design compare (C6);
     - on an undo or redo's result in `takeBack`, as the spec asks ("checked after every change … undo"), because an undo interleaved with another edit can otherwise leave a group unsound;
     - when a file is read.
   - It runs at the end of every change body. Anything that builds or moves a group whole must therefore do it inside one `apply` body: Group, Duplicate, rehost, a row move.
   - `DesignContent.elements` has a private setter and `DesignStore.change` is private. Groups.swift therefore writes only through `add`, `update`, `remove`, `move`, `reorder` and `apply`.
4. **Hit testing** (C2, C3, C6, C8, C12). Hit order is draw order, and a tap, a drag and hover all agree.
   - An unentered group is one `ElementTarget`: its box, with its effective lock, at the place of its block. Its members get targets of their own only once it is entered.
   - `hoverTarget` walks each host the same way.
   - The canvas hover outlines what a tap there would pick. Voice looks through groups.
   - A group's target is built again only when its box, angle or lock changes. `ElementTargets` now also reads `enteredGroups`.
   - The several-things areas tap through `targetTapped(_:at:)`.
   - Locked drawings drawn on top (Task 8) are also hit-tested on top, and the board picture draws them on top too.
5. **Rehost and C4.**
   - Every way a drag ends lands what it moved, in design order (`AppModel.rehost(_:)` calls `store.rehost(ref)`).
   - `store.rehost` lands a group whole, in one change, so a group drag that is cut short still lands whole.
   - Snapping leaves out the leaves of the group being dragged.
6. **Rotation.**
   - A group turns through `TurnSession`. Its members are its leaves, and its outline starts at the group's angle.
   - Group items nested inside it turn by the same angle.
   - A leaf locked on its own goes with its group.
   - The session survives a rehost.
   - `selectionShape` uses the session's rigid shape for a single group.
   - Reset stands the group at 0°.
   - Handle resizes scale from the pose the group had when the drag began, so a resize has no drift (rotation's anti-goal).
7. **The Layers panel (M9).**
   - Rows stay `.equatable()` values, given only what they show. That now includes their depth, whether they are dimmed, and whether a group is open.
   - The tree is built in `LayersList`.
   - The screen heading `LayerGroupRow` is renamed `LayerHeadingRow`, so that "group" means groups.
   - A hosted test checks that a grouped member's drag builds no rows.
8. **The file format** (D1, D2).
   - `group` is a `CodingKey`, so it isn't also kept in `unknownKeys`. It is in `DesignElement.reverting`'s list.
   - There is no version bump.
   - The kinds golden isn't re-recorded:
     - `describeEveryKind` iterates `ElementKind.placeable`. A group item with no members is removed by the soundness pass and left out of `screens`, so describing `.group` would fail.
     - `.group`'s catalogue entry gets a test of its own.
   - Two older-build tests replace one; see conflict A.
9. **Tests merged tonight that assume a tap replaces the selection** are rewritten in Task 1, keeping what each tests:
   - `InkOverAnElementTests.aTapOnInkOverAnElementPicksTheDrawing`
   - `SelectionAreaTapTests.inSelectItPicksWhatIsDrawnOnTopThere`
   - the UI tests `testInkOverAnElementIsWhatATapPicksAndADragMoves`, `testATapInsideASelectedDrawingsBoxPicksWhatIsUnderIt` and `testTheRotationFieldTurnsTheSelection`

   The UI tests known to fail on main are now two, not four (SUMMARY, "Final verification").
10. **Effective lock.**
    - `store.isLocked` now means "locked itself, or a group above it is". It decides moving, turning and deleting.
    - Layers rows show and toggle a thing's own flags.
    - The popover and the Format panel show the effective lock; see conflict D.

### Where the spec now conflicts with what merged tonight (for the user to decide)

**A. Older builds now keep the grouping** (documents D2).
- **The spec says** older builds "drop members' pointers when they save, so grouping is lost there".
- **What merged:** from build 0.2.0 (4) on (525477c), unknown keys are written back. Build 4 keeps members' `group` and the unread group item. Only builds up to 0.2.0 (3) drop the pointers.
- **Side effects in build 4:**
  - A member it duplicates carries the pointer, and joins the group when opened here.
  - A member it moves to another screen leaves the group (soundness rule 1).
- **Recommended:**
  - Accept this, since nothing is lost.
  - Change the spec's "Older builds" line and its edge-case row to "saving there keeps the grouping, which comes back here".
  - Test both (Task 3): a build 4 round trip, where the pointers are kept, and a build 3 round trip, where they are stripped.

**B. A near miss versus audit C12.**
- **The spec says** a tap that hits nothing within 8 pt of a selected thing's outline is ignored.
- **What merged:** C12 made a tap inside a selected drawing's box reach what is under it.
- **The conflict:** a selected drawing's whole box would then swallow taps.
- **Recommended:** leave drawings out of the near-miss band. Their 14 pt ink tolerance (ruling 47) already absorbs near misses. Task 1 is written this way.

**C. Hover on a grouped thing** (C3: a tap, a drag and hover agree).
- **The spec** doesn't say what hover outlines.
- **Recommended:** the canvas hover outlines what a tap would pick: the outermost unentered group, or the member itself once its group is entered. Voice targets still see elements. Task 5 is written this way.

**D. Locked only through a group.**
- **The spec says** a member is effectively locked when a group above it is.
- **What merged:** the popover shows only "Unlock" for a locked selection.
- **The conflict:** unlocking a member that is locked only by its group would change nothing.
- **Recommended:** the popover and the panel show the effective lock, and Unlock also unlocks the locked groups above what is selected, in one step. Layers rows still toggle a thing's own flag. Task 3 is written this way.

**E. Drawings and layer order.**
- **The spec says** layer order covers everything but drawings.
- **What merged:** Siri's `ArrangeElementIntent` can still reorder a drawing.
- **Recommended:** arranging leaves drawings where they are, and `canArrange` is false for a drawing on its own. Task 2 is written this way.

Rulings A–E were accepted (`.superpowers/sdd/2026-11-18-groups-layers/progress.md`). The spec now carries A: its "Older builds" line and its edge-case row say build 4 and later keep the grouping.

### Pre-flight amendments 2026-11-22

The pre-flight scan (`.superpowers/sdd/2026-11-18-groups-layers/preflight.md`) found 12 conflicts, 4 test defects and 10 lower notes. Every recommended ruling is applied in the task text. Each finding, and where it now lives:

- **F1** The build-4 test's members carry an unknown key, `"futureGroupID"`. → Task 3, `aDesignSavedByABuildThatKnowsNoGroupsKeepsThem`.
- **F2** The test moves A `before: B`, giving B, A, D. → Task 9, `aLayerMovesIntoAGroupAndOut`.
- **F3** `liftingTheFingerThatRestedIsNotATapOfItsOwn` is rewritten and now ends with `.element(body)`. → Task 1, Files and Step 1.
- **F4** The handles, badge, Draw area, `moveElement`, `turnableElement` and `canTurnSelection` read the effective lock. → Task 3, Files, Interfaces "Lock" and `aMemberOfALockedGroupIsntResizedOrTurnedOnItsOwn`; Task 6, `AppModel`.
- **F5** Adding a group folds its selected contents in. → Task 8, Interfaces and `aRowTapAddsOrTakesOutExactlyThatThing`.
- **F6** Siri and voice see a selected group's leaves. → Task 7, Files, Interfaces "Siri and voice", `aSelectedGroupIsNoSingleElementForSiri` and `aSqueezeOnAMemberOfASelectedGroupKeepsTheGroup`.
- **F7** Drawings belong to no sibling set and keep their slots. → Task 2, rule 1, the raw-order helper, `thingsOnTwoHostsEachMoveAmongTheirOwn` and `nothingToDoMeansTheCommandIsOff`; Task 4, sibling sets; Task 9, `moveLayer`.
- **F8** `setChildren` re-adds only the group items that are missing. → Task 3, Interfaces "The views" and `updatingAScreenKeepsEachGroupItemOnce`.
- **F9** No word names `.group`, and `ScreenBlueprint` is left alone. → Task 3, `Catalogue.group` and `aGroupIsAKindNothingIsSketchedAsOrWrittenAs`.
- **F10** Both UI tests tap empty canvas before their taps. → Task 10, Step 1.
- **F11** `xcodegen generate` runs in Step 1. → Tasks 2 and 3, Step 1; Global Constraints.
- **F12** There is one tap-rule helper, `selection(afterTapOn:from:)`. → Task 1, Interfaces; Task 5, `pick`; Task 8, `pickInList`.
- **D1** The panel-finger test puts the note under the panel finger. → Task 1, Step 1.
- **D2** The gathering test uses A–E, so G has to move. → Task 3, `membersAreGatheredWithTheGroupInFrontOfThem`.
- **D3** Two lock-and-move tests move to Task 6, each with a half that moves; the panel tests drive `setGroupBox`. → Task 6, Step 1; Task 7, Interfaces and Step 1.
- **D4** There is one `OrderBoard`, one tap-rule helper and one raw-order helper. → Task 2, Files and Interfaces; Tasks 1, 3–9.
- **L1** A plain tap on a member of a selected group takes the group out. → Task 5, `pick`.
- **L2** The resting-finger branch runs the tap rule. → Task 1, Interfaces and `aTapWithAFingerRestingFollowsTheTapRule`.
- **L3** The near miss is a band along the outline. → Task 1, Interfaces and `aScreensEmptyAreaClearsASelectionAndOtherwiseSelectsTheScreen`.
- **L4** 350 ms stands, with a comment. → Global Constraints "Taps"; Task 5, the double-tap.
- **L5** Boxes are enclosed in canvas points and stored in the item's scale. → Task 3, rule 5 and `aFloatingGroupsBoxHoldsMembersOfMixedScales`; Task 4, `group`.
- **L6** The spec's older-builds line and edge-case row are updated, in this amendment's commit rather than Task 3's.
- **L7** `canGroupSelection` is `store.canGroup(selection)`. → Task 4, AppModel.
- **L8** An H edit becomes a proportional frame, and X/Y become canvas points. → Task 7, `setGroupBox`, `aGroupsHeightFieldResizesInProportion` and `aGroupsXFieldMovesItInTheScreensPoints`.
- **L9** Unlocked drawings still have no target. → Task 5, Targets.
- **L10** Locked drawings come last in `targets(on: .canvas)`. → Task 8, Files and `aLockedDrawingIsTouchedAboveTheNoteItIsDrawnAbove`.
- Also from the scan's T3 row: `theKindsOfferedToShortcutsAreTheKindsThereAre` uses `placeable` in both its parts. → Task 3, Files.

Carried to dispatch: none. Every L note is applied above.

---

**Goal:** A finger tap adds to or takes from the selection; several things become a group that is selected, moved, turned, resized, locked, hidden, duplicated, arranged and deleted as one; all four layer-order commands work on one thing, a group or several; and the Layers panel shows groups as a tree whose rows can be dragged to reorder and to move into and out of groups.

**Architecture:**
- **The group item.** A group is an element of the new kind `.group` in the one list `DesignContent.elements`. Members point at it with a new optional `group` field and keep their screen.
- **The soundness pass.** One function, `DesignContent.keepGroupsSound()`, keeps every group sound:
  - it keeps each group's box current;
  - it keeps each group's members together;
  - it dissolves a group of one.

  It runs at the end of every store change, after undo and redo, and when a file is read.
- **The views.** Group items are left out of the views that draw, export, describe and hit-test elements (`screens[].elements`, `floating`). Those views give each member its effective lock and hide, so those paths keep working unchanged.
- **The tree.** The Layers panel and the canvas targets read the raw children (`store.children(on:)`), group items included.
- **Selection.** Selection stays `CanvasSelection`. A selected group is `.element(ref)` of its item. Operations expand it to its leaves where they act on elements.

**Tech Stack:** Swift 6, SwiftUI (iPadOS 27 `reorderable(collectionID:)`, `reorderContainer(for:in:)`, `dragContainer`, `dropDestination`), Swift Testing, XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-18-groups-layers-design.md` (approved 2026-11-18). Read it first. Also read:
- `docs/superpowers/specs/2026-11-18-rotation-design.md` for `TurnSession` and the turn API;
- the audit report `reports/Layer audit 2026-11-22/` in the main checkout: `SUMMARY.md`, `fixes-generation.md` (G4), `fixes-canvas-chrome.md` (C2, C3, M9) and `fixes-finish-b.md` (C4, C6, M14, C18).

**Before Task 1:** `feature/groups` is rebased onto main 525477c. Only the design and plan commits are on it.

## Global Constraints

- **Platform and tools.** iPadOS 27, Xcode 27.2. Unit tests use Swift Testing; UI tests use XCUITest.
- **Adding files.** Run `xcodegen generate` after adding or removing a file, and commit the regenerated `Layer.xcodeproj` with the change.
- **Drawings stay on top.**
  - Unlocked ink keeps drawing above every element.
  - Drawings never join groups.
  - Drawings keep their places when things are arranged.
  - The Layers panel lists drawings in a section of their own, and those rows don't drag.
- **Where a group can be.** A group stays on one screen or on the open canvas, and never holds a screen. Group needs two or more things sharing one host and one parent group. Locked things and drawings are left out of a new group.
- **Shortcuts:**

  | Command | Shortcut |
  |---|---|
  | Group | ⌥⌘G |
  | Ungroup | ⌥⇧⌘G |
  | Bring to Front | ⇧⌘] |
  | Bring Forward | ⌘] |
  | Send Backward | ⌘[ |
  | Send to Back | ⇧⌘[ |
- **Undo.**
  - Each group, ungroup, arrange, row move, and change made from a button or toggle is one undo step: one `apply { }` body, or several store calls inside `asOneStep { }`.
  - Gestures and panel fields act for their own `Edit`; see Revisions 2. Selecting isn't undone.
  - `DesignStore.change` is private. Extensions outside `DesignStore.swift` change the design through `apply` (one change), `update(_ refs:_:)` or `asOneStep`.
- **Building a group whole.** `keepGroupsSound()` runs at the end of every change body. Code that creates, copies, regroups or rehosts a group must do all of it inside one `apply` body. Split over several calls, the pass runs in between and dissolves the half-built group: a group item added alone has no members, and a member moved alone to another host leaves its group.
- **No needless work** (audit C6, M9).
  - The soundness pass writes only what differs, through `DesignContent.update`, which already skips an unchanged element. A drag frame of an ungrouped element costs one scan of the list and no copy.
  - Canvas targets and Layers rows are `.equatable()` values built from what they show.
- **The file format.**
  - Order stays array position; there are no fractional keys.
  - There is no file version bump. `group` is decoded with `decodeIfPresent`.
  - An older build keeps a group item as an unread element. Build 0.2.0 (4) and later also keep members' `group`; see conflict A.
- **What doesn't know about groups.** Generated code, voice and Siri see members exactly as today: they export them, describe them and offer them. Voice's targets never return a group item.
- **Taps.** A near miss is a tap within 8 pt on the glass of a selected thing's outline, drawings excepted (conflict B). A double-tap is a second tap on the same thing within 350 ms. iPadOS gives no public double-tap interval, so a comment at the constant says 350 ms stands in for "the system double-tap interval" the spec names (L4). The first tap always acts at once.
- **Nothing is repositioned to dodge the pencil palette.**

## Code map (main 525477c)

The line numbers are hints; search by name.

- `Layer/Model/Design.swift`:
  - `ElementKind` :5
  - `DesignElement` :60, with `CodingKeys` :119, `reverting` :134 and `init(from:)` :157
  - `UnreadElement` :392
  - `readList` :401
- `Layer/Document/DesignFile.swift`, `DesignContent`:
  - `screens` :66 and `floating` :87, both get and set
  - `children(of:)` :104
  - `update` :122
  - `move` :142
  - `reorder` :152
  - `setChildren` :163
  - `reverting` :230
  - `updateScreen` :308
  - `takeBack` (Siri) :325
  - `init(from:)` :405 and `encode` :420
- `Layer/Model/DesignStore.swift`:
  - `ElementRef` :14 and `content` :25
  - `element(_:)` :103 and `resolve(_:)` :109
  - `delete(_ refs:)` :207, `delete(_ ref:)` :248, `duplicate(_ ref:)` :257
  - `Arrangement` :296, `siblings(of:)` :320, `arrange` :328, `canArrange` :344
  - `rehost(_ ref:)` :456 and `move(_:toScreen:origin:)` :478
  - `Editor` :509 and `Edit` :529, `beginEdit` :571, `asOneStep` :814, `asOwnStep` :827
  - `change(_:)` :852, `register` :1065, `takeBack(_:)` :1104
- `Layer/Model/SeveralThings.swift`:
  - `canvasShape` :12, `isLocked` :37, `things(in:)` :47
  - `canvasFrames(besides:)` :63 and `position` :82
  - `private arrange(_:_ rule:)` :119
  - `setLocked` :145, `duplicate` :164, `delete` :190, `rehost(_ selection:)` :202
- `Layer/Model/Enclosure.swift`: `things(enclosedBy:)` ~:103.
- `Layer/Model/TurnSession.swift`: `form`, `placed`, `matches`, `translate`, `rehosted(as:in:)`.
- `Layer/App/AppModel.swift`:
  - taps:
    - `canvasTapped` :1077
    - `selectionAreaTapped` :1096
    - `targetTapped` :1108
    - `pick` :1131
    - `select(enclosedBy:)` :1162
  - rehost and hit testing:
    - `rehostSelection` :1212
    - `rehost(_ things:)` :1228
    - `hoverTarget` :1274
  - locking and arranging:
    - `isSelectionLocked` :1302
    - `setSelectionLocked` :1306
    - `arrangeSelection` :1322
    - `toggleHidden` :1352
  - turning:
    - `canTurnSelection` :1384
    - `turnableElement` :1417
    - `severalTurn` :1426
    - `beginTurn` :1436
    - `rotateSelection` :1560
    - `resetSelectionTurn` :1570
    - `turn(_:to:)` :1592
    - `selectionShape` :1617
  - the rest:
    - `deleteSelection` :1660
    - `dropSelectionOfMissingThings` :1666
    - `adjusting` :1764
- `Layer/Canvas/SelectionLayer.swift`:
  - `SelectionLayer`:
    - the Draw-mode selection area :45
    - the several-things areas :59
    - the handles :162
  - `CanvasDrags` :257:
    - `moveElement` :502 and `dropElement` :527
    - `adjustOnTarget` :542, `moveOnTarget` :556 and `dropOnTarget` :572
    - `moveSelection` :592, `moveGroup` :602 and `dropGroup` :645

    Here `moveGroup`, `dropGroup` and `groupOrigins` mean several things, not a group item.
  - `ElementTargets` :744 and `ElementTarget` :793
- `Layer/Chrome/LayersPanel.swift`:
  - `LayersList` :71
  - `pickLayer` :120
  - `LayerGroupRow` (the screen and canvas heading) :148
  - `LayerRow` :194
  - `LayersPanelWork` :438
- `Layer/Chrome/StylePanel.swift`:
  - `StylePanel.body` :15
  - `ElementSettings` :69, with its action row at :85
  - `SeveralSettings` :254
- `Layer/Chrome/SelectionActions.swift`:
  - the bar :49, whose single-element part with forward and backward runs to ~:102
  - `severalActions` :135
- Other files:
  - `Layer/Canvas/CanvasScreen.swift`: the hover at :67–79, floating things drawn at :27.
  - `Layer/Chrome/ShareMenu.swift`: the board picture at :240.
  - `Layer/Intents/ElementIntents.swift`: `store.arrange(ref, …)` :445.
- Test helpers:
  - the private `Board` in `LayerTests/MultiSelectionTests.swift`, which has `title`, `body`, `button`, `note`, `screen` and an `UndoManager` with `groupsByEvent = false`;
  - `HitBoard` in `CanvasHitTestTests.swift`.

**Commands:**

```bash
SIM=$(xcrun simctl list devices | grep -F "Layer iPad Pro 11 (groups)" | grep -oE '[0-9A-F-]{36}')
# Unit tests: one suite (a Swift Testing struct name), or a hosted one as HostedWindowSuites/<Suite>
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,id=$SIM" -only-testing:LayerTests/<Suite> 2>&1 | tail -30
# All unit tests
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI -destination "platform=iOS Simulator,id=$SIM" 2>&1 | tail -30
# UI tests: from a clean install, without the CI plan (it holds unit tests only)
xcrun simctl uninstall "$SIM" kahshin.Layer
xcodebuild test -project Layer.xcodeproj -scheme Layer -destination "platform=iOS Simulator,id=$SIM" \
  -only-testing:LayerUITests/SketchFlowUITests/<testName> 2>&1 | tail -30
```

- **Every new test fails before the code it guards.** Show the failure. Use geometry and orderings that can't pass by accident. A new test file joins the project only at `xcodegen generate`, so run it in Step 1, right after creating the file; otherwise `-only-testing` runs no tests and succeeds (F11).
- **Known flakes** in full runs (SUMMARY, "Final verification"):
  - `VoiceCallTests`;
  - four cold-simulator `eventually` timeouts: `aQuickSqueezeTogglesAndTheNextSends`, `aSliderMovedAndLetGoDuringACommandLeavesTheStepToTheCommand`, `aDesignStillComingUpIsPutAwayOnceItIsUp` and `aGenerationWhoseScreenIsTakenAwayStillFinishes`.

  Rerun them alone before calling a failure new.

## Review Focus

1. **Undo after Group and after Ungroup** puts back the exact order and membership in one step. That includes a group made from things that weren't next to each other. → Task 4, `undoingAGroupPutsTheOrderBack`, `undoingAnUngroupPutsTheGroupBack`.
2. **Taps in nested groups.** With a member of inner group I (inside G) selected:
   - a tap on another member of I adds it;
   - a tap on a direct member of G adds that member;
   - a tap on something outside G adds that thing's outermost group.

   → Task 5, `tapsInsideAnEnteredGroupPickTheNextLevelOnly`.
3. **Deleting down to one member** dissolves the group, and one undo brings the group back whole. → Task 3, `aGroupLeftWithOneMemberDissolvesAndUndoBringsItBack`.
4. **A member whose group is missing** opens as ungrouped, instead of vanishing or crashing. Its file may have been edited elsewhere, or by an older build. → Task 3, `aMemberOfAMissingGroupIsUngrouped`.
5. **A panel drag onto another screen's list** changes nothing. → Task 9, `aLayerCannotBeMovedToAnotherHostsList`.
6. **Group boxes and targets stay current without whole-board work** (C6, M9):
   - Dragging a group builds only the group's own target.
   - A grouped member's drag builds no Layers rows.
   - Entering a group swaps its one target for its members' targets.

   → Task 5 `aGroupIsOneTargetUntilItIsEntered`, Task 6 `aGroupDragBuildsOnlyItsOwnTarget`, Task 8 `aDragOfAGroupedThingBuildsNoRows`.

---

### Task 1: Tap-to-add

**Files:**
- Modify: `Layer/App/AppModel.swift`:
  - `pick(_:)` ~:1131;
  - `canvasTapped(at:)` ~:1077 and `selectionAreaTapped(at:)` ~:1096, which get one shared rule for a tapped point.
- Modify: `Layer/Canvas/SelectionLayer.swift`: a selection haptic beside the existing `.sensoryFeedback(.alignment, …)` ~:119.
- Test, `LayerTests/MultiSelectionTests.swift`:
  - a new suite `TapToAddTests`, using the file's private `Board`;
  - rewrite `aTapWithNoFingerRestingSelectsOnlyWhatIsTapped`, `aFingerRestingOnAPanelIsNotRestingOnTheCanvas` and `liftingTheFingerThatRestedIsNotATapOfItsOwn`, which are in `SeveralThingsOnTheCanvasTests`. The third ends with a tap on the title while title and body are selected, which tap-to-add answers differently (F3).
- Test, `LayerTests/CanvasHitTestTests.swift`: rewrite these, which pinned replace-on-tap:
  - `InkOverAnElementTests.aTapOnInkOverAnElementPicksTheDrawing`;
  - `SelectionAreaTapTests.inSelectItPicksWhatIsDrawnOnTopThere`.
- Test, `LayerUITests/SketchFlowUITests.swift`: update three tests (Step 5).
- Unchanged: `AppModelTests.tappingAScreenSelectsItAndTappingEmptyCanvasLetsGo` in `DesignTests.swift` taps with nothing selected and should still pass.

**Interfaces:**
- Produces:
  - `pick(_ thing: CanvasSelection?)` keeps its signature. With no finger resting:
    - `nil` (empty canvas) clears.
    - A thing goes through the tap rule below.
  - **The tap rule is one private helper** (F12, D4): `private func selection(afterTapOn thing: CanvasSelection, from current: CanvasSelection?) -> CanvasSelection?`. Task 5 adds to it and Task 8's `pickInList` calls it; nothing else re-implements it.
    - With nothing in `current`, it gives the thing.
    - A thing already in `current` is taken out (`removing`).
    - A thing inside a selected screen replaces that screen.
    - Otherwise the thing is added: `CanvasSelection(things + [thing])`, which folds a selected element into an added screen, as today.
  - **The resting-finger branch** keeps working out `held` and seeding from it: it starts again from `held` when that isn't selected, and a tap on the held thing itself still does nothing. Then it runs the plain tap's rule from the seeded selection instead of today's symmetric difference (L2, spec "it is now the same as tapping"):
    - `nil` clears;
    - a thing goes through the helper, with `from:` set to the seeded selection.

    The lifting-finger guard stays as it is.
  - One rule for a tapped point that isn't on an element target, in a private helper both call: `canvasTapped(at:)`, and `selectionAreaTapped(at:)` in Select.
    - Ink, or an element under the point (the existing condition in `canvasTapped`; any element in `selectionAreaTapped`): `pick` it.
    - A screen's name strip: `pick(.screen)`, which adds it. The strip counts only while names are shown (`showsFrameNames`), as `hoverTarget` does since C14.
    - A screen's empty area: with a selection, clear it; with none, select the screen.
    - Empty canvas: clear.

    `hoverTarget` returns `.screen` for both the strip and the screen itself. Tell them apart by `labelFrame` versus `canvasFrame`.
  - **A near miss.** Before clearing, in either of the last two cases, check for a near miss. If the point is within 8 view points of a selected thing's outline, nothing happens.
    - The outline is the edge of its view shape, `viewport.viewShape(for: store.canvasShape(of:))`. Measure the point's distance to that edge, on either side: the near miss is a band 8 pt wide along the outline, as the spec words it. Don't test containment in the shape grown by 8, which would swallow every tap inside a selected screen's empty area (L3).
    - Selected drawings don't count (conflict B). A tap inside a selected drawing's box still reaches what lies under it (C12).
  - `private(set) var tapSelectionChanges = 0` is bumped whenever a tap changes the selection. `SelectionLayer` plays `.sensoryFeedback(.selection, trigger: model.tapSelectionChanges)`.

- [ ] **Step 0:** Check the branch's simulator exists: `xcrun simctl list devices | grep -F "Layer iPad Pro 11 (groups)"`. It is made by the coordinator. Don't create or clone one; if it is missing, stop and say so. Then run all unit tests once and record the baseline: 1,009 tests in 118 suites at 525477c.
- [ ] **Step 1: Write the failing tests** in `TapToAddTests`, using `Board`:
  - `tapsAddOneAfterAnother`: `pick(title)`, `pick(body)` and `pick(note)` give `.several([title, body, note])`.
  - `tappingASelectedThingTakesItOut`: then `pick(body)` gives `.several([title, note])`, and `pick(title)` gives `.element(note)`.
  - `onlyEmptyCanvasClears`: `pick(nil)` gives nil.
  - `aScreensEmptyAreaClearsASelectionAndOtherwiseSelectsTheScreen`: with title and body selected, `canvasTapped` gives nil. It taps a point on the screen away from every element and more than 8 pt from both, and more than 8 pt inside the screen's edge. Tapped again, it gives `.screen(screen)`. Tapped a third time, with the screen selected, it gives nil: the point is inside the selected screen but outside the 8 pt band along its outline. A near miss measured by containment in the grown outline would keep the screen, so this half fails unless the band is measured (L3).
  - `aNearMissKeepsTheSelection`: with title and body selected, `canvasTapped` 4 view points outside the title's outline, on the screen, leaves the selection unchanged.
  - `aTapWithAFingerRestingFollowsTheTapRule` (L2): a finger rests on empty canvas, `restingFingers = { [CGPoint(x: 1100, y: 700)] }`, clear of the screen and the note.
    - With `.screen(screen)` selected, `pick(.element(button))` gives `.element(button)`. Today's symmetric difference gives screen + button, which folds back to `.screen(screen)`.
    - With title and body selected, `pick(nil)` gives nil. Today's resting branch returns early and keeps both.
  - `aThingOnASelectedScreenReplacesIt`: with `.screen(screen)` selected, `pick(.element(button))` gives `.element(button)`.
  - `addingAScreenFoldsItsSelectedElementsIn`: with title and note selected, `pick(.screen(screen))` gives `.several([.screen(screen), note])`.
  - `aTapOnAScreensNameAddsIt`: with the note selected, `canvasTapped` on the middle of the screen's `labelFrame` gives `.several([.screen(screen), note])`.
  - Rewrite the three old tests in `SeveralThingsOnTheCanvasTests`:
    - `aTapWithNoFingerRestingAddsWhatIsTapped`: with title and body selected, `pick(note)` gives all three.
    - `aFingerRestingOnAPanelIsNotRestingOnTheCanvas` (D1): put a thing under the panel finger, so that counting it would change the answer.
      - The panel's frame goes over the note: `chromeFrames["format"] = CGRect(x: 480, y: 80, width: 200, height: 200)`.
      - The finger rests on the note's middle, `board.canvasFrame(board.note)`'s mid point, inside that frame. The board's view shows the canvas unscrolled, so canvas and view points agree.
      - With the title selected, `pick(.element(body))` gives exactly `CanvasSelection([.element(title), .element(body)])`.
      - Counted as resting, the finger would hold the note, which isn't selected, and give note + body. So the test fails if the panel filter breaks.
    - `liftingTheFingerThatRestedIsNotATapOfItsOwn` (F3): unchanged up to the last tap. The last tap on the title, after the lift, is a real tap on a selected thing and takes it out, so its expectation becomes `.element(board.body)`.
  - Rewrite `aTapOnInkOverAnElementPicksTheDrawing`. The first target tap picks the drawing. The second, off the ink, gives `CanvasSelection([drawing, button])`. The button's own target reached the button, and the tap added it.
  - Rewrite `inSelectItPicksWhatIsDrawnOnTopThere`, starting with the note selected:
    1. A tap at the button gives note and button.
    2. A tap on the screen's empty area clears the selection.
    3. Tapped there again, it gives `.screen`.
    4. A tap on empty canvas gives nil.
- [ ] **Step 2:** Run `-only-testing:LayerTests/TapToAddTests -only-testing:LayerTests/SeveralThingsOnTheCanvasTests -only-testing:LayerTests/InkOverAnElementTests -only-testing:LayerTests/SelectionAreaTapTests`. Expected: the new and rewritten tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run those suites, then `HiddenHitTestTests` and `AppModelTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: UI tests that assumed a tap replaces the selection.** Update each so it checks the same thing, and keep its intent:
  - `testInkOverAnElementIsWhatATapPicksAndADragMoves`: tap empty canvas (150, 650) before "a tap on the button away from the ink". That keeps the check that the tap picks the button.
  - `testATapInsideASelectedDrawingsBoxPicksWhatIsUnderIt`: the second expectation becomes `value BEGINSWITH '2 items'`. The tap reached the button inside the box (C12), and it was added.
  - `testTheRotationFieldTurnsTheSelection`:
    1. The first tap where the button's end was clears the selection, since it hit no button.
    2. A second tap there selects 'Screen 1'. That proves the spot is the screen's.
    3. The tap on the centre then selects the button, since a thing on a selected screen replaces it.

  Run these three from a clean install. Then run these, which also tap one thing after another, and fix any that assumed replace-on-tap in the same way:
  - `testTheCanvasPansZoomsLocksAndFramesCanBeMoved`
  - `testWithTheLassoInHandAFingerStillTapsAndPans`
  - `testWithAPencilAroundAFingerSelectsAndPansWhileThePaletteIsUp`
  - `testSeveralThingsAreBoxedLinedUpMovedAndDeletedTogether`
  - `testThePaletteComesBackWhenTypingEndsInDraw`
- [ ] **Step 6:** In the simulator:
  1. Tap three elements one after another. All three are outlined, and the popover shows several.
  2. Tap one again. It goes.
  3. Tap a screen's empty area. Everything goes.
  4. Tap it again. The screen is selected.
- [ ] **Step 7: Commit:** `git add -A Layer LayerTests LayerUITests && git commit -m "Groups: a tap adds to the selection or takes out; only empty space clears it"`

---

### Task 2: All four layer-order commands, for one thing or several

**Files:**
- Create: `Layer/Model/LayerOrder.swift`, an extension of `DesignContent` and `DesignStore`. It holds the one raw-order helper, which Task 9's `moveLayer` uses too (D4).
- Modify: `Layer/Model/DesignStore.swift`:
  - `siblings(of:)` ~:320 reads the raw children;
  - `arrange(_ ref:_:)` ~:328 and `canArrange(_ ref:_:)` ~:344 call the new selection forms.
- Modify: `Layer/Model/SeveralThings.swift`: rename the private `arrange(_:_ rule:)` ~:119 to `lineUp(_:_:)`, and update its two callers, `align` and `distribute`. Otherwise the new `arrange(_ selection:_:)` would be an overload of it.
- Modify: `Layer/App/AppModel.swift`: `arrangeSelection` ~:1322, and a new `canArrangeSelection`.
- Modify: `Layer/Chrome/SelectionActions.swift`: the single-element bar's forward and backward `ForEach` ~:88 becomes one Arrange menu, and `severalActions` gets it too.
- Modify: `Layer/Chrome/StylePanel.swift`: `ElementSettings`' action row ~:85, and `SeveralSettings`' first section ~:270.
- Test: `LayerTests/LayerOrderTests.swift`, new. It holds `OrderBoard`, the one test board for this plan (D4). `OrderBoard` is internal, not private, so every suite in `LayerOrderTests.swift` and `GroupTests.swift` builds on it instead of a copy. It is built like `MultiSelectionTests.swift`'s `Board`, and a test adds to it what else it needs, such as a second screen:
  - an `AppModel` whose view shows the canvas unscrolled and unzoomed, so view and canvas points agree;
  - a screen at scale 0.5 holding five elements named "A" to "E", back to front, that don't overlap;
  - on the open canvas, two sticky notes ("note 1", then "note 2") and then a drawing, added in that order, so the drawing is frontmost in the canvas's raw list;
  - an `UndoManager` with `groupsByEvent = false`, set after the board is built.

**Interfaces:**
- Produces:
  - `DesignStore.arrange(_ selection: CanvasSelection, _ arrangement: Arrangement)` and `canArrange(_ selection: CanvasSelection, _ arrangement: Arrangement) -> Bool`.
  - The existing `arrange(_ ref:_:)` and `canArrange(_ ref:_:)` become calls of these, so Siri's `ArrangeElementIntent` (`ElementIntents.swift:445`) keeps working.
  - **The rules:**
    1. Things are split by sibling set: the same parent; from Task 4, also the same group. Drawings belong to no sibling set. When a set's slots are refilled, a drawing's slot stays fixed, so Forward or Front on a note never steps past a floating drawing or moves it (F7).
    2. Within a set, the moved things move as one block. They keep their own back-to-front order and close their gaps.
    3. Front puts the block at the front; back puts it at the back.
    4. Forward puts it just in front of the first sibling that was in front of its frontmost member. Backward puts it just behind the first sibling behind its backmost member.
    5. A screen in the selection is ignored, and so is a drawing (conflict E).
    6. It is one undo step: every host's `reorder` is made in one `apply { }` body.
    7. `canArrange` is false when nothing would change.
  - **Where the order comes from.** Read the sibling order from `content.children(of: parent)`, the raw list. From Task 3 on it also holds group items. `store.screen(id)?.elements` leaves them out, and `DesignContent.reorder` changes nothing unless it is given every sibling.
  - **The raw-order helper** (D4, F7): `func rawOrder(on parent: DesignScreen.ID?, withDrawingsKept order: [DesignElement.ID]) -> [DesignElement.ID]`, in `LayerOrder.swift`.
    - It is given the new back-to-front order of the parent's things that aren't drawings.
    - It gives the parent's whole raw order, with each drawing in the slot it holds now and the other slots filled by `order`.
    - `arrange` hands its result to `DesignContent.reorder(_:to:)`, and so does Task 9's `moveLayer`. No other code builds a raw order.
  - `AppModel.arrangeSelection(_:)` works for any selection, and there is `func canArrangeSelection(_ arrangement: DesignStore.Arrangement) -> Bool`.
  - **Popover:**
    - One `Menu` button labelled "Arrange", with the symbol `square.3.layers.3d`, holds the four commands with their names and symbols from `Arrangement`.
    - It is shown for a single element that isn't a drawing, and for several things.
    - Shortcuts ⇧⌘], ⌘], ⌘[ and ⇧⌘[ go on the menu items. If menu items can't carry them, they go on hidden buttons beside the menu, as the existing `.keyboardShortcut` ToolButtons do.
  - **Format panel:** all four `IconButton`s, in `ElementSettings`' action row and in `SeveralSettings`' first section.

- [ ] **Step 1: Write the failing tests** in `LayerOrderTests`, on `OrderBoard`. First create `Layer/Model/LayerOrder.swift`, empty but for its imports, and `LayerTests/LayerOrderTests.swift`, then run `xcodegen generate`, so that Step 2 compiles the tests (F11).
  - `frontAndBackMoveOneThingToTheEnds`.
  - `scatteredThingsMoveAsOneBlockKeepingTheirOrder`: Send to Back on B and D gives B, D, A, C, E. Bring to Front on A and C gives B, D, E, A, C.
  - `forwardStepsPastTheNextSiblingInFront`: Bring Forward on B and C gives A, D, B, C, E.
  - `thingsOnTwoHostsEachMoveAmongTheirOwn`: bring note 1 and A to the front.
    - A is frontmost among the screen's elements.
    - The canvas's raw order is note 2, note 1, drawing: note 1 is frontmost among the notes, and the drawing keeps its slot (F7). With the drawing among the notes' siblings, note 1 would land in front of it, giving note 2, drawing, note 1.
  - `arrangingIsOneUndoStep`: things on two hosts are arranged, and one `undo()` puts both orders back.
  - `nothingToDoMeansTheCommandIsOff`: `canArrange(.front)` is false:
    - for E, the frontmost thing on the screen;
    - for note 2, the frontmost note, although the drawing is in front of it in the raw list (F7);
    - for the drawing.
- [ ] **Step 2:** Run `-only-testing:LayerTests/LayerOrderTests`. Expected: it fails to compile.
- [ ] **Step 3:** Implement.
  - **The model change:** work out the sibling set's new back-to-front order. Refill that set's slots among the parent's things that aren't drawings, then hand the result to `rawOrder(on:withDrawingsKept:)` and that to `DesignContent.reorder(_:to:)`.
- [ ] **Step 4:** Run `LayerOrderTests`, `FlatStoreTests` (`arrangingReordersOnlyAmongWhatSharesItsScreen`), `FreeformBehaviourTests` (`elementsCanBeArrangedUpAndDown`), `DesignActionTests` and `LiningUpTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git add -A Layer LayerTests Layer.xcodeproj && git commit -m "Groups: front, forward, backward and back for one thing or several"`

---

### Task 3: The group item, kept sound

**Files:**
- Create: `Layer/Model/Groups.swift`, extensions of `DesignContent` and `DesignStore`.
- Modify: `Layer/Model/Design.swift`:
  - add `ElementKind.group` and `ElementKind.placeable` ~:5;
  - add `DesignElement.group` ~:60;
  - add `group` to `CodingKeys` ~:119;
  - add `back(\.group)` to `reverting` ~:134;
  - decode it in `init(from:)` ~:157.
- Modify: `Layer/Components/Catalogue.swift`: `Catalogue.group`, and its case in `ElementKind.spec`'s switch ~:9.
- Modify: `Layer/Document/DesignFile.swift`:
  - the `screens` and `floating` getters and setters (~:66, ~:87);
  - `setChildren` ~:163;
  - the end of `init(from:)` ~:405.
- Modify: `Layer/Model/DesignStore.swift`: `change(_:)` ~:852 and `takeBack(_:)` ~:1104.
- Modify: `Layer/Model/SeveralThings.swift`: `isLocked(_:)` ~:37.
- Modify: `Layer/App/AppModel.swift`: `setSelectionLocked` ~:1306, and, for the effective lock (F4), `canTurnSelection` ~:1384 and `turnableElement` ~:1417.
- Modify: `Layer/Canvas/SelectionLayer.swift`, for the effective lock (F4):
  - the Draw-mode selection area's `isEnabled` ~:49;
  - the lock badge and the handles ~:99;
  - `CanvasDrags.moveElement` ~:502, where a drag begins.
- Modify: every exhaustive `switch` over `ElementKind` the compiler names, giving each a `.group` case that draws nothing and writes nothing. They include `Layer/Canvas/PhoneScreenView.swift` ~:166 and `Layer/Code/SwiftUICodeGenerator.swift` ~:198 and ~:315.
- Modify: `LayerTests/ComponentCatalogueTests.swift`:
  - `describeEveryKind()` iterates `ElementKind.placeable`, so the golden `Goldens/ComponentKinds.txt` doesn't change. A `.group` item has no members, so the soundness pass removes it, and `screens` leaves it out. Describing it would fail at the layout-data line.
  - `theKindsOfferedToShortcutsAreTheKindsThereAre` uses `ElementKind.placeable` in both its parts: the set it compares `ElementKindChoice.allCases` with, and the `for kind in …` loop. `ElementKindChoice(.group)` falls back to `.text`, so a loop over `allCases` fails (scan, T3). `ElementKindChoice` itself doesn't change.
  - A new test, `aGroupIsAKindNothingIsSketchedAsOrWrittenAs`.
- Test: `LayerTests/GroupTests.swift`, new, with the suite `GroupModelTests`.

**Interfaces:**
- Produces:
  - `ElementKind.group`, with raw value `"group"`, and `static var placeable: [ElementKind]`, which is every kind but `.group`.
  - **`Catalogue.group`:**
    - name "Group", symbol `rectangle.3.group`, promptName "group";
    - `writtenNames: []`, `isAskedForOnScreens: false`;
    - `size: .fixed(.zero)`, `minimumSize: CGSize(width: 8, height: 8)`;
    - `hasEffects: false`, `traits: []`.

    `belongsOnScreens` keeps its default, true. Where a group can go is decided by its leaves (Task 6). Its empty placeholder means `hasText` is false, so the popover offers no Edit text. Because `writtenNames` is empty and `isAskedForOnScreens` is false, no word names `.group` and nothing asks for one:
    - `ScreenBlueprint.kindWords` maps every case, so it holds `([], .group)`. Its words are empty, so `ScreenBlueprint.kind(named:)` never returns `.group`. `ScreenBlueprint` is left alone (F9).
    - `.group` stays out of `ScreenPrompt.kindNames` and `SketchRequest.askedCandidates`.
  - **`DesignElement.group: DesignElement.ID?`** is the group it belongs to.
    - It is declared with a default of nil, so the memberwise init keeps working.
    - It is a `CodingKey` (`"group"`), so it is not also collected into `unknownKeys`.
    - It is read with `decodeIfPresent`, and written only when set.
    - It is in `DesignElement.reverting`'s list.
  - **`DesignContent`, in Groups.swift.** It writes only through `add`, `update`, `remove`, `move` and `reorder`, because `elements` has a private setter.
    - `func members(of group: DesignElement.ID) -> [DesignElement]`: the direct members, back to front.
    - `func leaves(of group: DesignElement.ID) -> [DesignElement]`: the non-group elements at any depth.
    - `func ancestors(of id: DesignElement.ID) -> [DesignElement.ID]`: the nearest group first.
    - `func isLockedWithItsGroups(_ id:) -> Bool` and `isHiddenWithItsGroups(_ id:) -> Bool`: its own flag, or any ancestor's.
    - `var hasGroups: Bool`: true when any element is a group item or has a `group`. Members left pointing at a group that has been deleted still need the pass.
    - `mutating func keepGroupsSound()` does these, in order, and writes only what differs:
      1. **Strays.** A member is treated as ungrouped (`group = nil`) when:
         - its group is missing;
         - its group isn't a group item;
         - its group has another parent;
         - it is a drawing;
         - its chain of groups loops back on itself.
      2. **Empty groups.** A group with no members is removed.
      3. **Groups of one.** A group with one member dissolves. The member takes the group's own `group`, and the group's `isLocked` and `isHidden` are OR-ed into it.
      4. **Gathering.** Each group's members, recursively, are gathered into one run, in their order. The run ends where the frontmost member was, with the group item just in front of it. Nothing else moves. This goes through `reorder(parent, to:)` with the parent's whole raw order.
      5. **Boxes.** Each group's box is `TurnedRect.enclosing(members' canvas shapes, at: group.resolvedRotation)`, innermost groups first. It is worked out in canvas points and stored as the group item's `frame` in the item's own points: its screen's placement, or on the open canvas its own scale. Floating members can each have a scale of their own, so there is no one "host's points" to enclose in (L5). Its `rotation` is kept.
  - **The views.**
    - The `screens` and `floating` getters leave out group items. A member's `isLocked` and `isHidden` there are its effective flags.
    - The `screens` and `floating` setters keep the existing group items of the hosts they set, appended after that host's elements. The pass then puts them in front of their members, or removes them.
    - `setChildren` re-adds only the existing group items of that screen that are missing from `children` (F8). `DesignContent.updateScreen` passes it `children(of:)`, which is raw and already holds them. Appending them all again would write each group item twice under one id, which voice's tidy and change-device commands (`VoiceToolbox` ~:372, ~:393) would then do.
    - For each element, a given `isLocked` or `isHidden` equal to the effective value the getter showed keeps the stored flag. A different value is written.
    - `children(of:)` stays raw: group items included, stored flags. `updateScreen`, the Siri `takeBack`, `reorder`'s callers and Task 2's arranging read it.
  - **Where the pass runs:**
    - `DesignStore.change` runs the body and the pass in one `inout` access, so `content`'s `didSet`, which compares whole designs (C6), runs once:

      ```swift
      func applying(_ c: inout DesignContent) { body(&c); if c.hasGroups { c.keepGroupsSound() } }
      ```
    - `DesignStore.takeBack(_:)` runs it on `result` after `rehostElementsOnMissingScreens(from:)` and before `content = result`, so the reverse step records it.
    - `DesignContent.init(from:)` runs it at its end, when `hasGroups`, so a file edited elsewhere, or saved by an older build, opens sound.
  - **Looking group items up.** `DesignStore.resolve(_:)` and `element(_:)` already find group items, because the index is over `content.elements`, together with their host's placement. Everything that takes a selected group as `.element(ref)` depends on this:
    - `canvasShape`
    - `canvasFrame`
    - `isLocked`
    - `selectedElement`
    - `dropSelectionOfMissingThings`

    Test it.
  - **Lock.**
    - `DesignStore.isLocked(.element(ref))` is the effective lock (`isLockedWithItsGroups`). `AppModel.isSelectionLocked` follows it.
    - Everything that stops a selected element being moved, resized or turned reads it too (F4). A member of a locked group can be selected by a double-tap or a Layers row, and the spec says nothing in a locked group moves. These places read the stored `selected.element.isLocked` today, and switch to `store.isLocked(.element(ref))`:
      - `SelectionLayer`'s lock badge and handles (~:99): the badge shows and there are no handles;
      - the Draw-mode selection area's `isEnabled` (~:49);
      - `AppModel.turnableElement` (~:1417) and `canTurnSelection` (~:1384), so `rotateSelection` and the knob leave the member alone;
      - `CanvasDrags.moveElement`: a drag doesn't begin on an element whose effective lock is set. Today the hidden handles and the disabled targets are the only guard.
    - `AppModel.setSelectionLocked(false)` also clears the lock of every locked group above each selected thing, in one `apply` (conflict D).
    - The Layers row toggles (`toggleLock`, `toggleHidden`) keep changing the thing's own flag.
  - **For later tasks:**
    - `DesignStore.children(on host: ElementRef.Host) -> [DesignElement]`: raw, back to front, group items included, stored flags.
    - `groupItems(on host:) -> [DesignElement]`.
    - `groupItem(_ id: DesignElement.ID) -> DesignElement?`.

- [ ] **Step 1: Write the failing tests** in `GroupModelTests`. First create `Layer/Model/Groups.swift`, empty but for its imports, and `LayerTests/GroupTests.swift`, then run `xcodegen generate`, so that Step 2 compiles the tests (F11). Use Task 2's `OrderBoard` wherever a board is needed (D4). Build groups directly in `DesignContent` here, through `add`/`update`, inside one `store.apply` body where the store is used; Task 4 adds the commands.
  - `aGroupsBoxHoldsItsMembers`: three elements on a screen, two of them grouped. After `keepGroupsSound()`, the group's frame is the union of the two (at 0°).
  - `aTurnedGroupsBoxIsAtItsAngle`: the group at rotation 30. Its frame is `TurnedRect.enclosing(…, at: 30).rect`.
  - `aFloatingGroupsBoxHoldsMembersOfMixedScales` (L5): on the open canvas, a note at scale 1 and a note at scale 2 are grouped by an item at scale 1. `store.canvasFrame(of: .element(G))` is the union of the two notes' canvas frames, `store.canvasFrame(of:)` of each. Enclosing their own frames as if they shared one scale gives a different box.
  - `membersAreGatheredWithTheGroupInFrontOfThem` (D2): A–E back to front, with B and D grouped as G, and G added last, so it starts in front of E. After `keepGroupsSound()` the order is A, C, B, D, G, E. G has to move back to between D and E, so the "group just in front of its members" half can fail.
  - `aGroupLeftWithOneMemberDissolvesAndUndoBringsItBack` (Review Focus 3): through the store, delete one of two members. The group is gone, and the other member has `group == nil` and keeps its place. One `undo()` restores both members and the group, in their order.
  - `aDissolvingHiddenGroupLeavesItsMemberHidden`.
  - `aMemberOfAMissingGroupIsUngrouped` (Review Focus 4): decode a design whose element has `"group"` pointing at no element. It opens with `group == nil`.
  - `aGroupOfADrawingOrALoopIsUndone`: decoded, a drawing with a `group`, and two group items pointing at each other, open ungrouped. It doesn't hang.
  - `groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed`, for a design with a group:
    - `screens[0].elements` and `floating` hold no `.group`;
    - `SwiftUICodeGenerator.code(for:typeName:settings:)` matches the same design without the group item;
    - `CanvasPicture` lists only the members;
    - `DesignActions`' element entities hold no group.
  - `aHiddenOrLockedGroupHidesOrLocksItsMembersWithoutChangingTheirOwnFlags`:
    - The members are hidden or locked in `screens[…].elements`.
    - They aren't in `children(of:)`.
    - `store.isLocked(.element(member))` is true.
    - Setting `content.screens = content.screens` changes nothing.
  - `unlockingAMemberLockedByItsGroupUnlocksTheGroup` (conflict D): `model.setSelectionLocked(false)` with the member selected unlocks the group. It is one undo step.
  - `aMemberOfALockedGroupIsntResizedOrTurnedOnItsOwn` (F4): G holds B and D and is locked; B's own flag is not set. With `.element(B)` selected:
    - `model.canTurnSelection` is false;
    - `model.rotateSelection(by: 30)` leaves B's rotation as it was;
    - a handle drag driven through `drags.moveElement(B, …, findsNewHome: false, …)` with a `resizedTurned` rule and a 40 pt translation leaves B's frame as it was.

    Each part fails while those places read B's stored flag, which is not set.
  - `updatingAScreenKeepsEachGroupItemOnce` (F8): G holds B and D. `store.updateScreen(screen) { $0.elements[i].frame.origin.x += 10 }`, where `i` is A's index, writes the children back through `setChildren`. Afterwards:
    - exactly one element in `content.elements` has G's id;
    - G's members are B and D;
    - the order is unchanged apart from A's move.
  - `groupsSurviveTheFile`: an encode/decode round trip keeps the group item, the members' `group` and the order. Nothing lands in any element's `unknownKeys`.
  - `aDesignSavedByABuildThatKnowsNoGroupsKeepsThem` (conflict A, build 4; F1). Build 4 knows neither the kind nor the key, so simulate it that way here, with both unknown:
    - Decode the JSON of a grouped design with an element list in which the group item's `"kind"` is `"futureGroup"`, and its members point at it with an unknown key, `"futureGroupID"`. Don't use `"group"`: this build decodes it, soundness rule 1 ungroups members whose group isn't a group item, and the re-encode would drop the key. That is the stray case rule 1 exists for, as `aMemberOfAMissingGroupIsUngrouped` shows for a missing group.
    - Re-encode it. The unread item, and each member's `"futureGroupID"` in its `unknownKeys`, are written back unchanged, in place, alongside the D2 test `keysThisVersionDoesNotKnowSurviveASave`.
    - Soundness rule 1 and Review Focus 4 stay as written.
  - `aDesignWhoseMembersLostTheirPointersOpensUngrouped` (build 3 and earlier). Strip `"group"` from every element of a grouped design's JSON and decode it. The group item has gone, and every element is in place, in its order.
  - `aGroupItemResolves`: `store.resolve(groupRef)` gives the item with its host's placement, and `store.canvasShape(of: .element(groupRef))` is its box.
  - In `ComponentCatalogueTests`, `aGroupIsAKindNothingIsSketchedAsOrWrittenAs` (F9):
    - no word names `.group`: `ScreenBlueprint.kindWords`' entry for `.group` has no words, and `ScreenBlueprint.kind(named:)` returns `.group` for neither "group" nor "Group". Don't assert that `.group` is missing from `kindWords`: the list maps every case;
    - `.group` isn't in `ScreenPrompt.kindNames`;
    - it isn't among `askedCandidates` on a screen;
    - its spec's name and symbol are as above;
    - `hasText` is false.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupModelTests`. Expected: it fails to compile.
- [ ] **Step 3:** Implement. Check that `Goldens/ComponentKinds.txt` is unchanged and `everyKindAnswersAsItsRecordSays` passes.
- [ ] **Step 4:** Run these suites, then all unit tests. Expected: all pass.
  - `GroupModelTests`
  - `ComponentCatalogueTests`
  - `TurningOneElementTests`
  - `CanvasDragTests`
  - `DesignFileTests`
  - `DesignStoreTests`
  - `FlatStoreTests`
  - `FlatFormatTests`
  - `GradualEditStepTests`
  - `ConcurrentEditTests`
  - `ConcurrentEditsGroupedByEventTests`
  - `CodeGenerationTests`
  - `CanvasPictureTests`
  - `VoiceToolsTests`
  - `DesignActionTests`
- [ ] **Step 5: Commit:** `git add -A Layer LayerTests Layer.xcodeproj && git commit -m "Groups: a group item in the one list, kept sound after every change"`

---

### Task 4: Group and Ungroup

**Files:**
- Modify: `Layer/Model/Groups.swift`: `group`, `canGroup`, `ungroup`.
- Modify: `Layer/Model/LayerOrder.swift`: sibling sets include the parent group, and a group counts as its whole block.
- Modify: `Layer/App/AppModel.swift`: `groupSelection`, `ungroupSelection`, `canGroupSelection`, `canUngroupSelection`.
- Modify: `Layer/Chrome/SelectionActions.swift`.
- Modify: `Layer/Chrome/StylePanel.swift`, until Task 7 replaces this:
  - Ungroup goes in `ElementSettings`' action row when `element.kind == .group`;
  - Group goes in `SeveralSettings`' first section.
- Modify: `Layer/Canvas/SelectionLayer.swift`: `SelectionSummary` reads "Group · W × H" for a selected group item, so VoiceOver and the UI tests can tell it from an element.
- Test: `LayerTests/GroupTests.swift`, suite `GroupCommandTests`.

**Interfaces:**
- Consumes: Task 3's model and Task 2's sibling-set rules.
- Produces:
  - `DesignStore.canGroup(_ selection: CanvasSelection) -> Bool`.
  - `@discardableResult DesignStore.group(_ selection: CanvasSelection) -> ElementRef?`:
    - It takes the selection's things, minus locked ones (effective lock) and drawings. They need to be two or more, share one host and one parent group, and include no screen.
    - **It builds the group whole in one `apply` body.** It adds the item with `content.add(DesignStore.newElement(.group), to: parent, scale:)`: on the open canvas, at the frontmost member's scale. Floating members may have different scales; that is fine, because the pass encloses them in canvas points and stores the box in the item's own scale (L5). It sets the item's own `group` to the shared parent group, sets each member's `group`, and calls `reorder`. The gathering puts the group where the frontmost member was. Added on its own, the item would be removed at the end of that change, as a group with no members.
    - It is one undo step, and returns the group's ref.
  - `@discardableResult DesignStore.ungroup(_ ref: ElementRef) -> CanvasSelection?`:
    - The members take the group's own `group`, with the group's lock and hide OR-ed in, and keep their places.
    - The group item goes.
    - It is one `apply`, so one step, and returns the members as a selection.
  - **Sibling sets** in `LayerOrder.swift` are now (parent, parent group). A group moves as its whole block: the item and every descendant. Drawings still belong to no set, and the order is still written through `rawOrder(on:withDrawingsKept:)` (F7, D4).
  - **AppModel:**
    - `groupSelection()` selects the new group, and `ungroupSelection()` selects the members.
    - `canGroupSelection` is `store.canGroup(selection)` (L7).
    - `canUngroupSelection`: the selection is one group item that isn't locked.
  - **Popover:**
    - "Group" (symbol `rectangle.3.group`, ⌥⌘G, `.keyboardShortcut("g", modifiers: [.command, .option])`) appears in `severalActions` when the things share a host.
    - When they span hosts, it is shown disabled, with the accessibility hint "Things on different screens can't be grouped".
    - "Ungroup" (symbol `rectangle.3.group.fill` or similar, ⌥⇧⌘G) is on the single-element bar when the selected element is a group.
    - The rest of that bar stays as it is for a group: Format, Duplicate, Lock, Arrange and Delete.
  - **Undo name.** Both steps are named plain "Undo", as Delete is (C18 left one-offs unnamed).

- [ ] **Step 1: Write the failing tests** in `GroupCommandTests`, on Task 2's `OrderBoard`, not a copy of it (D4): A–E on a screen, two floating notes and a floating drawing.
  - `groupingScatteredThingsGathersThemWhereTheFrontmostWas`: group B and D, giving A, C, B, D, G, E. The model's selection is `.element(G)`.
  - `lockedThingsAndDrawingsAreLeftOut`: grouping B (locked), C and D makes a group of C and D. Grouping B (locked) and C is refused.
  - `thingsOnTwoScreensOrAScreenCantBeGrouped`: A and a note, or A and the screen, give `canGroup == false`.
  - `undoingAGroupPutsTheOrderBack` (Review Focus 1): after grouping B and D, one undo gives A–E back, ungrouped. Check `undo.canUndo` before and after, so it can't take two.
  - `ungroupingKeepsPlacesAndPassesLockAndHideDown`: a hidden group, ungrouped, leaves its members hidden and in their places, and the selection is the members.
  - `undoingAnUngroupPutsTheGroupBack` (Review Focus 1).
  - `aGroupInsideAGroup`: group B and C as G1, then G1 and D as G2. `ancestors(of: B) == [G1, G2]`. Ungrouping G2 leaves G1 intact.
  - `aGroupArrangesAsOneBlock`: with G holding B and D, Send to Back gives B, D, G, A, C, E.
  - `arrangingInsideAGroupStaysInside`: Bring to Front on B, inside G, gives the order D, B within G's run.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupCommandTests`. Expected: it fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `GroupCommandTests`, `GroupModelTests` and `LayerOrderTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: Group and Ungroup, and groups arranged as one block"`

---

### Task 5: Selecting with groups: outermost first, a double-tap goes in

**Files:**
- Modify: `Layer/App/AppModel.swift`:
  - `pick` ~:1131
  - `targetTapped` ~:1108
  - `canvasTapped` ~:1077
  - `hoverTarget` ~:1274
  - a new `enteredGroups`, the double-tap memory, and an injected clock
- Modify: `Layer/Model/Groups.swift`: `pickTarget`, `leaf(at:in:)`, `targets(on:entered:)`.
- Modify: `Layer/Model/Enclosure.swift`: `things(enclosedBy:)` picks whole outermost groups.
- Modify: `Layer/Canvas/SelectionLayer.swift`:
  - `ElementTargets` ~:744 gives one target to each unentered group;
  - `CanvasDrags.moveOnTarget` ~:556 and `dropOnTarget` ~:572 send a group's target to `moveGroup`/`dropGroup`;
  - the several-things areas ~:63 tap through `targetTapped`.
- Modify: `Layer/Canvas/CanvasScreen.swift`: the hover ~:76 outlines what a tap would pick.
- Test: `LayerTests/GroupTests.swift`, suite `SelectingGroupsTests`.

**Interfaces:**
- Consumes: Tasks 1, 3 and 4.
- Produces:
  - `var enteredGroups: Set<DesignElement.ID>`: every group that is an ancestor of something selected. It is worked out from `selection`.
  - `DesignStore.pickTarget(for leaf: ElementRef, entered: Set<DesignElement.ID>) -> ElementRef`: the outermost ancestor-or-self of `leaf`, on its host, that isn't in `entered`. If all of them are entered, it is `leaf`.
  - **`pick(_:)`** is given the leaf that was tapped, or a group item when a group's gap was tapped.
    - It runs Task 1's tap-rule helper, `selection(afterTapOn:from:)`, on `pickTarget`'s result, after the double-tap check below (F12). It doesn't re-implement the rule.
    - Task 5 adds one case to that helper: a selected group that holds the target is replaced by it, as a selected screen is.
    - A plain tap only reaches a member of a selected group through `pickTarget`, which gives the group itself (G is selected, not entered). So tapping B with G selected takes G out, as the user-decided line "tapping a selected thing again takes it out" says. The spec's "a tap on something inside a selected … group replaces that group" applies to the Layers panel and the double-tap (L1).
    - The resting finger's `held` thing goes through `pickTarget` too.
    - The lifting-finger guard (`rested.on == thing`) compares after `pickTarget`, so that both sides are what a tap would pick (scan, P4).
  - **The double-tap:**
    - `pick` remembers the tapped leaf (or group), the time, and the selection before the tap: `@ObservationIgnored var now: () -> ContinuousClock.Instant = { .now }`.
    - A second `pick` of the same thing within 350 ms is read against S0, the selection before the first tap. The 350 ms is a named constant, with a comment that iPadOS gives no public double-tap interval for it to read (L4).
      1. If the leaf's outermost group, or the screen or group holding it, was in S0, the selection becomes S0 with that container replaced by the next level down towards the leaf.
      2. Otherwise, if the leaf is in a group, the selection becomes S0 plus the next level below the leaf's outermost group.
      3. Otherwise, it is S0 plus the leaf.
    - A double-tap never takes a thing out.
  - **Targets (C3, C6).** `DesignStore.targets(on host:, entered:) -> [ElementRef]` gives the host's touchable things, back to front, in draw order:
    - each visible leaf outside any unentered group;
    - each unentered group, at its block's place, its members having none;
    - inside an entered group, its unentered inner groups are one target each, and its leaves their own.

    Hidden things (effective hide) have none. An unlocked drawing has none either, as today: `targets(on:entered:)` keeps the `isPickedByItsFrame` filter that `ElementTargets` applies to floating things now (~:769), and such a drawing is picked by its ink (L9). `ElementTargets` builds its `ElementTarget`s from this list:
    - A group's target gets its box (`frame` in canvas points), its angle, and its effective lock as `isLocked`. Its members' own locks don't stop the group moving.
    - `ElementTarget` and its `==` don't change. A group's target is built again only when its box, angle or lock changes.
    - `ElementTargets` reads `model.enteredGroups`, so selecting into a group swaps the group's target for its members'.
  - **`targetTapped(_:at:)`** checks for ink first, as today (C3). For a group's target it passes `pick` the leaf under the point: `store.leaf(at: canvasPoint, in: groupID)`, the topmost visible leaf whose turned frame holds the point. In a gap it passes the group.
    - The several-things areas tap through it as well: `.onTapGesture(coordinateSpace: .named(SelectionLayer.space)) { model.targetTapped(thing, at: $0) }`.
    - So a tap there finds ink first, then the leaf under the touch. Both taps of a double-tap see the same leaf.
  - **`hoverTarget(at:skippingDrawings:)`** walks each host's raw children front to back, the way the targets are laid out:
    - An unentered group whose turned box holds the point gives its topmost leaf there, or the group itself in a gap.
    - Entered groups are walked into.
    - Ink comes first; hidden things, and a name strip while names are hidden, are looked through, as today.
    - With `skippingDrawings`, which is voice's look, a group's gap is looked through too, so voice still sees elements, not groups.

    `canvasTapped` (in Draw) gets a group from a gap this way.
  - **The canvas hover** (`CanvasScreen` ~:76) outlines `pickTarget` of what `hoverTarget` found, so a tap, a drag and hover agree (conflict C).
  - **`things(enclosedBy:)`:**
    - A member of a group is never picked on its own.
    - Each top-level group is judged by its box (`canvasShape`), with `Enclosure.share`.
    - Locked and hidden groups (effective) are left out.
  - **A drag on a group's target.** `moveOnTarget` checks for ink first. Otherwise the selection becomes the group, unless the group is already in it, and the drag goes through `moveGroup(by:startingAt:owner:model:)`. `dropOnTarget` then goes through `dropGroup`.
    - Moving the group's leaves arrives in Task 6, with `position` and `rehost`. Here, test only who is moved.

- [ ] **Step 1: Write the failing tests** in `SelectingGroupsTests`, on `OrderBoard` (D4). G holds B and D; G2 holds G and C, where needed.
  - `aTapOnAMemberPicksItsOutermostGroup`.
  - `aSecondTapWithin350msGoesOneLevelIn`: `pick(B)`, then `pick(B)` 100 ms later, give `.element(B)`. The same two taps 500 ms apart give G, then nothing selected.
  - `aDoubleTapIsReadAgainstTheSelectionBeforeIt`: with G already selected, a double-tap on B gives B, not nothing. With A selected, a double-tap on B gives A + B.
  - `aDoubleTapNeverTakesAThingOut`: with ungrouped A selected, a double-tap on A leaves A selected.
  - `tapsInsideAnEnteredGroupPickTheNextLevelOnly` (Review Focus 2): with x in I and I in G2, select x by double-taps. Then:
    - a tap on y, in I, adds y;
    - a tap on z, a direct member of G2, adds z;
    - a tap on an outside thing in group H adds H.
  - `aTapInAGapInsideAGroupsBoxPicksTheGroup`, at a point between B and D inside G's box:
    - `targetTapped(.element(G), at:)` there gives G;
    - in Draw, `canvasTapped` there gives G;
    - `hoverTarget(at:, skippingDrawings: true)` there gives the screen.
  - `aGroupIsOneTargetUntilItIsEntered` (Review Focus 6):
    - `targets(on: .screen(s), entered: [])` holds G and neither B nor D;
    - with B selected, `enteredGroups == [G]`, and the targets hold B and D but not G;
    - a hidden G has no target.
  - `aLoopPicksWholeGroupsNeverMembersAlone`.
  - `aDragOnAGroupsTargetSelectsTheGroup`: drive `drags.moveOnTarget` for G's ref with nothing selected. The selection is `.element(G)`, and the drag's edit is under way.
- [ ] **Step 2:** Run `-only-testing:LayerTests/SelectingGroupsTests`. Expected: it fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run these suites, then all unit tests. Expected: all pass.
  - `SelectingGroupsTests`
  - `TapToAddTests`
  - `SeveralThingsOnTheCanvasTests`
  - `PickedByALoopTests`
  - `CanvasDragTests`
  - `HiddenHitTestTests`
  - `InkOverAnElementTests`
  - `SelectionAreaTapTests`
  - `PencilVoiceTests`
  - `HostedWindowSuites/CanvasTargetsWorkTests`
- [ ] **Step 5: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: a tap picks the outermost group, a double-tap goes one level in"`

---

### Task 6: A group moves, turns and resizes as one

**Files:**
- Modify: `Layer/Model/SeveralThings.swift`:
  - `position` ~:82 handles group refs;
  - `canvasFrames(besides:)` ~:63 leaves out a dragged group's leaves;
  - `rehost(_ selection:)` ~:202.
- Modify: `Layer/Model/DesignStore.swift`: `rehost(_ ref:)` ~:456 sends a group item to `rehostGroup`.
- Modify: `Layer/Model/Groups.swift`: `rehostGroup`, `resizeGroup`, `GroupPose`.
- Modify: `Layer/Model/TurnSession.swift`: `form`, `Member`, `matches`, `placed`, `rehosted(as:in:)`.
- Modify: `Layer/App/AppModel.swift`:
  - `canTurnSelection` ~:1384
  - `turnableElement` ~:1417
  - `severalTurn` ~:1426
  - `resetSelectionTurn` ~:1570
  - `turn(_:to:)` ~:1592
  - `selectionShape` ~:1617
- Modify: `Layer/Model/ElementLayout.swift`: `resizedProportionally`.
- Modify: `Layer/Canvas/SelectionLayer.swift`:
  - the handles ~:162;
  - `CanvasDrags.moveElement`'s write ~:524;
  - the Draw-mode selection area ~:45 for a group;
  - `SpacingOverlay` isn't shown for a group.
- Test: `LayerTests/GroupTests.swift`, suite `GroupGeometryTests`.
- Test: `LayerTests/CanvasDragWorkTests.swift`, a new hosted test in `HostedWindowSuites.CanvasTargetsWorkTests`.

**Interfaces:**
- Consumes:
  - rotation's `TurnSession`, its turn API, and `ElementLayout.resizedTurned`;
  - Task 3's box;
  - Task 5's group targets.
- Produces:
  - **`position`.**
    - Given a group's ref, it moves every leaf by the same canvas delta, in its one `apply`. Leaves land on whole points, except drawings, as today.
    - A group whose effective lock is set stays put. Leaves locked on their own move with it.
  - **`canvasFrames(besides:)`** leaves out the leaves of any group among `things`, so a dragged group doesn't snap to itself.
  - **`rehostGroup`.** `rehost(_ ref:)` for a group item calls `rehostGroup`. When the box's middle lands on another screen, or on the open canvas, it acts in one `apply` body:
    - every leaf and every group item under it moves there, with `DesignContent.move`, back to front, so their stacking is kept;
    - each keeps its place on the canvas;
    - the group item's parent follows.

    The move is refused, and the group stays put, if a leaf's kind doesn't belong on screens and the target is a screen.
  - **Drags cut short (C4).** `CanvasDrags.endAbandoned` calls `AppModel.rehost(_:)`, which calls `store.rehost(ref)`. So a group drag cut short, by a twist, a tool change or the Pencil, lands whole, in the drag's step.
  - **A member dragged alone** to another host leaves the group. Task 3's soundness rule 1 does this.
  - **`TurnSession`:**
    - `form` takes a selection holding group items and uses their leaves as members.
    - When the selection is one group, the outline starts at that group's `resolvedRotation`.
    - Each `Member.isLocked` means "stays put". It is the effective lock of the selected thing the leaf belongs to, which for a group's leaves is the group's. `matches` compares that same value, so a lock change still forms a fresh session (rotation ruling 12).
    - Every group item at or under a selected group is kept in the baseline with its rotation. `placed` turns each of them by the same angle, so nested groups stay rigid.
    - `rehosted(as:in:)` expands group refs to their leaves when it matches, so the session survives a group landing on another screen (ruling 13).
  - **`AppModel`:**
    - `turnableElement` excludes `.group`.
    - `severalTurn` also takes a single selected group item.
    - `canTurnSelection` already reads the effective lock, `store.isLocked(thing)`, from Task 3 (F4).
    - `turn(_:to:)` writes the group items' new rotations in the same `apply` body as the leaves, so the group's angle becomes the outline's angle, in the same step.
    - `selectionShape` uses `session.shape` for a single group, as it does for several, so the outline and knob go round rigidly.
    - `resetSelectionTurn` for a single group turns it to 0°: `turn(&session, to: Rotation.normalized(-session.outline.degrees))`.
  - **`ElementLayout.resizedProportionally(_ frame: CGRect, degrees: Double, from corner: Corner, by translation: CGSize) -> CGRect`:**
    - It works like `resizedTurned`, but the new size keeps the frame's aspect ratio.
    - It uses the larger of the two scale factors along the frame's own axes, with no side below 8 pt.
    - The corner opposite the dragged one stays put.
  - **The selected group's chrome.** A selected group is a selected `.element` of kind `.group`, so the single-element selection drawing applies to it. Its outline, handles and knob sit on its box.
    - Its handles use `resizedProportionally` as their rule.
    - `CanvasDrags.moveElement` never writes a group item's frame. It calls `resizeGroup(ref, to: frame, from: start)` with the `GroupPose` captured as the handle drag began.
    - Its knob and twist go through the several-things turn, never the single-element one, which would turn only the item.
    - In Draw, its selection area drags it with `drags.moveSelection`.
  - **`DesignStore.resizeGroup(_ ref: ElementRef, to frame: CGRect, from start: GroupPose? = nil)`.** `GroupPose` is the box, each leaf's frame and each nested group's rotation. A handle drag passes the pose it began with on every frame, so frames don't compound and drift. The W/H fields pass nil, meaning now. With s the ratio of the new width to the start width:
    - each leaf's centre is mapped through the box's own axes, from the start box to the new box;
    - each leaf's frame size is scaled by s;
    - the leaves' angles and font sizes don't change;
    - it is one `apply`, so one change of the handle drag's edit ("Resize"), or one step on its own.

- [ ] **Step 1: Write the failing tests** in `GroupGeometryTests`, on `OrderBoard` (D4):
  - `movingAGroupMovesItsMembers`. Drive the target drag (`moveOnTarget` and `dropOnTarget` on G's ref, then `moveGroup`). Each leaf moves by the same delta. The drag is one undo step.
  - `aLockedGroupDoesntMoveAndNeitherDoItsMembers` (moved here from Task 7, D3). G holds B and D.
    1. Unlocked, `store.position([.element(G): origin])`, with the origin 20 canvas points right of G's box, moves B and D 20 canvas points right.
    2. Locked, the same call moves nothing, and `position` with B alone moves nothing.

    Part 1 fails until this task's `position`: before it, only the group item's frame is written, and the pass puts the box back round members that didn't move.
  - `aMemberLockedOnItsOwnMovesWithItsGroup` (moved here from Task 7, D3): B is locked on its own and G isn't. `position` with G moves B by the same delta as D.
  - `droppingAGroupOnAnotherScreenMovesItWhole`.
  - `aGroupDragCutShortLandsWhole` (C4): drag G from screen A over screen B, then `drags.cancel(owner, model:)`. G and every member are on B, in their order. The history moved by exactly one step, which one Undo takes back.
  - `aMemberDraggedAloneToAnotherScreenLeavesTheGroup`.
  - `turningAGroupTurnsItsMembersAboutItsMiddleAndKeepsItsAngle`:
    1. Turn a group of an elongated button and a note, with a nested group around the note, by 30.
    2. The group's rotation is 30, the nested group's has gone up by 30, and each member turned 30 about the group's centre.
    3. Turning back to 0 restores everything exactly.
  - `aMemberLockedOnItsOwnTurnsWithItsGroup`.
  - `resizingAGroupScalesItsMembersInProportion`:
    1. Double the box from its bottom-right. The members' frames double in size, their centres keep their relative positions, and the top-left stays put. A text member's `fontSize` is unchanged.
    2. Then drive a 30-frame handle drag out and back to the start translation. Every member is exactly where it began.
  - `aTurnedGroupResizesWithoutShear`: a group at 30° with a member at 10°. After resizing, the member's angle is still 10.
  - Hosted, `aGroupDragBuildsOnlyItsOwnTarget` (Review Focus 6). A 60-frame drag of a three-member group on the 40-element board of `CanvasTargetsWorkTests` builds 60 targets: the group's own, one per frame. Read `CanvasWork` as differences, since its counts only grow.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupGeometryTests`. Expected: it fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run these suites, then all unit tests. Expected: all pass.
  - `GroupGeometryTests`
  - `TurningSeveralThingsTests`
  - `TurningOneElementTests`
  - `TwistTests`
  - `RotationFieldTests`
  - `CanvasDragLandingTests`
  - `CanvasDragTests`
  - `CanvasDragWorkTests`
  - `HostedWindowSuites/CanvasTargetsWorkTests`
- [ ] **Step 5:** In the simulator, group three things and do each of these:
  - move the group;
  - turn it with its knob;
  - resize it from a corner;
  - drop it onto another screen;
  - twist it with two fingers mid-drag.
- [ ] **Step 6: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: a group moves, turns and resizes as one"`

---

### Task 7: A group as one thing: lock, hide, duplicate, delete, and its format panel

**Files:**
- Modify: `Layer/Model/SeveralThings.swift`: `duplicate` ~:164 and `delete` ~:190.
- Modify: `Layer/Model/DesignStore.swift`: `duplicate(_ ref:)` ~:257, `delete(_ ref:)` ~:248 and `delete(_ refs:)` ~:207 for groups.
- Modify: `Layer/App/AppModel.swift`:
  - `toggleHidden` ~:1352;
  - a new `selectedLeaves`: the refs of the selected elements, with groups expanded;
  - a new `setGroupBox`, which `GroupSettings`' X/Y/W/H fields call (D3, L8).
- Modify: `Layer/Chrome/StylePanel.swift`:
  - a new `GroupSettings`, picked in `StylePanel.body` ~:15 before `ElementSettings`;
  - `SeveralSettings`' style sections, extracted to read leaves;
  - `ElementSettings`' geometry section `.disabled(model.isSelectionLocked)`;
  - the panel's lock buttons show `isSelectionLocked`.
- Modify: `Layer/Chrome/SelectionActions.swift`.
- Modify, so that Siri and voice see a selected group's members (F6):
  - `Layer/Intents/DesignActions.swift`: `elementOrSelected` ~:110, and `ElementQuery.suggestedEntities` ~:341;
  - `Layer/Voice/CanvasPicture+Capture.swift` ~:13;
  - `Layer/Voice/PencilVoice.swift`: `target(at:in:)` ~:433 and `isPart` ~:447.
- Test: `LayerTests/GroupTests.swift`, suite `GroupAsOneThingTests`.
- Test: `LayerTests/SiriIntentsTests.swift`, a new test in `DesignActionTests`; `LayerTests/PencilVoiceTests.swift`, a new test in `PencilVoiceTests` (F6).

**Interfaces:**
- Produces:
  - **Duplicate** copies the group item and every descendant, with new ids, in one `apply` body:
    - copied members point at the copied groups;
    - a copied drawing gets `withStrokesOfItsOwn()`;
    - the copied block goes to the top of its host's things, 16 pt down and to the right, as a copy does today, with its inner order kept.
  - **Delete** removes the group and every descendant, locked members included: a member locked on its own still goes with its group. It is one change. The group's own effective lock still stops it, as `delete(_ selection:)` does today.
  - **Lock and hide** on a group set the group's own flag.
    - Hiding a group lets go of it and of anything selected inside it.
    - The popover's and the panel's lock state is `isSelectionLocked` (effective). Unlock works as in Task 3.
  - **`GroupSettings`** is shown when the selection is one group item. It has:
    - a `PanelHeader` with the group's name, renameable;
    - the action row: Duplicate, Lock, the four arrange buttons, and Ungroup;
    - the X/Y/W/H of its box, in its host's points as `ElementSettings` shows an element's, each set through `model.setGroupBox`;
    - Rotation, set through `model.rotateSelection(by: new - group.resolvedRotation)`;
    - `SeveralSettings`' style sections, applied to the leaves that have each setting.
  - **`AppModel.setGroupBox(_ ref: DesignStore.ElementRef, x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil)`** is the one entry point the fields call (D3), so its tests fail until this task. It acts inside `adjusting { }`. Its values are in the group's host's points, as the panel shows them.
    - **X or Y.** `position` takes canvas points (P33, L8). So the change from the box's current X or Y is multiplied by the host's scale, and the group's box origin from `canvasShape(of:)` moves by that canvas delta through `store.position([.element(ref): origin])`.
    - **W or H.** `resizeGroup`'s s is the ratio of the widths, so an H edit alone would scale nothing (L8). Either field therefore builds the proportional frame: both sides scaled by the edited side's ratio, with the top-left kept. That frame goes to `store.resizeGroup(ref, to:)`.
  - **Siri and voice see members, never a selected group item** (F6; Global "What doesn't know about groups"):
    - `DesignActions.selectedElement(in model: AppModel) -> (ref: DesignStore.ElementRef, element: DesignElement, placement: Placement)?` is `model.selectedElement`, unless that is a group item, when it is nil.
      - `elementOrSelected` uses it, so with a group selected Siri finds no single element and throws `LayerIntentError.elementNotFound`, as it does for several things. It never moves the group item alone, which the pass would answer by ungrouping every member.
      - `ElementQuery.suggestedEntities` uses it, so a selected group isn't offered first.
    - `CanvasPicture.capture(from:handles:)` marks `model.selectedLeaves` selected, not `selectedElements`.
    - `PencilVoice.target(at:in:)` keeps the whole selection when the pen is over part of it, for a single selected group as for several things. `isPart` counts each of the selection's leaves.
  - **Panel rules.**
    - Every change goes through `model.adjusting { }`: the panel's own edit (M14), named "Format".
    - The bindings change the refs captured when they were made (M5), not the selection at the time they are set.
    - `SeveralSettings` reads `selectedLeaves` for its style sections too, so a group among several things is styled through its members.

- [ ] **Step 1: Write the failing tests** in `GroupAsOneThingTests`, on `OrderBoard` (D4). `aLockedGroupDoesntMoveAndNeitherDoItsMembers` and `aMemberLockedOnItsOwnMovesWithItsGroup` moved to Task 6: here they would already pass on Task 3's and Task 6's code (D3).
  - `duplicatingANestedGroupCopiesItWhole`: there are new ids, the copied members point at the copied groups, the original is unchanged, and it is one undo step.
  - `deletingAGroupDeletesItsMembersEvenLockedOnes`.
  - `hidingAGroupHidesItsMembersOnTheBoard`:
    - the members are hidden in `screens[…].elements`, and so not drawn;
    - their own flags are unchanged;
    - a member that was selected is let go of.
  - `aGroupsWidthFieldResizesInProportion` (D3). G holds B and D, on the half-scale screen. `model.setGroupBox(G, width: 2 × the box's width)`:
    - the box's width and height both double, and its top-left stays put;
    - B's and D's frames double in size;
    - the step is named "Format".
  - `aGroupsHeightFieldResizesInProportion` (L8): `model.setGroupBox(G, height: 2 × the box's height)` doubles the box's width as well, and B's and D's frames double in size. Passing the H edit to `resizeGroup` as it stands scales nothing, since s is the width ratio.
  - `aGroupsXFieldMovesItInTheScreensPoints` (L8): `model.setGroupBox(G, x: the box's x + 10)` moves B's and D's own frames 10 points right, 5 canvas points on the half-scale screen. Read as canvas points, it would move them 20.
  - In `DesignActionTests`, `aSelectedGroupIsNoSingleElementForSiri` (F6). A screen holds a title and a button, grouped as G.
    - With `.element(G)` selected, `DesignActions.selectedElement(in: model)` is nil. So `elementOrSelected(nil)` throws `elementNotFound`, and `suggestedEntities` puts nothing first.
    - With the button selected inside G, it gives the button.
  - In `PencilVoiceTests`, `aSqueezeOnAMemberOfASelectedGroupKeepsTheGroup` (F6). Capture `bench.title` and `bench.button` first, since grouping can change their indices. Then group them as G, with `bench.app.store.group(…)`, and select `.element(G)`.
    - `bench.hold()` over the button leaves `.element(G)` selected, not the button. Before this task, voice's look finds the button and selects it.
    - `CanvasPicture.capture(from: bench.app, handles: VoiceHandles())` marks both the title and the button selected.
    - End with `bench.end()`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupAsOneThingTests -only-testing:LayerTests/DesignActionTests -only-testing:LayerTests/PencilVoiceTests`. Expected: it fails to compile, since `setGroupBox` and `DesignActions.selectedElement(in:)` don't exist yet.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run these suites, then all unit tests. Expected: all pass.
  - `GroupAsOneThingTests`
  - `PanelStepTests`
  - `FormatPanelEditTests`
  - `SeveralThingsChangedTogetherTests`
  - `UndoNameTests`
  - `DesignActionTests`
  - `PencilVoiceTests`
  - `VoiceToolsTests`
- [ ] **Step 5: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: locked, hidden, copied, deleted and formatted as one thing"`

---

### Task 8: The Layers panel as a tree

**Files:**
- Modify: `Layer/Chrome/LayersPanel.swift`:
  - `LayersList` ~:71 builds the rows from `store.layerTree`, holds `@State private var openGroups`, and adds the Drawings section;
  - `pickLayer` ~:120 calls `pickInList`;
  - rename `LayerGroupRow` ~:148, the screen and canvas heading, to `LayerHeadingRow`;
  - add a `GroupLayerRow`;
  - `LayerRow` ~:194 gets its depth and whether it is dimmed.
- Modify: `Layer/Model/Groups.swift`: `LayerNode`, `layerTree`, `drawings`; and `targets(on: .canvas, entered:)` puts floating locked drawings after the other floating things, because hit order is draw order (C3). The order lives there only, so `ElementTargets`, which is built from that list since Task 5, follows it; `hoverTarget` mirrors it; and the canvas draws to match (L10).
- Modify: `Layer/App/AppModel.swift`: `pickInList`; F5's fold in the tap-rule helper; `hoverTarget` tests floating locked drawings before other floating things, as `targets(on: .canvas)` orders them.
- Modify: `Layer/Canvas/CanvasScreen.swift` ~:27: locked drawings are drawn above other floating things.
- Modify: `Layer/Chrome/ShareMenu.swift` ~:245: the board picture draws floating drawings last, as the canvas does.
- Test: `LayerTests/GroupTests.swift`, suite `LayerTreeTests`.
- Test: `LayerTests/LayersPanelTests.swift`, a new test in `HostedWindowSuites.LayersPanelWorkTests`.

**Interfaces:**
- Produces:
  - **`struct LayerNode: Identifiable`**, with `var element: DesignElement`, `var ref: DesignStore.ElementRef`, `var children: [LayerNode]`, `var isHiddenWithItsGroups: Bool` and `var id: DesignElement.ID`.
  - **`DesignStore.layerTree(on host: ElementRef.Host) -> [LayerNode]`** is built from `children(on:)`, with stored flags for the toggles. It returns the top-level things topmost first, each group's children topmost first, and no drawings.
  - **`DesignStore.drawings -> [ElementRef]`**, topmost first.
  - **`AppModel.pickInList(_ thing: CanvasSelection)`** calls the tap-rule helper, `selection(afterTapOn:from:)`, directly on exactly that thing (F12, D4). That is the rule as Task 5 leaves it: a selected screen or group holding the thing is replaced by it, a selected thing is taken out, and anything else is added. There is no `pickTarget` step and no double-tap. It still sets `tool = .select`, as `pickLayer` does.
  - **Adding a group folds in its selected contents** (F5; spec Tap-to-add, "adding a … group whose contents are selected folds them into it"). This task adds the fold to the helper: when the thing added is a group item, the selected things inside it, at any depth, are dropped. `CanvasSelection.init` folds only screens' elements. Without the fold, `pickInList(.element(G))` with B selected gives G + B, and a drag then moves B twice. The canvas taps share the helper, so they fold the same way.
  - **Rows (M9).**
    - `LayersList` stays the only view that reads the design, the selection and the hover.
    - Each row is given only what it shows, and compared on that with `.equatable()`: ref, symbol, name, its own lock and hide, whether it is dimmed, its depth, selected, hovered, and for a group whether it is open.
    - Never pass a row a `LayerNode` or a `DesignElement`. Their frames change on every drag frame, and the row would be built again each time.
  - **What the rows show:**
    - A row is dimmed when its thing is hidden, by its own flag or by a group above it.
    - A group row has:
      - a disclosure chevron, labelled "Show contents" or "Hide contents";
      - `rectangle.3.group`;
      - its name;
      - the lock and hide toggles.
    - A group's members are indented 16 pt per level beneath it.
    - A group is shown open while something inside it is selected (`model.enteredGroups`), and otherwise as it was last left, in `openGroups`. That state is per session and not saved.
    - Hovering a group row outlines its box, through `model.hovered = .element(groupRef)`.
  - **The canvas section:** a "Drawings" heading with the drawings' rows, then the floating things that aren't drawings.
  - **Locked drawings on top.** In `CanvasScreen`, a floating drawing gets `.zIndex(3)`; other floating things keep `2`. Hit testing and the board picture follow the same order.

- [ ] **Step 1: Write the failing tests** in `LayerTreeTests`, on `OrderBoard` (D4):
  - `theTreeListsTopmostFirstWithMembersUnderTheirGroup`.
  - `drawingsAreNotInTheTree`.
  - `aRowTapAddsOrTakesOutExactlyThatThing`, with G holding B and D:
    - With G selected, `pickInList(.element(B))` replaces G with B, because the group is B's container.
    - With A selected, `pickInList(B)` gives A + B.
    - With B selected, `pickInList(.element(G))` gives exactly `.element(G)`, not G + B: adding the group folds B into it (F5).
  - `aLockedDrawingIsTouchedAboveTheNoteItIsDrawnAbove`: a locked drawing behind a sticky note in the list:
    - is what `hoverTarget` gives where they overlap;
    - comes after the note in `targets(on: .canvas, entered: [])`, so the targets agree with the hover and the drawing (L10).
  - Hosted, in `LayersPanelWorkTests`, `aDragOfAGroupedThingBuildsNoRows` (Review Focus 6): a 60-frame drag of a member of an open group, on the suite's board with a group added, builds no rows.
- [ ] **Step 2:** Run `-only-testing:LayerTests/LayerTreeTests`. Expected: it fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `LayerTreeTests`, `HostedWindowSuites/LayersPanelWorkTests`, `HiddenHitTestTests`, `DrawingStoreTests`, `TapToAddTests` and `SelectingGroupsTests` (the tap-rule helper changed), then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator:
  - open the Layers panel with a nested group;
  - open the group and close it;
  - tap rows to add and take out;
  - check that a locked drawing is drawn above a sticky note it overlaps, and that a tap there picks it.

  Run the UI test `testADrawingIsALayerThatCanBeHiddenLockedAndCopied` from a clean install.
- [ ] **Step 6: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: the Layers panel shows groups as a tree"`

---

### Task 9: Dragging rows in the Layers panel

**Files:**
- Modify: `Layer/Model/LayerOrder.swift`: `moveLayer`.
- Modify: `Layer/Chrome/LayersPanel.swift`: reorderable lists, drops on a closed group's row, and VoiceOver actions.
- Test: `LayerTests/LayerOrderTests.swift`, suite `MovingLayersTests`.
- Reference: the branch `spike/layers-reorder`, worktree `.claude/worktrees/spike-layers`. Read `SPIKE-FINDINGS.md` and `Layer/Chrome/SpikeReorder.swift` for the API shape that worked.

**Interfaces:**
- Produces:
  - `enum LayerList: Hashable, Sendable { case host(DesignStore.ElementRef.Host); case group(DesignElement.ID) }`.
  - **`@discardableResult DesignStore.moveLayer(_ id: DesignElement.ID, to list: LayerList, before: DesignElement.ID?) -> Bool`:**
    - `before` is the row it lands above in the panel, so it lands just in front of that thing in the list.
    - Nil means the bottom of the panel's list (the spike's `.end`): the back.
    - The thing's `group` changes to the list's group, or to nil.
    - It refuses, returning false and changing nothing:
      - a move to another host;
      - a move into the thing itself, or into its own descendant;
      - a move of a drawing.
    - It is one `apply`, so one undo step. A group left with one member dissolves in that same change.
    - It writes the parent's raw order through Task 2's `rawOrder(on:withDrawingsKept:)`, the one raw-order helper, so drawings keep their slots here too (F7, D4). It doesn't build a raw order of its own.
  - **The panel:**
    - Each list is a `ForEach(…).reorderable(collectionID: LayerList…)`: each screen's top-level list, the open canvas's, and each open group's member list.
    - The rows inside stay `.equatable()`.
    - The lists are under one `.reorderContainer(for: LayerItem.self, in: LayerList.self)`. The spike attached it outside the `ScrollView`.
    - The callback's `ReorderDifference` gives `sources` (possibly several ids), `destination.collectionID` and `destination.position` (`.before(id)` or `.end`).
    - **`LayerItem`** is `Identifiable, Sendable, Codable, Transferable`, with `id: DesignElement.ID` and a `CodableRepresentation(contentType: .json)`.
    - **A closed group's row** also takes a drop, which moves the row inside at the top. This needs `.dragContainer(for: LayerItem.self)` on the container and `.dropDestination(for: LayerItem.self)` on the row. Without `dragContainer`, drops on the row silently do nothing (spike).
    - Drawings' rows aren't `reorderable`.
  - **VoiceOver:** each row that can be dragged has the custom actions "Move Up", "Move Down", "Move Into Group Above" and "Move Out of Group". They call `moveLayer`.
  - **Check first** what the spike didn't test, on the real panel:
    - a closed group's row that is itself a reorderable row;
    - VoiceOver;
    - auto-scroll at the edges;
    - the real hold time.

    If the drop on the row is unreliable, fall back to the spec's "a closed group opens while a row hovers over it".

- [ ] **Step 1: Write the failing tests** in `MovingLayersTests`, on `OrderBoard` (D4):
  - `aLayerMovesWithinItsList`.
  - `aLayerMovesIntoAGroupAndOut` (F2). G holds B then D, back to front, so the panel shows D's row above B's.
    - `moveLayer(A, to: .group(G), before: B)` puts A's row just above B's in the panel, which is just in front of B in the list. G's members are then B, A, D, back to front, and A's `group` is G.
    - `moveLayer`'s meaning of `before:` is the spec's ("before" a row on screen is "after" it in the list), and stays.
    - Moving A back to `.host(.screen(s))` makes it ungrouped.
  - `aGroupLeftWithOneMemberByAMoveDissolves`.
  - `aLayerCannotBeMovedToAnotherHostsList` (Review Focus 5).
  - `aGroupCannotBeMovedIntoItself`.
  - `aDrawingDoesntMove`.
  - `eachMoveIsOneUndoStep`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/MovingLayersTests`. Expected: it fails.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `MovingLayersTests` and `HostedWindowSuites/LayersPanelWorkTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator, use an XCUITest `press(forDuration: 0.8, thenDragTo:)`, as the spike did, to drag a row:
  - within a list;
  - into an open group;
  - out of it;
  - onto a closed group's row.

  Check that a quick swipe still scrolls the panel.
- [ ] **Step 6: Commit:** `git add -A Layer LayerTests && git commit -m "Groups: Layers panel rows drag to reorder and into and out of groups"`

---

### Task 10: UI tests, README and the device checklist

**Files:**
- Modify: `LayerUITests/SketchFlowUITests.swift`, `README.md`

- [ ] **Step 1: Write the UI tests**, using the file's helpers: `openNewDesign`, `control(_:)`, `point(_:)`, `selectionElement`, `wait(for:toHave:)` and `stroke`.
  - `testTapsAddToTheSelectionAndEmptySpaceClearsIt`:
    1. Add text and two sticky notes. Each lands selected, so tap empty canvas first, so that nothing is selected (F10). Then tap each. The "Selection" value starts with "3 items".
    2. Tap one again. It reads "2 items".
    3. Tap empty canvas. There is no selection.
  - `testGroupingFromThePopoverAndGoingInWithADoubleTap`:
    1. Add two sticky notes, then tap empty canvas, so that the last one added isn't still selected (F10). Tap each note, then tap "Group". The "Selection" value starts with "Group", and the Layers panel shows a "Group" row.
    2. Double-tap one note, with `doubleTap()`. The selection is that note: "150 × 150".
    3. Tap empty canvas, tap a note to select the group, and tap "Ungroup". The selection reads "2 items".
  - `testArrangeMenuSendsToBack`: two overlapping notes. Send the front one to the back, and the Layers panel's row order flips.
  - `testDraggingALayerRowIntoAGroup`.
- [ ] **Step 2:** Run the four tests from a clean install. Then run the whole UI suite, also from a clean install, and compare its failures with main's two known ones: `testMagicPenSketchesBecomeADesignWithCode` and `testTheReferenceDesignFitsTheCanvas`.
- [ ] **Step 3: README:** in "Freeform-style objects", say:
  - that taps add to the selection;
  - that things can be grouped (Group, Ungroup, double-tap to go in);
  - that all four arrange commands exist;
  - that the Layers panel shows groups and drags rows.
- [ ] **Step 4:** Run all unit tests. Commit: `git add -A LayerUITests README.md && git commit -m "Groups: UI tests and README"`
- [ ] **Step 5: Device checklist** on the user's iPad. Do this only with the user's go-ahead, and when no other session is using the device. Install from main after merging, as the user prefers. Each line is an action, then what should happen, riskiest first.
  - [ ] **Type a Format number, then tap empty canvas or another kind of thing.** Type 200 in W (no Return), tap empty canvas, then select the thing again; repeat tapping a thing of another kind (an element, then a group, then a screen). The number is applied and one undo takes it back.
  - [ ] **Deselect with the Format panel open, and with the keyboard up.** The panel and the keyboard close fully, with no sliver left at the trailing edge; again with Reduce Motion on.
  - [ ] **Squeeze and roll to scrub a group's W, H and Rotation.** The field scrubs; with the pen over the zoom control, the zoom ruler still takes the squeeze.
  - [ ] **Pencil hover after a double-tap into a group.** The outline shows the member, not the outer group, once the pen moves; nothing stale shows while it is still.
  - [ ] **Voice and typed screen edits with groups.** Select a group and say "make these blue"; on a screen holding groups type "make the buttons rounded". Members change, never group items.
  - [ ] **Group, Ungroup and Arrange shortcuts with the selection scrolled off-screen.** Known follow-up: they may do nothing then (they live on the popover's hidden buttons).
  - [ ] **Drop a Layers row just under an open group's row.** It lands there, below the group's members, not at the back of the list.
  - [ ] **Twist a group mid-drag over another screen.** Drag a group onto a second screen and twist two fingers while dragging, then lift. It lands whole, at that screen's scale, with every member (C4); lifting mid-twist doesn't leave it half-turned.
  - [ ] **Double-tap a member of a group.** Quickly, with a finger, on a note in an unselected group, then on one in a selected group. The first goes in to the note under the finger and the second takes nothing out; single taps aren't slowed; the 350 ms window feels right; a double-tap straddling a member's edge reads as two taps; chained quick taps in a group nested three or more deep go one level per tap; the popover doesn't appear under the second tap and eat it.
  - [ ] **Drag Layers panel rows.** Press and hold a row, drag it. The hold time feels right and not slow; a quick swipe scrolls the panel instead; dragging near the panel's top or bottom edge auto-scrolls; dropping on a closed group's row puts it inside, at the top; dropping above a group's row takes it out; VoiceOver's row actions work.
  - [ ] **Tap to add with a finger.** Tap three things in turn, tap one again, tap empty canvas. Each tap adds, the second takes it out, empty canvas clears; a tap that only just misses a selected thing's edge keeps the selection; a Pencil lasso tap and a pointer click add too.
  - [ ] **Resize a group with a corner.** Drag a corner in and out. It scales in proportion, shrinks no smaller than what is in it, and feels smooth; parts with a fixed size hold theirs.
  - [ ] **Scrub a group's W and H in the Format panel; type W, H and Rotation for a turned group.** The group follows in proportion without its aspect drifting; typed edits to a turned group land where typed.
  - [ ] **Group, turn, move.** With real fingers, group two things, turn the group by the knob and by a twist, and move it. All members go together.
  - [ ] **Keyboard shortcuts after opening a design.** With a keyboard attached, press ⌘D as the first key press after opening a design, then ⌘], ⌘[, ⇧⌘], ⇧⌘[ and ⌥⌘G. The first press isn't lost; each fires although the Arrange menu is closed.
  - [ ] **Arrange from the menu.** Open the Arrange menu above a selection and send something to the back. The menu lists front at the top and back at the bottom, even when it opens upwards; Layers shows the new order.

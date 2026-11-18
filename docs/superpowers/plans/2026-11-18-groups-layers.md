# Groups, Layer Order, Layers Panel and Tap-to-Add Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A finger tap adds to or takes from the selection; several things become a group that is selected, moved, turned, resized, locked, hidden, duplicated, arranged and deleted as one; all four layer-order commands work on one thing, a group or several; and the Layers panel shows groups as a tree whose rows can be dragged to reorder and to move into and out of groups.

**Architecture:** A group is an element of the new kind `.group` in the one list `DesignContent.elements`; members point at it with a new optional `group` field and keep their screen. One function, `DesignContent.keepGroupsSound()`, run inside the store's single change funnel, keeps every group's box current and its members together, and dissolves groups of one. Group items are left out of the views that draw, export, describe and hit-test (`screens[].elements`, `floating`), so those paths keep working unchanged; the Layers panel reads a tree built for it. Selection stays `CanvasSelection`; a selected group is `.element(ref)` of its item, and operations expand it to its members where they act on elements.

**Tech Stack:** Swift 6, SwiftUI (iPadOS 27 `reorderable(collectionID:)`, `reorderContainer(for:in:)`, `dragContainer`, `dropDestination`), Swift Testing, XCUITest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-18-groups-layers-design.md` (approved 2026-11-18). Read it first. The rotation spec (`docs/superpowers/specs/2026-11-18-rotation-design.md`) describes the turn API and `TurnSession` this builds on.

**Before Task 1:** rotation must be finished on `feature/rotation`; rebase `feature/groups` onto it (only design and plan commits are on `feature/groups` until then).

## Global Constraints

- iPadOS 27, Xcode 27.2. Unit tests are Swift Testing; UI tests XCUITest. Run `xcodegen generate` after adding or removing a file.
- Drawings stay on top: unlocked ink keeps drawing above every element; drawings never join groups; the Layers panel lists drawings in a section of their own whose rows don't drag.
- A group stays on one screen or on the open canvas, and never holds a screen. Group needs two or more things sharing one host and one parent group; locked things and drawings are left out of a new group.
- Shortcuts: Group ⌥⌘G, Ungroup ⌥⇧⌘G, Bring to Front ⇧⌘], Bring Forward ⌘], Send Backward ⌘[, Send to Back ⇧⌘[.
- One undo step for each group, ungroup, arrange, panel drag, and change made from a button or toggle. Selecting isn't undone.
- Order stays array position (no fractional keys). No file version bump: `group` is decoded with `decodeIfPresent`; an older build keeps a group item as an unread element and drops members' `group` on save.
- Generated code, voice and Siri don't know about groups: members export, are described and are offered exactly as today.
- A near miss is 8 pt on the glass round a selected thing's outline. A double-tap is a second tap on the same thing within 350 ms; the first tap always acts at once.
- Nothing is repositioned to dodge the pencil palette.

**Commands** (make this branch its own simulator once, in Task 1 Step 0):

```bash
SIM=$(xcrun simctl list devices | grep "Layer iPad Pro 11 (groups)" | grep -oE '[0-9A-F-]{36}')
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI \
  -destination "platform=iOS Simulator,id=$SIM" -only-testing:LayerTests/<SuiteType> 2>&1 | tail -30
xcodebuild test -project Layer.xcodeproj -scheme Layer -testPlan CI -destination "platform=iOS Simulator,id=$SIM" 2>&1 | tail -30
```

Every new test must fail before the code it guards; show it. Use geometry and orderings that can't pass by accident.

## Review Focus

1. **Undo after Group and after Ungroup** puts back the exact order and membership in one step, including a group made from things that weren't next to each other. → Task 4, `undoingAGroupPutsTheOrderBack`, `undoingAnUngroupPutsTheGroupBack`.
2. **Taps in nested groups:** with a member of inner group I (inside G) selected, a tap on another member of I adds it; a tap on a direct member of G adds that member; a tap on something outside G adds its outermost group. → Task 5, `tapsInsideAnEnteredGroupPickTheNextLevelOnly`.
3. **Deleting down to one member** dissolves the group, and one undo brings the group back whole. → Task 3, `aGroupLeftWithOneMemberDissolvesAndUndoBringsItBack`.
4. **A member whose group is missing** (a file edited elsewhere, or by an older build) opens as ungrouped instead of vanishing or crashing. → Task 3, `aMemberOfAMissingGroupIsUngrouped`.
5. **A panel drag onto another screen's list** changes nothing. → Task 9, `aLayerCannotBeMovedToAnotherHostsList`.

---

### Task 1: Tap-to-add

**Files:**
- Modify: `Layer/App/AppModel.swift` (`pick(_:)` ~:934, `canvasTapped(at:)` ~:907)
- Modify: `Layer/Canvas/SelectionLayer.swift` (a selection haptic)
- Test: `LayerTests/MultiSelectionTests.swift` (rewrite `aTapWithNoFingerRestingSelectsOnlyWhatIsTapped` and `aFingerRestingOnAPanelIsNotRestingOnTheCanvas`; new suite `TapToAddTests`); `LayerTests/DesignTests.swift` (`tappingAScreenSelectsItAndTappingEmptyCanvasLetsGo` may need its expectations updated to the new screen rule)

**Interfaces:**
- Produces:
  - `pick(_ thing: CanvasSelection?)` keeps its signature. With no finger resting:
    - `nil` (empty canvas) clears;
    - a thing with nothing selected selects it;
    - a thing already in the selection is taken out (`removing`);
    - a thing inside a selected screen replaces that screen;
    - otherwise the thing is added (`CanvasSelection(things + [thing])`, which folds a selected element into an added screen as today).
  - The resting-finger branch and the lifting-finger guard stay as they are.
  - `canvasTapped(at:)` for a point on a screen's empty area: with a selection, clears it; with none, selects the screen.
  - A tap on empty canvas or a screen's empty area within 8 view points of any selected thing's outline (its view shape, `Viewport.viewShape(for: store.canvasShape(of:))`, grown by 8) does nothing.
  - `private(set) var tapSelectionChanges = 0`, bumped whenever a tap changes the selection. `SelectionLayer` plays `.sensoryFeedback(.selection, trigger: model.tapSelectionChanges)`.

- [ ] **Step 0:** Make the simulator: `xcrun simctl clone F8362E19-7F0C-42CB-8FE0-1F949F7C2950 "Layer iPad Pro 11 (groups)"`. Run all unit tests once and record the baseline.
- [ ] **Step 1: Write the failing tests** in `TapToAddTests` (use `Board`):
  - `tapsAddOneAfterAnother`: `pick(title)`, `pick(body)`, `pick(note)` give `.several([title, body, note])`.
  - `tappingASelectedThingTakesItOut`: then `pick(body)` gives `.several([title, note])`, and `pick(title)` gives `.element(note)`.
  - `onlyEmptyCanvasClears`: `pick(nil)` gives nil.
  - `aScreensEmptyAreaClearsASelectionAndOtherwiseSelectsTheScreen`: with title and body selected, `canvasTapped` at a point on the screen away from every element and more than 8 pt from both gives nil; tapped again, it gives `.screen(screen)`.
  - `aNearMissKeepsTheSelection`: title and body selected; `canvasTapped` 4 view points outside the title's outline, on the screen, leaves the selection unchanged.
  - `aThingOnASelectedScreenReplacesIt`: `.screen(screen)` selected; `pick(.element(button))` gives `.element(button)`.
  - `addingAScreenFoldsItsSelectedElementsIn`: title and note selected; `pick(.screen(screen))` gives `.several([.screen(screen), note])`.
  - Rewrite the two old tests:
    - `aTapWithNoFingerRestingAddsWhatIsTapped`: title and body selected, `pick(note)` gives all three.
    - `aFingerRestingOnAPanelIsNotRestingOnTheCanvas`: the panel finger doesn't count, so `pick(body)` with title selected gives both.
- [ ] **Step 2:** Run `-only-testing:LayerTests/TapToAddTests -only-testing:LayerTests/SeveralThingsOnTheCanvasTests`. Expected: the new and rewritten tests fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run those suites, `DesignTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator, tap three elements one after another (all outlined, popover shows several), tap one again (it goes), tap a screen's empty area (all go), tap it again (the screen is selected).
- [ ] **Step 6: Commit:** `git commit -am "Groups: a tap adds to the selection or takes out; only empty space clears it"`

---

### Task 2: All four layer-order commands, for one thing or several

**Files:**
- Create: `Layer/Model/LayerOrder.swift` (an extension of `DesignContent` and `DesignStore`)
- Modify: `Layer/Model/DesignStore.swift` (`arrange`/`canArrange` delegate to the new block rules; `siblings(of:)`), `Layer/App/AppModel.swift` (`arrangeSelection`, `canArrangeSelection`), `Layer/Chrome/SelectionActions.swift` (one Arrange menu), `Layer/Chrome/StylePanel.swift` (`ElementSettings` and `SeveralSettings` action rows)
- Test: `LayerTests/LayerOrderTests.swift` (new)

**Interfaces:**
- Produces:
  - `DesignStore.arrange(_ selection: CanvasSelection, _ arrangement: Arrangement)` and `canArrange(_ selection: CanvasSelection, _ arrangement: Arrangement) -> Bool`. The existing `arrange(_ ref:_:)` / `canArrange(_ ref:_:)` become calls of these, so Siri keeps working.
  - The rules:
    1. Things are split by sibling set: same parent; same group, once groups exist in Task 4.
    2. Within a set, the moved things move as one block, keeping their own back-to-front order and closing their gaps.
    3. Front puts the block at the front; back puts it at the back.
    4. Forward puts it just in front of the first sibling that was in front of its frontmost member. Backward puts it just behind the first sibling behind its backmost member.
    5. A screen in the selection is ignored.
    6. It is one undo step.
    7. `canArrange` is false when nothing would change.
  - `AppModel.arrangeSelection(_:)` works for any selection; `func canArrangeSelection(_ arrangement: DesignStore.Arrangement) -> Bool`.
  - Popover:
    - One `Menu` button labelled "Arrange", with symbol `square.3.layers.3d`, holding the four commands with their names and symbols from `Arrangement`.
    - It is shown for a single element (not a drawing) and for several things.
    - Shortcuts: ⇧⌘], ⌘], ⌘[, ⇧⌘[ on the menu items, or on hidden buttons beside the menu if menu items can't carry them.
  - Format panel: all four `IconButton`s in `ElementSettings`' action row, and in `SeveralSettings`' first section.

- [ ] **Step 1: Write the failing tests** in `LayerOrderTests` (a board with a screen holding five elements A–E back to front, plus two floating notes):
  - `frontAndBackMoveOneThingToTheEnds`.
  - `scatteredThingsMoveAsOneBlockKeepingTheirOrder`: Send to Back on B and D gives B, D, A, C, E. Bring to Front on A and C gives B, D, E, A, C.
  - `forwardStepsPastTheNextSiblingInFront`: Bring Forward on B and C gives A, D, B, C, E.
  - `thingsOnTwoHostsEachMoveAmongTheirOwn`: one note and A to the front: the note is frontmost among the notes, and A among the screen's elements.
  - `arrangingIsOneUndoStep`.
  - `nothingToDoMeansTheCommandIsOff`: `canArrange(.front)` is false for the frontmost.
- [ ] **Step 2:** Run `-only-testing:LayerTests/LayerOrderTests`. Expected: fail to compile.
- [ ] **Step 3:** Implement; `xcodegen generate`. The model change: work out the sibling set's new back-to-front order, write the parent's whole order with that set's slots refilled, and hand it to `DesignContent.reorder(_:to:)`.
- [ ] **Step 4:** Run `LayerOrderTests`, `FlatStoreTests`, `FreeformTests`, `SiriIntentsTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -am "Groups: front, forward, backward and back for one thing or several"`

---

### Task 3: The group item, kept sound

**Files:**
- Create: `Layer/Model/Groups.swift` (`DesignContent` and `DesignStore` extensions)
- Modify: `Layer/Model/Design.swift` (`ElementKind.group`, `ElementKind.placeable`, `DesignElement.group`, `CodingKeys`, `init(from:)`), `Layer/Components/Catalogue.swift` (`.group` spec), `Layer/Document/DesignFile.swift` (`screens`/`floating` getters leave group items out and give members their effective lock and hide; setters and `setChildren` keep group items and stored flags), `Layer/Model/DesignStore.swift` (`change` runs `keepGroupsSound()`), `Layer/Canvas/PhoneScreenView.swift` and `Layer/Code/SwiftUICodeGenerator.swift` (a `.group` case in each exhaustive `switch`: draws nothing, writes nothing), `Layer/Intents/LayerEntities.swift` (`ElementKindChoice` mirrors `ElementKind.placeable`)
- Modify: `LayerTests/Goldens/ComponentKinds.txt` (re-record with `TEST_RUNNER_LAYER_RECORD_KINDS=<path>`), `LayerTests/ComponentCatalogueTests.swift` (`theKindsOfferedToShortcutsAreTheKindsThereAre` compares with `ElementKind.placeable`)
- Test: `LayerTests/GroupTests.swift` (new, suite `GroupModelTests`)

**Interfaces:**
- Produces:
  - `ElementKind.group` (raw value `"group"`) and `static var placeable: [ElementKind]`, which is every kind but `.group`.
  - `Catalogue.group`: name "Group", symbol `rectangle.3.group`, promptName "group", `writtenNames: []`, `isAskedForOnScreens: false`, `hasEffects: false`, `traits: []`. Every other field keeps its default.
  - `DesignElement.group: DesignElement.ID?`: the group it belongs to. It is saved under the key `"group"` and read with `decodeIfPresent`.
  - `DesignContent` (in `Groups.swift`):
    - `func members(of group: DesignElement.ID) -> [DesignElement]`: direct members, back to front.
    - `func leaves(of group: DesignElement.ID) -> [DesignElement]`: non-group elements at any depth.
    - `func ancestors(of id: DesignElement.ID) -> [DesignElement.ID]`: the nearest group first.
    - `var hasGroups: Bool`.
    - `mutating func keepGroupsSound()`, which in order:
      1. Treats a member whose group is missing, isn't a group, or has another parent as ungrouped (`group = nil`).
      2. Removes a group with no members.
      3. Dissolves a group with one member: the member takes the group's own `group`, and the group's `isLocked`/`isHidden` are OR-ed into it.
      4. Gathers each group's members (recursively) into one run, in their order, ending where the frontmost member was, with the group item just in front of the run. Nothing else moves.
      5. Sets each group's `frame` to the rect of `TurnedRect.enclosing(members' shapes, at: group.resolvedRotation)`, innermost groups first, in the host's points. Its `rotation` is kept.
  - The `screens` and `floating` getters leave out group items. A member's `isLocked` and `isHidden` there are its own flag OR-ed with every ancestor's. The setters and `setChildren` keep existing group items, and take each element's stored `isLocked`/`isHidden` from the stored element with the same id.
  - `DesignStore.change` runs `content.keepGroupsSound()` after the body when `content.hasGroups`.
  - `DesignStore.resolve(_:)` and `element(_:)` find group items too, with their host's placement, though the views leave them out. Everything that takes a selected group as `.element(ref)` depends on this: `canvasShape`, `isLocked`, `selectedElement`, and dropping missing things from the selection. Test it.
  - `DesignStore.groupItems(on host: ElementRef.Host) -> [DesignElement]` and `DesignStore.groupItem(_ id: DesignElement.ID) -> DesignElement?`, for later tasks.

- [ ] **Step 1: Write the failing tests** in `GroupModelTests`. Build groups directly in `DesignContent` here; Task 4 adds the commands.
  - `aGroupsBoxHoldsItsMembers`: three elements on a screen, two grouped. The group's frame is the union of the two (at 0°).
  - `aTurnedGroupsBoxIsAtItsAngle`: the group at rotation 30. Its frame is `TurnedRect.enclosing(…, at: 30).rect`.
  - `membersAreGatheredWithTheGroupInFrontOfThem`: A, B, C, D back to front, with B and D grouped as G. After `keepGroupsSound()` the order is A, C, B, D, G.
  - `aGroupLeftWithOneMemberDissolvesAndUndoBringsItBack` (Review Focus 3): through the store, delete one of two members. The group is gone, and the other member has `group == nil` and keeps its place. One `undo()` restores both members and the group.
  - `aDissolvingHiddenGroupLeavesItsMemberHidden`.
  - `aMemberOfAMissingGroupIsUngrouped` (Review Focus 4): decode a design whose element has `"group"` pointing at no element. It opens with `group == nil`.
  - `groupItemsAreLeftOutOfWhatIsDrawnExportedAndDescribed`, for a design with a group:
    - `screens[0].elements` and `floating` hold no `.group`;
    - `SwiftUICodeGenerator.code(for:)` matches the same design without the group item;
    - `CanvasPicture` lists only the members.
  - `aHiddenOrLockedGroupHidesOrLocksItsMembersWithoutChangingTheirOwnFlags`.
  - `groupsSurviveTheFile`: an encode/decode round trip keeps the group item, members' `group` and the order.
  - `aGroupItemResolves`: `store.resolve(groupRef)` gives the item with its host's placement, and `store.canvasShape(of: .element(groupRef))` is its box.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupModelTests`. Expected: fail to compile.
- [ ] **Step 3:** Implement. `xcodegen generate`; re-record the kinds golden and check that its only change is the new `## group` block.
- [ ] **Step 4:** Run `GroupModelTests`, `ComponentCatalogueTests`, `DesignTests`, `FlatStoreTests`, `SiriIntentsTests`, `VoiceToolsTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -am "Groups: a group item in the one list, kept sound after every change"`

---

### Task 4: Group and Ungroup

**Files:**
- Modify: `Layer/Model/Groups.swift` (`group`, `canGroup`, `ungroup`), `Layer/Model/LayerOrder.swift` (sibling sets include the parent group; a group counts as its whole block), `Layer/App/AppModel.swift` (`groupSelection`, `ungroupSelection`, `canGroupSelection`, `canUngroupSelection`), `Layer/Chrome/SelectionActions.swift`, `Layer/Chrome/StylePanel.swift`
- Test: `LayerTests/GroupTests.swift` (suite `GroupCommandTests`)

**Interfaces:**
- Consumes: Task 3's model; Task 2's sibling-set rules.
- Produces:
  - `DesignStore.canGroup(_ selection: CanvasSelection) -> Bool`.
  - `@discardableResult DesignStore.group(_ selection: CanvasSelection) -> ElementRef?`:
    - It takes the selection's things, minus locked ones and drawings. They need to be two or more, and share one host and one parent group.
    - It makes a group item (`newElement(.group)`) with that parent, `scale` (on the open canvas, the members' scale) and parent group.
    - The members are gathered as `keepGroupsSound()` would, with the group where the frontmost member was.
    - It is one undo step, and returns the group's ref.
  - `@discardableResult DesignStore.ungroup(_ ref: ElementRef) -> CanvasSelection?`:
    - The members take the group's own `group`, with the group's lock and hide OR-ed in, and keep their places.
    - The group item goes. It is one undo step, and returns the members as a selection.
  - Sibling sets in `LayerOrder.swift` are now (parent, parent group), and a group moves as its whole block.
  - AppModel:
    - `groupSelection()` selects the new group, and `ungroupSelection()` selects the members.
    - `canGroupSelection` and `canUngroupSelection` exist. The selection is one group item that isn't locked.
  - Popover:
    - "Group" (symbol `rectangle.3.group`, ⌥⌘G) for several things when `canGroupSelection`.
    - "Ungroup" (symbol `rectangle.3.group.fill` or similar, ⌥⇧⌘G) when a group is selected.
    - Group is shown disabled, with accessibility hint "Things on different screens can't be grouped", when the things span hosts.
    - The format panel has the same two buttons.

- [ ] **Step 1: Write the failing tests** in `GroupCommandTests` (a board with A–E on a screen and two floating notes):
  - `groupingScatteredThingsGathersThemWhereTheFrontmostWas`: group B and D, giving A, C, B, D, G, E. The selection is `.element(G)`.
  - `lockedThingsAndDrawingsAreLeftOut`: grouping B (locked), C and D makes a group of C and D. Grouping B (locked) and C is refused.
  - `thingsOnTwoScreensOrAScreenCantBeGrouped`: A and a note, or A and the screen, give `canGroup == false`.
  - `undoingAGroupPutsTheOrderBack` (Review Focus 1): after grouping B and D, one undo gives A–E back, ungrouped.
  - `ungroupingKeepsPlacesAndPassesLockAndHideDown`: a hidden group, ungrouped, leaves its members hidden and in their places, and the selection is the members.
  - `undoingAnUngroupPutsTheGroupBack` (Review Focus 1).
  - `aGroupInsideAGroup`: group B and C as G1, then G1 and D as G2. `ancestors(of: B) == [G1, G2]`. Ungrouping G2 leaves G1 intact.
  - `aGroupArrangesAsOneBlock`: with G holding B and D, Send to Back gives B, D, G, A, C, E.
  - `arrangingInsideAGroupStaysInside`: Bring to Front on B inside G gives the order D, B within G's run.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupCommandTests`. Expected: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `GroupCommandTests`, `GroupModelTests`, `LayerOrderTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -am "Groups: Group and Ungroup, and groups arranged as one block"`

---

### Task 5: Selecting with groups: outermost first, a double-tap goes in

**Files:**
- Modify: `Layer/App/AppModel.swift` (`pick`, `canvasTapped`, `hoverTarget`, `enteredGroups`, the double-tap memory), `Layer/Model/Groups.swift` (`pickTarget`), `Layer/Model/Enclosure.swift` (`things(enclosedBy:)` picks whole outermost groups), `Layer/Canvas/SelectionLayer.swift` (a drag on an unselected member moves its outermost group)
- Test: `LayerTests/GroupTests.swift` (suite `SelectingGroupsTests`)

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces:
  - `var enteredGroups: Set<DesignElement.ID>`: every group that is an ancestor of something selected.
  - `DesignStore.pickTarget(for leaf: ElementRef, entered: Set<DesignElement.ID>) -> ElementRef`: the outermost ancestor-or-self of `leaf`, on its host, that isn't in `entered`; if all of them are entered, `leaf`.
  - `pick(_:)` is given the leaf that was tapped, and picks `pickTarget` under Task 1's rules. A selected group that holds the target is replaced by it, as a selected screen is.
  - The double-tap:
    - `pick` remembers the tapped leaf, when, and the selection before the tap.
    - A second `pick` of the same leaf within 350 ms is read against that earlier selection, with S0 the selection before the first tap:
      1. If the leaf's outermost group, or the screen or group holding it, was in S0, the selection becomes S0 with that container replaced by the next level down towards the leaf.
      2. Otherwise, if the leaf is in a group, the selection becomes S0 plus the next level below the leaf's outermost group.
      3. Otherwise, it is S0 plus the leaf.
    - A double-tap never takes a thing out.
  - `canvasTapped(at:)` and `hoverTarget(at:)`: a point inside an unentered top-level group's turned box, but on none of its members, picks that group (before the screen).
  - `things(enclosedBy:)`: a member of a group is never picked on its own. Each top-level group is judged by its box (`canvasShape`) with `Enclosure.share`. Locked and hidden groups are left out.
  - Dragging an unselected element whose `pickTarget` is a group selects that group and moves it as a whole (the several-things move path, with the group as the selection).

- [ ] **Step 1: Write the failing tests** in `SelectingGroupsTests` (G holds B and D; G2 holds G and C, as needed):
  - `aTapOnAMemberPicksItsOutermostGroup`.
  - `aSecondTapWithin350msGoesOneLevelIn`: `pick(B)` and then `pick(B)` 100 ms later give `.element(B)`. The same two taps 500 ms apart give G, then nothing selected.
  - `aDoubleTapIsReadAgainstTheSelectionBeforeIt`: with G already selected, a double-tap on B gives B (not nothing). With A selected, a double-tap on B gives A + B.
  - `aDoubleTapNeverTakesAThingOut`: with ungrouped A selected, a double-tap on A leaves A selected.
  - `tapsInsideAnEnteredGroupPickTheNextLevelOnly` (Review Focus 2): with x in I and I in G2, select x by double-taps.
    - A tap on y (in I) adds y.
    - A tap on z (a direct member of G2) adds z.
    - A tap on an outside thing in group H adds H.
  - `aTapInAGapInsideAGroupsBoxPicksTheGroup`: `canvasTapped` at a point between B and D inside G's box gives G.
  - `aLoopPicksWholeGroupsNeverMembersAlone`.
  - `draggingAMemberMovesItsGroup`: test this at the model level: the subject of a drag on B is G.
- [ ] **Step 2:** Run `-only-testing:LayerTests/SelectingGroupsTests`. Expected: fail.
- [ ] **Step 3:** Implement. Inject the clock (`var now: () -> ContinuousClock.Instant = { .now }` on AppModel) so the 350 ms rule is testable.
- [ ] **Step 4:** Run this suite, `TapToAddTests`, the `MultiSelectionTests` suites, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -am "Groups: a tap picks the outermost group, a double-tap goes one level in"`

---

### Task 6: A group moves, turns and resizes as one

**Files:**
- Modify: `Layer/Model/SeveralThings.swift` (`position`, `rehost` handle group refs), `Layer/Model/DesignStore.swift` (`rehost(_ ref:)` for a group), `Layer/Model/TurnSession.swift` (`form` expands a group to its leaves, outline at the group's angle), `Layer/App/AppModel.swift` (a selected group turns through the several-things path; the group's `rotation` follows the turn), `Layer/Model/ElementLayout.swift` (`resizedProportionally`), `Layer/Model/Groups.swift` (`resizeGroup`), `Layer/Canvas/SelectionLayer.swift` (a selected group's outline, four handles and knob on its box)
- Test: `LayerTests/GroupTests.swift` (suite `GroupGeometryTests`)

**Interfaces:**
- Consumes: rotation's `TurnSession`, turn API and `ElementLayout.resizedTurned`; Task 3's box.
- Produces:
  - `position` given a group's ref moves every leaf by the same canvas delta (whole points except drawings, as today).
  - `rehost(_ ref:)` for a group: when the box's middle lands on another screen (or the open canvas), every leaf moves there, keeping their places relative to each other, and the group item's parent follows. The move is refused (stays put) if a leaf's kind doesn't belong on screens.
  - A member dragged on its own to another host leaves the group (Task 3's soundness rule does this).
  - `TurnSession.form` for a selection holding group items uses their leaves as members. When the selection is one group, the outline is at that group's `resolvedRotation`. After a turn, `AppModel` sets the group item's rotation to the outline's angle, in the same step.
  - `ElementLayout.resizedProportionally(_ frame: CGRect, degrees: Double, from corner: Corner, by translation: CGSize) -> CGRect`:
    - It works like `resizedTurned`, but the new size keeps the frame's aspect ratio. It uses the larger of the two scale factors along the frame's own axes, with no side below 8 pt.
    - The corner opposite the dragged one stays put.
  - A selected group is a selected `.element` of kind `.group`, so the single-element selection drawing applies to it. Its outline, handles and knob sit on its box. Its handles call `resizeGroup(ref, to: ElementLayout.resizedProportionally(…))` instead of writing the item's frame. Its knob and twist go through the several-things turn, never the single-element one, which would turn only the item.
  - `DesignStore.resizeGroup(_ ref: ElementRef, to frame: CGRect)`. With s the ratio of the new width to the old:
    - each leaf's centre is mapped through the box's own axes, old box to new box;
    - each leaf's frame size is scaled by s;
    - leaves' angles and font sizes don't change;
    - it is one undo step.

- [ ] **Step 1: Write the failing tests** in `GroupGeometryTests`:
  - `movingAGroupMovesItsMembers`.
  - `droppingAGroupOnAnotherScreenMovesItWhole`.
  - `aMemberDraggedAloneToAnotherScreenLeavesTheGroup`.
  - `turningAGroupTurnsItsMembersAboutItsMiddleAndKeepsItsAngle`:
    - Turn a group of an elongated button and a note by 30.
    - The group's rotation is 30, and each member turned 30 about the group's centre.
    - Turning back to 0 restores everything exactly.
  - `resizingAGroupScalesItsMembersInProportion`: double the box from its bottom-right. The members' frames double in size, their centres keep their relative positions, and the top-left stays put. A text member's `fontSize` is unchanged.
  - `aTurnedGroupResizesWithoutShear`: a group at 30° with a member at 10°. After resizing, the member's angle is still 10.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupGeometryTests`. Expected: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run this suite, `TurningSeveralThingsTests`, `TurningOneElementTests`, then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator, group three things and do each of these: move the group, turn it with its knob, resize it from a corner, and drop it onto another screen.
- [ ] **Step 6: Commit:** `git commit -am "Groups: a group moves, turns and resizes as one"`

---

### Task 7: A group as one thing: lock, hide, duplicate, delete, and its format panel

**Files:**
- Modify: `Layer/Model/SeveralThings.swift` (`duplicate`, `delete`, `isLocked` for group refs), `Layer/Model/DesignStore.swift` (`duplicate(_ ref:)`, `delete(_ ref:)` for a group), `Layer/App/AppModel.swift` (`toggleLock`, `toggleHidden` on a group), `Layer/Chrome/StylePanel.swift` (a `GroupSettings` view), `Layer/Chrome/SelectionActions.swift`
- Test: `LayerTests/GroupTests.swift` (suite `GroupAsOneThingTests`)

**Interfaces:**
- Produces:
  - Duplicating a group copies the group item and every descendant, with new ids. Members point at the copied groups, and ink gets `withStrokesOfItsOwn()`. The copy sits as a duplicate does today.
  - Deleting a group deletes it and every descendant, locked members included. A member locked on its own still goes with its group.
  - Lock and hide on a group set the group's own flag.
  - `GroupSettings` (shown when the selection is one group item) has:
    - `PanelHeader` with the group's name, renameable;
    - the action row: Duplicate, Lock, the four arrange buttons, Ungroup;
    - X/Y/W/H of the box: X/Y move the group, W/H go through `resizeGroup` keeping proportions;
    - Rotation;
    - `SeveralSettings`' style sections applied to the leaves that have each setting.

- [ ] **Step 1: Write the failing tests** in `GroupAsOneThingTests`:
  - `duplicatingANestedGroupCopiesItWhole`: there are new ids, the copied members point at the copied groups, and the original is unchanged.
  - `deletingAGroupDeletesItsMembersEvenLockedOnes`.
  - `aLockedGroupDoesntMoveAndNeitherDoItsMembers`: `position` with the group or a member does nothing.
  - `aMemberLockedOnItsOwnMovesWithItsGroup`.
  - `hidingAGroupHidesItsMembersOnTheBoard`: the members are absent from `screens[…].elements` drawn (hidden), and their own flags are unchanged.
  - `aGroupsWidthFieldResizesInProportion`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/GroupAsOneThingTests`. Expected: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run this suite, then all unit tests. Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -am "Groups: locked, hidden, copied, deleted and formatted as one thing"`

---

### Task 8: The Layers panel as a tree

**Files:**
- Modify: `Layer/Chrome/LayersPanel.swift` (tree rows, disclosure, indentation, Drawings section, taps follow the canvas rule), `Layer/Model/Groups.swift` (`layerTree`), `Layer/App/AppModel.swift` (`pickInList`), `Layer/Canvas/CanvasScreen.swift` (locked drawings drawn above other floating things)
- Test: `LayerTests/GroupTests.swift` (suite `LayerTreeTests`)

**Interfaces:**
- Produces:
  - `struct LayerNode: Identifiable` with `var element: DesignElement`, `var ref: DesignStore.ElementRef`, `var children: [LayerNode]` and `var id: DesignElement.ID`. `DesignStore.layerTree(on host: ElementRef.Host) -> [LayerNode]` returns top-level things topmost first, a group's children topmost first, and no drawings.
  - `DesignStore.drawings -> [ElementRef]`, topmost first.
  - `AppModel.pickInList(_ thing: CanvasSelection)`: Task 1's add/take-out/replace rule on exactly that thing. There is no outermost-group step and no double-tap.
  - Rows:
    - A row is dimmed when its thing is hidden, whether by its own flag or by a group above it.
    - A group row has a disclosure chevron (labelled "Show contents" or "Hide contents"), `rectangle.3.group`, its name, and the lock and hide toggles. Its members are indented 16 pt per level beneath it.
    - A group is shown open while something inside it is selected, and otherwise as last left, in `@State private var openGroups: Set<DesignElement.ID>`.
    - Hovering a group row outlines its box, through `model.hovered = .element(groupRef)`.
  - The canvas section: a "Drawings" header with the drawings' rows, then the floating non-drawing things.
  - In `CanvasScreen`, a floating drawing gets `.zIndex(3)`; other floating things keep `2`.

- [ ] **Step 1: Write the failing tests** in `LayerTreeTests`:
  - `theTreeListsTopmostFirstWithMembersUnderTheirGroup`.
  - `drawingsAreNotInTheTree`.
  - `aRowTapAddsOrTakesOutExactlyThatThing`: with G selected, `pickInList(.element(B))` replaces G with B, the group being B's container. With A selected, `pickInList(B)` gives A + B.
- [ ] **Step 2:** Run `-only-testing:LayerTests/LayerTreeTests`. Expected: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run this suite, then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator:
  - open the Layers panel with a nested group;
  - open and close it;
  - tap rows to add and take out;
  - check that a locked drawing is drawn above a sticky note it overlaps.
- [ ] **Step 6: Commit:** `git commit -am "Groups: the Layers panel shows groups as a tree"`

---

### Task 9: Dragging rows in the Layers panel

**Files:**
- Modify: `Layer/Model/LayerOrder.swift` (`moveLayer`), `Layer/Chrome/LayersPanel.swift` (reorderable lists, header drops, VoiceOver actions)
- Test: `LayerTests/LayerOrderTests.swift` (suite `MovingLayersTests`)
- Reference: `spike/layers-reorder` (`SPIKE-FINDINGS.md`, `Layer/Chrome/SpikeReorder.swift`) for the API shape that worked

**Interfaces:**
- Produces:
  - `enum LayerList: Hashable, Sendable { case host(DesignStore.ElementRef.Host); case group(DesignElement.ID) }`.
  - `@discardableResult DesignStore.moveLayer(_ id: DesignElement.ID, to list: LayerList, before: DesignElement.ID?) -> Bool`:
    - `before` is the row it lands above in the panel, so it lands just **in front of** that thing in the list. Nil means the bottom of the panel's list, the back.
    - The group changes to the list's group, or nil.
    - It refuses (returns false, changes nothing) a move to another host, into the thing itself or its own descendant, and a move of a drawing.
    - It is one undo step.
  - Panel:
    - Each screen's top-level list, the open canvas's, and each open group's member list is a `ForEach(…).reorderable(collectionID: LayerList…)`, under one `.reorderContainer(for: LayerItem.self, in: LayerList.self)`.
    - `LayerItem: Identifiable, Sendable, Codable, Transferable` with `id: DesignElement.ID` and a `CodableRepresentation(contentType: .json)`.
    - A closed group's row also takes a drop (`.dragContainer(for: LayerItem.self)` on the container, `.dropDestination(for: LayerItem.self)` on the row), which moves the row inside at the top.
    - Drawings' rows aren't `reorderable`.
  - VoiceOver: each draggable row has custom actions "Move Up", "Move Down", "Move Into Group Above" and "Move Out of Group", which call `moveLayer`.

- [ ] **Step 1: Write the failing tests** in `MovingLayersTests`:
  - `aLayerMovesWithinItsList`.
  - `aLayerMovesIntoAGroupAndOut`: moving A into G's list before D makes A a member between D and B. Moving it back to the host's list makes it ungrouped.
  - `aGroupLeftWithOneMemberByAMoveDissolves`.
  - `aLayerCannotBeMovedToAnotherHostsList` (Review Focus 5).
  - `aGroupCannotBeMovedIntoItself`.
  - `aDrawingDoesntMove`.
  - `eachMoveIsOneUndoStep`.
- [ ] **Step 2:** Run `-only-testing:LayerTests/MovingLayersTests`. Expected: fail.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run this suite, then all unit tests. Expected: all pass.
- [ ] **Step 5:** In the simulator, use an XCUITest `press(forDuration: 0.8, thenDragTo:)`, as the spike did, to drag a row within a list, into an open group, out of it, and onto a closed group's row. Check that a quick swipe still scrolls the panel.
- [ ] **Step 6: Commit:** `git commit -am "Groups: Layers panel rows drag to reorder and into and out of groups"`

---

### Task 10: UI tests, README and the device checklist

**Files:**
- Modify: `LayerUITests/SketchFlowUITests.swift`, `README.md`

- [ ] **Step 1: Write the UI tests**, using the existing helpers (`openNewDesign`, `control(_:)`, `point(_:)`, `selectionElement`):
  - `testTapsAddToTheSelectionAndEmptySpaceClearsIt`:
    1. Add text and two sticky notes, and tap each. The "Selection" value starts with "3 items".
    2. Tap one again. It reads "2 items".
    3. Tap empty canvas. There is no selection.
  - `testGroupingFromThePopoverAndGoingInWithADoubleTap`:
    1. Select two sticky notes and tap "Group". The Layers panel shows a "Group" row.
    2. Double-tap one note. The selection is that note.
    3. Select the group and tap "Ungroup".
  - `testArrangeMenuSendsToBack`: two overlapping notes. Send the front one to back; the Layers panel's row order flips.
  - `testDraggingALayerRowIntoAGroup`.
- [ ] **Step 2:** Run the four tests, then the whole UI suite, and compare its failures with main's known four.
- [ ] **Step 3:** README: in "Freeform-style objects", say that taps add to the selection, groups (Group/Ungroup, double-tap to go in), all four arrange commands, and that the Layers panel shows groups and drags rows.
- [ ] **Step 4:** Run all unit tests. Commit: `git commit -am "Groups: UI tests and README"`
- [ ] **Step 5: Device checklist** on the user's iPad. Only do this with the user's go-ahead and when no other session is using the device.
  - [ ] Tap-to-add feels right with a finger; near misses keep the selection.
  - [ ] A double-tap into a group doesn't feel delayed, and single taps aren't slowed.
  - [ ] Dragging rows in the Layers panel: the hold time, scrolling, and dropping into a closed group.
  - [ ] Group, turn, resize and move with real fingers.
